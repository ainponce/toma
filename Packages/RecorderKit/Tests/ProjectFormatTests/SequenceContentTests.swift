// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the editor, the render and the mix use only the public API.
import ProjectFormat

/// Clips with content as points that last, the cut of the sound and its limits, and the invariant of each take (phase 3
/// design §4.1, §7.3 and §9; base plan decision 7).
@Suite struct SequenceContentTests {
    private static let second: Int64 = 1_000_000_000

    private static func ns(_ nanoseconds: Int64) -> HostTime { HostTime(nanoseconds: UInt64(nanoseconds)) }

    private static func clip(
        _ id: String, _ start: Int64, _ end: Int64, speed: Double = 1, take: String = "take-001", shift: Int64 = 0
    ) -> Clip {
        Clip(id: id, take: take, start: ns(start), end: ns(end), speed: speed, audioShift: shift)
    }

    private static func content(_ id: String, at point: Int64, _ content: ClipContent, take: String = "take-001") -> Clip {
        Clip(id: id, take: take, start: ns(point), end: ns(point), speed: 1, content: content)
    }

    private static let card = TitleCard(title: "Toma", style: .centered, background: .stage)

    /// `[0, 1 s)`, a frozen frame of 2 s at 1 s, `[1 s, 2 s)`.
    private static let frozen = [
        clip("c-00000001", 0, second), content("c-00000002", at: second, .freeze(duration: 2 * second)),
        clip("c-00000003", second, 2 * second),
    ]

    @Test func contentClipIsAPointThatLasts() throws {
        let map = TimeMap(sequence: Self.frozen)
        #expect(map.duration == 4 * Self.second)
        #expect(map.clipOutputStarts == [0, Self.second, 3 * Self.second])
        #expect(map.audioStarts == map.clipOutputStarts)
        #expect(TimeMap.outputDuration(of: Self.frozen[1]) == 2 * Self.second)
        // Every output instant of the frozen frame shows its point, at its offset into the content.
        for τ in [Self.second, Self.second + 1, 2 * Self.second, 3 * Self.second - 1] {
            let shown = try #require(map.source(atOutput: τ))
            #expect(shown.clip == 1 && shown.source == Self.ns(Self.second), "\(τ)")
            let offset = try #require(map.contentOffset(atOutput: τ))
            #expect(offset.clip == 1 && offset.offset == τ - Self.second, "\(τ)")
        }
        // Around it, the take's stretches, which have no content offset.
        #expect(map.source(atOutput: Self.second - 1)?.clip == 0)
        #expect(map.source(atOutput: Self.second - 1)?.source == Self.ns(Self.second - 1))
        #expect(map.source(atOutput: 3 * Self.second)?.clip == 2)
        #expect(map.source(atOutput: 3 * Self.second)?.source == Self.ns(Self.second))
        #expect(map.contentOffset(atOutput: Self.second - 1) == nil)
        #expect(map.contentOffset(atOutput: 3 * Self.second) == nil)
        // Clamped to the output as `source(atOutput:)` is.
        #expect(map.contentOffset(atOutput: -5) == nil)
        #expect(TimeMap(sequence: [Self.frozen[1]]).contentOffset(atOutput: 10 * Self.second)?.offset == 2 * Self.second - 1)
        #expect(TimeMap(sequence: [Self.frozen[1]]).source(atOutput: -1)?.source == Self.ns(Self.second))
        // No source instant falls in it: the source maps to the clip after it.
        #expect(map.output(atSource: Self.ns(Self.second), take: "take-001") == 3 * Self.second)
        #expect(map.output(atSource: Self.ns(Self.second - 1), take: "take-001") == Self.second - 1)
        #expect(map.firstKeptOutput(atOrAfter: Self.ns(Self.second), take: "take-001") == 3 * Self.second)
        #expect(map.outputRange(ofSource: Self.ns(0)..<Self.ns(2 * Self.second), take: "take-001") == 0..<(4 * Self.second))
        #expect(map.output(ofSampleAt: Self.ns(5 * Self.second), take: "take-001") == 7 * Self.second)
        // A sequence of only content: no source maps anywhere, and every instant shows the point.
        let alone = TimeMap(sequence: [Self.frozen[1]])
        #expect(alone.duration == 2 * Self.second)
        #expect(alone.output(atSource: Self.ns(Self.second), take: "take-001") == nil)
        #expect(alone.output(ofSampleAt: Self.ns(Self.second), take: "take-001") == nil)
        #expect(alone.output(ofChangeAt: Self.ns(0), take: "take-001") == nil)
        // A content clip whose end is not its start (a document edited by hand) is read as its point all the same.
        var wide = Self.frozen
        wide[1].end = Self.ns(5 * Self.second)
        #expect(TimeMap(sequence: wide) == map)
    }

