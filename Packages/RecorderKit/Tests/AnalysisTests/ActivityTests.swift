// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Testing

/// The synthetic take of the tests of `Activity` and `AutoZoomPlanner`: events over a display of 1440×900 pt at the
/// origin, recorded for 60 s from `base`, in a 16:9 document whose one clip starts at `base` (so output seconds are
/// seconds after `base`), without padding (the screen fills the stage's height, 1440×900 pt on 1.6 × 1 of the stage's
/// 16/9 × 1) and with Toma's automatic zoom (`DefaultStyle.toma.zoomAuto`).
///
/// The tests that use these helpers are nested in extensions of this namespace, where they are found unqualified, so
/// other files of AnalysisTests can have helpers of their own with the same names.
enum ActivityFixtures {
    /// An arbitrary host time well after boot.
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let takeID = "take-001"
    static let screenID = "display-1"
    static let screenFrame = Rect(x: 0, y: 0, width: 1440, height: 900)

    /// The host time `seconds` after `base`.
    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    /// `seconds` of output, in nanoseconds.
    static func ns(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// A take with one screen track of `kind`, at `frame`, recorded from `base` for 60 s.
    static func makeTake(kind: TrackKind = .display, frame: Rect = screenFrame, captureArea: Rect? = nil) -> TakeRecord {
        let source = TrackSource(
            name: "Screen", displayID: kind == .display ? 1 : nil, globalFrame: frame, pixelScale: 2, captureArea: captureArea)
        let segment = SegmentRecord(
            index: 1, file: "takes/\(takeID)/\(screenID)/seg-0001.mov", startHostTime: base, endHostTime: at(60),
            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
        return TakeRecord(
            id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [TrackRecord(id: screenID, kind: kind, source: source, segments: [segment])])
    }

    /// Clip `number` over the source seconds `[from, to)` after `base`.
    static func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
        Clip(id: "c-0000000\(number)", take: takeID, start: at(from), end: at(to), speed: speed)
    }

    static func makeDocument(
        sequence: [Clip] = [clip(1, from: 0, to: 60)], aspect: Aspect = .landscape, padding: Double = 0,
        auto: AutoZoomSettings = DefaultStyle.toma.zoomAuto, regions: [ZoomRegion] = [], suppressed: [SourceRange] = []
    ) -> EditDocument {
        let toma = DefaultStyle.toma
        var style = toma.style
        style.padding = padding
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: aspect, frameRate: 60, sequence: sequence,
            screens: ScreenPlan(initial: [takeID: screenID], changes: []), style: style, cursor: toma.cursor,
            zoom: ZoomPlan(
                show: true, auto: auto, spring: toma.zoomSpring, motionBlur: toma.zoomMotionBlur, regions: regions,
                suppressed: suppressed),
            camera: CameraPlan(show: false, initial: [:], changes: []), audio: AudioPlan(limiter: true, tracks: [:]))
    }

    static func pointer(_ seconds: Double, x: Double, y: Double) -> InputEvent {
        InputEvent(t: at(seconds), kind: .cursor(x: x, y: y))
    }

    /// A click at (`x`, `y`) `seconds` after `base`: the button goes down, and up 50 ms later.
    static func click(_ seconds: Double, x: Double, y: Double, button: MouseButton = .left) -> [InputEvent] {
        [
            InputEvent(t: at(seconds), kind: .mouseDown(button, x: x, y: y)),
            InputEvent(t: at(seconds + 0.05), kind: .mouseUp(button, x: x, y: y)),
        ]
    }

    /// A left drag in a straight line from `from` to `to` between those seconds: down, the pointer every 1/60 s, up.
    static func drag(_ start: Double, _ end: Double, from: SIMD2<Double>, to: SIMD2<Double>) -> [InputEvent] {
        let steps = max(1, Int(((end - start) * 60).rounded()))
        var events = [InputEvent(t: at(start), kind: .mouseDown(.left, x: from.x, y: from.y))]
        for step in 1..<steps {
            let p = from + (to - from) * (Double(step) / Double(steps))
            events.append(pointer(start + (end - start) * Double(step) / Double(steps), x: p.x, y: p.y))
        }
        events.append(InputEvent(t: at(end), kind: .mouseUp(.left, x: to.x, y: to.y)))
        return events
    }

