// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the captions (phase 2 design §5.2), made with the compositor's (`LayerPipelines`): none in the base
/// of phase 2. Milestone 2a fills them here.
struct CaptionPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the captions `layer` in output space in an output of `outputSize`, into `pass`, counting it in
    /// `counts.captions`: step 6 of phase 2 design §11, over everything (`drawOverlays`). Nothing without one: always in
    /// the base.
    func drawCaptions(
        _ layer: CaptionLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        guard layer != nil else { return }
    }
}
