// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct PrivacyTrackRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    private static func output(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    private static let take = TakeRecord(
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

    /// Clips [0, 10) and [12, 20) s of the take at 1×: output 0…18 s, the cut at 10 s.
    private static func document(_ blocks: [PrivacyBlock]) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: base, end: at(10), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: at(12), end: at(20), speed: 1),
        ]
        document.privacy.blocks = blocks
        return document
    }

    private static func block(_ id: String, from: Double, to: Double) -> PrivacyBlock {
        PrivacyBlock(id: id, take: "take-001", start: at(from), end: at(to), effect: .blur, rect: PrivacyCommands.defaultRect)
    }

    @Test func longestFirstSoTheShortestIsHit() {
        // A 10 s block with a 1 s one inside it, listed first in the document.
        let document = Self.document([Self.block("p-00000001", from: 4, to: 5), Self.block("p-00000002", from: 0, to: 10)])
        let items = PrivacyTrackRules.items(document)
        #expect(items.map(\.id) == ["p-00000002", "p-00000001"])
        #expect(items.allSatisfy { $0.track == .privacy })
        #expect(items[1].output == Self.output(4)..<Self.output(5))
        // The ruler (0–24), Video (24–80), Zoom (80–108), Privacy (108–136).
        let layout = TimelineLayout(take: Self.take, document: document)
        #expect(layout.tracks.map(\.track) == [.ruler, .video, .zoom, .privacy])
        let x = TimelineLayout.headerWidth + 4.5 * 100
        let hit = TimelineHitTest.hit(at: CGPoint(x: x, y: 120), items: items, layout: layout, scale: 100, offset: 0)
        #expect(hit == .item(.privacy, id: "p-00000001"))
        // Outside the short one, the long one.
        let outside = TimelineHitTest.hit(
            at: CGPoint(x: TimelineLayout.headerWidth + 2 * 100, y: 120), items: items, layout: layout, scale: 100, offset: 0)
        #expect(outside == .item(.privacy, id: "p-00000002"))
    }

    @Test func blocksOfTheSameLengthKeepTheDocumentsOrder() {
        let document = Self.document([Self.block("p-00000001", from: 1, to: 3), Self.block("p-00000002", from: 1, to: 3)])
        #expect(PrivacyTrackRules.items(document).map(\.id) == ["p-00000001", "p-00000002"])
    }

    @Test func blocksInACutAreNotItems() {
        // [10.5, 11.5) of the take is in the cut; [9, 13) shows its two kept parts, closed: 9…11 s of output.
        let document = Self.document([Self.block("p-00000001", from: 10.5, to: 11.5), Self.block("p-00000002", from: 9, to: 13)])
        let items = PrivacyTrackRules.items(document)
        #expect(items == [TimelineItem(id: "p-00000002", track: .privacy, output: Self.output(9)..<Self.output(11))])
        #expect(PrivacyTrackRules.items(Self.document([])).isEmpty)
    }
}
