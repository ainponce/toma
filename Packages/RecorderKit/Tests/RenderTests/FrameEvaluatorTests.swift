// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Render
import Testing

private func seconds(_ s: Double) -> HostTime { HostTime(nanoseconds: UInt64(s * 1_000_000_000)) }

private func evaluator(
    globalFrame: Rect?, segments: [SegmentRecord]? = nil, events: [InputEvent] = [], outputSize: SIMD2<Int> = [1920, 1080]
) -> FrameEvaluator {
    let take = makeTake(tracks: [
        displayTrack(globalFrame: globalFrame, segments: segments ?? [segment(start: base, end: base.adding(seconds: 10))]),
    ])
    return FrameEvaluator(take: take, events: events, style: StyleV0(), outputSize: outputSize)
}

private func cursor(_ seconds: Double, x: Double, y: Double) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: .cursor(x: x, y: y))
}

@Test func timelineEndsWithTheMicrophoneWhenItRecordedLonger() {
    let display = displayTrack(globalFrame: nil, segments: [segment(start: base, end: base.adding(seconds: 2))])
    func microphone(_ segments: [SegmentRecord]) -> TrackRecord {
        TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Mic"), segments: segments)
    }
    func evaluate(_ tracks: [TrackRecord]) -> FrameEvaluator {
        FrameEvaluator(take: makeTake(tracks: tracks), events: [], style: StyleV0(), outputSize: [1920, 1080])
    }
    // The mic starts earlier and ends later: the start stays the screen's, the end is the mic's.
    let longer = evaluate([microphone([segment(start: base.adding(seconds: -0.5), end: base.adding(seconds: 6))]), display])
    #expect(longer.timelineStart == base)
    #expect(abs(longer.duration - 6) < 1e-9)
    #expect(longer.frame(at: 5).screen?.sourceTime == base.adding(seconds: 5))
    // An open mic segment counts up to its start.
    let open = evaluate([display, microphone([segment(start: base.adding(seconds: 3), end: nil, reason: nil)])])
    #expect(abs(open.duration - 3) < 1e-9)
    // A shorter mic changes nothing; without a screen segment the mic does not make a timeline.
    #expect(evaluate([display, microphone([segment(start: base, end: base.adding(seconds: 1))])]).duration == 2)
    let screenless = evaluate([displayTrack(globalFrame: nil, segments: []), microphone([segment(start: base, end: base.adding(seconds: 6))])])
    #expect(screenless.duration == 0)
}

@Test func styleV0Values() {
    let style = StyleV0()
    #expect(style.gradientStart == SIMD4<Float>(0x7F, 0x5A, 0xF0, 255) / 255)
    #expect(style.gradientEnd == SIMD4<Float>(0x2C, 0xB1, 0xBC, 255) / 255)
    #expect(style.gradientAngleDegrees == 135)
    #expect(style.paddingFraction == 0.08)
    #expect(style.cornerRadiusFraction == 0.012)
    #expect(style.cursorPointHeight == 24)
}

@Test func evaluatorMapsOutputTimeToHostTime() {
    let e = evaluator(
        globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080),
        segments: [segment(start: seconds(10), end: seconds(15))])
    #expect(e.timelineStart == seconds(10))
    #expect(e.duration == 5)
    #expect(e.frame(at: 2).screen?.sourceTime == seconds(12))
    #expect(e.frame(at: 2).screen?.trackID == trackID)
    // Clamped to [0, duration].
    #expect(e.frame(at: -1).screen?.sourceTime == seconds(10))
    #expect(e.frame(at: 60).screen?.sourceTime == seconds(15))
    #expect(e.frame(at: .nan).screen?.sourceTime == seconds(10))
}

@Test func timelineSpansEverySegmentOfTheScreen() {
    let e = evaluator(
        globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080),
        segments: [
            segment(index: 1, start: seconds(10), end: seconds(12), reason: .empty),
            segment(index: 2, start: seconds(13), end: seconds(16)),
        ])
    #expect(e.timelineStart == seconds(10))
    #expect(e.duration == 6)
    #expect(e.frame(at: 4).screen?.sourceTime == seconds(14))
}

