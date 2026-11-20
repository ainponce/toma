// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the sequence commands' and the edit points' tests, namespaced so that no other file of EditingTests
/// meets its names: two clips of 4 s at 1× with a cut of 5 s between them, `c-00000001` over the source [101 s, 105 s)
/// and `c-00000002` over [110 s, 114 s), of a take whose timeline is [100 s, 130 s), at 60 fps.
enum TwoClips {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 100_000_000_000)

    /// The source instant `seconds` after the start of the take's timeline, and `plus` nanoseconds.
    static func at(_ seconds: Double, plus nanoseconds: Int64 = 0) -> HostTime {
        HostTime(nanoseconds: UInt64(Int64(base.adding(seconds: seconds).nanoseconds) + nanoseconds))
    }

    /// `seconds` of output, in nanoseconds.
    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// The output from `from` to `to` seconds.
    static func range(_ from: Double, _ to: Double) -> Range<Int64> { output(from)..<output(to) }

    /// One frame at 60 fps: 16 666 667 ns.
    static let frame = TimeMap.frameTime(1, frameRate: 60)

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display, source: TrackSource(name: "Display", displayID: 1),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: at(0), endHostTime: at(30),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    static func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
        clip("c-0000000\(number)", from: from, to: to, speed: speed)
    }

    /// A clip with the id `id`, as a command makes a new one.
    static func clip(_ id: String, from: Double, to: Double, speed: Double = 1) -> Clip {
        Clip(id: id, take: takeID, start: at(from), end: at(to), speed: speed)
    }

    static func document(_ sequence: [Clip] = [clip(1, from: 1, to: 5), clip(2, from: 10, to: 14)]) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = sequence
        return document
    }

    static func duration(_ document: EditDocument) -> Int64 { TimeMap(sequence: document.sequence).duration }

    static func limits(
        _ clipID: String, _ edge: ClipEdge, in document: EditDocument, events: [InputEvent] = []
    ) -> ClosedRange<HostTime> {
        SequenceCommands.trimLimits(document, clipID: clipID, edge: edge, take: take, events: events)
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// A `makeID` that counts `c-00000010`, `c-00000011`… as it is asked.
    final class CountingIDs {
        private var next = 0x10
        private(set) var made: [String] = []

        func make(_ prefix: String) -> String {
            let hex = String(next, radix: 16)
            next += 1
            let id = prefix + String(repeating: "0", count: 8 - hex.count) + hex
            made.append(id)
            return id
        }
    }

    /// A new `CountingIDs`' `make`.
    static var newIDs: (String) -> String { CountingIDs().make }
}

// MARK: - Split

@Test func splitMakesTwoClipsThatTouch() throws {
    let document = TwoClips.document()
    let ids = TwoClips.CountingIDs()
    let step = try #require(SequenceCommands.split(document, atOutput: TwoClips.output(1.5), makeID: ids.make))
    #expect(step.label == .split)
    #expect(step.target == "c-00000001")
    let first = TwoClips.clip("c-00000001", from: 1, to: 2.5)
    let second = TwoClips.clip("c-00000010", from: 2.5, to: 5)
    #expect(
        step.changes == [
            try #require(document.replaceChange(.sequence, id: "c-00000001", with: first)),
            document.insertChange(.sequence, at: 1, second),
        ])
    #expect(ids.made == ["c-00000010"])
    let edited = try TwoClips.applying(step, to: document)
    #expect(edited.sequence == [first, second, document.sequence[1]])
    #expect(TwoClips.duration(edited) == TwoClips.duration(document))
}

