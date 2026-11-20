// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The automatic zoom with the keyboard's focus, `focusZoom-1` (fases 4 y 5 design §5.2), over the synthetic take of
// `ActivityFixtures`: a display of 1440×900 pt at the origin, a 16:9 stage without padding (the screen is 1.6 × 1 of its
// 16/9 × 1, 1 pt is 1/900 of the stage's height) and Toma's settings (depth 2, groups up to 2.5 s apart, 0.5 s before and
// 1.0 s after, `follow` on); `followsFocus` on unless a test says otherwise. Its one clip is the take's first 60 s, so
// output seconds are seconds after `base`.

extension ActivityFixtures {
    @Suite struct FocusZoomTests {
        /// Toma's settings with `followsFocus` on and `change` applied.
        private func settings(_ change: (inout AutoZoomSettings) -> Void = { _ in }) -> AutoZoomSettings {
            var auto = DefaultStyle.toma.zoomAuto
            auto.followsFocus = true
            change(&auto)
            return auto
        }

        private func plan(_ events: [InputEvent], document: EditDocument? = nil) -> [ZoomRegion] {
            AutoZoomPlanner.plan(take: makeTake(), events: events, document: document ?? makeDocument(auto: settings()))
        }

        private func plan(_ events: [InputEvent], auto: AutoZoomSettings) -> [ZoomRegion] {
            plan(events, document: makeDocument(auto: auto))
        }

        /// The source spans of `regions`, in seconds after `base`.
        private func spans(_ regions: [ZoomRegion]) -> [ClosedRange<Double>] {
            regions.map { Double($0.start.nanoseconds - base.nanoseconds) / 1e9...Double($0.end.nanoseconds - base.nanoseconds) / 1e9 }
        }

        /// Whether `focus` is fixed at (`x`, `y`), within 1e-9.
        private func isFixed(_ focus: ZoomFocus, at x: Double, _ y: Double) -> Bool {
            guard case let .fixed(fx, fy) = focus else { return false }
            return abs(fx - x) < 1e-9 && abs(fy - y) < 1e-9
        }

