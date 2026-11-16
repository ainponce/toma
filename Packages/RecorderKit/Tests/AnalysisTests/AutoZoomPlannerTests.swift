// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation
import ProjectFormat
import Testing

// The automatic zoom `autoZoom-1` (design §8.2) over the synthetic take of `ActivityFixtures`: 1440×900 pt, a 16:9 stage
// without padding, Toma's settings (depth 2, groups up to 2.5 s apart, 0.5 s before and 1.0 s after).

extension ActivityFixtures {
    @Suite struct AutoZoomPlannerTests {
        private func plan(_ events: [InputEvent], take: TakeRecord = makeTake(), document: EditDocument = makeDocument())
            -> [ZoomRegion]
        {
            AutoZoomPlanner.plan(take: take, events: events, document: document)
        }

        /// Toma's settings with `change` applied.
        private func settings(_ change: (inout AutoZoomSettings) -> Void) -> AutoZoomSettings {
            var auto = DefaultStyle.toma.zoomAuto
            change(&auto)
            return auto
        }

        /// The source spans of `regions`, in seconds after `base`.
        private func spans(_ regions: [ZoomRegion]) -> [ClosedRange<Double>] {
            regions.map { Double($0.start.nanoseconds - base.nanoseconds) / 1e9...Double($0.end.nanoseconds - base.nanoseconds) / 1e9 }
        }

        /// A user's block over the source seconds `[from, to)`.
        private func userBlock(from: Double, to: Double, origin: Origin = .user) -> ZoomRegion {
            userBlock(at(from)..<at(to), origin: origin)
        }

        private func userBlock(_ source: Range<HostTime>, origin: Origin = .user) -> ZoomRegion {
            ZoomRegion(
                id: "z-\(source.lowerBound.nanoseconds % 100_000_000)", take: takeID, start: source.lowerBound, end: source.upperBound,
                origin: origin, depth: 1.6, focus: .follow, instant: false)
        }

        private func suppressed(from: Double, to: Double) -> SourceRange {
            SourceRange(take: takeID, start: at(from), end: at(to))
        }

        /// Whether `focus` is fixed at (`x`, `y`), within 1e-9.
        private func isFixed(_ focus: ZoomFocus, at x: Double, _ y: Double) -> Bool {
            guard case let .fixed(fx, fy) = focus else { return false }
            return abs(fx - x) < 1e-9 && abs(fy - y) < 1e-9
        }

        @Test func oneClickMakesOneBlock() {
            let regions = plan(click(5, x: 720, y: 450))
            let expected = ZoomRegion(
                id: AutoZoomPlanner.regionID(take: takeID, start: at(4.5), end: at(6)), take: takeID, start: at(4.5), end: at(6),
                origin: .auto, depth: nil, focus: .follow, instant: false)
            #expect(regions == [expected])
        }

        @Test func burstOfClicksIsOneGroup() {
            let regions = plan(click(5, x: 700, y: 450) + click(6, x: 720, y: 460) + click(7.5, x: 710, y: 440))
            #expect(spans(regions) == [4.5...8.5])
            // More than 2.5 s after the last one is another group.
            #expect(spans(plan(click(5, x: 700, y: 450) + click(7.6, x: 700, y: 450))) == [4.5...6.0, 7.1...8.6])
        }

        @Test func farClicksThatDoNotFitSplit() {
            let regions = plan(click(5, x: 20, y: 20) + click(6, x: 1420, y: 880))
            // [4.5, 6.0) and [5.5, 7.0) overlap: they stay one against the other, at the midpoint of 5 and 6 s.
            #expect(spans(regions) == [4.5...5.5, 5.5...7.0])
            #expect(regions.allSatisfy { $0.depth == nil && $0.focus == .follow && $0.origin == .auto })
        }

        @Test func neighboursThatFitAreOne() {
            // Groups up to 1.0 s apart: 5 and 6.5 s are two groups, [4.5, 6.0) and [6.0, 7.5), whose boxes fit together.
            let document = makeDocument(auto: settings { $0.groupGap = 1.0 })
            #expect(spans(plan(click(5, x: 700, y: 450) + click(6.5, x: 720, y: 450), document: document)) == [4.5...7.5])
        }

