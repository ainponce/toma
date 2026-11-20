// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the calm zoom (phase 3 design §6 and §12, step 4: highlight, dim and the loupe), made with the
/// compositor's (`LayerPipelines`): none in the base. Milestone 3b fills them here.
struct CalmZoomPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the calm zoom `layer` of `frame` over the stage drawn (step 4 of phase 3 design §12, after the click effects
    /// and before the annotations stuck to the recording and the camera, `drawOverTheStage`): through `stage`, or the
    /// card's content `card` in a card's mode, into `pass`, counting each drawn in `counts.calmZooms`. Highlight draws in
    /// the same pass; dim and the loupe, which read what is drawn of the stage, end `encoder`'s pass, sample its target
    /// through a texture of their own made from `commandBuffer`, and open one pass into `target` alone, which they leave in
    /// `encoder`. Returns whether they did: what follows is drawn into that pass (`Compositor.directCamera`, `.target`).
    /// Nothing without a layer, and in the base: `false`. Throws `RenderError.metalResourceUnavailable` when Metal cannot
    /// make a texture it needs, leaving in `encoder` a pass still open (the one given, or the one it opened), which the
    /// caller ends: the frame is never drawn some other way.
    func drawCalmZoom(
        _ layer: CalmZoomLayer?, frame: RenderFrame, through stage: StageTransform?, card: CardContent?, pass: LayerPass,
        encoder: inout any MTLRenderCommandEncoder, target: any MTLTexture, commandBuffer: any MTLCommandBuffer,
        counts: inout DrawCounts
    ) throws -> Bool {
        false
    }
}
