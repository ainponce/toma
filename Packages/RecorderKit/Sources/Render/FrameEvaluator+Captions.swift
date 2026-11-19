// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The captions shown in a frame (phase 2 design §5.2), drawn over everything (§11, step 6). Empty in the base: milestone
/// 2a gives it what it draws.
public struct CaptionLayer: Equatable, Sendable {
    public init() {}
}

/// The captions of a document (`EditDocument.captions` over its `transcript`) as the frames draw them, worked out once for
/// the scene and again for each size (`FrameEvaluator.init` and `resized(to:)`).
///
/// The base of phase 2 leaves it empty: no layer at any time, so a document without captions draws as in phase 1.
/// Milestone 2a fills it here.
struct CaptionScene: Sendable {
    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {}

    /// The captions at output time `output` (nanoseconds); `nil` when none is shown, always in the base.
    func layer(atOutput output: Int64) -> CaptionLayer? {
        nil
    }
}