@Test func splitAtAnEdgeDoesNothing() {
    let document = TwoClips.document()
    func split(at output: Int64) -> EditStep? { SequenceCommands.split(document, atOutput: output, makeID: TwoClips.newIDs) }
    // The start, the edge between the clips, the end, outside the output, and less than a frame from an edge.
    for seconds in [0, 4, 8, -1, 9, 0.008, 4 - 0.008, 4 + 0.008, 8 - 0.008] {
        #expect(split(at: TwoClips.output(seconds)) == nil, "at \(seconds) s")
    }
    // A frame from an edge is a clip of a frame; a nanosecond less is not.
    let edge = TwoClips.output(4)
    #expect(split(at: edge + TwoClips.frame) != nil)
    #expect(split(at: edge + TwoClips.frame - 1) == nil)
    #expect(split(at: edge - TwoClips.frame) != nil)
    #expect(split(at: edge - TwoClips.frame + 1) == nil)
}

@Test func splitAtTheSourceShownAtThatInstant() throws {
    // At 2×, output 1 s shows the source 2 s into the clip; both halves keep the speed.
    let document = TwoClips.document([TwoClips.clip(1, from: 1, to: 5, speed: 2)])
    let step = try #require(SequenceCommands.split(document, atOutput: TwoClips.output(1), makeID: TwoClips.newIDs))
    let edited = try TwoClips.applying(step, to: document)
    #expect(
        edited.sequence == [TwoClips.clip(1, from: 1, to: 3, speed: 2), TwoClips.clip("c-00000010", from: 3, to: 5, speed: 2)])
    #expect(TwoClips.duration(edited) == TwoClips.output(2))
}

@Test func splitARangeAtBothEdges() throws {
    let document = TwoClips.document()
    func split(_ range: Range<Int64>) -> EditStep? { SequenceCommands.split(document, range: range, makeID: TwoClips.newIDs) }
    // Inside one clip: three pieces, the new ones in order after it.
    let inside = try #require(split(TwoClips.range(1, 2)))
    #expect(inside.label == .split)
    #expect(inside.target == "c-00000001")
    #expect(
        try TwoClips.applying(inside, to: document).sequence == [
            TwoClips.clip(1, from: 1, to: 2), TwoClips.clip("c-00000010", from: 2, to: 3),
            TwoClips.clip("c-00000011", from: 3, to: 5), TwoClips.clip(2, from: 10, to: 14),
        ])
    // Across the edge between the clips: each one split once.
    let across = try #require(split(TwoClips.range(3, 5)))
    #expect(
        try TwoClips.applying(across, to: document).sequence == [
            TwoClips.clip(1, from: 1, to: 4), TwoClips.clip("c-00000010", from: 4, to: 5),
            TwoClips.clip(2, from: 10, to: 11), TwoClips.clip("c-00000011", from: 11, to: 14),
        ])
    // An edge on a clip's edge splits only at the other one; with both on edges, nothing.
    let oneEdge = try #require(split(TwoClips.range(4, 6)))
    #expect(oneEdge.target == "c-00000002")
    #expect(try TwoClips.applying(oneEdge, to: document).sequence.count == 3)
    #expect(split(TwoClips.range(0, 8)) == nil)
    // A range shorter than a frame: the second edge would leave a sliver, so only the first one splits.
    let short = try #require(split(TwoClips.output(1)..<(TwoClips.output(1) + TwoClips.frame - 1)))
    #expect(try TwoClips.applying(short, to: document).sequence.map(\.start) == [TwoClips.at(1), TwoClips.at(2), TwoClips.at(10)])
}

@Test func newClipIDsAreNeverOnesInUse() throws {
    let document = TwoClips.document()
    // A `makeID` that only gives an id in use: the first free one counting from 1.
    let step = try #require(SequenceCommands.split(document, atOutput: TwoClips.output(1), makeID: { $0 + "00000002" }))
    #expect(try TwoClips.applying(step, to: document).sequence.map(\.id) == ["c-00000001", "c-00000003", "c-00000002"])
}

// MARK: - Delete

