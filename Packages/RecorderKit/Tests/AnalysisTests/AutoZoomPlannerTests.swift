// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CryptoKit
import Foundation
import ProjectFormat
import Testing

// The automatic zoom `autoZoom-1` (design §8.2) over the synthetic take of ActivityTests: 1440×900 pt, a 16:9 stage
// without padding, Toma's settings (depth 2, groups up to 2.5 s apart, 0.5 s before and 1.0 s after).

private func plan(_ events: [InputEvent], take: TakeRecord = makeTake(), document: EditDocument = makeDocument()) -> [ZoomRegion] {
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
    ZoomRegion(
        id: "z-0000000\(Int(from))", take: takeID, start: at(from), end: at(to), origin: origin, depth: 1.6, focus: .follow,
        instant: false)
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
    let depth = try #require(regions.first?.depth)
    #expect(depth < 2 && depth >= 1.15)
    // The box fits in the crop with 12 % of it on each side.
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
    // Half of it or more over a suppressed range: none; less: it stays.
    #expect(planned(suppressed: [SourceRange(take: takeID, start: at(4.5), end: at(6.5))]).isEmpty)
    #expect(planned(suppressed: [SourceRange(take: takeID, start: at(4.5), end: at(6.4))]) == [4.5...8.5])
}

@Test func zeroLengthKeptUserBlockTakesNoRoom() {
    // At 16×, a user's block of 1 ns of source lasts 0 ns of output (an empty output range): it trims nothing.
    let fast = [clip(1, from: 0, to: 60, speed: 16)]
    let user = ZoomRegion(
        id: "z-00000001", take: takeID, start: at(32), end: HostTime(nanoseconds: at(32).nanoseconds + 1), origin: .user,
        focus: .follow, instant: false)
    let regions = plan(click(32, x: 720, y: 450), document: makeDocument(sequence: fast, regions: [user]))
    #expect(regions.count == 1)
    // It is [1.5, 3.0) s of output; at 16×, its end in the source (the source of 3.0 s − 1 ns, + 1 ns) comes back
    // 1 ns short.
    let output = regions.first.flatMap { TimeMap(sequence: fast).outputRange(ofSource: $0.start..<$0.end, take: takeID) }
    #expect(output?.lowerBound == ns(1.5))
    #expect(output.map { abs($0.upperBound - ns(3)) <= 1 } == true)
}

@Test func blocksAreStoredInTheSource() {
    // At 2×, the click at 10 s of source is at 5 s of output: the block is [4.5, 6.0) of output. Its start is the source
    // of 4.5 s, its end the source of the last nanosecond before 6.0 s and one more (plan decision 16).
    let double = [clip(1, from: 0, to: 60, speed: 2)]
    let regions = plan(click(10, x: 720, y: 450), document: makeDocument(sequence: double))
    #expect(regions.map(\.start) == [at(9)])
    #expect(regions.map(\.end) == [HostTime(nanoseconds: base.nanoseconds + 11_999_999_999)])
    #expect(regions.first.flatMap { TimeMap(sequence: double).outputRange(ofSource: $0.start..<$0.end, take: takeID) } == ns(4.5)..<ns(6))
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
    #expect(first.count >= 5)
    for region in first {
        #expect(region.id == AutoZoomPlanner.regionID(take: takeID, start: region.start, end: region.end))
    }
    // In order, never overlapping.
    #expect(zip(first, first.dropFirst()).allSatisfy { $0.end <= $1.start })
}

@Test func regionIDIsTheHashOfPlannerTakeStartAndEnd() {
    // Plan decision 10: "z-" and the first 4 bytes, in hex, of SHA-256 of "<planner>|<take>|<start>|<end>" in ns.
    let digest = SHA256.hash(data: Data("autoZoom-1|take-001|5000000000|6000000000".utf8))
    let expected = "z-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    #expect(AutoZoomPlanner.id == "autoZoom-1")
    #expect(
        AutoZoomPlanner.regionID(take: "take-001", start: HostTime(nanoseconds: 5_000_000_000), end: HostTime(nanoseconds: 6_000_000_000))
            == expected)
    #expect(expected.count == 10)
}
