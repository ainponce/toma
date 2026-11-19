// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// @testable for `ProjectJSON.compactEncoder()`, the encoder a `JSONValue` goes through.
@testable import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private func parsed(_ text: String) throws -> JSONValue {
    try ProjectJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func pretty(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.encoder().encode(value), as: UTF8.self)
}

private func set(_ path: String) throws -> EditChange {
    .set(path: try JSONPointer(path), before: .bool(false), after: .bool(true))
}

extension JSONValue {
    /// The member `key` of an object; `nil` removes it. Reading or writing it on anything else does nothing.
    fileprivate subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(members) = self else { return nil }
            return members[key]
        }
        set {
            guard case var .object(members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }

    /// The value at `pointer`, `nil` if there is none.
    fileprivate func at(_ pointer: String) -> JSONValue? {
        (try? JSONPointer(pointer)).flatMap { value(at: $0) }
    }
}

/// What the migration from version 2 writes (phase 2 design §8), as the design gives the legacy values.
private let addedFrom2: [String: JSONValue] = [
    "/captions": .object([
        "show": .bool(false),
        "style": .object([
            "highlight": .bool(true), "highlightColor": .array([.integer(1), .number(214.0 / 255), .number(10.0 / 255), .integer(1)]),
            "position": .string("bottom"), "preset": .string("bold"), "size": .string("medium"), "uppercase": .bool(false),
        ]),
    ]),
    "/keys": .object(["mode": .string("off"), "position": .string("bottomCenter"), "size": .string("medium")]),
    "/privacy": .object(["blocks": .array([])]),
    "/style/reframe": .string("fit"),
    "/camera/background": .string("original"),
    "/camera/framing": .object([
        "center": .object(["x": .number(0.5), "y": .number(0.5)]), "mode": .string("center"), "zoom": .integer(1),
    ]),
    "/camera/look": .object(["intensity": .integer(1), "preset": .string("natural")]),
    "/camera/syncOffset": .integer(0),
    "/audio/normalize": .bool(false),
]

// MARK: - Version 2 is read migrated to 3

@Test func version2DecodesMigratedTo3() throws {
    let v2 = try parsed(DesignExample.canonical)
    #expect(v2["documentVersion"] == .integer(2))
    let document = try EditDocument.decode(Data(DesignExample.canonical.utf8))
    #expect(document.documentVersion == 3)
    #expect(document.transcript == nil)
    #expect(document.captions == .legacy)
    #expect(document.privacy.blocks.isEmpty)
    #expect(document.keys == .legacy)
    #expect(document.style.reframe == .fit)
    #expect(document.camera.background == .original)
    #expect(document.camera.framing == .legacy)
    #expect(document.camera.look == .natural)
    #expect(document.camera.syncOffset == 0)
    #expect(!document.audio.normalize)
    #expect(document.audio.tracks.count == 2)
    #expect(document.audio.tracks.values.allSatisfy { $0.cleanup == 0 })
    #expect(document == DesignExample.document)
    // Everything else is what 1c read from it: reverted, the bytes 1c wrote.
    let back = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 2))
    #expect(back == v2)
    #expect(try pretty(back) == DesignExample.canonical)

    // The same rule from its JSON, and inside another value, as in the `create` line of a 1c edit log.
    #expect(try EditDocument.decode(json: v2) == document)
    struct Entry: Decodable {
        var document: EditDocument
    }
    let entry = try ProjectJSON.decoder().decode(Entry.self, from: Data("{\"document\" : \(DesignExample.canonical)}".utf8))
    #expect(entry.document == document)
    let createLine = #"{"app":{"name":"Toma","version":"0.3.0"},"document":"#
        + String(decoding: try ProjectJSON.compactEncoder().encode(v2), as: UTF8.self) + #","seq":1,"type":"create"}"#
    #expect(try EditLogEntry(jsonLine: createLine) == .create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.3.0")))
    #expect(EditDocument.writtenVersion(of: Data(DesignExample.canonical.utf8)) == 2)
}

