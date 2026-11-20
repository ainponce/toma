// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the volume stretches' tests, namespaced so that no other file of EditingTests meets its names: documents
/// whose sequence is made of clips of `take-001` and `take-002` (both recorded for 60 s from `base`, at 1× unless said),
/// with the audio track `mic` in the takes `tracks` names.
private enum RangeFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    static func clip(_ n: Int, _ take: String = "take-001", from: Double, to: Double, speed: Double = 1, shift: Int64 = 0) -> Clip {
        Clip(id: "c-0000000\(n)", take: take, start: at(from), end: at(to), speed: speed, audioShift: shift)
    }

    static func range(_ id: String, _ take: String = "take-001", from: Double, to: Double, gain: Double = -6) -> GainRange {
        GainRange(id: id, take: take, start: at(from), end: at(to), gain: gain)
    }

    static func document(
        _ sequence: [Clip], tracks: [String: [GainRange]] = ["take-001/mic": []]
    ) -> EditDocument {
        var document = EditDocument.legacy(take: take("take-001"), events: [])
        document.sequence = sequence
        document.audio.tracks = tracks.mapValues { TrackGain(gain: 1, muted: false, ranges: $0) }
        return document
    }

    static func take(_ id: String) -> TakeRecord {
        TakeRecord(
            id: id, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "display-1", kind: .display,
                    source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                    segments: [
                        SegmentRecord(
                            index: 1, file: "takes/\(id)/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(60),
                            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                    ])
            ])
    }

    /// Applies `step` and checks it undoes; the edited document holds, and decodes.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        #expect(DocumentRules.problems(in: edited).isEmpty)
        return edited
    }

    static func ids() -> (String) -> String {
        let count = Counter()
        return { prefix in prefix + String(format: "%08x", count.next()) }
    }

    final class Counter: @unchecked Sendable {
        private var value = 0
        func next() -> Int { value += 1; return value }
    }
}

@Suite struct AudioRangeCommandsTests {
    private typealias F = RangeFixture

