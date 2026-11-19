// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share: a project of 1c (its edit document in `documentVersion` 2) or of 1b (in 1,
/// `DocumentV1Fixture`) opened, looked at and edited in phase 2, whose document is of version 3 (phase 2 design §8).
private enum To3 {
    static let app = AppInfo(name: "Toma", version: "0.4.0")
    /// The `at` of every step of the fixtures: 2026-11-15T20:12:03Z.
    static let date = Date(timeIntervalSince1970: 1_794_773_523)

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

    static func step(_ document: EditDocument, _ path: String, _ value: some Encodable, _ label: EditLabel) throws -> EditStep {
        EditStep(label: label, target: path, changes: [try #require(document.setChange(path, value))])
    }

    static func padding(_ document: EditDocument, _ value: Double) throws -> EditStep {
        try step(document, "/style/padding", value, .padding)
    }

    /// The first edit of phase 2 here: the captions shown, a place only version 3 has.
    static func captions(_ document: EditDocument) throws -> EditStep {
        try step(document, "/captions/show", true, .captionsShow)
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

    /// A project edited in milestone 1c, as the app of 1c left it on disk: `DocumentV1Fixture`'s package and steps, with
    /// everything written in `documentVersion` 2 (`<directory>/1c-<steps>-<snapshotAt>.toma`).
    @concurrent static func v2Project(in directory: URL, steps: Int, snapshotAt: Int?) async throws -> URL {
        let builder = try TakeBuilder(in: directory, name: "1c-\(steps)-\(snapshotAt.map(String.init) ?? "none")")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        let project = try builder.write()

        var document = EditDocument.legacy(for: project)
        document.logSequence = 1
        let app = AppInfo(name: "Toma", version: "0.3.0")
        var lines = [try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine(writingDocumentAt: 2)]
        var snapshot = snapshotAt == 0 ? document : nil
        for step in stride(from: 1, through: steps, by: 1) {
            let seq = step + 1
            let index = (step - 1) % DocumentV1Fixture.paths.count
            let change = try #require(document.setChange(DocumentV1Fixture.paths[index], 0.001 * Double(step) + 0.05))
            lines.append(
                try EditLogEntry.do(seq: seq, group: seq, label: DocumentV1Fixture.labels[index], changes: [change], at: date)
                    .jsonLine())
            document = try document.applying([change])
            document.logSequence = seq
            if step == snapshotAt { snapshot = document }
        }
        try DurableFile.writeAtomically(Data(lines.map { $0 + "\n" }.joined().utf8), to: project.package.editLogURL)
        if snapshotAt != nil {
            let taken = try #require(snapshot)
            let written = try #require(DocumentMigration.reverted(try JSONValue(encoding: taken), to: 2))
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(written), to: project.package.editURL)
        }
        return project.package.url
    }

    /// A project of 1c (`version` 2) or of 1b (`version` 1) with `steps` steps and its snapshot at `snapshotAt`.
    static func project(_ version: Int, in directory: URL, steps: Int, snapshotAt: Int?) async throws -> URL {
        version == 2
            ? try await v2Project(in: directory, steps: steps, snapshotAt: snapshotAt)
            : try await DocumentV1Fixture.make(in: directory, steps: steps, snapshotAt: snapshotAt)
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

// MARK: - Opening a project of phase 1 writes nothing in version 3

@MainActor @Test func openingAVersion2ProjectWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let context = To3.context(caches: caches)

        // The snapshot at the last line: opened, read as the export reads it (`EditSession.readDocument`, which the
        // library's export and `recorder-dev export` use), played and closed without an edit: nothing written.
        let current = try await To3.v2Project(in: dir, steps: 4, snapshotAt: 4)
        let unchanged = try treeHash(current)
        let looked = try await To3.open(current, context)
        #expect(looked.access == .editable)
        #expect(looked.notices.isEmpty)
        #expect(looked.document.documentVersion == 3)
        #expect(looked.document.captions == .legacy)
        #expect(looked.document == (try To3.replay(current)).document)
        #expect(looked.undoLabel == .padding)
        let (_, exported, diskVersion) = try EditSession.readDocumentWithDiskVersion(current, take: nil, context: context)
        #expect(diskVersion == 2)
        #expect(exported == looked.document)
        #expect(try EditSession.readDocument(current, take: nil, context: context).1 == looked.document)
        #expect(try EditSession.readOutline(current, take: nil, context: context).1.diskVersion == 2)
        #expect(await looked.flushed() == 5)
        #expect(!looked.hasUnsavedChanges)
        await looked.close()
        #expect(try treeHash(current) == unchanged)

        // A tail of the log after the snapshot: the snapshot at closing catches up with it, in version 2, as the replay
        // gives its JSON before decoding it.
        let behind = try await To3.v2Project(in: dir, steps: 4, snapshotAt: 1)
        let behindLog = try Data(contentsOf: To3.log(behind))
        let replayed = try To3.replay(behind)
        #expect(replayed.version == 2)
        let caught = try await To3.open(behind, context)
        #expect(caught.document == replayed.document)
        await caught.close()
        #expect(try To3.snapshotVersion(behind) == 2)
        #expect(try Data(contentsOf: To3.snapshot(behind)) == (try ProjectJSON.encoder().encode(replayed.json)))
        #expect(try Data(contentsOf: To3.log(behind)) == behindLog)
        #expect(!(try String(decoding: Data(contentsOf: To3.snapshot(behind)), as: UTF8.self)).contains("\"captions\""))

        // A long log, past the compaction's threshold: compacted at opening and closing, with the `create` in version 2
        // and no `migrate`.
        let large = try await To3.v2Project(in: dir, steps: 6, snapshotAt: 2)
        try To3.append(
            [try EditLogEntry.undo(seq: 8, group: 7).jsonLine(), try EditLogEntry.redo(seq: 9, group: 7).jsonLine()]
                .map { $0 + "\n" }.joined(),
            to: large)
        let uncompacted = try To3.replay(large)
        let compacting = To3.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 5))
        let large1 = try await To3.open(large, compacting)
        #expect(large1.document == uncompacted.document)
        await large1.close()
        let compacted = try To3.read(large)
        #expect(compacted.createVersion == 2)
        #expect(compacted.entries.count == 7)
        #expect(compacted.entries.last?.seq == 9)
        #expect(try !To3.hasMigrate(large))
        #expect(try To3.snapshotVersion(large) == 2)
        #expect(try Data(contentsOf: To3.snapshot(large)) == (try ProjectJSON.encoder().encode(To3.replay(large).json)))
        #expect(try To3.replay(large).json == uncompacted.json)
        #expect(try !To3.lines(large).contains { $0.contains("\"captions\"") || $0.contains("\"documentVersion\":3") })

        // A last line cut short: truncated, and everything written is in version 2.
        let cut = try await To3.v2Project(in: dir, steps: 4, snapshotAt: 2)
        let whole = try Data(contentsOf: To3.log(cut))
        try To3.append(#"{"at":"2026-11-15T2"#, to: cut)
        let cutShort = try await To3.open(cut, context)
        #expect(cutShort.access == .editable)
        #expect(try Data(contentsOf: To3.log(cut)) == whole)
        await cutShort.close()
        #expect(try Data(contentsOf: To3.log(cut)) == whole)
        #expect(try To3.read(cut).createVersion == 2)
        #expect(try To3.snapshotVersion(cut) == 2)
    }
}

@MainActor @Test func openingAVersion1ProjectWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let context = To3.context(caches: dir.appending(path: "Caches"))
        for snapshotAt in [3, 1] {
            let url = try await DocumentV1Fixture.make(in: dir, steps: 3, snapshotAt: snapshotAt)
            let replayed = try To3.replay(url)
            #expect(replayed.version == 1)
            let unchanged = try treeHash(url)
            let log = try Data(contentsOf: To3.log(url))
            let session = try await To3.open(url, context)
            #expect(session.access == .editable)
            #expect(session.notices.isEmpty)
            #expect(session.document.documentVersion == 3)
            #expect(session.document == replayed.document)
            let (_, exported, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
            #expect(diskVersion == 1)
            #expect(exported == session.document)
            #expect(try EditSession.readOutline(url, take: nil, context: context).1.diskVersion == 1)
            await session.close()
            #expect(try Data(contentsOf: To3.log(url)) == log)
            #expect(try To3.snapshotVersion(url) == 1)
            #expect(try Data(contentsOf: To3.snapshot(url)) == (try ProjectJSON.encoder().encode(replayed.json)))
            if snapshotAt == 3 {
                #expect(try treeHash(url) == unchanged)
            }
        }
    }
}