@Test func version1MigratesThroughBothSteps() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try DocumentMigration.migrate(v1, from: 1)
    let v3 = try DocumentMigration.migrate(v2, from: 2)
    #expect(v2["documentVersion"] == .integer(2))
    #expect(v3["documentVersion"] == .integer(3))
    let document = try EditDocument.decode(Data(DocumentV1Example.canonical.utf8))
    #expect(document == (try v3.decoded(as: EditDocument.self)))
    #expect(document == (try EditDocument.decode(json: v1)))
    #expect(document == DesignExample.document)
    #expect(document.documentVersion == 3)
    // And back, one version at a time.
    #expect(DocumentMigration.reverted(v3, to: 2) == v2)
    #expect(DocumentMigration.reverted(v3, to: 1) == v1)
    #expect(try pretty(#require(DocumentMigration.reverted(JSONValue(encoding: document), to: 1))) == DocumentV1Example.canonical)
}

@Test func migrationFrom2AddsOnlyItsPlaces() throws {
    // The design example has two audio tracks: each gets its `cleanup`.
    let v2 = try parsed(DesignExample.canonical)
    let migrated = try DocumentMigration.migrate(v2, from: 2)
    #expect(migrated["documentVersion"] == .integer(3))
    #expect(DocumentMigration.addedPlaces[2] == [
        "/captions", "/keys", "/privacy", "/style/reframe", "/camera/background", "/camera/framing", "/camera/look",
        "/camera/syncOffset", "/audio/normalize", "/audio/tracks/*/cleanup",
    ])
    #expect(DocumentMigration.addedPlaces[1] == DocumentMigration.addedCameraFields.map { "/camera/" + $0 })
    #expect(DocumentMigration.addedPlaces.keys.sorted() == [1, 2])
    var rest = migrated
    rest["documentVersion"] = .integer(2)
    for (place, value) in addedFrom2 {
        #expect(migrated.at(place) == value, "\(place)")
        #expect(v2.at(place) == nil, "\(place)")
        let components = try JSONPointer(place).components
        switch components.count {
        case 1: rest[components[0]] = nil
        default: rest[components[0]]?[components[1]] = nil
        }
    }
    for track in ["take-001/mic", "take-001/system-audio"] {
        #expect(migrated["audio"]?["tracks"]?[track]?["cleanup"] == .integer(0), "\(track)")
        #expect(v2["audio"]?["tracks"]?[track]?["cleanup"] == nil, "\(track)")
        rest["audio"]?["tracks"]?[track]?["cleanup"] = nil
    }
    #expect(rest == v2)
    // What it writes is what the legacy values of the types encode to.
    let legacy = try JSONValue(encoding: EditDocument.legacy(take: TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: []))
    for (place, value) in addedFrom2 {
        #expect(legacy.at(place) == value, "\(place)")
    }
    #expect(try JSONValue(encoding: TrackGain(gain: 1, muted: false))["cleanup"] == .integer(0))

    // What was already there is overwritten.
    var handWritten = v2
    handWritten["keys"] = .string("all")
    handWritten["camera"]?["syncOffset"] = .integer(5)
    handWritten["audio"]?["tracks"]?["take-001/mic"]?["cleanup"] = .number(0.5)
    #expect(try DocumentMigration.migrate(handWritten, from: 2) == migrated)

    // A document without tracks migrates; one without the objects it writes in does not.
    var silent = v2
    silent["audio"]?["tracks"] = .object([:])
    #expect(try DocumentMigration.migrate(silent, from: 2)["audio"]?["tracks"] == .object([:]))
    for (missing, error) in [("style", "/style"), ("camera", "/camera"), ("audio", "/audio")] {
        var without = v2
        without[missing] = nil
        #expect(throws: EditChangeError.invalidDocument(error), "\(missing)") { try DocumentMigration.migrate(without, from: 2) }
        var notAnObject = v2
        notAnObject[missing] = .integer(1)
        #expect(throws: EditChangeError.invalidDocument(error), "\(missing)") { try DocumentMigration.migrate(notAnObject, from: 2) }
    }
    var withoutTracks = v2
    withoutTracks["audio"]?["tracks"] = nil
    #expect(throws: EditChangeError.invalidDocument("/audio/tracks")) { try DocumentMigration.migrate(withoutTracks, from: 2) }
    var trackNotAnObject = v2
    trackNotAnObject["audio"]?["tracks"]?["take-001/mic"] = .integer(1)
    #expect(throws: EditChangeError.invalidDocument("/audio/tracks/take-001~1mic")) {
        try DocumentMigration.migrate(trackNotAnObject, from: 2)
    }

    #expect(DocumentMigration.isAdditive(from: 1))
    #expect(DocumentMigration.isAdditive(from: 2))
    #expect(!DocumentMigration.isAdditive(from: 3))
    #expect(!DocumentMigration.isAdditive(from: 0))
    // No migration from another version, nor of a document of another version.
    for (document, version) in [(v2, 1), (v2, 3), (migrated, 2), (migrated, 3)] {
        #expect(throws: EditChangeError.invalidDocument("/documentVersion"), "\(version)") {
            try DocumentMigration.migrate(document, from: version)
        }
    }
}

