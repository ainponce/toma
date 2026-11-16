// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Editing
import ProjectFormat

/// An item of the timeline that can be pointed at: a clip, a screen's stretch, a zoom block or a camera change (an empty
/// `output`, an instant) with the track it is on and where it is in output time (nanoseconds).
public struct TimelineItem: Equatable, Sendable {
    public var id: String
    public var track: TimelineTrack
    public var output: Range<Int64>

    public init(id: String, track: TimelineTrack, output: Range<Int64>) {
        self.id = id
        self.track = track
        self.output = output
    }
}

/// What is under the mouse in the timeline (design §5.5).
public enum TimelineHit: Equatable, Sendable {
    /// Nothing, on `track`, at output time `output` (nanoseconds; not clamped to the output).
    case empty(TimelineTrack, output: Int64)
    /// The body of an item.
    case item(TimelineTrack, id: String)
    /// The part of an item within `TimelineHitTest.edgeZone` of one of its edges.
    case edge(TimelineTrack, id: String, ClipEdge)
    /// The ruler: a click or a drag there moves the playhead.
    case playhead
}

/// Which item the mouse is on, how a click changes the selection and how far an edge snaps (design §5.5): pure, so the
/// view only passes it the mouse.
public enum TimelineHitTest {
    /// How near an edge of an item the mouse is on the edge, in points: it turns into `resizeLeftRight` and dragging trims.
    public static let edgeZone = 6.0
    /// How near the playhead, an edge, a diamond, a marker or the start or end an edge snaps, in points.
    public static let snapDistance = 8.0

    /// What is at `point`, in the timeline's own coordinates: `x` from its left edge, with the headers in it, and `y` from
    /// its top, the ruler first. The rows' vertical scroll is added to `y` by the caller below the ruler (`y` of a point on a
    /// row scrolled up 10 pt is 10 more), and `scale` and `offset` are the timeline's (`TimelineLayout`).
    ///
    /// - The ruler is `.playhead`.
    /// - On a row, an item whose range is under the point is `.item`, or `.edge` within `edgeZone` of either of its edges
    ///   (a third of its width at most, so a narrow block can still be grabbed by its body). Items side by side, as the
    ///   sequence's clips are, share the point between them: it belongs to the one it starts. A camera change, an
    ///   instant, is an item within `edgeZone` of its time and has no edges.
    /// - Anywhere else, `.empty` with the row's track (the last one, below them) and the time of the point.
    public static func hit(at point: CGPoint, items: [TimelineItem], layout: TimelineLayout, scale: Double, offset: Double) -> TimelineHit {
        guard point.y >= TimelineLayout.rulerHeight else { return .playhead }
        var top = TimelineLayout.rulerHeight
        var track = layout.tracks.last { $0.track != .ruler }?.track ?? .video
        for row in layout.tracks where row.track != .ruler {
            if point.y < top + row.height {
                track = row.track
                break
            }
            top += row.height
        }
        func x(_ τ: Int64) -> Double { layout.x(ofOutput: τ, scale: scale, offset: offset) }
        let output = layout.output(atX: point.x, scale: scale, offset: offset)
        var found: (item: TimelineItem, left: Double, right: Double)?
        for item in items where item.track == track {
            let (left, right) = item.output.isEmpty
                ? (x(item.output.lowerBound) - edgeZone, x(item.output.lowerBound) + edgeZone)
                : (x(item.output.lowerBound), x(item.output.upperBound))
            guard point.x >= left, point.x <= right else { continue }
            // At a shared point, the item that starts there, which is the later one.
            if let current = found, current.right > point.x, right <= point.x { continue }
            found = (item, left, right)
        }
        guard let (item, left, right) = found else { return .empty(track, output: output) }
        guard !item.output.isEmpty else { return .item(track, id: item.id) }
        let zone = min(edgeZone, (right - left) / 3)
        if point.x - left <= zone { return .edge(track, id: item.id, .start) }
        if right - point.x <= zone { return .edge(track, id: item.id, .end) }
        return .item(track, id: item.id)
    }

    /// The selection after a click on `hit`: a click on an item (or its edge) selects it, with ⇧ it adds it to the selection
    /// when that is all of its track (`trackOf` says which track an id is on), otherwise it is the only one; a click on
    /// nothing deselects; the ruler leaves the selection alone (it moves the playhead).
    public static func selection(
        _ current: Set<String>, clicking hit: TimelineHit, shift: Bool, trackOf: (String) -> TimelineTrack?
    ) -> Set<String> {
        let (track, id): (TimelineTrack, String)
        switch hit {
        case .playhead: return current
        case .empty: return []
        case let .item(itemTrack, itemID), let .edge(itemTrack, itemID, _): (track, id) = (itemTrack, itemID)
        }
        guard shift, !current.isEmpty, current.allSatisfy({ trackOf($0) == track }) else { return [id] }
        return current.union([id])
    }

    /// `snapDistance` in nanoseconds of output at `scale` points per second (`EditPoints.snap`'s tolerance); 0, no snapping,
    /// for a scale that is not a positive number.
    public static func snapTolerance(scale: Double) -> Int64 {
        guard scale > 0, scale.isFinite else { return 0 }
        return Int64((snapDistance / scale * 1e9).rounded())
    }
}