// MARK: - The first edit

@MainActor @Test func firstEditTo3WritesMigrateAndTheStepInOneWrite() async throws {
    try await withTemporaryDirectory { dir in
        for version in [2, 1] {
            let url = try await To3.project(version, in: dir, steps: 3, snapshotAt: 3)
            let before = try To3.lines(url)
            let io = To3.IO()
            let session = try await To3.open(url, To3.context(caches: dir.appending(path: "Caches"), io: io.io))
            #expect(io.writes.isEmpty)
            #expect(session.perform(try To3.captions(session.document)) == .applied)
            // The migrates, one for each version up to 3, and the step.
            let migrates: [EditLogEntry] =
                version == 2 ? [.migrate(seq: 5, from: 2, to: 3)] : [.migrate(seq: 5, from: 1, to: 2), .migrate(seq: 6, from: 2, to: 3)]
            let last = 5 + migrates.count
            #expect(await session.flushed() == last, "\(version)")

            let lines = try To3.lines(url)
            #expect(Array(lines.prefix(4)) == before, "\(version)")
            #expect(lines.count == last, "\(version)")
            let entries = try To3.read(url).entries
            #expect(Array(entries.dropFirst(4).dropLast()) == migrates, "\(version)")
            if case let .do(seq, group, label, _, _)? = entries.last {
                #expect((seq, group, label) == (last, last, "captions.show"), "\(version)")
            } else {
                Issue.record("no do line: \(entries)")
            }
            // One write with every line.
            #expect(io.writes.count == 1, "\(version)")
            #expect(io.writes.first == Array(lines.dropFirst(4).map { $0 + "\n" }.joined().utf8), "\(version)")
            #expect(try To3.read(url).createVersion == version, "\(version)")
            #expect(try To3.replay(url).version == 3, "\(version)")

            // The snapshot after it is of version 3.
            await session.close()
            #expect(try To3.snapshotVersion(url) == 3, "\(version)")
            #expect(try EditDocument.decode(Data(contentsOf: To3.snapshot(url))) == session.document, "\(version)")
            #expect(try To3.lines(url) == lines, "\(version)")
            #expect(
                try EditSession.readDocumentWithDiskVersion(url, take: nil, context: To3.context(caches: dir)).diskVersion == 3,
                "\(version)")
        }
    }
}

