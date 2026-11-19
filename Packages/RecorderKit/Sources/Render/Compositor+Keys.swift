// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the keys on screen (phase 2 design §7.4), made with the compositor's (`LayerPipelines`): none in the
/// base of phase 2. Milestone 2c fills them here.
struct KeyPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the keys `layer` in output space in an output of `outputSize`, into `pass`, counting it in
    /// `counts.keyOverlays`: step 5 of phase 2 design §11, over the camera (`drawOverlays`). Nothing without one: always
    /// in the base.
    func drawKeys(
        _ layer: KeyOverlayLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        guard layer != nil else { return }
    }
}
