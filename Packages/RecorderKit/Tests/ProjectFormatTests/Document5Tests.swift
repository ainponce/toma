// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// @testable for `ProjectJSON.compactEncoder()`, the encoder a `JSONValue` goes through.
@testable import ProjectFormat

private func parsed(_ text: String) throws -> JSONValue {
    try ProjectJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func compact(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.compactEncoder().encode(value), as: UTF8.self)
}

private func pretty(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.encoder().encode(value), as: UTF8.self)
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
}

/// `DocumentV4Example` with what version 5 adds away from its legacy value (fases 4 y 5 design §4.1): a title and a
/// summary, and automatic zooms that follow the keyboard's focus.
private enum DocumentV5Example {
    static let info = ProjectInfo(title: "Demo de Toma", summary: "Cómo grabar, editar y compartir.\nEn dos minutos.")

    static let document: EditDocument = {
        var document = DocumentV4Example.document
        document.info = info
        document.zoom.auto.followsFocus = true
        return document
    }()
}

// MARK: - The migration from 4

@Test func version4MigratesToVersion5() throws {
    // The example of phase 3, as phase 3 wrote it, read in version 5: nothing but `followsFocus` added, at `false`.
    let v4 = try parsed(DocumentV4Example.canonical)
    #expect(v4["documentVersion"] == .integer(4))
    #expect(EditDocument.currentVersion == 5)
    let document = try EditDocument.decode(Data(DocumentV4Example.canonical.utf8))
    #expect(document.documentVersion == 5)
    #expect(document.info == nil)
    #expect(document.zoom.auto.followsFocus == false)
    #expect(document == DocumentV4Example.document)
    #expect(try EditDocument.decode(json: v4) == document)
    #expect(EditDocument.writtenVersion(of: Data(DocumentV4Example.canonical.utf8)) == 4)
    // Reverted, the bytes phase 3 wrote.
    let back = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 4))
    #expect(back == v4)
    #expect(try pretty(back) == DocumentV4Example.canonical)
    #expect(DocumentMigration.oldestVersion(holding: document) == 4)
    // Inside the `create` of a log of phase 3.
    let line = #"{"app":{"name":"Toma","version":"0.5.0"},"document":"# + (try compact(v4)) + #","seq":1,"type":"create"}"#
    #expect(try EditLogEntry(jsonLine: line) == .create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.5.0")))

    // The row of the table: additive, one place, at its frozen value.
    #expect(DocumentMigration.isAdditive(from: 4))
    #expect(!DocumentMigration.isAdditive(from: 5))
    #expect(DocumentMigration.addedPlaces[4] == ["/zoom/auto/followsFocus"])
    #expect(DocumentMigration.addedPlaces.keys.sorted() == [1, 2, 3, 4])
    let migrated = try DocumentMigration.migrate(v4, from: 4)
    #expect(migrated == (try JSONValue(encoding: document)))
    // From 1, 2 and 3, every step up to 5, and back down.
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try parsed(DesignExample.canonical)
    let v3 = try parsed(DocumentV3Example.canonical)
    var fromV1 = v1
    for from in 1...4 { fromV1 = try DocumentMigration.migrate(fromV1, from: from) }
    #expect(fromV1 == (try JSONValue(encoding: DesignExample.document)))
    #expect(try EditDocument.decode(json: v1) == DesignExample.document)
    #expect(try EditDocument.decode(json: v2) == DesignExample.document)
    #expect(try EditDocument.decode(json: v3) == DocumentV3Example.document)
    #expect(DesignExample.document.documentVersion == 5)
    #expect(DocumentMigration.reverted(fromV1, to: 1) == v1)
    #expect(DocumentMigration.reverted(fromV1, to: 2) == v2)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: DocumentV3Example.document), to: 3) == v3)
    #expect(DocumentMigration.oldestVersion(holding: DesignExample.document) == 1)
}