        @Test func bigDragLowersTheDepth() throws {
            // 540 pt of the screen's 900 tall: 0.6 of the stage's height.
            let regions = plan(drag(5, 6, from: SIMD2(400, 180), to: SIMD2(600, 720)))
            #expect(spans(regions) == [4.5...7.0])
            // The box fits in the crop with 12 % of it on each side: 0.76 / 0.6.
            let depth = try #require(regions.first?.depth)
            #expect((depth * 10_000).rounded() / 10_000 == 1.2667)
            #expect(0.6 <= (1 - 2 * 0.12) / depth + 1e-12)
            // 855 pt, 0.95 of the stage's height, fits only below 1.15×: no block.
            #expect(plan(drag(5, 6, from: SIMD2(400, 20), to: SIMD2(600, 875))).isEmpty)
        }

        @Test func typingAfterAClickHolds() {
            #expect(spans(plan(click(5, x: 720, y: 450) + keys(from: 6.0, to: 12.0))) == [4.5...13.25])
        }

        @Test func typingAloneNeedsANearbyClick() {
            // A fixed focus, to see where the block looks.
            let document = makeDocument(auto: settings { $0.follow = false })
            let typing = keys(from: 20, to: 20.5)
            let near = plan(click(12, x: 700, y: 450) + [pointer(15, x: 710, y: 450)] + typing, document: document)
            #expect(spans(near) == [11.5...13.0, 19.5...21.75])
            #expect(near.allSatisfy { isFixed($0.focus, at: 700.0 / 1440, 0.5) })
            // A click more than 10 s before, or a cursor that went 50 pt from it: only the click's own block.
            #expect(spans(plan(click(9, x: 700, y: 450) + [pointer(15, x: 710, y: 450)] + typing, document: document)) == [8.5...10.0])
            #expect(spans(plan(click(12, x: 700, y: 450) + [pointer(15, x: 750, y: 450)] + typing, document: document)) == [11.5...13.0])
        }

        @Test func typingAloneOffWithoutHoldWhileTyping() {
            let document = makeDocument(auto: settings { $0.holdWhileTyping = false })
            let events = click(12, x: 700, y: 450) + [pointer(15, x: 710, y: 450)] + keys(from: 20, to: 20.5)
            #expect(spans(plan(events, document: document)) == [11.5...13.0])
            // Nor does typing hold a zoom then ("Hold While Typing" off); scrolling still does.
            #expect(spans(plan(click(5, x: 720, y: 450) + keys(from: 6.0, to: 12.0), document: document)) == [4.5...6.0])
            #expect(spans(plan(click(5, x: 720, y: 450) + [scroll(6)], document: document)) == [4.5...7.0])
        }

        @Test func scrollHoldsButNeverCreates() {
            let scrolling = stride(from: 6.0, through: 6.5, by: 0.1).map { scroll($0) }
            #expect(plan(scrolling).isEmpty)
            // From 1 s after the click to 6.5 s: the block ends 1.0 s after the scroll.
            #expect(spans(plan(click(5, x: 720, y: 450) + scrolling)) == [4.5...7.5])
        }

        @Test func clicksInACutMakeNothing() {
            let cut = makeDocument(sequence: [clip(1, from: 0, to: 10), clip(2, from: 20, to: 40)])
            #expect(plan(click(15, x: 720, y: 450), document: cut).isEmpty)
            // A click that is kept makes the block it makes without the cut, in source time and with the same id.
            let kept = plan(click(15, x: 720, y: 450) + click(25, x: 720, y: 450), document: cut)
            #expect(kept == plan(click(25, x: 720, y: 450)))
            #expect(spans(kept) == [24.5...26.0])
        }

