// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

private enum PrivacyFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let base2 = HostTime(nanoseconds: 9_000_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func output(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    /// Clips of take-001 [0, 10) and [12, 20) s at 1x (output 0…18 s), then one of take-002 (output 18…23 s).
    static func document(_ blocks: [PrivacyBlock] = []) -> EditDocument {
        var d = EditDocument.legacy(take: take, events: [])
        d.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: base, end: at(10), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: at(12), end: at(20), speed: 1),
            Clip(id: "c-00000003", take: "take-002", start: base2, end: base2.adding(seconds: 5), speed: 1),
        ]
        d.privacy.blocks = blocks
        return d
    }

    static func block(
        _ id: String, from: Double, to: Double, keys: [RectKey] = [], origin: PrivacyOrigin = .manual
    ) -> PrivacyBlock {
        PrivacyBlock(
            id: id, take: "take-001", start: at(from), end: at(to), effect: .blur, rect: PrivacyCommands.defaultRect, keys: keys,
            origin: origin)
    }

    static func counter() -> (String) -> String {
        var n = 0
        return { prefix in
            n += 1
            return prefix + String(format: "%08x", n + 15)
        }
    }

    static func applied(_ doc: EditDocument, _ step: EditStep?) throws -> EditDocument {
        try doc.applying(try #require(step).changes)
    }
}

@Suite struct PrivacyCommandsTests {
    fileprivate typealias F = PrivacyFixture

    @Test func newBlockLastsThreeSecondsFromThePlayheadCentred() throws {
        let doc = F.document()
        let step = try #require(PrivacyCommands.add(doc, atOutput: F.output(2), makeID: F.counter()))
        #expect(step.label == .privacyAdd)
        let after = try doc.applying(step.changes)
        let block = try #require(after.privacy.blocks.first)
        #expect(block.id == "p-00000010")
        #expect(PrivacyCommands.outputRange(of: block, in: after) == F.output(2)..<F.output(5))
        #expect(block.rect == NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2))
        #expect(block.effect == .blur && block.strength == 0.6 && block.color == RGBA(0, 0, 0, 1) && block.origin == .manual)
        #expect(step.target == block.id)
    }

    @Test func newBlockStopsWhereTheTakeStops() throws {
        let doc = F.document()
        // The take-001 clips end at 18 s of output.
        let a = try F.applied(doc, PrivacyCommands.add(doc, atOutput: F.output(17), makeID: F.counter()))
        let r = try #require(PrivacyCommands.outputRange(of: a.privacy.blocks[0], in: a))
        #expect(r == F.output(17)..<F.output(18))
        #expect(PrivacyCommands.add(doc, atOutput: F.output(17.8), makeID: F.counter()) == nil)
        #expect(PrivacyCommands.add(doc, atOutput: F.output(99), makeID: F.counter()) == nil)
    }

    @Test func blocksMayOverlap() throws {
        var doc = F.document()
        let make = F.counter()
        doc = try F.applied(doc, PrivacyCommands.add(doc, atOutput: F.output(2), makeID: make))
        doc = try F.applied(doc, PrivacyCommands.add(doc, atOutput: F.output(2), makeID: make))
        #expect(doc.privacy.blocks.count == 2)
        #expect(doc.privacy.blocks[0].id == "p-00000010" && doc.privacy.blocks[1].id == "p-00000011")
        #expect(PrivacyCommands.blocks(atOutput: F.output(3), in: doc).count == 2)
    }