// MARK: - Undoing the migration, and what commutes with it

@Test func revertedWalksDownOneVersionAtATime() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try parsed(DesignExample.canonical)
    let v3 = try DocumentMigration.migrate(v2, from: 2)
    #expect(DocumentMigration.reverted(v3, to: 2) == v2)
    #expect(DocumentMigration.reverted(v3, to: 3) == v3)
    #expect(DocumentMigration.reverted(v3, to: 1) == v1)
    #expect(DocumentMigration.reverted(try DocumentMigration.migrate(DocumentMigration.migrate(v1, from: 1), from: 2), to: 1) == v1)
    // Never forward, nor below version 1, nor from a version this app has no migration to.
    #expect(DocumentMigration.reverted(v2, to: 3) == nil)
    #expect(DocumentMigration.reverted(v1, to: 3) == nil)
    #expect(DocumentMigration.reverted(v3, to: 0) == nil)
    var v4 = v3
    v4["documentVersion"] = .integer(4)
    #expect(DocumentMigration.reverted(v4, to: 3) == nil)
    #expect(DocumentMigration.reverted(v4, to: 4) == v4)

    // A document that uses what version 3 adds has no version 2, nor 1.
    let uses: [(String, (inout JSONValue) -> Void)] = [
        ("captions shown", { $0["captions"]?["show"] = .bool(true) }),
        ("a cleanup", { $0["audio"]?["tracks"]?["take-001/mic"]?["cleanup"] = .number(0.6) }),
        ("normalized", { $0["audio"]?["normalize"] = .bool(true) }),
        ("a privacy block", { $0["privacy"]?["blocks"] = .array([.object(["id": .string("p-00000001")])]) }),
        ("following the cursor", { $0["style"]?["reframe"] = .string("followCursor") }),
        ("keys on screen", { $0["keys"]?["mode"] = .string("all") }),
        ("a look", { $0["camera"]?["look"]?["intensity"] = .number(0.5) }),
        ("a lut", { $0["camera"]?["look"]?["lut"] = .string("assets/x.cube") }),
        ("late", { $0["camera"]?["syncOffset"] = .integer(40_000_000) }),
        ("a missing place", { $0["camera"]?["framing"] = nil }),
        ("a transcription", { $0["transcript"] = .object(["engine": .string("speechTranscriber-1")]) }),
        ("a device frame", {
            $0["style"]?["frame"] = .object(["finish": .string("dark"), "model": .string("iPhone"), "type": .string("device")])
        }),
    ]
    for (name, use) in uses {
        var document = v3
        use(&document)
        #expect(document != v3, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 2) == nil, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 1) == nil, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 3) == document, "\(name)")
    }
    // A macOS window frame is of version 2 already.
    var window = v3
    window["style"]?["frame"] = .object([
        "appearance": .string("dark"), "buttons": .bool(true), "title": .string("Notes"), "type": .string("macWindow"),
    ])
    var windowV2 = v2
    windowV2["style"]?["frame"] = window["style"]?["frame"]
    #expect(DocumentMigration.reverted(window, to: 2) == windowV2)

    // A document of version 2 that uses what version 2 adds has no version 1.
    var mirrored = v3
    mirrored["camera"]?["mirror"] = .bool(true)
    #expect(DocumentMigration.reverted(mirrored, to: 2) != nil)
    #expect(DocumentMigration.reverted(mirrored, to: 1) == nil)
}