        /// The focused element at (`x`, `y`), `width` × `height` pt, from `seconds` on.
        private func element(_ seconds: Double, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> InputEvent {
            InputEvent(t: at(seconds), kind: .focus(x: x, y: y, width: width, height: height, kind: .element))
        }

        /// The text cursor at (`x`, `y`), 0 × `height` pt, from `seconds` on.
        private func caret(_ seconds: Double, _ x: Double, _ y: Double, height: Double = 18) -> InputEvent {
            InputEvent(t: at(seconds), kind: .focus(x: x, y: y, width: 0, height: height, kind: .caret))
        }

        /// `count` text cursors every 0.1 s from `from`, the `k`-th at `place(k)`.
        private func carets(from: Double, count: Int, _ place: (Int) -> SIMD2<Double>) -> [InputEvent] {
            (0..<count).map { k in
                let point = place(k)
                return caret(from + 0.1 * Double(k), point.x, point.y)
            }
        }

        /// The focus where the take starts, far from everything: the state, never a change.
        private var state: [InputEvent] { [element(0.2, 1000, 820, 240, 30)] }

        /// Typing from 5.0 to 6.0 s (a span to 6.25 s) with ten text cursors from 5.05 s, 9 pt apart from (300, 200).
        private var typedLine: [InputEvent] {
            keys(from: 5.0, to: 6.0) + carets(from: 5.05, count: 10) { SIMD2(300 + 9 * Double($0), 200) }
        }

        // MARK: - Nothing changes without it

        /// The scripts of `AutoZoomPlannerTests`: clicks, drags, pauses of the cursor, typing and scrolling.
        private var scripts: [[InputEvent]] {
            let pause = (0...25).map { pointer(2 + 0.5 * Double($0) / 25, x: 500 + 4 * Double($0), y: 400) } + [pointer(4, x: 650, y: 400)]
            let everything = click(3, x: 200, y: 200) + click(4, x: 1300, y: 800) + drag(10, 11, from: SIMD2(300, 300), to: SIMD2(700, 500))
                + keys(from: 11.5, to: 15) + click(20, x: 700, y: 450) + [pointer(22, x: 705, y: 450)] + keys(from: 28, to: 29)
                + (0...25).map { pointer(40 + 0.5 * Double($0) / 25, x: 100 + 4 * Double($0), y: 600) } + [pointer(42, x: 260, y: 600)]
                + stride(from: 33.0, through: 34.0, by: 0.1).map { scroll($0) } + click(32, x: 900, y: 300)
            return [
                click(5, x: 720, y: 450),
                click(5, x: 700, y: 450) + click(6, x: 720, y: 460) + click(7.5, x: 710, y: 440),
                click(5, x: 20, y: 20) + click(6, x: 1420, y: 880),
                drag(5, 6, from: SIMD2(400, 180), to: SIMD2(600, 720)),
                click(5, x: 720, y: 450) + keys(from: 6.0, to: 12.0),
                click(12, x: 700, y: 450) + [pointer(15, x: 710, y: 450)] + keys(from: 20, to: 20.5),
                click(5, x: 720, y: 450) + stride(from: 6.0, through: 6.5, by: 0.1).map { scroll($0) },
                pause,
                everything,
            ]
        }

        /// Focus all along the first 50 s: a field every 3.7 s, somewhere else each time, and the text cursor every 0.1 s.
        private var focusAllAlong: [InputEvent] {
            let fields = (0..<14).map { k in element(0.2 + 3.7 * Double(k), 100 + 83 * Double(k), 120 + 47 * Double(k), 240, 30) }
            return fields + carets(from: 0.05, count: 500) { k in SIMD2(300 + 9 * Double(k % 40), 200 + 31 * Double(k / 40)) }
        }

        @Test func focusChangesNothingWithFollowsFocusOff() {
            let off = [
                settings { $0.followsFocus = false },
                settings { $0.followsFocus = false; $0.triggers = .clicksAndPauses },
                settings { $0.followsFocus = false; $0.follow = false },
                settings { $0.followsFocus = false; $0.holdWhileTyping = false },
            ]
            var followed = 0
            for (index, script) in scripts.enumerated() {
                for auto in off {
                    let without = plan(script, auto: auto)
                    #expect(plan(script + focusAllAlong, auto: auto) == without, "script \(index)")
                    // Mixed in among the events, in any order.
                    #expect(plan((script + focusAllAlong).reversed(), auto: auto) == without, "script \(index), reversed")
                }
                if plan(script + focusAllAlong, auto: settings()) != plan(script, auto: settings()) { followed += 1 }
            }
            // The same focus does change them with `followsFocus` on.
            #expect(followed == scripts.count)
        }

        // MARK: - Typing

        @Test func typingWithACaretZoomsOnTheCaret() {
            let regions = plan(state + typedLine)
            let expected = ZoomRegion(
                id: AutoZoomPlanner.regionID(take: takeID, start: at(4.55), end: at(7.25)), take: takeID, start: at(4.55), end: at(7.25),
                origin: .auto, depth: nil, focus: .fixed(x: 300.0 / 1440, y: 209.0 / 900), instant: false)
            #expect(regions.count == 1)
            #expect(spans(regions) == [4.55...7.25])
            #expect(regions.first.map { isFixed($0.focus, at: 300.0 / 1440, 209.0 / 900) } == true)
            #expect(regions.first.map { region in
                var region = region
                region.focus = expected.focus
                return region
            } == expected)
        }

        @Test func caretBlocksDoNotNeedHoldWhileTyping() {
            let auto = settings { $0.holdWhileTyping = false }
            #expect(spans(plan(state + typedLine, auto: auto)) == [4.55...7.25])
            #expect(plan(state + typedLine, auto: auto) == plan(state + typedLine))
            // A span without text cursors makes nothing, as without the focus.
            #expect(plan(state + keys(from: 5.0, to: 6.0), auto: auto).isEmpty)
            #expect(plan(state + keys(from: 5.0, to: 6.0)).isEmpty)
        }

