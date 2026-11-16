// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the editor uses only the public API.
import ProjectFormat

private let app = AppInfo(name: "Toma", version: "0.2.0")

/// 2026-11-15T20:12:03Z, the date of the example of design §6.3.
private let date = Date(timeIntervalSince1970: 1_794_773_523)

/// What milestone 1b's `EditDocument.currentVersion` was: its reader refuses a document, or a `migrate`, past it.
private let versionOf1b = 1

/// The document of a 1b project: the design example, which version 1 holds.
private let legacy = DesignExample.document

private func set(_ path: String, _ before: JSONValue, _ after: JSONValue) throws -> EditChange {
    .set(path: try JSONPointer(path), before: before, after: after)
}

private let create = EditLogEntry.create(seq: 1, document: legacy, app: app)

/// The step of 1b every log here has: the padding from 0.08 to 0.1.
private func padding(_ seq: Int) throws -> EditLogEntry {
    .do(seq: seq, group: seq, label: "style.padding", changes: [try set("/style/padding", .number(0.08), .number(0.1))], at: date)
}

/// A step only version 2 has a place for: the camera mirrored.
private func mirror(_ seq: Int) throws -> EditLogEntry {
    .do(seq: seq, group: seq, label: "camera", changes: [try set("/camera/mirror", .bool(false), .bool(true))], at: date)
}

/// `entries` as their lines, each with its line break, the `create` written at `createVersion`.
private func text(_ entries: [EditLogEntry], createVersion: Int) throws -> String {
    try entries.map { try $0.jsonLine(writingDocumentAt: createVersion) + "\n" }.joined()
}

/// `entries` written to `url`, the `create` at `createVersion`, and read back.
private func written(_ entries: [EditLogEntry], to url: URL, createVersion: Int = 1) throws -> EditLogRead {
    try Data(text(entries, createVersion: createVersion).utf8).write(to: url)
    return try EditLogReader.read(url)
}

/// The replay of a log as it was read: from its `create`, at the version it is written in.
private func replay(_ read: EditLogRead) throws -> EditReplay {
    let createVersion = try #require(read.createVersion)
    return try #require(EditReplay.replay(snapshot: nil, entries: read.entries, createVersion: createVersion))
}

private func replay(_ entries: [EditLogEntry], createVersion: Int) throws -> EditReplay {
    try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: createVersion))
}

/// `document` as it is after the line `seq` of the log.
private func at(_ seq: Int, _ document: EditDocument) -> EditDocument {
    var document = document
    document.logSequence = seq
    return document
}

extension JSONValue {
    /// The member `key` of an object.
    fileprivate func member(_ key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }
}

// MARK: - The replay goes through an additive migrate

@Test func additiveMigrateIsReplayedInPlace() throws {
    try withTemporaryDirectory { dir in
        let entries = [create, try padding(2), .migrate(seq: 3, from: 1, to: 2), try mirror(4)]
        let read = try written(entries, to: dir.appending(path: "edit-log.jsonl"))
        #expect(read.createVersion == 1)
        #expect(read.entries == entries)
        #expect(!read.droppedTrailingMigrate)

        let replayed = try replay(read)
        #expect(replayed.mismatchSeq == nil)
        #expect(replayed.lastAppliedSeq == 4)
        #expect(replayed.version == 2)
        #expect(replayed.document.documentVersion == 2)
        #expect(replayed.document.style.padding == 0.1)
        #expect(replayed.document.camera.mirror)
        var expected = legacy
        expected.style.padding = 0.1
        expected.camera.mirror = true
        #expect(replayed.document == at(4, expected))
        // In version 2 the state on disk is the document's own.
        #expect(replayed.json == (try JSONValue(encoding: replayed.document)))

        // From a snapshot before the migrate, written in version 1, and from one after it, in version 2: the same.
        var padded = legacy
        padded.style.padding = 0.1
        let fromV1 = try #require(
            EditReplay.replay(snapshot: at(2, padded), snapshotVersion: 1, entries: read.entries, createVersion: 1))
        #expect(fromV1.mismatchSeq == nil)
        #expect(fromV1.version == 2)
        #expect(fromV1.document == replayed.document)
        #expect(fromV1.json == replayed.json)
        let fromV2 = try #require(
            EditReplay.replay(snapshot: at(3, padded), snapshotVersion: 2, entries: read.entries, createVersion: 1))
        #expect(fromV2.mismatchSeq == nil)
        #expect(fromV2.version == 2)
        #expect(fromV2.document == replayed.document)
    }
}