@Test func touchesAddedFieldsFrom2() throws {
    let block = try JSONValue(
        encoding: PrivacyBlock(
            id: "p-00000001", take: "take-001", start: ns(1), end: ns(2), effect: .blur, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)))
    let layout = try JSONValue(
        encoding: LayoutBlock(id: "l-00000001", take: "take-001", start: ns(1), end: ns(2), kind: .screenOnly, instant: false))
    // The objects of the design example in version 2, and the same changed: what a line of 1c writes.
    let v2 = try parsed(DesignExample.canonical)
    func whole(_ pointer: String, _ change: (inout JSONValue) -> Void) throws -> EditChange {
        let before = try #require(v2.at(pointer))
        var after = before
        change(&after)
        return .set(path: try JSONPointer(pointer), before: before, after: after)
    }
    let cases: [(EditChange, Bool)] = [
        (try set(""), true),
        (try set("/documentVersion"), true),
        (try set("/captions"), true),
        (try set("/captions/show"), true),
        (try set("/captions/style/highlightColor"), true),
        (try set("/keys/mode"), true),
        (try set("/style/reframe"), true),
        (try set("/camera/background"), true),
        (try set("/camera/look/intensity"), true),
        (try set("/camera/syncOffset"), true),
        (try set("/audio/normalize"), true),
        (try set("/audio/tracks/take-001~1mic/cleanup"), true),
        (.insert(collection: try JSONPointer("/privacy/blocks"), index: 0, value: block), true),
        // A whole object that holds what the migration adds is carried through it: "Apply a Style" (`/style`), a track's
        // volume (`/audio/tracks/<track>`, or `/audio/tracks` for one without an entry), the whole camera or sound.
        (try whole("/style") { $0["padding"] = .number(0.1) }, false),
        (try whole("/camera") { $0["mirror"] = .bool(true) }, false),
        (try whole("/audio") { $0["limiter"] = .bool(false) }, false),
        (try whole("/audio/tracks") { $0["take-002/mic"] = .object(["gain": .integer(1), "muted": .bool(false)]) }, false),
        (try whole("/audio/tracks/take-001~1mic") { $0["gain"] = .number(0.5) }, false),
        // Unless the migration cannot write in its values: not objects, or the place there with another value.
        (try set("/style"), true),
        (try set("/audio/tracks/take-001~1mic"), true),
        (try whole("/style") { $0["reframe"] = .string("followCursor") }, true),
        (try set("/style/padding"), false),
        (try set("/style/frame"), false),
        (try set("/camera/mirror"), false),
        (try set("/camera/show"), false),
        (.insert(collection: try JSONPointer("/camera/layouts"), index: 0, value: layout), false),
        (try set("/audio/tracks/take-001~1mic/gain"), false),
        (try set("/audio/tracks/take-001~1mic/muted"), false),
        (try set("/audio/limiter"), false),
        (try set("/captionsAndMore"), false),
        (try set("/zoom/show"), false),
        (try set("/aspect"), false),
    ]
    for (change, touches) in cases {
        #expect(DocumentMigration.touchesAddedFields(change, from: 2) == touches, "\(change)")
        #expect(DocumentMigration.touchesAddedFields(change.inverse, from: 2) == touches, "\(change)")
        // Nothing is known to commute with a migration that is not additive.
        #expect(DocumentMigration.touchesAddedFields(change, from: 3), "\(change)")
    }
    // From 1, the same rule with its own places.
    #expect(DocumentMigration.touchesAddedFields(try set("/camera/mirror"), from: 1))
    #expect(!DocumentMigration.touchesAddedFields(try set("/camera/background"), from: 1))
    #expect(!DocumentMigration.touchesAddedFields(try set("/captions/show"), from: 1))
}

