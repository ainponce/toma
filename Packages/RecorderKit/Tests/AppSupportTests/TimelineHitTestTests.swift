// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct TimelineHitTestTests {
    private static func track(_ id: String, _ kind: TrackKind) -> TrackRecord {
        let segment = SegmentRecord(
            index: 1, file: "takes/take-001/\(id)/seg-0001.mov", startHostTime: HostTime(nanoseconds: 1_000_000_000),
            endHostTime: HostTime(nanoseconds: 11_000_000_000), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
        return TrackRecord(id: id, kind: kind, source: TrackSource(name: id), segments: [segment])
    }

    /// The ruler (0–24), Video (24–80), Zoom (80–108), Camera (108–132).
    private static let layout: TimelineLayout = {
        let tracks = [track("display-1", .display), track("camera", .camera)]
        let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: tracks)
        return TimelineLayout(take: take, document: .legacy(take: take, events: []))
    }()

    /// At 100 pt/s with the timeline not scrolled, second `s` is at `88 + 100 s`.
    private static func x(_ seconds: Double) -> Double { TimelineLayout.headerWidth + seconds * 100 }

    private static let items = [
        TimelineItem(id: "c-1", track: .video, output: 0..<2_000_000_000),
        TimelineItem(id: "c-2", track: .video, output: 2_000_000_000..<5_000_000_000),
        TimelineItem(id: "z-1", track: .zoom, output: 1_000_000_000..<4_000_000_000),
        TimelineItem(id: "k-1", track: .camera, output: 3_000_000_000..<3_000_000_000),
    ]

    private static func hit(_ x: Double, _ y: Double, items: [TimelineItem] = items) -> TimelineHit {
        TimelineHitTest.hit(at: CGPoint(x: x, y: y), items: items, layout: layout, scale: 100, offset: 0)
    }

    @Test func edgesWithinSixPoints() {
        // Clip c-2 ends at 5 s: 5 pt before it is its end edge, 7 pt is the clip.
        #expect(Self.hit(Self.x(5) - 5, 50) == .edge(.video, id: "c-2", .end))
        #expect(Self.hit(Self.x(5) - 7, 50) == .item(.video, id: "c-2"))
        // The start edge, and the boundary between two clips: each side belongs to its clip.
        #expect(Self.hit(Self.x(2) + 4, 50) == .edge(.video, id: "c-2", .start))
        #expect(Self.hit(Self.x(2) - 4, 50) == .edge(.video, id: "c-1", .end))
        #expect(Self.hit(Self.x(0) + 2, 50) == .edge(.video, id: "c-1", .start))
        #expect(TimelineHitTest.edgeZone == 6)
    }

    @Test func aNarrowItemKeepsItsMiddle() {
        // A 12 pt block: a third of its width at each edge, the rest is the block itself.
        let narrow = [TimelineItem(id: "z-2", track: .zoom, output: 1_000_000_000..<1_120_000_000)]
        #expect(Self.hit(Self.x(1) + 2, 90, items: narrow) == .edge(.zoom, id: "z-2", .start))
        #expect(Self.hit(Self.x(1) + 6, 90, items: narrow) == .item(.zoom, id: "z-2"))
        #expect(Self.hit(Self.x(1.12) - 2, 90, items: narrow) == .edge(.zoom, id: "z-2", .end))
    }

    @Test func instantsAreItemsNeverEdges() {
        #expect(Self.hit(Self.x(3) + 4, 120) == .item(.camera, id: "k-1"))
        #expect(Self.hit(Self.x(3) - 4, 120) == .item(.camera, id: "k-1"))
        #expect(Self.hit(Self.x(3) + 8, 120) == .empty(.camera, output: 3_080_000_000))
    }

    @Test func emptyPlacesKeepTheirTrackAndTime() {
        #expect(Self.hit(Self.x(6), 50) == .empty(.video, output: 6_000_000_000))
        #expect(Self.hit(Self.x(0.5), 90) == .empty(.zoom, output: 500_000_000))
        // Left of the headers' edge and below the last row.
        #expect(Self.hit(40, 50) == .empty(.video, output: -480_000_000))
        #expect(Self.hit(Self.x(1), 500) == .empty(.camera, output: 1_000_000_000))
    }

    @Test func theRulerIsThePlayhead() {
        #expect(Self.hit(Self.x(1), 10) == .playhead)
        #expect(Self.hit(Self.x(1), 23.9) == .playhead)
        #expect(Self.hit(Self.x(1), 24) == .item(.video, id: "c-1"))
    }

    @Test func scrollingMovesTheItems() {
        // Scrolled 100 pt to the left, second 2 is 100 pt from the headers.
        let hit = TimelineHitTest.hit(at: CGPoint(x: 88 + 120, y: 50), items: Self.items, layout: Self.layout, scale: 100, offset: 100)
        #expect(hit == .item(.video, id: "c-2"))
    }

    @Test func emptyClickDeselects() {
        let hit = Self.hit(Self.x(0.5), 90)
        #expect(hit == .empty(.zoom, output: 500_000_000))
        let selected: Set<String> = ["c-1", "c-2"]
        #expect(TimelineHitTest.selection(selected, clicking: hit, shift: false, trackOf: Self.trackOf) == [])
        #expect(TimelineHitTest.selection(selected, clicking: hit, shift: true, trackOf: Self.trackOf) == [])
        // The ruler moves the playhead and leaves the selection alone.
        #expect(TimelineHitTest.selection(selected, clicking: .playhead, shift: false, trackOf: Self.trackOf) == selected)
    }

    @Test func shiftClickAddsOnlyOnTheSameTrack() {
        let video: Set<String> = ["c-1"]
        // Another clip: both. A zoom: only the zoom.
        #expect(TimelineHitTest.selection(video, clicking: .item(.video, id: "c-2"), shift: true, trackOf: Self.trackOf) == ["c-1", "c-2"])
        #expect(TimelineHitTest.selection(video, clicking: .item(.zoom, id: "z-1"), shift: true, trackOf: Self.trackOf) == ["z-1"])
        // An edge counts as its item; without ⇧ the click replaces the selection.
        #expect(TimelineHitTest.selection(video, clicking: .edge(.video, id: "c-2", .end), shift: true, trackOf: Self.trackOf) == ["c-1", "c-2"])
        #expect(TimelineHitTest.selection(video, clicking: .item(.video, id: "c-2"), shift: false, trackOf: Self.trackOf) == ["c-2"])
        // From nothing, ⇧ selects the one.
        #expect(TimelineHitTest.selection([], clicking: .item(.zoom, id: "z-1"), shift: true, trackOf: Self.trackOf) == ["z-1"])
        // A selection of ids the track function does not know is not of the clicked track.
        #expect(TimelineHitTest.selection(["gone"], clicking: .item(.video, id: "c-2"), shift: true, trackOf: Self.trackOf) == ["c-2"])
    }

    private static func trackOf(_ id: String) -> TimelineTrack? {
        items.first { $0.id == id }?.track
    }

    @Test func snapToleranceIsEightPoints() {
        #expect(TimelineHitTest.snapDistance == 8)
        #expect(TimelineHitTest.snapTolerance(scale: 100) == 80_000_000)
        #expect(TimelineHitTest.snapTolerance(scale: 600) == 13_333_333)
        #expect(TimelineHitTest.snapTolerance(scale: 0.5) == 16_000_000_000)
        // A scale that is not usable snaps to nothing.
        #expect(TimelineHitTest.snapTolerance(scale: 0) == 0)
        #expect(TimelineHitTest.snapTolerance(scale: .nan) == 0)
    }
}
