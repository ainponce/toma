// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The synthetic takes of the tests of `ScreenFollowPlanner`: two displays side by side, `display-1` (1440×900 pt at the
/// origin) and `display-2` (1920×1080 pt to its right), each with one segment recorded for 60 s from `base`, in a
/// package where every segment file is written (a byte each) unless a test leaves it out.
///
/// The tests are nested in an extension of this namespace, where these helpers are found unqualified, so other files of
/// AnalysisTests can have helpers of their own with the same names.
enum ScreenFollowFixtures {
    /// An arbitrary host time well after boot.
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let takeID = "take-001"
    static let frame1 = Rect(x: 0, y: 0, width: 1440, height: 900)
    static let frame2 = Rect(x: 1440, y: 0, width: 1920, height: 1080)

    /// The host time `seconds` after `base`.
    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    /// Segment `index` of `track` over the seconds `[from, to)` after `base`.
    static func segment(
        _ track: String, _ index: Int = 1, from: Double = 0, to: Double = 60, endReason: SegmentEndReason = .stopped
    ) -> SegmentRecord {
        SegmentRecord(
            index: index, file: "takes/\(takeID)/\(track)/seg-000\(index).mov", startHostTime: at(from), endHostTime: at(to),
            endReason: endReason, droppedFrames: 0, heartbeatFrames: 0)
    }

    /// Display `number` (`display-<number>`, `displayID` `number`) at `frame`, with `segments` (one of 60 s by default).
    static func display(_ number: Int, frame: Rect, segments: [SegmentRecord]? = nil) -> TrackRecord {
        let id = "display-\(number)"
        return TrackRecord(
            id: id, kind: .display,
            source: TrackSource(name: "Display \(number)", displayID: UInt32(number), globalFrame: frame, pixelScale: 2),
            segments: segments ?? [segment(id)])
    }

    static func makeTake(_ tracks: [TrackRecord]? = nil) -> TakeRecord {
        TakeRecord(
            id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: tracks ?? [display(1, frame: frame1), display(2, frame: frame2)])
    }

    /// The pointer `seconds` after `base` in the middle of display `screen` (1 or 2).
    static func pointer(_ seconds: Double, on screen: Int) -> InputEvent {
        let frame = screen == 1 ? frame1 : frame2
        return InputEvent(t: at(seconds), kind: .cursor(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))
    }

    /// The pointer at `t` in the middle of display `screen` (1 or 2).
    static func pointer(_ t: HostTime, on screen: Int) -> InputEvent {
        InputEvent(t: t, kind: pointer(0, on: screen).kind)
    }

    /// A clip of `take` over the seconds `[from, to)` after `base`.
    static func clip(from: Double, to: Double, speed: Double = 1, take: String = takeID) -> Clip {
        Clip(id: "c-00000001", take: take, start: at(from), end: at(to), speed: speed)
    }

    /// The plan of `take` over `events`, in a package where every segment file of `take` is written with `bytes`
    /// bytes, but those of the tracks in `missing`, which are not written. With `sequence`, measured in its output
    /// (`plan(take:events:package:timeMap:)`); without, in the take's new document's.
    static func plan(
        _ events: [InputEvent], take: TakeRecord = makeTake(), missing: Set<String> = [], bytes: Int = 1,
        sequence: [Clip]? = nil
    ) throws -> (initial: String?, changes: [ScreenChange]) {
        try withTemporaryDirectory { directory in
            let package = ProjectPackage(url: directory.appendingPathComponent("Test.toma", isDirectory: true))
            for track in take.tracks where !missing.contains(track.id) {
                for segment in track.segments {
                    let url = package.fileURL(segment.file)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(repeating: 0x2A, count: bytes).write(to: url)
                }
            }
            guard let sequence else { return ScreenFollowPlanner.plan(take: take, events: events, package: package) }
            return ScreenFollowPlanner.plan(take: take, events: events, package: package, timeMap: TimeMap(sequence: sequence))
        }
    }