@Test func deleteClosesTheGap() throws {
    let document = TwoClips.document()
    let step = try SequenceCommands.delete(document, clipIDs: ["c-00000001"], takeBounds: [:]).get()
    #expect(step.label == .delete)
    #expect(step.target == "c-00000001")
    #expect(step.changes == [try #require(document.removeChange(.sequence, at: 0))])
    let edited = try TwoClips.applying(step, to: document)
    #expect(edited.sequence == [TwoClips.clip(2, from: 10, to: 14)])
    let map = TimeMap(sequence: edited.sequence)
    #expect(map.duration == TwoClips.output(4))
    #expect(map.clipOutputStarts == [0])
}

@Test func deletingTheLastClipIsRefused() throws {
    let document = TwoClips.document()
    #expect(SequenceCommands.delete(document, clipIDs: ["c-00000001", "c-00000002"], takeBounds: [:]) == .failure(.lastClip))
    // What is left has to be at least a frame long.
    let sliver = TwoClips.document([TwoClips.clip(1, from: 1, to: 5), TwoClips.clip(2, from: 10, to: 10.01)])
    #expect(SequenceCommands.delete(sliver, clipIDs: ["c-00000001"], takeBounds: [:]) == .failure(.lastClip))
    // Ids that are not in the sequence: nothing to do.
    #expect(try SequenceCommands.delete(document, clipIDs: ["c-0000000f"], takeBounds: [:]).get().changes == [])
}

@Test func deleteSeveralClips() throws {
    let document = TwoClips.document([
        TwoClips.clip(1, from: 1, to: 2), TwoClips.clip(2, from: 3, to: 4), TwoClips.clip(3, from: 5, to: 6),
    ])
    let step = try SequenceCommands.delete(document, clipIDs: ["c-00000003", "c-00000001"], takeBounds: [:]).get()
    #expect(step.target == "c-00000001,c-00000003")
    #expect(try TwoClips.applying(step, to: document).sequence == [TwoClips.clip(2, from: 3, to: 4)])
}

@Test func deleteRangeInOneStep() throws {
    let document = TwoClips.document()
    let step = try SequenceCommands.deleteRange(document, output: TwoClips.range(3, 5), takeBounds: [:], makeID: TwoClips.newIDs).get()
    #expect(step.label == .delete)
    #expect(step.target == "c-00000001,c-00000002")
    #expect(
        step.changes == [
            try #require(document.replaceChange(.sequence, id: "c-00000001", with: TwoClips.clip(1, from: 1, to: 4))),
            try #require(document.replaceChange(.sequence, id: "c-00000002", with: TwoClips.clip(2, from: 11, to: 14))),
        ])
    let edited = try TwoClips.applying(step, to: document)
    #expect(TwoClips.duration(edited) == TwoClips.output(6))
}

@Test func deleteRangeInsideOneClipCutsIt() throws {
    let document = TwoClips.document()
    let step = try SequenceCommands.deleteRange(document, output: TwoClips.range(1, 2), takeBounds: [:], makeID: TwoClips.newIDs).get()
    let tail = TwoClips.clip("c-00000010", from: 3, to: 5)
    #expect(
        step.changes == [
            try #require(document.replaceChange(.sequence, id: "c-00000001", with: TwoClips.clip(1, from: 1, to: 2))),
            document.insertChange(.sequence, at: 1, tail),
        ])
    let edited = try TwoClips.applying(step, to: document)
    #expect(edited.sequence == [TwoClips.clip(1, from: 1, to: 2), tail, TwoClips.clip(2, from: 10, to: 14)])
    #expect(TwoClips.duration(edited) == TwoClips.output(7))
}

