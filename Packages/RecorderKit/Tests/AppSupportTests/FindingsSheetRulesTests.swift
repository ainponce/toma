// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct FindingsSheetRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)

    private static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: base.adding(seconds: 20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    /// Clips [0, 10) and [12, 20) s of the take at 1×: output 0…18 s, the cut from 10 to 12 s; with `blocks`.
    private static func document(_ blocks: [PrivacyBlock] = []) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: base, end: base.adding(seconds: 10), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: base.adding(seconds: 12), end: base.adding(seconds: 20), speed: 1),
        ]
        document.privacy.blocks = blocks
        return document
    }

    /// A block the scan's finding of `origin` makes, from `from` s for 1 s.
    private static func found(_ origin: PrivacyOrigin, from: Double, y: Double = 0.1) -> PrivacyBlock {
        let rect = NormalizedRect(x: 0.1, y: y, width: 0.2, height: 0.05)
        return PrivacyBlock(
            id: "p-00000000", take: "take-001", start: base.adding(seconds: from), end: base.adding(seconds: from + 1),
            effect: .blur, strength: 0.6, rect: rect, keys: [RectKey(t: base.adding(seconds: from), rect: rect)], origin: origin)
    }

    @Test func groupsFollowTheKindsAndSkipEmptyOnes() {
        // In the order of their start, as the scan gives them: a face, two emails, a key, an email, a card.
        let blocks = [
            Self.found(.face, from: 0), Self.found(.email, from: 1), Self.found(.secret, from: 2), Self.found(.email, from: 3),
            Self.found(.card, from: 4), Self.found(.email, from: 5),
        ]
        let rules = FindingsSheetRules(blocks: blocks)
        // Emails, phones, cards, keys and tokens, faces: no phone, so no group of phones.
        #expect(rules.groups == [
            .init(origin: .email, indices: [1, 3, 5]), .init(origin: .card, indices: [4]), .init(origin: .secret, indices: [2]),
            .init(origin: .face, indices: [0]),
        ])
        #expect(FindingsSheetRules(blocks: []).groups.isEmpty)
    }

    @Test func aGroupIsInTheOrderOfStart() {
        // Given out of order: the later one is listed after.
        let rules = FindingsSheetRules(blocks: [Self.found(.phone, from: 8), Self.found(.phone, from: 2)])
        #expect(rules.groups == [.init(origin: .phone, indices: [1, 0])])
    }

    @Test func everythingStartsChecked() {
        let blocks = (0..<4).map { Self.found(.email, from: Double($0)) } + [Self.found(.face, from: 9)]
        let rules = FindingsSheetRules(blocks: blocks)
        #expect(rules.checked == Set(0..<5))
        #expect(rules.addCount == 5)
        #expect(rules.chosen == blocks)
        #expect(rules.alreadyHidden.isEmpty)
    }

    @Test func addCountIsTheChecked() {
        // Unchecking 2 of 7 leaves 5.
        let blocks = (0..<7).map { Self.found(.card, from: Double($0)) }
        var rules = FindingsSheetRules(blocks: blocks)
        rules.toggle(1)
        rules.toggle(4)
        #expect(rules.addCount == 5)
        #expect(rules.chosen == [blocks[0], blocks[2], blocks[3], blocks[5], blocks[6]])
        // Checked again, it is back; an index of no finding changes nothing.
        rules.toggle(4)
        rules.toggle(99)
        #expect(rules.addCount == 6)
        #expect(!rules.isChecked(1) && rules.isChecked(4))
    }

    @Test func whatTheDocumentAlreadyHidesStartsUnchecked() {
        // The scan's blocks were added once ("Desenfocar N"), with ids of their own, and one changed to a fill since: what
        // the same scan finds again is hidden already and starts unchecked, so blurring again does not double it.
        let blocks = [Self.found(.email, from: 1), Self.found(.email, from: 3), Self.found(.secret, from: 5)]
        var added = blocks[0]
        added.id = "p-1a2b3c4d"
        var changed = blocks[2]
        changed.id = "p-5e6f7a8b"
        changed.effect = .fill
        let rules = FindingsSheetRules(blocks: blocks, document: Self.document([added, changed]))
        #expect(rules.alreadyHidden == [0, 2])
        #expect(rules.checked == [1])
        #expect(rules.addCount == 1)
        // Still listed, in their group.
        #expect(rules.groups == [.init(origin: .email, indices: [0, 1]), .init(origin: .secret, indices: [2])])
        // A block of the user's over the same place hides nothing of the scan's.
        var mine = blocks[1]
        mine.origin = .manual
        #expect(FindingsSheetRules(blocks: blocks, document: Self.document([mine])).alreadyHidden.isEmpty)
    }

    @Test func aFindingAllInACutIsNotListed() {
        // The scan looks at the whole take, so a later trim needs no new search; what the output does not show now is in
        // no group and never added. One across the cut is listed, at its output times, the cut closed.
        let blocks = [Self.found(.email, from: 10.2), Self.found(.email, from: 9.5), Self.found(.card, from: 14)]
        let rules = FindingsSheetRules(blocks: blocks, document: Self.document())
        #expect(rules.groups == [.init(origin: .email, indices: [1]), .init(origin: .card, indices: [2])])
        #expect(rules.checked == [1, 2])
        #expect(rules.output(of: 0) == nil)
        #expect(rules.output(of: 1) == 9_500_000_000..<10_000_000_000)
        #expect(rules.output(of: 2) == 12_000_000_000..<13_000_000_000)
        // Without a document, every one is listed and none has an output time.
        #expect(FindingsSheetRules(blocks: blocks).output(of: 1) == nil)
    }

    @Test func aBlockOfTheUsersIsNoFinding() {
        // Never made by the scan, but if it were: in no group and never added.
        let rules = FindingsSheetRules(blocks: [Self.found(.manual, from: 0), Self.found(.face, from: 1)])
        #expect(rules.groups == [.init(origin: .face, indices: [1])])
        #expect(rules.checked == [1])
        var toggled = rules
        toggled.toggle(0)
        #expect(toggled.checked == [1])
    }
}
