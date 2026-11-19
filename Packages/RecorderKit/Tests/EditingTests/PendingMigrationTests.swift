// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share: a project of 1b (`DocumentV1Fixture`) opened, looked at and edited in 1c. Since
/// phase 2 its first edit migrates it twice, to version 3 (`PendingMigrationTo3Tests`, which also has the projects of 1c).
private enum Pending {
    static let app = AppInfo(name: "Toma", version: "0.3.0")

    /// A clock that moves 2 s each time it is read: every step is a group of its own.
    final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_794_780_000))

        func now() -> Date {
            date.withLock { date in
                defer { date += 2 }
                return date
            }
        }
    }

    static func context(
        caches: URL, compaction: (maxBytes: Int, maxEntries: Int) = (LogCompaction.maxBytes, LogCompaction.maxEntries),
        io: EditJournalIO = .system
    ) -> EditContext {
        let clock = Clock()
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma, now: { clock.now() },
            makeID: { prefix in count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            } },
            compaction: compaction, journalIO: io)
    }

    static func open(_ url: URL, _ context: EditContext) async throws -> EditSession {
        try await EditSession.open(url, take: nil, context: context)
    }

    static func step(_ document: EditDocument, _ path: String, _ value: Double, _ label: EditLabel) throws -> EditStep {
        EditStep(label: label, target: path, changes: [try #require(document.setChange(path, value))])
    }

    static func padding(_ document: EditDocument, _ value: Double) throws -> EditStep {
        try step(document, "/style/padding", value, .padding)
    }

    static func log(_ url: URL) -> URL { ProjectPackage(url: url).editLogURL }

    static func snapshot(_ url: URL) -> URL { ProjectPackage(url: url).editURL }

    static func read(_ url: URL) throws -> EditLogRead {
        try EditLogReader.read(log(url))
    }

    /// The lines of the log as they are in the file, without their line breaks.
    static func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: log(url)), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: log(url))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// The `documentVersion` `edit.json` is written in.
    static func snapshotVersion(_ url: URL) throws -> Int? {
        EditDocument.writtenVersion(of: try Data(contentsOf: snapshot(url)))
    }

    static func hasMigrate(_ url: URL) throws -> Bool {
        try lines(url).contains { $0.contains(#""type":"migrate""#) }
    }

    /// The log replayed from its `create`, in the version it is written in.
    static func replay(_ url: URL) throws -> EditReplay {
        let read = try read(url)
        let createVersion = try #require(read.createVersion)
        return try #require(EditReplay.replay(snapshot: nil, entries: read.entries, createVersion: createVersion))
    }

    /// `document` at another line of the log, to compare states whatever line they are at.
    static func state(_ document: EditDocument) -> EditDocument {
        var document = document
        document.logSequence = 0
        return document
    }

    /// The document of the log's `create`, as it is read (migrated).
    static func created(_ url: URL) throws -> EditDocument {
        guard case let .create(_, document, _)? = try read(url).entries.first else { throw TestSupportError.missing("create") }
        return document
    }

    /// A take of 1 s of one display in a new package of `formatVersion` without edits, written off the main actor.
    @concurrent static func legacyPackage(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "Legacy-v\(formatVersion)", formatVersion: formatVersion)
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    /// The system's calls, counting the writes (the bytes each one wrote). `cut(after:then:)` makes the next write stop
    /// after that many bytes and every write after it fail, until `heal()`.
    final class IO: Sendable {
        private struct State {
            var writes: [[UInt8]] = []
            var cutAfter: Int?
            var failure: POSIXErrorCode?
            var failing: POSIXErrorCode?
        }

        private enum Plan {
            case write(Int)
            case fail(POSIXErrorCode)
        }

        private let state = Mutex(State())

        var writes: [[UInt8]] { state.withLock { $0.writes } }

        func cut(after bytes: Int, then code: POSIXErrorCode) {
            state.withLock { state in
                state.cutAfter = bytes
                state.failure = code
            }
        }

        func heal() {
            state.withLock { state in
                state.cutAfter = nil
                state.failure = nil
                state.failing = nil
            }
        }

        var io: EditJournalIO {
            EditJournalIO(
                open: { try EditJournalIO.system.open($0, $1, $2) },
                write: { [self] descriptor, bytes in
                    let plan = state.withLock { state -> Plan in
                        if let code = state.failing { return .fail(code) }
                        guard let cut = state.cutAfter else { return .write(bytes.count) }
                        state.cutAfter = nil
                        state.failing = state.failure
                        return .write(min(cut, bytes.count))
                    }
                    switch plan {
                    case let .fail(code):
                        throw POSIXError(code)
                    case let .write(count):
                        let written = try EditJournalIO.system.write(descriptor, UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                        state.withLock { $0.writes.append(Array(bytes[..<written])) }
                        return written
                    }
                },
                fullSync: { try EditJournalIO.system.fullSync($0) },
                fsync: { try EditJournalIO.system.fsync($0) },
                syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
        }
    }
}

// MARK: - Opening a project of 1b writes nothing in version 2

@MainActor @Test func openingA1bProjectWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")

        // The snapshot at the last line: nothing to write.
        let current = try await DocumentV1Fixture.make(in: dir, steps: 4, snapshotAt: 4)
        let unchanged = try treeHash(current)
        let looked = try await Pending.open(current, Pending.context(caches: caches))
        #expect(looked.access == .editable)
        #expect(looked.notices.isEmpty)
        #expect(looked.document.documentVersion == EditDocument.currentVersion)
        #expect(looked.document.camera.layouts.isEmpty)
        #expect(looked.document == (try Pending.replay(current)).document)
        #expect(looked.undoLabel == .padding)
        #expect(await looked.flushed() == 5)
        #expect(!looked.hasUnsavedChanges)
        await looked.close()
        #expect(try treeHash(current) == unchanged)

        // A tail of the log after the snapshot: the snapshot at closing catches up with it, in version 1, as the replay
        // gives its JSON before decoding it.
        let behind = try await DocumentV1Fixture.make(in: dir, steps: 4, snapshotAt: 1)
        let behindLog = try Data(contentsOf: Pending.log(behind))
        let replayed = try Pending.replay(behind)
        #expect(replayed.version == 1)
        let caught = try await Pending.open(behind, Pending.context(caches: caches))
        #expect(caught.document == replayed.document)
        await caught.close()
        #expect(try Pending.snapshotVersion(behind) == 1)
        #expect(try Data(contentsOf: Pending.snapshot(behind)) == (try ProjectJSON.encoder().encode(replayed.json)))
        #expect(try Data(contentsOf: Pending.log(behind)) == behindLog)

        // Past the compaction's threshold: compacted at opening, with the `create` in version 1 and no `migrate`.
        let large = try await DocumentV1Fixture.make(in: dir, steps: 6, snapshotAt: 2)
        // An undo and a redo of the last step, as 1b writes them: lines the compaction drops.
        try Pending.append(
            [try EditLogEntry.undo(seq: 8, group: 7).jsonLine(), try EditLogEntry.redo(seq: 9, group: 7).jsonLine()]
                .map { $0 + "\n" }.joined(),
            to: large)
        let uncompacted = try Pending.replay(large)
        let compacting = Pending.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 5))
        let large1 = try await Pending.open(large, compacting)
        #expect(large1.document == uncompacted.document)
        await large1.close()
        let compacted = try Pending.read(large)
        #expect(compacted.createVersion == 1)
        #expect(compacted.entries.count == 7)
        #expect(compacted.entries.last?.seq == 9)
        #expect(try !Pending.hasMigrate(large))
        #expect(try Pending.snapshotVersion(large) == 1)
        #expect(try Data(contentsOf: Pending.snapshot(large)) == (try ProjectJSON.encoder().encode(Pending.replay(large).json)))
        #expect(try Pending.replay(large).json == uncompacted.json)

        // A last line cut short: truncated, and everything written is in version 1.
        let cut = try await DocumentV1Fixture.make(in: dir, steps: 4, snapshotAt: 2)
        let whole = try Data(contentsOf: Pending.log(cut))
        try Pending.append(#"{"at":"2026-11-15T2"#, to: cut)
        let cutShort = try await Pending.open(cut, Pending.context(caches: caches))
        #expect(cutShort.access == .editable)
        #expect(cutShort.notices.isEmpty)
        #expect(try Data(contentsOf: Pending.log(cut)) == whole)
        await cutShort.close()
        #expect(try Data(contentsOf: Pending.log(cut)) == whole)
        #expect(try Pending.read(cut).createVersion == 1)
        #expect(try Pending.snapshotVersion(cut) == 1)
        #expect(try Data(contentsOf: Pending.snapshot(cut)) == (try ProjectJSON.encoder().encode(Pending.replay(cut).json)))
    }
}