    @Test func aRangeIsAnchoredToTheSource() throws {
        // [0, 2) s and [3, 10) s of the take: the cut between them closes in the output.
        let document = F.document([F.clip(1, from: 0, to: 2), F.clip(2, from: 3, to: 10)])
        let map = TimeMap(sequence: document.sequence)
        let step = try #require(AudioRangeCommands.addRange(
            document, track: "mic", takes: ["take-001"], forOutput: F.output(1)..<F.output(4), gain: -20, timeMap: map, makeID: F.ids()))
        #expect(step.label == .audioRange)
        #expect(step.target == "g-00000001")
        let edited = try F.applying(step, to: document)
        // Its end is the source of 1 ns before the output end, and 1 ns: the output's 4 s is the take's 5 s.
        #expect(edited.audio.tracks["take-001/mic"]?.ranges == [F.range("g-00000001", from: 1, to: 5, gain: -20)])
        #expect(AudioRangeCommands.shownRanges(edited, track: "mic", timeMap: map)
            == [.init(id: "g-00000001", output: F.output(1)..<F.output(4), gain: -20)])
    }

    @Test func aRangeOverTwoTakesIsOneIDInEach() throws {
        let document = F.document(
            [F.clip(1, from: 0, to: 3), F.clip(2, "take-002", from: 0, to: 3)],
            tracks: ["take-001/mic": [], "take-002/mic": []])
        let map = TimeMap(sequence: document.sequence)
        let step = try #require(AudioRangeCommands.addRange(
            document, track: "mic", takes: ["take-001", "take-002"], forOutput: F.output(2)..<F.output(4), gain: -10,
            timeMap: map, makeID: F.ids()))
        let edited = try F.applying(step, to: document)
        #expect(edited.audio.tracks["take-001/mic"]?.ranges == [F.range("g-00000001", from: 2, to: 3, gain: -10)])
        #expect(edited.audio.tracks["take-002/mic"]?.ranges == [F.range("g-00000001", "take-002", from: 0, to: 1, gain: -10)])
        // Shown as one stretch.
        #expect(AudioRangeCommands.shownRanges(edited, track: "mic", timeMap: map).map(\.output) == [F.output(2)..<F.output(4)])

        let louder = try #require(AudioRangeCommands.setGain(edited, track: "mic", id: "g-00000001", gain: 3))
        #expect(louder.label == .audioRange)
        let after = try F.applying(louder, to: edited)
        #expect(after.audio.tracks.values.flatMap(\.ranges).map(\.gain) == [3, 3])
        #expect(AudioRangeCommands.setGain(after, track: "mic", id: "g-00000001", gain: 3) == nil)
        #expect(AudioRangeCommands.setGain(after, track: "mic", id: "g-nope", gain: 1) == nil)

        let gone = try #require(AudioRangeCommands.delete(after, track: "mic", id: "g-00000001"))
        #expect(try F.applying(gone, to: after).audio.tracks.values.allSatisfy { $0.ranges.isEmpty })
    }

    @Test func aNewRangeCutsTheOldOnes() throws {
        let old = [F.range("g-a", from: 1, to: 5), F.range("g-b", from: 6, to: 7), F.range("g-c", from: 8, to: 9)]
        let document = F.document([F.clip(1, from: 0, to: 10)], tracks: ["take-001/mic": old])
        let map = TimeMap(sequence: document.sequence)

        // Inside one: it splits in two, the second with a new id.
        let inside = try #require(AudioRangeCommands.addRange(
            document, track: "mic", takes: ["take-001"], forOutput: F.output(2)..<F.output(3), gain: 0, timeMap: map, makeID: F.ids()))
        let split = try F.applying(inside, to: document).audio.tracks["take-001/mic"]?.ranges ?? []
        #expect(split.map(\.id) == ["g-a", "g-00000001", "g-00000002", "g-b", "g-c"])
        #expect(split.prefix(3).map { [$0.start, $0.end] } == [[F.at(1), F.at(2)], [F.at(2), F.at(3)], [F.at(3), F.at(5)]])

        // Over a tail, a whole one and a head: trimmed, gone, trimmed.
        let over = try #require(AudioRangeCommands.addRange(
            document, track: "mic", takes: ["take-001"], forOutput: F.output(4)..<F.output(8.5), gain: 0, timeMap: map, makeID: F.ids()))
        let cut = try F.applying(over, to: document).audio.tracks["take-001/mic"]?.ranges ?? []
        #expect(cut.map { [$0.start, $0.end] } == [[F.at(1), F.at(4)], [F.at(4), F.at(8.5)], [F.at(8.5), F.at(9)]])
        #expect(cut.map(\.id) == ["g-a", "g-00000001", "g-c"])
    }

    @Test func aKeyWithoutTrackGainIsMade() throws {
        let document = F.document([F.clip(1, from: 0, to: 10)], tracks: [:])
        let map = TimeMap(sequence: document.sequence)
        let step = try #require(AudioRangeCommands.addRange(
            document, track: "mic", takes: ["take-001"], forOutput: F.output(1)..<F.output(2), gain: -6, timeMap: map, makeID: F.ids()))
        #expect(step.changes.count == 1)
        #expect(step.target == "g-00000001")
        let edited = try F.applying(step, to: document)
        #expect(edited.audio.tracks["take-001/mic"] == TrackGain(gain: 1, muted: false, ranges: [F.range("g-00000001", from: 1, to: 2)]))
    }

    @Test func tooShortOrNothingShownIsNil() throws {
        let document = F.document([
            F.clip(1, from: 0, to: 5),
            Clip(id: "c-00000002", take: "take-001", start: F.at(5), end: F.at(5), speed: 1, content: .freeze(duration: 2_000_000_000)),
        ])
        let map = TimeMap(sequence: document.sequence)
        func add(_ range: Range<Int64>, takes: [String] = ["take-001"]) -> EditStep? {
            AudioRangeCommands.addRange(document, track: "mic", takes: takes, forOutput: range, gain: 0, timeMap: map, makeID: F.ids())
        }
        #expect(add(F.output(1)..<(F.output(1) + 90_000_000)) == nil)
        #expect(add(F.output(1)..<(F.output(1) + 100_000_000)) != nil)
        // Over the frozen frame (5 s to 7 s of output): nothing is heard.
        #expect(add(F.output(5.2)..<F.output(6.9)) == nil)
        #expect(add(F.output(1)..<F.output(2), takes: ["take-002"]) == nil)
        #expect(add(F.output(1)..<F.output(2), takes: []) == nil)
    }

    @Test func gainIsHeld() throws {
        let document = F.document([F.clip(1, from: 0, to: 10)])
        let map = TimeMap(sequence: document.sequence)
        func gain(_ value: Double) -> Double? {
            guard
                let step = AudioRangeCommands.addRange(
                    document, track: "mic", takes: ["take-001"], forOutput: F.output(1)..<F.output(2), gain: value, timeMap: map, makeID: F.ids()),
                let edited = try? document.applying(step.changes)
            else { return nil }
            return edited.audio.tracks["take-001/mic"]?.ranges.first?.gain
        }
        #expect(gain(20) == 12)
        #expect(gain(-200) == -120)
        #expect(gain(-120) == -120)
        #expect(gain(.nan) == nil)
        let with = F.document([F.clip(1, from: 0, to: 10)], tracks: ["take-001/mic": [F.range("g-a", from: 1, to: 2)]])
        #expect(AudioRangeCommands.setGain(with, track: "mic", id: "g-a", gain: .nan) == nil)
        let held = try #require(AudioRangeCommands.setGain(with, track: "mic", id: "g-a", gain: 99))
        #expect(try F.applying(held, to: with).audio.tracks["take-001/mic"]?.ranges.first?.gain == 12)
    }

    @Test func shownRangesFollowTheCuts() throws {
        // take-001 [0, 2) and [2, 4), with a stretch of take-002 between them: the output is 1 s of take-002 apart.
        let document = F.document(
            [F.clip(1, from: 0, to: 2), F.clip(2, "take-002", from: 0, to: 1), F.clip(3, from: 2, to: 4), F.clip(4, from: 10, to: 12)],
            tracks: ["take-001/mic": [
                F.range("g-a", from: 1, to: 3.5), F.range("g-gone", from: 5, to: 6), F.range("g-closed", from: 3.5, to: 11)
            ]])
        let map = TimeMap(sequence: document.sequence)
        let shown = AudioRangeCommands.shownRanges(document, track: "mic", timeMap: map)
        #expect(shown.filter { $0.id == "g-a" }.map(\.output) == [F.output(1)..<F.output(2), F.output(3)..<F.output(4.5)])
        // Cut whole: nothing. A range over a cut of the take is one stretch in the output.
        #expect(!shown.contains { $0.id == "g-gone" })
        #expect(shown.filter { $0.id == "g-closed" }.map(\.output) == [F.output(4.5)..<F.output(6)])
        // Another track has no stretches.
        #expect(AudioRangeCommands.shownRanges(document, track: "system-audio", timeMap: map).isEmpty)
    }

    @Test func aStretchFollowsTheSoundNotThePicture() throws {
        // An L cut of 1 s at clip 2: clip 1's sound plays to 5 s.
        let document = F.document(
            [F.clip(1, from: 0, to: 4), F.clip(2, from: 4, to: 8, shift: 1_000_000_000)],
            tracks: ["take-001/mic": [F.range("g-a", from: 3, to: 5)]])
        let map = TimeMap(sequence: document.sequence)
        #expect(AudioRangeCommands.shownRanges(document, track: "mic", timeMap: map).map(\.output) == [F.output(3)..<F.output(5)])
    }

    @Test func trimStopsAtItsNeighborsAndTheMinimum() throws {
        let document = F.document(
            [F.clip(1, from: 0, to: 10)], tracks: ["take-001/mic": [F.range("g-a", from: 1, to: 2), F.range("g-b", from: 4, to: 6)]])
        let map = TimeMap(sequence: document.sequence)
        let end = try #require(AudioRangeCommands.trim(document, track: "mic", id: "g-a", edge: .end, toOutput: F.output(9), timeMap: map))
        #expect(try F.applying(end, to: document).audio.tracks["take-001/mic"]?.ranges.first?.end == F.at(4))
        let start = try #require(AudioRangeCommands.trim(document, track: "mic", id: "g-b", edge: .start, toOutput: F.output(0), timeMap: map))
        #expect(try F.applying(start, to: document).audio.tracks["take-001/mic"]?.ranges.last?.start == F.at(2))
        let short = try #require(AudioRangeCommands.trim(document, track: "mic", id: "g-a", edge: .end, toOutput: F.output(1), timeMap: map))
        #expect(try F.applying(short, to: document).audio.tracks["take-001/mic"]?.ranges.first?.end == F.at(1.1))
        #expect(AudioRangeCommands.trim(document, track: "mic", id: "g-a", edge: .end, toOutput: F.output(2), timeMap: map) == nil)
        #expect(AudioRangeCommands.trim(document, track: "mic", id: "g-x", edge: .end, toOutput: F.output(2), timeMap: map) == nil)
    }

    @Test func shiftStopsAtItsLimits() throws {
        let document = F.document([F.clip(1, from: 0, to: 4), F.clip(2, from: 4, to: 8)])
        let bounds = ["take-001": F.at(0)...F.at(60)]
        // Half of the shorter clip: 2 s.
        #expect(AudioRangeCommands.shiftLimits(document, clip: 1, takeBounds: bounds) == -2_000_000_000...2_000_000_000)
        let later = try #require(AudioRangeCommands.setAudioShift(document, clip: 1, to: 5_000_000_000, takeBounds: bounds))
        #expect(later.label == .audioShift)
        #expect(later.target == "c-00000002")
        let edited = try F.applying(later, to: document)
        #expect(edited.sequence[1].audioShift == 2_000_000_000)
        let sooner = try #require(AudioRangeCommands.setAudioShift(edited, clip: 1, to: -5_000_000_000, takeBounds: bounds))
        #expect(try F.applying(sooner, to: edited).sequence[1].audioShift == -2_000_000_000)
        // Back to 0 is a step; the same is not.
        #expect(AudioRangeCommands.setAudioShift(edited, clip: 1, to: 0, takeBounds: bounds) != nil)
        #expect(AudioRangeCommands.setAudioShift(edited, clip: 1, to: 2_000_000_000, takeBounds: bounds) == nil)
        #expect(AudioRangeCommands.setAudioShift(document, clip: 1, to: 0, takeBounds: bounds) == nil)
        // The first clip, one that is not there and one beside content have no cut that moves.
        #expect(AudioRangeCommands.setAudioShift(document, clip: 0, to: 1_000_000_000, takeBounds: bounds) == nil)
        #expect(AudioRangeCommands.setAudioShift(document, clip: 7, to: 1_000_000_000, takeBounds: bounds) == nil)
        var withContent = document
        withContent.sequence.insert(
            Clip(id: "c-00000009", take: "take-001", start: F.at(4), end: F.at(4), speed: 1, content: .freeze(duration: 2_000_000_000)), at: 1)
        #expect(AudioRangeCommands.setAudioShift(withContent, clip: 2, to: 1_000_000_000, takeBounds: bounds) == nil)
        // What there is of the take holds a J cut: clip 2 starts 1 s into the take.
        let tight = F.document([F.clip(1, from: 0.5, to: 4), F.clip(2, from: 4, to: 8)])
        let tightBounds = ["take-001": F.at(0)...F.at(60)]
        let limits = AudioRangeCommands.shiftLimits(tight, clip: 1, takeBounds: tightBounds)
        #expect(limits.lowerBound >= -2_000_000_000 && limits.upperBound <= 2_000_000_000)
        let first = F.document([F.clip(1, from: 0, to: 4), F.clip(2, from: 1, to: 5)])
        let holding = AudioRangeCommands.shiftLimits(first, clip: 1, takeBounds: ["take-001": F.at(0)...F.at(60)])
        #expect(holding.lowerBound == -1_000_000_000)
    }
}
