// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the device frame (phase 2 design §6.7, `deviceFrame-1`), made with the compositor's
/// (`LayerPipelines`): its body (`deviceBodyFragment`) and the MacBook base's shadow (the core's `screenShadowFragment`,
/// under the base) in the stage's passes, straight into the target and into a subsample of the motion blur's; its island
/// or notch (`deviceCutoutFragment`) in the passes of what goes over the stage, straight into the target and into the
/// motion blur's target.
struct DeviceFramePipelines {
    private let body: any MTLRenderPipelineState
    private let subsampleBody: any MTLRenderPipelineState
    private let baseShadow: any MTLRenderPipelineState
    private let subsampleBaseShadow: any MTLRenderPipelineState
    private let cutout: any MTLRenderPipelineState
    private let blurTargetCutout: any MTLRenderPipelineState

    init(maker: PipelineMaker) throws {
        precondition(
            MemoryLayout<DeviceBodyUniforms>.stride == 208, "DeviceBodyUniforms must keep the layout of the shaders' struct: 208 bytes")
        precondition(
            MemoryLayout<DeviceCutoutUniforms>.stride == 64, "DeviceCutoutUniforms must keep the layout of the shaders' struct: 64 bytes")
        precondition(
            MemoryLayout<DeviceShadowUniforms>.stride == 32, "DeviceShadowUniforms must keep the layout of the shaders' struct: 32 bytes")
        func make(_ fragment: String, _ pass: LayerPass) throws -> any MTLRenderPipelineState {
            try maker.pipeline(vertex: "quadVertex", fragment: fragment, blending: .over, into: pass.attachments)
        }
        body = try make("deviceBodyFragment", .target)
        subsampleBody = try make("deviceBodyFragment", .subsample)
        baseShadow = try make("screenShadowFragment", .target)
        subsampleBaseShadow = try make("screenShadowFragment", .subsample)
        cutout = try make("deviceCutoutFragment", .target)
        blurTargetCutout = try make("deviceCutoutTargetFragment", .blurTarget)
    }

    /// The body's and the base shadow's pipelines of the stage's `pass`.
    func body(for pass: LayerPass) -> (body: any MTLRenderPipelineState, baseShadow: any MTLRenderPipelineState) {
        switch pass {
        case .target: (body, baseShadow)
        case .subsample: (subsampleBody, subsampleBaseShadow)
        case .blurTarget: preconditionFailure("The device's body is drawn with the stage, never over the motion blur's average")
        }
    }

    /// The island's or the notch's pipeline of `pass`, over the stage.
    func cutout(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: cutout
        case .blurTarget: blurTargetCutout
        case .subsample: preconditionFailure("The device's island or notch is drawn over the stage, never into a subsample of it")
        }
    }
}

extension Compositor {
    /// Draws the device `layer` around the screen through `stage` (as it is when `nil`) in an output of `outputSize`, into
    /// `pass`, counting it in `counts.deviceFrames`: in `drawFrame`, step 1 of phase 2 design §11, right after the window
    /// frame and before the screen. The MacBook base's shadow first (under the base, `screenShadowFragment`), then the body
    /// (`deviceBodyFragment`) over one quad of the device's bounds and a pixel more on every side, so every antialiased
    /// edge is drawn whole: the base, the buttons, the band and the bezel. Nothing without one, nor for one hidden (its
    /// opacity not above 0) or of no size.
    func drawDeviceFrame(
        _ layer: DeviceFrameLayer?, through stage: StageTransform?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard let layer, let opacity = Self.deviceOpacity(layer) else { return }
        let drawn = stage?.drawn(layer, outputSize: outputSize) ?? layer
        let rects = drawn.rects, bounds = rects.bounds
        guard [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite), bounds.width > 0, bounds.height > 0
        else { return }
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        let pipelines = layers.deviceFrame.body(for: pass)

        // The base's shadow, under the base drawn over it next at the group's opacity.
        if let shadow = drawn.baseShadow, let base = rects.base, let box = ShadowMath.Box(shadow) {
            let reach = 3 * box.sigma + 1
            let origin = box.lower - reach, size = box.upper - box.lower + 2 * reach
            var quad = QuadUniforms(
                viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
                uvSize: .one, radius: 0)
            var uniforms = DeviceShadowUniforms(
                lower: box.lower, upper: box.upper, sigma: box.sigma, corner: box.corner, opacity: box.opacity)
            var shape = Self.shape(base, cornerRadius: 0, bottomRadius: rects.baseFrontRadius, viewport: viewport)
            var shown = opacity
            encoder.setRenderPipelineState(pipelines.baseShadow)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DeviceShadowUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&shape, length: MemoryLayout<QuadUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&shown, length: MemoryLayout<Float>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        let origin = SIMD2(Float(bounds.x - 1), Float(bounds.y - 1)), size = SIMD2(Float(bounds.width + 2), Float(bounds.height + 2))
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero, uvSize: .one,
            radius: 0)
        var uniforms = DeviceBodyUniforms(drawn, opacity: opacity)
        encoder.setRenderPipelineState(pipelines.body)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DeviceBodyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        counts.deviceFrames += 1
    }

