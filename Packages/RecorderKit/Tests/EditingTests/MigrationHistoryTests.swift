// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the session uses only the public API.
import Editing
import ProjectFormat

/// 2026-11-15T20:12:03Z, the date of the example of design §6.3.
private let date = Date(timeIntervalSince1970: 1_794_773_523)

private func set(_ path: String, _ before: JSONValue, _ after: JSONValue) throws -> EditChange {
    .set(path: try JSONPointer(path), before: before, after: after)
}

/// The padding of `SmallDocument` from 0.08 to 0.1, a step of 1b.
private func padding(_ seq: Int, group: Int? = nil) throws -> EditLogEntry {
    .do(
        seq: seq, group: group ?? seq, label: EditLabel.padding.rawValue,
        changes: [try set("/style/padding", .number(0.08), .number(0.1))], at: date)
}

/// The camera mirrored, a step only version 2 has a place for.
private func mirror(_ seq: Int) throws -> EditLogEntry {
    .do(seq: seq, group: seq, label: EditLabel.camera.rawValue, changes: [try set("/camera/mirror", .bool(false), .bool(true))], at: date)
}

private func replay(_ entries: [EditLogEntry], createVersion: Int = 1) throws -> EditReplay {
    try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: createVersion))
}

private func at(_ seq: Int, _ document: EditDocument) -> EditDocument {
    var document = document
    document.logSequence = seq
    return document
}

// MARK: - Undo and redo cross an additive migrate

@Test func undoCrossesAnAdditiveMigrate() throws {
    // A 1b project (its create in version 1) with a step of 1b, and a step of 1c after its first edit's migrate.
    let log = [SmallDocument.create, try padding(2), .migrate(seq: 3, from: 1, to: 2), try mirror(4)]
    var history = UndoHistory(entries: log, createVersion: 1)
    #expect(history.done == [2, 4])
    #expect(history.undone == [])
    #expect(history.undoLabel == .camera)
    #expect(history.nextSeq == 5)

    let undos: [EditLogEntry] = [.undo(seq: 5, group: 4), .undo(seq: 6, group: 2)]
    for undo in undos {
        history.record(undo)
    }
    #expect(history.done == [])
    #expect(history.undone == [4, 2])
    #expect(history.redoLabel == .padding)

    // The undo of the step of 1b applies its inverse to the document of version 2: the padding and the camera of before,
    // never "unmigrated".
    let undone = try replay(log + undos)
    #expect(undone.mismatchSeq == nil)
    #expect(undone.version == 2)
    #expect(undone.document == at(6, SmallDocument.document))
    #expect(DocumentMigration.reverted(try JSONValue(encoding: undone.document), to: 2) == undone.json)

    // And both come back.
    let redos: [EditLogEntry] = [.redo(seq: 7, group: 2), .redo(seq: 8, group: 4)]
    for redo in redos {
        history.record(redo)
    }
    #expect(history.done == [2, 4])
    let redone = try replay(log + undos + redos)
    #expect(redone.mismatchSeq == nil)
    #expect(redone.document.style.padding == 0.1)
    #expect(redone.document.camera.mirror)

    // The same lines after a create in version 2: that migrate does not follow, so nothing before it comes back (1b).
    let cut = UndoHistory(entries: log)
    #expect(cut.done == [4])
    #expect(try replay(log + undos, createVersion: 2).mismatchSeq == 3)
}

@Test func lineThatWritesCameraBeforeTheMigrateClearsTheStacks() throws {
    // A line of version 1 that writes the whole camera, made by hand: it does not commute with the migration, which
    // writes inside it.
    let v1 = try #require(DocumentMigration.reverted(JSONValue(encoding: SmallDocument.document), to: 1))
    guard case let .object(document) = v1, case let .object(camera)? = document["camera"] else {
        Issue.record("no camera")
        return
    }
    var hidden = camera
    hidden["show"] = .bool(false)
    let wholeCamera = EditLogEntry.do(
        seq: 2, group: 2, label: EditLabel.camera.rawValue, changes: [try set("/camera", .object(camera), .object(hidden))], at: date)
    #expect(UndoHistory(entries: [SmallDocument.create, wholeCamera], createVersion: 1).done == [2])

    let log = [SmallDocument.create, wholeCamera, .migrate(seq: 3, from: 1, to: 2)]
    let history = UndoHistory(entries: log, createVersion: 1)
    #expect(history.done == [])
    #expect(history.undone == [])
    #expect(LogCompaction.compact(log, createVersion: 1) == log)
    let longer = log + [try padding(4)]
    #expect(UndoHistory(entries: longer, createVersion: 1).done == [4])
    #expect(LogCompaction.compact(longer, createVersion: 1) == longer)

    // The replay still migrates and goes on; only the history before the migrate is cut, and its undo is refused.
    let replayed = try replay(longer)
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.version == 2)
    #expect(!replayed.document.camera.show)
    #expect(replayed.document.camera.layouts.isEmpty)
    #expect(try replay(longer + [.undo(seq: 5, group: 2)]).mismatchSeq == 5)
    #expect(try replay(longer + [.undo(seq: 5, group: 4)]).mismatchSeq == nil)
}

