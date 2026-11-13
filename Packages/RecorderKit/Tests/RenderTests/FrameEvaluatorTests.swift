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