@Test func deleteRangeLeavingOneFrame() throws {
    let document = TwoClips.document()
    let all = TwoClips.output(8)
    let oneFrame = try SequenceCommands.deleteRange(document, output: 0..<(all - TwoClips.frame), takeBounds: [:], makeID: TwoClips.newIDs).get()
    let edited = try TwoClips.applying(oneFrame, to: document)
    #expect(
        edited.sequence == [
            Clip(id: "c-00000002", take: TwoClips.takeID, start: TwoClips.at(14, plus: -16_666_667), end: TwoClips.at(14), speed: 1)
        ])
    #expect(TwoClips.duration(edited) == TwoClips.frame)
    // Less than a frame left goes with the range, and then nothing is left; the same for everything and more.
    for range in [0..<(all - TwoClips.output(0.010)), 0..<all, TwoClips.range(-1, 9)] {
        #expect(SequenceCommands.deleteRange(document, output: range, takeBounds: [:], makeID: TwoClips.newIDs) == .failure(.lastClip))
    }
}

@Test func deleteRangeTakesASliverWithIt() throws {
    let document = TwoClips.document()
    let step = try SequenceCommands.deleteRange(document, output: TwoClips.range(0.005, 6), takeBounds: [:], makeID: TwoClips.newIDs).get()
    #expect(
        step.changes == [
            try #require(document.removeChange(.sequence, at: 0)),
            try #require(document.replaceChange(.sequence, id: "c-00000002", with: TwoClips.clip(2, from: 12, to: 14))),
        ])
    let edited = try TwoClips.applying(step, to: document)
    #expect(TwoClips.duration(edited) == TwoClips.output(2))
    // Inside one clip, a sliver at its end goes too: the clip is only trimmed, and no id is made.
    let ids = TwoClips.CountingIDs()
    let inside = try SequenceCommands.deleteRange(document, output: TwoClips.range(1, 3.995), takeBounds: [:], makeID: ids.make).get()
    #expect(
        try TwoClips.applying(inside, to: document).sequence == [
            TwoClips.clip(1, from: 1, to: 2), TwoClips.clip(2, from: 10, to: 14),
        ])
    #expect(ids.made == [])
}

@Test func deleteRangeOutsideTheOutputDoesNothing() throws {
    let document = TwoClips.document()
    for range in [TwoClips.range(8, 9), TwoClips.range(-2, -1), TwoClips.range(2, 2)] {
        #expect(try SequenceCommands.deleteRange(document, output: range, takeBounds: [:], makeID: TwoClips.newIDs).get().changes == [])
    }
}

// MARK: - Trim

@Test func trimStopsAtTheNeighbourSource() throws {
    let document = TwoClips.document()
    let limits = TwoClips.limits("c-00000001", .end, in: document)
    // From one frame of the clip to the start of the next one.
    #expect(limits == TwoClips.at(1, plus: 16_666_667)...TwoClips.at(10))
    let step = try #require(
        SequenceCommands.trim(document, clipID: "c-00000001", edge: .end, toSource: TwoClips.at(12), limits: limits, takeBounds: [:]))
    #expect(step.label == .trim)
    #expect(step.target == "c-00000001")
    let longer = TwoClips.clip(1, from: 1, to: 10)
    #expect(step.changes == [try #require(document.replaceChange(.sequence, id: "c-00000001", with: longer))])
    let edited = try TwoClips.applying(step, to: document)
    // The magnetic sequence: the next clip moves along.
    #expect(TimeMap(sequence: edited.sequence).clipOutputStarts == [0, TwoClips.output(9)])

    // The start of the second one, back to the end of the first.
    let back = TwoClips.limits("c-00000002", .start, in: document)
    #expect(back == TwoClips.at(5)...TwoClips.at(14, plus: -16_666_667))
    let start = try #require(
        SequenceCommands.trim(document, clipID: "c-00000002", edge: .start, toSource: TwoClips.at(2), limits: back, takeBounds: [:]))
    #expect(try TwoClips.applying(start, to: document).sequence[1] == TwoClips.clip(2, from: 5, to: 14))
}