        @Test func caretJumpsLineOnlyWhenItLeavesTheView() {
            let line = keys(from: 5.0, to: 6.0) + carets(from: 5.05, count: 5) { SIMD2(300 + 9 * Double($0), 200) }
            // 100 pt lower, it is still in the view (at 2×, the crop at the top of the screen and 12 % of it, 54 pt, in
            // from its bottom, at 396 pt): one block.
            let below = line + carets(from: 5.55, count: 5) { SIMD2(345 + 9 * Double($0), 300) }
            #expect(spans(plan(state + below)) == [4.55...7.25])
            // At 650 pt it leaves the view: the block is cut where that cursor comes, and another starts there, fixed on it.
            let lower = line + carets(from: 5.55, count: 5) { SIMD2(345 + 9 * Double($0), 650) }
            let jumped = plan(state + lower)
            #expect(spans(jumped) == [4.55...5.55, 5.55...7.25])
            #expect(jumped.first?.end == jumped.last?.start)
            #expect(jumped.first.map { isFixed($0.focus, at: 300.0 / 1440, 209.0 / 900) } == true)
            #expect(jumped.last.map { isFixed($0.focus, at: 345.0 / 1440, 659.0 / 900) } == true)
            #expect(jumped.allSatisfy { $0.depth == nil && $0.origin == .auto })
        }

        @Test func atTheScreensEdgeTheViewIsTheCropPlacedThere() {
            // The cursor at x = 10: the crop of 2× is placed at the screen's left edge (800 pt wide, from 0), where no
            // margin is left out, so typing on along the line never leaves it.
            let typing = keys(from: 5.0, to: 6.0)
            let edge = typing + carets(from: 5.05, count: 10) { SIMD2(10 + 9 * Double($0), 200) }
            #expect(spans(plan(state + edge)) == [4.55...7.25])
            // 100 pt to the right is in it, and so is 400 pt, which a crop centred on the cursor would not show.
            #expect(spans(plan(state + typing + [caret(5.05, 10, 200), caret(5.15, 110, 200)])) == [4.55...7.25])
            #expect(spans(plan(state + typing + [caret(5.05, 10, 200), caret(5.15, 410, 200)])) == [4.55...7.25])
            // 12 % of the crop in from its right edge, at 704 pt, it leaves it.
            #expect(spans(plan(state + typing + [caret(5.05, 10, 200), caret(5.15, 710, 200)])) == [4.55...5.15, 5.15...7.25])
            // The same at the top of the screen.
            let top = typing + carets(from: 5.05, count: 10) { SIMD2(300 + 9 * Double($0), 2) }
            #expect(spans(plan(state + top)) == [4.55...7.25])
        }

        @Test func typingWithoutACaretIsAsBefore() {
            let scripts = [
                click(5, x: 720, y: 450) + keys(from: 6.0, to: 12.0),
                click(12, x: 700, y: 450) + [pointer(15, x: 710, y: 450)] + keys(from: 20, to: 20.5),
            ]
            for script in scripts {
                let off = plan(state + script, auto: settings { $0.followsFocus = false })
                #expect(!off.isEmpty)
                #expect(plan(state + script) == off)
                #expect(plan(state + script, auto: settings { $0.follow = false }) == plan(state + script, auto: settings { $0.follow = false; $0.followsFocus = false }))
            }
        }

        @Test func aTypingSpanWithCaretsHoldsNoGroup() {
            let events = state + click(2, x: 200, y: 200) + keys(from: 2.5, to: 4.0)
                + carets(from: 2.6, count: 14) { SIMD2(1100 + 9 * Double($0), 700) }
            // Without the focus the typing holds the click's block to 1.0 s after it, 5.25 s.
            #expect(spans(plan(events, auto: settings { $0.followsFocus = false })) == [1.5...5.25])
            // With it, the click's block ends 1.0 s after the click (3.0 s), and the cursor's starts 0.5 s before it
            // (2.1 s): they meet halfway between the click and the first cursor.
            let regions = plan(events)
            #expect(spans(regions) == [1.5...2.3, 2.3...5.25])
            #expect(regions.first?.focus == .follow)
            #expect(regions.last.map { isFixed($0.focus, at: 1100.0 / 1440, 709.0 / 900) } == true)
        }