@MainActor @Test func trailingMigrateOpensAsVersion1() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 1)
        let whole = try Data(contentsOf: Pending.log(url))
        // The first edit of a 1c app cut short after its `migrate`.
        try Pending.append(try EditLogEntry.migrate(seq: 5, from: 1, to: 2).jsonLine() + "\n", to: url)
        let read = try Pending.read(url)
        #expect(read.droppedTrailingMigrate)
        #expect(read.entries.count == 4)
        #expect(read.createVersion == 1)

        let session = try await Pending.open(url, Pending.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .editable)
        #expect(session.notices.isEmpty)
        #expect(session.document.documentVersion == EditDocument.currentVersion)
        #expect(session.document == (try Pending.replay(url)).document)
        // The `migrate` is cut from the file before the journal opens it.
        #expect(try Data(contentsOf: Pending.log(url)) == whole)
        await session.close()
        #expect(try Data(contentsOf: Pending.log(url)) == whole)
        #expect(try Pending.read(url).createVersion == 1)
        #expect(try Pending.snapshotVersion(url) == 1)
        #expect(try EditDocument.decode(Data(contentsOf: Pending.snapshot(url))).logSequence == 4)
    }
}

@MainActor @Test func repairNeverEndsTheLogWithAMigrate() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 1)
        let good = try Pending.lines(url)
        // A first edit of 1c whose step does not match the document (its `before` is not what is there): the replay
        // stops right after the `migrate`, which the repaired log leaves out, as the reader would.
        let mismatch = EditLogEntry.do(
            seq: 6, group: 6, label: "style.padding",
            changes: [.set(path: try JSONPointer("/style/padding"), before: .number(0.9), after: .number(0.1))],
            at: DocumentV1Fixture.date)
        try Pending.append(
            [try EditLogEntry.migrate(seq: 5, from: 1, to: 2).jsonLine(), try mismatch.jsonLine()].map { $0 + "\n" }.joined(),
            to: url)
        let context = Pending.context(caches: dir.appending(path: "Caches"))
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == 1)

        let session = try await Pending.open(url, context)
        #expect(session.access == .editable)
        #expect(session.notices.count == 1)
        #expect(try Pending.lines(url) == good)
        #expect(session.undoLabel == .shadow)
        await session.close()
        #expect(try Pending.lines(url) == good)
        #expect(try Pending.snapshotVersion(url) == 1)
        #expect(try EditDocument.decode(Data(contentsOf: Pending.snapshot(url))).logSequence == 4)
        let copies = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasPrefix("edit-log.jsonl.damaged-") }
        #expect(copies.count == 1)
    }
}

