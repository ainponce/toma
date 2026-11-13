// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import Testing

private func clock(_ frame: Int, at t: HostTime, track: String = "mic") -> InputEvent {
    InputEvent(t: t, kind: .audioClock(track: track, frame: frame))
}

private func anchors(_ result: (kept: [(frame: Int, t: HostTime)], rejected: Int)) -> [[UInt64]] {
    result.kept.map { [UInt64($0.frame), $0.t.nanoseconds] }
}

private func expected(_ pairs: [(Int, HostTime)]) -> [[UInt64]] {
    pairs.map { [UInt64($0.0), $0.1.nanoseconds] }
}

@Test func clockAnchorsBelongToTheSegmentWhoseSpanHoldsThem() {
    let first = base, second = base.adding(seconds: 20)
    let events = [
        clock(480_000, at: first.adding(seconds: 10)),  // logged out of time order
        clock(240_000, at: first.adding(seconds: 5)),
        clock(240_000, at: first.adding(seconds: 5), track: "other-mic"),
        InputEvent(t: first.adding(seconds: 6), kind: .cursor(x: 1, y: 2)),
        clock(240_000, at: second.adding(seconds: 5)),
    ]
    let one = MicrophoneTimeline.clockAnchors(of: "mic", from: first, before: second, sourceRate: 48_000, in: events)
    #expect(anchors(one) == expected([(240_000, first.adding(seconds: 5)), (480_000, first.adding(seconds: 10))]))
    #expect(one.rejected == 0)
    let two = MicrophoneTimeline.clockAnchors(of: "mic", from: second, before: nil, sourceRate: 48_000, in: events)
    #expect(anchors(two) == expected([(240_000, second.adding(seconds: 5))]))
    #expect(MicrophoneTimeline.clockAnchors(of: "mic", from: base.adding(seconds: 40), before: nil, sourceRate: 48_000, in: events).kept.isEmpty)
}

@Test func clockAnchorsLeaveOutOnesThatDoNotMoveForward() {
    let events = [
        clock(240_000, at: base.adding(seconds: 5.01)),
        clock(300_000, at: base.adding(seconds: 5.01)),  // not after the last one kept
        clock(200_000, at: base.adding(seconds: 6)),  // backwards in frames
    ]
    let result = MicrophoneTimeline.clockAnchors(of: "mic", from: base, before: nil, sourceRate: 48_000, in: events)
    #expect(anchors(result) == expected([(240_000, base.adding(seconds: 5.01))]))
    #expect(result.rejected == 2)
}

@Test func clockAnchorsLeaveOutOnesBeyond5000PPM() {
    // 2000 ppm is a plausible device clock; a 100 ms jump in the timestamps over 5 s (2 %) is not. The
    // anchor after the jump is compared with the one before it, so only the jump is lost.
    let events = [
        clock(240_000, at: base.adding(seconds: 5.01)),
        clock(480_000, at: base.adding(seconds: 10.12)),
        clock(720_000, at: base.adding(seconds: 15.13)),
    ]
    let result = MicrophoneTimeline.clockAnchors(of: "mic", from: base, before: nil, sourceRate: 48_000, in: events)
    #expect(anchors(result) == expected([(240_000, base.adding(seconds: 5.01)), (720_000, base.adding(seconds: 15.13))]))
    #expect(result.rejected == 1)
    // 6000 ppm from the segment's start: the first one goes too.
    let far = MicrophoneTimeline.clockAnchors(
        of: "mic", from: base, before: nil, sourceRate: 48_000, in: [clock(240_000, at: base.adding(seconds: 5.03))])
    #expect(far.kept.isEmpty && far.rejected == 1)
    // 44.1 kHz: 220 500 frames in 5 s is the nominal rate.
    let other = MicrophoneTimeline.clockAnchors(
        of: "mic", from: base, before: nil, sourceRate: 44_100, in: [clock(220_500, at: base.adding(seconds: 5))])
    #expect(other.kept.count == 1 && other.rejected == 0)
}

/// Output frames are at 48 kHz from `timelineStart`; the segment starts 1 s in, at output frame 48 000.
private let timelineStart = base.adding(seconds: -1)

