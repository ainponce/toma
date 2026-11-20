// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

import Analysis
import ProjectFormat

@testable import Editing

/// Clips of `take-001` [0, 2) and [3, 5) s and of `take-002` [0, 1) s: output 0–2, 2–4, 4–5 s.
private enum Fixture {
    static let base = HostTime(nanoseconds: 100_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func ns(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }
    static let recorded: MarkerList.Recorded = ["take-001": [at(1), at(3.5)], "take-002": [at(0.5)]]
    static let sequence = [
        Clip(id: "c-00000001", take: "take-001", start: at(0), end: at(2), speed: 1),
        Clip(id: "c-00000002", take: "take-001", start: at(3), end: at(5), speed: 1),
        Clip(id: "c-00000003", take: "take-002", start: at(0), end: at(1), speed: 1),
    ]
    static var timeMap: TimeMap { TimeMap(sequence: sequence) }

    static func document(_ items: [Marker] = []) -> EditDocument {
        EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: sequence,
            screens: ScreenPlan(initial: [:], changes: []), style: DefaultStyle.toma.style, cursor: DefaultStyle.toma.cursor,
            zoom: ZoomPlan(show: true, auto: DefaultStyle.toma.zoomAuto, spring: DefaultStyle.toma.zoomSpring, motionBlur: 0, regions: [], suppressed: []),
            camera: CameraPlan(show: true, initial: [:], changes: []), audio: AudioPlan(limiter: false, tracks: [:]),
            markers: MarkerPlan(items: items))
    }

    static func visible(_ doc: EditDocument) -> [VisibleMarker] {
        MarkerList.visible(document: doc, recorded: recorded, timeMap: timeMap)
    }

    /// A `makeID` that counts.
    final class Counter: @unchecked Sendable {
        var n = 0
        func make(_ prefix: String) -> String {
            n += 1
            return prefix + String(repeating: "0", count: 7) + String(n)
        }
    }

    static func apply(_ step: EditStep?, to doc: EditDocument) throws -> EditDocument {
        try doc.applying(try #require(step).changes)
    }

    static func undo(_ step: EditStep, from doc: EditDocument) throws -> EditDocument {
        try doc.applying(step.changes.reversed().map(\.inverse))
    }
}

@Test func renamingARecordedMarkerAddsItsEntry() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let recorded = Fixture.visible(doc)[0]
    let step = try #require(MarkerCommands.rename(doc, recorded, to: "Intro", makeID: ids.make))
    #expect(step.label == .markerRename)
    let renamed = try Fixture.apply(step, to: doc)
    #expect(renamed.markers.items == [Marker(id: "m-00000001", take: "take-001", t: Fixture.at(1), name: "Intro", origin: .recorded)])
    #expect(step.target == "m-00000001")
    let shown = Fixture.visible(renamed)
    #expect(shown.count == 3 && shown[0].name == "Intro" && shown[0].entryID == "m-00000001")
    // Again: one set. An empty name: no name.
    let again = try #require(MarkerCommands.rename(renamed, shown[0], to: "Start", makeID: ids.make))
    #expect(again.changes.count == 1)
    let blank = try Fixture.apply(MarkerCommands.rename(renamed, shown[0], to: "  ", makeID: ids.make), to: renamed)
    #expect(blank.markers.items[0].name.isEmpty)
    #expect(try Fixture.undo(step, from: renamed) == doc)
    // An empty name on one without an entry is nothing; the same name is nothing.
    #expect(MarkerCommands.rename(doc, recorded, to: " ", makeID: ids.make) == nil)
    #expect(MarkerCommands.rename(renamed, shown[0], to: "Intro", makeID: ids.make) == nil)
}

@Test func movingARecordedMarkerLeavesNoTwin() throws {
    let ids = Fixture.Counter()
    let named = Marker(id: "m-00000009", take: "take-001", t: Fixture.at(1), name: "Intro", origin: .recorded)
    let doc = Fixture.document([named])
    let marker = Fixture.visible(doc)[0]
    let step = try #require(MarkerCommands.move(doc, marker, toOutput: Fixture.ns(3), timeMap: Fixture.timeMap, makeID: ids.make))
    #expect(step.label == .markerMove)
    let moved = try Fixture.apply(step, to: doc)
    #expect(moved.markers.items.count == 2)
    #expect(moved.markers.items[0].hidden && moved.markers.items[0].id == "m-00000009")
    #expect(moved.markers.items[1] == Marker(id: "m-00000001", take: "take-001", t: Fixture.at(4), name: "Intro", origin: .added))
    let shown = Fixture.visible(moved)
    #expect(shown.map(\.output) == [2.5, 3, 4.5].map(Fixture.ns))
    #expect(!shown.contains { $0.t == Fixture.at(1) && $0.take == "take-001" })
    #expect(try Fixture.undo(step, from: moved) == doc)
    // One that was never named: a hidden entry and the added one.
    let plain = Fixture.visible(Fixture.document())[0]
    let fresh = try Fixture.apply(
        MarkerCommands.move(Fixture.document(), plain, toOutput: Fixture.ns(0.5), timeMap: Fixture.timeMap, makeID: ids.make),
        to: Fixture.document())
    #expect(fresh.markers.items.map(\.hidden) == [true, false])
    #expect(Fixture.visible(fresh).map(\.output) == [0.5, 2.5, 4.5].map(Fixture.ns))
}