@MainActor @Test func damageBeforeTheSnapshotStartsAVersion1Log() async throws {
    try await withTemporaryDirectory { dir in
        // Plan decision 5 of 1b: `edit.json` is newer than every line that can be applied; the log starts again with a
        // `create` of it, in the version it is written in.
        let url = try await DocumentV1Fixture.make(in: dir, steps: 4, snapshotAt: 4)
        let snapshot = try Data(contentsOf: Pending.snapshot(url))
        var lines = try Pending.lines(url)
        lines[2] = "garbage"
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: Pending.log(url))
        let session = try await Pending.open(url, Pending.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .editable)
        #expect(session.notices.count == 1)
        #expect(session.undoLabel == nil)
        #expect(await session.flushed() == 5)
        await session.close()
        let read = try Pending.read(url)
        #expect(read.createVersion == 1)
        #expect(read.entries.count == 1)
        #expect(read.entries.first == .create(seq: 5, document: session.document, app: Pending.app))
        #expect(try Data(contentsOf: Pending.snapshot(url)) == snapshot)
    }
}

@MainActor @Test func aMigrateThatCutsTheHistoryRefusesUndoingAcrossIt() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 0, snapshotAt: nil)
        // A line of version 1 that writes the whole document, made by hand, and a step after it: the first edit's
        // `migrate` does not commute with the first, even carried, so it cuts the history (the rule of 1b). (One that
        // writes the whole camera is carried through it: `MigrationHistoryTests`.)
        let v1 = try #require(DocumentMigration.reverted(JSONValue(encoding: Pending.created(url)), to: 1))
        guard case var .object(document) = v1, case var .object(camera)? = document["camera"] else {
            Issue.record("no camera")
            return
        }
        camera["show"] = .bool(false)
        document["camera"] = .object(camera)
        let lines = [
            EditLogEntry.do(
                seq: 2, group: 2, label: EditLabel.camera.rawValue,
                changes: [.set(path: JSONPointer(components: []), before: v1, after: .object(document))],
                at: DocumentV1Fixture.date),
            EditLogEntry.do(
                seq: 3, group: 3, label: EditLabel.padding.rawValue,
                changes: [.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))],
                at: DocumentV1Fixture.date),
        ]
        try Pending.append(try lines.map { try $0.jsonLine() + "\n" }.joined(), to: url)
        let before = try Pending.lines(url)

        let caches = dir.appending(path: "Caches")
        let session = try await Pending.open(url, Pending.context(caches: caches))
        #expect(!session.document.camera.show)
        #expect(session.undoLabel == .padding)
        // After the `migrate` there is nothing to undo: nothing is written.
        #expect(session.undo() == .refused)
        #expect(session.document.style.padding == 0.1)
        #expect(await session.flushed() == 3)
        #expect(try Pending.lines(url) == before)

        #expect(session.perform(try Pending.step(session.document, "/style/shadow", 0.2, .shadow)) == .applied)
        #expect(await session.flushed() == 6)
        #expect(Array(try Pending.read(url).entries.suffix(3).prefix(2)) == [.migrate(seq: 4, from: 1, to: 2), .migrate(seq: 5, from: 2, to: 3)])
        #expect(session.undo() == .applied)
        #expect(session.undo() == .refused)
        let undone = session.document
        await session.close()

        let again = try await Pending.open(url, Pending.context(caches: caches))
        #expect(again.notices.isEmpty)
        #expect(again.document == undone)
        #expect(again.undoLabel == nil)
        #expect(again.redoLabel == .shadow)
        await again.close()
    }
}

