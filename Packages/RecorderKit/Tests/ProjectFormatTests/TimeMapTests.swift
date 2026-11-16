// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private func clip(_ id: String, _ start: UInt64, _ end: UInt64, speed: Double = 1, take: String = "take-001") -> Clip {
    Clip(id: id, take: take, start: ns(start), end: ns(end), speed: speed)
}

/// `[0, 1 s)` at 1× and `[2 s, 3 s)` at 3×: a cut of 1 s between them.
private let twoClips = TimeMap(sequence: [
    clip("c-00000001", 0, 1_000_000_000), clip("c-00000002", 2_000_000_000, 3_000_000_000, speed: 3),
])

@Test func durationsAreRoundedPerClipAndSummed() {
    #expect(twoClips.duration == 1_333_333_333)
    #expect(twoClips.clipOutputStarts == [0, 1_000_000_000])
    #expect(twoClips.durationSeconds == 1.333333333)
}

@Test func outputToSourceAcrossClips() throws {
    let second = try #require(twoClips.source(atOutput: 1_200_000_000))
    #expect(second.clip == 1)
    #expect(second.source == ns(2_600_000_000))
    let first = try #require(twoClips.source(atOutput: 999_999_999))
    #expect(first.clip == 0)
    #expect(first.source == ns(999_999_999))
    // The first output instant of a clip is its start.
    let edge = try #require(twoClips.source(atOutput: 1_000_000_000))
    #expect(edge.clip == 1)
    #expect(edge.source == ns(2_000_000_000))
}

@Test func cutSourceHasNoOutput() {
    #expect(twoClips.output(atSource: ns(1_500_000_000), take: "take-001") == nil)
    #expect(twoClips.output(atSource: ns(2_000_000_000), take: "take-001") == 1_000_000_000)
    // The end of a clip is excluded, and so is anything after the last one or in another take.
    #expect(twoClips.output(atSource: ns(1_000_000_000), take: "take-001") == nil)
    #expect(twoClips.output(atSource: ns(999_999_999), take: "take-001") == 999_999_999)
    #expect(twoClips.output(atSource: ns(3_000_000_000), take: "take-001") == nil)
    #expect(twoClips.output(atSource: ns(500_000_000), take: "take-002") == nil)
}

@Test func sourceRangeAcrossACutIsOneOutputRange() {
    func range(_ lower: Int64, _ upper: Int64) -> Range<Int64> { lower..<upper }
    func outputRange(_ a: UInt64, _ b: UInt64, take: String = "take-001") -> Range<Int64>? {
        twoClips.outputRange(ofSource: ns(a)..<ns(b), take: take)
    }
    // The end is the clip's mapping of the range's end: 1 s + round(0.5 s / 3).
    #expect(outputRange(500_000_000, 2_500_000_000) == range(500_000_000, 1_000_000_000 + 166_666_667))
    // A range that starts in the cut begins at the first kept instant; one that ends in it, after the last.
    #expect(outputRange(1_500_000_000, 2_300_000_000) == range(1_000_000_000, 1_100_000_000))
    #expect(outputRange(500_000_000, 1_500_000_000) == range(500_000_000, 1_000_000_000))
    #expect(outputRange(0, 4_000_000_000) == range(0, twoClips.duration))
    // Nothing kept in it: entirely in the cut, after the last clip, empty, or another take.
    #expect(outputRange(1_000_000_000, 2_000_000_000) == nil)
    #expect(outputRange(3_000_000_000, 4_000_000_000) == nil)
    #expect(outputRange(500_000_000, 500_000_000) == nil)
    #expect(outputRange(0, 1_000_000_000, take: "take-002") == nil)
}