@Test func migratedVersion4HasNoInfoAndNoFocus() throws {
    let v4 = try parsed(DocumentV4Example.canonical)
    let migrated = try DocumentMigration.migrate(v4, from: 4)
    #expect(migrated["documentVersion"] == .integer(5))
    #expect(migrated["zoom"]?["auto"]?["followsFocus"] == .bool(false))
    #expect(migrated["info"] == nil)
    // Nothing else.
    var rest = migrated
    rest["documentVersion"] = .integer(4)
    rest["zoom"]?["auto"]?["followsFocus"] = nil
    #expect(rest == v4)
    // What it writes is what a new document's legacy value encodes to, and the legacy document has no `info`.
    let legacy = try JSONValue(encoding: EditDocument.legacy(take: TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: []))
    #expect(legacy["zoom"]?["auto"]?["followsFocus"] == .bool(false))
    #expect(legacy["info"] == nil)
    #expect(!(try pretty(DesignExample.document)).contains("\"info\""))
    #expect(try pretty(DesignExample.document).contains("\"followsFocus\" : false"))

    // A `followsFocus` already there is overwritten, as every migration writes over what was there.
    var handWritten = v4
    handWritten["zoom"]?["auto"]?["followsFocus"] = .bool(true)
    #expect(try DocumentMigration.migrate(handWritten, from: 4) == migrated)
    // An `info` in a document of version 4 is what version 4 has no place for: damaged, never read as version 5.
    var withInfo = v4
    withInfo["info"] = .object(["summary": .string(""), "title": .string("Demo")])
    #expect(throws: EditChangeError.invalidDocument("/info")) { try DocumentMigration.migrate(withInfo, from: 4) }
    #expect(throws: DecodingError.self) { try EditDocument.decode(json: withInfo) }
    #expect(throws: DecodingError.self) { try EditDocument.decode(Data(compact(withInfo).utf8)) }
    // One without the objects it writes in does not migrate.
    var withoutAuto = v4
    withoutAuto["zoom"]?["auto"] = nil
    #expect(throws: EditChangeError.invalidDocument("/zoom/auto")) { try DocumentMigration.migrate(withoutAuto, from: 4) }
    var withoutZoom = v4
    withoutZoom["zoom"] = nil
    #expect(throws: EditChangeError.invalidDocument("/zoom")) { try DocumentMigration.migrate(withoutZoom, from: 4) }
    for (document, version) in [(v4, 3), (v4, 5), (migrated, 4), (migrated, 5)] {
        #expect(throws: EditChangeError.invalidDocument("/documentVersion"), "\(version)") {
            try DocumentMigration.migrate(document, from: version)
        }
    }

    // A document that uses what version 5 adds has no version 4, nor any older.
    let example = try JSONValue(encoding: DocumentV5Example.document)
    #expect(DocumentMigration.oldestVersion(holding: DocumentV5Example.document) == 5)
    var onlyInfo = migrated
    onlyInfo["info"] = .object(["summary": .string(""), "title": .string("Demo")])
    var onlyFocus = migrated
    onlyFocus["zoom"]?["auto"]?["followsFocus"] = .bool(true)
    var noFocus = migrated
    noFocus["zoom"]?["auto"]?["followsFocus"] = nil
    for (name, document) in [("example", example), ("info", onlyInfo), ("focus", onlyFocus), ("no focus", noFocus)] {
        for version in 1...4 {
            #expect(DocumentMigration.reverted(document, to: version) == nil, "\(name) \(version)")
        }
        #expect(DocumentMigration.reverted(document, to: 5) == document, "\(name)")
    }

    // What commutes with it: anything but `followsFocus` itself and above it; `/zoom/auto` whole gains it at `false`.
    let auto = try #require(v4["zoom"]?["auto"])
    var deeper = auto
    deeper["depth"] = .number(2.5)
    let wholeAuto = EditChange.set(path: try JSONPointer("/zoom/auto"), before: auto, after: deeper)
    var carriedAuto = deeper
    carriedAuto["followsFocus"] = .bool(false)
    var carriedBefore = auto
    carriedBefore["followsFocus"] = .bool(false)
    #expect(
        DocumentMigration.carried(wholeAuto, from: 4)
            == .set(path: try JSONPointer("/zoom/auto"), before: carriedBefore, after: carriedAuto))
    let padding = EditChange.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))
    #expect(DocumentMigration.carried(padding, from: 4) == padding)
    #expect(!DocumentMigration.touchesAddedFields(padding, from: 4))
    let focus = EditChange.set(path: try JSONPointer("/zoom/auto/followsFocus"), before: .bool(false), after: .bool(true))
    #expect(DocumentMigration.touchesAddedFields(focus, from: 4))
    let version = EditChange.set(path: try JSONPointer("/documentVersion"), before: .integer(4), after: .integer(5))
    #expect(DocumentMigration.touchesAddedFields(version, from: 4))
}

