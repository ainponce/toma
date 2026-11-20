// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the music commands' tests: a document of one clip of 60 s at 1× (`take-001`, from `base`) cut to
/// `seconds`, with `items` as its music.
private enum MusicFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let theme = "library:music-1/calm"

    static func s(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    static func item(
        _ id: String, _ from: Double, _ to: Double, offset: Double = 0, loop: Bool = true, fadeIn: Double = 0.5, fadeOut: Double = 0.5
    ) -> MusicItem {
        MusicItem(
            id: id, source: theme, start: s(from), end: s(to), offset: s(offset), gain: -14, fadeIn: s(fadeIn), fadeOut: s(fadeOut), loop: loop)
    }

    static func document(seconds: Double = 20, _ items: [MusicItem] = []) -> EditDocument {
        let take = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "display-1", kind: .display,
                    source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                    segments: [
                        SegmentRecord(
                            index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base,
                            endHostTime: base.adding(seconds: 60), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                    ])
            ])
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [Clip(id: "c-00000001", take: "take-001", start: base, end: base.adding(seconds: seconds), speed: 1)]
        document.music.items = items
        return document
    }

    static func map(_ document: EditDocument) -> TimeMap { TimeMap(sequence: document.sequence) }

    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        #expect(DocumentRules.problems(in: edited).isEmpty)
        return edited
    }

    static func ids() -> (String) -> String {
        { prefix in prefix + "000000a1" }
    }
}

@Suite struct MusicCommandsTests {
    private typealias F = MusicFixture