@Test func replayJSONStaysAtTheDiskVersion() throws {
    try withTemporaryDirectory { dir in
        let read = try written([create, try padding(2)], to: dir.appending(path: "edit-log.jsonl"))
        #expect(read.createVersion == 1)
        let replayed = try replay(read)
        #expect(replayed.mismatchSeq == nil)
        #expect(replayed.version == 1)
        #expect(replayed.json.member("documentVersion") == .integer(1))
        let camera = try #require(replayed.json.member("camera"))
        #expect(camera.member("layout") == nil)
        for key in DocumentMigration.addedCameraFields {
            #expect(camera.member(key) == nil, "\(key)")
        }
        #expect(camera.member("show") == .bool(true))
        #expect(replayed.json.member("style")?.member("padding") == .number(0.1))
        #expect(replayed.json.member("logSequence") == .integer(2))
        // The document is always of the current version.
        #expect(replayed.document.documentVersion == 2)
        #expect(replayed.document.style.padding == 0.1)

        // A log written in version 2 stays there.
        let current = try written([create, try padding(2)], to: dir.appending(path: "v2.jsonl"), createVersion: 2)
        #expect(current.createVersion == 2)
        let replayedV2 = try replay(current)
        #expect(replayedV2.version == 2)
        #expect(replayedV2.document == replayed.document)
        #expect(replayedV2.json == (try JSONValue(encoding: replayedV2.document)))

        // Lines that change nothing replayable leave the create's own JSON, at its line.
        let alone = try replay([create], createVersion: 1)
        #expect(alone.version == 1)
        #expect(alone.json == DocumentMigration.reverted(try JSONValue(encoding: at(1, legacy)), to: 1))
    }
}

@Test func revertedIsTheReplayedJSON() throws {
    try withTemporaryDirectory { dir in
        let read = try written([create, try padding(2)], to: dir.appending(path: "edit-log.jsonl"))
        let replayed = try replay(read)
        #expect(DocumentMigration.reverted(try JSONValue(encoding: replayed.document), to: 1) == replayed.json)

        // And in version 2, after the migrate.
        let migrated = try replay([create, try padding(2), .migrate(seq: 3, from: 1, to: 2), try mirror(4)], createVersion: 1)
        #expect(DocumentMigration.reverted(try JSONValue(encoding: migrated.document), to: 2) == migrated.json)
        #expect(DocumentMigration.reverted(migrated.json, to: 1) == nil, "the camera is mirrored: version 1 can't hold it")
    }
}

@Test func migrateThatDoesNotFollowStops() throws {
    try withTemporaryDirectory { dir in
        // A create written in version 2 and a migrate from 1: the replay stops there, as in 1b.
        let entries = [create, try padding(2), .migrate(seq: 3, from: 1, to: 2), try padding(4)]
        let read = try written(entries, to: dir.appending(path: "edit-log.jsonl"), createVersion: 2)
        #expect(read.createVersion == 2)
        #expect(read.entries == entries)
        let replayed = try replay(read)
        #expect(replayed.mismatchSeq == 3)
        #expect(replayed.lastAppliedSeq == 2)
        #expect(replayed.version == 2)
        #expect(replayed.document.style.padding == 0.1)
    }
    // From a create in version 1, every migrate that is not the next version from the one the document is at.
    let migrate = EditLogEntry.migrate(seq: 3, from: 1, to: 2)
    let cases: [(String, [EditLogEntry], Int, Int)] = [
        ("to the same version", [create, try padding(2), .migrate(seq: 3, from: 1, to: 1), try mirror(4)], 3, 1),
        ("from another version", [create, try padding(2), .migrate(seq: 3, from: 0, to: 1), try mirror(4)], 3, 1),
        ("skipping a version", [create, try padding(2), .migrate(seq: 3, from: 1, to: 3), try mirror(4)], 3, 1),
        ("the same one twice", [create, try padding(2), migrate, .migrate(seq: 4, from: 1, to: 2), try mirror(5)], 4, 2),
        ("one this app has no migration for", [create, try padding(2), migrate, .migrate(seq: 4, from: 2, to: 3), try mirror(5)], 4, 2),
    ]
    for (name, entries, mismatch, version) in cases {
        let replayed = try replay(entries, createVersion: 1)
        #expect(replayed.mismatchSeq == mismatch, "\(name)")
        #expect(replayed.lastAppliedSeq == mismatch - 1, "\(name)")
        #expect(replayed.version == version, "\(name)")
        #expect(replayed.document.style.padding == 0.1, "\(name)")
        #expect(!replayed.document.camera.mirror, "\(name)")
    }
    // A snapshot already in version 2 before the migrate is not the state the migrate goes from.
    var padded = legacy
    padded.style.padding = 0.1
    let mixed = try #require(
        EditReplay.replay(
            snapshot: at(2, padded), snapshotVersion: 2, entries: [create, try padding(2), migrate, try mirror(4)], createVersion: 1))
    #expect(mixed.mismatchSeq == 3)
    #expect(mixed.version == 2)
}

