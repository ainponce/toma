// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the annotations (phase 3 design §5.1 and §12, steps 5 and 7, `annotation-1`), made with the
/// compositor's (`LayerPipelines`): none in the base. Milestone 3a fills them here.
struct AnnotationPipelines {
    init(maker: PipelineMaker) throws {}
}

/// What a frame's annotations are drawn with besides their own textures: the images and the frames of the clips the
/// renderer decoded for them (`FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`). `nil` draws none of those;
/// nothing in the base. They must stay alive until the command buffer they are drawn in completes.
struct AnnotationTextures {}

extension Compositor {
    /// Draws the annotations stuck to the recording `layers`, in their order, with `textures` (step 5 of phase 3 design §12,
    /// after the calm zoom and before the camera, `drawOverTheStage`): in the stage, through `stage`, or the card's content
    /// `card` and cut to it in a card's mode, in an output of `outputSize`, into `pass`, counting each drawn in
    /// `counts.contentAnnotations`. Nothing without them, and in the base.
    func drawContentAnnotations(
        _ layers: [AnnotationLayer], through stage: StageTransform?, card: CardContent?, textures: AnnotationTextures?,
        outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {}

    /// Draws the output's annotations `layers`, in their order, with `textures` (step 7 of phase 3 design §12, over the
    /// camera and a title card and under the keys, `drawOverlays`): in output space in an output of `outputSize`, into
    /// `pass`, counting each drawn in `counts.outputAnnotations`. Nothing without them, and in the base.
    func drawOutputAnnotations(
        _ layers: [AnnotationLayer], textures: AnnotationTextures?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {}
}
