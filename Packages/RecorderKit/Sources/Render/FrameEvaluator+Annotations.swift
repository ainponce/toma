// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// An annotation as a frame draws it (phase 3 design §5.1 and §12, `annotation-1`): stuck to the recording (step 5, in the
/// stage, under the camera) or of the output (step 7, over the camera and under the keys). Nothing in the base; milestone
/// 3a fills it (plan 3a decisions 2 to 9).
public struct AnnotationLayer: Equatable, Sendable {
    public init() {}
}

/// The annotations of a document (`EditDocument.annotations`) as the frames of its take `take` draw them, with the take's
/// `events` (what the screen shown holds, as `PrivacyScene` reads it), worked out once for the scene and again for each
/// size (`FrameEvaluator.init` and `resized(to:)`). None in the base.
struct AnnotationScene: Sendable {
    init(document: EditDocument, take: TakeRecord, events: [InputEvent], timeMap: TimeMap, outputSize: SIMD2<Int>) {}

    /// The annotations stuck to the recording that `frame` shows, a frame of the take at output time `output` showing
    /// source instant `t` as either path left it (`finishLayers`), in their layers' order: none in the base.
    func content(atSource t: HostTime, output: Int64, frame: RenderFrame) -> [AnnotationLayer] {
        []
    }

    /// The annotations of the output and of the whole video shown at output time `output`, in their layers' order, over
    /// whatever the clip there shows: none in the base.
    func output(atOutput output: Int64) -> [AnnotationLayer] {
        []
    }
}