    /// `keyActivity` every `every` seconds from `from` to `to`, both included.
    static func keys(from: Double, to: Double, every: Double = 0.25) -> [InputEvent] {
        let count = Int(((to - from) / every).rounded())
        return (0...count).map { InputEvent(t: at(from + Double($0) * every), kind: .keyActivity) }
    }

    /// A `scroll` with the pointer at (`x`, `y`).
    static func scroll(_ seconds: Double, x: Double = 720, y: Double = 450) -> InputEvent {
        InputEvent(t: at(seconds), kind: .scroll(dx: 0, dy: -12, x: x, y: y))
    }

    static func activity(_ events: [InputEvent], take: TakeRecord = makeTake(), document: EditDocument = makeDocument()) -> Activity {
        Activity.extract(take: take, events: events, document: document, timeMap: TimeMap(sequence: document.sequence))
    }

    /// Whether `a` and `b` are within `tolerance` of each other on each axis.
    static func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}

extension ActivityFixtures {
    @Suite struct ActivityTests {
        // MARK: - Stage points

        @Test func stagePointsPlaceTheScreenInsideThePadding() throws {
            // 16:9 stage of 16/9 × 1 with 8 % of its width of padding: 1.4933 × 0.7156 of room, where a 1.6:1 screen
            // fits by its height.
            let stage = StagePoints(take: makeTake(), events: [], document: makeDocument(padding: 0.08))
            #expect(stage.stageSize == SIMD2(16.0 / 9, 1))
            let margin = 0.08 * 16 / 9
            let height = 1 - 2 * margin, width = height * 1.6
            let rect = try #require(stage.screenRect(at: at(1)))
            #expect(abs(rect.height - height) < 1e-12 && abs(rect.width - width) < 1e-12)
            #expect(abs(rect.x - (16.0 / 9 - width) / 2) < 1e-12 && abs(rect.y - margin) < 1e-12)
            // The screen's centre is the stage's; its top-left corner is the rect's.
            #expect(near(try #require(stage.stagePoint(global: SIMD2(720, 450), at: at(1))), SIMD2(16.0 / 18, 0.5)))
            #expect(near(try #require(stage.stagePoint(global: SIMD2(0, 0), at: at(1))), SIMD2(rect.x, rect.y)))
            // Off the screen (its far edges are out, as for the drawn cursor): nothing.
            #expect(stage.stagePoint(global: SIMD2(1440, 450), at: at(1)) == nil)
            #expect(stage.stagePoint(global: SIMD2(-1, 450), at: at(1)) == nil)
        }

        @Test func stagePointsAreNilOffTheAreaAndWhileAWindowIsOffScreen() throws {
            // An area of the display: only the area is shown, and it fills the stage's height without padding.
            let area = Rect(x: 100, y: 100, width: 800, height: 450)
            let areaStage = StagePoints(take: makeTake(captureArea: area), events: [], document: makeDocument())
            #expect(areaStage.stagePoint(global: SIMD2(1200, 800), at: at(1)) == nil)
            #expect(near(try #require(areaStage.stagePoint(global: SIMD2(500, 325), at: at(1))), SIMD2(16.0 / 18, 0.5)))
            // A window that goes off screen at 2 s: its points are shown before, not after; its rect is still drawn.
            let window = makeTake(kind: .window, frame: Rect(x: 100, y: 100, width: 800, height: 600))
            let hidden = InputEvent(
                t: at(2), kind: .windowGeometry(track: screenID, frame: Rect(x: 100, y: 100, width: 800, height: 600), onScreen: false))
            let windowStage = StagePoints(take: window, events: [hidden], document: makeDocument())
            #expect(windowStage.stagePoint(global: SIMD2(500, 400), at: at(1)) != nil)
            #expect(windowStage.stagePoint(global: SIMD2(500, 400), at: at(3)) == nil)
            #expect(windowStage.screenRect(at: at(3)) != nil)
            // A screen the take does not have: nothing at all.
            var other = makeDocument()
            other.screens.initial = [takeID: "display-9"]
            let missing = StagePoints(take: makeTake(), events: [], document: other)
            #expect(missing.screenRect(at: at(1)) == nil && missing.stagePoint(global: SIMD2(720, 450), at: at(1)) == nil)
        }

