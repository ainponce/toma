// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat

/// The pipelines of the camera's colour, background and mask (phase 2 design §6.1 and §6.3), made with the compositor's
/// (`LayerPipelines`): the camera's shader with its look (`cameraLookFragment`), with its border and without it, straight
/// into the target and into the motion blur's target, the two passes the camera is drawn in. And what a look binds where
/// it has nothing of its own (a texture of one texel, 3D for no LUT and 2D for no mask or no blurred copy), so every
/// texture the shader declares is bound.
struct CameraLookPipelines {
    private let direct: any MTLRenderPipelineState
    private let directBordered: any MTLRenderPipelineState
    private let blurTarget: any MTLRenderPipelineState
    private let blurTargetBordered: any MTLRenderPipelineState
    /// Bound at the LUT's texture without a LUT, never read (the intensity is 0).
    let noLUT: any MTLTexture
    /// Bound at the mask's and the blurred copy's textures without them, never read (the background's mode says so).
    let noImage: any MTLTexture

    init(maker: PipelineMaker) throws {
        precondition(
            MemoryLayout<CameraLookUniforms>.stride == 64, "CameraLookUniforms must keep the layout of the shaders' struct: 64 bytes")
        func make(_ fragment: String, _ pass: LayerPass) throws -> any MTLRenderPipelineState {
            try maker.pipeline(vertex: "quadVertex", fragment: fragment, blending: .over, into: pass.attachments)
        }
        direct = try make("cameraLookFragment", .target)
        directBordered = try make("borderedCameraLookFragment", .target)
        blurTarget = try make("cameraLookTargetFragment", .blurTarget)
        blurTargetBordered = try make("borderedCameraLookTargetFragment", .blurTarget)
        func texel(_ type: MTLTextureType, _ format: MTLPixelFormat) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = type
            descriptor.pixelFormat = format
            (descriptor.width, descriptor.height, descriptor.depth) = (1, 1, 1)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = maker.device.makeTexture(descriptor: descriptor) else {
                throw RenderError.metalResourceUnavailable("a texel for the camera's look")
            }
            var bytes = [UInt8](repeating: 0, count: 8)
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &bytes, bytesPerRow: 8,
                bytesPerImage: type == .type3D ? 8 : 0)
            return texture
        }
        noLUT = try texel(.type3D, .rgba16Float)
        noImage = try texel(.type2D, Compositor.pixelFormat)
    }

    /// The camera's pipeline with its look in `pass`, with its border with `bordered`.
    func pipeline(for pass: LayerPass, bordered: Bool) -> any MTLRenderPipelineState {
        switch pass {
        case .target: bordered ? directBordered : direct
        case .blurTarget: bordered ? blurTargetBordered : blurTarget
        case .subsample: preconditionFailure("The camera is drawn over the stage, never into a subsample of it")
        }
    }
}

/// The uniforms of the camera's look (`CameraLookUniforms` of `ShaderSource.cameraLookMetal`, 64 bytes).
struct CameraLookUniforms {
    /// A colour's texture coordinates in the LUT: `colour × scale + offset`, per channel (`w` unused).
    var lutScale: SIMD4<Float>
    var lutOffset: SIMD4<Float>
    /// A texel of the blur's level of the camera's mipmaps, in texture coordinates of its frame.
    var blurTexel: SIMD2<Float>
    /// 0 to 1; 0 draws no LUT.
    var intensity: Float
    /// 0 the original background, 1 blurred, 2 removed.
    var mode: Float
    /// The mask's `smoothstep` (phase 2 design §6.1).
    var maskLow: Float = CameraLookUniforms.maskLow
    var maskHigh: Float = CameraLookUniforms.maskHigh
    var blurLevel: Float
    var padding: Float = 0

    /// What a mask's value is read as person from, and all person from (phase 2 design §6.1, `personMask-1`).
    static let maskLow: Float = 0.35
    static let maskHigh: Float = 0.65
    /// The short side of a frame, in texels of the level the blurred background is read at (plan 2b decision 5).
    static let blurTexels = 36.0