    @Test func everyContentIsAPoint() throws {
        let media = MediaClip(asset: "assets/0123456789abcdef0123456789abcdef.mov", start: 0, end: 3 * Self.second, speed: 1.5)
        let sequence = [
            Self.clip("c-00000001", 0, Self.second), Self.content("c-00000002", at: Self.second, .card(Self.card, duration: 3 * Self.second)),
            Self.content("c-00000003", at: Self.second, .media(media)), Self.clip("c-00000004", Self.second, 2 * Self.second),
        ]
        let map = TimeMap(sequence: sequence)
        #expect(map.clipOutputStarts == [0, Self.second, 4 * Self.second, 6 * Self.second])
        #expect(map.duration == 7 * Self.second)
        for τ in stride(from: Self.second, to: 6 * Self.second, by: Int(Self.second / 4)) {
            #expect(try #require(map.source(atOutput: τ)).source == Self.ns(Self.second), "\(τ)")
        }
        #expect(map.contentOffset(atOutput: 4 * Self.second)?.clip == 2)
        #expect(map.contentOffset(atOutput: 4 * Self.second)?.offset == 0)
        #expect(map.contentOffset(atOutput: 4 * Self.second - 1)?.clip == 1)
        #expect(map.contentOffset(atOutput: 4 * Self.second - 1)?.offset == 3 * Self.second - 1)
    }

    @Test func durationsAreReadHeld() {
        #expect(ClipContent.freeze(duration: 0).outputDuration == 100_000_000)
        #expect(ClipContent.freeze(duration: -5).outputDuration == 100_000_000)
        #expect(ClipContent.freeze(duration: 600 * Self.second).outputDuration == 60 * Self.second)
        #expect(ClipContent.freeze(duration: .max).outputDuration == 60 * Self.second)
        #expect(ClipContent.freeze(duration: 2 * Self.second).outputDuration == 2 * Self.second)
        #expect(ClipContent.card(Self.card, duration: 0).outputDuration == 100_000_000)
        #expect(ClipContent.card(Self.card, duration: 10 * 60 * Self.second).outputDuration == 60 * Self.second)
        func media(_ start: Int64, _ end: Int64, _ speed: Double) -> Int64 {
            ClipContent.media(MediaClip(asset: "assets/a.mov", start: start, end: end, speed: speed)).outputDuration
        }
        #expect(media(Self.second, 0, 1) == 0)
        #expect(media(Self.second, Self.second, 1) == 0)
        #expect(media(0, 3 * Self.second, .nan) == 3 * Self.second)
        #expect(media(0, 3 * Self.second, 2) == 1_500_000_000)
        #expect(media(0, 1_000_000_001, 2) == 500_000_001)
        #expect(media(0, 3 * Self.second, 100) == 187_500_000)
        #expect(media(.min, .max, 16) == 1_152_921_504_606_846_976)
        // The time map reads them so.
        let held = Self.content("c-00000001", at: 0, .freeze(duration: 0))
        #expect(TimeMap.outputDuration(of: held) == 100_000_000)
        #expect(TimeMap(sequence: [held, Self.clip("c-00000002", 0, Self.second)]).clipOutputStarts == [0, 100_000_000])
        // A media clip of no length is never shown.
        let empty = Self.content("c-00000003", at: Self.second, .media(MediaClip(asset: "assets/a.mov", start: 5, end: 5)))
        let map = TimeMap(sequence: [Self.clip("c-00000001", 0, Self.second), empty, Self.clip("c-00000002", Self.second, 2 * Self.second)])
        #expect(map.duration == 2 * Self.second)
        #expect(map.source(atOutput: Self.second)?.clip == 2)
        #expect(map.contentOffset(atOutput: Self.second) == nil)
    }