@Test func contentRectIsAspectFitInsidePadding() throws {
    // A 3024×1964 px display: 1512×982 points at 2 px per point.
    let e = evaluator(globalFrame: Rect(x: 0, y: 0, width: 1512, height: 982))
    let frame = e.frame(at: 1)
    #expect(frame.outputSize == [1920, 1080])
    #expect(frame.gradientStart == StyleV0().gradientStart)
    #expect(frame.gradientEnd == StyleV0().gradientEnd)
    #expect(frame.gradientAngleDegrees == 135)
    let screen = try #require(frame.screen)
    let height = 1080 - 2 * 0.08 * 1920  // 772.8: the height limits, padding is 153.6 px per side
    let width = height * 3024 / 1964
    #expect(abs(screen.rect.height - 772.8) < 1e-9)
    #expect(abs(screen.rect.height - height) < 1e-9)
    #expect(abs(screen.rect.width - width) < 1e-9)
    #expect(abs(screen.rect.x - (1920 - width) / 2) < 1e-9)
    #expect(abs(screen.rect.y - 153.6) < 1e-9)
    #expect(abs(screen.cornerRadius - 0.012 * 1920) < 1e-9)
}

@Test func contentRectOfAWideDisplayIsLimitedByWidth() throws {
    let e = evaluator(globalFrame: Rect(x: 0, y: 0, width: 5120, height: 1440))
    let screen = try #require(e.frame(at: 0).screen)
    let width = 1920 - 2 * 0.08 * 1920
    #expect(abs(screen.rect.width - width) < 1e-9)
    #expect(abs(screen.rect.height - width * 1440 / 5120) < 1e-9)
    #expect(abs(screen.rect.x - 153.6) < 1e-9)
    #expect(abs(screen.rect.y - (1080 - screen.rect.height) / 2) < 1e-9)
}

@Test func cursorInterpolatesBetweenSamples() throws {
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    // Given out of order, as events.jsonl may hold them.
    let e = evaluator(globalFrame: display, events: [
        cursor(0.008, x: 100, y: 540),
        cursor(0, x: 0, y: 540),
        cursor(0.200, x: 1000, y: 540),
    ])
    let rect = try #require(e.frame(at: 0).screen?.rect)
    let atStart = try #require(e.frame(at: 0).cursor)
    let halfway = try #require(e.frame(at: 0.004).cursor)
    let atSecond = try #require(e.frame(at: 0.008).cursor)
    let mapped0 = rect.x + 0 / 1920 * rect.width
    let mapped100 = rect.x + 100 / 1920 * rect.width
    #expect(abs(atStart.hotspot.x - mapped0) < 1e-9)
    #expect(abs(atSecond.hotspot.x - mapped100) < 1e-9)
    #expect(abs(halfway.hotspot.x - (mapped0 + mapped100) / 2) < 1e-9)
    #expect(abs(halfway.hotspot.y - (rect.y + rect.height / 2)) < 1e-9)
    // 8 ms and 200 ms are more than 50 ms apart: the cursor stays where it was until the next sample.
    let held = try #require(e.frame(at: 0.1).cursor)
    #expect(abs(held.hotspot.x - mapped100) < 1e-9)
}

@Test func cursorFollowsClicksAndIsHiddenBeforeTheFirstSample() throws {
    let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let e = evaluator(globalFrame: display, events: [
        InputEvent(t: base.adding(seconds: 1), kind: .mouseDown(.left, x: 960, y: 540)),
        InputEvent(t: base.adding(seconds: 2), kind: .mouseUp(.left, x: 480, y: 540)),
        InputEvent(t: base.adding(seconds: 3), kind: .marker),
    ])
    let rect = try #require(e.frame(at: 0).screen?.rect)
    #expect(e.frame(at: 0.5).cursor == nil)
    #expect(abs(try #require(e.frame(at: 1.5).cursor).hotspot.x - (rect.x + rect.width / 2)) < 1e-9)
    #expect(abs(try #require(e.frame(at: 3.5).cursor).hotspot.x - (rect.x + rect.width / 4)) < 1e-9)
}

@Test func cursorMapsOnDisplayWithNegativeOrigin() throws {
    let display = Rect(x: -1920, y: -200, width: 1920, height: 1080)
    let e = evaluator(globalFrame: display, events: [cursor(0, x: -960, y: 340)])
    let frame = e.frame(at: 0.5)
    let rect = try #require(frame.screen?.rect)
    let cursor = try #require(frame.cursor)
    #expect(abs(cursor.hotspot.x - (rect.x + rect.width / 2)) < 1e-9)
    #expect(abs(cursor.hotspot.y - (rect.y + rect.height / 2)) < 1e-9)
    #expect(abs(cursor.height - 24 * rect.height / 1080) < 1e-9)
}