    /// Draws what of the device `layer` goes over the screen (the iPhone's island, the MacBook's notch) through `stage`,
    /// the frame's transform of the device (the stage's zoom on the stage, the background's in a card; as it is when
    /// `nil`), in an output of `outputSize`, into `pass`, counting it in `counts.deviceOverlays`: first in
    /// `drawOverTheStage`, once and never blurred, over the cursor and under the click effects (plan 2b decision 10), in
    /// the bezel's colour at the group's opacity. Nothing without one, nor for one without a cutout, hidden or of no size.
    func drawDeviceOverlay(
        _ layer: DeviceFrameLayer?, through stage: StageTransform?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard let layer, layer.rects.cutout != nil, let opacity = Self.deviceOpacity(layer) else { return }
        let drawn = stage?.drawn(layer, outputSize: outputSize) ?? layer
        guard let cutout = drawn.rects.cutout, [cutout.x, cutout.y, cutout.width, cutout.height].allSatisfy(\.isFinite),
              cutout.width > 0, cutout.height > 0
        else { return }
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        var uniforms = DeviceCutoutUniforms(drawn, cutout: cutout, opacity: opacity)
        let reach = uniforms.fillet + 1
        let origin = SIMD2(uniforms.cutout.x - reach, uniforms.cutout.y - reach)
        let size = SIMD2(uniforms.cutout.z + 2 * reach, uniforms.cutout.w + 2 * reach)
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero, uvSize: .one,
            radius: 0)
        encoder.setRenderPipelineState(layers.deviceFrame.cutout(for: pass))
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DeviceCutoutUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        counts.deviceOverlays += 1
    }

    /// `layer`'s opacity from 0 to 1 (0 if not a number); `nil` when it is not above 0, and nothing of it is drawn.
    private static func deviceOpacity(_ layer: DeviceFrameLayer) -> Float? {
        let opacity = layer.opacity.isNaN ? 0 : min(max(layer.opacity, 0), 1)
        return opacity > 0 ? Float(opacity) : nil
    }
}

/// The MacBook's notch, as fractions of its height: its bottom corners and the concave corners where it meets the screen's
/// top edge (`deviceFrame-1`).
private enum NotchShape {
    static let bottomCorners = 0.28
    static let fillets = 0.18
}

/// `DeviceBodyUniforms` in `ShaderSource+DeviceFrame.swift`: 208 bytes.
private struct DeviceBodyUniforms {
    var band: SIMD4<Float>
    var bezel: SIMD4<Float>
    var base: SIMD4<Float>
    var body: SIMD4<Float>
    var screen: SIMD4<Float>
    var baseRect: SIMD4<Float>
    var groove: SIMD4<Float>
    var button0: SIMD4<Float>
    var button1: SIMD4<Float>
    var button2: SIMD4<Float>
    var button3: SIMD4<Float>
    var bodyRadius: Float
    var bodyBottomRadius: Float
    var bandWidth: Float
    var screenRadius: Float
    var baseFrontRadius: Float
    var grooveShade: Float
    var buttonRadius: Float
    var opacity: Float

