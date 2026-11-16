// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat

/// Draws a `RenderFrame` into a `.bgra8Unorm` target: the background, the window frame, the screen, the cursor, the
/// click effects and the camera, in that order, in one render pass that starts by clearing the target, blended
/// premultiplied "over".
///
/// The shaders are compiled and the pipelines built once, in `init`. The same frame and source textures
/// always give the same bytes on the same GPU.
public final class Compositor: @unchecked Sendable {
    /// The only target format: preview and export must write the same bytes, so never an `_srgb` format.
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// The compiled shaders (`ShaderSource`), for what draws into textures of its own (`BackgroundImages`).
    let library: any MTLLibrary
    private let gradientPipeline: any MTLRenderPipelineState
    private let wallpaperPipeline: any MTLRenderPipelineState
    private let backgroundImagePipeline: any MTLRenderPipelineState
    private let blurredWallpaperPipeline: any MTLRenderPipelineState
    private let screenPipeline: any MTLRenderPipelineState
    private let spritePipeline: any MTLRenderPipelineState
    private let cursorPipeline: any MTLRenderPipelineState
    private let windowBarPipeline: any MTLRenderPipelineState
    private let clickEffectPipeline: any MTLRenderPipelineState
    private let screenSampler: any MTLSamplerState
    private let spriteSampler: any MTLSamplerState