@Test func cursorOutsideRecordedDisplayIsHidden() {
    let display = Rect(x: 0, y: 0, width: 1512, height: 982)
    let e = evaluator(globalFrame: display, events: [
        cursor(0, x: -500, y: 100),
        cursor(1, x: 100, y: 100),
    ])
    #expect(e.frame(at: 0.5).cursor == nil)
    #expect(e.frame(at: 1.5).cursor != nil)
}

@Test func takeWithoutGeometryShowsTheScreenWithoutCursor() throws {
    let e = evaluator(globalFrame: nil, events: [cursor(0, x: 10, y: 10)])
    let frame = e.frame(at: 1)
    let screen = try #require(frame.screen)
    #expect(abs(screen.rect.x - 153.6) < 1e-9 && abs(screen.rect.y - 153.6) < 1e-9)
    #expect(abs(screen.rect.width - (1920 - 2 * 153.6)) < 1e-9)
    #expect(frame.cursor == nil)
}

@Test func takeWithoutDisplayTrackDrawsOnlyTheBackground() {
    let take = makeTake(tracks: [])
    let e = FrameEvaluator(take: take, events: [cursor(0, x: 10, y: 10)], style: StyleV0(), outputSize: [1920, 1080])
    #expect(e.duration == 0)
    #expect(e.frame(at: 0).screen == nil)
    #expect(e.frame(at: 0).cursor == nil)
}

/// y grows down in global points and in the output alike: a cursor a quarter of the way down the display
/// is a quarter of the way down the screen's rect, on the main display and on one with a negative origin.
@Test(arguments: [
    Rect(x: 0, y: 0, width: 1920, height: 1080),
    Rect(x: -1920, y: -200, width: 1920, height: 1080),
])
func cursorKeepsItsVerticalPositionOffCentre(display: Rect) throws {
    let e = evaluator(globalFrame: display, events: [
        cursor(0, x: display.x + 0.75 * display.width, y: display.y + 0.25 * display.height),
    ])
    let frame = e.frame(at: 0.5)
    let rect = try #require(frame.screen?.rect)
    let hotspot = try #require(frame.cursor).hotspot
    #expect(abs(hotspot.x - (rect.x + 0.75 * rect.width)) < 1e-9)
    #expect(abs(hotspot.y - (rect.y + 0.25 * rect.height)) < 1e-9)
}

// MARK: - The screen shown

private let builtIn = Rect(x: 0, y: 0, width: 1512, height: 982)
private let leftDisplay = Rect(x: -1920, y: -200, width: 1920, height: 1080)

/// Display 1 (`builtIn`) and display 2 (`leftDisplay`), each with a 10 s segment unless `recorded` leaves it out.
private func twoDisplays(recorded: Set<Int> = [1, 2]) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(
            globalFrame: builtIn, segments: recorded.contains(1) ? [segment(start: base, end: base.adding(seconds: 10))] : []),
        displayTrack(
            id: "display-2", displayID: 2, globalFrame: leftDisplay,
            segments: recorded.contains(2) ? [segment(track: "display-2", start: base, end: base.adding(seconds: 10))] : []),
    ])
}

@Test func screenIsTheDisplayUnderTheFirstCursorSample() throws {
    let take = twoDisplays()
    // Out of order, as events.jsonl may hold them: the first in time is on display 2.
    let events = [cursor(1, x: 100, y: 100), cursor(0, x: -960, y: 340)]
    #expect(ScreenChoice.screenTrack(in: take, events: events)?.id == "display-2")
    let e = FrameEvaluator(take: take, events: events, style: StyleV0(), outputSize: [1920, 1080])
    let frame = e.frame(at: 0)
    #expect(frame.screen?.trackID == "display-2")
    let rect = try #require(frame.screen?.rect)
    let hotspot = try #require(frame.cursor).hotspot
    #expect(abs(hotspot.x - (rect.x + rect.width / 2)) < 1e-9)
    #expect(abs(hotspot.y - (rect.y + rect.height / 2)) < 1e-9)
    #expect(abs(rect.width / rect.height - 1920.0 / 1080) < 1e-9)
    // On display 1 later, the cursor is off the screen shown.
    #expect(e.frame(at: 1.5).cursor == nil)
    // A click counts as much as a cursor sample.
    let click = [InputEvent(t: base, kind: .mouseDown(.left, x: 10, y: 10)), cursor(0.5, x: -960, y: 340)]
    #expect(ScreenChoice.screenTrack(in: take, events: click)?.id == trackID)
}