@MainActor @Test func canUndoAndCanRedoAreFalseWhereAMigrateThatCutsTheHistoryRefuses() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 0, snapshotAt: nil)
        // As above, a line of version 1 that writes the whole document, two steps after it, and the second undone (as 1b
        // writes it): an undo and a redo on the stacks that both apply to the document, and both of which the first
        // edit's `migrate` cuts.
        let v1 = try #require(DocumentMigration.reverted(JSONValue(encoding: Pending.created(url)), to: 1))
        guard case var .object(document) = v1, case var .object(camera)? = document["camera"] else {
            Issue.record("no camera")
            return
        }
        camera["show"] = .bool(false)
        document["camera"] = .object(camera)
        let lines = [
            EditLogEntry.do(
                seq: 2, group: 2, label: EditLabel.camera.rawValue,
                changes: [.set(path: JSONPointer(components: []), before: v1, after: .object(document))],
                at: DocumentV1Fixture.date),
            EditLogEntry.do(
                seq: 3, group: 3, label: EditLabel.padding.rawValue,
                changes: [.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))],
                at: DocumentV1Fixture.date),
            EditLogEntry.do(
                seq: 4, group: 4, label: EditLabel.padding.rawValue,
                changes: [.set(path: try JSONPointer("/style/padding"), before: .number(0.1), after: .number(0.12))],
                at: DocumentV1Fixture.date),
            EditLogEntry.undo(seq: 5, group: 4),
        ]
        try Pending.append(try lines.map { try $0.jsonLine() + "\n" }.joined(), to: url)
        let before = try Pending.lines(url)

        let session = try await Pending.open(url, Pending.context(caches: dir.appending(path: "Caches")))
        // The history 1b left names an undo and a redo, but the Edit menu offers neither: both would be refused.
        #expect(session.undoLabel == .padding && session.redoLabel == .padding)
        #expect(session.document.style.padding == 0.1)
        #expect(!session.canUndo && !session.canRedo)
        #expect(session.undo() == .refused)
        #expect(session.redo() == .refused)
        #expect(session.document.style.padding == 0.1)
        #expect(await session.flushed() == 5)
        #expect(try Pending.lines(url) == before)

        // The first edit writes the `migrate`: from then on each answer is what the step does.
        #expect(session.perform(try Pending.step(session.document, "/style/shadow", 0.2, .shadow)) == .applied)
        #expect(session.canUndo && !session.canRedo)
        #expect(session.undo() == .applied)
        // Nothing from before the `migrate` comes back.
        #expect(!session.canUndo && session.canRedo)
        #expect(session.undo() == .refused)
        #expect(session.redo() == .applied)
        #expect(session.canUndo && !session.canRedo)
        #expect(session.redo() == .refused)
        await session.close()
    }
}