@Test func trimStopsAtTheTakeEdges() throws {
    let document = TwoClips.document()
    // A pause is no limit: its frozen frame shows.
    let pauses = [
        InputEvent(t: TwoClips.at(0.5), kind: .paused(reason: "user")), InputEvent(t: TwoClips.at(0.8), kind: .resumed),
        InputEvent(t: TwoClips.at(20), kind: .paused(reason: "user")), InputEvent(t: TwoClips.at(25), kind: .resumed),
    ]
    for events in [[], pauses] {
        let limits = TwoClips.limits("c-00000001", .start, in: document, events: events)
        #expect(limits.lowerBound == TwoClips.at(0))
        let step = try #require(
            SequenceCommands.trim(document, clipID: "c-00000001", edge: .start, toSource: TwoClips.at(-5), limits: limits, takeBounds: [:]))
        #expect(try TwoClips.applying(step, to: document).sequence[0] == TwoClips.clip(1, from: 0, to: 5))

        let end = TwoClips.limits("c-00000002", .end, in: document, events: events)
        #expect(end.upperBound == TwoClips.at(30))
        let longer = try #require(
            SequenceCommands.trim(document, clipID: "c-00000002", edge: .end, toSource: TwoClips.at(40), limits: end, takeBounds: [:]))
        #expect(try TwoClips.applying(longer, to: document).sequence[1] == TwoClips.clip(2, from: 10, to: 30))
    }
}

@Test func trimKeepsAFrame() throws {
    let document = TwoClips.document()
    // Shortening past the other edge stops a frame before it.
    let limits = TwoClips.limits("c-00000001", .start, in: document)
    let step = try #require(
        SequenceCommands.trim(document, clipID: "c-00000001", edge: .start, toSource: TwoClips.at(20), limits: limits, takeBounds: [:]))
    let edited = try TwoClips.applying(step, to: document)
    #expect(TimeMap.outputDuration(of: edited.sequence[0]) == TwoClips.frame)
    // At 4×, a frame is four times as much source: 66 666 666 ns, which round(L / 4) makes 16 666 667.
    let fast = TwoClips.document([TwoClips.clip(1, from: 1, to: 5, speed: 4)])
    let shortest = TwoClips.limits("c-00000001", .end, in: fast).lowerBound
    #expect(shortest == TwoClips.at(1, plus: 66_666_666))
    #expect(TimeMap.outputDuration(of: Clip(id: "", take: "", start: TwoClips.at(1), end: shortest, speed: 4)) == TwoClips.frame)
    // Limits that would allow less, a trim that changes nothing and a clip that is not there do nothing.
    let anything = TwoClips.at(0)...TwoClips.at(30)
    func trim(_ clipID: String, toSource seconds: Double) -> EditStep? {
        SequenceCommands.trim(document, clipID: clipID, edge: .end, toSource: TwoClips.at(seconds), limits: anything, takeBounds: [:])
    }
    #expect(trim("c-00000001", toSource: 1.01) == nil)
    #expect(trim("c-00000001", toSource: 5) == nil)
    #expect(trim("c-0000000f", toSource: 6) == nil)
}

@Test func trimToThePlayhead() throws {
    let document = TwoClips.document()
    func trim(_ edge: ClipEdge, at seconds: Double) -> EditStep? {
        SequenceCommands.trimToPlayhead(document, edge: edge, atOutput: TwoClips.output(seconds), take: TwoClips.take, events: [])
    }
    let start = try #require(trim(.start, at: 1))
    #expect(start.label == .trim)
    #expect(try TwoClips.applying(start, to: document).sequence[0] == TwoClips.clip(1, from: 2, to: 5))
    let end = try #require(trim(.end, at: 6))
    #expect(try TwoClips.applying(end, to: document).sequence[1] == TwoClips.clip(2, from: 10, to: 12))
    // On an edge, less than a frame from the other edge (it does not stop short) and outside the output, nothing.
    #expect(trim(.start, at: 4) == nil)
    #expect(trim(.end, at: 4) == nil)
    #expect(trim(.end, at: 4.008) == nil)
    #expect(trim(.start, at: 8 - 0.008) == nil)
    #expect(trim(.end, at: 8) == nil)
    #expect(trim(.start, at: -1) == nil)
}