    @Test func theFirstThemeCoversTheVideo() throws {
        let document = F.document()
        let step = try #require(MusicCommands.add(document, source: F.theme, atOutput: F.s(3), timeMap: F.map(document), makeID: F.ids()))
        #expect(step.label == .musicAdd)
        #expect(step.target == "mu-000000a1")
        let item = try #require(try F.applying(step, to: document).music.items.first)
        #expect(item == MusicItem(
            id: "mu-000000a1", source: F.theme, start: 0, end: F.s(20), offset: 0, gain: -14, fadeIn: 1_000_000_000,
            fadeOut: 2_000_000_000, loop: true))
        #expect(MusicCommands.add(document, source: "http://example.com/a.mp3", atOutput: 0, timeMap: F.map(document), makeID: F.ids()) == nil)
        // A short gap: the fades are held to half of it.
        let short = MusicCommands.newItem(id: "mu-1", source: F.theme, output: 0..<F.s(1.5))
        #expect(short.fadeIn == F.s(0.75) && short.fadeOut == F.s(0.75))
    }

    @Test func moreMusicGoesInTheGapAtThePlayhead() throws {
        let document = F.document([F.item("mu-a", 0, 5), F.item("mu-b", 8, 14)])
        let map = F.map(document)
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(6), timeMap: map) == F.s(5)..<F.s(8))
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(5), timeMap: map) == F.s(5)..<F.s(8))
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(2), timeMap: map) == nil)
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(16), timeMap: map) == F.s(14)..<F.s(20))
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(20), timeMap: map) == F.s(14)..<F.s(20))
        let step = try #require(MusicCommands.add(document, source: F.theme, atOutput: F.s(6), timeMap: map, makeID: F.ids()))
        let edited = try F.applying(step, to: document)
        #expect(edited.music.items.map(\.id) == ["mu-a", "mu-000000a1", "mu-b"])
        #expect(edited.music.items[1].start == F.s(5) && edited.music.items[1].end == F.s(8))
        // Less than 1 s free.
        let tight = F.document([F.item("mu-a", 0, 10), F.item("mu-b", 10.5, 20)])
        #expect(MusicCommands.roomForNew(tight, atOutput: F.s(10.2), timeMap: F.map(tight)) == nil)
        #expect(MusicCommands.add(tight, source: F.theme, atOutput: F.s(10.2), timeMap: F.map(tight), makeID: F.ids()) == nil)
    }

    @Test func itemsNeverOverlap() throws {
        let document = F.document([F.item("mu-a", 2, 6), F.item("mu-b", 9, 12)])
        let map = F.map(document)
        func moved(_ id: String, to seconds: Double) -> MusicItem? {
            MusicCommands.move(document, id: id, toOutputStart: F.s(seconds), timeMap: map)
                .flatMap { try? document.applying($0.changes) }?.music.items.first { $0.id == id }
        }
        #expect(moved("mu-a", to: 8)?.start == F.s(5))  // 4 s long, stops at mu-b (9 - 4)
        #expect(moved("mu-a", to: -5)?.start == 0)
        #expect(moved("mu-b", to: 30)?.start == F.s(17))  // 3 s long, ends at the output's 20 s
        #expect(moved("mu-b", to: 0)?.start == F.s(6))
        #expect(MusicCommands.move(document, id: "mu-a", toOutputStart: F.s(2), timeMap: map) == nil)
        #expect(MusicCommands.move(document, id: "mu-x", toOutputStart: F.s(2), timeMap: map) == nil)

        func trimmed(_ id: String, _ edge: ClipEdge, to seconds: Double) -> MusicItem? {
            MusicCommands.trim(document, id: id, edge: edge, toOutput: F.s(seconds), timeMap: map)
                .flatMap { try? document.applying($0.changes) }?.music.items.first { $0.id == id }
        }
        #expect(trimmed("mu-a", .end, to: 15)?.end == F.s(9))
        #expect(trimmed("mu-b", .end, to: 99)?.end == F.s(20))
        #expect(trimmed("mu-b", .start, to: 0) == nil)  // its music starts there: no earlier
        #expect(trimmed("mu-b", .start, to: 10)?.start == F.s(10))
        // At least 1 s: a shorter one only grows.
        #expect(trimmed("mu-a", .end, to: 2.2)?.end == F.s(3))
        #expect(trimmed("mu-a", .start, to: 6)?.start == F.s(5))
        #expect(MusicCommands.trim(document, id: "mu-a", edge: .end, toOutput: F.s(6), timeMap: map) == nil)
    }

    @Test func trimmingTheStartKeepsTheMusicInPlace() throws {
        let document = F.document([F.item("mu-a", 0, 10, fadeIn: 1, fadeOut: 2)])
        let map = F.map(document)
        let step = try #require(MusicCommands.trim(document, id: "mu-a", edge: .start, toOutput: F.s(2), timeMap: map))
        #expect(step.label == .musicTrim)
        let item = try #require(try F.applying(step, to: document).music.items.first)
        #expect(item.start == F.s(2) && item.end == F.s(10) && item.offset == F.s(2))
        // Back out: the offset comes back, and never goes below 0.
        let again = try #require(MusicCommands.trim(try F.applying(step, to: document), id: "mu-a", edge: .start, toOutput: F.s(-4), timeMap: map))
        #expect(try F.applying(again, to: try F.applying(step, to: document)).music.items.first?.start == 0)
        #expect(MusicCommands.trim(document, id: "mu-a", edge: .start, toOutput: F.s(-4), timeMap: map) == nil)
        // The fades follow the length.
        let small = try #require(MusicCommands.trim(document, id: "mu-a", edge: .end, toOutput: F.s(1.2), timeMap: map))
        let held = try #require(try F.applying(small, to: document).music.items.first)
        #expect(held.fadeIn == F.s(0.6) && held.fadeOut == F.s(0.6))
    }

    @Test func slipWrapsWithTheLoop() throws {
        let document = F.document([F.item("mu-a", 0, 10), F.item("mu-b", 12, 18, loop: false)])
        func slipped(_ id: String, _ seconds: Double, theme: Double?) -> Int64? {
            MusicCommands.slip(document, id: id, offset: F.s(seconds), themeLength: theme.map(F.s))
                .flatMap { try? document.applying($0.changes) }?.music.items.first { $0.id == id }?.offset
        }
        #expect(slipped("mu-a", 130, theme: 120) == F.s(10))
        #expect(slipped("mu-b", 130, theme: 120) == F.s(130))
        #expect(slipped("mu-a", 130, theme: nil) == F.s(130))
        #expect(slipped("mu-a", -4, theme: 120) == nil)  // 0 already
        #expect(slipped("mu-b", 3, theme: 120) == F.s(3))
        #expect(MusicCommands.slip(document, id: "mu-a", offset: 0, themeLength: 120) == nil)
    }

    @Test func changeHoldsItsValues() throws {
        let document = F.document([F.item("mu-a", 0, 10)])
        func changed(_ edit: (inout MusicItem) -> Void) throws -> MusicItem? {
            try MusicCommands.change(document, id: "mu-a", edit).map { try F.applying($0, to: document).music.items[0] }
        }
        let long = try #require(try changed { $0.fadeIn = F.s(9); $0.fadeOut = -5 })
        #expect(long.fadeIn == F.s(5) && long.fadeOut == 0)
        #expect(try changed { $0.source = "http://example.com/a.mp3" } == nil)
        #expect(try changed { $0.gain = .nan } == nil)
        #expect(try changed { _ in } == nil)
        #expect(try changed { $0.gain = 10 }?.gain == 6)
        #expect(try changed { $0.gain = -500 }?.gain == -120)
        #expect(try changed { $0.offset = -1 } == nil)  // 0 already
        #expect(try changed { $0.offset = F.s(-1); $0.gain = -3 }?.offset == 0)
        // The place is not for `change`.
        let place = try #require(try changed { $0.start = F.s(5); $0.id = "mu-z"; $0.gain = -10 })
        #expect(place.start == 0 && place.id == "mu-a" && place.gain == -10)
        #expect(try changed { $0.source = "assets/0123456789abcdef0123456789abcdef.m4a" }?.source == "assets/0123456789abcdef0123456789abcdef.m4a")
        let step = try #require(MusicCommands.change(document, id: "mu-a") { $0.loop = false })
        #expect(step.label == .musicChange)
        #expect(MusicCommands.change(document, id: "mu-x") { $0.loop = false } == nil)
    }

    @Test func duckingIsSetWhole() throws {
        let document = F.document()
        let step = try #require(MusicCommands.setDucking(document, Ducking(enabled: false, amount: -60, attack: 0, release: 9)))
        #expect(step.label == .musicDucking)
        #expect(step.target == "/music/ducking")
        #expect(step.changes.count == 1)
        #expect(try F.applying(step, to: document).music.ducking == Ducking(enabled: false, amount: -40, attack: 0.05, release: 4))
        let nan = try #require(MusicCommands.setDucking(document, Ducking(enabled: true, amount: -9, attack: .nan, release: .nan)))
        #expect(try F.applying(nan, to: document).music.ducking == Ducking(enabled: true, amount: -9, attack: 0.3, release: 0.8))
        #expect(MusicCommands.setDucking(document, .default) == nil)
        #expect(MusicCommands.setDucking(document, Ducking(enabled: true, amount: 5, attack: 0.3, release: 0.8))?.changes.count == 1)
    }

    @Test func deleteTakesTheItemOut() throws {
        let document = F.document([F.item("mu-a", 0, 10)])
        let step = try #require(MusicCommands.delete(document, id: "mu-a"))
        #expect(step.label == .musicDelete)
        #expect(try F.applying(step, to: document).music.items.isEmpty)
        #expect(MusicCommands.delete(document, id: "mu-x") == nil)
    }

    @Test func shownItemsEndWithTheOutput() throws {
        let document = F.document(seconds: 6, [F.item("mu-a", 1, 10), F.item("mu-b", 7, 12)])
        let shown = MusicCommands.shownItems(document, timeMap: F.map(document))
        #expect(shown.map(\.id) == ["mu-a"])
        #expect(shown.first?.output == F.s(1)..<F.s(6))
        // The gap before it lasts 1 s; the item that ends with the output leaves none after it.
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(0.5), timeMap: F.map(document)) == 0..<F.s(1))
        #expect(MusicCommands.roomForNew(document, atOutput: F.s(6), timeMap: F.map(document)) == nil)
    }
}