@Test func screenFallsBackToTheFirstScreenWithoutCursorEvents() {
    let take = twoDisplays()
    #expect(ScreenChoice.screenTrack(in: take, events: [])?.id == trackID)
    #expect(ScreenChoice.screenTrack(in: take, events: [InputEvent(t: base, kind: .marker)])?.id == trackID)
    // A first cursor on neither display.
    #expect(ScreenChoice.screenTrack(in: take, events: [cursor(0, x: 5000, y: 5000), cursor(1, x: -960, y: 340)])?.id == trackID)
    let e = FrameEvaluator(take: take, events: [], style: StyleV0(), outputSize: [1920, 1080])
    #expect(e.frame(at: 0).screen?.trackID == trackID)
}

@Test func screenIsTheOnlyScreenThatRecorded() {
    // Display 1 recorded nothing: display 2 is shown even with the first cursor on display 1, and the take is not
    // left blank.
    let take = twoDisplays(recorded: [2])
    let events = [cursor(0, x: 100, y: 100)]
    #expect(ScreenChoice.screenTrack(in: take, events: events)?.id == "display-2")
    let e = FrameEvaluator(take: take, events: events, style: StyleV0(), outputSize: [1920, 1080])
    #expect(e.frame(at: 1).screen?.trackID == "display-2")
    #expect(e.duration == 10)
    // No screen recorded anything: the first screen track, as in phase 0.
    #expect(ScreenChoice.screenTrack(in: twoDisplays(recorded: []), events: events)?.id == trackID)
    let windowFirst = makeTake(tracks: [
        TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Mic"), segments: []),
        displayTrack(id: "window-7", kind: .window, globalFrame: builtIn, segments: []),
        displayTrack(globalFrame: builtIn, segments: []),
    ])
    #expect(ScreenChoice.screenTrack(in: windowFirst, events: events)?.id == "window-7")
    #expect(ScreenChoice.screenTrack(in: makeTake(tracks: []), events: events) == nil)
}

// MARK: - Area

private func areaTake(display: Rect = builtIn, area: Rect) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: display, captureArea: area, segments: [segment(start: base, end: base.adding(seconds: 10))]),
    ])
}

@Test func areaCropsTheDisplayAndKeepsTheCursorInside() throws {
    let take = areaTake(area: Rect(x: 100, y: 100, width: 800, height: 450))
    let e = FrameEvaluator(
        take: take, events: [cursor(0, x: 500, y: 325), cursor(1, x: 50, y: 50)], style: StyleV0(), outputSize: [1920, 1080])
    let frame = e.frame(at: 0.5)
    let screen = try #require(frame.screen)
    #expect(screen.crop == Rect(x: 100.0 / 1512, y: 100.0 / 982, width: 800.0 / 1512, height: 450.0 / 982))
    #expect(abs(screen.rect.width / screen.rect.height - 16.0 / 9) < 1e-9)
    #expect(abs(screen.rect.height - 772.8) < 1e-9)  // as tall as the padding allows
    // The centre of the area is the centre of the rect, and the cursor is as tall as 24 pt of the area.
    let cursor = try #require(frame.cursor)
    #expect(abs(cursor.hotspot.x - (screen.rect.x + screen.rect.width / 2)) < 1e-9)
    #expect(abs(cursor.hotspot.y - (screen.rect.y + screen.rect.height / 2)) < 1e-9)
    #expect(abs(cursor.height - 24 * screen.rect.height / 450) < 1e-9)
    // On the display but outside the area: hidden.
    #expect(e.frame(at: 1.5).cursor == nil)
    // Without an area, the whole frame.
    #expect(evaluator(globalFrame: builtIn).frame(at: 0).screen?.crop == Rect(x: 0, y: 0, width: 1, height: 1))
}