    /// A pointer that wanders between both screens and off them at uneven times, with pauses, for 59 s (seeded, so
    /// always the same).
    static func wander() -> [InputEvent] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: UInt64) -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state >> 33) % bound
        }
        var events: [InputEvent] = []
        var t: UInt64 = 0
        while t < 59_000_000_000 {
            let place = next(5)
            let time = HostTime(nanoseconds: base.nanoseconds + t)
            switch place {
            case 0: events.append(InputEvent(t: time, kind: .cursor(x: 5000, y: 5000)))
            case 1, 2: events.append(pointer(time, on: 1))
            default: events.append(pointer(time, on: 2))
            }
            if next(12) == 0 {
                events.append(InputEvent(t: HostTime(nanoseconds: time.nanoseconds + 1_000), kind: .paused(reason: "user")))
                t += 1_000 + next(3_000_000_000)
                events.append(InputEvent(t: HostTime(nanoseconds: base.nanoseconds + t), kind: .resumed))
            }
            t += 1 + next(1_600_000_000)
        }
        return events
    }

    /// The id of plan decision 10, computed here on its own.
    static func expectedID(_ t: HostTime, _ track: String) -> String {
        let digest = SHA256.hash(data: Data("screenFollow-1|\(takeID)|\(t.nanoseconds)|\(track)".utf8))
        return "p-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The automatic change to `track` at `t`, with its id.
    static func change(_ t: HostTime, _ track: String) -> ScreenChange {
        ScreenChange(id: expectedID(t, track), take: takeID, t: t, track: track, origin: .auto)
    }
}

extension ScreenFollowFixtures {
    @Suite struct ScreenFollowPlannerTests {
        @Test func firstScreenHoldsTheFirstPointer() throws {
            let result = try plan([pointer(0.5, on: 2), pointer(30, on: 2)])
            #expect(result.initial == "display-2")
            #expect(result.changes.isEmpty)
        }

        @Test func switchesAfterDwellAtTheEntryInstant() throws {
            // Recorded for 4 s: the pointer is on display-2 from 3 s to the end, 1 s.
            let take = makeTake([
                display(1, frame: frame1, segments: [segment("display-1", to: 4)]),
                display(2, frame: frame2, segments: [segment("display-2", to: 4)]),
            ])
            let result = try plan([pointer(0, on: 1), pointer(3, on: 2)], take: take)
            #expect(result.initial == "display-1")
            #expect(result.changes == [change(at(3), "display-2")])
            #expect(result.changes.first?.origin == .auto)
        }

        @Test func shortVisitDoesNotSwitch() throws {
            let result = try plan([pointer(0, on: 1), pointer(3, on: 2), pointer(3.5, on: 1)])
            #expect(result.initial == "display-1")
            #expect(result.changes.isEmpty)
        }

        @Test func unreadableScreenIsSkipped() throws {
            let take = makeTake([
                display(1, frame: frame1),
                display(2, frame: frame2, segments: [segment("display-2", endReason: .unreadable(bytes: 4096))]),
            ])
            let first = try plan([pointer(0.5, on: 2), pointer(30, on: 2)], take: take)
            #expect(first.initial == "display-1")
            #expect(first.changes.isEmpty)

            let entering = try plan([pointer(0, on: 1), pointer(3, on: 2)], take: take)
            #expect(entering.initial == "display-1")
            #expect(entering.changes.isEmpty)
        }

        @Test func singleScreenHasNoChanges() throws {
            let take = makeTake([display(1, frame: frame1)])
            let result = try plan([pointer(0, on: 1), pointer(3, on: 2), pointer(10, on: 1), pointer(20, on: 2)], take: take)
            #expect(result.initial == "display-1")
            #expect(result.changes.isEmpty)
        }

        @Test func dwellOfExactlyEightTenthsSwitches() throws {
            let entry = at(3)
            let exit = HostTime(nanoseconds: entry.nanoseconds + UInt64(ScreenFollowPlanner.dwell))
            let back = try plan([pointer(0, on: 1), pointer(entry, on: 2), pointer(exit, on: 1)])
            #expect(back.changes == [change(entry, "display-2"), change(exit, "display-1")])

            let early = HostTime(nanoseconds: exit.nanoseconds - 1)
            let short = try plan([pointer(0, on: 1), pointer(entry, on: 2), pointer(early, on: 1)])
            #expect(short.changes.isEmpty)
        }