@Test func clockMapWithoutAnchorsRunsAtTheNominalRate() {
    let map = ClockMap(start: base, anchors: [], sourceRate: 48_000, timelineStart: timelineStart, outputRate: 48_000)
    var k = 0
    #expect(map.output(atDecoded: 0) == 48_000)
    #expect(map.decoded(atOutput: 48_000 + 4_800, interval: &k) == 4_800)
    #expect(map.output(atDecoded: 480_000) == 528_000)
}

@Test func clockMapFollowsItsAnchorsAndKeepsTheLastRateAfterThem() {
    // 2000 ppm: 5 s of frames take 5.01 s of host time, then 2000 ppm the other way.
    let anchors = [(frame: 240_000, t: base.adding(seconds: 5.01)), (frame: 480_000, t: base.adding(seconds: 10.0))]
    let map = ClockMap(start: base, anchors: anchors, sourceRate: 48_000, timelineStart: timelineStart, outputRate: 48_000)
    var k = 0
    #expect(abs(map.decoded(atOutput: 48_000 + 2.505 * 48_000, interval: &k) - 120_000) < 1e-6)  // halfway to the first
    #expect(abs(map.decoded(atOutput: 48_000 + 5.01 * 48_000, interval: &k) - 240_000) < 1e-6)
    #expect(k == 1)
    #expect(abs(map.decoded(atOutput: 48_000 + 10.0 * 48_000, interval: &k) - 480_000) < 1e-6)
    // Past the last anchor, at the rate between the last two: 240 000 frames per 4.99 s.
    #expect(abs(map.decoded(atOutput: 48_000 + 14.99 * 48_000, interval: &k) - 720_000) < 1e-6)
    #expect(abs(map.output(atDecoded: 720_000) - (48_000 + 14.99 * 48_000)) < 1e-6)
    #expect(abs(map.output(atDecoded: 240_000) - (48_000 + 5.01 * 48_000)) < 1e-6)
}

@Test func clockMapWithOneAnchorGoesOnAtItsRate() {
    let map = ClockMap(
        start: base, anchors: [(frame: 240_000, t: base.adding(seconds: 5.01))], sourceRate: 48_000,
        timelineStart: timelineStart, outputRate: 48_000)
    var k = 0
    #expect(abs(map.decoded(atOutput: 48_000 + 10.02 * 48_000, interval: &k) - 480_000) < 1e-6)
    #expect(abs(map.output(atDecoded: 480_000) - (48_000 + 10.02 * 48_000)) < 1e-6)
}

@Test func clockMapCountsSourceFramesAtTheirOwnRate() {
    // A 44.1 kHz file decoded at 48 kHz: source frame 220 500 is 5 s in, decoded frame 240 000.
    let map = ClockMap(
        start: base, anchors: [(frame: 220_500, t: base.adding(seconds: 5))], sourceRate: 44_100,
        timelineStart: timelineStart, outputRate: 48_000)
    var k = 0
    #expect(abs(map.decoded(atOutput: 48_000 + 5 * 48_000, interval: &k) - 240_000) < 1e-6)
    #expect(abs(map.output(atDecoded: 240_000) - (48_000 + 5 * 48_000)) < 1e-6)
}

@Test func shiftingAClockMapMovesEveryKnotTogether() {
    // A segment following on 10 ms early after a closed gap: every frame goes 480 output frames earlier.
    let anchors = [(frame: 240_000, t: base.adding(seconds: 5.01)), (frame: 480_000, t: base.adding(seconds: 10.02))]
    let original = ClockMap(start: base, anchors: anchors, sourceRate: 48_000, timelineStart: timelineStart, outputRate: 48_000)
    var shifted = original
    shifted.shift(by: -480)
    for decoded in [0.0, 120_000, 240_000, 480_000, 720_000] {
        #expect(abs(shifted.output(atDecoded: decoded) - (original.output(atDecoded: decoded) - 480)) < 1e-6)
    }
    var k = 0, j = 0
    #expect(abs(shifted.decoded(atOutput: 300_000 - 480, interval: &k) - original.decoded(atOutput: 300_000, interval: &j)) < 1e-6)
}
