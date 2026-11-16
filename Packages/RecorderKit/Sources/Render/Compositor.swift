// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat

/// Draws a `RenderFrame` into a `.bgra8Unorm` target: the gradient, the screen, the cursor and the camera, in that
/// order, in one render pass that starts by clearing the target, blended premultiplied "over".
///
/// The shaders are compiled and the pipelines built once, in `init`. The same frame and source textures
/// always give the same bytes on the same GPU.
public final class Compositor: @unchecked Sendable {
    /// The only target format: preview and export must write the same bytes, so never an `_srgb` format.
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private let gradientPipeline: any MTLRenderPipelineState
    private let screenPipeline: any MTLRenderPipelineState
    private let spritePipeline: any MTLRenderPipelineState
    private let screenSampler: any MTLSamplerState
    private let spriteSampler: any MTLSamplerState

    /// Throws the compiler's error if the shaders do not build, and `RenderError` if Metal cannot make a
    /// pipeline or sampler.
    public init(device: any MTLDevice) throws {
        precondition(MemoryLayout<QuadUniforms>.stride == 64, "QuadUniforms must keep the layout of the shaders' struct: 64 bytes")
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
        gradientPipeline = try pipeline(vertex: "gradientVertex", fragment: "gradientFragment", blended: false)
        screenPipeline = try pipeline(vertex: "quadVertex", fragment: "screenFragment", blended: true)
        spritePipeline = try pipeline(vertex: "quadVertex", fragment: "spriteFragment", blended: true)

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
    /// is set; the camera only when `frame.camera` is set and `camera` is given, filling its rect without stretching
    /// (cropped, centred, to the rect's shape). `screen`, `camera` and `cursor` must stay alive until `commandBuffer`
    /// completes.
    public func encode(
        _ frame: RenderFrame,
        screen: (any MTLTexture)?,
        camera: (any MTLTexture)?,
        cursor: any MTLTexture,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
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
        let viewport = SIMD2<Float>(Float(frame.outputSize.x), Float(frame.outputSize.y))

        // 1. Background.
        let angle = frame.gradientAngleDegrees * .pi / 180
        var gradient = GradientUniforms(
            start: frame.gradientStart, end: frame.gradientEnd, direction: SIMD2(sin(angle), -cos(angle)), padding: .zero)
        encoder.setRenderPipelineState(gradientPipeline)
        encoder.setFragmentBytes(&gradient, length: MemoryLayout<GradientUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. Screen.
        if let layer = frame.screen, let screen {
            let crop = layer.crop
            // Only an area's crop is clamped: the whole frame is drawn exactly as before (the golden frames).
            drawImage(
                screen, in: layer.rect, cornerRadius: layer.cornerRadius,
                uvOrigin: SIMD2(Float(crop.x), Float(crop.y)), uvSize: SIMD2(Float(crop.width), Float(crop.height)),
                clampsToCrop: crop != Rect(x: 0, y: 0, width: 1, height: 1), viewport: viewport, encoder: encoder)
        }

        // 3. Cursor, its hotspot at the cursor position.
        if let layer = frame.cursor, layer.height > 0 {
            let size = SIMD2(layer.height * CursorSprite.aspect, layer.height)
            let origin = layer.hotspot - CursorSprite.hotspot * size
            var quad = QuadUniforms(
                viewport: viewport,
                origin: SIMD2<Float>(origin),
                size: SIMD2<Float>(size),
                contentOrigin: SIMD2<Float>(origin),
                contentSize: SIMD2<Float>(size),
                uvOrigin: .zero,
                uvSize: .one,
                radius: 0)
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(cursor, index: 0)
            encoder.setFragmentSamplerState(spriteSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 4. Camera, over everything.
        if let layer = frame.camera, let camera {
            let fill = Self.aspectFill(SIMD2(Double(camera.width), Double(camera.height)), in: layer.rect)
            drawImage(
                camera, in: layer.rect, cornerRadius: layer.cornerRadius, uvOrigin: fill.origin, uvSize: fill.size,
                viewport: viewport, encoder: encoder)
        }
        encoder.endEncoding()
    }

    /// Draws the part `uvOrigin`, `uvSize` of `texture` into `rect` with rounded corners (`screenFragment`), over a
    /// quad one pixel larger on every side so its antialiased edge is drawn whole; with `clampsToCrop`, nothing of
    /// `texture` outside that part shows, not even blended at the edge. Nothing for an empty rect.
    private func drawImage(
        _ texture: any MTLTexture, in rect: Rect, cornerRadius: Double, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
        clampsToCrop: Bool = false, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder
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
            clampsToCrop: clampsToCrop ? 1 : 0)
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

/// `QuadUniforms` in `ShaderSource.metal`: 64 bytes.
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
}