@Test func areaAtTheDisplayEdgeIsClamped() throws {
    let e = FrameEvaluator(
        take: areaTake(area: Rect(x: 1400, y: 900, width: 300, height: 200)),
        events: [cursor(0, x: 1450, y: 950), cursor(1, x: 1300, y: 950)], style: StyleV0(), outputSize: [1920, 1080])
    let screen = try #require(e.frame(at: 0.5).screen)
    let crop = screen.crop
    #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= 1 && crop.y + crop.height <= 1)
    #expect(abs(crop.x - 1400.0 / 1512) < 1e-12 && abs(crop.y - 900.0 / 982) < 1e-12)
    #expect(abs(crop.width - 112.0 / 1512) < 1e-12 && abs(crop.height - 82.0 / 982) < 1e-12)
    #expect(abs(screen.rect.width / screen.rect.height - 112.0 / 82) < 1e-9)
    #expect(e.frame(at: 0.5).cursor != nil)
    #expect(e.frame(at: 1.5).cursor == nil)  // left of the area that is on the display

    // Past the top-left corner, too.
    let topLeft = FrameEvaluator(
        take: areaTake(area: Rect(x: -100, y: -50, width: 400, height: 300)), events: [], style: StyleV0(), outputSize: [1920, 1080])
    let clamped = try #require(topLeft.frame(at: 0).screen).crop
    #expect(clamped.x == 0 && clamped.y == 0)
    #expect(abs(clamped.width - 300.0 / 1512) < 1e-12 && abs(clamped.height - 250.0 / 982) < 1e-12)

    // An area that is not on the display at all shows the whole display.
    let off = FrameEvaluator(
        take: areaTake(area: Rect(x: 2000, y: 100, width: 400, height: 300)), events: [], style: StyleV0(), outputSize: [1920, 1080])
    #expect(try #require(off.frame(at: 0).screen).crop == Rect(x: 0, y: 0, width: 1, height: 1))
}

@Test func areaCropFollowsDisplayGeometryEvents() throws {
    let events = [
        cursor(0, x: 500, y: 325),
        // Another display's geometry changes nothing here.
        InputEvent(t: base.adding(seconds: 1), kind: .displayGeometry(displayID: 2, frame: leftDisplay, scale: 1)),
        InputEvent(t: base.adding(seconds: 2), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 1800, height: 1169), scale: 2)),
    ]
    let e = FrameEvaluator(
        take: areaTake(area: Rect(x: 100, y: 100, width: 800, height: 450)), events: events, style: StyleV0(),
        outputSize: [1920, 1080])
    #expect(try #require(e.frame(at: 1).screen).crop.width == 800.0 / 1512)
    let later = e.frame(at: 3)
    let screen = try #require(later.screen)
    #expect(screen.crop.width == 800.0 / 1800)
    #expect(screen.crop.x == 100.0 / 1800)
    let hotspot = try #require(later.cursor).hotspot
    #expect(abs(hotspot.x - (screen.rect.x + screen.rect.width / 2)) < 1e-9)
    #expect(abs(hotspot.y - (screen.rect.y + screen.rect.height / 2)) < 1e-9)

    // Without an area the screen takes the display's new shape, and the cursor is placed on it.
    let resized = [
        cursor(0, x: 480, y: 270),
        InputEvent(t: base.adding(seconds: 2), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)),
    ]
    let whole = evaluator(globalFrame: builtIn, events: resized)
    let before = try #require(whole.frame(at: 1).screen?.rect)
    #expect(abs(before.width / before.height - 1512.0 / 982) < 1e-9)
    let after = whole.frame(at: 3)
    let rect = try #require(after.screen?.rect)
    #expect(abs(rect.width / rect.height - 1920.0 / 1080) < 1e-9)
    #expect(abs(try #require(after.cursor).hotspot.x - (rect.x + rect.width / 4)) < 1e-9)
}

// MARK: - Window