    /// Throws the compiler's error if the shaders do not build, and `RenderError` if Metal cannot make a
    /// pipeline or sampler.
    public init(device: any MTLDevice) throws {
        precondition(MemoryLayout<QuadUniforms>.stride == 80, "QuadUniforms must keep the layout of the shaders' struct: 80 bytes")
        precondition(
            MemoryLayout<WindowBarUniforms>.stride == 112, "WindowBarUniforms must keep the layout of the shaders' struct: 112 bytes")
        precondition(
            MemoryLayout<ClickEffectUniforms>.stride == 32, "ClickEffectUniforms must keep the layout of the shaders' struct: 32 bytes")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        func function(_ name: String) throws -> any MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw RenderError.missingShaderFunction(name) }
            return function
        }
        func pipeline(vertex: String, fragment: String, blended: Bool) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = Self.pixelFormat
            if blended {
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.library = library
        gradientPipeline = try pipeline(vertex: "gradientVertex", fragment: "gradientFragment", blended: false)
        wallpaperPipeline = try pipeline(vertex: "quadVertex", fragment: "wallpaperFragment", blended: false)
        backgroundImagePipeline = try pipeline(vertex: "gradientVertex", fragment: "backgroundImageFragment", blended: false)
        blurredWallpaperPipeline = try pipeline(vertex: "gradientVertex", fragment: "blurredWallpaperFragment", blended: false)
        screenPipeline = try pipeline(vertex: "quadVertex", fragment: "screenFragment", blended: true)
        spritePipeline = try pipeline(vertex: "quadVertex", fragment: "spriteFragment", blended: true)
        cursorPipeline = try pipeline(vertex: "quadVertex", fragment: "cursorFragment", blended: true)
        windowBarPipeline = try pipeline(vertex: "quadVertex", fragment: "windowBarFragment", blended: true)
        clickEffectPipeline = try pipeline(vertex: "quadVertex", fragment: "clickEffectFragment", blended: true)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        guard let screenSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.metalResourceUnavailable("screen sampler")
        }
        sampler.mipFilter = .linear
        guard let spriteSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.metalResourceUnavailable("cursor sampler")
        }
        self.screenSampler = screenSampler
        self.spriteSampler = spriteSampler
    }

    /// Encodes the frame into `target`, which must be `.bgra8Unorm` (`pixelFormat`). Positions in `frame`
    /// map onto the whole target (they are in pixels of `frame.outputSize`). The screen is drawn only when
    /// `frame.screen` is set and `screen` is given, its `crop` filling its rect; the cursor only when `frame.cursor`
    /// is set, shown (opacity above 0) and of some size, with `cursor` the texture of its image (`CursorImages`); the
    /// click effects over it (`frame.clickEffects`); the camera only when `frame.camera` is set and `camera` is given,
    /// filling its rect without stretching (cropped, centred, to the rect's shape). An `.image` background is
    /// `backgroundImage`, the texture
    /// `BackgroundImages` made of it for this size, or the frame's gradient without one. A `.wallpaper` is drawn directly
    /// without `backgroundImage`; with one, its blurred mesh gradient (`BackgroundImages.texture(forWallpaper:…)`), the
    /// grain is added to it. A window frame's title is `windowTitle`, the texture `TitleTexture` made of it, drawn at the
    /// bar's pixels (`barPixels`); none without one. `screen`, `camera`, `cursor`, `backgroundImage` and `windowTitle`
    /// must stay alive until `commandBuffer` completes.
    public func encode(
        _ frame: RenderFrame,
        screen: (any MTLTexture)?,
        camera: (any MTLTexture)?,
        cursor: any MTLTexture,
        backgroundImage: (any MTLTexture)? = nil,
        windowTitle: (any MTLTexture)? = nil,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
        let encoder = renderPass(into: target, commandBuffer: commandBuffer)
        let viewport = SIMD2<Float>(Float(frame.outputSize.x), Float(frame.outputSize.y))
        func drawFramesGradient() {
            let angle = frame.gradientAngleDegrees * .pi / 180
            drawGradient(start: frame.gradientStart, end: frame.gradientEnd, direction: SIMD2(sin(angle), -cos(angle)), encoder: encoder)
        }

        // 1. Background.
        switch frame.background {
        case .gradient:
            drawFramesGradient()
        case .image:
            if let backgroundImage {
                drawBackgroundImage(backgroundImage, viewport: viewport, encoder: encoder)
            } else {
                // The image is missing or cannot be read: the frame carries Toma classic for it.
                drawFramesGradient()
            }
        case let .color(color):
            // Both ends of that colour: every pixel is `mix(color, color, t)`, the colour itself.
            drawGradient(start: color, end: color, direction: .zero, encoder: encoder)
        case let .wallpaper(preset, _):
            if let backgroundImage {
                drawBlurredWallpaper(backgroundImage, viewport: viewport, encoder: encoder)
            } else {
                drawWallpaper(
                    preset, in: Rect(x: 0, y: 0, width: Double(viewport.x), height: Double(viewport.y)), viewport: viewport,
                    encoder: encoder)
            }
        }

        // 2. Window frame: its bar and buttons, then its title.
        if let window = frame.windowFrame, window.rect.width > 0, window.rect.height > 0 {
            drawWindowBar(window, viewport: viewport, encoder: encoder)
            if let windowTitle {
                let box = window.barPixels
                drawSprite(
                    windowTitle, origin: SIMD2<Double>(box.origin), size: SIMD2<Double>(box.size), viewport: viewport, encoder: encoder)
            }
        }

        // 3. Screen, cut by the window around it if there is one.
        if let layer = frame.screen, let screen {
            let crop = layer.crop
            // Only an area's crop is clamped: the whole frame is drawn exactly as before (the golden frames).
            drawImage(
                screen, in: layer.rect, cornerRadius: frame.windowFrame?.cornerRadius ?? layer.cornerRadius,
                uvOrigin: SIMD2(Float(crop.x), Float(crop.y)), uvSize: SIMD2(Float(crop.width), Float(crop.height)),
                clampsToCrop: crop != Rect(x: 0, y: 0, width: 1, height: 1), shape: frame.windowFrame?.rect, viewport: viewport,
                encoder: encoder)
        }

        // 4. Cursor, its hotspot at the cursor position, pressed smaller about it, at its opacity.
        if let layer = frame.cursor, layer.opacity > 0 {
            let height = layer.height * layer.clickScale
            if height > 0, height.isFinite, layer.aspect > 0, layer.aspect.isFinite {
                let size = SIMD2(height * layer.aspect, height)
                drawSprite(
                    cursor, origin: layer.hotspot - layer.hotspotFraction * size, size: size, opacity: Float(min(layer.opacity, 1)),
                    viewport: viewport, encoder: encoder)
            }
        }

        // 5. Click effects, over the cursor.
        drawClickEffects(frame.clickEffects, viewport: viewport, encoder: encoder)

        // 6. Camera, over everything.
        if let layer = frame.camera, let camera {
            let fill = Self.aspectFill(SIMD2(Double(camera.width), Double(camera.height)), in: layer.rect)
            drawImage(
                camera, in: layer.rect, cornerRadius: layer.cornerRadius, uvOrigin: fill.origin, uvSize: fill.size,
                viewport: viewport, encoder: encoder)
        }
        encoder.endEncoding()
    }

    /// Draws `preset` alone into all of `target` (`.bgra8Unorm`): in one quad as `encode` draws a frame's wallpaper when
    /// `tileSize` is `nil`, otherwise in one quad per square of `tileSize` pixels (cut at the right and bottom edges). For
    /// tests: nothing in a wallpaper depends on how its drawing is split.
    func encodeWallpaper(_ preset: WallpaperPreset, tileSize: Int?, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        let encoder = renderPass(into: target, commandBuffer: commandBuffer)
        let size = SIMD2(target.width, target.height)
        let viewport = SIMD2<Float>(Float(size.x), Float(size.y))
        let step = tileSize ?? max(size.x, size.y)
        precondition(step > 0, "Tiles of \(step) pixels")
        for y in stride(from: 0, to: size.y, by: step) {
            for x in stride(from: 0, to: size.x, by: step) {
                let tile = Rect(x: Double(x), y: Double(y), width: Double(min(step, size.x - x)), height: Double(min(step, size.y - y)))
                drawWallpaper(preset, in: tile, viewport: viewport, encoder: encoder)
            }
        }
        encoder.endEncoding()
    }

    /// A render pass into `target` (`.bgra8Unorm`) that starts by clearing it to opaque black.
    private func renderPass(into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> any MTLRenderCommandEncoder {
        precondition(target.pixelFormat == Self.pixelFormat, "Compositor draws into \(Self.pixelFormat) only, not \(target.pixelFormat)")
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        attachment.storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("Compositor: the command buffer takes no render pass (already committed, or another encoder is open)")
        }
        encoder.label = "Compositor"
        return encoder
    }

    /// Fills the whole target with the gradient from `start` to `end` along `direction` (`gradientFragment`).
    private func drawGradient(start: SIMD4<Float>, end: SIMD4<Float>, direction: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        var gradient = GradientUniforms(start: start, end: end, direction: direction, padding: .zero)
        encoder.setRenderPipelineState(gradientPipeline)
        encoder.setFragmentBytes(&gradient, length: MemoryLayout<GradientUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Fills the whole target with `texture`, a background image made for the stage's size (`backgroundImageFragment`).
    private func drawBackgroundImage(_ texture: any MTLTexture, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        var stageSize = viewport
        encoder.setRenderPipelineState(backgroundImagePipeline)
        encoder.setFragmentBytes(&stageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Fills the whole target with `mesh`, a wallpaper's mesh gradient blurred for the stage's size, and the grain of the
    /// output pixels (`blurredWallpaperFragment`).
    private func drawBlurredWallpaper(_ mesh: any MTLTexture, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        var stageSize = viewport
        encoder.setRenderPipelineState(blurredWallpaperPipeline)
        encoder.setFragmentBytes(&stageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(mesh, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Draws the part `rect` (output pixels) of `preset` over a stage of the whole output (`wallpaperFragment`).
    private func drawWallpaper(_ preset: WallpaperPreset, in rect: Rect, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        let origin = SIMD2(Float(rect.x), Float(rect.y)), size = SIMD2(Float(rect.width), Float(rect.height))
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        var wallpaper = WallpaperUniforms(stageSize: viewport, count: UInt32(preset.points.count), padding: 0)
        encoder.setRenderPipelineState(wallpaperPipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&wallpaper, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
        preset.points.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        preset.colors.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws `texture`, premultiplied, into the rect at `origin` of `size` (output pixels), all of it: as it is
    /// (`spriteFragment`), or at `opacity` (`cursorFragment`).
    private func drawSprite(
        _ texture: any MTLTexture, origin: SIMD2<Double>, size: SIMD2<Double>, opacity: Float? = nil, viewport: SIMD2<Float>,
        encoder: any MTLRenderCommandEncoder
    ) {
        var quad = QuadUniforms(
            viewport: viewport,
            origin: SIMD2<Float>(origin),
            size: SIMD2<Float>(size),
            contentOrigin: SIMD2<Float>(origin),
            contentSize: SIMD2<Float>(size),
            uvOrigin: .zero,
            uvSize: .one,
            radius: 0)
        if var opacity {
            encoder.setRenderPipelineState(cursorPipeline)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        } else {
            encoder.setRenderPipelineState(spritePipeline)
        }
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(spriteSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws `layers` in order (`clickEffectFragment`), each over the square around it that holds its outline and its
    /// antialiased edge; nothing of one at opacity 0 or of no size. Their positions are stage coordinates, which are
    /// output pixels while the stage is not transformed: with the zoom's camera, they are drawn once, never blurred,
    /// after the blur's subsamples are resolved, through the stage's transform at the frame's time (plan decision 26).
    private func drawClickEffects(
        _ layers: [ClickEffectLayer], viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder
    ) {
        guard !layers.isEmpty else { return }
        encoder.setRenderPipelineState(clickEffectPipeline)
        for layer in layers {
            guard layer.opacity > 0, layer.opacity.isFinite, layer.radius > 0, layer.radius.isFinite, layer.center.x.isFinite,
                  layer.center.y.isFinite
            else { continue }
            let ring = layer.kind == .ripple
            let thickness = ring && layer.thickness.isFinite ? max(layer.thickness, 0) : 0
            // A ring's white, its outline and half a pixel of antialiasing past it; a disc's edge and half a pixel.
            let reach = layer.radius + thickness / 2 + (ring ? 2 : 1)
            let origin = SIMD2<Float>(layer.center - reach), size = SIMD2<Float>(repeating: Float(2 * reach))
            var quad = QuadUniforms(
                viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
                uvSize: .one, radius: 0)
            var uniforms = ClickEffectUniforms(
                center: SIMD2<Float>(layer.center), radius: Float(layer.radius), thickness: Float(thickness),
                opacity: Float(min(layer.opacity, 1)), outline: Float(min(ClickEffects.outlineOpacity(of: layer), 1)),
                ring: ring ? 1 : 0)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ClickEffectUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Draws the title bar of `window` with its buttons (`windowBarFragment`), over a quad one pixel larger than the bar
    /// on every side and one more at the bottom, where the bar goes on one pixel under the screen.
    private func drawWindowBar(_ window: WindowFrameLayer, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        let rect = window.rect, bar = window.barHeight
        let origin = SIMD2(Float(rect.x - 1), Float(rect.y - 1)), size = SIMD2(Float(rect.width + 2), Float(bar + 3))
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        let colors = WindowFrameLayer.buttonColors
        var uniforms = WindowBarUniforms(
            barColor: window.barColor, red: colors[0], yellow: colors[1], green: colors[2],
            windowOrigin: SIMD2(Float(rect.x), Float(rect.y)), windowSize: SIMD2(Float(rect.width), Float(rect.height)),
            firstButton: SIMD2<Float>(window.firstButton), buttonSpacing: Float(WindowFrameLayer.buttonSpacing * bar),
            buttonRadius: window.buttons ? Float(WindowFrameLayer.buttonDiameter / 2 * bar) : 0,
            radius: Float(max(window.cornerRadius, 0)), barBottom: Float(rect.y + bar))
        encoder.setRenderPipelineState(windowBarPipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WindowBarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws the part `uvOrigin`, `uvSize` of `texture` into `rect` with rounded corners (`screenFragment`), over a
    /// quad one pixel larger on every side so its antialiased edge is drawn whole; with `clampsToCrop`, nothing of
    /// `texture` outside that part shows, not even blended at the edge. With a `shape`, the rounded rect that cuts it is
    /// that one (with `cornerRadius`), and `rect`'s own edges are square. Nothing for an empty rect.
    private func drawImage(
        _ texture: any MTLTexture, in rect: Rect, cornerRadius: Double, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
        clampsToCrop: Bool = false, shape: Rect? = nil, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        var quad = QuadUniforms(
            viewport: viewport,
            origin: SIMD2(Float(rect.x - 1), Float(rect.y - 1)),
            size: SIMD2(Float(rect.width + 2), Float(rect.height + 2)),
            contentOrigin: SIMD2(Float(rect.x), Float(rect.y)),
            contentSize: SIMD2(Float(rect.width), Float(rect.height)),
            uvOrigin: uvOrigin,
            uvSize: uvSize,
            radius: Float(max(cornerRadius, 0)),
            clampsToCrop: clampsToCrop ? 1 : 0,
            shapeOrigin: shape.map { SIMD2(Float($0.x), Float($0.y)) } ?? .zero,
            shapeSize: shape.map { SIMD2(Float($0.width), Float($0.height)) } ?? .zero)
        encoder.setRenderPipelineState(screenPipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// The part of an image of `size` that fills `rect` without stretching: all of it along the axis where its
    /// shape is narrower than the rect's, the middle of it along the other.
    static func aspectFill(_ size: SIMD2<Double>, in rect: Rect) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard size.x > 0, size.y > 0, rect.width > 0, rect.height > 0 else { return (.zero, .one) }
        let imageAspect = size.x / size.y, rectAspect = rect.width / rect.height
        if imageAspect > rectAspect {
            let width = rectAspect / imageAspect
            return (SIMD2(Float((1 - width) / 2), 0), SIMD2(Float(width), 1))
        }
        let height = imageAspect / rectAspect
        return (SIMD2(0, Float((1 - height) / 2)), SIMD2(1, Float(height)))
    }
}

/// `GradientUniforms` in `ShaderSource.metal`.
private struct GradientUniforms {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var direction: SIMD2<Float>
    var padding: SIMD2<Float>
}

/// `WallpaperUniforms` in `ShaderSource.metal`: 16 bytes.
struct WallpaperUniforms {
    var stageSize: SIMD2<Float>
    var count: UInt32
    var padding: UInt32
}

/// `QuadUniforms` in `ShaderSource.metal`: 80 bytes.
private struct QuadUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var contentOrigin: SIMD2<Float>
    var contentSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var radius: Float
    var clampsToCrop: Float = 0
    var shapeOrigin: SIMD2<Float> = .zero
    var shapeSize: SIMD2<Float> = .zero
}

/// `ClickEffectUniforms` in `ShaderSource.metal`: 32 bytes.
private struct ClickEffectUniforms {
    var center: SIMD2<Float>
    var radius: Float
    var thickness: Float
    var opacity: Float
    var outline: Float
    var ring: Float
    var padding: Float = 0
}

/// `WindowBarUniforms` in `ShaderSource.metal`: 112 bytes.
private struct WindowBarUniforms {
    var barColor: SIMD4<Float>
    var red: SIMD4<Float>
    var yellow: SIMD4<Float>
    var green: SIMD4<Float>
    var windowOrigin: SIMD2<Float>
    var windowSize: SIMD2<Float>
    var firstButton: SIMD2<Float>
    var buttonSpacing: Float
    var buttonRadius: Float
    var radius: Float
    var barBottom: Float
    var padding: SIMD2<Float> = .zero
}
