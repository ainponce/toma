// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The camera's sync against the sound (phase 2 design §5.9, `EditDocument.camera.syncOffset`): which frame of the camera
/// a frame draws (§11, step 4, "tomada en `t − syncOffset`"), worked out once for the scene (`FrameEvaluator.init`).
///
/// With an offset of 0 it is the identity (the camera's frame of the same instant, as in phase 1, also outside what was
/// recorded); otherwise the instant is `t − syncOffset`, held to what the take's camera recorded. The screen, the cursor
/// and the sound never move: only the camera layer's source instant, which its framing, colour and mask then follow.
struct CameraSyncScene: Sendable {
    /// The largest shift the interface offers (§5.9, ±300 ms); a hand-edited document beyond it is held to it.
    static let limit: Int64 = 300_000_000

    private let offset: Int64
    /// The first and last instants the camera recorded, `nil` without a camera.
    private let recorded: (first: UInt64, last: UInt64)?

    init(document: EditDocument, take: TakeRecord) {
        offset = min(max(document.camera.syncOffset, -Self.limit), Self.limit)
        var first = UInt64.max, last = UInt64.min
        for track in take.tracks where track.kind == .camera {
            for segment in track.segments {
                first = min(first, segment.startHostTime.nanoseconds)
                last = max(last, (segment.endHostTime ?? segment.startHostTime).nanoseconds)
            }
        }
        recorded = first <= last ? (first, last) : nil
    }

    /// The source instant of the camera's frame drawn where the frame shows the camera at source instant `t`.
    func cameraTime(atSource t: HostTime) -> HostTime {
        guard offset != 0, let recorded else { return t }
        // Later picture (positive) shows an earlier frame; saturating so an instant near zero cannot wrap.
        let shifted = offset >= 0 ? t.nanoseconds.subtractingReportingOverflow(UInt64(offset)).partialValue
            : t.nanoseconds.addingReportingOverflow(UInt64(-offset)).partialValue
        let wrapped = offset >= 0 ? t.nanoseconds < UInt64(offset) : false
        return HostTime(nanoseconds: wrapped ? recorded.first : min(max(shifted, recorded.first), recorded.last))
    }
}