@MainActor @Test func readDocumentOfAPendingProjectChangesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 1)
        try Pending.append(#"{"at":"2026-11-15T2"#, to: url)
        let before = try treeHash(url)
        let context = Pending.context(caches: dir.appending(path: "Caches"))
        let (_, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
        #expect(diskVersion == 1)
        #expect(document.documentVersion == EditDocument.currentVersion)
        #expect(document == (try Pending.replay(url)).document)
        let (_, plain) = try EditSession.readDocument(url, take: nil, context: context)
        #expect(plain == document)
        #expect(try treeHash(url) == before)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Caches").path))
    }
}

@MainActor @Test func readDocumentGivesTheDiskVersion() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let context = Pending.context(caches: dir.appending(path: "Caches"))
        let (_, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
        #expect(diskVersion == 1)
        #expect(document.documentVersion == EditDocument.currentVersion)
        #expect(document.camera.sizeReference == .height)

        let session = try await Pending.open(url, context)
        #expect(session.document == document)
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 7)
        // The migrates and the step are on disk: the project is of version 3 now, also before the snapshot.
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == EditDocument.currentVersion)
        let edited = session.document
        await session.close()
        let (_, read, version) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
        #expect(version == EditDocument.currentVersion)
        #expect(read == edited)
    }
}

// MARK: - The first edit

