// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The calm zoom of a frame (phase 3 design §6 and §12, step 4, `calmZoom-1` and `loupe-1`): highlight, dim or the loupe,
/// over the stage drawn and under the annotations stuck to the recording. Nothing in the base; milestone 3b fills it.
public struct CalmZoomLayer: Equatable, Sendable {
    public init() {}
}

/// The calm zoom's blocks of a document (`ZoomMode` other than `classic`) as the frames draw them, worked out once for the
/// scene from its motion paths (`FrameEvaluator.init`): it depends on no size. `nil` everywhere in the base.
struct CalmZoomScene: Sendable {
    init(document: EditDocument, take: TakeRecord, timeMap: TimeMap, paths: MotionPaths) {}

    /// The calm zoom of `frame`, a frame of the take at output time `output` as either path left it (`finishLayers`):
    /// `nil` without a calm block there, and always in the base.
    func layer(atOutput output: Int64, frame: RenderFrame) -> CalmZoomLayer? {
        nil
    }
}