@Test func movingAnAddedMarkerAcrossTakes() throws {
    let ids = Fixture.Counter()
    let added = Marker(id: "m-00000005", take: "take-001", t: Fixture.at(1.5), name: "Here", origin: .added)
    let doc = Fixture.document([added])
    let marker = try #require(Fixture.visible(doc).first { $0.id == "m-00000005" })
    let step = try #require(MarkerCommands.move(doc, marker, toOutput: Fixture.ns(4.25), timeMap: Fixture.timeMap, makeID: ids.make))
    let moved = try Fixture.apply(step, to: doc)
    #expect(moved.markers.items == [Marker(id: "m-00000005", take: "take-002", t: Fixture.at(0.25), name: "Here", origin: .added)])
    #expect(step.changes.count == 1)
    #expect(MarkerCommands.move(moved, try #require(Fixture.visible(moved).first { $0.id == "m-00000005" }), toOutput: Fixture.ns(4.25), timeMap: Fixture.timeMap, makeID: ids.make) == nil)
}

@Test func deletingHidesRecordedAndRemovesAdded() throws {
    let ids = Fixture.Counter()
    let added = Marker(id: "m-00000005", take: "take-001", t: Fixture.at(1.5), name: "Here", origin: .added)
    let doc = Fixture.document([added])
    let shown = Fixture.visible(doc)
    let recorded = shown[0], mine = try #require(shown.first { $0.id == "m-00000005" })
    let hide = try #require(MarkerCommands.delete(doc, recorded, makeID: ids.make))
    #expect(hide.label == .markerDelete)
    let hidden = try Fixture.apply(hide, to: doc)
    #expect(hidden.markers.items.count == 2 && hidden.markers.items[1].hidden)
    #expect(Fixture.visible(hidden).count == 3)
    #expect(try Fixture.undo(hide, from: hidden) == doc)
    let remove = try #require(MarkerCommands.delete(doc, mine, makeID: ids.make))
    let removed = try Fixture.apply(remove, to: doc)
    #expect(removed.markers.items.isEmpty)
    #expect(try Fixture.undo(remove, from: removed) == doc)
    // A recorded one with an entry: that entry hidden, no second one.
    let named = Marker(id: "m-00000007", take: "take-001", t: Fixture.at(1), name: "N", origin: .recorded)
    let withEntry = Fixture.document([named])
    let step = try #require(MarkerCommands.delete(withEntry, Fixture.visible(withEntry)[0], makeID: ids.make))
    #expect(try Fixture.apply(step, to: withEntry).markers.items == [Marker(id: "m-00000007", take: "take-001", t: Fixture.at(1), name: "N", origin: .recorded, hidden: true)])
}

@Test func addingAnchorsToTheClipsTake() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    let step = try #require(MarkerCommands.add(doc, atOutput: Fixture.ns(4.25), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make))
    #expect(step.label == .markerAdd)
    let added = try Fixture.apply(step, to: doc)
    #expect(added.markers.items.count == 1)
    let marker = added.markers.items[0]
    #expect(marker.take == "take-002" && marker.t == Fixture.at(0.25) && marker.origin == .added && marker.name.isEmpty)
    #expect(marker.id.hasPrefix("m-"))
    #expect(try Fixture.undo(step, from: added) == doc)
    // Nothing to show at the end of an empty output.
    var empty = doc
    empty.sequence = []
    #expect(MarkerCommands.add(empty, atOutput: 0, timeMap: TimeMap(sequence: []), recorded: [:], makeID: ids.make) == nil)
}