    /// A small random number generator of fixed seed (SplitMix64), so every run draws the same sequences.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Phase 2's mapping from the output to the source, written again here from its definition: the clip `k` with
    /// `O_k ≤ τ < O_k + D_k` (the last one starting at or before `τ`), `s_k + round((τ − O_k) × v_k)` clamped to the clip.
    private static func phase2Source(_ sequence: [Clip], atOutput τ: Int64) -> (clip: Int, source: HostTime)? {
        var starts: [Int64] = []
        var total: Int64 = 0
        for clip in sequence {
            starts.append(total)
            let length = clip.end.nanoseconds > clip.start.nanoseconds ? clip.end.nanoseconds - clip.start.nanoseconds : 0
            total += Int64((Double(length) / ClipSpeed.clamped(clip.speed)).rounded())
        }
        guard total > 0 else { return nil }
        let t = min(max(τ, 0), total - 1)
        let k = starts.lastIndex { $0 <= t }!
        let clip = sequence[k]
        let offset = Int64((Double(t - starts[k]) * ClipSpeed.clamped(clip.speed)).rounded())
        let length = clip.end.nanoseconds - clip.start.nanoseconds
        return (k, HostTime(nanoseconds: clip.start.nanoseconds + min(UInt64(max(offset, 0)), length - 1)))
    }

