// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the Replay uses only the public API.
import ProjectFormat

// Milestone 5c, Task R1 (fases 4 y 5 design §10.3, plan decisions 6 and 7): the events of a saved take start at its first
// segment with the state in force there, and keep only what goes with the media saved.

private let origin = HostTime(nanoseconds: 5_000_000_000_000)

private func at(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

private func event(_ seconds: Double, _ kind: InputEvent.Kind) -> InputEvent {
    InputEvent(t: at(seconds), kind: kind)
}

private func track(_ id: String, _ kind: TrackKind, edges: [Double]) -> TrackRecord {
    TrackRecord(
        id: id, kind: kind, source: TrackSource(name: id),
        segments: zip(edges, edges.dropFirst()).enumerated().map { offset, span in
            SegmentRecord(
                index: offset + 1, file: "takes/take-001/\(id)/seg-" + String(format: "%04d", offset + 1) + ".mov",
                startHostTime: at(span.0), endHostTime: at(span.1), endReason: .rotated, droppedFrames: 0, heartbeatFrames: 0)
        })
}

/// A screen of 0–10–20–25 s and a microphone that rotated a little earlier, saving the last 12 s: the cut is at 13 s and
/// the events start at 9.98 s, the microphone's second segment.
private func cut(_ extra: [TrackRecord] = []) throws -> ReplayCut {
    let tracks = [track("display-1", .display, edges: [0, 10, 20, 25]), track("mic", .microphone, edges: [0, 9.98, 19.97, 25.01])]
    return try ReplayCut.make(
        take: TakeRecord(id: "take-001", status: .recording, startedAt: Date(), tracks: tracks + extra), seconds: 12,
        takeID: "take-001")
}

private let frameA = Rect(x: 0, y: 0, width: 1512, height: 982)
private let frameA2 = Rect(x: 0, y: 0, width: 1728, height: 1117)
private let frameB = Rect(x: 1512, y: -200, width: 2560, height: 1440)
private let window1 = Rect(x: 100, y: 80, width: 800, height: 600)
private let window2 = Rect(x: 140, y: 90, width: 820, height: 610)

private func cursorImage(_ hash: String) -> InputEvent.Kind {
    .cursorImage(hash: hash, hotspot: SIMD2(0.16, 0.12), size: SIMD2(24, 32), kind: .arrow)
}

private let hash1 = String(repeating: "1", count: 32)
private let hash2 = String(repeating: "2", count: 32)

@Suite struct ReplayEventsTests {
    @Test func stateIsReEmittedAtTheStart() throws {
        let cut = try cut([track("window-4242", .window, edges: [0, 10, 20, 25])])
        let events = [
            event(1, .displayGeometry(displayID: 1, frame: frameA, scale: 2)),
            event(1, cursorImage(hash1)),
            event(2, .displayGeometry(displayID: 2, frame: frameB, scale: 1)),
            event(2, .cursor(x: 10, y: 10)),
            event(3, .windowGeometry(track: "window-4242", frame: window1, onScreen: true)),
            event(3, .marker),
            event(4, .focus(x: 1, y: 2, width: 3, height: 4, kind: .element)),
            event(4, .keyActivity),
            event(5, .displayGeometry(displayID: 1, frame: frameA2, scale: 2)),
            event(6, .windowGeometry(track: "window-4242", frame: window2, onScreen: false)),
            event(7, cursorImage(hash2)),
            event(8, .mouseDown(.left, x: 30, y: 40)),
            event(8.5, .mouseUp(.left, x: 30, y: 40)),
            event(9, .scroll(dx: 0, dy: -4, x: 50, y: 60)),
            event(9.5, .focus(x: 640.5, y: -40, width: 2, height: 18, kind: .caret)),
            event(11, .cursor(x: 70, y: 80)),
            event(12, .marker),
        ]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        let start = cut.start
        #expect(start == at(9.98))
        #expect(saved.events == [
            InputEvent(t: start, kind: .displayGeometry(displayID: 1, frame: frameA2, scale: 2)),
            InputEvent(t: start, kind: .displayGeometry(displayID: 2, frame: frameB, scale: 1)),
            InputEvent(t: start, kind: .windowGeometry(track: "window-4242", frame: window2, onScreen: false)),
            InputEvent(t: start, kind: cursorImage(hash2)),
            InputEvent(t: start, kind: .cursor(x: 50, y: 60)),
            InputEvent(t: start, kind: .focus(x: 640.5, y: -40, width: 2, height: 18, kind: .caret)),
            event(11, .cursor(x: 70, y: 80)),
            event(12, .marker),
        ])
        #expect(saved.cameraStyle == nil)
    }

    @Test func cameraStyleGoesToTheRecordNotToAnEvent() throws {
        let cut = try cut([track("camera", .camera, edges: [0, 10, 20, 25])])
        let initial = CameraStyle.default
        let moved = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
        let later = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .bottomLeading)
        let events = [
            event(3, .cameraStyle(CameraStyle(shape: .circle, size: CameraStyle.large, anchor: .topTrailing))),
            event(8, .cameraStyle(moved)),
            event(15, .cameraStyle(later)),
        ]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: initial, cut: cut)

        #expect(saved.cameraStyle == moved)
        #expect(saved.events == [event(15, .cameraStyle(later))])
        // With no change before the start, the take's own.
        let unchanged = ReplayEvents.saved([event(15, .cameraStyle(later))], carried: [], initialCameraStyle: initial, cut: cut)
        #expect(unchanged.cameraStyle == initial)
    }

    @Test func stateOfPrunedShardsComesFromCarried() throws {
        let cut = try cut()
        var state = ReplayEventState(cameraStyle: nil)
        state.fold([
            event(1, .displayGeometry(displayID: 1, frame: frameA, scale: 2)),
            event(1, .displayGeometry(displayID: 2, frame: frameB, scale: 1)),
            event(1.5, cursorImage(hash1)),
            event(2, .mouseDown(.left, x: 30, y: 40)),
            event(2.5, .marker),
        ])
        // What the state keeps is the state, at the times it came from; a position is a position.
        #expect(state.events == [
            event(1, .displayGeometry(displayID: 1, frame: frameA, scale: 2)),
            event(1, .displayGeometry(displayID: 2, frame: frameB, scale: 1)),
            event(1.5, cursorImage(hash1)),
            event(2, .cursor(x: 30, y: 40)),
        ])
        let events = [
            event(5, .displayGeometry(displayID: 2, frame: frameA2, scale: 2)),
            event(6, .cursor(x: 7, y: 8)),
            event(11, .marker),
        ]

        let saved = ReplayEvents.saved(events, carried: state.events, initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [
            InputEvent(t: cut.start, kind: .displayGeometry(displayID: 1, frame: frameA, scale: 2)),
            InputEvent(t: cut.start, kind: .displayGeometry(displayID: 2, frame: frameA2, scale: 2)),
            InputEvent(t: cut.start, kind: cursorImage(hash1)),
            InputEvent(t: cut.start, kind: .cursor(x: 7, y: 8)),
            event(11, .marker),
        ])
    }

    @Test func foldKeepsTheLatestByTimeAcrossBatches() {
        var state = ReplayEventState(cameraStyle: .default)
        let moved = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
        state.fold([event(5, .displayGeometry(displayID: 1, frame: frameA2, scale: 2)), event(6, .cameraStyle(moved))])
        // A later shard can hold a line logged a little earlier: time decides, not the order of the folds.
        state.fold([
            event(4, .displayGeometry(displayID: 1, frame: frameA, scale: 2)),
            event(4, .cameraStyle(.default)),
            event(7, .focus(x: 1, y: 2, width: 3, height: 4, kind: .element)),
        ])

        #expect(state.cameraStyle == moved)
        #expect(state.events == [
            event(5, .displayGeometry(displayID: 1, frame: frameA2, scale: 2)),
            event(6, .cameraStyle(moved)),
            event(7, .focus(x: 1, y: 2, width: 3, height: 4, kind: .element)),
        ])
        #expect(state.reEmitted(at: at(9)) == [
            event(9, .displayGeometry(displayID: 1, frame: frameA2, scale: 2)),
            event(9, .focus(x: 1, y: 2, width: 3, height: 4, kind: .element)),
        ])
    }

    @Test func lifecycleOfAnUnsavedSegmentIsLeftOut() throws {
        // System audio rotated at 10.02 s, after the events start, and its last segment ended early at 24.5 s.
        let cut = try cut([track("system-audio", .systemAudio, edges: [0, 10.02, 20.03, 24.5])])
        let events = [
            event(0, .segmentStarted(track: "system-audio", index: 1)),
            event(5, .audioClock(track: "system-audio", frame: 240_000)),
            event(10, .audioClock(track: "system-audio", frame: 480_000)),
            event(10.01, .droppedSamples(track: "system-audio", count: 3)),
            event(10.01, .streamInterrupted(track: "system-audio", domain: "SCStreamErrorDomain", code: -3821)),
            event(10.01, .deviceChanged(track: "system-audio", deviceUniqueID: "other")),
            event(10.02, .segmentStarted(track: "system-audio", index: 2)),
            event(15.02, .audioClock(track: "system-audio", frame: 240_000)),
            event(16, .droppedSamples(track: "system-audio", count: 1)),
            event(20.03, .segmentStarted(track: "system-audio", index: 3)),
            // Its segment 4 was still open when the save froze the take: not saved, nor what goes with it.
            event(24.5, .segmentStarted(track: "system-audio", index: 4)),
            event(24.9, .audioClock(track: "system-audio", frame: 19_200)),
            event(24.95, .droppedSamples(track: "system-audio", count: 2)),
        ]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [
            event(10.02, .segmentStarted(track: "system-audio", index: 1)),
            event(15.02, .audioClock(track: "system-audio", frame: 240_000)),
            event(16, .droppedSamples(track: "system-audio", count: 1)),
            event(20.03, .segmentStarted(track: "system-audio", index: 2)),
        ])
    }

    @Test func segmentStartedIsRenumbered() throws {
        let cut = try cut()
        let events = [
            event(0, .segmentStarted(track: "display-1", index: 1)),
            event(0, .segmentStarted(track: "mic", index: 1)),
            event(9.98, .segmentStarted(track: "mic", index: 2)),
            event(10, .segmentStarted(track: "display-1", index: 2)),
            event(19.97, .segmentStarted(track: "mic", index: 3)),
            event(20, .segmentStarted(track: "display-1", index: 3)),
            // The segments the save's rotation opened.
            event(25, .segmentStarted(track: "display-1", index: 4)),
        ]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [
            event(9.98, .segmentStarted(track: "mic", index: 1)),
            event(10, .segmentStarted(track: "display-1", index: 1)),
            event(19.97, .segmentStarted(track: "mic", index: 2)),
            event(20, .segmentStarted(track: "display-1", index: 2)),
        ])
    }

    @Test func eventsOfATrackNotSavedAreLeftOut() throws {
        // A window that closed before the cut: its track is not saved, nor its geometry.
        let cut = try cut([track("window-4242", .window, edges: [0, 10, 12])])
        #expect(!cut.tracks.contains { $0.id == "window-4242" })
        let events = [
            event(2, .windowGeometry(track: "window-4242", frame: window1, onScreen: true)),
            event(11, .windowGeometry(track: "window-4242", frame: window2, onScreen: true)),
            event(11, .droppedSamples(track: "window-4242", count: 1)),
            event(11.5, .marker),
        ]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [event(11.5, .marker)])
    }

    @Test func eventsAfterTheEndAreLeftOut() throws {
        let cut = try cut()
        let events = [event(24, .marker), event(25, .marker), event(25.5, .marker), event(26, .cursor(x: 1, y: 1))]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [event(24, .marker), event(25, .marker)])
    }

    @Test func eventsAreInTimeOrderWhateverTheirFileOrder() throws {
        let cut = try cut()
        let events = [event(12, .marker), event(11, .cursor(x: 1, y: 1)), event(9, .cursor(x: 2, y: 2)), event(11, .keyActivity)]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [
            InputEvent(t: cut.start, kind: .cursor(x: 2, y: 2)),
            event(11, .cursor(x: 1, y: 1)),
            event(11, .keyActivity),
            event(12, .marker),
        ])
    }

    @Test func aButtonHeldAcrossTheCutIsNotReEmitted() throws {
        let cut = try cut()
        let events = [event(9, .mouseDown(.left, x: 5, y: 6)), event(11, .mouseUp(.left, x: 7, y: 8))]

        let saved = ReplayEvents.saved(events, carried: [], initialCameraStyle: nil, cut: cut)

        #expect(saved.events == [
            InputEvent(t: cut.start, kind: .cursor(x: 5, y: 6)),
            event(11, .mouseUp(.left, x: 7, y: 8)),
        ])
    }

    @Test func lastFocusIsReEmittedOnlyIfThereIsOne() throws {
        let cut = try cut()
        let without = ReplayEvents.saved([event(2, .cursor(x: 1, y: 1))], carried: [], initialCameraStyle: nil, cut: cut)
        #expect(without.events == [InputEvent(t: cut.start, kind: .cursor(x: 1, y: 1))])

        let focused = ReplayEvents.saved(
            [
                event(2, .focus(x: 1, y: 2, width: 3, height: 4, kind: .element)),
                event(3, .focus(x: 5, y: 6, width: 2, height: 18, kind: .caret)),
            ],
            carried: [], initialCameraStyle: nil, cut: cut)
        #expect(focused.events == [InputEvent(t: cut.start, kind: .focus(x: 5, y: 6, width: 2, height: 18, kind: .caret))])
    }
}