        @Test func framedStageRectIsTheWholeWindow() throws {
            // With a macOS window around the screen, the screen's rect is the whole window, bar included, as the render
            // places it in a 1920 × 1080 output (where the bar's 18 px floor is of output pixels), in stage units:
            // pixels / 1080.
            var document = makeDocument(padding: 0.08)
            document.style.frame = .macWindow(appearance: .dark, title: "Demo", buttons: true)
            let stage = StagePoints(take: makeTake(), events: [], document: document)
            let layout = StageLayout.windowRect(contentAspect: 1.6, padding: 0.08, outputSize: [1920, 1080])
            let window = try #require(stage.screenRect(at: at(1)))
            let expected = layout.window
            #expect(near(SIMD2(window.x, window.y), SIMD2(expected.x, expected.y) / 1080, 1e-12), "\(window)")
            #expect(near(SIMD2(window.width, window.height), SIMD2(expected.width, expected.height) / 1080, 1e-12), "\(window)")
            #expect(window.height > window.width / 1.6 + 0.03)
            // A click at the screen's top-left corner falls under the bar; one at its centre, at the centre of the screen.
            let bar = layout.barHeight / 1080
            #expect(near(try #require(stage.stagePoint(global: SIMD2(0, 0), at: at(1))), SIMD2(window.x, window.y + bar), 1e-12))
            let screen = layout.screen
            let centre = SIMD2(screen.x + screen.width / 2, screen.y + screen.height / 2) / 1080
            #expect(near(try #require(stage.stagePoint(global: SIMD2(720, 450), at: at(1))), centre, 1e-12))
            #expect(stage.stagePoint(global: SIMD2(1440, 450), at: at(1)) == nil)
        }

        // MARK: - Activity

        @Test func doubleClickIsOneClick() {
            let double = activity(click(5.0, x: 700, y: 450) + click(5.2, x: 703, y: 450))
            #expect(double.clicks.count == 1)
            #expect(double.clicks.first?.output == ns(5))
            #expect(double.clicks.first?.host == at(5))
            // A triple click is one too; 0.4 s later, or 6 pt away, it is another click.
            #expect(activity(click(5.0, x: 700, y: 450) + click(5.2, x: 702, y: 450) + click(5.4, x: 704, y: 450)).clicks.count == 1)
            #expect(activity(click(5.0, x: 700, y: 450) + click(5.4, x: 700, y: 450)).clicks.count == 2)
            #expect(activity(click(5.0, x: 700, y: 450) + click(5.2, x: 706, y: 450)).clicks.count == 2)
            // Right clicks count; other buttons do not.
            #expect(activity(click(5.0, x: 700, y: 450, button: .right)).clicks.count == 1)
            #expect(activity(click(5.0, x: 700, y: 450, button: .other)).clicks.isEmpty)
        }

        @Test func aDragIsNotAClick() throws {
            let dragged = activity(drag(5, 6, from: SIMD2(400, 300), to: SIMD2(600, 450)))
            #expect(dragged.clicks.isEmpty)
            #expect(dragged.drags.count == 1)
            let one = try #require(dragged.drags.first)
            #expect(one.start == ns(5) && one.end == ns(6))
            // Its box, in stage units (the screen is 1.6 × 1 from x = (16/9 − 1.6) / 2): 200 × 150 pt of 1440 × 900.
            let left = (16.0 / 9 - 1.6) / 2
            #expect(abs(one.box.x - (left + 400.0 / 900)) < 1e-12 && abs(one.box.y - 300.0 / 900) < 1e-12)
            #expect(abs(one.box.width - 200.0 / 900) < 1e-12 && abs(one.box.height - 150.0 / 900) < 1e-12)
            // Going 8 pt or less from where it went down is a click.
            let wobble = activity(drag(5, 5.2, from: SIMD2(400, 300), to: SIMD2(408, 300)))
            #expect(wobble.drags.isEmpty && wobble.clicks.count == 1)
        }

        @Test func typingAndScrollAreSpans() {
            let typed = activity(keys(from: 6, to: 8) + keys(from: 9, to: 9.5) + keys(from: 11, to: 11))
            // 8 → 9 is 1.0 s: the same span; 9.5 → 11 is not.
            #expect(typed.typing == [ns(6)..<ns(9.75), ns(11)..<ns(11.25)])
            let scrolled = activity([scroll(2), scroll(2.4), scroll(2.9), scroll(4), scroll(4.6), scroll(30, x: 2000, y: 450)])
            // 2.4 → 2.9 is 0.5 s: the same span; one off the screen does not count.
            #expect(scrolled.scrolls == [ns(2)..<ns(2.9), ns(4)..<ns(4), ns(4.6)..<ns(4.6)])
        }