// MARK: - The document of version 5

@Test func version5ExampleRoundTrips() throws {
    let document = DocumentV5Example.document
    #expect(document.documentVersion == 5)
    let text = try pretty(document)
    #expect(try EditDocument.decode(Data(text.utf8)) == document)
    #expect(try EditDocument.decode(ProjectJSON.compactEncoder().encode(document)) == document)
    #expect(document.heldJSON() == (try JSONValue(encoding: document)))
    let create = EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.6.0"))
    #expect(try EditLogEntry(jsonLine: create.jsonLine()) == create)
    // `info` at its place in key order, `followsFocus` last of the automatic zoom's settings.
    #expect(try compact(DocumentV5Example.info) == #"{"summary":"Cómo grabar, editar y compartir.\nEn dos minutos.","title":"Demo de Toma"}"#)
    #expect(text.contains(#""frameRate" : 60,\#n  "info" : {\#n    "summary" : "#))
    #expect(try compact(document.zoom.auto).hasPrefix(#"{"depth":"#))
    #expect(try compact(document.zoom.auto).contains(#""follow":true,"followsFocus":true,"groupGap""#))
    // Its members, one at a time, through the JSON the editor applies changes to.
    let json = try #require(DesignExample.document.heldJSON())
    let setInfo = try #require(DesignExample.document.setChange("/info", DocumentV5Example.info))
    #expect(setInfo == .set(path: try JSONPointer("/info"), before: .null, after: try JSONValue(encoding: DocumentV5Example.info)))
    let fast = try DesignExample.document.applying([setInfo], json: json)
    #expect(fast.document.info == DocumentV5Example.info)
    #expect(fast.document == (try DesignExample.document.applying([setInfo])))
    #expect(fast.json == (try JSONValue(encoding: fast.document)))
    let removed = try fast.document.applying([setInfo.inverse], json: fast.json)
    #expect(removed.document == DesignExample.document)
    #expect(removed.json == json)
    // `followsFocus` is always written in a document: a change that takes it away is refused.
    let away = EditChange.set(path: try JSONPointer("/zoom/auto/followsFocus"), before: .bool(false), after: .null)
    #expect(throws: EditChangeError.invalidDocument("/zoom/auto/followsFocus")) { try DesignExample.document.applying([away]) }
    // Settings saved by phase 3 (`default-style.json`, a `.tomastyle`) have none, and read as `false`.
    var saved = try JSONValue(encoding: DefaultStyle.toma)
    #expect(saved["zoomAuto"]?["followsFocus"] == .bool(false))
    saved["zoomAuto"]?["followsFocus"] = nil
    #expect(try ProjectJSON.decoder().decode(DefaultStyle.self, from: Data(compact(saved).utf8)) == DefaultStyle.toma)
    #expect(DefaultStyle.toma.zoomAuto.followsFocus == false)
}