    /// For `layer` as it is drawn, at `opacity`.
    init(_ layer: DeviceFrameLayer, opacity: Float) {
        let rects = layer.rects
        func floats(_ r: Rect) -> SIMD4<Float> { SIMD4(Float(r.x), Float(r.y), Float(r.width), Float(r.height)) }
        band = layer.band
        bezel = layer.bezel
        base = layer.base
        body = floats(rects.body)
        screen = floats(rects.screen)
        baseRect = rects.base.map(floats) ?? .zero
        // The groove at the middle of the base's top edge.
        groove = rects.base.map { base in
            let width = DeviceMeasures.macBookGrooveWidth * base.width
            return floats(Rect(
                x: base.x + (base.width - width) / 2, y: base.y, width: width, height: DeviceMeasures.macBookGrooveHeight * base.height))
        } ?? .zero
        // Each button reaching under the band from the side of the body it is on, by the band and its own thickness.
        let body = rects.body
        let buttons: [SIMD4<Float>] = rects.buttons.prefix(4).map { button in
            let thickness = min(button.width, button.height), reach = rects.bandWidth + thickness
            var r = button
            if button.x + button.width <= body.x + 1e-9 {
                r.width += reach
            } else if button.x >= body.x + body.width - 1e-9 {
                r.x -= reach
                r.width += reach
            } else if button.y + button.height <= body.y + 1e-9 {
                r.height += reach
            } else {
                r.y -= reach
                r.height += reach
            }
            return floats(r)
        }
        let padded = buttons + Array(repeating: SIMD4<Float>.zero, count: 4 - buttons.count)
        (button0, button1, button2, button3) = (padded[0], padded[1], padded[2], padded[3])
        bodyRadius = Float(max(rects.bodyCornerRadius, 0))
        bodyBottomRadius = layer.model == .macBook
            ? Float(DeviceMeasures.macBookLidBottomCorners * rects.screen.width) : bodyRadius
        bandWidth = Float(max(rects.bandWidth, 0))
        screenRadius = Float(max(rects.screenCornerRadius, 0))
        baseFrontRadius = Float(max(rects.baseFrontRadius, 0))
        grooveShade = Float(DeviceMeasures.macBookGrooveShade)
        buttonRadius = Float(rects.buttons.map { min($0.width, $0.height) }.min() ?? 0)
        self.opacity = opacity
    }
}

/// `DeviceCutoutUniforms` in `ShaderSource+DeviceFrame.swift`: 64 bytes.
private struct DeviceCutoutUniforms {
    var color: SIMD4<Float>
    var cutout: SIMD4<Float>
    var topRadius: Float
    var bottomRadius: Float
    var fillet: Float
    var edge: Float
    var opacity: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0

    /// For `layer`'s `cutout` as it is drawn, at `opacity`: the iPhone's island a capsule; the MacBook's notch reaching up
    /// into the bezel by its height (the bezel above the screen is taller), with its fillets at the screen's top edge.
    init(_ layer: DeviceFrameLayer, cutout: Rect, opacity: Float) {
        color = layer.bezel
        edge = Float(cutout.y)
        self.opacity = opacity
        switch layer.model {
        case .macBook:
            let height = cutout.height
            self.cutout = SIMD4(Float(cutout.x), Float(cutout.y - height), Float(cutout.width), Float(2 * height))
            topRadius = 0
            bottomRadius = Float(NotchShape.bottomCorners * height)
            fillet = Float(NotchShape.fillets * height)
        case .iPhone, .iPad:
            self.cutout = SIMD4(Float(cutout.x), Float(cutout.y), Float(cutout.width), Float(cutout.height))
            topRadius = Float(min(cutout.width, cutout.height) / 2)
            bottomRadius = topRadius
            fillet = 0
        }
    }
}

/// `ShadowUniforms` in `ShaderSource.metal`: 32 bytes.
private struct DeviceShadowUniforms {
    var lower: SIMD2<Float>
    var upper: SIMD2<Float>
    var sigma: Float
    var corner: Float
    var opacity: Float
    var padding: Float = 0
}