@Test func changeInACutRulesFromTheFirstKeptInstant() {
    #expect(twoClips.firstKeptOutput(atOrAfter: ns(1_200_000_000), take: "take-001") == 1_000_000_000)
    // A kept instant is its own output; before the first clip, the first one rules; after the last, nothing.
    #expect(twoClips.firstKeptOutput(atOrAfter: ns(2_600_000_000), take: "take-001") == 1_200_000_000)
    #expect(
        TimeMap(sequence: [clip("c-00000001", 1_000_000_000, 2_000_000_000)])
            .firstKeptOutput(atOrAfter: ns(10), take: "take-001") == 0)
    #expect(twoClips.firstKeptOutput(atOrAfter: ns(3_000_000_000), take: "take-001") == nil)
    #expect(twoClips.firstKeptOutput(atOrAfter: ns(0), take: "take-002") == nil)
}

@Test func samplesOutsideTheClipsKeepTheirTimeThroughTheNearestClip() {
    // [1 s, 2 s) at 2× and [3 s, 4 s) at 1×: 0.5 s of output, then 1 s.
    let map = TimeMap(sequence: [
        clip("c-00000001", 1_000_000_000, 2_000_000_000, speed: 2), clip("c-00000002", 3_000_000_000, 4_000_000_000),
    ])
    func sample(_ x: UInt64, take: String = "take-001") -> Int64? { map.output(ofSampleAt: ns(x), take: take) }
    // Before the first clip, through its mapping: −round(0.6 s / 2); after the last, through its own: 0.5 s + 1.5 s.
    #expect(sample(400_000_000) == -300_000_000)
    #expect(sample(4_500_000_000) == 2_000_000_000)
    #expect(sample(4_000_000_000) == map.duration)
    // In a clip, its own; in the cut between the two, dropped; another take has none.
    #expect(sample(1_500_000_000) == 250_000_000)
    #expect(sample(3_500_000_000) == 1_000_000_000)
    #expect(sample(2_500_000_000) == nil)
    #expect(sample(2_000_000_000) == nil)
    #expect(sample(1_500_000_000, take: "take-002") == nil)
    #expect(TimeMap(sequence: []).output(ofSampleAt: ns(0), take: "take-001") == nil)

    // The speed is the clamped one, and a half rounds away from zero on both sides: −round(1.5) and round(6.5).
    func atZero(speed: Double) -> Int64? {
        let map = TimeMap(sequence: [clip("c-00000001", 1_000_000_000, 2_000_000_000, speed: speed)])
        return map.output(ofSampleAt: ns(0), take: "take-001")
    }
    #expect(atZero(speed: .nan) == -1_000_000_000)
    #expect(atZero(speed: 100) == -62_500_000)
    let halves = TimeMap(sequence: [clip("c-00000001", 10, 20, speed: 2)])
    #expect(halves.output(ofSampleAt: ns(7), take: "take-001") == -2)
    #expect(halves.output(ofSampleAt: ns(23), take: "take-001") == 7)
    // Far away it saturates instead of trapping.
    let late = TimeMap(sequence: [clip("c-00000001", UInt64.max - 10, UInt64.max, speed: 0.25)])
    #expect(late.output(ofSampleAt: ns(0), take: "take-001") == -Int64.max)
    let early = TimeMap(sequence: [clip("c-00000001", 0, 10, speed: 0.25)])
    #expect(early.output(ofSampleAt: ns(UInt64.max), take: "take-001") == .max)
}

@Test func changesBeforeTheFirstClipAreUnderWayAtZero() {
    let map = TimeMap(sequence: [
        clip("c-00000001", 1_000_000_000, 2_000_000_000, speed: 2), clip("c-00000002", 3_000_000_000, 4_000_000_000),
    ])
    func change(_ x: UInt64, take: String = "take-001") -> Int64? { map.output(ofChangeAt: ns(x), take: take) }
    #expect(change(400_000_000) == -300_000_000)
    // In a clip, its own time; in the cut, from the next clip; after the last, never; another take, never.
    #expect(change(1_500_000_000) == 250_000_000)
    #expect(change(2_500_000_000) == 500_000_000)
    #expect(change(4_000_000_000) == nil)
    #expect(change(400_000_000, take: "take-002") == nil)
}

