// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

/// Two clips of 4 s at 1× with a cut of 5 s between them: `c-1` over the source [101 s, 105 s) and `c-2` over
/// [110 s, 114 s), at outputs [0 s, 4 s) and [4 s, 8 s).
private enum Clips {
    static let take = "take-001"

    /// The source instant `seconds` after host time 0.
    static func at(_ seconds: Double) -> HostTime { HostTime(nanoseconds: 0).adding(seconds: seconds) }

    static func clip(_ id: String, _ from: Double, _ to: Double, speed: Double = 1) -> Clip {
        Clip(id: id, take: take, start: at(from), end: at(to), speed: speed)
    }

    static let first = clip("c-1", 101, 105)
    static let second = clip("c-2", 110, 114)
    static let both = [first, second]
}

/// `seconds` of output, in nanoseconds.
private func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

@Suite struct PlayheadRuleTests {
    @Test func aSpeedChangeKeepsTheInstantAtItsNewTime() {
        // The first clip at 2×: [0 s, 2 s), the second from 2 s.
        let faster = [Clips.clip("c-1", 101, 105, speed: 2), Clips.second]
        // Source 104 s, 3 s into the first clip: 1.5 s at 2×.
        #expect(PlayheadRule.output(afterChange: output(3), from: Clips.both, to: faster) == 1_500_000_000)
        // Source 111 s, in the second clip: 2 s earlier.
        #expect(PlayheadRule.output(afterChange: output(5), from: Clips.both, to: faster) == 3_000_000_000)
        // Back to 1×, the same instants come back.
        #expect(PlayheadRule.output(afterChange: 1_500_000_000, from: faster, to: Clips.both) == 3_000_000_000)
    }

    @Test func aTrimKeepsWhatItKeepsAndGoesToTheNewEdgeOtherwise() {
        // The first clip's start trimmed to 102 s: [0 s, 3 s).
        let trimmedStart = [Clips.clip("c-1", 102, 105), Clips.second]
        #expect(PlayheadRule.output(afterChange: output(2), from: Clips.both, to: trimmedStart) == 1_000_000_000)
        // Source 101.5 s was trimmed away: the clip's new start.
        #expect(PlayheadRule.output(afterChange: output(0.5), from: Clips.both, to: trimmedStart) == 0)
        // The first clip's end trimmed to 104 s: source 104.5 s goes to the join with the second clip, at 3 s.
        let trimmedEnd = [Clips.clip("c-1", 101, 104), Clips.second]
        #expect(PlayheadRule.output(afterChange: output(3.5), from: Clips.both, to: trimmedEnd) == 3_000_000_000)
        #expect(PlayheadRule.output(afterChange: output(5), from: Clips.both, to: trimmedEnd) == 4_000_000_000)
    }

    @Test func aDeleteKeepsWhatItKeepsAndGoesToTheNextClipOtherwise() {
        let withoutFirst = [Clips.second]
        // A delete before the playhead: source 111 s, now 1 s in.
        #expect(PlayheadRule.output(afterChange: output(5), from: Clips.both, to: withoutFirst) == 1_000_000_000)
        // The playhead's clip deleted: the start of the clip after it.
        #expect(PlayheadRule.output(afterChange: output(1), from: Clips.both, to: withoutFirst) == 0)
        // The last clip deleted with the playhead in it: the end.
        let withoutSecond = [Clips.first]
        #expect(PlayheadRule.output(afterChange: output(6), from: Clips.both, to: withoutSecond) == 4_000_000_000)
        #expect(PlayheadRule.output(afterChange: output(2), from: Clips.both, to: withoutSecond) == 2_000_000_000)
    }

    @Test func aCutThatRemovesThePlayheadsInstantGoesToTheJoin() {
        // Output [1 s, 2 s) cut out of the first clip: [101 s, 102 s) and [103 s, 105 s), then the second clip from 3 s.
        let cut = [Clips.clip("c-1", 101, 102), Clips.clip("c-3", 103, 105), Clips.second]
        #expect(PlayheadRule.output(afterChange: output(1.5), from: Clips.both, to: cut) == 1_000_000_000)
        // Kept instants move with the cut closed.
        #expect(PlayheadRule.output(afterChange: output(2.5), from: Clips.both, to: cut) == 1_500_000_000)
        #expect(PlayheadRule.output(afterChange: output(6), from: Clips.both, to: cut) == 5_000_000_000)
        #expect(PlayheadRule.output(afterChange: output(0.25), from: Clips.both, to: cut) == 250_000_000)
    }

    @Test func theSameSequenceLeavesThePlayheadAndNoOutputGivesZero() {
        #expect(PlayheadRule.output(afterChange: 1_234_567, from: Clips.both, to: Clips.both) == 1_234_567)
        #expect(PlayheadRule.output(afterChange: output(3), from: [], to: Clips.both) == 0)
    }

    @Test func framesOfTheGrid() {
        // At or before: the frame the engine plays, from each frame's own time.
        for n in 0..<600 {
            let seconds = Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9
            #expect(PlayheadRule.frame(atOrBefore: seconds, frameRate: 60, frameCount: 600) == n)
            #expect(PlayheadRule.frame(atOrBefore: seconds + 0.9 / 60, frameRate: 60, frameCount: 600) == n)
            #expect(PlayheadRule.frame(nearest: seconds + 0.4 / 60, frameRate: 60, frameCount: 600) == n)
            #expect(PlayheadRule.frame(nearest: seconds + 0.6 / 60, frameRate: 60, frameCount: 600) == min(n + 1, 599))
        }
        #expect(PlayheadRule.frame(atOrBefore: 1.5, frameRate: 24, frameCount: 100) == 36)
        #expect(PlayheadRule.frame(nearest: 1.52, frameRate: 25, frameCount: 100) == 38)
        // Within the grid.
        #expect(PlayheadRule.frame(atOrBefore: 100, frameRate: 60, frameCount: 600) == 599)
        #expect(PlayheadRule.frame(nearest: -1, frameRate: 60, frameCount: 600) == 0)
        #expect(PlayheadRule.frame(atOrBefore: .nan, frameRate: 60, frameCount: 600) == 0)
        #expect(PlayheadRule.frame(nearest: 3, frameRate: 60, frameCount: 0) == 0)
    }
}