@Test func aVersionNewerThan5IsRefused() throws {
    #expect(throws: EditDocumentError.newerVersion(6)) {
        try EditDocument.decode(Data(#"{"documentVersion":6,"aspect":"4:3"}"#.utf8))
    }
    var newer = try JSONValue(encoding: DocumentV5Example.document)
    newer["documentVersion"] = .integer(6)
    #expect(throws: EditDocumentError.newerVersion(6)) { try EditDocument.decode(json: newer) }
    let line = #"{"app":{"name":"Toma","version":"0.7.0"},"document":"# + (try compact(newer)) + #","seq":1,"type":"create"}"#
    #expect(throws: EditDocumentError.newerVersion(6)) { try EditLogEntry(jsonLine: line) }
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let create = EditLogEntry.create(seq: 1, document: DocumentV5Example.document, app: AppInfo(name: "Toma", version: "0.6.0"))
        try Data((try create.jsonLine() + "\n" + EditLogEntry.migrate(seq: 2, from: 5, to: 6).jsonLine() + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(6)) { try EditLogReader.read(url) }
        // A `migrate` to 5 is one this app follows.
        let v4 = EditLogEntry.create(seq: 1, document: DocumentV4Example.document, app: AppInfo(name: "Toma", version: "0.5.0"))
        try Data((try v4.jsonLine(writingDocumentAt: 4) + "\n" + EditLogEntry.migrate(seq: 2, from: 4, to: 5).jsonLine() + "\n").utf8)
            .write(to: url)
        #expect(try EditLogReader.read(url).createVersion == 4)
    }
}

@Test func infoLimitsAreProblems() throws {
    #expect(ProjectInfo.titleLimit == 200)
    #expect(ProjectInfo.summaryLimit == 2000)
    var document = DesignExample.document
    #expect(DocumentRules.problems(in: document).isEmpty)
    // At the limits, in characters: an emoji of several scalars is one.
    document.info = ProjectInfo(title: String(repeating: "a", count: 200), summary: String(repeating: "b", count: 2000))
    #expect(DocumentRules.problems(in: document).isEmpty)
    document.info = ProjectInfo(title: String(repeating: "👩🏽‍💻", count: 200), summary: "")
    #expect(DocumentRules.problems(in: document).isEmpty)
    document.info = ProjectInfo(title: String(repeating: "a", count: 201), summary: "")
    #expect(DocumentRules.problems(in: document) == [.infoTooLong(field: "title")])
    document.info = ProjectInfo(title: "", summary: String(repeating: "b", count: 2001))
    #expect(DocumentRules.problems(in: document) == [.infoTooLong(field: "summary")])
    document.info = ProjectInfo(title: String(repeating: "a", count: 201), summary: String(repeating: "b", count: 2001))
    #expect(DocumentRules.problems(in: document) == [.infoTooLong(field: "title"), .infoTooLong(field: "summary")])
    // It still decodes: a rule beyond the decoding, as the others of phase 3.
    #expect(try EditDocument.decode(ProjectJSON.encoder().encode(document)) == document)
}

// MARK: - The `focus` event

@Test func focusEventRoundTripsAndOldKindsStay() throws {
    let caret = InputEvent(t: HostTime(nanoseconds: 5), kind: .focus(x: 640.5, y: -40, width: 2, height: 18, kind: .caret))
    let caretLine = #"{"height":18,"kind":"caret","t":5,"type":"focus","width":2,"x":640.5,"y":-40}"#
    #expect(try caret.jsonLine() == caretLine)
    #expect(try InputEvent(jsonLine: caretLine) == caret)
    let element = InputEvent(t: HostTime(nanoseconds: 6), kind: .focus(x: 100, y: 80, width: 320.25, height: 24, kind: .element))
    let elementLine = #"{"height":24,"kind":"element","t":6,"type":"focus","width":320.25,"x":100,"y":80}"#
    #expect(try element.jsonLine() == elementLine)
    #expect(try InputEvent(jsonLine: elementLine) == element)
    #expect(FocusKind.allCases == [.element, .caret])
    // Additive: never a reason to raise the package, and never a pointer position.
    #expect(!caret.kind.requiresFormatVersion4)
    #expect(caret.kind.pointerPosition == nil)
    // A field missing or a `kind` this version does not know: not a focus this version wrote.
    for line in [
        #"{"height":18,"kind":"selection","t":5,"type":"focus","width":2,"x":1,"y":2}"#,
        #"{"height":18,"t":5,"type":"focus","width":2,"x":1,"y":2}"#,
        #"{"kind":"caret","t":5,"type":"focus","width":2,"x":1,"y":2}"#,
        #"{"height":18,"kind":"caret","t":5,"type":"focus","x":1,"y":2}"#,
    ] {
        #expect(throws: DecodingError.self, "\(line)") { try InputEvent(jsonLine: line) }
    }

    // The kinds of before give the same bytes, and read back the same.
    let old = InputEvent.documentedExamples.filter { if case .focus = $0.0.kind { false } else { true } }
    let types = Set(try old.map { example -> String in
        let object = try JSONSerialization.jsonObject(with: Data(example.1.utf8)) as? [String: Any]
        return try #require(object?["type"] as? String)
    })
    #expect(types.count == 18)
    #expect(!types.contains("focus"))
    for (event, line) in old {
        #expect(try event.jsonLine() == line)
        #expect(try InputEvent(jsonLine: line) == event)
    }

    try withTemporaryDirectory { dir in
        // This reader reads it among the others.
        let url = dir.appending(path: "events.jsonl")
        let events = [InputEvent(t: HostTime(nanoseconds: 4), kind: .marker), caret, element, InputEvent(t: HostTime(nanoseconds: 7), kind: .keyActivity)]
        let writer = try EventLogWriter(url: url)
        for event in events { writer.append(event) }
        try writer.close()
        let read = try EventLogReader.read(url)
        #expect(read.events == events)
        #expect(read.skippedLines == 0)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(caretLine + "\n" + elementLine + "\n"))
        // A reader whose kinds have no `focus`, as phase 3's, skips those lines and reads the rest: a type it does not
        // know is a line it counts in `skippedLines`, as this one does with a type of a later version.
        let later = dir.appending(path: "later.jsonl")
        let laterLine = #"{"height":18,"kind":"caret","t":5,"type":"focusLater","width":2,"x":640.5,"y":-40}"#
        try Data(([try events[0].jsonLine(), laterLine, try events[3].jsonLine()].map { $0 + "\n" }.joined()).utf8).write(to: later)
        let skipped = try EventLogReader.read(later)
        #expect(skipped.events == [events[0], events[3]])
        #expect(skipped.skippedLines == 1)
        #expect(!skipped.droppedTruncatedTail)
    }
}

// MARK: - The `rotated` end of a segment

@Test func rotatedRoundTrips() throws {
    let rotated = SegmentEndReason.rotated
    #expect(try compact(rotated) == #"{"type":"rotated"}"#)
    #expect(try ProjectJSON.decoder().decode(SegmentEndReason.self, from: Data(#"{"type":"rotated"}"#.utf8)) == .rotated)
    let segment = SegmentRecord(
        index: 3, file: "takes/take-001/display-1/seg-0003.mov", startHostTime: HostTime(nanoseconds: 10_000_000_000),
        endHostTime: HostTime(nanoseconds: 20_000_000_000), endReason: .rotated, droppedFrames: 0, heartbeatFrames: 2)
    let data = try ProjectJSON.encoder().encode(segment)
    #expect(String(decoding: data, as: UTF8.self).contains(#""endReason" : {\#n    "type" : "rotated"\#n  }"#))
    #expect(try ProjectJSON.decoder().decode(SegmentRecord.self, from: data) == segment)
    // The reasons of before keep their bytes.
    let before: [(SegmentEndReason, String)] = [
        (.stopped, #"{"type":"stopped"}"#), (.paused, #"{"type":"paused"}"#),
        (.streamError(domain: "SCStreamErrorDomain", code: -3821), #"{"code":-3821,"domain":"SCStreamErrorDomain","type":"streamError"}"#),
        (.writerError(domain: "AVFoundationErrorDomain", code: -11800), #"{"code":-11800,"domain":"AVFoundationErrorDomain","type":"writerError"}"#),
        (.formatChanged, #"{"type":"formatChanged"}"#), (.diskFull, #"{"type":"diskFull"}"#),
        (.recoveredAfterCrash, #"{"type":"recoveredAfterCrash"}"#), (.empty, #"{"type":"empty"}"#),
        (.unreadable(bytes: 2_097_152), #"{"bytes":2097152,"type":"unreadable"}"#),
    ]
    for (reason, text) in before {
        #expect(try compact(reason) == text)
        #expect(try ProjectJSON.decoder().decode(SegmentEndReason.self, from: Data(text.utf8)) == reason)
        #expect(reason != rotated)
    }
}