@MainActor @Test func undoCrossesTheMigrationTo3() async throws {
    try await withTemporaryDirectory { dir in
        // A project of 1c with a step of 1c (the padding), and the first edit in phase 2: the captions shown.
        let url = try await To3.v2Project(in: dir, steps: 1, snapshotAt: 1)
        let created = try To3.created(url)
        let caches = dir.appending(path: "Caches")
        let session = try await To3.open(url, To3.context(caches: caches))
        #expect(session.undoLabel == .padding)
        let padded = To3.state(session.document)
        #expect(session.perform(try To3.captions(session.document)) == .applied)
        #expect(session.document.captions.show)
        // Two undos bring back both: the captions hidden, then the padding of the create, never "unmigrated".
        #expect(session.undoLabel == .captionsShow)
        #expect(session.undo() == .applied)
        #expect(To3.state(session.document) == padded)
        #expect(session.undo() == .applied)
        #expect(To3.state(session.document) == To3.state(created))
        #expect(session.document.documentVersion == 3)
        #expect(session.undo() == .refused)
        #expect(await session.flushed() == 6)
        let undone = session.document
        await session.close()

        // The replay gives the same, and both come back.
        #expect(To3.state(try To3.replay(url).document) == To3.state(undone))
        #expect(try To3.replay(url).version == 3)
        let again = try await To3.open(url, To3.context(caches: caches))
        #expect(To3.state(again.document) == To3.state(undone))
        #expect(again.redoLabel == .padding)
        #expect(again.redo() == .applied)
        #expect(To3.state(again.document) == padded)
        #expect(again.redo() == .applied)
        #expect(again.document.captions.show)
        await again.close()
    }
}