// MARK: - A migrate alone at the end is the first edit cut short

@Test func trailingMigrateIsDroppedOnReadAndTruncated() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let head = [create, try padding(2)]
        let headText = try text(head, createVersion: 1)
        let migrate = try EditLogEntry.migrate(seq: 3, from: 1, to: 2).jsonLine()
        let chainEnd = try EditLogEntry.migrate(seq: 4, from: 2, to: 2).jsonLine()
        let step = try mirror(4).jsonLine()
        // The migrate as the last line, with and without its line break, followed by a line cut short or by a damaged
        // one, and two of them: never kept as the last entry.
        let tails: [(String, String, damaged: Int?, cut: Bool)] = [
            ("alone", migrate + "\n", nil, false),
            ("without its line break", migrate, nil, false),
            ("before a step cut short", migrate + "\n" + step.prefix(40), nil, true),
            ("before a damaged line", migrate + "\nnot json\n", 3, false),
            ("two of them", migrate + "\n" + chainEnd + "\n", nil, false),
        ]
        for (name, tail, damaged, cut) in tails {
            try Data((headText + tail).utf8).write(to: url)
            let read = try EditLogReader.read(url)
            #expect(read.entries == head, "\(name)")
            #expect(read.droppedTrailingMigrate, "\(name)")
            #expect(read.droppedTruncatedTail == cut, "\(name)")
            #expect(read.damagedLine == damaged, "\(name)")
            #expect(read.createVersion == 1, "\(name)")
            let replayed = try replay(read)
            #expect(replayed.version == 1, "\(name)")
            #expect(replayed.lastAppliedSeq == 2, "\(name)")
            guard damaged == nil else { continue }
            // Opened to edit, the file ends at the line before.
            #expect(try EditLogReader.truncateIncompleteTail(url), "\(name)")
            #expect(try SafeRead.regularFile(at: url) == Data(headText.utf8), "\(name)")
            #expect(try EditLogReader.truncateIncompleteTail(url) == false, "\(name)")
            #expect(try !EditLogReader.read(url).droppedTrailingMigrate, "\(name)")
        }

        // A migrate followed by a step is a line like any other.
        let whole = headText + migrate + "\n" + step + "\n"
        try Data(whole.utf8).write(to: url)
        let read = try EditLogReader.read(url)
        #expect(read.entries.count == 4)
        #expect(!read.droppedTrailingMigrate)
        #expect(try EditLogReader.truncateIncompleteTail(url) == false)
        #expect(try SafeRead.regularFile(at: url) == Data(whole.utf8))

        // A log of a create alone keeps it.
        try Data(try text([create], createVersion: 1).utf8).write(to: url)
        #expect(try EditLogReader.truncateIncompleteTail(url) == false)
        #expect(try EditLogReader.read(url).entries == [create])
    }
}