@MainActor @Test func firstEditWritesMigrateAndTheStepInOneWrite() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let before = try Pending.lines(url)
        let io = Pending.IO()
        let session = try await Pending.open(url, Pending.context(caches: dir.appending(path: "Caches"), io: io.io))
        #expect(io.writes.isEmpty)
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 7)

        let lines = try Pending.lines(url)
        #expect(Array(lines.prefix(4)) == before)
        #expect(lines.count == 7)
        let entries = try Pending.read(url).entries
        #expect(entries.count == 7)
        #expect(Array(entries[4...5]) == [.migrate(seq: 5, from: 1, to: 2), .migrate(seq: 6, from: 2, to: 3)])
        if case let .do(seq, group, label, _, _)? = entries.last {
            #expect((seq, group, label) == (7, 7, "style.padding"))
        } else {
            Issue.record("no do line: \(entries)")
        }
        // One write with the three lines.
        #expect(io.writes.count == 1)
        #expect(io.writes.first == Array((lines[4] + "\n" + lines[5] + "\n" + lines[6] + "\n").utf8))
        #expect(try Pending.read(url).createVersion == 1)

        // The snapshot after it is of the current version.
        await session.close()
        #expect(try Pending.snapshotVersion(url) == EditDocument.currentVersion)
        #expect(try EditDocument.decode(Data(contentsOf: Pending.snapshot(url))) == session.document)
        #expect(try Pending.lines(url) == lines)
    }
}

@MainActor @Test func firstUndoAlsoMigrates() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let io = Pending.IO()
        let caches = dir.appending(path: "Caches")
        let session = try await Pending.open(url, Pending.context(caches: caches, io: io.io))
        #expect(session.undoLabel == .shadow)
        #expect(session.undo() == .applied)
        #expect(session.document.style.shadow == 0)
        #expect(await session.flushed() == 7)
        let entries = try Pending.read(url).entries
        #expect(Array(entries.suffix(3)) == [.migrate(seq: 5, from: 1, to: 2), .migrate(seq: 6, from: 2, to: 3), .undo(seq: 7, group: 4)])
        let lines = try Pending.lines(url)
        #expect(io.writes == [Array((lines[4] + "\n" + lines[5] + "\n" + lines[6] + "\n").utf8)])
        let undone = session.document
        await session.close()
        #expect(try Pending.snapshotVersion(url) == EditDocument.currentVersion)

        let again = try await Pending.open(url, Pending.context(caches: caches))
        #expect(Pending.state(again.document) == Pending.state(undone))
        #expect(again.undoLabel == .cornerRadius)
        #expect(again.redoLabel == .shadow)
        #expect(again.redo() == .applied)
        #expect(again.document.style.shadow != 0)
        #expect(await again.flushed() == 8)
        await again.close()
        // Only one `migrate` to each version.
        #expect(try Pending.lines(url).count { $0.contains(#""type":"migrate""#) } == 2)
    }
}

@MainActor @Test func aLayoutCommandOnA1bProjectWritesTheMigrationWithIt() async throws {
    try await withTemporaryDirectory { dir in
        // The camera's layouts arrive with version 2: a 1b project still in version 1 on disk gets them at its first edit.
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let caches = dir.appending(path: "Caches")
        let session = try await Pending.open(url, Pending.context(caches: caches))
        let map = TimeMap(sequence: session.document.sequence)
        let add = try #require(LayoutCommands.add(session.document, kind: .split, at: 0, timeMap: map, makeID: { $0 + "0000000a" }))
        #expect(session.perform(add) == .applied)
        #expect(session.perform(try #require(LayoutCommands.setProjectLayout(session.document, .cameraOnly))) == .applied)
        #expect(await session.flushed() == 8)
        let read = try Pending.read(url)
        #expect(read.createVersion == 1)
        #expect(read.entries.count == 8)
        #expect(Array(read.entries[4...5]) == [.migrate(seq: 5, from: 1, to: 2), .migrate(seq: 6, from: 2, to: 3)])
        let labels = read.entries.suffix(2).compactMap { entry -> String? in
            guard case let .do(_, _, label, _, _) = entry else { return nil }
            return label
        }
        #expect(labels == ["layout.add", "camera.layout"])
        let edited = session.document
        await session.close()
        #expect(try Pending.snapshotVersion(url) == EditDocument.currentVersion)

        // Reopened, from the snapshot and from the log alone: the block and the project's layout are there.
        let again = try await Pending.open(url, Pending.context(caches: caches))
        #expect(Pending.state(again.document) == Pending.state(edited))
        #expect(Pending.state(try Pending.replay(url).document) == Pending.state(edited))
        let block = try #require(again.document.camera.layouts.first)
        #expect(again.document.camera.layouts.count == 1)
        #expect((block.id, block.kind, block.split) == ("l-0000000a", .split, SplitLayout(side: .end)))
        #expect(map.outputRange(ofSource: block.start..<block.end, take: block.take) == 0..<map.duration)
        #expect(again.document.camera.layout == CameraLayout(kind: .cameraOnly))
        #expect(again.undoLabel == .cameraLayout)
        await again.close()
    }
}