        @Test func aMissingOrEmptySegmentDoesNotCount() throws {
            let events = [pointer(0.5, on: 2), pointer(30, on: 2)]
            let missing = try plan(events, missing: ["display-2"])
            #expect(missing.initial == "display-1")
            #expect(missing.changes.isEmpty)

            let empty = try plan(
                events,
                take: makeTake([
                    display(1, frame: frame1), display(2, frame: frame2, segments: [segment("display-2", endReason: .empty)]),
                ]))
            #expect(empty.initial == "display-1")
            #expect(empty.changes.isEmpty)

            // Files of 0 bytes are empty too, so with display-1's as well nothing counts: ScreenChoice's pick stays.
            let zeroBytes = try plan(events, bytes: 0)
            #expect(zeroBytes.initial == "display-2")
            #expect(zeroBytes.changes.isEmpty)
        }

        @Test func aScreenCountsFromItsReadableSegment() throws {
            // display-2 cannot be read for its first 10 s: the pointer has been on it since 3 s, and the output shows it
            // from 10 s, the instant it starts to count.
            let take = makeTake([
                display(1, frame: frame1),
                display(
                    2, frame: frame2,
                    segments: [
                        segment("display-2", 1, to: 10, endReason: .unreadable(bytes: 4096)), segment("display-2", 2, from: 10),
                    ]),
            ])
            let result = try plan([pointer(0, on: 1), pointer(3, on: 2)], take: take)
            #expect(result.changes == [change(at(10), "display-2")])
        }

        @Test func dwellIsMeasuredInTheOutput() throws {
            // On display-2 from 3 s; paused from 3.3 s to 20 s. Back on display-1 0.3 s after resuming: 0.6 s of output.
            let paused = [InputEvent(t: at(3.3), kind: .paused(reason: "user")), InputEvent(t: at(20), kind: .resumed)]
            let short = try plan([pointer(0, on: 1), pointer(3, on: 2)] + paused + [pointer(20.3, on: 1)])
            #expect(short.changes.isEmpty)

            // 0.6 s after resuming: 0.9 s of output.
            let long = try plan([pointer(0, on: 1), pointer(3, on: 2)] + paused + [pointer(20.6, on: 1)])
            #expect(long.changes == [change(at(3), "display-2"), change(at(20.6), "display-1")])

            // Entered during the pause: the change rules from the first instant recorded after it.
            let duringPause = try plan(
                [pointer(0, on: 1), InputEvent(t: at(3), kind: .paused(reason: "user")), pointer(10, on: 2),
                 InputEvent(t: at(20), kind: .resumed)])
            #expect(duringPause.changes == [change(at(20), "display-2")])
        }

        @Test func aDisplayIsFollowedWhereItIs() throws {
            // At 5 s display-2 moves to the left of display-1; at 6 s the pointer is there, where it was nothing before.
            let moved = Rect(x: -1920, y: 0, width: 1920, height: 1080)
            let events = [
                pointer(0, on: 1),
                InputEvent(t: at(5), kind: .displayGeometry(displayID: 2, frame: moved, scale: 2)),
                InputEvent(t: at(6), kind: .cursor(x: -960, y: 540)),
            ]
            let result = try plan(events)
            #expect(result.changes == [change(at(6), "display-2")])
        }

