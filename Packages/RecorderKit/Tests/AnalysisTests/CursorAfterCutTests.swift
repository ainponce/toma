// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The cursor after a cut (final review B-I1): the pointer moved in the part cut away and then stood still, so no sample
// is in the next clip. Where it is when that clip starts is the last position of the cut, placed at the clip's start as a
// press or a release in a cut is; the positions inside the cut are never drawn.

private let origin = HostTime(nanoseconds: 9_000_000_000_000)
private let takeID = "take-001"
private let take = TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])

private func at(_ seconds: Double, _ point: SIMD2<Double>) -> InputEvent {
    InputEvent(t: origin.adding(seconds: seconds), kind: .cursor(x: point.x, y: point.y))
}

private func clip(_ number: Int, from: Double, to: Double) -> Clip {
    Clip(id: "c-0000000\(number)", take: takeID, start: origin.adding(seconds: from), end: origin.adding(seconds: to), speed: 1)
}

private func path(_ events: [InputEvent], _ smoothing: CursorSmoothing, _ sequence: [Clip]) -> CursorPath {
    let style = CursorStyle(
        show: true, style: .system, scale: 1, smoothing: smoothing, hideWhenIdle: false, idleDelay: 2, clickEffect: "none",
        clickSound: "none", clickSoundGain: 1, motionBlur: 0)
    return CursorPath(take: take, events: events, style: style, timeMap: TimeMap(sequence: sequence))
}

private let a = SIMD2(100.0, 100), b = SIMD2(900.0, 500)
/// At A from 0 s, at B from 1.5 s (in the cut over [1, 2) s), and no other position: clips [0, 1) and [2, 4).
private let events = [at(0, a), at(1.5, b)]
private let sequence = [clip(1, from: 0, to: 1), clip(2, from: 2, to: 4)]

private func distance(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double { ((p - q) * (p - q)).sum().squareRoot() }

@Test func afterACutTheUnsmoothedCursorIsWhereThePointerIs() throws {
    let off = path(events, .off, sequence)
    // Output 1 s is the second clip's start, source 2 s.
    #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: 0.9))).position == a)
    #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1))).position == b)
    #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1.5))).position == b)
    #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: 2.9))).position == b)
}

@Test func afterACutTheSmoothedCursorGoesToWhereThePointerIs() throws {
    let spring = path(events, .spring(SpringSpec(damping: 1, response: 0.16)), sequence)
    // The spring goes from the last position before the cut to the first after it (design §8.4): toward B, and there.
    let start = try #require(spring.sample(atStep: 599)).position
    let soon = try #require(spring.sample(atStep: 660)).position
    #expect(distance(start, a) < 1)
    #expect(distance(soon, b) < distance(start, b) - 100, "heading to B")
    #expect(distance(try #require(spring.sample(atStep: 1500)).position, b) < 0.5)
}

/// Only the last position of a cut is drawn, at the next clip's start; one exactly there is the pointer's own and wins.
@Test func onlyTheLastPositionOfACutCounts() throws {
    let c = SIMD2(400.0, 800)
    let wandering = [at(0, a), at(1.2, c), at(1.5, b)]
    let off = path(wandering, .off, sequence)
    for seconds in [0.95, 0.999] {
        #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: seconds))).position == a, "nothing of the cut")
    }
    #expect(try #require(off.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1))).position == b)
    let atTheStart = path(wandering + [at(2, c)], .off, sequence)
    #expect(try #require(atTheStart.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1.5))).position == c)
}

/// A legacy document (one clip, no cut) has no position in a cut: nothing changes there (the golden).
@Test func withoutACutNothingMoves() throws {
    let one = path(events, .off, [clip(1, from: 0, to: 4)])
    #expect(try #require(one.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1.4))).position == a)
    #expect(try #require(one.sample(atOutput: TimeMap.outputNanoseconds(seconds: 1.5))).position == b)
}
