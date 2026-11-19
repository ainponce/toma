// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the camera's colour, background and mask (phase 2 design §6.1 and §6.3), made with the compositor's
/// (`LayerPipelines`): none in milestone 2b's seam. Task I10 fills them here.
struct CameraLookPipelines {
    init(maker: PipelineMaker) throws {}
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
}

extension Compositor {
    /// What `frame`'s camera is drawn with, `textures` and what is made of the camera's frame `camera` for them, encoded
    /// into `commandBuffer` before any render pass, as the screen's copies with mipmaps are (`cameraCopies`). In the seam,
    /// `textures` as they are, and nothing encoded. Throws `RenderError.metalResourceUnavailable`, having encoded nothing,
    /// when Metal cannot make what it makes.
    func prepareCameraLook(
        _ frame: RenderFrame, camera: (any MTLTexture)?, textures: CameraLookTextures?, commandBuffer: any MTLCommandBuffer
    ) throws -> CameraLookTextures? {
        textures
    }

    /// The part of the camera's picture `texture` that fills `layer`'s rect without stretching, as fractions of it, before
    /// the mirror: with a framing (`CameraLookLayer.framing`), its crop of the frame (plan 2b decision 2); without one, the
    /// centred fill of the whole picture, as in phase 1 (`aspectFill`), always in the seam.
    func cameraFill(_ layer: CameraLayer, texture: any MTLTexture) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        Self.aspectFill(SIMD2(Double(texture.width), Double(texture.height)), in: layer.rect)
    }

    /// The pipeline the camera `layer` is drawn with for its colour and background (`CameraLayer.look`, `background`) and
    /// what `textures` hold for them (a background without its mask is the original), in `drawCamera`, step 4 of phase 2
    /// design §11: with its border with `bordered`, into `pass`. `nil`: the camera's own pipeline of phase 1, and
    /// `bindCameraLook` is not called. Always `nil` without them, and in the seam.
    func cameraLookPipeline(
        for layer: CameraLayer, textures: CameraLookTextures?, bordered: Bool, pass: LayerPass
    ) -> (any MTLRenderPipelineState)? {
        nil
    }

    /// Binds what `layer`'s look needs of `textures` (`prepareCameraLook`'s) for the pipeline `cameraLookPipeline` gave,
    /// right before the camera is drawn with it, at fragment buffers and textures the camera's own drawing does not set
    /// (buffers 3 on, textures 1 on): the bindings stay through `setRenderPipelineState`. Nothing in the seam.
    func bindCameraLook(_ layer: CameraLayer, textures: CameraLookTextures?, encoder: any MTLRenderCommandEncoder) {}
}
