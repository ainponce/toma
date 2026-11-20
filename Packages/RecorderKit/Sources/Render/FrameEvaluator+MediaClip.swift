// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The imported clip a frame of the sequence shows (phase 3 design §5.4 and §12, step 2), drawn where the screens are:
/// nothing in the base. Milestone 3a fills it (plan 3a decision 12).
public struct MediaClipLayer: Equatable, Sendable {
    public init() {}
}

/// The imported clips of a document's sequence (`ClipContent.media`) as the frames draw them, worked out once for the
/// scene and again for each size (`FrameEvaluator.init` and `resized(to:)`). In the base, a frame of one is the
/// background alone, as a clip of another take is.
struct MediaClipScene: Sendable {
    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {}

    /// The frame at `offset` ns into clip `k` of the sequence, an imported clip (`TimeMap.contentOffset(atOutput:)`), over
    /// `background`, the frame with the background alone: `background` itself in the base.
    func frame(clip k: Int, offset: Int64, background: RenderFrame) -> RenderFrame {
        background
    }
}