@Test func cutAtEveryByteOfTheFirstEditOpensBeforeOrAfter() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        // A 1b project with one step of 1b, and the first edit in 1c: its migrate and its step, in one buffer.
        let head = Array(try text([create, try padding(2)], createVersion: 1).utf8)
        let migrateLine = Array(try EditLogEntry.migrate(seq: 3, from: 1, to: 2).jsonLine().utf8)
        let firstEdit = [EditLogEntry.migrate(seq: 3, from: 1, to: 2), try mirror(4)]
        let buffer = Array(try text(firstEdit, createVersion: 1).utf8)
        let before = try replay([create, try padding(2)], createVersion: 1)
        let after = try replay([create, try padding(2)] + firstEdit, createVersion: 1)
        #expect(before.version == 1)
        #expect(after.version == 2)
        #expect(after.document.camera.mirror)

        for length in 0...buffer.count {
            try Data(head + buffer.prefix(length)).write(to: url)
            let read = try EditLogReader.read(url)
            // The step is whole once all but its line break is there.
            let whole = length >= buffer.count - 1
            let migrateWhole = length >= migrateLine.count
            #expect(read.damagedLine == nil, "cut at \(length)")
            #expect(read.droppedTrailingMigrate == (migrateWhole && !whole), "cut at \(length)")
            // Never the migrate without its step.
            #expect(read.entries.count == (whole ? 4 : 2), "cut at \(length)")
            let replayed = try replay(read)
            #expect(replayed.mismatchSeq == nil, "cut at \(length)")
            #expect(replayed.version == (whole ? 2 : 1), "cut at \(length)")
            #expect(replayed.document == (whole ? after.document : before.document), "cut at \(length)")
            #expect(replayed.json == (whole ? after.json : before.json), "cut at \(length)")

            // Opened to edit: the file ends at the line before the first edit, or after it.
            #expect(try EditLogReader.truncateIncompleteTail(url) == (length > 0 && length < buffer.count), "cut at \(length)")
            #expect(try SafeRead.regularFile(at: url) == Data(head + (whole ? buffer : [])), "cut at \(length)")
            #expect(try EditLogReader.read(url).entries == read.entries, "cut at \(length)")
        }
    }
}

@Test func a1bReaderWouldRefuseTheMigratedLog() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        // Before the first edit in 1c, the log and the snapshot from its state on disk are of version 1, which 1b opens.
        let before = try written([create, try padding(2)], to: url)
        #expect(!before.entries.contains { if case .migrate = $0 { true } else { false } })
        let snapshotBefore = try ProjectJSON.encoder().encode(try replay(before).json)
        #expect(EditDocument.writtenVersion(of: snapshotBefore) == versionOf1b)

        // After it, a snapshot of version 2 and a migrate to 2: 1b refuses both as written by a newer app.
        let read = try written([create, try padding(2), .migrate(seq: 3, from: 1, to: 2), try mirror(4)], to: url)
        let replayed = try replay(read)
        let snapshot = try ProjectJSON.encoder().encode(replayed.json)
        #expect(EditDocument.writtenVersion(of: snapshot) == 2)
        #expect(try EditDocument.decode(snapshot) == replayed.document)
        #expect(read.entries.contains { if case let .migrate(_, _, to) = $0 { to == 2 && to > versionOf1b } else { false } })
    }
}

// MARK: - Lines written at a version

@Test func createIsWrittenAtTheVersionAsked() throws {
    // At the current version, the line `jsonLine()` writes; in version 1, the document as 1b wrote it.
    #expect(try create.jsonLine(writingDocumentAt: 2) == create.jsonLine())
    let v1 = try create.jsonLine(writingDocumentAt: 1)
    #expect(v1 != (try create.jsonLine()))
    #expect(v1.contains(#""documentVersion":1"#))
    #expect(!v1.contains(#""layouts""#))
    // The text of 1b design §6.2's example in version 1, compact, with the rules of the log's lines.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let v1Document = try JSONDecoder().decode(JSONValue.self, from: Data(DocumentV1Example.canonical.utf8))
    let asIn1b = #"{"app":{"name":"Toma","version":"0.2.0"},"document":"#
        + String(decoding: try encoder.encode(v1Document), as: UTF8.self) + #","seq":1,"type":"create"}"#
    #expect(v1 == asIn1b)
    // Read back, it is the same entry: the document migrated.
    #expect(try EditLogEntry(jsonLine: v1) == create)

    // A document that uses what version 2 adds has no version 1.
    var mirrored = legacy
    mirrored.camera.mirror = true
    let newer = EditLogEntry.create(seq: 1, document: mirrored, app: app)
    #expect(throws: (any Error).self) { try newer.jsonLine(writingDocumentAt: 1) }
    #expect(throws: (any Error).self) { try create.jsonLine(writingDocumentAt: 3) }

    // Every other line is written as it is.
    for entry in [try padding(2), .undo(seq: 3, group: 2), .redo(seq: 4, group: 2), .migrate(seq: 5, from: 1, to: 2)] {
        #expect(try entry.jsonLine(writingDocumentAt: 1) == entry.jsonLine())
    }
}