@MainActor @Test func diskFullOnTheFirstEditTo3NeverLeavesMigrateAlone() async throws {
    try await withTemporaryDirectory { dir in
        for version in [2, 1] {
            let url = try await To3.project(version, in: dir, steps: 3, snapshotAt: 3)
            let before = try To3.lines(url)
            let io = To3.IO()
            let context = To3.context(caches: dir.appending(path: "Caches"), io: io.io)
            let session = try await To3.open(url, context)
            let original = session.document
            let migrates =
                version == 2
                ? [try EditLogEntry.migrate(seq: 5, from: 2, to: 3).jsonLine()]
                : [try EditLogEntry.migrate(seq: 5, from: 1, to: 2).jsonLine(), try EditLogEntry.migrate(seq: 6, from: 2, to: 3).jsonLine()]
            let migrateBytes = migrates.map { $0 + "\n" }.joined().utf8.count
            // The disk fills up in the middle of the buffer: right after the migrate of 2→3, or inside it.
            io.cut(after: version == 2 ? migrateBytes : migrateBytes - 3, then: .ENOSPC)
            #expect(session.perform(try To3.captions(session.document)) == .applied)
            #expect(await session.flushed() == 4)
            #expect(await eventually { session.notices.contains(.saveFailed(.ENOSPC)) })
            #expect(session.hasUnsavedChanges)

            // A copy of the package as it is now, as a crash would leave it, opens as it was: no migrate at the end, the
            // document of before, in its version.
            let copy = dir.appending(path: "Copy-\(version).toma", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: url, to: copy)
            let read = try To3.read(copy)
            #expect(read.entries.count == 4, "\(version)")
            #expect(!read.entries.contains { if case .migrate = $0 { true } else { false } }, "\(version)")
            let (_, copied, diskVersion) = try EditSession.readDocumentWithDiskVersion(copy, take: nil, context: context)
            #expect(diskVersion == version)
            #expect(To3.state(copied) == To3.state(original))
            let reopened = try await To3.open(copy, To3.context(caches: dir.appending(path: "Caches")))
            #expect(reopened.access == .editable)
            #expect(To3.state(reopened.document) == To3.state(original))
            await reopened.close()
            #expect(try !To3.hasMigrate(copy), "\(version)")
            #expect(try To3.lines(copy) == before, "\(version)")
            #expect(try To3.snapshotVersion(copy) == version, "\(version)")

            // The retry writes the rest of the buffer: every line, once each, in order.
            io.heal()
            #expect(await eventually(timeout: .seconds(20)) { !session.hasUnsavedChanges })
            let last = 5 + migrates.count
            #expect(await session.flushed() == last)
            let lines = try To3.lines(url)
            #expect(lines.count == last)
            #expect(Array(lines.prefix(4)) == before)
            #expect(Array(lines.dropFirst(4).prefix(migrates.count)) == migrates)
            #expect(try To3.read(url).entries.map(\.seq) == Array(1...last))
            await session.close()
            #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == 3)
        }
    }
}

// MARK: - The log across the migrate to 3

@Test func revertedIsTheReplayedJSONAtVersion2() throws {
    let document = SmallDocument.document
    let create = EditLogEntry.create(seq: 1, document: document, app: To3.app)
    let padding = try #require(document.setChange("/style/padding", 0.1))
    let entries = [create, EditLogEntry.do(seq: 2, group: 2, label: EditLabel.padding.rawValue, changes: [padding], at: To3.date)]
    let replay = try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: 2))
    #expect(replay.mismatchSeq == nil)
    #expect(replay.version == 2)
    #expect(replay.document.documentVersion == 3)
    #expect(replay.document.style.padding == 0.1)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: replay.document), to: 2) == replay.json)
    #expect(try replay.json.decoded(as: EditDocument.self) == replay.document)
    // Of version 1 the same, through both steps.
    let fromV1 = try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: 1))
    #expect(fromV1.version == 1)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: fromV1.document), to: 1) == fromV1.json)
    #expect(fromV1.document == replay.document)
}