        @Test func clickOutsideTheShownAreaIsIgnored() {
            let area = makeTake(captureArea: Rect(x: 100, y: 100, width: 800, height: 450))
            #expect(plan(click(5, x: 1200, y: 800), take: area).isEmpty)
            #expect(spans(plan(click(5, x: 500, y: 300), take: area)) == [4.5...6.0])
        }

        @Test func userBlocksAndSuppressedWin() {
            let burst = click(5, x: 700, y: 450) + click(6, x: 720, y: 460) + click(7.5, x: 710, y: 440)
            func planned(regions: [ZoomRegion] = [], suppressed: [SourceRange] = []) -> [ClosedRange<Double>] {
                spans(plan(burst, document: makeDocument(regions: regions, suppressed: suppressed)))
            }
            #expect(planned() == [4.5...8.5])
            // A user's block over its end: the automatic one keeps the free part.
            #expect(planned(regions: [userBlock(from: 7, to: 9)]) == [4.5...7.0])
            // Less than 1.0 s free: none.
            #expect(planned(regions: [userBlock(from: 5, to: 9)]).isEmpty)
            // A user's block inside it leaves two free parts, each kept.
            #expect(planned(regions: [userBlock(from: 6, to: 6.5)]) == [4.5...6.0, 6.5...8.5])
            // An automatic block in the document is the one being replaced: it takes no room.
            #expect(planned(regions: [userBlock(from: 5, to: 9, origin: .auto)]) == [4.5...8.5])
            // Half of it or more over a suppressed range: none.
            #expect(planned(suppressed: [suppressed(from: 4.5, to: 6.5)]).isEmpty)
        }

        @Test func deletedZoomStaysDeletedWhenItGrows() {
            let burst = click(5, x: 700, y: 450) + click(6, x: 720, y: 460) + click(7.5, x: 710, y: 440)
            func planned(_ suppressed: [SourceRange]) -> [ClosedRange<Double>] {
                spans(plan(burst, document: makeDocument(suppressed: suppressed)))
            }
            // The user deleted the zoom of the click at 5 s, [4.5, 6.0); more clicks now make it [4.5, 8.5), of which the
            // deletion is 37.5 %: it is all of what the user deleted, so it stays deleted.
            #expect(planned([suppressed(from: 4.5, to: 6.0)]).isEmpty)
            // Two neighbours deleted one by one, each less than half of the block they are now.
            #expect(planned([suppressed(from: 4.5, to: 6.4), suppressed(from: 6.4, to: 8.5)]).isEmpty)
            // Half of the deletion: none; less than half of it (1.0 s of 3.5 s) and of the block (1.0 of 4.0 s): it stays.
            #expect(planned([suppressed(from: 3.0, to: 6.0)]).isEmpty)
            #expect(planned([suppressed(from: 2.0, to: 5.5)]) == [4.5...8.5])
            // A block that is all inside a longer deletion stays deleted too (all of it is where the user deleted).
            #expect(planned([suppressed(from: 0, to: 40)]).isEmpty)
        }

        @Test func zeroLengthKeptUserBlockTakesNoRoom() {
            // At 16×, a user's block of 1 ns of source lasts 0 ns of output (an empty output range): it trims nothing.
            let fast = [clip(1, from: 0, to: 60, speed: 16)]
            let user = userBlock(at(32)..<HostTime(nanoseconds: at(32).nanoseconds + 1))
            let regions = plan(click(32, x: 720, y: 450), document: makeDocument(sequence: fast, regions: [user]))
            #expect(regions.count == 1)
            // It is [1.5, 3.0) s of output; at 16×, its end in the source (the source of 3.0 s − 1 ns, + 1 ns) comes back
            // 1 ns short.
            let output = regions.first.flatMap { TimeMap(sequence: fast).outputRange(ofSource: $0.start..<$0.end, take: takeID) }
            #expect(output?.lowerBound == ns(1.5))
            #expect(output.map { abs($0.upperBound - ns(3)) <= 1 } == true)
        }

