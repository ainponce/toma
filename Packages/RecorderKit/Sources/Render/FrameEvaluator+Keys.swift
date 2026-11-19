// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The keys shown in a frame (phase 2 design §7.4), drawn over the camera and under the captions (§11, step 5). Empty in
/// the base: milestone 2c gives it what it draws.
public struct KeyOverlayLayer: Equatable, Sendable {
    public init() {}
}

/// The keys on screen of a document (`EditDocument.keys` over the take's `keyPress` events) as the frames draw them,
/// worked out once for the scene and again for each size (`FrameEvaluator.init` and `resized(to:)`).
///
/// The base of phase 2 leaves it empty: no layer at any time, so a document with the keys off draws as in phase 1.
/// Milestone 2c fills it here.
struct KeyOverlayScene: Sendable {
    init(document: EditDocument, events: [InputEvent], timeMap: TimeMap, outputSize: SIMD2<Int>) {}

    /// The keys at output time `output` (nanoseconds); `nil` when none is shown, always in the base.
    func layer(atOutput output: Int64) -> KeyOverlayLayer? {
        nil
    }
}