@MainActor @Test func undoReachesStepsFromBefore1c() async throws {
    try await withTemporaryDirectory { dir in
        // Three groups of 1b.
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let created = try Pending.created(url)
        let caches = dir.appending(path: "Caches")
        let session = try await Pending.open(url, Pending.context(caches: caches))
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .applied)
        // The document after each group, from the last one to the create's.
        var states = [Pending.state(session.document)]
        for _ in 0..<4 {
            #expect(session.undo() == .applied)
            states.append(Pending.state(session.document))
        }
        #expect(session.undo() == .refused)
        #expect(session.undoLabel == nil)
        #expect(session.redoLabel == .padding)
        #expect(Pending.state(session.document) == Pending.state(created))
        #expect(session.document.documentVersion == EditDocument.currentVersion)
        #expect(await session.flushed() == 11)
        await session.close()

        let again = try await Pending.open(url, Pending.context(caches: caches))
        #expect(Pending.state(again.document) == Pending.state(created))
        #expect(again.undoLabel == nil)
        #expect(again.redoLabel == .padding)
        // Every group comes back, in order, up to the edit of 1c.
        for expected in states.reversed().dropFirst() {
            #expect(again.redo() == .applied)
            #expect(Pending.state(again.document) == expected)
        }
        #expect(again.redo() == .refused)
        #expect(again.undoLabel == .padding)
        await again.close()
    }
}

@MainActor @Test func diskFullOnTheFirstEditNeverLeavesMigrateAlone() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let before = try Pending.lines(url)
        let io = Pending.IO()
        let context = Pending.context(caches: dir.appending(path: "Caches"), io: io.io)
        let session = try await Pending.open(url, context)
        let original = session.document
        let migrate = try EditLogEntry.migrate(seq: 5, from: 1, to: 2).jsonLine()
        // The disk fills up right after the `migrate` line.
        io.cut(after: migrate.utf8.count + 1, then: .ENOSPC)
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 4)
        #expect(await eventually { session.notices.contains(.saveFailed(.ENOSPC)) })
        #expect(session.hasUnsavedChanges)
        #expect(try Pending.lines(url) == before + [migrate])

        // A copy of the package as it is now, as a crash would leave it, opens as version 1: as if the edit had not come.
        let copy = dir.appending(path: "Copy.toma", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(try Pending.read(copy).droppedTrailingMigrate)
        let (_, copied, version) = try EditSession.readDocumentWithDiskVersion(copy, take: nil, context: context)
        #expect(version == 1)
        #expect(Pending.state(copied) == Pending.state(original))

        // The retry writes the rest of the buffer: every line, once each, in order.
        io.heal()
        #expect(await eventually(timeout: .seconds(20)) { !session.hasUnsavedChanges })
        #expect(await session.flushed() == 7)
        let lines = try Pending.lines(url)
        #expect(lines.count == 7)
        #expect(Array(lines.prefix(5)) == before + [migrate])
        let entries = try Pending.read(url).entries
        #expect(entries.map(\.seq) == [1, 2, 3, 4, 5, 6, 7])
        if case let .do(_, _, label, _, _)? = entries.last {
            #expect(label == "style.padding")
        } else {
            Issue.record("no do line: \(entries)")
        }
        #expect(io.writes.map(\.count).reduce(0, +) == (lines[4] + "\n" + lines[5] + "\n" + lines[6] + "\n").utf8.count)
        await session.close()
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == EditDocument.currentVersion)
    }
}