// MARK: - Speed

@Test func speedThatLeavesLessThanAFrameIsRefused() throws {
    let document = TwoClips.document([TwoClips.clip(1, from: 1, to: 1.030), TwoClips.clip(2, from: 10, to: 14)])
    // 30 ms at 4× is 7.5 ms, less than a frame of 16.7 ms; at 1.5×, 20 ms.
    #expect(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001"], speed: 4, takeBounds: [:]) == nil)
    // With another clip that could: all or nothing.
    #expect(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001", "c-00000002"], speed: 4, takeBounds: [:]) == nil)
    let step = try #require(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001"], speed: 1.5, takeBounds: [:]))
    #expect(step.label == .speed)
    #expect(step.target == "c-00000001")
    let edited = try TwoClips.applying(step, to: document)
    #expect(edited.sequence[0] == TwoClips.clip(1, from: 1, to: 1.030, speed: 1.5))
    #expect(TwoClips.duration(edited) == TwoClips.output(0.020) + TwoClips.output(4))
}

@Test func speedIsClampedToItsRange() throws {
    #expect(SequenceCommands.speedRange == ClipSpeed.range)
    #expect(SequenceCommands.speedRange == 0.25...16)
    #expect(SequenceCommands.speedPresets == [0.5, 1, 1.5, 2, 4, 8])
    let document = TwoClips.document()
    func speed(_ value: Double) throws -> Double {
        let step = try #require(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001"], speed: value, takeBounds: [:]))
        return try TwoClips.applying(step, to: document).sequence[0].speed
    }
    #expect(try speed(32) == 16)
    #expect(try speed(0.1) == 0.25)
    #expect(try speed(.infinity) == 16)
    // The speed it has already (one that is not a number is 1), or no clip of the sequence: nothing to do.
    #expect(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001"], speed: 1, takeBounds: [:]) == nil)
    #expect(SequenceCommands.setSpeed(document, clipIDs: ["c-00000001"], speed: .nan, takeBounds: [:]) == nil)
    #expect(SequenceCommands.setSpeed(document, clipIDs: ["c-0000000f"], speed: 2, takeBounds: [:]) == nil)
    // Several clips in one step, in the order of the sequence; the output gets shorter.
    let both = try #require(SequenceCommands.setSpeed(document, clipIDs: ["c-00000002", "c-00000001"], speed: 2, takeBounds: [:]))
    #expect(both.target == "c-00000001,c-00000002")
    #expect(TwoClips.duration(try TwoClips.applying(both, to: document)) == TwoClips.output(4))
}

@Test func everySpeedWrittenIsInItsRange() throws {
    // A document edited by hand with a speed past 16: a clip a command writes again is written at 16, which is how the
    // time map has always played it.
    let document = TwoClips.document([TwoClips.clip(1, from: 1, to: 5, speed: 100)])
    let split = try #require(SequenceCommands.split(document, atOutput: TwoClips.output(0.125), makeID: TwoClips.newIDs))
    #expect(try TwoClips.applying(split, to: document).sequence.map(\.speed) == [16, 16])
    let limits = TwoClips.limits("c-00000001", .end, in: document)
    let trim = try #require(
        SequenceCommands.trim(document, clipID: "c-00000001", edge: .end, toSource: TwoClips.at(4), limits: limits, takeBounds: [:]))
    #expect(try TwoClips.applying(trim, to: document).sequence.map(\.speed) == [16])
    let range = try SequenceCommands.deleteRange(document, output: TwoClips.range(0, 0.125), takeBounds: [:], makeID: TwoClips.newIDs).get()
    #expect(try TwoClips.applying(range, to: document).sequence.map(\.speed) == [16])
}