// MARK: - Compaction keeps the create in version 1 and the migrate

@Test func compactionKeepsTheV1CreateAndTheMigrate() throws {
    // A seed whose stacks hold groups from before the migrate, done and undone, and groups from after it.
    let (editor, migrateSeq) = try edited(seed: 0)
    #expect(editor.history.done.contains { $0 < migrateSeq }, "done before the migrate")
    #expect(editor.history.undone.contains { $0 < migrateSeq }, "undone before the migrate")
    #expect((editor.history.done + editor.history.undone).contains { $0 > migrateSeq }, "groups from after it")
    #expect(editor.history.undone.count >= 3)

    let original = try replay(editor.entries)
    #expect(original.mismatchSeq == nil)
    #expect(original.version == 2)
    #expect(original.document.camera.mirror == editor.document.camera.mirror)
    var expected = editor.document
    expected.logSequence = original.lastAppliedSeq
    #expect(original.document == expected)

    let compacted = LogCompaction.compact(editor.entries, createVersion: 1)
    #expect(compacted.count < editor.entries.count)
    #expect(compacted.first == SmallDocument.create)
    guard compacted.count > 1, case .migrate(_, 1, 2) = compacted[1] else {
        Issue.record("the migrate right after the create")
        return
    }
    #expect(compacted.dropFirst(2).allSatisfy { if case .migrate = $0 { false } else { true } })
    #expect(zip(compacted, compacted.dropFirst()).allSatisfy { $0.seq < $1.seq })
    #expect(compacted.last?.seq == editor.entries.last?.seq)

    // Written as the session writes it, its create in version 1, and read back.
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data(try compacted.map { try $0.jsonLine(writingDocumentAt: 1) + "\n" }.joined().utf8).write(to: url)
        let read = try EditLogReader.read(url)
        #expect(read.createVersion == 1)
        #expect(read.entries == compacted)
        #expect(!read.droppedTrailingMigrate)
    }

    let replayed = try replay(compacted)
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.document == original.document)
    #expect(replayed.json == original.json)
    #expect(replayed.version == original.version)
    #expect(replayed.lastAppliedSeq == original.lastAppliedSeq)
    let history = UndoHistory(entries: compacted, createVersion: 1)
    #expect(history.done == editor.history.done)
    #expect(history.undone == editor.history.undone)
    #expect(history.undoLabel == editor.history.undoLabel)
    #expect(history.redoLabel == editor.history.redoLabel)
    #expect(history.nextSeq == UndoHistory(entries: editor.entries, createVersion: 1).nextSeq)

    // Undoing everything, across the migrate, and redoing everything goes through the same documents.
    let walked = try walkThroughTheHistory(compacted)
    #expect(try walked == walkThroughTheHistory(editor.entries))

    // With a create in version 2 that migrate does not follow: nothing is compacted.
    #expect(LogCompaction.compact(editor.entries) == editor.entries)
}

// MARK: - Helpers

/// A session of 300 random operations on a 1b project (its create in version 1), with the migrate of its first edit in
/// 1c at the 150th, then three undos; and the `seq` of the migrate.
private func edited(seed: UInt64) throws -> (editor: Editor, migrateSeq: Int) {
    var generator = SplitMix64(seed: seed)
    var editor = Editor(SmallDocument.document)
    var clock = date
    var migrateSeq = 0
    for operation in 0..<300 {
        if operation == 150 {
            // The first edit in 1c: its migrate and its step, together.
            migrateSeq = editor.history.nextSeq
            editor.migrate()
            clock += 2
            let step = try #require(
                editor.document.setChange("/style/padding", editor.document.style.padding + 0.01).map {
                    EditStep(label: .padding, target: "/style/padding", changes: [$0])
                })
            try editor.perform(step, at: clock)
            continue
        }
        let roll = Int.random(in: 0..<20, using: &generator)
        if roll < 10 {
            clock += Double.random(in: 0.05...1.4, using: &generator)
            if let step = randomStep(editor.document, migrated: migrateSeq > 0, using: &generator) {
                try editor.perform(step, at: clock)
            }
        } else if roll < 15 {
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                try editor.undo()
            }
        } else if roll < 19 {
            for _ in 0..<Int.random(in: 1...2, using: &generator) {
                try editor.redo()
            }
        } else {
            // A gap in the seqs, which the log allows.
            editor.history.nextSeq += Int.random(in: 1...3, using: &generator)
        }
    }
    for _ in 0..<3 {
        try editor.undo()
    }
    return (editor, migrateSeq)
}