@Test func cutAtEveryByteOfTheFirstEditOpensBeforeOrAfterTo3() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let document = SmallDocument.document
        let create = EditLogEntry.create(seq: 1, document: document, app: To3.app)
        let padding = EditLogEntry.do(
            seq: 2, group: 2, label: EditLabel.padding.rawValue, changes: [try #require(document.setChange("/style/padding", 0.1))],
            at: To3.date)
        for version in [2, 1] {
            // A project of 1c (or 1b) with one step, and the first edit in phase 2: its migrates and its step, in one buffer.
            let head = Array(try [create, padding].map { try $0.jsonLine(writingDocumentAt: version) + "\n" }.joined().utf8)
            let migrates: [EditLogEntry] =
                version == 2 ? [.migrate(seq: 3, from: 2, to: 3)] : [.migrate(seq: 3, from: 1, to: 2), .migrate(seq: 4, from: 2, to: 3)]
            let captions = EditLogEntry.do(
                seq: 3 + migrates.count, group: 3 + migrates.count, label: EditLabel.captionsShow.rawValue,
                changes: [.set(path: try JSONPointer("/captions/show"), before: .bool(false), after: .bool(true))], at: To3.date)
            let firstEdit = migrates + [captions]
            let buffer = Array(try firstEdit.map { try $0.jsonLine() + "\n" }.joined().utf8)
            let firstMigrate = try migrates[0].jsonLine().utf8.count
            let before = try #require(EditReplay.replay(snapshot: nil, entries: [create, padding], createVersion: version))
            let after = try #require(EditReplay.replay(snapshot: nil, entries: [create, padding] + firstEdit, createVersion: version))
            #expect(before.version == version)
            #expect(after.version == 3)
            #expect(after.document.captions.show)

            for length in 0...buffer.count {
                try Data(head + buffer.prefix(length)).write(to: url)
                let read = try EditLogReader.read(url)
                // The step is whole once all but its line break is there.
                let whole = length >= buffer.count - 1
                #expect(read.damagedLine == nil, "\(version) cut at \(length)")
                #expect(read.droppedTrailingMigrate == (length >= firstMigrate && !whole), "\(version) cut at \(length)")
                // Never a migrate without its step.
                #expect(read.entries.count == (whole ? 2 + firstEdit.count : 2), "\(version) cut at \(length)")
                let replayed = try #require(EditReplay.replay(snapshot: nil, entries: read.entries, createVersion: version))
                #expect(replayed.mismatchSeq == nil, "\(version) cut at \(length)")
                #expect(replayed.version == (whole ? 3 : version), "\(version) cut at \(length)")
                #expect(replayed.document == (whole ? after.document : before.document), "\(version) cut at \(length)")
                #expect(replayed.json == (whole ? after.json : before.json), "\(version) cut at \(length)")

                // Opened to edit: the file ends at the line before the first edit, or after it.
                #expect(
                    try EditLogReader.truncateIncompleteTail(url) == (length > 0 && length < buffer.count), "\(version) cut at \(length)")
                #expect(try SafeRead.regularFile(at: url) == Data(head + (whole ? buffer : [])), "\(version) cut at \(length)")
                #expect(try EditLogReader.read(url).entries == read.entries, "\(version) cut at \(length)")
            }
        }
    }
}

@Test func compactionKeepsTheV2CreateAndTheMigrate() throws {
    // A project of 1c (its create in version 2): 300 random operations with the migrate 2→3 of the first edit in phase 2
    // at the 150th, then three undos.
    let (editor, migrateSeq) = try edited(seed: 12)
    #expect(editor.history.done.contains { $0 < migrateSeq }, "done before the migrate")
    #expect(editor.history.undone.contains { $0 < migrateSeq }, "undone before the migrate")
    #expect((editor.history.done + editor.history.undone).contains { $0 > migrateSeq }, "groups from after it")

    let original = try #require(EditReplay.replay(snapshot: nil, entries: editor.entries, createVersion: 2))
    #expect(original.mismatchSeq == nil)
    #expect(original.version == 3)
    var expected = editor.document
    expected.logSequence = original.lastAppliedSeq
    #expect(original.document == expected)

    let compacted = LogCompaction.compact(editor.entries, createVersion: 2)
    #expect(compacted.count < editor.entries.count)
    #expect(compacted.first == SmallDocument.create)
    guard compacted.count > 1, case .migrate(_, 2, 3) = compacted[1] else {
        Issue.record("the migrate right after the create")
        return
    }
    #expect(compacted.dropFirst(2).allSatisfy { if case .migrate = $0 { false } else { true } })
    #expect(zip(compacted, compacted.dropFirst()).allSatisfy { $0.seq < $1.seq })
    #expect(compacted.last?.seq == editor.entries.last?.seq)

    // Written as the session writes it, its create in version 2, and read back.
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data(try compacted.map { try $0.jsonLine(writingDocumentAt: 2) + "\n" }.joined().utf8).write(to: url)
        let read = try EditLogReader.read(url)
        #expect(read.createVersion == 2)
        #expect(read.entries == compacted)
        #expect(!read.droppedTrailingMigrate)
    }

    let replayed = try #require(EditReplay.replay(snapshot: nil, entries: compacted, createVersion: 2))
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.document == original.document)
    #expect(replayed.json == original.json)
    #expect(replayed.version == 3)
    let history = UndoHistory(entries: compacted, createVersion: 2)
    #expect(history.done == editor.history.done)
    #expect(history.undone == editor.history.undone)
    #expect(history.undoLabel == editor.history.undoLabel)
    #expect(history.redoLabel == editor.history.redoLabel)
    #expect(history.nextSeq == UndoHistory(entries: editor.entries, createVersion: 2).nextSeq)

    // Undoing everything, across the migrate, and redoing everything goes through the same documents.
    let walked = try walkThroughTheHistory(compacted)
    #expect(try walked == walkThroughTheHistory(editor.entries))
    #expect(walked.count > 2)

    // With a create in version 3, that migrate does not follow: nothing is compacted.
    #expect(LogCompaction.compact(editor.entries) == editor.entries)
}

