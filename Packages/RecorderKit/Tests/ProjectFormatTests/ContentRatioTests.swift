// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

// The ratio `auto` ("like the recording") follows: the region of the initial screen at the start of its first segment
// (plan decision 11, design §6.4).

private enum Ratio {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    static func segment(_ track: String, from: Double = 0) -> SegmentRecord {
        SegmentRecord(
            index: 1, file: "takes/\(takeID)/\(track)/seg-0001.mov", startHostTime: at(from), endHostTime: at(from + 60),
            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
    }

    static func display(_ number: UInt32, width: Double, height: Double, area: Rect? = nil, from: Double = 0) -> TrackRecord {
        TrackRecord(
            id: "display-\(number)", kind: .display,
            source: TrackSource(
                name: "Display", displayID: number, globalFrame: Rect(x: 0, y: 0, width: width, height: height), pixelScale: 2,
                captureArea: area),
            segments: [segment("display-\(number)", from: from)])
    }

    static func window(frame: Rect) -> TrackRecord {
        TrackRecord(
            id: "window-1", kind: .window, source: TrackSource(name: "Window", globalFrame: frame, windowID: 1),
            segments: [segment("window-1")])
    }

    static func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    }

    static func ratio(_ take: TakeRecord, events: [InputEvent] = [], screen: String? = nil) -> Double? {
        var document = EditDocument.legacy(take: take, events: events)
        if let screen { document.screens.initial = [takeID: screen] }
        return StageLayout.contentRatio(take: take, document: document, events: events)
    }
}

@Test func contentRatioIsTheFirstSegmentsRegion() {
    // A 2560 × 1440 display is 16:9.
    #expect(Ratio.ratio(Ratio.take([Ratio.display(1, width: 2560, height: 1440)])) == 2560.0 / 1440)
    // The Area crop: 1000 × 400 points.
    let area = Rect(x: 100, y: 100, width: 1000, height: 400)
    #expect(Ratio.ratio(Ratio.take([Ratio.display(1, width: 2560, height: 1440, area: area)])) == 2.5)
    // A window's geometry at the start of its first segment: 800 × 1200.
    let window = Ratio.take([Ratio.window(frame: Rect(x: 0, y: 0, width: 100, height: 100))])
    let events = [
        InputEvent(t: Ratio.at(0), kind: .windowGeometry(track: "window-1", frame: Rect(x: 0, y: 0, width: 800, height: 1200), onScreen: true))
    ]
    #expect(Ratio.ratio(window, events: events, screen: "window-1") == 2.0 / 3)
    // No screen: no ratio.
    #expect(Ratio.ratio(Ratio.take([]), screen: nil) == nil)
    #expect(Ratio.ratio(Ratio.take([Ratio.display(1, width: 2560, height: 1440)]), screen: "display-9") == nil)
}

@Test func contentRatioOfAnAudioTrackIsNil() {
    let audio = TrackRecord(
        id: "mic", kind: .microphone, source: TrackSource(name: "Mic"), segments: [Ratio.segment("mic")])
    #expect(Ratio.ratio(Ratio.take([audio]), screen: "mic") == nil)
}

@Test func contentRatioIgnoresLaterChanges() {
    let take = Ratio.take([
        Ratio.window(frame: Rect(x: 0, y: 0, width: 800, height: 1200)),
        Ratio.display(2, width: 1000, height: 1000),
    ])
    let events = [
        InputEvent(t: Ratio.at(10), kind: .windowGeometry(track: "window-1", frame: Rect(x: 0, y: 0, width: 1600, height: 900), onScreen: true))
    ]
    var document = EditDocument.legacy(take: take, events: events)
    document.screens.initial = [Ratio.takeID: "window-1"]
    document.screens.changes = [ScreenChange(id: "s-00000001", take: Ratio.takeID, t: Ratio.at(20), track: "display-2", origin: .user)]
    #expect(StageLayout.contentRatio(take: take, document: document, events: events) == 2.0 / 3)
}

@Test func autoSizeFollowsTheContent() {
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 2.4) == [2592, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 16.0 / 9) == [1920, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: nil) == [1920, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 2.0 / 3) == [1080, 1620])
    // The fixed aspects ignore it.
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 1080, contentRatio: 2.4) == [1920, 1080])
    #expect(StageLayout.outputSize(aspect: .fourByFive, shortSide: 1080, contentRatio: 2.4) == [1080, 1350])
}
