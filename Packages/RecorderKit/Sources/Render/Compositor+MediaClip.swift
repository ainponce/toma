// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of an imported clip of the sequence (phase 3 design §5.4 and §12, step 2), made with the compositor's
/// (`LayerPipelines`): none in the base. Milestone 3a fills them here.
struct MediaClipPipelines {
    init(maker: PipelineMaker) throws {}
}

/// What a frame's imported clip is drawn with: the frame of its file the renderer decoded for it
/// (`FrameRenderer.mediaTextures(for:decoded:commandBuffer:)`). `nil` draws none; nothing in the base. It must stay alive
/// until the command buffer it is drawn in completes.
struct MediaClipTextures {}

extension Compositor {
    /// Draws the imported clip `layer` with `textures`, where the screens are (step 2 of phase 3 design §12, after them and
    /// before the cursor, `drawStage`): through `stage`, or the card's content `card` in a card's mode, in an output of
    /// `outputSize`, into `pass`, counting each drawn in `counts.mediaClips`. Nothing without a layer, and in the base.
    func drawMediaClip(
        _ layer: MediaClipLayer?, through stage: StageTransform?, card: CardContent?, textures: MediaClipTextures?,
        outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {}
}