        @Test func withoutAPointerOrAReadableScreen() throws {
            // No pointer: the first screen that counts.
            #expect(try plan([]).initial == "display-1")
            let secondOnly = makeTake([
                display(1, frame: frame1, segments: [segment("display-1", endReason: .unreadable(bytes: 4096))]),
                display(2, frame: frame2),
            ])
            #expect(try plan([], take: secondOnly).initial == "display-2")
            // The pointer off every screen at the start: the first that counts then.
            let off = try plan([InputEvent(t: at(0), kind: .cursor(x: 5000, y: 5000)), pointer(2, on: 2)], take: secondOnly)
            #expect(off.initial == "display-2")
            #expect(off.changes.isEmpty)
            // Nothing counts anywhere: ScreenChoice's pick, and no changes.
            let none = try plan([pointer(0, on: 2), pointer(3, on: 1)], missing: ["display-1", "display-2"])
            #expect(none.initial == "display-2")
            #expect(none.changes.isEmpty)
            // No screen track at all.
            let audio = TrackRecord(
                id: "mic-1", kind: .microphone, source: TrackSource(name: "Mic"), segments: [segment("mic-1")])
            let noScreen = try plan([pointer(0, on: 1)], take: makeTake([audio]))
            #expect(noScreen.initial == nil)
            #expect(noScreen.changes.isEmpty)
        }

        @Test func sameInputSameChangesAndIDs() throws {
            let events = [pointer(0, on: 1), pointer(3, on: 2), pointer(8, on: 1), pointer(8.3, on: 2), pointer(12, on: 1)]
            let first = try plan(events)
            let second = try plan(events)
            #expect(first.changes == second.changes)
            #expect(first.initial == second.initial)
            #expect(first.changes == [change(at(3), "display-2"), change(at(12), "display-1")])
            #expect(first.changes.allSatisfy { $0.id == expectedID($0.t, $0.track) && $0.origin == .auto })
        }

        @Test func changesNeverOverlapAndAlwaysSwitch() throws {
            let events = wander()
            let take = makeTake()
            let result = try plan(events, take: take)
            #expect(result.changes.count > 5)

            let spans = TakeTimeline.recordedSpans(take: take, events: events)
            let timeMap = TimeMap(
                sequence: spans.map { Clip(id: "c-00000001", take: takeID, start: $0.lowerBound, end: $0.upperBound, speed: 1) })
            var shown = result.initial
            var previous: Int64?
            for change in result.changes {
                #expect(change.track != shown)
                let output = try #require(timeMap.output(atSource: change.t, take: takeID), "a change at a recorded instant")
                if let previous { #expect(output - previous >= ScreenFollowPlanner.dwell) }
                #expect(change.id == expectedID(change.t, change.track))
                shown = change.track
                previous = output
            }
        }

        @Test func initialIsThePointersScreenWhenNothingCountsAtTheStart() throws {
            // Nothing can be read in the first second; from 1 s both screens can, with the pointer on display-2.
            let take = makeTake([
                display(1, frame: frame1, segments: [segment("display-1", from: 1)]),
                display(
                    2, frame: frame2,
                    segments: [segment("display-2", 1, to: 1, endReason: .empty), segment("display-2", 2, from: 1)]),
            ])
            let result = try plan([pointer(0, on: 2), pointer(30, on: 2)], take: take)
            #expect(result.initial == "display-2")
            #expect(result.changes.isEmpty)
        }

        // A document's output: `plan(take:events:package:timeMap:)`.

        @Test func theNewDocumentsOutputIsTheDefault() throws {
            let events = wander()
            let take = makeTake()
            let sequence = TakeTimeline.recordedSpans(take: take, events: events).map {
                Clip(id: "c-00000001", take: takeID, start: $0.lowerBound, end: $0.upperBound, speed: 1)
            }
            let byDefault = try plan(events, take: take)
            let given = try plan(events, take: take, sequence: sequence)
            #expect(byDefault.initial == given.initial)
            #expect(byDefault.changes == given.changes)
        }

        @Test func aCutThatRemovesAStayDoesNotSwitch() throws {
            // 2 s on display-2, there and back in the recorded take.
            let events = [pointer(0, on: 1), pointer(3, on: 2), pointer(5, on: 1)]
            #expect(try plan(events).changes == [change(at(3), "display-2"), change(at(5), "display-1")])
            // With the source from 2.9 s to 5.1 s cut, none of it is in the output.
            let cut = try plan(events, sequence: [clip(from: 0, to: 2.9), clip(from: 5.1, to: 60)])
            #expect(cut.initial == "display-1")
            #expect(cut.changes.isEmpty)
        }

        @Test func aClipsSpeedScalesAStay() throws {
            // 1.2 s of source on display-2: 0.6 s of output at 2×.
            let events = [pointer(0, on: 1), pointer(3, on: 2), pointer(4.2, on: 1)]
            #expect(try plan(events).changes == [change(at(3), "display-2"), change(at(4.2), "display-1")])
            #expect(try plan(events, sequence: [clip(from: 0, to: 60, speed: 2)]).changes.isEmpty)
            // 0.5 s of source: 1 s of output at 0.5×.
            let slow = [pointer(0, on: 1), pointer(3, on: 2), pointer(3.5, on: 1)]
            #expect(try plan(slow).changes.isEmpty)
            #expect(
                try plan(slow, sequence: [clip(from: 0, to: 60, speed: 0.5)]).changes
                    == [change(at(3), "display-2"), change(at(3.5), "display-1")])
        }

