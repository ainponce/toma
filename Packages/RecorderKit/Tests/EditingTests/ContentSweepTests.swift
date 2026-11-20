// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The commands of the sequence with clips with content (phase 3 base plan, B5): a clip with content is a point of its
/// take that lasts, which no command cuts, trims or speeds up, and which every command that edits the take's stretches
/// leaves where it is; and no command leaves a cut of the sound out of its limits.
@Suite struct ContentSweepTests {
    private typealias F = TwoClips

    private static let card = TitleCard(title: "Toma", style: .centered, background: .stage)

    /// A clip with content `content` at the source second `point` of the take.
    private static func content(_ id: String, at point: Double, _ content: ClipContent) -> Clip {
        Clip(id: id, take: F.takeID, start: F.at(point), end: F.at(point), speed: 1, content: content)
    }

    /// `c-00000001` over [1 s, 5 s), a title card of 3 s at 5 s, `c-00000002` over [10 s, 14 s): the card is the output
    /// [4 s, 7 s), the second clip [7 s, 11 s).
    private static let withCard = F.document([
        F.clip(1, from: 1, to: 5), content("c-0000000a", at: 5, .card(card, duration: 3_000_000_000)), F.clip(2, from: 10, to: 14),
    ])

    /// Ids from 1 for each prefix: `c-00000001`, `c-00000002`…
    private final class IDs {
        private var counts: [String: Int] = [:]

        func make(_ prefix: String) -> String {
            let count = counts[prefix, default: 100] + 1
            counts[prefix] = count
            return prefix + String(format: "%08x", count)
        }
    }