    @Test func movingCarriesTheKeysAndIgnoresOtherBlocks() throws {
        let keys = [
            RectKey(t: F.at(1), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            RectKey(t: F.at(2), rect: NormalizedRect(x: 0.2, y: 0.1, width: 0.2, height: 0.2)),
        ]
        let doc = F.document([F.block("p-a", from: 1, to: 3, keys: keys), F.block("p-b", from: 4, to: 7)])
        let step = try #require(PrivacyCommands.move(doc, id: "p-a", toOutputStart: F.output(3.5)))
        #expect(step.label == .privacyMove)
        let after = try doc.applying(step.changes)
        let moved = after.privacy.blocks[0]
        #expect(moved.start == F.at(3.5) && moved.end == F.at(5.5))
        #expect(moved.keys.map(\.t) == [F.at(3.5), F.at(4.5)])
        #expect(moved.keys.map(\.rect) == keys.map(\.rect))
        #expect(step.changes.count == 1)
        #expect(PrivacyCommands.move(doc, id: "p-a", toOutputStart: F.output(1)) == nil)
    }

    @Test func trimKeepsTheKeysAndAMinimum() throws {
        let keys = [RectKey(t: F.at(1), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        let doc = F.document([F.block("p-a", from: 1, to: 4, keys: keys)])
        let step = try #require(PrivacyCommands.trim(doc, id: "p-a", edge: .end, toOutput: F.output(1.1)))
        #expect(step.label == .privacyTrim)
        let after = try doc.applying(step.changes).privacy.blocks[0]
        #expect(PrivacyCommands.outputRange(of: after, in: try doc.applying(step.changes)) == F.output(1)..<F.output(1.3))
        #expect(after.keys == keys)
        let start = try #require(PrivacyCommands.trim(doc, id: "p-a", edge: .start, toOutput: F.output(2)))
        #expect(try doc.applying(start.changes).privacy.blocks[0].start == F.at(2))
    }

    @Test func changeClampsStrengthAndIsOneReplace() throws {
        let doc = F.document([F.block("p-a", from: 1, to: 4)])
        let step = try #require(PrivacyCommands.change(doc, id: "p-a", effect: .fill, strength: 1.4))
        #expect(step.label == .privacyChange && step.changes.count == 1)
        guard case .replace(_, let id, let before, let after) = step.changes[0] else { Issue.record("not a replace"); return }
        #expect(id == "p-a" && before != after)
        let block = try doc.applying(step.changes).privacy.blocks[0]
        #expect(block.strength == 1 && block.effect == .fill)
        #expect(PrivacyCommands.change(doc, id: "p-a", strength: .nan) == nil)
        #expect(PrivacyCommands.change(doc, id: "p-a") == nil)
        #expect(PrivacyCommands.change(doc, id: "p-zz", strength: 0.2) == nil)
    }

    @Test func editingAnAutomaticRectMovesEveryKey() throws {
        let keys = [
            RectKey(t: F.at(1), rect: NormalizedRect(x: 0.1, y: 0.3, width: 0.2, height: 0.1)),
            RectKey(t: F.at(3), rect: NormalizedRect(x: 0.5, y: 0.3, width: 0.2, height: 0.1)),
        ]
        let doc = F.document([F.block("p-a", from: 0, to: 5, keys: keys, origin: .email)])
        // At 2 s the rect is x 0.3; drag it to 0.4.
        let step = try #require(
            PrivacyCommands.setRect(doc, id: "p-a", NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.1), atSource: F.at(2)))
        let block = try doc.applying(step.changes).privacy.blocks[0]
        #expect(abs(block.keys[0].rect.x - 0.2) < 1e-12 && abs(block.keys[1].rect.x - 0.6) < 1e-12)
        #expect(block.origin == .email)
        // Pushed past the edge: kept inside.
        let edge = try #require(
            PrivacyCommands.setRect(doc, id: "p-a", NormalizedRect(x: 0.9, y: 0.3, width: 0.2, height: 0.1), atSource: F.at(2)))
        #expect(try doc.applying(edge.changes).privacy.blocks[0].keys.allSatisfy { $0.rect.x + $0.rect.width <= 1 + 1e-12 })
    }

    @Test func autoAddsOneStepWithNewIDs() throws {
        let doc = F.document([F.block("p-00000010", from: 0, to: 1)])
        let found = [
            F.block("p-x3", from: 6, to: 7, origin: .card), F.block("p-x1", from: 2, to: 3, origin: .email),
            F.block("p-x2", from: 4, to: 5, origin: .phone),
        ]
        let step = try #require(PrivacyCommands.addAuto(doc, blocks: found, makeID: F.counter()))
        #expect(step.label == .privacyAuto && step.target == "/privacy/blocks" && step.changes.count == 3)
        let after = try doc.applying(step.changes).privacy.blocks
        #expect(after.count == 4)
        #expect(after.map(\.start) == [F.at(0), F.at(2), F.at(4), F.at(6)])
        #expect(Set(after.map(\.id)).count == 4 && !after.dropFirst().contains { $0.id.hasPrefix("p-x") })
        #expect(PrivacyCommands.addAuto(doc, blocks: [], makeID: F.counter()) == nil)
    }

    @Test func aBlockOverACutIsKept() throws {
        let doc = F.document([F.block("p-a", from: 2, to: 4)])
        let step = try SequenceCommands.deleteRange(doc, output: F.output(1)..<F.output(6), makeID: F.counter()).get()
        let cut = try doc.applying(step.changes)
        #expect(cut.privacy.blocks.count == 1)
        #expect(PrivacyCommands.outputRange(of: cut.privacy.blocks[0], in: cut) == nil)
        #expect(PrivacyCommands.move(cut, id: "p-a", toOutputStart: 0) == nil)
    }

    @Test func blocksAtTheOutputAreTheShownOnes() {
        var other = F.block("p-c", from: 0, to: 5)
        other.take = "take-002"
        other.start = F.base2
        other.end = F.base2.adding(seconds: 5)
        let doc = F.document([F.block("p-a", from: 1, to: 4), F.block("p-b", from: 3, to: 6), other])
        #expect(PrivacyCommands.blocks(atOutput: F.output(3.5), in: doc).map(\.id) == ["p-a", "p-b"])
        #expect(PrivacyCommands.blocks(atOutput: F.output(5), in: doc).map(\.id) == ["p-b"])
        #expect(PrivacyCommands.blocks(atOutput: F.output(19), in: doc).map(\.id) == ["p-c"])
        #expect(PrivacyCommands.blocks(atOutput: F.output(8), in: doc).isEmpty)
    }

    @Test func deleteTakesOnlyTheIdsGiven() throws {
        let doc = F.document([F.block("p-a", from: 1, to: 2), F.block("p-b", from: 3, to: 4), F.block("p-c", from: 5, to: 6)])
        let step = try #require(PrivacyCommands.delete(doc, ids: ["p-c", "p-a", "p-zz"]))
        #expect(step.label == .privacyDelete && step.target == "p-a,p-c")
        #expect(try doc.applying(step.changes).privacy.blocks.map(\.id) == ["p-b"])
        #expect(PrivacyCommands.delete(doc, ids: ["p-zz"]) == nil)
    }
}