@Test func addingOnAFreezeAnchorsToItsPoint() throws {
    let ids = Fixture.Counter()
    var doc = Fixture.document()
    doc.sequence = [
        Clip(id: "c-00000001", take: "take-001", start: Fixture.at(0), end: Fixture.at(1), speed: 1),
        Clip(id: "c-00000002", take: "take-001", start: Fixture.at(1), end: Fixture.at(1), speed: 1, content: .freeze(duration: Fixture.ns(2))),
        Clip(id: "c-00000003", take: "take-001", start: Fixture.at(1), end: Fixture.at(2), speed: 1),
    ]
    let map = TimeMap(sequence: doc.sequence)
    let step = try #require(MarkerCommands.add(doc, atOutput: Fixture.ns(2), timeMap: map, recorded: [:], makeID: ids.make))
    let added = try Fixture.apply(step, to: doc)
    #expect(added.markers.items[0].t == Fixture.at(1))
    // It shows where the frozen frame starts, not where the stretch after it does.
    #expect(MarkerList.visible(document: added, recorded: [:], timeMap: map).map(\.output) == [Fixture.ns(1)])
}

/// M on a title card, or on a frozen frame, shows the marker where that clip starts, wherever the clip is: at the start of
/// the output, splitting a stretch, at the end of the output, a frozen frame at a stretch's end with a cut after it.
@Test func addingOnACardOrAFreezeShowsAtItsStart() throws {
    let card = ClipContent.card(TitleCard(title: "Capítulo 2", style: .centered, background: .stage), duration: Fixture.ns(3))
    func point(_ id: String, _ s: Double, _ content: ClipContent = card) -> Clip {
        Clip(id: id, take: "take-001", start: Fixture.at(s), end: Fixture.at(s), speed: 1, content: content)
    }
    func stretch(_ id: String, _ start: Double, _ end: Double) -> Clip {
        Clip(id: id, take: "take-001", start: Fixture.at(start), end: Fixture.at(end), speed: 1)
    }
    // (the sequence, an output time on the card or the frozen frame, where it starts)
    let cases: [([Clip], Double, Double)] = [
        ([point("c-00000001", 0), stretch("c-00000002", 0, 4)], 1.5, 0),
        ([stretch("c-00000001", 0, 2), point("c-00000002", 2), stretch("c-00000003", 2, 4)], 3.5, 2),
        ([stretch("c-00000001", 0, 2), point("c-00000002", 2)], 3.5, 2),
        ([stretch("c-00000001", 0, 2), point("c-00000002", 2, .freeze(duration: Fixture.ns(2))), stretch("c-00000003", 3, 5)], 3, 2),
    ]
    for (sequence, τ, start) in cases {
        let ids = Fixture.Counter()
        var doc = Fixture.document()
        doc.sequence = sequence
        let map = TimeMap(sequence: sequence)
        let step = try #require(MarkerCommands.add(doc, atOutput: Fixture.ns(τ), timeMap: map, recorded: [:], makeID: ids.make))
        let added = try Fixture.apply(step, to: doc)
        let shown = MarkerList.visible(document: added, recorded: [:], timeMap: map)
        #expect(shown.map(\.output) == [Fixture.ns(start)])
        // M again elsewhere on the same clip would put a second one on that frame: nothing.
        #expect(MarkerCommands.add(added, atOutput: Fixture.ns(τ + 0.25), timeMap: map, recorded: [:], makeID: ids.make) == nil)
    }
}

@Test func addingTwiceOnOneFrameIsNothing() throws {
    let ids = Fixture.Counter()
    let doc = Fixture.document()
    // The recorded marker at 1 s is on frame 60; so is 1 s + a few ms.
    #expect(MarkerCommands.add(doc, atOutput: Fixture.ns(1), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make) == nil)
    #expect(MarkerCommands.add(doc, atOutput: Fixture.ns(1.005), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make) == nil)
    let first = try Fixture.apply(
        MarkerCommands.add(doc, atOutput: Fixture.ns(1.5), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make), to: doc)
    #expect(MarkerCommands.add(first, atOutput: Fixture.ns(1.5), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: ids.make) == nil)
}

@Test func nameIsTrimmedAndBounded() {
    #expect(MarkerCommands.normalized(String(repeating: "a", count: 120)).count == 100)
    #expect(MarkerCommands.normalized("\n Intro \n") == "Intro")
    #expect(MarkerCommands.normalized("   ").isEmpty)
}

@Test func existingIDsAreNeverReused() throws {
    let doc = Fixture.document([Marker(id: "m-00000001", take: "take-001", t: Fixture.at(1.5), origin: .added)])
    let step = try #require(MarkerCommands.add(doc, atOutput: Fixture.ns(0.2), timeMap: Fixture.timeMap, recorded: Fixture.recorded, makeID: { _ in "m-00000001" }))
    let added = try Fixture.apply(step, to: doc)
    #expect(Set(added.markers.items.map(\.id)).count == 2)
}