// MARK: - Compaction after the first edit

@MainActor @Test func compactionAfterTheFirstEditKeepsTheV1Create() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: 3)
        let caches = dir.appending(path: "Caches")
        let compacting = Pending.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 5))
        let session = try await Pending.open(url, compacting)
        // The first edit, an undo and a redo (which the compaction drops) and another step.
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .applied)
        #expect(session.undo() == .applied)
        #expect(session.redo() == .applied)
        #expect(session.perform(try Pending.step(session.document, "/style/shadow", 0.2, .shadow)) == .applied)
        #expect(session.undo() == .applied)
        #expect(await session.flushed() == 11)
        // The log before the compaction, in a copy of the package.
        let copy = dir.appending(path: "Uncompacted.toma", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        let edited = session.document
        await session.close()

        let compacted = try Pending.read(url)
        let uncompacted = try Pending.read(copy)
        #expect(compacted.entries.count < uncompacted.entries.count)
        #expect(compacted.entries.last?.seq == 11)
        #expect(compacted.createVersion == 1)
        #expect(compacted.entries.first == uncompacted.entries.first)
        guard compacted.entries.count > 2, case .migrate(_, 1, 2) = compacted.entries[1], case .migrate(_, 2, 3) = compacted.entries[2]
        else {
            Issue.record("the migrates right after the create: \(compacted.entries)")
            return
        }
        #expect(try Pending.lines(url).first == (try Pending.lines(copy).first))
        #expect(try Pending.snapshotVersion(url) == EditDocument.currentVersion)

        // The same document, the same JSON and the same stacks.
        #expect(try Pending.replay(url).json == (try Pending.replay(copy).json))
        #expect(try Pending.replay(url).version == EditDocument.currentVersion)
        #expect(try Pending.replay(url).document == (try Pending.replay(copy).document))
        let stacks = UndoHistory(entries: compacted.entries, createVersion: 1)
        let original = UndoHistory(entries: uncompacted.entries, createVersion: 1)
        #expect(stacks.done == original.done)
        #expect(stacks.undone == original.undone)
        #expect(stacks.done.count == 4)

        let again = try await Pending.open(url, Pending.context(caches: caches))
        let other = try await Pending.open(copy, Pending.context(caches: caches))
        #expect(again.document == edited)
        #expect(other.document == edited)
        #expect(again.redoLabel == .shadow)
        #expect(again.redo() == .applied)
        #expect(other.redo() == .applied)
        #expect(Pending.state(again.document) == Pending.state(other.document))
        // Undo goes back through every group, those of 1b included, to the create's document.
        while other.undo() == .applied {
            #expect(again.undo() == .applied)
            #expect(Pending.state(again.document) == Pending.state(other.document))
        }
        #expect(again.undo() == .refused)
        #expect(Pending.state(again.document) == Pending.state(try Pending.created(url)))
        await again.close()
        await other.close()
    }
}

// MARK: - Legacy packages

@MainActor @Test func legacyPackageFirstEditCreatesTheCurrentVersion() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await Pending.legacyPackage(in: dir, formatVersion: 2)
        let url = project.package.url
        let context = Pending.context(caches: dir.appending(path: "Caches"))
        let current = EditDocument.currentVersion
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == current)
        let session = try await Pending.open(url, context)
        #expect(session.perform(try Pending.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 2)
        let read = try Pending.read(url)
        #expect(read.createVersion == current)
        #expect(read.entries.count == 2)
        #expect(try !Pending.hasMigrate(url))
        await session.close()
        #expect(try Pending.snapshotVersion(url) == current)
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == current)
    }
}
