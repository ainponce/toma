// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of a title card (phase 3 design §5.2 and §12, `titleCard-1`), made with the compositor's
/// (`LayerPipelines`): none in the base. Milestone 3a fills them here.
struct TitleCardPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the title card `layer` in output space in an output of `outputSize`, into `pass`, counting it in
    /// `counts.titleCards`: first in `drawOverlays`, over what its frame drew in the place of steps 1 to 6 of phase 3
    /// design §12 and under the output's annotations (base plan decision 9). Nothing without one, and in the base.
    func drawTitleCard(
        _ layer: TitleCardLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {}
}