        @Test func blocksAreStoredInTheSource() {
            // At 2×, the click at 10 s of source is at 5 s of output: the block is [4.5, 6.0) of output. Its start is the
            // source of 4.5 s, its end the source of the last nanosecond before 6.0 s and one more (plan decision 16).
            let double = [clip(1, from: 0, to: 60, speed: 2)]
            let regions = plan(click(10, x: 720, y: 450), document: makeDocument(sequence: double))
            #expect(regions.map(\.start) == [at(9)])
            #expect(regions.map(\.end) == [HostTime(nanoseconds: base.nanoseconds + 11_999_999_999)])
            #expect(
                regions.first.flatMap { TimeMap(sequence: double).outputRange(ofSource: $0.start..<$0.end, take: takeID) }
                    == ns(4.5)..<ns(6))
        }

        @Test(arguments: [0.5, 0.25])
        func belowOneTimesABlockEndsWhereTheNextInstantIs(speed: Double) {
            // At 0.5× (0.25×), the click at 5 s of source is at 10 s (20 s) of output: the block is 0.5 s before it to
            // 1.0 s after it. The last nanosecond of the block and the first after it show the same source instant, so
            // its end is that instant, not one past it: it comes back to the same output.
            let sequence = [clip(1, from: 0, to: 60, speed: speed)]
            let regions = plan(click(5, x: 720, y: 450), document: makeDocument(sequence: sequence))
            #expect(spans(regions) == [(5 - 0.5 * speed)...(5 + 1.0 * speed)])
            let output = regions.first.flatMap { TimeMap(sequence: sequence).outputRange(ofSource: $0.start..<$0.end, take: takeID) }
            #expect(output == ns(5 / speed - 0.5)..<ns(5 / speed + 1.0))
        }

        /// No two blocks overlap, in the source or in the output, at `speed`: the automatic ones among themselves and with
        /// the user's.
        private func expectApart(_ autos: [ZoomRegion], _ users: [ZoomRegion], timeMap: TimeMap, _ comment: Comment) {
            #expect(zip(autos, autos.dropFirst()).allSatisfy { $0.end <= $1.start }, comment)
            for auto in autos {
                #expect(users.allSatisfy { auto.end <= $0.start || $0.end <= auto.start }, comment)
            }
            let outputs = (autos + users).compactMap { timeMap.outputRange(ofSource: $0.start..<$0.end, take: takeID) }
                .sorted { $0.lowerBound < $1.lowerBound }
            #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound }, comment)
        }

