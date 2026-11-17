// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The camera's bubble of a take, where the render draws it and the zoom keeps the cursor out from under it: one rule
/// for both (`FrameEvaluator`, `ZoomCameraPath`).
///
/// The camera is the take's first camera track with a segment, shown from the start of its first segment on, at the
/// `CameraStyleTimeline` of the document's `camera.initial` for the take and its `camera.changes` in output time
/// (`TimeMap.output(ofChangeAt:take:)`): a change in a cut rules from the first instant kept after it, one before the
/// first clip keeps its time through that clip's mapping (it is under way at output 0, as it always was), and one after
/// the last never rules. There is none while the document hides the camera (`camera.show`).
public struct CameraBubble: Sendable {
    /// The camera track drawn.
    public let trackID: String
    /// The start of its first segment: no bubble before it.
    public let start: HostTime
    private let timeline: CameraStyleTimeline

    /// `nil` when the document hides the camera, and when the take has no camera track with a segment.
    public init?(document: EditDocument, take: TakeRecord, timeMap: TimeMap) {
        guard document.camera.show, let camera = take.tracks.first(where: { $0.kind == .camera && !$0.segments.isEmpty }),
              let start = camera.segments.map(\.startHostTime).min()
        else { return nil }
        trackID = camera.id
        self.start = start
        timeline = CameraStyleTimeline(
            initial: document.camera.initial[take.id] ?? .default,
            changes: document.camera.changes.filter { $0.take == take.id }.compactMap { change in
                timeMap.output(ofChangeAt: change.t, take: take.id).map { ($0, change.style) }
            })
    }

    /// The bubble at output time `τ`, showing source instant `host`, in an output `output` big (pixels, or stage units),
    /// measured against `reference` (the document's `camera.sizeReference`; the output's height, as in 1b, by default):
    /// `nil` before `start`.
    public func frame(atOutput τ: Int64, host: HostTime, output: SIMD2<Double>, reference: SizeReference = .height) -> CameraFrame? {
        guard host >= start else { return nil }
        return timeline.frame(atOutput: τ, output: output, reference: reference)
    }
}