@Test func propertiesHoldForRandomSequences() {
    var generator = SplitMix64(seed: 0x746f_6d61_2d31_62)
    var failures: [String] = []
    var unshownClips = 0
    for index in 0..<1000 {
        let sequence = RandomSequence.make(using: &generator)
        let map = TimeMap(sequence: sequence)
        func fail(_ message: String) {
            if failures.count < 20 { failures.append("sequence \(index): \(message) in \(sequence)") }
        }

        // D == Σ round((e − s) / v), and each O_k is the sum of the durations before it.
        let durations = sequence.map { Int64((Double($0.end.nanoseconds - $0.start.nanoseconds) / $0.speed).rounded()) }
        unshownClips += durations.filter { $0 == 0 }.count
        if map.duration != durations.reduce(0, +) { fail("duration \(map.duration) != \(durations.reduce(0, +))") }
        if map.clipOutputStarts != durations.indices.map({ durations[..<$0].reduce(0, +) }) {
            fail("output starts \(map.clipOutputStarts)")
        }

        // Source instants: every clip edge, the ones next to it and random ones, around the whole sequence.
        let first = sequence[0].start.nanoseconds
        let last = sequence[sequence.count - 1].end.nanoseconds
        var sources: [UInt64] = sequence.flatMap { clip in
            [clip.start.nanoseconds, clip.end.nanoseconds - 1, clip.end.nanoseconds, clip.start.nanoseconds - 1]
        }
        for _ in 0..<64 { sources.append(UInt64.random(in: (first - 1000)...(last + 1000), using: &generator)) }
        sources.sort()
        var previous: Int64?
        for x in sources {
            // The design's formula: O_k + round((x − s_k) / v_k) in the clip that holds x; nil if x is cut.
            let holder = sequence.indices.first { sequence[$0].start.nanoseconds <= x && x < sequence[$0].end.nanoseconds }
            let expected = holder.map { k in
                map.clipOutputStarts[k] + Int64((Double(x - sequence[k].start.nanoseconds) / sequence[k].speed).rounded())
            }
            let output = map.output(atSource: ns(x), take: "take-001")
            if output != expected { fail("output of \(x) is \(String(describing: output)), not \(String(describing: expected))") }
            if let output {
                if let previous, output < previous { fail("output of \(x) is \(output), before \(previous)") }
                previous = output
            }
        }

        // Output → source → output comes back within ceil(1 / v) ns, from a clip that has output.
        var outputs: [Int64] = map.clipOutputStarts.flatMap { [$0, $0 - 1, $0 + 1] } + [map.duration - 1]
        for _ in 0..<64 { outputs.append(Int64.random(in: 0..<max(1, map.duration), using: &generator)) }
        for τ in outputs where τ >= 0 && τ < map.duration {
            guard let found = map.source(atOutput: τ) else {
                fail("no source at \(τ)")
                continue
            }
            let (k, source) = (found.clip, found.source)
            let clip = sequence[k]
            let o = map.clipOutputStarts[k]
            if !(o <= τ && τ < o + durations[k]) { fail("clip \(k) chosen at \(τ), outside its output") }
            // s_k + round((τ − O_k) × v_k), clamped to [s_k, e_k − 1].
            let offset = min(UInt64((Double(τ - o) * clip.speed).rounded()), clip.end.nanoseconds - clip.start.nanoseconds - 1)
            if source != ns(clip.start.nanoseconds + offset) { fail("source of \(τ) is \(source), not at offset \(offset)") }
            guard let back = map.output(atSource: source, take: "take-001") else {
                fail("source \(source) of \(τ) has no output")
                continue
            }
            if abs(back - τ) > Int64((1 / clip.speed).rounded(.up)) { fail("\(τ) → \(source) → \(back) at \(clip.speed)×") }
        }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    // The sequences have clips of no output, which must never be chosen.
    #expect(unshownClips > 0)
}

@Test func halfNanosecondsRoundAwayFromZero() {
    // [0, 10) at 2×: 5 ns of output, the source's 1 ns is 0.5 ns of it.
    let fast = TimeMap(sequence: [clip("c-00000001", 0, 10, speed: 2)])
    #expect(fast.duration == 5)
    #expect(fast.output(atSource: ns(1), take: "take-001") == 1)
    #expect(fast.output(atSource: ns(3), take: "take-001") == 2)
    // [0, 3) at 0.25×: 12 ns of output, of which 2 ns are 0.5 ns of the source.
    let slow = TimeMap(sequence: [clip("c-00000001", 0, 3, speed: 0.25)])
    #expect(slow.duration == 12)
    #expect(slow.source(atOutput: 2)?.source == ns(1))
    #expect(slow.source(atOutput: 1)?.source == ns(0))
    // 3 ns at 2× is 1.5 ns: 2.
    #expect(TimeMap(sequence: [clip("c-00000001", 0, 3, speed: 2)]).duration == 2)
}

@Test func legacyMapIsAddingSeconds() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("phaseZero", in: dir)
        let (_, start, end) = TakeTimeline.bounds(take: project.take, events: project.events)
        let map = TimeMap(sequence: EditDocument.legacy(for: project).sequence)
        let frameCount = map.frameCount(frameRate: 60)
        #expect(frameCount == max(1, Int((end.seconds(since: start) * 60).rounded())))
        #expect(frameCount == 180)
        let mismatches = (0..<frameCount).filter { n in
            map.source(atOutput: TimeMap.frameTime(n, frameRate: 60))?.source != start.adding(seconds: Double(n) / 60)
        }
        #expect(mismatches.isEmpty)
    }
}

