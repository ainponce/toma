// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

import Analysis
import ProjectFormat

@testable import Editing

/// One clip of `take-001` [0, 300) s at 60 fps; recorded markers at 60 s (no entry); an added "Demo" at 120 s.
private enum Fixture {
    static let base = HostTime(nanoseconds: 100_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func ns(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }
    static let recorded: MarkerList.Recorded = ["take-001": [at(60)]]
    static let sequence = [Clip(id: "c-00000001", take: "take-001", start: at(0), end: at(300), speed: 1)]
    static var timeMap: TimeMap { TimeMap(sequence: sequence) }
    static let demo = Marker(id: "m-0000000a", take: "take-001", t: at(120), name: "Demo", origin: .added)

    static func document(_ items: [Marker] = []) -> EditDocument {
        EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: sequence,
            screens: ScreenPlan(initial: [:], changes: []), style: DefaultStyle.toma.style, cursor: DefaultStyle.toma.cursor,
            zoom: ZoomPlan(show: true, auto: DefaultStyle.toma.zoomAuto, spring: DefaultStyle.toma.zoomSpring, motionBlur: 0, regions: [], suppressed: []),
            camera: CameraPlan(show: true, initial: [:], changes: []), audio: AudioPlan(limiter: false, tracks: [:]),
            markers: MarkerPlan(items: items))
    }

    final class Counter: @unchecked Sendable {
        var n = 0
        func make(_ prefix: String) -> String {
            n += 1
            return prefix + String(repeating: "0", count: 7) + String(n)
        }
    }

    static func chapter(_ s: Double, _ title: String) -> Chapter { Chapter(start: ns(s), title: title) }

    static func visible(_ doc: EditDocument) -> [VisibleMarker] {
        MarkerList.visible(document: doc, recorded: recorded, timeMap: timeMap)
    }
}

@Test func addingChaptersIsOneUndoStep() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let chapters = [Fixture.chapter(0, "Intro"), Fixture.chapter(30, "Instalar"), Fixture.chapter(200, "Cierre")]
    let result = try #require(
        ChapterCommands.add(doc, chapters, timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make))
    #expect(result.step.label == .markerChapters)
    #expect(result.step.target == "m-00000001")
    #expect((result.added, result.named, result.skipped) == (3, 0, 0))
    let after = try doc.applying(result.step.changes)
    let shown = MarkerList.visible(document: after, recorded: [:], timeMap: Fixture.timeMap)
    #expect(shown.map(\.name) == ["Intro", "Instalar", "Cierre"])
    #expect(shown.allSatisfy { $0.origin == .added })
    let undone = try after.applying(result.step.changes.reversed().map(\.inverse))
    #expect(undone == doc)
}

@Test func anUnnamedMarkerTakesTheName() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let result = try #require(
        ChapterCommands.add(
            doc, [Fixture.chapter(60, "Parte")], timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make))
    #expect((result.added, result.named, result.skipped) == (0, 1, 0))
    let after = try doc.applying(result.step.changes)
    #expect(after.markers.items == [Marker(id: "m-00000001", take: "take-001", t: Fixture.at(60), name: "Parte", origin: .recorded)])
    // The entry of an unnamed one that already has it is renamed in place.
    let entry = Marker(id: "m-0000000b", take: "take-001", t: Fixture.at(60), origin: .recorded)
    let withEntry = Fixture.document([entry])
    let again = try #require(
        ChapterCommands.add(
            withEntry, [Fixture.chapter(60, "Parte")], timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make))
    #expect(again.step.target == "m-0000000b")
    #expect(try withEntry.applying(again.step.changes).markers.items.map(\.name) == ["Parte"])
}

@Test func aNamedMarkerIsKeptAndCounted() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document([Fixture.demo])
    #expect(
        ChapterCommands.add(
            doc, [Fixture.chapter(120, "Otro")], timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make) == nil)
    let result = try #require(
        ChapterCommands.add(
            doc, [Fixture.chapter(120, "Otro"), Fixture.chapter(10, "Antes")], timeMap: Fixture.timeMap,
            recorded: Fixture.recorded, makeID: ids.make))
    #expect((result.added, result.named, result.skipped) == (1, 0, 1))
    let after = try doc.applying(result.step.changes)
    #expect(Fixture.visible(after).map(\.name).contains("Demo"))
    #expect(!Fixture.visible(after).map(\.name).contains("Otro"))
}

@Test func twoOnOneFrameKeepTheFirst() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let chapters = [Fixture.chapter(30, "el primero"), Chapter(start: Fixture.ns(30) + 5_000_000, title: "el segundo")]
    let result = try #require(ChapterCommands.add(doc, chapters, timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make))
    #expect((result.added, result.named, result.skipped) == (1, 0, 1))
    #expect(try doc.applying(result.step.changes).markers.items.map(\.name) == ["el primero"])
}

@Test func aCutOutputAddsNothing() {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let past = [Fixture.chapter(300, "Fin"), Fixture.chapter(400, "Nada")]
    #expect(ChapterCommands.add(doc, past, timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make) == nil)
    // A cut clip: only [0, 100) s and [200, 300) s remain; output 100 s is source 200 s, nothing is lost, but 250 s is past the end.
    let cut = [
        Clip(id: "c-00000001", take: "take-001", start: Fixture.at(0), end: Fixture.at(100), speed: 1),
        Clip(id: "c-00000002", take: "take-001", start: Fixture.at(200), end: Fixture.at(300), speed: 1),
    ]
    var short = doc
    short.sequence = cut
    let result = ChapterCommands.add(
        short, [Fixture.chapter(250, "Fuera"), Fixture.chapter(150, "Dentro")], timeMap: TimeMap(sequence: cut), recorded: [:],
        makeID: ids.make)
    #expect(result?.added == 1)
    #expect(result?.skipped == 1)
}

@Test func namesAreNormalized() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let long = String(repeating: "x", count: 120)
    let result = try #require(
        ChapterCommands.add(
            doc, [Fixture.chapter(10, "  Instalar  \n"), Fixture.chapter(20, long), Fixture.chapter(30, "  ")],
            timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make))
    #expect(result.skipped == 1)
    #expect(try doc.applying(result.step.changes).markers.items.map(\.name) == ["Instalar", String(repeating: "x", count: 100)])
}

@Test func twoAdditionsAreTwoUndoSteps() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let first = try #require(
        ChapterCommands.add(doc, [Fixture.chapter(10, "A")], timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make))
    let next = try doc.applying(first.step.changes)
    let second = try #require(
        ChapterCommands.add(next, [Fixture.chapter(20, "B")], timeMap: Fixture.timeMap, recorded: [:], makeID: ids.make))
    #expect(first.step.target != second.step.target)
}