@Test func aVolumeStepOf1cIsCutByTheMigrateTo3() throws {
    // The volume of a track in 1c writes its whole `TrackGain`: the migration writes inside it (`cleanup`), so the undo
    // of that step after the migrate would not match. The migrate cuts the history before it, as every one did in 1b, and
    // the log is not compacted; the replay goes on.
    var document = SmallDocument.document
    document.audio.tracks["take-001/mic"] = TrackGain(gain: 1, muted: false)
    let create = EditLogEntry.create(seq: 1, document: document, app: To3.app)
    let change = EditChange.set(
        path: try JSONPointer("/audio/tracks/take-001~1mic"), before: .object(["gain": .integer(1), "muted": .bool(false)]),
        after: .object(["gain": .number(0.5), "muted": .bool(false)]))
    #expect(DocumentMigration.touchesAddedFields(change, from: 2))
    let volume = EditLogEntry.do(seq: 2, group: 2, label: EditLabel.volume.rawValue, changes: [change], at: To3.date)
    let captions = EditLogEntry.do(
        seq: 4, group: 4, label: EditLabel.captionsShow.rawValue,
        changes: [.set(path: try JSONPointer("/captions/show"), before: .bool(false), after: .bool(true))], at: To3.date)
    let log = [create, volume, .migrate(seq: 3, from: 2, to: 3), captions]
    #expect(UndoHistory(entries: [create, volume], createVersion: 2).done == [2])
    #expect(UndoHistory(entries: log, createVersion: 2).done == [4])
    #expect(LogCompaction.compact(log, createVersion: 2) == log)
    let replayed = try #require(EditReplay.replay(snapshot: nil, entries: log, createVersion: 2))
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.version == 3)
    #expect(replayed.document.audio.tracks["take-001/mic"] == TrackGain(gain: 0.5, muted: false))
    #expect(replayed.document.captions.show)
    #expect(try #require(EditReplay.replay(snapshot: nil, entries: log + [.undo(seq: 5, group: 2)], createVersion: 2)).mismatchSeq == 5)
    #expect(try #require(EditReplay.replay(snapshot: nil, entries: log + [.undo(seq: 5, group: 4)], createVersion: 2)).mismatchSeq == nil)
}

// MARK: - The labels and collections of phase 2