        /// 100 pt in 25 steps of 4 pt from 2 s, still from 2.5 s until a step of 50 pt, and the output ends 0.5 s after
        /// that step (a cursor that stops for good before the end also pauses).
        private func pauses(stillFor: Double, travel: Double = 100, from x: Double = 500, with extra: [InputEvent] = [])
            -> [Activity.Click]
        {
            let steps = Int(travel / 4)
            let moving = (0...steps).map { pointer(2 + 0.5 * Double($0) / Double(steps), x: x + 4 * Double($0), y: 400) }
            let events = moving + [pointer(2.5 + stillFor, x: x + travel + 50, y: 400)] + extra
            return activity(events, document: makeDocument(sequence: [clip(1, from: 0, to: 3 + stillFor)])).pauses
        }

        @Test func pauseNeedsTravelStillnessAndNoClick() {
            let paused = pauses(stillFor: 1.5)
            #expect(paused.count == 1)
            #expect(paused.first?.output == ns(2.5))
            #expect(paused.first?.host == at(2.5))
            #expect(paused.first.map { near($0.point, SIMD2((16.0 / 9 - 1.6) / 2 + 600.0 / 900, 400.0 / 900)) } == true)
            // Still for less than 1.2 s, after less than 80 pt, or with a click less than 1 s away: no pause.
            #expect(pauses(stillFor: 1.1).isEmpty)
            #expect(pauses(stillFor: 1.5, travel: 76).isEmpty)
            #expect(pauses(stillFor: 1.5, with: click(3.4, x: 600, y: 400)).isEmpty)
            #expect(pauses(stillFor: 1.5, with: click(1.4, x: 300, y: 400)).count == 1)
            // A jitter of 1 pt while it stands still is still standing still, and makes no other pause.
            let jitter = (1...80).map { pointer(2.5 + Double($0) / 60, x: 600 + Double($0 % 2), y: 400) }
            #expect(pauses(stillFor: 1.5, with: jitter).map(\.output) == [ns(2.5)])
            // Stopping off the screen is no pause.
            #expect(pauses(stillFor: 1.5, from: 1400).isEmpty)
        }

        @Test func aClickExactlyOneSecondAwayLeavesThePause() {
            // The cursor stops at 2.5 s: a click 1 s before or after it is not "less than 1 s" away; 1 ns closer, it is.
            #expect(pauses(stillFor: 1.5, with: click(3.5, x: 600, y: 400)).map(\.output) == [ns(2.5)])
            #expect(pauses(stillFor: 1.5, with: click(3.499_999_999, x: 600, y: 400)).isEmpty)
            #expect(pauses(stillFor: 1.5, with: click(1.5, x: 300, y: 400)).map(\.output) == [ns(2.5)])
            #expect(pauses(stillFor: 1.5, with: click(1.500_000_001, x: 300, y: 400)).isEmpty)
        }

        @Test func activityIsInOutputTimeAndOnlyWhatIsKept() {
            // [0, 10) s at 1× and [20, 40) s at 2×: source 25 s is output 10 + 2.5 s; 15 s is cut.
            let document = makeDocument(sequence: [clip(1, from: 0, to: 10), clip(2, from: 20, to: 40, speed: 2)])
            let found = activity(click(15, x: 700, y: 450) + click(25, x: 700, y: 450) + keys(from: 14, to: 21), document: document)
            #expect(found.clicks.map(\.output) == [ns(12.5)])
            #expect(found.clicks.map(\.host) == [at(25)])
            // The keys of 20 to 21 s are 10 to 10.5 s of output.
            #expect(found.typing == [ns(10)..<ns(10.75)])
        }

        @Test func belowOneTimesActivityIsSlower() {
            // At 0.5×, source 5 s is output 10 s, and typing every 0.25 s of source is every 0.5 s of output: still one
            // span (≤ 1.0 s apart), with its 0.25 s tail in output time.
            let document = makeDocument(sequence: [clip(1, from: 0, to: 60, speed: 0.5)])
            let found = activity(click(5, x: 700, y: 450) + keys(from: 6, to: 7), document: document)
            #expect(found.clicks.map(\.output) == [ns(10)])
            #expect(found.typing == [ns(12)..<ns(14.25)])
            // 0.2 s of source apart is 0.4 s of output: no longer one double click.
            #expect(activity(click(5.0, x: 700, y: 450) + click(5.2, x: 702, y: 450), document: document).clicks.count == 2)
        }
    }
}