        // MARK: - Changes of the focused element

        @Test func aStableElementReachedByKeyboardZooms() throws {
            let events = state + [element(4, 600, 300, 240, 30), element(6, 100, 700, 240, 30)]
            let regions = plan(events)
            // Too far apart to be one: they meet halfway, at 5 s.
            #expect(spans(regions) == [3.5...5.0, 5.0...7.0])
            let first = try #require(regions.first)
            #expect(isFixed(first.focus, at: 720.0 / 1440, 315.0 / 900))
            // 240 × 30 pt fits at 2×: the setting's depth.
            #expect(first.depth == nil)
            #expect(regions.last.map { isFixed($0.focus, at: 220.0 / 1440, 715.0 / 900) } == true)
            // At 4×, a field of 20 × 20 pt zooms 2.5× at most.
            let deep = plan(state + [element(4, 700, 440, 20, 20)], auto: settings { $0.depth = 4 })
            #expect(spans(deep) == [3.5...5.0])
            #expect(deep.map(\.depth) == [2.5])
            // A wide one zooms as deep as fits it, below 2.5×: 900 pt is 1 of the stage, 0.76 / 1 with its margin.
            let wide = plan(state + [element(4, 200, 300, 900, 30)], auto: settings { $0.depth = 4 })
            #expect(wide.count == 1)
            #expect(wide.first?.depth.map { abs($0 - 0.76 * 16 / 9) < 1e-9 } == true)
        }

        /// What makes an element no change (plan decision 9).
        enum NotAChange: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case firstOfTheTake, firstAfterResuming, afterALeftClick, afterARightClick, followedByAnother, wider, taller, notShown
            case insideACaretRun

