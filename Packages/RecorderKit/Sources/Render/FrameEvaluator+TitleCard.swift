// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The title card a frame of the sequence shows (phase 3 design §5.2 and §12, `titleCard-1`), in the place of steps 1 to
/// 6 and under the output's annotations (base plan decision 9): nothing in the base. Milestone 3a fills it (plan 3a
/// decision 10).
public struct TitleCardLayer: Equatable, Sendable {
    public init() {}
}

/// The title cards of a document's sequence (`ClipContent.card`) as the frames draw them, worked out once for the scene
/// and again for each size (`FrameEvaluator.init` and `resized(to:)`). In the base, a frame of one is the background
/// alone, as a clip of another take is.
struct TitleCardScene: Sendable {
    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {}

    /// The frame at `offset` ns into clip `k` of the sequence, a title card (`TimeMap.contentOffset(atOutput:)`), over
    /// `background`, the frame with the background alone; `neighbor` gives the frame the output shows at an output time,
    /// before its output's annotations (the clip next to the card, which it fades against). `background` itself in the
    /// base, which asks `neighbor` nothing.
    func frame(
        clip k: Int, offset: Int64, background: RenderFrame, neighbor: (_ output: Int64) throws -> RenderFrame
    ) rethrows -> RenderFrame {
        background
    }
}