@Test func outsideTheTimelineIsClamped() throws {
    let map = TimeMap(sequence: [clip("c-00000001", 1_000_000_000, 4_000_000_000)])
    let before = try #require(map.source(atOutput: -5))
    #expect(before.clip == 0)
    #expect(before.source == ns(1_000_000_000))
    let after = try #require(map.source(atOutput: map.duration))
    #expect(after.clip == 0)
    #expect(after.source == ns(4_000_000_000 - 1))
}

@Test func tinyClipAtSixteenTimes() throws {
    let tenNanoseconds = TimeMap(sequence: [clip("c-00000001", 1_000, 1_010, speed: 16)])
    #expect(tenNanoseconds.duration == 1)
    let only = try #require(tenNanoseconds.source(atOutput: 0))
    #expect(only.clip == 0)
    #expect(only.source == ns(1_000))

    let around = [clip("c-00000001", 0, 1_000), clip("c-00000003", 3_000, 4_000)]
    let withTiny = TimeMap(sequence: [around[0], clip("c-00000002", 2_000, 2_001, speed: 16), around[1]])
    #expect(withTiny.duration == TimeMap(sequence: around).duration)
    #expect(withTiny.clipOutputStarts == [0, 1_000, 1_000])
    // Its output is the start of the next clip, which is the one chosen there.
    let chosen = (-1...2_001).compactMap { withTiny.source(atOutput: Int64($0))?.clip }
    #expect(!chosen.contains(1))
    #expect(withTiny.source(atOutput: 1_000)?.clip == 2)
    #expect(withTiny.output(atSource: ns(2_000), take: "take-001") == 1_000)
}

@Test func emptySequenceHasNoSource() {
    let empty = TimeMap(sequence: [])
    #expect(empty.duration == 0)
    #expect(empty.durationSeconds == 0)
    #expect(empty.clipOutputStarts == [])
    #expect(empty.source(atOutput: 0) == nil)
    #expect(empty.frameCount(frameRate: 60) == 1)
    #expect(TimeMap(sequence: [clip("c-00000001", 1_000, 1_001, speed: 16)]).source(atOutput: 0) == nil)
}

@Test func speedOutOfItsRangeIsClamped() {
    // A document edited by hand: 1600 ns at 100× lasts as at 16×, at 0× or −1× as at 0.25×, and nothing traps.
    func duration(at speed: Double) -> Int64 { TimeMap(sequence: [clip("c-00000001", 0, 1_600, speed: speed)]).duration }
    #expect(duration(at: 100) == 100)
    #expect(duration(at: .infinity) == 100)
    #expect(duration(at: 0) == 6_400)
    #expect(duration(at: -1) == 6_400)
    #expect(duration(at: .nan) == 1_600)
}