@Test func carriedGivesTheValuesWhatTheMigrationAdds() throws {
    let v2 = try parsed(DesignExample.canonical)
    let v3 = try DocumentMigration.migrate(v2, from: 2)
    // A track's volume, as 1c writes it: its `TrackGain` whole, without `cleanup`.
    let track = try #require(v2.at("/audio/tracks/take-001~1mic"))
    var quieter = track
    quieter["gain"] = .number(0.5)
    let volume = EditChange.set(path: try JSONPointer("/audio/tracks/take-001~1mic"), before: track, after: quieter)
    let carried = try #require(DocumentMigration.carried(volume, from: 2))
    var carriedTrack = track, carriedQuieter = quieter
    carriedTrack["cleanup"] = .integer(0)
    carriedQuieter["cleanup"] = .integer(0)
    #expect(carried == .set(path: try JSONPointer("/audio/tracks/take-001~1mic"), before: carriedTrack, after: carriedQuieter))
    // Applied after the migration, it gives the migration of applying it before; and its inverse undoes it there.
    let after = try v3.applying([carried])
    #expect(after == (try DocumentMigration.migrate(v2.applying([volume]), from: 2)))
    #expect(try after.applying([carried.inverse]) == v3)
    // The whole `style` gains `reframe`; the whole tracks, a `cleanup` in each; `null` (a member not there) stays.
    let style = try #require(v2.at("/style"))
    let style3 = try #require(v3.at("/style"))
    let styleChange = EditChange.set(path: try JSONPointer("/style"), before: style, after: style)
    #expect(DocumentMigration.carried(styleChange, from: 2) == .set(path: try JSONPointer("/style"), before: style3, after: style3))
    let added = EditChange.set(path: try JSONPointer("/audio/tracks/take-002~1mic"), before: .null, after: track)
    #expect(DocumentMigration.carried(added, from: 2) == .set(path: try JSONPointer("/audio/tracks/take-002~1mic"), before: .null, after: carriedTrack))
    let tracks = try #require(v2.at("/audio/tracks"))
    let tracks3 = try #require(v3.at("/audio/tracks"))
    let allTracks = EditChange.set(path: try JSONPointer("/audio/tracks"), before: tracks, after: .object([:]))
    #expect(DocumentMigration.carried(allTracks, from: 2) == .set(path: try JSONPointer("/audio/tracks"), before: tracks3, after: .object([:])))
    // What the migration does not reach is as it was.
    let padding = EditChange.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))
    #expect(DocumentMigration.carried(padding, from: 2) == padding)
    #expect(DocumentMigration.carried([padding, volume], from: 2, to: 2) == [padding, volume])
    #expect(DocumentMigration.carried([padding, volume], from: 2, to: 3) == [padding, carried])
    #expect(DocumentMigration.carried([padding], from: 3, to: 2) == nil)
    #expect(DocumentMigration.carried(padding, from: 3) == nil)

    // From 1 through both: the whole camera of 1b gains the camera's fields of 1c and of phase 2.
    let v1 = try parsed(DocumentV1Example.canonical)
    let camera = try #require(v1.at("/camera"))
    var hidden = camera
    hidden["show"] = .bool(false)
    let wholeCamera = EditChange.set(path: try JSONPointer("/camera"), before: camera, after: hidden)
    let throughBoth = try #require(DocumentMigration.carried([wholeCamera], from: 1, to: 3))
    let migrated = try DocumentMigration.migrate(DocumentMigration.migrate(v1, from: 1), from: 2)
    #expect(try migrated.applying(throughBoth) == (try DocumentMigration.migrate(DocumentMigration.migrate(v1.applying([wholeCamera]), from: 1), from: 2)))
}

