// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Which recorded screen a take shows (plan decision 2): the preview, the export and the camera's anchors all use
/// this one.
///
/// The candidates are the screen tracks (`TrackKind.isScreen`: displays and a window) that recorded a segment. With
/// one, it is shown, wherever it is in the take's tracks. With several, the one whose `globalFrame` holds the take's
/// first pointer position (the first `cursor`, `mouseDown` or `mouseUp` event in time order), or the first candidate
/// when none holds it or there is no such event. Without candidates, the first screen track, as in phase 0: its
/// timeline is empty.
public enum ScreenChoice {
    public static func screenTrack(in take: TakeRecord, events: [InputEvent]) -> TrackRecord? {
        let screens = take.tracks.filter(\.kind.isScreen)
        let candidates = screens.filter { !$0.segments.isEmpty }
        guard candidates.count > 1 else { return candidates.first ?? screens.first }
        guard let pointer = firstPointerPosition(in: events) else { return candidates[0] }
        let point = CGPoint(x: pointer.x, y: pointer.y)
        return candidates.first { $0.source.globalFrame.map { CursorGeometry.contains(point, $0) } ?? false } ?? candidates[0]
    }

    /// Whether `screenTrack(in:events:)` looks at the events for `take`: only when two or more of its screen tracks
    /// recorded a segment. Otherwise the events change nothing of the choice.
    public static func dependsOnEvents(_ take: TakeRecord) -> Bool {
        take.tracks.filter { $0.kind.isScreen && !$0.segments.isEmpty }.count > 1
    }

    /// The position of the earliest pointer event, the first of those with the same `t` in the order given (the
    /// first that `sortedByTime()` would give), without sorting them all.
    private static func firstPointerPosition(in events: [InputEvent]) -> SIMD2<Double>? {
        var first: (t: HostTime, point: SIMD2<Double>)?
        for event in events {
            guard let point = event.kind.pointerPosition else { continue }
            if first.map({ event.t < $0.t }) ?? true { first = (event.t, point) }
        }
        return first?.point
    }
}

extension InputEvent.Kind {
    /// Where the pointer is, in global points, for `cursor`, `mouseDown` and `mouseUp`; `nil` for the others.
    public var pointerPosition: SIMD2<Double>? {
        switch self {
        case let .cursor(x, y), let .mouseDown(_, x, y), let .mouseUp(_, x, y):
            SIMD2(x, y)
        default:
            nil
        }
    }
}