        @Test func aStayIsMeasuredAcrossACut() throws {
            // On display-2 from 3 s, with the source from 3.4 s to 10 s cut.
            let sequence = [clip(from: 0, to: 3.4), clip(from: 10, to: 60)]
            // Back on display-1 at 10.5 s: 0.4 s + 0.5 s of output.
            let long = try plan([pointer(0, on: 1), pointer(3, on: 2), pointer(10.5, on: 1)], sequence: sequence)
            #expect(long.changes == [change(at(3), "display-2"), change(at(10.5), "display-1")])
            // At 10.3 s: 0.4 s + 0.3 s.
            let short = try plan([pointer(0, on: 1), pointer(3, on: 2), pointer(10.3, on: 1)], sequence: sequence)
            #expect(short.changes.isEmpty)
            // Entered inside the cut: the change rules from the first instant kept after it, the next clip's start.
            let inside = try plan([pointer(0, on: 1), pointer(5, on: 2)], sequence: sequence)
            #expect(inside.changes == [change(at(10), "display-2")])
        }

        @Test func aLegacyPauseStillCountsInTheStay() throws {
            // Paused from 3.3 s to 20 s, each screen's segment ends at the pause and the next starts at the resume.
            let take = makeTake([
                display(
                    1, frame: frame1,
                    segments: [segment("display-1", 1, to: 3.3, endReason: .paused), segment("display-1", 2, from: 20)]),
                display(
                    2, frame: frame2,
                    segments: [segment("display-2", 1, to: 3.3, endReason: .paused), segment("display-2", 2, from: 20)]),
            ])
            let events = [
                pointer(0, on: 1), pointer(3, on: 2), InputEvent(t: at(3.3), kind: .paused(reason: "user")),
                InputEvent(t: at(20), kind: .resumed), pointer(20.3, on: 1),
            ]
            // The new document closes the pause: 0.6 s on display-2.
            #expect(try plan(events, take: take).changes.isEmpty)
            // The legacy document's one clip shows it as a still frame: 17.3 s.
            let legacy = try plan(events, take: take, sequence: [clip(from: 0, to: 60)])
            #expect(legacy.changes == [change(at(3), "display-2"), change(at(20.3), "display-1")])
        }

        @Test func instantsShownAtOneOutputInstantAreOne() throws {
            // At 16×, the pointer's move to display-2 5 ns after the start is seen from the output's first instant on.
            let events = [pointer(base, on: 1), pointer(HostTime(nanoseconds: base.nanoseconds + 5), on: 2)]
            let result = try plan(events, sequence: [clip(from: 0, to: 60, speed: 16)])
            #expect(result.initial == "display-2")
            #expect(result.changes.isEmpty)
        }

        @Test func aStayEndsWithItsTake() throws {
            // This take's clip ends at 4 s; a clip of another take follows it.
            let sequence = [clip(from: 0, to: 4), clip(from: 100, to: 160, take: "take-002")]
            #expect(try plan([pointer(0, on: 1), pointer(3.5, on: 2)], sequence: sequence).changes.isEmpty)
            #expect(try plan([pointer(0, on: 1), pointer(3, on: 2)], sequence: sequence).changes == [change(at(3), "display-2")])
        }
    }
}