    /// For a LUT of `size` points a side over `domain`: the coordinates `uvw = (c − min) / (max − min) × (N − 1) / N + 0.5 / N`
    /// (plan 2b decision 7, with the `.cube`'s `DOMAIN_MIN` and `DOMAIN_MAX`), as a scale and an offset.
    static func lutMapping(size: Int, domainMin: SIMD3<Float>, domainMax: SIMD3<Float>) -> (scale: SIMD4<Float>, offset: SIMD4<Float>) {
        let n = Float(max(size, 2))
        let scale = (n - 1) / n / (domainMax - domainMin)
        let offset = SIMD3<Float>(repeating: 0.5 / n) - domainMin * scale
        return (SIMD4(scale, 0), SIMD4(offset, 0))
    }

    /// The level of the mipmaps of a camera's frame `width` × `height` the blurred background is read at:
    /// `max(0, log2(short side / 36))`, and a texel of it in the frame's texture coordinates.
    static func blur(width: Int, height: Int) -> (level: Float, texel: SIMD2<Float>) {
        let short = Double(max(min(width, height), 1))
        let level = max(0, log2(short / blurTexels))
        let texel = exp2(level)
        return (Float(level), SIMD2(Float(texel / Double(max(width, 1))), Float(texel / Double(max(height, 1)))))
    }
}

/// What a frame's camera is drawn with for its colour and background (`CameraLayer.look`, `background`), besides its
/// picture: the 3D LUT of its look, the person's mask decoded for the camera's frame and, once `prepareCameraLook` made
/// it, the copy with mipmaps of that frame that a blurred background reads. Only the renderer makes them
/// (`CameraLookResources`); `nil`, or none of them, draws the camera as in phase 1. They must stay alive until the command
/// buffer they are drawn in completes.
public struct CameraLookTextures {
    var lut: (any MTLTexture)?
    var mask: (any MTLTexture)?
    var blurred: (any MTLTexture)?
    /// The input that maps to the LUT's first point and to its last one, per channel (a `.cube`'s `DOMAIN_MIN` and
    /// `DOMAIN_MAX`; 0 and 1 for the looks made in code).
    var lutDomain = (min: SIMD3<Float>(repeating: 0), max: SIMD3<Float>(repeating: 1))
}

extension Compositor {
    /// What `frame`'s camera is drawn with, `textures` and what is made of the camera's frame `camera` for them, encoded
    /// into `commandBuffer` before any render pass, as the screen's copies with mipmaps are (`cameraCopies`): for a blurred
    /// background with its mask, the copy with mipmaps of the whole frame it reads (`blurred`, plan 2b decision 5). Throws
    /// `RenderError.metalResourceUnavailable`, having encoded nothing, when Metal cannot make what it makes.
    func prepareCameraLook(
        _ frame: RenderFrame, camera: (any MTLTexture)?, textures: CameraLookTextures?, commandBuffer: any MTLCommandBuffer
    ) throws -> CameraLookTextures? {
        guard var textures, let camera, frame.camera?.background?.mode == .blurred, textures.mask != nil else { return textures }
        textures.blurred = try cameraCopies.copy(
            of: camera, region: MTLRegionMake2D(0, 0, camera.width, camera.height), commandBuffer: commandBuffer)
        return textures
    }