@Test func oneSpeedRuleForEveryReader() {
    #expect(ClipSpeed.range == 0.25...16)
    #expect(ClipSpeed.clamped(1.5) == 1.5)
    #expect(ClipSpeed.clamped(32) == 16)
    #expect(ClipSpeed.clamped(.infinity) == 16)
    #expect(ClipSpeed.clamped(0.1) == 0.25)
    #expect(ClipSpeed.clamped(-.infinity) == 0.25)
    #expect(ClipSpeed.clamped(.nan) == 1)
    // A clip's duration on its own is the one the mapping gives it, at the clamped speed.
    let speeds: [Double] = [1, 3, 0.1, 100, .nan]
    for speed in speeds {
        let one = clip("c-00000001", 0, 1_600, speed: speed)
        #expect(TimeMap.outputDuration(of: one) == TimeMap(sequence: [one]).duration, "at \(speed)×")
    }
    #expect(TimeMap.outputDuration(of: clip("c-00000001", 0, 1_600, speed: 3)) == 533)
    // An end before the start is no source at all.
    #expect(TimeMap.outputDuration(of: clip("c-00000001", 1_600, 0)) == 0)
}

@Test func framesAreOnTheRoundedGrid() {
    #expect(TimeMap.frameTime(0, frameRate: 60) == 0)
    #expect(TimeMap.frameTime(1, frameRate: 60) == 16_666_667)
    #expect(TimeMap.frameTime(2, frameRate: 60) == 33_333_333)
    #expect(TimeMap.frameTime(1, frameRate: 24) == 41_666_667)
    #expect(TimeMap.outputNanoseconds(seconds: 1.5) == 1_500_000_000)
    #expect(TimeMap.outputNanoseconds(seconds: -0.25) == -250_000_000)
    #expect(TimeMap.outputNanoseconds(seconds: 1.0 / 60) == TimeMap.frameTime(1, frameRate: 60))
    #expect(twoClips.frameCount(frameRate: 60) == 80)
    #expect(twoClips.frameCount(frameRate: 30) == 40)
}

/// The SplitMix64 generator (Steele, Lea and Flood), for a fixed seed's sequence of numbers on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A sequence of one take made the way the editor makes them: one clip over a take, then splits (some next to an
/// edge, leaving clips of a few nanoseconds), deletes, trims and speeds from 0.25× to 16×, never leaving it empty.
private enum RandomSequence {
    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    static func make(using generator: inout SplitMix64) -> [Clip] {
        let start = UInt64.random(in: 1_000_000...100_000_000_000_000, using: &generator)
        let length = UInt64.random(in: 1...120_000_000_000, using: &generator)
        var clips = [clip("c-00000000", start, start + length)]
        var nextID = 1
        for _ in 0..<Int.random(in: 0...24, using: &generator) {
            let k = Int.random(in: 0..<clips.count, using: &generator)
            let (s, e) = (clips[k].start.nanoseconds, clips[k].end.nanoseconds)
            switch Int.random(in: 0..<5, using: &generator) {
            case 0 where e - s >= 2:
                // Split, sometimes one nanosecond from an edge.
                let at: UInt64
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: at = s + 1
                case 1: at = e - 1
                default: at = UInt64.random(in: (s + 1)...(e - 1), using: &generator)
                }
                var second = clips[k]
                second.id = String(format: "c-%08x", nextID)
                nextID += 1
                clips[k].end = ns(at)
                second.start = ns(at)
                clips.insert(second, at: k + 1)
            case 1 where clips.count > 1:
                clips.remove(at: k)
            case 2 where e - s >= 2:
                clips[k].start = ns(UInt64.random(in: s...(e - 1), using: &generator))
            case 3 where e - s >= 2:
                clips[k].end = ns(UInt64.random(in: (s + 1)...e, using: &generator))
            default:
                clips[k].speed =
                    Bool.random(using: &generator)
                    ? speeds[Int.random(in: 0..<speeds.count, using: &generator)]
                    : Double.random(in: 0.25...16, using: &generator)
            }
        }
        return clips
    }
}
