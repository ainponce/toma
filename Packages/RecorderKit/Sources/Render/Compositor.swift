// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat

/// Draws a `RenderFrame` into a `.bgra8Unorm` target: the gradient, the screen and the cursor, in one
/// render pass that starts by clearing the target, blended premultiplied "over".
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
    /// `frame.screen` is set and `screen` is given; the cursor only when `frame.cursor` is set. `screen` and
    /// `cursor` must stay alive until `commandBuffer` completes.
    public func encode(
        _ frame: RenderFrame,
        screen: (any MTLTexture)?,
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

        // 2. Screen, over a quad one pixel larger on every side so its antialiased edge is drawn whole.
        if let layer = frame.screen, let screen, layer.rect.width > 0, layer.rect.height > 0 {
            let rect = layer.rect
            var quad = QuadUniforms(
                viewport: viewport,
                origin: SIMD2(Float(rect.x - 1), Float(rect.y - 1)),
                size: SIMD2(Float(rect.width + 2), Float(rect.height + 2)),
                contentOrigin: SIMD2(Float(rect.x), Float(rect.y)),
                contentSize: SIMD2(Float(rect.width), Float(rect.height)),
                radius: Float(max(layer.cornerRadius, 0)))
            encoder.setRenderPipelineState(screenPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(screen, index: 0)
            encoder.setFragmentSamplerState(screenSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
                radius: 0)
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(cursor, index: 0)
            encoder.setFragmentSamplerState(spriteSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }
}

/// `GradientUniforms` in `ShaderSource.metal`.
private struct GradientUniforms {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var direction: SIMD2<Float>
    var padding: SIMD2<Float>
}

/// `QuadUniforms` in `ShaderSource.metal`.
private struct QuadUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var contentOrigin: SIMD2<Float>
    var contentSize: SIMD2<Float>
    var radius: Float
    var padding: Float = 0
}
