// SPDX-License-Identifier: GPL-3.0-or-later
import Metal

/// The pipelines of the transparent background (milestone 4c, design §7.1: `BackgroundLayer.transparent`), made last with
/// the compositor's (`LayerPipelines.alpha`) and used only by a transparent frame, so an opaque one draws with the same
/// pipelines, in the same order, as ever:
///
/// - `clear(for:)`: the background's step, (0,0,0,0) over the whole target without blending (the core's
///   `transparentFragment`), in the pass of the stage (straight into the target, into a subsample of the motion blur's):
///   so every subsample, which loads nothing, starts from nothing where the stage does not cover it, and a card's
///   `.frame` drawn once over the last content leaves nothing of it.
/// - `highlight(for:)`: Highlight that darkens what is drawn and not the void, in each pass of what goes over the stage
///   (`calmHighlightAlphaFragment`, `calmHighlightAlphaTargetFragment`, which read the target and blend in the shader).
/// - `dim`: Dim's veil from the blurred copy with its own alpha (`calmDimAlphaFragment`), blended "over".
/// - `lens`: the loupe's lens magnifying what is under it with its alpha, its shadow and its ring as they are drawn
///   (`loupeAlphaFragment`, which reads the target and blends in the shader), into the target alone.
struct AlphaPipelines {
    private let clearTarget: any MTLRenderPipelineState
    private let clearSubsample: any MTLRenderPipelineState
    private let highlightTarget: any MTLRenderPipelineState
    private let highlightBlurTarget: any MTLRenderPipelineState
    let dim: any MTLRenderPipelineState
    let lens: any MTLRenderPipelineState

    init(maker: PipelineMaker) throws {
        clearTarget = try maker.pipeline(
            vertex: "gradientVertex", fragment: "transparentFragment", blending: .none, into: LayerPass.target.attachments)
        clearSubsample = try maker.pipeline(
            vertex: "gradientVertex", fragment: "transparentFragment", blending: .none, into: LayerPass.subsample.attachments)
        highlightTarget = try maker.pipeline(
            vertex: "quadVertex", fragment: "calmHighlightAlphaFragment", blending: .none, into: LayerPass.target.attachments)
        highlightBlurTarget = try maker.pipeline(
            vertex: "quadVertex", fragment: "calmHighlightAlphaTargetFragment", blending: .none,
            into: LayerPass.blurTarget.attachments)
        dim = try maker.pipeline(vertex: "quadVertex", fragment: "calmDimAlphaFragment", blending: .over, into: .target)
        lens = try maker.pipeline(vertex: "quadVertex", fragment: "loupeAlphaFragment", blending: .none, into: .target)
    }

    /// The background's step of a transparent frame in `pass`, a pass of the stage.
    func clear(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: clearTarget
        case .subsample: clearSubsample
        case .blurTarget: preconditionFailure("The background is drawn with the stage, never over the motion blur's average")
        }
    }

    /// Highlight's pipeline of a transparent frame in `pass`, over the stage.
    func highlight(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: highlightTarget
        case .blurTarget: highlightBlurTarget
        case .subsample: preconditionFailure("The calm zoom is drawn over the stage, never into a subsample of it")
        }
    }
}