@Test func phase2LabelsAndCollections() {
    // Phase 2 design §8, after the 33 of phase 1: written in edit-log.jsonl, so they never change.
    let labels: [(EditLabel, String)] = [
        (.transcriptCreate, "transcript.create"), (.transcriptCut, "transcript.cut"), (.transcriptRestore, "transcript.restore"),
        (.transcriptWord, "transcript.word"), (.transcriptBreak, "transcript.break"), (.transcriptFillers, "transcript.fillers"),
        (.transcriptPauses, "transcript.pauses"), (.captionsShow, "captions.show"), (.captionsStyle, "captions.style"),
        (.cameraHideSilences, "camera.hideSilences"), (.cameraBackground, "camera.background"), (.cameraFraming, "camera.framing"),
        (.cameraLook, "camera.look"), (.cameraSync, "camera.sync"), (.audioCleanup, "audio.cleanup"),
        (.audioNormalize, "audio.normalize"), (.styleReframe, "style.reframe"), (.privacyAdd, "privacy.add"),
        (.privacyChange, "privacy.change"), (.privacyMove, "privacy.move"), (.privacyTrim, "privacy.trim"),
        (.privacyDelete, "privacy.delete"), (.privacyAuto, "privacy.auto"), (.keysOverlay, "keys.overlay"),
        (.speedTyping, "speed.typing"),
    ]
    #expect(labels.count == 25)
    for (label, raw) in labels {
        #expect(label.rawValue == raw)
        #expect(EditLabel(rawValue: raw) == label)
    }
    #expect(EditLabel.allCases.count == 33 + 25)
    #expect(Array(EditLabel.allCases.suffix(25)) == labels.map(\.0))
    #expect(EditCollection.privacyBlocks.rawValue == "/privacy/blocks")
    #expect(EditCollection.transcriptTakes.rawValue == "/transcript/takes")
}

// MARK: - Helpers

/// A session of 300 random operations on a project of 1c (its create in version 2), with the migrate of its first edit
/// in phase 2 at the 150th, then three undos; and the `seq` of the migrate.
private func edited(seed: UInt64) throws -> (editor: Editor, migrateSeq: Int) {
    var generator = SplitMix64(seed: seed)
    var editor = Editor(SmallDocument.document)
    var clock = To3.date
    var migrateSeq = 0
    for operation in 0..<300 {
        if operation == 150 {
            // The first edit in phase 2: its migrate and its step, together.
            migrateSeq = editor.history.nextSeq
            editor.migrate()
            clock += 2
            try editor.perform(try To3.captions(editor.document), at: clock)
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

/// An editor over `UndoHistory` the way the session uses it on a project of 1c (its create in version 2), with the
/// migrate of its first edit in phase 2.
private struct Editor {
    var history: UndoHistory
    private(set) var entries: [EditLogEntry]
    private(set) var document: EditDocument
    private var groups: [Int: [EditChange]] = [:]

    init(_ document: EditDocument) {
        history = UndoHistory(entries: [SmallDocument.create], createVersion: 2)
        entries = [SmallDocument.create]
        self.document = document
    }

    mutating func migrate() {
        append(.migrate(seq: history.nextSeq, from: 2, to: 3))
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

/// A step of 1c on `document` (the padding, the corners, a suppressed range, the camera mirrored), or, once `migrated`,
/// also one only version 3 has (the captions' style, the keys on screen, a cleanup); `nil` if it would change nothing.
private func randomStep(_ document: EditDocument, migrated: Bool, using generator: inout SplitMix64) -> EditStep? {
    let level = Double(Int.random(in: 0...20, using: &generator)) / 100
    switch Int.random(in: 0..<(migrated ? 7 : 4), using: &generator) {
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
        return document.setChange("/camera/mirror", !document.camera.mirror).map {
            EditStep(label: .cameraMirror, target: "/camera/mirror", changes: [$0])
        }
    case 4:
        return document.setChange("/captions/style/uppercase", !document.captions.style.uppercase).map {
            EditStep(label: .captionsStyle, target: "/captions/style/uppercase", changes: [$0])
        }
    case 5:
        let mode = KeyOverlayMode.allCases.randomElement(using: &generator) ?? .off
        return document.setChange("/keys/mode", mode).map { EditStep(label: .keysOverlay, target: "/keys/mode", changes: [$0]) }
    default:
        return document.setChange("/camera/syncOffset", Int64(level * 1e9)).map {
            EditStep(label: .cameraSync, target: "/camera/syncOffset", changes: [$0])
        }
    }
}

/// The documents met undoing every group of `entries` and then redoing every one, each line appended and replayed from
/// the document before it, its create in version 2.
private func walkThroughTheHistory(_ entries: [EditLogEntry]) throws -> [EditDocument] {
    var entries = entries
    var history = UndoHistory(entries: entries, createVersion: 2)
    let start = try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: 2))
    var document = start.document
    var version = start.version
    var documents = [document]
    func append(_ line: EditLogEntry) throws {
        entries.append(line)
        history.record(line)
        let replayed = try #require(
            EditReplay.replay(snapshot: document, snapshotVersion: version, entries: entries, createVersion: 2))
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
