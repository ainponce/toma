// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct MusicTrackRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func s(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// A 200 s output (one clip of 200 s), with `items` of music.
    private static func document(_ items: [MusicItem]) -> (EditDocument, TimeMap) {
        var document = EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
            events: [])
        document.sequence = [Clip(id: "c-1", take: "take-001", start: base, end: base.adding(seconds: 200), speed: 1)]
        document.music.items = items
        return (document, TimeMap(sequence: document.sequence))
    }

    private static func item(
        _ id: String = "mu-1", from: Double = 0, to: Double = 200, offset: Double = 0, loop: Bool = true, fadeIn: Double = 1,
        fadeOut: Double = 2, gain: Double = -14
    ) -> MusicItem {
        MusicItem(
            id: id, source: "library:music-1/calm", start: s(from), end: s(to), offset: s(offset), gain: gain, fadeIn: s(fadeIn),
            fadeOut: s(fadeOut), loop: loop)
    }

    private static let lengths = ["library:music-1/calm": s(120)]

    @Test func blocksShowWrapsAndTheEnd() {
        var (document, map) = Self.document([Self.item(offset: 30)])
        var blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks.count == 1)
        #expect(blocks[0].wraps == [Self.s(90)])
        #expect(blocks[0].runsOutAt == nil)
        #expect(blocks[0].output == 0..<Self.s(200))
        #expect(blocks[0].gain == -14)

        // From the start: wraps at 120 s; with a loop off the file ends there.
        (document, map) = Self.document([Self.item()])
        blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].wraps == [Self.s(120)])
        (document, map) = Self.document([Self.item(offset: 30, loop: false)])
        blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].wraps.isEmpty)
        #expect(blocks[0].runsOutAt == Self.s(90))

        // A block that starts later: wraps from its own start; the file is longer than the block: no end.
        (document, map) = Self.document([Self.item(from: 50, to: 100, loop: false)])
        blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].runsOutAt == nil)
        (document, map) = Self.document([Self.item(from: 50, to: 190, offset: 10, loop: true)])
        blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].wraps == [Self.s(160)])
    }

    @Test func aFileOffsetPastItsEndHasNothingToPlayWithoutALoop() {
        let (document, map) = Self.document([Self.item(from: 10, to: 60, offset: 130, loop: false)])
        let blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].runsOutAt == Self.s(10))
    }

    @Test func theEndThatSoundsIsTheOutputs() {
        var (document, map) = Self.document([Self.item(from: 150, to: 500), Self.item("mu-2", from: 300, to: 400)])
        var blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks.map(\.id) == ["mu-1"])
        #expect(blocks[0].output == Self.s(150)..<Self.s(200))
        // Fades are at most half of what sounds: 25 s of 50.
        (document, map) = Self.document([Self.item(from: 190, to: 200, fadeIn: 30, fadeOut: 3)])
        blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: Self.lengths)
        #expect(blocks[0].fadeIn == Self.s(5) && blocks[0].fadeOut == Self.s(3))
    }

    @Test func blocksComeByTheirStartAndUnknownLengthsHaveNoMarks() {
        let (document, map) = Self.document([Self.item("mu-2", from: 100, to: 150), Self.item("mu-1", from: 0, to: 50)])
        let blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: [:])
        #expect(blocks.map(\.id) == ["mu-1", "mu-2"])
        #expect(blocks.allSatisfy { $0.wraps.isEmpty && $0.runsOutAt == nil })
    }

    @Test func aTinyFileDoesNotMakeAMillionMarks() {
        let (document, map) = Self.document([Self.item()])
        let blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: ["library:music-1/calm": 1_000])
        #expect(blocks[0].wraps.count == MusicTrackRules.maxWraps)
    }

    @Test func musicHitsByPlace() {
        let (document, map) = Self.document([Self.item(gain: -14), Self.item("mu-2", from: 0, to: 0, gain: 0)])
        let block = MusicTrackRules.blocks(document, timeMap: map, lengths: [:])[0]
        let spans = [(block, x: 100.0...400.0)]
        let h = 36.0
        let line = AudioRowGeometry.y(ofGain: -14, height: h)
        func hit(_ x: Double, _ y: Double, option: Bool = false) -> MusicTrackHit {
            MusicTrackRules.hit(x: x, y: y, option: option, height: h, blocks: spans)
        }
        #expect(hit(103, 10) == .edge(id: "mu-1", edge: .start))
        #expect(hit(397, 10) == .edge(id: "mu-1", edge: .end))
        #expect(hit(105, 10) == .body(id: "mu-1"))
        #expect(hit(250, 2) == .body(id: "mu-1"))
        #expect(hit(250, 10, option: true) == .slip(id: "mu-1"))
        #expect(hit(250, line + 2) == .gainLine(id: "mu-1"))
        #expect(hit(103, line, option: true) == .edge(id: "mu-1", edge: .start))
        #expect(hit(50, 10) == .empty)
        #expect(hit(450, line) == .empty)
    }

    @Test func theNearestEdgeWinsBetweenNeighbours() {
        let (document, map) = Self.document([Self.item("mu-1", from: 0, to: 50), Self.item("mu-2", from: 50, to: 100)])
        let blocks = MusicTrackRules.blocks(document, timeMap: map, lengths: [:])
        let spans = [(blocks[0], x: 0.0...100.0), (blocks[1], x: 102.0...200.0)]
        func hit(_ x: Double) -> MusicTrackHit { MusicTrackRules.hit(x: x, y: 5, option: false, height: 36, blocks: spans) }
        #expect(hit(99) == .edge(id: "mu-1", edge: .end))
        #expect(hit(103) == .edge(id: "mu-2", edge: .start))
    }
}