@Test func cursorFollowsWindowGeometryEvents() throws {
    let window = "window-7"
    let take = makeTake(tracks: [
        displayTrack(
            id: window, kind: .window, globalFrame: Rect(x: 100, y: 100, width: 800, height: 600),
            segments: [segment(track: window, start: base, end: base.adding(seconds: 10))]),
    ])
    let moved = Rect(x: 300, y: 100, width: 800, height: 600)
    let events = [
        cursor(0.5, x: 500, y: 400),
        InputEvent(t: base.adding(seconds: 1), kind: .windowGeometry(track: window, frame: moved, onScreen: true)),
        // Another window's events change nothing here.
        InputEvent(t: base.adding(seconds: 1.2), kind: .windowGeometry(track: "window-8", frame: builtIn, onScreen: false)),
        InputEvent(t: base.adding(seconds: 2), kind: .windowGeometry(track: window, frame: moved, onScreen: false)),
        InputEvent(t: base.adding(seconds: 3), kind: .windowGeometry(track: window, frame: Rect(x: 300, y: 100, width: 1200, height: 600), onScreen: true)),
    ]
    let e = FrameEvaluator(take: take, events: events, style: StyleV0(), outputSize: [1920, 1080])
    let first = e.frame(at: 0.5)
    #expect(first.screen?.trackID == window)
    let rect = try #require(first.screen?.rect)
    #expect(abs(rect.width / rect.height - 800.0 / 600) < 1e-9)
    let centre = try #require(first.cursor)
    #expect(abs(centre.hotspot.x - (rect.x + rect.width / 2)) < 1e-9)
    #expect(abs(centre.hotspot.y - (rect.y + rect.height / 2)) < 1e-9)
    #expect(abs(centre.height - 24 * rect.height / 600) < 1e-9)
    // The window moved right under the cursor that stayed put.
    let quarter = try #require(e.frame(at: 1.5).cursor)
    #expect(abs(quarter.hotspot.x - (rect.x + rect.width / 4)) < 1e-9)
    #expect(abs(quarter.hotspot.y - (rect.y + rect.height / 2)) < 1e-9)
    // Off screen: no cursor. Resized: the screen takes its new shape.
    #expect(e.frame(at: 2.5).cursor == nil)
    let wide = try #require(e.frame(at: 3.5).screen?.rect)
    #expect(abs(wide.width / wide.height - 2) < 1e-9)
    #expect(e.frame(at: 3.5).cursor != nil)
}

// MARK: - Camera

private let medium = Rect(x: 1626.24, y: 786.24, width: 259.2, height: 259.2)

/// A take of a 10 s screen and a camera from `cameraFrom` to `cameraTo` seconds.
private func cameraTake(style: CameraStyle? = nil, cameraFrom: Double = 0, cameraTo: Double = 10) -> TakeRecord {
    makeTake(
        tracks: [
            displayTrack(globalFrame: builtIn, segments: [segment(start: base, end: base.adding(seconds: 10))]),
            displayTrack(
                id: cameraID, kind: .camera, globalFrame: nil,
                segments: [segment(track: cameraID, start: base.adding(seconds: cameraFrom), end: base.adding(seconds: cameraTo))]),
        ],
        cameraStyle: style)
}

private func isClose(_ a: Rect, _ b: Rect, tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

private func styleChange(_ seconds: Double, _ style: CameraStyle) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: .cameraStyle(style))
}

@Test func takeWithoutStyleUsesTheMediumCircleBottomRight() throws {
    let e = FrameEvaluator(take: cameraTake(), events: [], style: StyleV0(), outputSize: [1920, 1080])
    let frame = e.frame(at: 1)
    let camera = try #require(frame.camera)
    #expect(camera.trackID == cameraID)
    #expect(camera.sourceTime == frame.screen?.sourceTime)
    #expect(isClose(camera.rect, medium))
    #expect(abs(camera.cornerRadius - 129.6) < 1e-9)
}

@Test func cameraUsesTheTakeInitialStyle() throws {
    let style = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
    let camera = try #require(
        FrameEvaluator(take: cameraTake(style: style), events: [], style: StyleV0(), outputSize: [1920, 1080]).frame(at: 1).camera)
    #expect(isClose(camera.rect, Rect(x: 34.56, y: 34.56, width: 244.8, height: 137.7), tolerance: 0.001))
    #expect(abs(camera.cornerRadius - 25.92) < 0.001)
}