    /// The part of the camera's picture `texture` that fills `layer`'s rect without stretching, as fractions of it, before
    /// the mirror: with a framing (`CameraLookLayer.framing`), its crop of the frame (`CameraFramingGeometry.crop`, plan 2b
    /// decision 2); without one, the centred fill of the whole picture, as in phase 1 (`aspectFill`).
    func cameraFill(_ layer: CameraLayer, texture: any MTLTexture) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let size = SIMD2(Double(texture.width), Double(texture.height))
        guard let framing = layer.look?.framing else { return Self.aspectFill(size, in: layer.rect) }
        let crop = CameraFramingGeometry.crop(
            frameSize: size, rectAspect: layer.rect.width / layer.rect.height, center: framing.center, zoom: framing.zoom)
        return (SIMD2(Float(crop.x), Float(crop.y)), SIMD2(Float(crop.width), Float(crop.height)))
    }

    /// The pipeline the camera `layer` is drawn with for its colour and background (`CameraLayer.look`, `background`) and
    /// what `textures` hold for them (a background without its mask is the original), in `drawCamera`, step 4 of phase 2
    /// design §11: with its border with `bordered`, into `pass`. `nil`, the camera's own pipeline of phase 1 (and
    /// `bindCameraLook` is not called), without a LUT drawn (none, or an intensity not above 0) and without a background
    /// with its mask: a framing alone is the camera's own drawing of another part of the picture.
    func cameraLookPipeline(
        for layer: CameraLayer, textures: CameraLookTextures?, bordered: Bool, pass: LayerPass
    ) -> (any MTLRenderPipelineState)? {
        guard Self.drawsLUT(layer, textures) || Self.drawsBackground(layer, textures) else { return nil }
        return layers.cameraLook.pipeline(for: pass, bordered: bordered)
    }

    /// Binds what `layer`'s look needs of `textures` (`prepareCameraLook`'s) for the pipeline `cameraLookPipeline` gave,
    /// right before the camera is drawn with it, at fragment buffers and textures the camera's own drawing does not set
    /// (buffers 3 on, textures 1 on): the bindings stay through `setRenderPipelineState`. The LUT's mapping and intensity,
    /// the background's mode, the mask's smoothstep and the blur's level (of the blurred copy's frame), with the LUT's
    /// sampler and the trilinear one.
    func bindCameraLook(_ layer: CameraLayer, textures: CameraLookTextures?, encoder: any MTLRenderCommandEncoder) {
        let lut = Self.drawsLUT(layer, textures) ? textures?.lut : nil
        let mode: Float
        switch Self.drawsBackground(layer, textures) ? layer.background?.mode : nil {
        case .blurred? where textures?.blurred != nil: mode = 1
        case .removed?: mode = 2
        default: mode = 0
        }
        let domain = textures?.lutDomain ?? (.zero, .one)
        let mapping = lut.map { CameraLookUniforms.lutMapping(size: $0.width, domainMin: domain.min, domainMax: domain.max) } ?? (.zero, .zero)
        let blurred = textures?.blurred
        let blur = blurred.map { CameraLookUniforms.blur(width: $0.width, height: $0.height) } ?? (0, .zero)
        var uniforms = CameraLookUniforms(
            lutScale: mapping.scale, lutOffset: mapping.offset, blurTexel: blur.texel,
            intensity: lut == nil ? 0 : min(max(layer.look?.intensity ?? 0, 0), 1), mode: mode, blurLevel: blur.level)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CameraLookUniforms>.stride, index: 3)
        encoder.setFragmentTexture(lut ?? layers.cameraLook.noLUT, index: 1)
        encoder.setFragmentSamplerState(lutSampler, index: 1)
        // What the shader declares and this frame has none of (the mask, the blurred copy) is a texel, never read.
        encoder.setFragmentTexture((mode == 0 ? nil : textures?.mask) ?? layers.cameraLook.noImage, index: 2)
        encoder.setFragmentTexture((mode == 1 ? blurred : nil) ?? layers.cameraLook.noImage, index: 3)
        encoder.setFragmentSamplerState(trilinearSampler, index: 2)
    }

    /// Whether `layer` draws its look's LUT with `textures`: one asked for, at an intensity above 0, and there.
    private static func drawsLUT(_ layer: CameraLayer, _ textures: CameraLookTextures?) -> Bool {
        guard let look = layer.look, look.lut != nil, look.intensity > 0, textures?.lut != nil else { return false }
        return true
    }

    /// Whether `layer` draws its background with `textures`: blurred or removed, with its mask decoded.
    private static func drawsBackground(_ layer: CameraLayer, _ textures: CameraLookTextures?) -> Bool {
        layer.background != nil && textures?.mask != nil
    }
}