// MARK: - The replay goes through the migrate to 3

@Test func replayGoesThroughTheMigrateFrom2() throws {
    let app = AppInfo(name: "Toma", version: "0.3.0")
    let date = Date(timeIntervalSince1970: 1_794_773_523)
    let create = EditLogEntry.create(seq: 1, document: DesignExample.document, app: app)
    let padding = EditLogEntry.do(
        seq: 2, group: 2, label: "style.padding",
        changes: [.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))], at: date)
    let captions = EditLogEntry.do(
        seq: 4, group: 4, label: "captions.show", changes: [.set(path: try JSONPointer("/captions/show"), before: .bool(false), after: .bool(true))],
        at: date)
    let entries = [create, padding, .migrate(seq: 3, from: 2, to: 3), captions]
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data(try entries.map { try $0.jsonLine(writingDocumentAt: 2) + "\n" }.joined().utf8).write(to: url)
        let read = try EditLogReader.read(url)
        #expect(read.createVersion == 2)
        #expect(read.entries == entries)
        let replayed = try #require(EditReplay.replay(snapshot: nil, entries: read.entries, createVersion: 2))
        #expect(replayed.mismatchSeq == nil)
        #expect(replayed.version == 3)
        #expect(replayed.document.style.padding == 0.1)
        #expect(replayed.document.captions.show)
        #expect(replayed.json == (try JSONValue(encoding: replayed.document)))
        // Before the migrate, the JSON stays in version 2.
        let before = try #require(EditReplay.replay(snapshot: nil, entries: Array(read.entries.prefix(2)), createVersion: 2))
        #expect(before.version == 2)
        #expect(before.json["documentVersion"] == .integer(2))
        #expect(before.json["captions"] == nil)
        #expect(DocumentMigration.reverted(try JSONValue(encoding: before.document), to: 2) == before.json)
    }
    // A line of version 2 that writes what version 3 adds is refused, whether a migrate follows or not.
    let early = EditLogEntry.do(
        seq: 2, group: 2, label: "captions.show",
        changes: [.set(path: try JSONPointer("/captions"), before: .null, after: .object(["show": .bool(true)]))], at: date)
    for lines in [[create, early], [create, early, .migrate(seq: 3, from: 2, to: 3)]] {
        let replayed = try #require(EditReplay.replay(snapshot: nil, entries: lines, createVersion: 2))
        #expect(replayed.mismatchSeq == 2)
        #expect(replayed.version == 2)
    }
    // From a create of version 1, both migrates in turn.
    let chained = [create, padding, .migrate(seq: 3, from: 1, to: 2), .migrate(seq: 4, from: 2, to: 3), captions.renumbered(5)]
    let fromV1 = try #require(EditReplay.replay(snapshot: nil, entries: chained, createVersion: 1))
    #expect(fromV1.mismatchSeq == nil)
    #expect(fromV1.version == 3)
    #expect(fromV1.document.captions.show && fromV1.document.style.padding == 0.1)
    // Skipping one is not following.
    let skipping = [create, padding, .migrate(seq: 3, from: 1, to: 3), captions]
    #expect(try #require(EditReplay.replay(snapshot: nil, entries: skipping, createVersion: 1)).mismatchSeq == 3)
}

extension EditLogEntry {
    /// This `do` line with another `seq`, which is its group too.
    fileprivate func renumbered(_ seq: Int) -> EditLogEntry {
        guard case let .do(_, _, label, changes, at) = self else { return self }
        return .do(seq: seq, group: seq, label: label, changes: changes, at: at)
    }
}