            var testDescription: String { rawValue }
        }

        @Test(arguments: NotAChange.allCases)
        func elementsThatAreNotChangesMakeNothing(_ reason: NotAChange) {
            let field = element(4, 600, 300, 240, 30)
            /// The events before the element, and what it may add to them.
            let before: [InputEvent]
            var change = [field]
            switch reason {
            case .firstOfTheTake:
                before = []
            case .firstAfterResuming:
                before = state + [InputEvent(t: at(2), kind: .paused(reason: "user")), InputEvent(t: at(3.9), kind: .resumed)]
            case .afterALeftClick:
                before = state + click(3.7, x: 1200, y: 100)
            case .afterARightClick:
                before = state + click(3.7, x: 1200, y: 100, button: .right)
            case .followedByAnother:
                // Only the second counts: it is stable.
                let second = element(4.3, 100, 700, 240, 30)
                before = state + [second]
                change = [field]
                #expect(plan(state + [second]).count == 1)
            case .wider:
                before = state
                change = [element(4, 100, 300, 1020, 30)]
                // Just 70 % of the screen is not more than it: it zooms.
                #expect(plan(state + [element(4, 100, 300, 1008, 30)]).count == 1)
            case .taller:
                before = state
                change = [element(4, 600, 50, 240, 640)]
            case .notShown:
                before = state
                change = [element(4, 1500, 300, 240, 30)]
            case .insideACaretRun:
                before = state + keys(from: 3.0, to: 6.0) + carets(from: 3.05, count: 30) { SIMD2(300 + 9 * Double($0 % 10), 200) }
            }
            #expect(plan(before + change) == plan(before), "\(reason)")
            // Never as a block of its own.
            #expect(plan(before + change).allSatisfy { !isFixed($0.focus, at: 720.0 / 1440, 315.0 / 900) })
        }

        @Test func focusBlocksGroupWithClicks() throws {
            // A click and, 1 s after it, a field next to it: one block, which follows the cursor (`follow`) and zooms
            // 2.5× at most at 4×.
            let both = state + click(5, x: 600, y: 300) + [element(6, 620, 310, 100, 30)]
            let deep = plan(both, auto: settings { $0.depth = 4 })
            #expect(spans(deep) == [4.5...7.0])
            #expect(deep.map(\.focus) == [.follow])
            #expect(deep.map(\.depth) == [2.5])
            // At 2×, the setting's depth.
            #expect(plan(both).map(\.depth) == [nil])
            // Two fields alone are fixed on their box, `follow` on and all.
            let fields = state + [element(5, 600, 300, 100, 30), element(6, 720, 300, 100, 30)]
            let fixed = plan(fields)
            #expect(spans(fixed) == [4.5...7.0])
            #expect(fixed.first.map { isFixed($0.focus, at: 710.0 / 1440, 315.0 / 900) } == true)
            // Two fields 1 s apart whose blocks are neighbours that fit together: one, still fixed.
            let neighbours = plan(fields, auto: settings { $0.groupGap = 0.5 })
            #expect(spans(neighbours) == [4.5...7.0])
            #expect(neighbours.first.map { isFixed($0.focus, at: 710.0 / 1440, 315.0 / 900) } == true)
            // A field and a click that are neighbours, as one: it follows the cursor.
            let mixed = plan(state + [element(5, 600, 300, 100, 30)] + click(6, x: 700, y: 310), auto: settings { $0.groupGap = 0.5 })
            #expect(spans(mixed) == [4.5...7.0])
            #expect(mixed.map(\.focus) == [.follow])

            // Following the cursor (`reframe-1`), every block follows it: the text cursor's, the fields' and the clicks'.
            var reframed = makeDocument(aspect: .portrait, auto: settings())
            reframed.style.reframe = .followCursor
            let fitted = makeDocument(aspect: .portrait, auto: settings())
            let events = state + typedLine + [element(12, 600, 300, 100, 30)] + click(20, x: 600, y: 300)
            let following = plan(events, document: reframed)
            #expect(following.count == 3)
            #expect(following.allSatisfy { $0.focus == .follow })
            let placed = plan(events, document: fitted)
            #expect(placed.map(\.id) == following.map(\.id))
            #expect(placed.filter { $0.focus != .follow }.count == 2)
        }

        @Test func userBlocksAndSuppressedWinOverFocus() {
            let user = ZoomRegion(
                id: "z-00000001", take: takeID, start: at(6), end: at(9), origin: .user, depth: 1.6, focus: .follow, instant: false)
            func planned(_ events: [InputEvent], regions: [ZoomRegion] = [], suppressed: [SourceRange] = []) -> [ClosedRange<Double>] {
                spans(plan(events, document: makeDocument(auto: settings(), regions: regions, suppressed: suppressed)))
            }
            // The text cursor's block keeps what the user's leaves free.
            #expect(planned(state + typedLine) == [4.55...7.25])
            #expect(planned(state + typedLine, regions: [user]) == [4.55...6.0])
            // Half of it or more deleted: none.
            #expect(planned(state + typedLine, suppressed: [SourceRange(take: takeID, start: at(4.5), end: at(6.5))]).isEmpty)
            // A field's the same.
            let field = state + [element(5, 600, 300, 240, 30)]
            #expect(planned(field) == [4.5...6.0])
            // A user's block from 5 s leaves it 0.5 s free: none.
            var later = user
            later.start = at(5)
            #expect(planned(field, regions: [later]).isEmpty)
            #expect(planned(field, suppressed: [SourceRange(take: takeID, start: at(4.5), end: at(5.5))]).isEmpty)
            // Cut out of the sequence: nothing of it.
            let cut = makeDocument(sequence: [clip(1, from: 0, to: 4), clip(2, from: 8, to: 60)], auto: settings())
            #expect(plan(field + typedLine, document: cut).isEmpty)
        }

        @Test func sameFocusSameBlocksAndIDs() {
            let events = state + typedLine + [element(12, 600, 300, 240, 30)] + click(20, x: 700, y: 450)
                + keys(from: 25, to: 27) + carets(from: 25.05, count: 20) { SIMD2(200 + 9 * Double($0 % 10), $0 < 10 ? 100 : 700) }
                + [element(31, 100, 700, 240, 30), element(31.2, 300, 700, 240, 30)]
            let first = plan(events)
            #expect(first == plan(events.reversed()))
            #expect(spans(first) == [4.55...7.25, 11.5...13.0, 19.5...21.0, 24.55...26.05, 26.05...28.25, 30.7...32.2])
            for region in first {
                #expect(region.id == AutoZoomPlanner.regionID(take: takeID, start: region.start, end: region.end))
                #expect(region.origin == .auto)
            }
        }

        @Test func focusZoomIDIsFrozen() {
            #expect(FocusZoom.id == "focusZoom-1")
            #expect(FocusZoom.stableDuration == 400_000_000)
            #expect(FocusZoom.clickClearance == 500_000_000)
            #expect(FocusZoom.largestFraction == 0.7)
            #expect(FocusZoom.maximumDepth == 2.5)
            // The blocks keep the ids of `autoZoom-1`.
            #expect(AutoZoomPlanner.id == "autoZoom-1")
        }

        // MARK: - The activity

        @Test func activityHasTheCaretRunsAndTheChanges() throws {
            let events = state + typedLine + [caret(8, 300, 200), element(12, 600, 300, 240, 30)]
            let found = activity(events)
            // Only the text cursors in a span of typing, in output order and on the stage.
            let run = try #require(found.caretRuns.first)
            #expect(found.caretRuns.count == 1)
            #expect(run.span == ns(5)..<ns(6.25))
            #expect(run.carets.map(\.output) == (0..<10).map { ns(5.05 + 0.1 * Double($0)) })
            #expect(run.carets.map(\.host) == (0..<10).map { at(5.05 + 0.1 * Double($0)) })
            let origin = (16.0 / 9 - 1.6) / 2
            let box = try #require(run.carets.first?.box)
            #expect(abs(box.x - (origin + 300.0 / 900)) < 1e-12 && abs(box.y - 200.0 / 900) < 1e-12)
            #expect(box.width == 0 && abs(box.height - 18.0 / 900) < 1e-12)
            // The state is no change; the field at 12 s is one.
            #expect(found.focusChanges.map(\.output) == [ns(12)])
            #expect(found.focusChanges.map(\.host) == [at(12)])
            #expect(found.focusChanges.first.map { abs($0.box.width - 240.0 / 900) < 1e-12 } == true)
            // Without the focus, none.
            let plain = activity(keys(from: 5.0, to: 6.0))
            #expect(plain.caretRuns.isEmpty && plain.focusChanges.isEmpty)
        }

        @Test func stageRectIsCutToWhatIsShown() throws {
            let stage = StagePoints(take: makeTake(captureArea: Rect(x: 100, y: 100, width: 800, height: 450)), events: [], document: makeDocument())
            // The area fills the stage's height: 450 pt is 1, from 0.
            let rect = try #require(stage.stageRect(global: Rect(x: 50, y: 325, width: 100, height: 300), at: at(1)))
            #expect(abs(rect.x - 0) < 1e-12 && abs(rect.y - 0.5) < 1e-12)
            #expect(abs(rect.width - 50.0 / 450) < 1e-12 && abs(rect.height - 0.5) < 1e-12)
            // A caret, 0 wide, at the far edge of the area is still there; one past it is not.
            #expect(stage.stageRect(global: Rect(x: 900, y: 200, width: 0, height: 18), at: at(1)) != nil)
            #expect(stage.stageRect(global: Rect(x: 950, y: 200, width: 10, height: 18), at: at(1)) == nil)
            #expect(stage.stageRect(global: Rect(x: 300, y: 200, width: .nan, height: 18), at: at(1)) == nil)
            #expect(stage.stageRect(global: Rect(x: 300, y: 200, width: -1, height: 18), at: at(1)) == nil)
        }
    }
}