    @Test func noContentNoShiftIsPhase2() {
        var random = Seeded(state: 0x7041_3B5F)
        let speeds = [0.25, 0.5, 1, 1.5, 2, 3, 16]
        for round in 0..<200 {
            // Clips of two takes in source order, at any speed, some cut apart and some going on.
            var sequence: [Clip] = []
            var ends = ["take-001": Int64(0), "take-002": Int64(0)]
            for k in 0..<Int.random(in: 1...12, using: &random) {
                let take = Bool.random(using: &random) ? "take-001" : "take-002"
                let start = ends[take]! + (Bool.random(using: &random) ? 0 : Int64.random(in: 1...3 * Self.second, using: &random))
                let end = start + Int64.random(in: 1...4 * Self.second, using: &random)
                ends[take] = end
                sequence.append(Self.clip(String(format: "c-%08x", k + 1), start, end, speed: speeds.randomElement(using: &random)!, take: take))
            }
            let map = TimeMap(sequence: sequence)
            #expect(map.audioStarts == map.clipOutputStarts, "round \(round)")
            #expect(SequenceRules.firstOutOfOrder(in: sequence) == nil, "round \(round)")
            #expect((0..<sequence.count).allSatisfy { SequenceRules.audioShift(of: sequence, at: $0) == 0 }, "round \(round)")
            for _ in 0..<20 {
                let τ = Int64.random(in: -Self.second...(map.duration + Self.second), using: &random)
                let shown = map.source(atOutput: τ), expected = Self.phase2Source(sequence, atOutput: τ)
                #expect(shown?.clip == expected?.clip && shown?.source == expected?.source, "round \(round) at \(τ)")
                #expect(map.contentOffset(atOutput: τ) == nil, "round \(round) at \(τ)")
                if let shown {
                    // The instant shown, but where that is clamped to the clip's last one.
                    let heard = map.audioSource(ofClip: shown.clip, atOutput: min(max(τ, 0), map.duration - 1))
                    let last = Int64(sequence[shown.clip].end.nanoseconds) - 1
                    #expect(heard == Int64(shown.source.nanoseconds) || (heard > last && shown.source.nanoseconds == UInt64(last)),
                        "round \(round) at \(τ)")
                }
            }
        }
    }

    @Test func invariantHoldsPerTake() {
        let second = Self.second
        #expect(SequenceRules.firstOutOfOrder(in: Self.frozen) == nil)
        #expect(SequenceRules.firstOutOfOrder(in: []) == nil)
        // A clip of a take before the end of the one before it in that take.
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", second, 2 * second), Self.clip("c-2", 0, second)]) == 1)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", 0, 2 * second), Self.clip("c-2", second, 3 * second)]) == 1)
        // Two takes interleaved, each in order.
        #expect(SequenceRules.firstOutOfOrder(in: [
            Self.clip("c-1", 0, second), Self.clip("c-2", 5 * second, 6 * second, take: "take-002"),
            Self.clip("c-3", second, 2 * second), Self.clip("c-4", 0, second, take: "take-001"),
        ]) == 3)
        #expect(SequenceRules.firstOutOfOrder(in: [
            Self.clip("c-1", 0, second), Self.clip("c-2", 5 * second, 6 * second, take: "take-002"),
            Self.clip("c-3", second, 2 * second), Self.clip("c-4", 0, second, take: "take-003"),
            Self.clip("c-5", 6 * second, 7 * second, take: "take-002"),
        ]) == nil)
        // A point inside the clip before it of its take, or before a point of it, is out of order; at its edge it is not.
        let freeze = ClipContent.freeze(duration: second)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", 0, 2 * second), Self.content("c-2", at: second, freeze)]) == 1)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", 0, 2 * second), Self.content("c-2", at: 2 * second, freeze)]) == nil)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.content("c-1", at: 2 * second, freeze), Self.clip("c-2", second, 3 * second)]) == 1)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.content("c-1", at: second, freeze), Self.content("c-2", at: second, freeze)]) == nil)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.content("c-1", at: 2 * second, freeze), Self.content("c-2", at: second, freeze)]) == 1)
        // A point of another take is in no order of this one.
        #expect(SequenceRules.firstOutOfOrder(in: [
            Self.clip("c-1", 0, 2 * second), Self.content("c-2", at: second, freeze, take: "take-002"),
        ]) == nil)
        // A point's own end is not read; a clip with an end before its start is its start.
        var wide = Self.content("c-2", at: second, freeze)
        wide.end = Self.ns(9 * second)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", 0, second), wide, Self.clip("c-3", second, 2 * second)]) == nil)
        #expect(SequenceRules.firstOutOfOrder(in: [Self.clip("c-1", 3 * second, second), Self.clip("c-2", 3 * second, 4 * second)]) == nil)
        // Against every clip of its take before it, not only the last one.
        #expect(SequenceRules.firstOutOfOrder(in: [
            Self.clip("c-1", 0, 5 * second), Self.clip("c-2", 6 * second, 7 * second), Self.clip("c-3", 8 * second, 9 * second),
        ]) == nil)
    }

    @Test func audioShiftLimits() {
        let second = Self.second
        let tenth = second / 10
        // The first clip, a clip with content and the one after it are never moved.
        #expect(SequenceRules.audioShiftRange(of: Self.frozen, at: 0) == 0...0)
        #expect(SequenceRules.audioShiftRange(of: Self.frozen, at: 1) == 0...0)
        #expect(SequenceRules.audioShiftRange(of: Self.frozen, at: 2) == 0...0)
        #expect(SequenceRules.audioShiftRange(of: Self.frozen, at: 3) == 0...0)
        #expect(SequenceRules.audioShiftRange(of: Self.frozen, at: -1) == 0...0)
        // Half of the shorter clip at the edge, in output: 1 s and 0.4 s.
        let pair = [Self.clip("c-1", 0, second, shift: 0), Self.clip("c-2", 2 * second, 2 * second + 4 * tenth, shift: 9 * tenth)]
        #expect(SequenceRules.audioShiftRange(of: pair, at: 1) == (-2 * tenth)...(2 * tenth))
        #expect(SequenceRules.audioShift(of: pair, at: 1) == 2 * tenth)
        var j = pair
        j[1].audioShift = -9 * tenth
        #expect(SequenceRules.audioShift(of: j, at: 1) == -2 * tenth)
        j[1].audioShift = -tenth
        #expect(SequenceRules.audioShift(of: j, at: 1) == -tenth)
        #expect(SequenceRules.audioShift(of: j, at: 7) == 0)
        // At its speed: 0.4 s at 2× lasts 0.2 s; an odd duration is halved down.
        let fast = [Self.clip("c-1", 0, second), Self.clip("c-2", 2 * second, 2 * second + 4 * tenth, speed: 2)]
        #expect(SequenceRules.audioShiftRange(of: fast, at: 1) == (-tenth)...tenth)
        let odd = [Self.clip("c-1", 0, 3), Self.clip("c-2", 5, 10)]
        #expect(SequenceRules.audioShiftRange(of: odd, at: 1) == -1...1)
        // The time map moves the sound and nothing else.
        let map = TimeMap(sequence: pair)
        #expect(map.clipOutputStarts == [0, second])
        #expect(map.audioStarts == [0, second + 2 * tenth])
        let unmoved = TimeMap(sequence: [pair[0], Self.clip("c-2", 2 * second, 2 * second + 4 * tenth)])
        #expect(map.duration == unmoved.duration && map.clipOutputStarts == unmoved.clipOutputStarts)
        #expect(map.source(atOutput: second)?.source == unmoved.source(atOutput: second)?.source)
        // A shift held to 0 there: after a content clip.
        var afterContent = Self.frozen
        afterContent[2].audioShift = 3 * tenth
        #expect(SequenceRules.audioShift(of: afterContent, at: 2) == 0)
        #expect(TimeMap(sequence: afterContent).audioStarts == TimeMap(sequence: Self.frozen).audioStarts)

        // With the takes' bounds: the J never reads before its take's start, the L never past the end of its own.
        let takes = [
            "take-001": Self.ns(0)...Self.ns(10 * second),
            "take-002": Self.ns(5 * second - tenth)...Self.ns(20 * second),
        ]
        let across = [
            Self.clip("c-1", 9 * second + 5 * tenth, 10 * second - tenth), Self.clip("c-2", 5 * second, 6 * second, take: "take-002"),
        ]
        // Half of 0.4 s is 0.2 s; take-002 starts 0.1 s before c-2, and take-001 ends 0.1 s after c-1.
        #expect(SequenceRules.audioShiftRange(of: across, at: 1) == (-2 * tenth)...(2 * tenth))
        #expect(SequenceRules.audioShiftRange(of: across, at: 1, takeBounds: takes) == (-tenth)...tenth)
        #expect(SequenceRules.audioShiftRange(of: across, at: 1, takeBounds: [:]) == (-2 * tenth)...(2 * tenth))
        // At 2×, the 0.1 s of take before c-2 last 0.05 s of output.
        var fastAcross = across
        fastAcross[1].speed = 2
        #expect(SequenceRules.audioShiftRange(of: fastAcross, at: 1, takeBounds: takes) == (-tenth / 2)...tenth)
        // The limits are where `audioSource` reads the edges of the take.
        for shift in [-tenth / 2, tenth] {
            var moved = fastAcross
            moved[1].audioShift = shift
            let map = TimeMap(sequence: moved)
            let start = map.audioSource(ofClip: 1, atOutput: map.audioStarts[1])
            let end = map.audioSource(ofClip: 0, atOutput: map.audioStarts[1])
            if shift < 0 { #expect(start == Int64(takes["take-002"]!.lowerBound.nanoseconds)) }
            if shift > 0 { #expect(end == Int64(takes["take-001"]!.upperBound.nanoseconds)) }
        }
        // A clip at the very edge of its take has no room on that side.
        let edges = ["take-001": Self.ns(0)...Self.ns(10 * second - tenth), "take-002": Self.ns(5 * second)...Self.ns(20 * second)]
        #expect(SequenceRules.audioShiftRange(of: across, at: 1, takeBounds: edges) == 0...0)
        // A clip that starts before its take's bounds (a document edited by hand) has no J at all.
        #expect(SequenceRules.audioShiftRange(of: across, at: 1, takeBounds: ["take-002": Self.ns(6 * second)...Self.ns(7 * second)])
            == 0...(2 * tenth))
    }

    @Test func audioSourceExtrapolates() {
        let second = Self.second
        let tenth = second / 10
        let sequence = [Self.clip("c-1", 0, second), Self.clip("c-2", 5 * second, 7 * second, speed: 2)]
        let map = TimeMap(sequence: sequence)
        #expect(map.clipOutputStarts == [0, second])
        // Before the clip, at 2×: 0.1 s of output before it is 0.2 s of source before its start.
        #expect(map.audioSource(ofClip: 1, atOutput: second - tenth) == 5 * second - 2 * tenth)
        #expect(map.audioSource(ofClip: 1, atOutput: second) == 5 * second)
        #expect(map.audioSource(ofClip: 1, atOutput: second + tenth) == 5 * second + 2 * tenth)
        // After the clip: past its end.
        #expect(map.audioSource(ofClip: 0, atOutput: second + tenth) == second + tenth)
        // Signed: before host time 0.
        #expect(map.audioSource(ofClip: 0, atOutput: -tenth) == -tenth)
        #expect(map.audioSource(ofClip: 1, atOutput: -second) == 5 * second - 4 * second)
        // Saturating.
        #expect(map.audioSource(ofClip: 1, atOutput: .min) == .min)
        #expect(map.audioSource(ofClip: 1, atOutput: .max) == .max)
        // Inside a clip, the instant `source(atOutput:)` shows.
        for τ in stride(from: Int64(0), to: map.duration, by: 37_000_001) {
            let shown = map.source(atOutput: τ)!
            #expect(map.audioSource(ofClip: shown.clip, atOutput: τ) == Int64(shown.source.nanoseconds), "\(τ)")
        }
    }
}