@Test func cameraStyleEventAnimatesWithTheShapeSpring() throws {
    #expect(abs(CameraStyleTimeline.progress(seconds: 0.25) - 0.84403) < 1e-4)
    #expect(abs(CameraStyleTimeline.progress(seconds: 0.5) - 0.99378) < 1e-4)
    #expect(CameraStyleTimeline.progress(seconds: 0) == 0 && CameraStyleTimeline.progress(seconds: -1) == 0)
    #expect(CameraStyleTimeline.progress(seconds: CameraStyleTimeline.settleSeconds) == 1)
    #expect(CameraStyleTimeline.progress(seconds: 60) == 1)
    #expect(CameraStyleTimeline.damping == 0.95 && CameraStyleTimeline.response == 0.5 && CameraStyleTimeline.settleSeconds == 1.5)

    let landscape = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
    let output = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let from = CameraStyle.default.frame(in: output), to = landscape.frame(in: output)
    let e = FrameEvaluator(take: cameraTake(), events: [styleChange(2, landscape)], style: StyleV0(), outputSize: [1920, 1080])
    let atChange = try #require(e.frame(at: 2).camera)
    #expect(atChange.rect == from.rect && atChange.cornerRadius == from.cornerRadius)
    // A quarter of a second in, every value is 0.84403 of the way.
    let moving = try #require(e.frame(at: 2.25).camera)
    let p = CameraStyleTimeline.progress(seconds: 0.25)
    func along(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
    #expect(isClose(moving.rect, Rect(
        x: along(from.rect.x, to.rect.x), y: along(from.rect.y, to.rect.y),
        width: along(from.rect.width, to.rect.width), height: along(from.rect.height, to.rect.height))))
    #expect(abs(moving.cornerRadius - along(from.cornerRadius, to.cornerRadius)) < 1e-9)
    let settled = try #require(e.frame(at: 4).camera)
    #expect(settled.rect == to.rect && settled.cornerRadius == to.cornerRadius)
    // The timeline on its own, at any output size.
    let timeline = CameraStyleTimeline(initial: .default, events: [styleChange(2, landscape)])
    #expect(timeline.frame(at: base.adding(seconds: 1), output: [1920, 1080]) == from)
    #expect(timeline.frame(at: base.adding(seconds: 9), output: [1280, 720]) == landscape.frame(in: Rect(x: 0, y: 0, width: 1280, height: 720)))
}

@Test func styleTransitionStartsFromTheDisplayedRect() throws {
    let landscape = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
    let portrait = CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top)
    func evaluate(_ events: [InputEvent]) -> FrameEvaluator {
        FrameEvaluator(take: cameraTake(), events: events, style: StyleV0(), outputSize: [1920, 1080])
    }
    let once = evaluate([styleChange(2, landscape)])
    // Given out of order: the timeline sorts them.
    let twice = evaluate([styleChange(2.1, portrait), styleChange(2, landscape)])
    // The second change starts where the first one had got to: no jump.
    #expect(try #require(twice.frame(at: 2.1).camera) == (try #require(once.frame(at: 2.1).camera)))
    let output = Rect(x: 0, y: 0, width: 1920, height: 1080)
    let shown = try #require(once.frame(at: 2.1).camera)
    #expect(shown.rect != CameraStyle.default.frame(in: output).rect && shown.rect != landscape.frame(in: output).rect)
    let justAfter = try #require(twice.frame(at: 2.1005).camera)
    #expect(isClose(justAfter.rect, shown.rect, tolerance: 1))
    let settled = try #require(twice.frame(at: 4).camera)
    #expect(settled.rect == portrait.frame(in: output).rect && settled.cornerRadius == portrait.frame(in: output).cornerRadius)
}

@Test func cameraLayerAppearsOnlyAfterTheFirstCameraFrame() throws {
    let e = FrameEvaluator(take: cameraTake(cameraFrom: 1, cameraTo: 3), events: [], style: StyleV0(), outputSize: [1920, 1080])
    #expect(e.frame(at: 0.5).camera == nil)
    #expect(e.frame(at: 1).camera != nil)
    #expect(e.frame(at: 1.5).camera != nil)
    #expect(e.frame(at: 5).camera != nil)  // its last frame, after it ends
    #expect(e.duration == 10)
    // A camera recorded longer than the screen does not make the timeline longer.
    #expect(FrameEvaluator(take: cameraTake(cameraTo: 20), events: [], style: StyleV0(), outputSize: [1920, 1080]).duration == 10)
    // Without a camera segment, no camera.
    var take = cameraTake()
    take.tracks[1].segments = []
    #expect(FrameEvaluator(take: take, events: [], style: StyleV0(), outputSize: [1920, 1080]).frame(at: 1).camera == nil)
}