    @Test func splitNeverCutsAContentClip() throws {
        let doc = Self.withCard
        let ids = IDs()
        // In the middle of the card, and on its edges, as on any clip's edge.
        for seconds in [4.0, 4.5, 5.5, 6.99, 7.0] {
            #expect(SequenceCommands.split(doc, atOutput: F.output(seconds), makeID: ids.make) == nil, "\(seconds)")
        }
        // A range with one edge in the card splits only at the other one.
        let step = try #require(SequenceCommands.split(doc, range: F.range(5.5, 8), makeID: ids.make))
        let edited = try F.applying(step, to: doc)
        #expect(edited.sequence.map(\.start) == [F.at(1), F.at(5), F.at(10), F.at(11)])
        #expect(edited.sequence.map(\.end) == [F.at(5), F.at(5), F.at(11), F.at(14)])
        #expect(edited.sequence[1] == doc.sequence[1])
        // The clips of the take around it split as they always did.
        let before = try F.applying(try #require(SequenceCommands.split(doc, atOutput: F.output(2), makeID: ids.make)), to: doc)
        #expect(before.sequence.map(\.start) == [F.at(1), F.at(3), F.at(5), F.at(10)])
        #expect(DocumentRules.problems(in: before) == [])
    }

    @Test func trimSpeedAndDeleteKeepContentWhole() throws {
        let doc = Self.withCard
        let card = doc.sequence[1]
        // Its edges never move it in its take.
        for edge in [ClipEdge.start, .end] {
            #expect(F.limits(card.id, edge, in: doc) == card.start...card.start)
            for to in [F.at(4), F.at(5), F.at(6)] {
                #expect(SequenceCommands.trim(doc, clipID: card.id, edge: edge, toSource: to, limits: F.at(0)...F.at(30), takeBounds: [:]) == nil)
            }
            #expect(SequenceCommands.trimToPlayhead(doc, edge: edge, atOutput: F.output(5), take: F.take, events: []) == nil)
        }
        // A point holds the edges of the take's clips on each side of it in the sequence.
        let freezeAfter = F.document([F.clip(1, from: 1, to: 5), Self.content("c-0000000b", at: 5, .freeze(duration: 2_000_000_000))])
        #expect(F.limits("c-00000001", .end, in: freezeAfter).upperBound == F.at(5))
        #expect(F.limits("c-00000001", .end, in: F.document([F.clip(1, from: 1, to: 5)])).upperBound == F.at(30))
        let freezeBefore = F.document([Self.content("c-0000000b", at: 8, .freeze(duration: 2_000_000_000)), F.clip(2, from: 10, to: 14)])
        #expect(F.limits("c-00000002", .start, in: freezeBefore).lowerBound == F.at(8))
        let atItsStart = F.document([Self.content("c-0000000b", at: 10, .freeze(duration: 2_000_000_000)), F.clip(2, from: 10, to: 14)])
        #expect(F.limits("c-00000002", .start, in: atItsStart).lowerBound == F.at(10))
        // No speed changes it; with it alone there is nothing to change.
        let speed = try #require(SequenceCommands.setSpeed(doc, clipIDs: [card.id, "c-00000001"], speed: 2, takeBounds: [:]))
        let faster = try F.applying(speed, to: doc)
        #expect(faster.sequence.map(\.speed) == [2, 1, 1])
        #expect(faster.sequence[1] == card)
        #expect(speed.target == "c-00000001")
        #expect(SequenceCommands.setSpeed(doc, clipIDs: [card.id], speed: 2, takeBounds: [:]) == nil)
        // A deletion takes it whole.
        let deleted = try F.applying(try SequenceCommands.delete(doc, clipIDs: [card.id], takeBounds: [:]).get(), to: doc)
        #expect(deleted.sequence.map(\.id) == ["c-00000001", "c-00000002"])
        // A range deletion only if it covers it whole.
        let ids = IDs()
        let partial = try SequenceCommands.deleteRange(doc, output: F.range(4.5, 6), takeBounds: [:], makeID: ids.make).get()
        #expect(partial.changes.isEmpty)
        let across = try SequenceCommands.deleteRange(doc, output: F.range(6, 8), takeBounds: [:], makeID: ids.make).get()
        let acrossEdited = try F.applying(across, to: doc)
        #expect(acrossEdited.sequence.map(\.id) == ["c-00000001", card.id, "c-00000002"])
        #expect(acrossEdited.sequence[1] == card)
        #expect(acrossEdited.sequence[2].start == F.at(11))
        let whole = try F.applying(try SequenceCommands.deleteRange(doc, output: F.range(4, 7), takeBounds: [:], makeID: ids.make).get(), to: doc)
        #expect(whole.sequence.map(\.id) == ["c-00000001", "c-00000002"])
        let around = try F.applying(try SequenceCommands.deleteRange(doc, output: F.range(3, 8), takeBounds: [:], makeID: ids.make).get(), to: doc)
        #expect(around.sequence.map(\.start) == [F.at(1), F.at(11)])
        #expect(around.sequence.map(\.end) == [F.at(4), F.at(14)])
        // Content lasts: a card alone is a clip of at least a frame, so its neighbours can go.
        #expect((try? SequenceCommands.delete(doc, clipIDs: ["c-00000001", "c-00000002"], takeBounds: [:]).get()) != nil)
        #expect(throws: SequenceError.lastClip) { try SequenceCommands.delete(doc, clipIDs: Set(doc.sequence.map(\.id)), takeBounds: [:]).get() }
    }

    /// The transcript's commands take source out of the take's clips and give it back without moving a point or going
    /// across it: a frozen frame at the edge of two clips stays there, and what is given back on each side of it goes to
    /// the clip on that side.
    @Test func sourceCommandsLeaveEachPointWhereItIs() throws {
        let freeze = Self.content("c-0000000b", at: 5, .freeze(duration: 2_000_000_000))
        let doc = F.document([F.clip(1, from: 1, to: 5), freeze, F.clip(2, from: 5, to: 9)])
        let ids = IDs()
        let cut = try F.applying(
            try SequenceCommands.deleteSource(doc, take: F.takeID, ranges: [F.at(4)..<F.at(6)], label: .transcriptCut, takeBounds: [:], makeID: ids.make)
                .get(), to: doc)
        #expect(cut.sequence.map(\.start) == [F.at(1), F.at(5), F.at(6)])
        #expect(cut.sequence.map(\.end) == [F.at(4), F.at(5), F.at(6 + 3)])
        #expect(cut.sequence[1] == freeze)
        let restored = try F.applying(
            try #require(SequenceCommands.restore(cut, take: F.takeID, range: F.at(4)..<F.at(6), bounds: F.at(0)...F.at(30), makeID: ids.make)),
            to: cut)
        #expect(restored == doc)
        // Given back with the point inside what was cut, and nothing of the take on either side: a new clip on each side.
        let alone = F.document([F.clip(1, from: 1, to: 2), Self.content("c-0000000b", at: 5, .freeze(duration: 2_000_000_000)),
                                F.clip(2, from: 10, to: 14)])
        let back = try F.applying(
            try #require(SequenceCommands.restore(alone, take: F.takeID, range: F.at(3)..<F.at(8), bounds: F.at(0)...F.at(30), makeID: ids.make)),
            to: alone)
        #expect(back.sequence.map(\.start) == [F.at(1), F.at(3), F.at(5), F.at(5), F.at(10)])
        #expect(back.sequence.map(\.end) == [F.at(2), F.at(5), F.at(5), F.at(8), F.at(10 + 4)])
        #expect(back.sequence[2].content != nil)
        #expect(SequenceRules.firstOutOfOrder(in: back.sequence) == nil)
        // Given back up to a point that ends the take's clips: the clip before it is lengthened up to it, not past.
        let end = F.document([F.clip(1, from: 1, to: 4), Self.content("c-0000000b", at: 5, .freeze(duration: 2_000_000_000))])
        let upTo = try F.applying(
            try #require(SequenceCommands.restore(end, take: F.takeID, range: F.at(4)..<F.at(7), bounds: F.at(0)...F.at(30), makeID: ids.make)),
            to: end)
        #expect(upTo.sequence.map(\.start) == [F.at(1), F.at(5), F.at(5)])
        #expect(upTo.sequence.map(\.end) == [F.at(5), F.at(5), F.at(7)])
        #expect(SequenceRules.firstOutOfOrder(in: upTo.sequence) == nil)
        #expect(DocumentRules.problems(in: upTo) == [])
    }

    /// Typing sped up leaves a point alone, and the clips around it are sped as always.
    @Test func typingSpeedLeavesAPointAlone() throws {
        let freeze = Self.content("c-0000000b", at: 5, .freeze(duration: 2_000_000_000))
        let doc = F.document([F.clip(1, from: 0, to: 5), freeze, F.clip(2, from: 5, to: 30)])
        let keys = (0...24).map { InputEvent(t: F.at(2 + Double($0) * 0.25), kind: .keyActivity) }
        let step = try #require(TypingSpeed.apply(doc, take: F.take, events: keys, speed: 3, makeID: IDs().make))
        let edited = try F.applying(step, to: doc)
        #expect(edited.sequence.filter { $0.content != nil } == [freeze])
        #expect(edited.sequence.contains { $0.speed == 3 })
        #expect(SequenceRules.firstOutOfOrder(in: edited.sequence) == nil)
        #expect(DocumentRules.problems(in: edited) == [])
    }

    /// A cut of the sound a command leaves out of its limits is held to them in the same step; a clip a command makes
    /// starts its sound with its picture.
    @Test func everyCommandKeepsTheCutsOfTheSoundInTheirLimits() throws {
        // c-00000002's sound starts 1.5 s late: half of the shorter clip, 4 s, is 2 s.
        var doc = F.document()
        doc.sequence[1].audioShift = 1_500_000_000
        #expect(DocumentRules.problems(in: doc) == [])
        let ids = IDs()
        // Trimmed to 2 s, its cut can move 1 s at most.
        let trimmed = try F.applying(
            try #require(SequenceCommands.trim(doc, clipID: "c-00000002", edge: .end, toSource: F.at(12), limits: F.at(0)...F.at(30), takeBounds: [:])),
            to: doc)
        #expect(trimmed.sequence[1].audioShift == 1_000_000_000)
        #expect(DocumentRules.problems(in: trimmed) == [])
        // The first clip at 4×: 1 s of output.
        let fast = try F.applying(try #require(SequenceCommands.setSpeed(doc, clipIDs: ["c-00000001"], speed: 4, takeBounds: [:])), to: doc)
        #expect(fast.sequence[1].audioShift == 500_000_000)
        // Split: the first piece keeps the cut at its start, the second starts its sound with its picture.
        let split = try F.applying(try #require(SequenceCommands.split(doc, atOutput: F.output(5), makeID: ids.make)), to: doc)
        #expect(split.sequence.map(\.audioShift) == [0, 500_000_000, 0])
        #expect(DocumentRules.problems(in: split) == [])
        // Deleted the clip before it, it is the first, which never moves its sound.
        let first = try F.applying(try SequenceCommands.delete(doc, clipIDs: ["c-00000001"], takeBounds: [:]).get(), to: doc)
        #expect(first.sequence.map(\.audioShift) == [0])
        // A range deletion inside it: the piece after the range starts its sound with its picture.
        let inside = try F.applying(try SequenceCommands.deleteRange(doc, output: F.range(5, 6), takeBounds: [:], makeID: ids.make).get(), to: doc)
        #expect(inside.sequence.map(\.audioShift) == [0, 500_000_000, 0])
        #expect(DocumentRules.problems(in: inside) == [])
        // Typing sped up inside it: the first piece keeps the cut at its start, held to its 0.75 s.
        let keys = (0...12).map { InputEvent(t: F.at(10.5 + Double($0) * 0.25), kind: .keyActivity) }
        let typed = try F.applying(try #require(TypingSpeed.apply(doc, take: F.take, events: keys, speed: 3, makeID: ids.make)), to: doc)
        #expect(typed.sequence.map(\.speed) == [1, 1, 3, 1])
        #expect(typed.sequence.map(\.audioShift) == [0, 375_000_000, 0, 0])
        #expect(DocumentRules.problems(in: typed) == [])
        // Undone, every cut comes back as it was.
        for step in [
            try #require(SequenceCommands.trim(doc, clipID: "c-00000002", edge: .end, toSource: F.at(12), limits: F.at(0)...F.at(30), takeBounds: [:])),
            try SequenceCommands.delete(doc, clipIDs: ["c-00000001"], takeBounds: [:]).get(),
        ] {
            let edited = try doc.applying(step.changes)
            #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == doc)
        }
        // Without a cut moved, a command makes the changes it always made.
        let plain = F.document()
        let plainStep = try #require(SequenceCommands.trim(plain, clipID: "c-00000002", edge: .end, toSource: F.at(12), limits: F.at(0)...F.at(30), takeBounds: [:]))
        #expect(plainStep.changes.count == 1)
    }
}
