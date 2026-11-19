// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the camera's colour, background and mask (phase 2 design §6.1 and §6.3), made with the compositor's
/// (`LayerPipelines`): none in the base of phase 2. Milestone 2b fills them here. The framing's crop
/// (`CameraLayer.crop`) needs none: `drawCamera` fills the rect with it.
struct CameraLookPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// The pipeline the camera `layer` is drawn with for its colour and background (`CameraLayer.look`, `background`), in
    /// `drawCamera`, step 4 of phase 2 design §11: with its border with `bordered`, into `pass`. `nil`: the camera's own
    /// pipeline of phase 1, and `bindCameraLook` is not called. Always `nil` without them, and in the base.
    func cameraLookPipeline(for layer: CameraLayer, bordered: Bool, pass: LayerPass) -> (any MTLRenderPipelineState)? {
        nil
    }

    /// Binds what `layer`'s look needs for the pipeline `cameraLookPipeline` gave, right before the camera is drawn with
    /// it, at fragment buffers and textures the camera's own drawing does not set (buffers 3 on, textures 1 on): the
    /// bindings stay through `setRenderPipelineState`. Nothing in the base.
    func bindCameraLook(_ layer: CameraLayer, encoder: any MTLRenderCommandEncoder) {}
}