/// An editor over `UndoHistory` the way the session uses it on a 1b project (its create in version 1), as in
/// `LogCompactionTests`, with the migrate of its first edit in 1c.
private struct Editor {
    var history: UndoHistory
    private(set) var entries: [EditLogEntry]
    private(set) var document: EditDocument
    private var groups: [Int: [EditChange]] = [:]

    init(_ document: EditDocument) {
        let create = EditLogEntry.create(seq: 1, document: document, app: app)
        history = UndoHistory(entries: [create], createVersion: 1)
        entries = [create]
        self.document = document
    }

    mutating func migrate() {
        append(.migrate(seq: history.nextSeq, from: 1, to: 2))
    }

    mutating func perform(_ step: EditStep, at: Date) throws {
        let group = history.groupForNext(step, at: at)
        document = try document.applying(step.changes)
        groups[group, default: []] += step.changes
        append(.do(seq: history.nextSeq, group: group, label: step.label.rawValue, changes: step.changes, at: at.roundedToWholeSeconds))
    }

    mutating func undo() throws {
        guard let group = history.done.last else { return }
        document = try document.applying(groups[group, default: []].reversed().map(\.inverse))
        append(.undo(seq: history.nextSeq, group: group))
    }

    mutating func redo() throws {
        guard let group = history.undone.last else { return }
        document = try document.applying(groups[group, default: []])
        append(.redo(seq: history.nextSeq, group: group))
    }

    private mutating func append(_ entry: EditLogEntry) {
        history.record(entry)
        entries.append(entry)
    }
}

/// A step of 1b on `document`, or, once `migrated`, also one of the camera's mirror and shadow that only version 2 has;
/// `nil` if the one picked would change nothing.
private func randomStep(_ document: EditDocument, migrated: Bool, using generator: inout SplitMix64) -> EditStep? {
    let level = Double(Int.random(in: 0...20, using: &generator)) / 100
    switch Int.random(in: 0..<(migrated ? 8 : 6), using: &generator) {
    case 0:
        return document.setChange("/style/padding", level).map { EditStep(label: .padding, target: "/style/padding", changes: [$0]) }
    case 1:
        return document.setChange("/style/cornerRadius", level).map {
            EditStep(label: .cornerRadius, target: "/style/cornerRadius", changes: [$0])
        }
    case 2:
        let index = Int.random(in: 0...document.zoom.suppressed.count, using: &generator)
        let start = UInt64.random(in: 1_000...8_000, using: &generator)
        let range = SourceRange(take: "take-001", start: HostTime(nanoseconds: start), end: HostTime(nanoseconds: start + 500))
        return EditStep(label: .zoomDelete, target: "/zoom/suppressed", changes: [document.insertChange(.zoomSuppressed, at: index, range)])
    case 3:
        guard !document.zoom.suppressed.isEmpty else { return nil }
        let index = Int.random(in: 0..<document.zoom.suppressed.count, using: &generator)
        return document.removeChange(.zoomSuppressed, at: index).map {
            EditStep(label: .zoomAdd, target: "/zoom/suppressed", changes: [$0])
        }
    case 4:
        var clip = document.sequence[0]
        clip.speed = [0.5, 1, 2, 4].randomElement(using: &generator) ?? 1
        return document.replaceChange(.sequence, id: clip.id, with: clip).map { EditStep(label: .speed, target: clip.id, changes: [$0]) }
    case 5:
        return document.setChange("/camera/show", !document.camera.show).map {
            EditStep(label: .camera, target: "/camera/show", changes: [$0])
        }
    case 6:
        return document.setChange("/camera/mirror", !document.camera.mirror).map {
            EditStep(label: .camera, target: "/camera/mirror", changes: [$0])
        }
    default:
        return document.setChange("/camera/shadow", level).map { EditStep(label: .camera, target: "/camera/shadow", changes: [$0]) }
    }
}

/// The documents met undoing every group of `entries` and then redoing every one, each line appended and replayed from
/// the document before it, as `LogCompactionTests` walks a log, its create in version 1.
private func walkThroughTheHistory(_ entries: [EditLogEntry]) throws -> [EditDocument] {
    var entries = entries
    var history = UndoHistory(entries: entries, createVersion: 1)
    let start = try replay(entries)
    var document = start.document
    var version = start.version
    var documents = [document]
    func append(_ line: EditLogEntry) throws {
        entries.append(line)
        history.record(line)
        let replayed = try #require(
            EditReplay.replay(snapshot: document, snapshotVersion: version, entries: entries, createVersion: 1))
        #expect(replayed.mismatchSeq == nil, "line \(line.seq)")
        document = replayed.document
        version = replayed.version
        documents.append(document)
    }
    while let group = history.done.last {
        try append(.undo(seq: history.nextSeq, group: group))
    }
    while let group = history.undone.last {
        try append(.redo(seq: history.nextSeq, group: group))
    }
    return documents
}

/// SplitMix64 (Steele, Lea and Flood): a seeded generator, so a failure can be run again.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