        @Test(arguments: [0.25, 0.5, 1, 1.5, 3, 4, 16])
        func blocksNeverOverlapAtAnySpeed(speed: Double) {
            let sequence = [clip(1, from: 0, to: 600, speed: speed)]
            let timeMap = TimeMap(sequence: sequence)
            /// The source seconds shown at `output` seconds.
            func source(_ output: Double) -> Double { output * speed }
            /// A user's block over output seconds `[from, to)` as the editor stores it (plan decision 16).
            func userBlock(output from: Double, _ to: Double) -> ZoomRegion {
                let start = timeMap.source(atOutput: ns(from))!.source
                let end = HostTime(nanoseconds: timeMap.source(atOutput: ns(to) - 1)!.source.nanoseconds + 1)
                return self.userBlock(start..<end)
            }

            // Far clicks at 5 and 6 s of output meet at 5.5 s.
            let far = plan(click(source(5), x: 20, y: 20) + click(source(6), x: 1420, y: 880), document: makeDocument(sequence: sequence))
            #expect(far.count == 2, "far clicks at \(speed)×")
            expectApart(far, [], timeMap: timeMap, "far clicks at \(speed)×")

            // A burst over [4.5, 8.5) s of output, with the user's blocks inside it and right after it: as the editor
            // stores them, and over exact source seconds.
            let burst = click(source(5), x: 700, y: 450) + click(source(6), x: 720, y: 460) + click(source(7.5), x: 710, y: 440)
            let stored = [userBlock(output: 6.0, 6.5), userBlock(output: 8.5, 9.0)]
            let exact = [self.userBlock(from: source(6.0), to: source(6.5)), self.userBlock(from: source(8.5), to: source(9.0))]
            for (name, users) in [("stored", stored), ("exact", exact)] {
                let autos = plan(burst, document: makeDocument(sequence: sequence, regions: users))
                let comment: Comment = "burst with \(name) user blocks at \(speed)×"
                #expect(autos.count == 2, comment)
                expectApart(autos, users, timeMap: timeMap, comment)
                // The free parts are still [4.5, 6.0) and [6.5, 8.5) of output, within a few nanoseconds.
                let outputs = autos.compactMap { timeMap.outputRange(ofSource: $0.start..<$0.end, take: takeID) }
                let expected = [ns(4.5)..<ns(6.0), ns(6.5)..<ns(8.5)]
                #expect(
                    zip(outputs, expected).allSatisfy {
                        abs($0.lowerBound - $1.lowerBound) <= 4 && abs($0.upperBound - $1.upperBound) <= 4
                    },
                    comment)
            }
        }

        @Test func cursorPausesOnlyWithThatTrigger() {
            // 100 pt in 25 steps of 4 pt, still from 2.5 s for 1.5 s, without a click; then 50 pt more.
            let events = (0...25).map { pointer(2 + 0.5 * Double($0) / 25, x: 500 + 4 * Double($0), y: 400) } + [pointer(4, x: 650, y: 400)]
            #expect(spans(plan(events, document: makeDocument(auto: settings { $0.triggers = .clicksAndPauses }))) == [2.0...3.5])
            #expect(plan(events).isEmpty)
        }

        @Test func autoZoomOffPlansNothing() {
            #expect(plan(click(5, x: 720, y: 450), document: makeDocument(auto: settings { $0.enabled = false })).isEmpty)
        }

        @Test func sameInputSameBlocksAndIDs() {
            let events = click(3, x: 200, y: 200) + click(4, x: 1300, y: 800) + drag(10, 11, from: SIMD2(300, 300), to: SIMD2(700, 500))
                + keys(from: 11.5, to: 15) + click(20, x: 700, y: 450) + [pointer(22, x: 705, y: 450)] + keys(from: 28, to: 29)
                + (0...25).map { pointer(40 + 0.5 * Double($0) / 25, x: 100 + 4 * Double($0), y: 600) } + [pointer(42, x: 260, y: 600)]
                + stride(from: 33.0, through: 34.0, by: 0.1).map { scroll($0) } + click(32, x: 900, y: 300)
            let document = makeDocument(auto: settings { $0.triggers = .clicksAndPauses })
            let first = plan(events, document: document)
            let second = plan(events.reversed(), document: document)
            #expect(first == second)
            // Far clicks at 3 and 4 s meet at 3.5 s; the drag is held by the typing to 15.25 s; the click at 20 s has its
            // block and makes the typing at 28 s one (10 s or less after it, 5 pt away); the scroll holds the click at
            // 32 s to 34 s; the cursor pauses at 40.5 s.
            #expect(spans(first) == [2.5...3.5, 3.5...5.0, 9.5...16.25, 19.5...21.0, 27.5...30.25, 31.5...35.0, 40.0...41.5])
            for region in first {
                #expect(region.id == AutoZoomPlanner.regionID(take: takeID, start: region.start, end: region.end))
            }
        }

        @Test func regionIDIsTheHashOfPlannerTakeStartAndEnd() {
            // Plan decision 10: "z-" and the first 4 bytes, in hex, of SHA-256 of "<planner>|<take>|<start>|<end>" in ns.
            let digest = SHA256.hash(data: Data("autoZoom-1|take-001|5000000000|6000000000".utf8))
            let expected = "z-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            #expect(AutoZoomPlanner.id == "autoZoom-1")
            #expect(
                AutoZoomPlanner.regionID(
                    take: "take-001", start: HostTime(nanoseconds: 5_000_000_000), end: HostTime(nanoseconds: 6_000_000_000))
                    == expected)
            #expect(expected.count == 10)
        }
    }
}
