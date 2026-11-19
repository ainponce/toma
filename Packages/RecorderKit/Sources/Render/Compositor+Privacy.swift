// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the screen with its privacy regions (phase 2 design §7.1), made with the compositor's
/// (`LayerPipelines`): none in the base of phase 2. Milestone 2c fills them here.
struct PrivacyPipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// The pipeline the screen `layer` is drawn with for its privacy regions (`ScreenLayer.privacy`), in `drawStage`, step
    /// 2 of phase 2 design §11: cut to a card with `clipped`, sampled from mipmaps with `mipmapped`, into `pass`. `nil`:
    /// the screen's own pipeline of phase 1, and `bindPrivacy` is not called. Always `nil` without regions, and in the
    /// base.
    func privacyScreenPipeline(
        for layer: ScreenLayer, clipped: Bool, mipmapped: Bool, pass: LayerPass
    ) -> (any MTLRenderPipelineState)? {
        nil
    }

    /// Binds `regions` for the pipeline `privacyScreenPipeline` gave, right before the screen is drawn with it, at
    /// fragment buffers the screen's own drawing does not set (3 on): the bindings stay through `setRenderPipelineState`.
    /// Nothing in the base.
    func bindPrivacy(_ regions: [PrivacyRegion], encoder: any MTLRenderCommandEncoder) {}
}
