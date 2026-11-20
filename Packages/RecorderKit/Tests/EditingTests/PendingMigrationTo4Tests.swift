// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share: a project of phase 2 (its edit document in `documentVersion` 3), of 1c (in 2) or
/// of 1b (in 1, `DocumentV1Fixture`) opened, looked at and edited in phase 3, whose document is of version 4 (phase 3
/// design §10). Since phases 4 and 5 the document is of version 5 (`InfoCommandsTests`): the first edit migrates it on to
/// 5 too.
private enum To4 {
    static let app = AppInfo(name: "Toma", version: "0.5.0")
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

    static func padding(_ document: EditDocument, _ value: Double) throws -> EditStep {
        EditStep(label: .padding, target: "/style/padding", changes: [try #require(document.setChange("/style/padding", value))])
    }

    /// The marker every first edit of phase 3 here adds.
    static let marker = Marker(id: "m-0000abcd", take: "take-001", t: HostTime(nanoseconds: 5_000_500_000_000), name: "Demo", origin: .added)

    /// The first edit of phase 3 here: a marker added, in a place only version 4 has.
    static func markers(_ document: EditDocument) -> EditStep {
        EditStep(label: .markerAdd, target: marker.id, changes: [document.insertChange(.markers, at: 0, marker)])
    }

    /// The same as a line of the log, at `seq`.
    static func markersLine(_ seq: Int) throws -> EditLogEntry {
        .do(
            seq: seq, group: seq, label: EditLabel.markerAdd.rawValue,
            changes: [.insert(collection: EditCollection.markers.pointer, index: 0, value: try JSONValue(encoding: marker))], at: date)
    }

    /// The `migrate` lines from `version` to the current one, from `seq` on.
    static func migrates(from version: Int, seq: Int) -> [EditLogEntry] {
        (version..<EditDocument.currentVersion).enumerated().map { offset, from in
            .migrate(seq: seq + offset, from: from, to: from + 1)
        }
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

    /// Whether `text` holds a member only version 4 writes.
    static func hasVersion4(_ text: String) -> Bool {
        ["\"annotations\"", "\"markers\"", "\"music\"", "\"audioShift\"", "\"ranges\"", "\"documentVersion\":4", "\"documentVersion\" : 4"]
            .contains { text.contains($0) }
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

    /// A project edited in phase 2 (`version` 3) or in 1c (`version` 2), as its app left it on disk: `DocumentV1Fixture`'s
    /// package and steps, with everything written in `documentVersion` `version` (`<directory>/v<version>-<steps>-<snapshotAt>.toma`).
    @concurrent static func writtenProject(_ version: Int, in directory: URL, steps: Int, snapshotAt: Int?) async throws -> URL {
        let builder = try TakeBuilder(in: directory, name: "v\(version)-\(steps)-\(snapshotAt.map(String.init) ?? "none")")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        let project = try builder.write()

        var document = EditDocument.legacy(for: project)
        document.logSequence = 1
        let app = AppInfo(name: "Toma", version: version == 3 ? "0.4.0" : "0.3.0")
        var lines = [try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine(writingDocumentAt: version)]
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
            let written = try #require(DocumentMigration.reverted(try JSONValue(encoding: taken), to: version))
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(written), to: project.package.editURL)
        }
        return project.package.url
    }

    /// A project of phase 2 (`version` 3), of 1c (2) or of 1b (1) with `steps` steps and its snapshot at `snapshotAt`.
    static func project(_ version: Int, in directory: URL, steps: Int, snapshotAt: Int?) async throws -> URL {
        version == 1
            ? try await DocumentV1Fixture.make(in: directory, steps: steps, snapshotAt: snapshotAt)
            : try await writtenProject(version, in: directory, steps: steps, snapshotAt: snapshotAt)
    }

    /// The system's calls, counting the writes (the bytes each one wrote). `cut(after:then:)` makes the next write stop
    /// after that many bytes and every write after it fail, until `heal()`: a disk that fills up in the middle of a write.
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

// MARK: - Opening a project of phase 1 or 2 writes nothing in version 4

@MainActor @Test func openingAVersion3ProjectWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let context = To4.context(caches: caches)

        // The snapshot at the last line: opened, read as the export reads it (`EditSession.readDocument`, which the
        // library's export and `recorder-dev export` use), played and closed without an edit: nothing written.
        let current = try await To4.writtenProject(3, in: dir, steps: 4, snapshotAt: 4)
        let unchanged = try treeHash(current)
        let looked = try await To4.open(current, context)
        #expect(looked.access == .editable)
        #expect(looked.notices.isEmpty)
        #expect(looked.document.documentVersion == EditDocument.currentVersion)
        #expect(looked.document.markers == .legacy && looked.document.annotations == .legacy && looked.document.music == .legacy)
        #expect(looked.document == (try To4.replay(current)).document)
        #expect(looked.undoLabel == .padding)
        #expect(!looked.documentIsCurrentOnDisk)
        let (_, exported, diskVersion) = try EditSession.readDocumentWithDiskVersion(current, take: nil, context: context)
        #expect(diskVersion == 3)
        #expect(exported == looked.document)
        #expect(try EditSession.readDocument(current, take: nil, context: context).1 == looked.document)
        #expect(try EditSession.readOutline(current, take: nil, context: context).1.diskVersion == 3)
        #expect(await looked.flushed() == 5)
        #expect(!looked.hasUnsavedChanges)
        await looked.close()
        #expect(try treeHash(current) == unchanged)

        // A tail of the log after the snapshot: the snapshot at closing catches up with it, in version 3, as the replay
        // gives its JSON before decoding it.
        let behind = try await To4.writtenProject(3, in: dir, steps: 4, snapshotAt: 1)
        let behindLog = try Data(contentsOf: To4.log(behind))
        let replayed = try To4.replay(behind)
        #expect(replayed.version == 3)
        let caught = try await To4.open(behind, context)
        #expect(caught.document == replayed.document)
        await caught.close()
        #expect(try To4.snapshotVersion(behind) == 3)
        #expect(try Data(contentsOf: To4.snapshot(behind)) == (try ProjectJSON.encoder().encode(replayed.json)))
        #expect(try Data(contentsOf: To4.log(behind)) == behindLog)
        #expect(!To4.hasVersion4(String(decoding: try Data(contentsOf: To4.snapshot(behind)), as: UTF8.self)))

        // A long log, past the compaction's threshold: compacted at opening and closing, with the `create` in version 3
        // and no `migrate`.
        let large = try await To4.writtenProject(3, in: dir, steps: 6, snapshotAt: 2)
        try To4.append(
            [try EditLogEntry.undo(seq: 8, group: 7).jsonLine(), try EditLogEntry.redo(seq: 9, group: 7).jsonLine()]
                .map { $0 + "\n" }.joined(),
            to: large)
        let uncompacted = try To4.replay(large)
        let compacting = To4.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 5))
        let large1 = try await To4.open(large, compacting)
        #expect(large1.document == uncompacted.document)
        await large1.close()
        let compacted = try To4.read(large)
        #expect(compacted.createVersion == 3)
        #expect(compacted.entries.count == 7)
        #expect(compacted.entries.last?.seq == 9)
        #expect(try !To4.hasMigrate(large))
        #expect(try To4.snapshotVersion(large) == 3)
        #expect(try Data(contentsOf: To4.snapshot(large)) == (try ProjectJSON.encoder().encode(To4.replay(large).json)))
        #expect(try To4.replay(large).json == uncompacted.json)
        #expect(try !To4.lines(large).contains { To4.hasVersion4($0) })

        // A last line cut short: truncated, and everything written is in version 3.
        let cut = try await To4.writtenProject(3, in: dir, steps: 4, snapshotAt: 2)
        let whole = try Data(contentsOf: To4.log(cut))
        try To4.append(#"{"at":"2026-11-15T2"#, to: cut)
        let cutShort = try await To4.open(cut, context)
        #expect(cutShort.access == .editable)
        #expect(try Data(contentsOf: To4.log(cut)) == whole)
        await cutShort.close()
        #expect(try Data(contentsOf: To4.log(cut)) == whole)
        #expect(try To4.read(cut).createVersion == 3)
        #expect(try To4.snapshotVersion(cut) == 3)
    }
}

@MainActor @Test func openingVersion1And2ProjectsWriteNothing() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let context = To4.context(caches: caches)
        for version in [2, 1] {
            for snapshotAt in [3, 1] {
                let url = try await To4.project(version, in: dir, steps: 3, snapshotAt: snapshotAt)
                let replayed = try To4.replay(url)
                #expect(replayed.version == version)
                let unchanged = try treeHash(url)
                let log = try Data(contentsOf: To4.log(url))
                let session = try await To4.open(url, context)
                #expect(session.access == .editable)
                #expect(session.notices.isEmpty)
                #expect(session.document.documentVersion == EditDocument.currentVersion)
                #expect(session.document == replayed.document)
                #expect(!session.documentIsCurrentOnDisk)
                let (_, exported, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
                #expect(diskVersion == version)
                #expect(exported == session.document)
                #expect(try EditSession.readOutline(url, take: nil, context: context).1.diskVersion == version)
                await session.close()
                #expect(try Data(contentsOf: To4.log(url)) == log, "\(version) \(snapshotAt)")
                #expect(try To4.snapshotVersion(url) == version, "\(version) \(snapshotAt)")
                #expect(try Data(contentsOf: To4.snapshot(url)) == (try ProjectJSON.encoder().encode(replayed.json)))
                #expect(!To4.hasVersion4(String(decoding: try Data(contentsOf: To4.snapshot(url)), as: UTF8.self)))
                #expect(try !To4.lines(url).contains { To4.hasVersion4($0) })
                if snapshotAt == 3 {
                    #expect(try treeHash(url) == unchanged, "\(version)")
                }
            }
            // A long log of 1c or 1b, compacted at opening and closing: in its version, without a `migrate`.
            let large = try await To4.project(version, in: dir, steps: 6, snapshotAt: 6)
            let uncompacted = try To4.replay(large)
            let compacting = To4.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 4))
            let opened = try await To4.open(large, compacting)
            #expect(opened.document == uncompacted.document)
            await opened.close()
            #expect(try To4.read(large).createVersion == version)
            #expect(try !To4.hasMigrate(large))
            #expect(try To4.snapshotVersion(large) == version)
            #expect(try To4.replay(large).json == uncompacted.json)
            #expect(try !To4.lines(large).contains { To4.hasVersion4($0) })
        }
    }
}

// MARK: - The first edit

@MainActor @Test func firstEditWritesEveryMigrateAndTheStepInOneWrite() async throws {
    try await withTemporaryDirectory { dir in
        for version in [3, 2, 1] {
            let url = try await To4.project(version, in: dir, steps: 3, snapshotAt: 3)
            let before = try To4.lines(url)
            let io = To4.IO()
            let session = try await To4.open(url, To4.context(caches: dir.appending(path: "Caches"), io: io.io))
            #expect(io.writes.isEmpty)
            #expect(session.perform(To4.markers(session.document)) == .applied)
            #expect(session.document.markers.items == [To4.marker])
            // The migrates, one for each version up to the current one, and the step.
            let migrates = To4.migrates(from: version, seq: 5)
            #expect(migrates.count == EditDocument.currentVersion - version)
            let last = 5 + migrates.count
            #expect(await session.flushed() == last, "\(version)")

            let lines = try To4.lines(url)
            #expect(Array(lines.prefix(4)) == before, "\(version)")
            #expect(lines.count == last, "\(version)")
            let entries = try To4.read(url).entries
            #expect(Array(entries.dropFirst(4).dropLast()) == migrates, "\(version)")
            if case let .do(seq, group, label, _, _)? = entries.last {
                #expect((seq, group, label) == (last, last, "marker.add"), "\(version)")
            } else {
                Issue.record("no do line: \(entries)")
            }
            // One write with every line.
            #expect(io.writes.count == 1, "\(version)")
            #expect(io.writes.first == Array(lines.dropFirst(4).map { $0 + "\n" }.joined().utf8), "\(version)")
            #expect(try To4.read(url).createVersion == version, "\(version)")
            #expect(try To4.replay(url).version == EditDocument.currentVersion, "\(version)")
            #expect(try To4.replay(url).document.markers.items == [To4.marker], "\(version)")

            // The snapshot after it is of version 4.
            await session.close()
            #expect(try To4.snapshotVersion(url) == EditDocument.currentVersion, "\(version)")
            #expect(try EditDocument.decode(Data(contentsOf: To4.snapshot(url))) == session.document, "\(version)")
            #expect(try To4.lines(url) == lines, "\(version)")
            let context = To4.context(caches: dir)
            #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == EditDocument.currentVersion, "\(version)")
            let again = try await To4.open(url, To4.context(caches: dir.appending(path: "Caches")))
            #expect(again.documentIsCurrentOnDisk, "\(version)")
            #expect(again.document.markers.items == [To4.marker], "\(version)")
            await again.close()
        }
    }
}

@MainActor @Test func undoCrossesTheMigrationTo4() async throws {
    try await withTemporaryDirectory { dir in
        for version in [3, 1] {
            // A project of phase 2 (or of 1b) with a step of its own (the padding), and the first edit in phase 3: a marker.
            let url = try await To4.project(version, in: dir, steps: 1, snapshotAt: 1)
            let created = try To4.created(url)
            let caches = dir.appending(path: "Caches")
            let session = try await To4.open(url, To4.context(caches: caches))
            #expect(session.undoLabel == .padding)
            let padded = To4.state(session.document)
            #expect(session.perform(To4.markers(session.document)) == .applied)
            #expect(session.document.markers.items == [To4.marker])
            // Two undos bring back both: no marker, then the padding of the create, never "unmigrated".
            #expect(session.undoLabel == .markerAdd)
            #expect(session.undo() == .applied)
            #expect(To4.state(session.document) == padded)
            #expect(session.undo() == .applied)
            #expect(To4.state(session.document) == To4.state(created))
            #expect(session.document.documentVersion == EditDocument.currentVersion)
            #expect(session.undo() == .refused)
            let last = 3 + (EditDocument.currentVersion - version) + 2
            #expect(await session.flushed() == last, "\(version)")
            let undone = session.document
            await session.close()

            // The replay gives the same, and both come back.
            #expect(To4.state(try To4.replay(url).document) == To4.state(undone), "\(version)")
            #expect(try To4.replay(url).version == EditDocument.currentVersion, "\(version)")
            let again = try await To4.open(url, To4.context(caches: caches))
            #expect(To4.state(again.document) == To4.state(undone), "\(version)")
            #expect(again.redoLabel == .padding, "\(version)")
            #expect(again.redo() == .applied)
            #expect(To4.state(again.document) == padded, "\(version)")
            #expect(again.redo() == .applied)
            #expect(again.document.markers.items == [To4.marker], "\(version)")
            await again.close()
        }
    }
}

@MainActor @Test func diskFullOnTheFirstEditTo4NeverLeavesMigrateAlone() async throws {
    try await withTemporaryDirectory { dir in
        for version in [3, 1] {
            let url = try await To4.project(version, in: dir, steps: 3, snapshotAt: 3)
            let before = try To4.lines(url)
            let io = To4.IO()
            let context = To4.context(caches: dir.appending(path: "Caches"), io: io.io)
            let session = try await To4.open(url, context)
            let original = session.document
            let migrates = try To4.migrates(from: version, seq: 5).map { try $0.jsonLine() }
            let migrateBytes = migrates.map { $0 + "\n" }.joined().utf8.count
            // The disk fills up in the middle of the buffer: right after the last migrate, or inside it.
            io.cut(after: version == 3 ? migrateBytes : migrateBytes - 3, then: .ENOSPC)
            #expect(session.perform(To4.markers(session.document)) == .applied)
            #expect(await session.flushed() == 4)
            #expect(await eventually { session.notices.contains(.saveFailed(.ENOSPC)) })
            #expect(session.hasUnsavedChanges)

            // A copy of the package as it is now, as a crash would leave it, opens as it was: no migrate at the end, the
            // document of before, in its version.
            let copy = dir.appending(path: "Copy-\(version).toma", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: url, to: copy)
            let read = try To4.read(copy)
            #expect(read.entries.count == 4, "\(version)")
            #expect(!read.entries.contains { if case .migrate = $0 { true } else { false } }, "\(version)")
            let (_, copied, diskVersion) = try EditSession.readDocumentWithDiskVersion(copy, take: nil, context: context)
            #expect(diskVersion == version)
            #expect(To4.state(copied) == To4.state(original))
            let reopened = try await To4.open(copy, To4.context(caches: dir.appending(path: "Caches")))
            #expect(reopened.access == .editable)
            #expect(To4.state(reopened.document) == To4.state(original))
            await reopened.close()
            #expect(try !To4.hasMigrate(copy), "\(version)")
            #expect(try To4.lines(copy) == before, "\(version)")
            #expect(try To4.snapshotVersion(copy) == version, "\(version)")

            // The retry writes the rest of the buffer: every line, once each, in order.
            io.heal()
            #expect(await eventually(timeout: .seconds(20)) { !session.hasUnsavedChanges })
            let last = 5 + migrates.count
            #expect(await session.flushed() == last)
            let lines = try To4.lines(url)
            #expect(lines.count == last)
            #expect(Array(lines.prefix(4)) == before)
            #expect(Array(lines.dropFirst(4).prefix(migrates.count)) == migrates)
            #expect(try To4.read(url).entries.map(\.seq) == Array(1...last))
            await session.close()
            #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == EditDocument.currentVersion)
        }
    }
}

@MainActor @Test func aTakeNeverEditedStaysOfVersion2UntilItsFirstEditTo4() async throws {
    try await withTemporaryDirectory { dir in
        // A take that no editor opened: its first opening writes the new document's `create` and snapshot in version 2,
        // which phases 1 and 2 open; its first edit writes the migrates to 3 and to 4 with the step.
        let builder = try TakeBuilder(in: dir, name: "Recorded")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        let url = try builder.write().package.url
        let caches = dir.appending(path: "Caches")
        let looked = try await To4.open(url, To4.context(caches: caches))
        #expect(looked.document.documentVersion == EditDocument.currentVersion)
        await looked.close()
        #expect(try To4.read(url).createVersion == 2)
        #expect(try To4.snapshotVersion(url) == 2)
        #expect(!To4.hasVersion4(String(decoding: try Data(contentsOf: To4.snapshot(url)), as: UTF8.self)))
        let session = try await To4.open(url, To4.context(caches: caches))
        #expect(session.perform(To4.markers(session.document)) == .applied)
        #expect(await session.flushed() == 5)
        let entries = try To4.read(url).entries
        #expect(Array(entries[1...3]) == To4.migrates(from: 2, seq: 2))
        await session.close()
        #expect(try To4.snapshotVersion(url) == EditDocument.currentVersion)
        #expect(try To4.read(url).createVersion == 2)

        // A new document that version 3 cannot hold (a default style whose automatic zooms dim) starts in version 4.
        let other = try TakeBuilder(in: dir, name: "Dimming")
        try await other.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        let dimming = try other.write().package.url
        var style = DefaultStyle.toma
        style.zoomAuto.mode = .dim
        let context = EditContext(app: To4.app, cachesRoot: caches, defaultStyle: style, now: { To4.date }, makeID: { $0 + "00000001" })
        let new = try await EditSession.open(dimming, take: nil, context: context)
        #expect(new.document.zoom.auto.mode == .dim)
        await new.close()
        #expect(try To4.read(dimming).createVersion == 4)
        #expect(try To4.snapshotVersion(dimming) == 4)
    }
}

// MARK: - The log across the migrate to 4

@Test func revertedIsTheReplayedJSONAtVersion3() throws {
    let document = SmallDocument.document
    let create = EditLogEntry.create(seq: 1, document: document, app: To4.app)
    let padding = try #require(document.setChange("/style/padding", 0.1))
    let entries = [create, EditLogEntry.do(seq: 2, group: 2, label: EditLabel.padding.rawValue, changes: [padding], at: To4.date)]
    for version in [3, 2, 1] {
        let replay = try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: version))
        #expect(replay.mismatchSeq == nil)
        #expect(replay.version == version)
        #expect(replay.document.documentVersion == EditDocument.currentVersion)
        #expect(replay.document.style.padding == 0.1)
        #expect(DocumentMigration.reverted(try JSONValue(encoding: replay.document), to: version) == replay.json)
        #expect(try replay.json.decoded(as: EditDocument.self) == replay.document)
    }
}

@Test func cutAtEveryByteOfTheFirstEditOpensBeforeOrAfterTo4() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let document = SmallDocument.document
        let create = EditLogEntry.create(seq: 1, document: document, app: To4.app)
        let padding = EditLogEntry.do(
            seq: 2, group: 2, label: EditLabel.padding.rawValue, changes: [try #require(document.setChange("/style/padding", 0.1))],
            at: To4.date)
        for version in [3, 2, 1] {
            // A project of phase 2 (or 1c, or 1b) with one step, and the first edit in phase 3: its migrates and its step,
            // in one buffer.
            let head = Array(try [create, padding].map { try $0.jsonLine(writingDocumentAt: version) + "\n" }.joined().utf8)
            let migrates = To4.migrates(from: version, seq: 3)
            let firstEdit = migrates + [try To4.markersLine(3 + migrates.count)]
            let buffer = Array(try firstEdit.map { try $0.jsonLine() + "\n" }.joined().utf8)
            let firstMigrate = try migrates[0].jsonLine().utf8.count
            let before = try #require(EditReplay.replay(snapshot: nil, entries: [create, padding], createVersion: version))
            let after = try #require(EditReplay.replay(snapshot: nil, entries: [create, padding] + firstEdit, createVersion: version))
            #expect(before.version == version)
            #expect(after.version == EditDocument.currentVersion)
            #expect(after.mismatchSeq == nil)
            #expect(after.document.markers.items == [To4.marker])

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
                #expect(replayed.version == (whole ? EditDocument.currentVersion : version), "\(version) cut at \(length)")
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

@Test func compactionKeepsTheV3CreateAndTheMigrate() throws {
    // A project of phase 2 (its create in version 3): 300 random operations with the migrate 3→4 of the first edit in
    // phase 3 at the 150th, then three undos.
    let (editor, migrateSeq) = try edited(seed: 17)
    #expect(editor.history.done.contains { $0 < migrateSeq }, "done before the migrate")
    #expect(editor.history.undone.contains { $0 < migrateSeq }, "undone before the migrate")
    #expect((editor.history.done + editor.history.undone).contains { $0 > migrateSeq }, "groups from after it")

    let original = try #require(EditReplay.replay(snapshot: nil, entries: editor.entries, createVersion: 3))
    #expect(original.mismatchSeq == nil)
    #expect(original.version == 4)
    var expected = editor.document
    expected.logSequence = original.lastAppliedSeq
    #expect(original.document == expected)

    let compacted = LogCompaction.compact(editor.entries, createVersion: 3)
    #expect(compacted.count < editor.entries.count)
    #expect(compacted.first == SmallDocument.create)
    guard compacted.count > 1, case .migrate(_, 3, 4) = compacted[1] else {
        Issue.record("the migrate right after the create")
        return
    }
    #expect(compacted.dropFirst(2).allSatisfy { if case .migrate = $0 { false } else { true } })
    #expect(zip(compacted, compacted.dropFirst()).allSatisfy { $0.seq < $1.seq })
    #expect(compacted.last?.seq == editor.entries.last?.seq)

    // Written as the session writes it, its create in version 3, and read back.
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data(try compacted.map { try $0.jsonLine(writingDocumentAt: 3) + "\n" }.joined().utf8).write(to: url)
        let read = try EditLogReader.read(url)
        #expect(read.createVersion == 3)
        #expect(read.entries == compacted)
        #expect(!read.droppedTrailingMigrate)
    }

    let replayed = try #require(EditReplay.replay(snapshot: nil, entries: compacted, createVersion: 3))
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.document == original.document)
    #expect(replayed.json == original.json)
    #expect(replayed.version == 4)
    let history = UndoHistory(entries: compacted, createVersion: 3)
    #expect(history.done == editor.history.done)
    #expect(history.undone == editor.history.undone)
    #expect(history.undoLabel == editor.history.undoLabel)
    #expect(history.redoLabel == editor.history.redoLabel)
    #expect(history.nextSeq == UndoHistory(entries: editor.entries, createVersion: 3).nextSeq)

    // Undoing everything, across the migrate, and redoing everything goes through the same documents.
    let walked = try walkThroughTheHistory(compacted)
    #expect(try walked == walkThroughTheHistory(editor.entries))
    #expect(walked.count > 2)

    // With a create in version 4, that migrate does not follow: nothing is compacted.
    #expect(LogCompaction.compact(editor.entries) == editor.entries)
}

// MARK: - Whole objects of phase 2 across the migrate to 4

/// The lines of phase 2 that write a whole object the migration to 4 extends, in version 3 as phase 2 writes them: a
/// clip of the sequence (without `audioShift`), a track's volume (its `TrackGain`, without `ranges`) and the automatic
/// zoom's settings of an applied style (`/zoom/auto`, without `mode`).
private enum WholeObjects {
    /// `SmallDocument`'s with the microphone of its take at gain 1, as a create of phase 2 holds it.
    static let document: EditDocument = {
        var document = SmallDocument.document
        document.audio.tracks["take-001/mic"] = TrackGain(gain: 1, muted: false)
        return document
    }()

    static let create = EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.4.0"))

    /// `document` in version 3.
    static var v3: JSONValue {
        get throws { try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 3)) }
    }

    /// The value at `pointer` of `json`.
    static func value(_ json: JSONValue, _ pointer: String) throws -> JSONValue {
        guard let components = try? JSONPointer(pointer).components else { throw TestSupportError.missing(pointer) }
        var value = json
        for component in components {
            switch value {
            case let .object(members):
                guard let member = members[component] else { throw TestSupportError.missing(pointer) }
                value = member
            case let .array(elements):
                guard let index = Int(component), elements.indices.contains(index) else { throw TestSupportError.missing(pointer) }
                value = elements[index]
            default:
                throw TestSupportError.missing(pointer)
            }
        }
        return value
    }

    static func with(_ value: JSONValue, _ key: String, _ member: JSONValue) -> JSONValue {
        guard case var .object(members) = value else { return value }
        members[key] = member
        return .object(members)
    }

    /// The clip split at 5 000 ns as phase 2 does it: the clip replaced by its first half, its second half inserted.
    static func split(_ seq: Int) throws -> EditLogEntry {
        let clip = try value(v3, "/sequence/0")
        let first = with(clip, "end", .integer(5_000))
        let second = with(with(clip, "start", .integer(5_000)), "id", .string("c-00000002"))
        return .do(
            seq: seq, group: seq, label: EditLabel.split.rawValue,
            changes: [
                .replace(collection: EditCollection.sequence.pointer, id: "c-00000001", before: clip, after: first),
                .insert(collection: EditCollection.sequence.pointer, index: 1, value: second),
            ], at: To4.date)
    }

    /// The microphone at 50 %, its whole `TrackGain` from `gain` to 0.5.
    static func volume(_ seq: Int) throws -> EditLogEntry {
        let path = "/audio/tracks/take-001~1mic"
        let before = try value(v3, path)
        return .do(
            seq: seq, group: seq, label: EditLabel.volume.rawValue,
            changes: [.set(path: try JSONPointer(path), before: before, after: with(before, "gain", .number(0.5)))], at: To4.date)
    }

    /// The automatic zoom of Toma's style applied, the whole `/zoom/auto` in version 3.
    static func autoZoom(_ seq: Int) throws -> EditLogEntry {
        let before = try value(v3, "/zoom/auto")
        guard case var .object(members) = try JSONValue(encoding: DefaultStyle.toma.zoomAuto) else {
            throw TestSupportError.missing("the zoom's settings")
        }
        members["mode"] = nil
        members["followsFocus"] = nil
        return .do(
            seq: seq, group: seq, label: EditLabel.styleApply.rawValue,
            changes: [.set(path: try JSONPointer("/zoom/auto"), before: before, after: .object(members))], at: To4.date)
    }

    static func replay(_ entries: [EditLogEntry]) throws -> EditReplay {
        try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: 3))
    }

    /// `document` at another line of the log.
    static func state(_ document: EditDocument) -> EditDocument {
        var document = document
        document.logSequence = 0
        return document
    }
}

@Test func wholeObjectsOfPhase2AreUndoneAcrossTheMigrateTo4() throws {
    // A split, a volume and an applied style of phase 2 write whole objects the migration writes inside of (`audioShift`,
    // `ranges`, `mode`): carried through the migrate, so the history is kept and their undo after it matches.
    let split = try WholeObjects.split(2), volume = try WholeObjects.volume(3), autoZoom = try WholeObjects.autoZoom(4)
    for line in [split, volume, autoZoom] {
        guard case let .do(_, _, _, changes, _) = line else { continue }
        #expect(changes.allSatisfy { !DocumentMigration.touchesAddedFields($0, from: 3) })
    }
    let log = [WholeObjects.create, split, volume, autoZoom, .migrate(seq: 5, from: 3, to: 4), try To4.markersLine(6)]
    let history = UndoHistory(entries: log, createVersion: 3)
    #expect(history.done == [2, 3, 4, 6])
    #expect(history.undoLabel == .markerAdd)
    let replayed = try WholeObjects.replay(log)
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.version == 4)
    #expect(replayed.document.sequence.count == 2)
    #expect(replayed.document.sequence.allSatisfy { $0.audioShift == 0 && $0.content == nil })
    #expect(replayed.document.audio.tracks["take-001/mic"] == TrackGain(gain: 0.5, muted: false))
    #expect(replayed.document.zoom.auto == DefaultStyle.toma.zoomAuto)
    #expect(replayed.document.markers.items == [To4.marker])
    // In version 4: the log has no migrate to 5.
    #expect(replayed.json == DocumentMigration.reverted(try JSONValue(encoding: replayed.document), to: 4))
    // Every one undone, in order, back to the create's document; and every one redone.
    let undos: [EditLogEntry] = [.undo(seq: 7, group: 6), .undo(seq: 8, group: 4), .undo(seq: 9, group: 3), .undo(seq: 10, group: 2)]
    let undone = try WholeObjects.replay(log + undos)
    #expect(undone.mismatchSeq == nil)
    #expect(WholeObjects.state(undone.document) == WholeObjects.state(WholeObjects.document))
    #expect(undone.json == DocumentMigration.reverted(try JSONValue(encoding: undone.document), to: 4))
    let redos: [EditLogEntry] = [.redo(seq: 11, group: 2), .redo(seq: 12, group: 3), .redo(seq: 13, group: 4), .redo(seq: 14, group: 6)]
    let redone = try WholeObjects.replay(log + undos + redos)
    #expect(redone.mismatchSeq == nil)
    #expect(WholeObjects.state(redone.document) == WholeObjects.state(replayed.document))

    // Compacted: the groups of before the migrate go after it, carried, and replay to the same document.
    let compacted = LogCompaction.compact(log + undos + redos, createVersion: 3)
    #expect(compacted.count < (log + undos + redos).count)
    guard compacted.count > 1, case .migrate(_, 3, 4) = compacted[1] else {
        Issue.record("the migrate right after the create: \(compacted)")
        return
    }
    let fromCompacted = try WholeObjects.replay(compacted)
    #expect(fromCompacted.mismatchSeq == nil)
    #expect(fromCompacted.document == redone.document)
    #expect(fromCompacted.json == redone.json)
    #expect(UndoHistory(entries: compacted, createVersion: 3).done == UndoHistory(entries: log + undos + redos, createVersion: 3).done)
}

@MainActor @Test func undoAfterTheFirstEditReachesTheWholeObjectsOfPhase2() async throws {
    try await withTemporaryDirectory { dir in
        // A project of phase 2 whose log has a split and a track's volume, its snapshot at the last line, in version 3.
        let builder = try TakeBuilder(in: dir, name: "p2-whole")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.audio.tracks["take-001/mic"] = TrackGain(gain: 1, muted: false)
        document.logSequence = 1
        let v3 = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 3))
        let clip = try WholeObjects.value(v3, "/sequence/0")
        let middle = Int64(base.nanoseconds + 500_000_000)
        let first = WholeObjects.with(clip, "end", .integer(middle))
        let second = WholeObjects.with(WholeObjects.with(clip, "start", .integer(middle)), "id", .string("c-00000002"))
        let track = try WholeObjects.value(v3, "/audio/tracks/take-001~1mic")
        let lines: [EditLogEntry] = [
            .create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.4.0")),
            .do(
                seq: 2, group: 2, label: EditLabel.split.rawValue,
                changes: [
                    .replace(collection: EditCollection.sequence.pointer, id: "c-00000001", before: clip, after: first),
                    .insert(collection: EditCollection.sequence.pointer, index: 1, value: second),
                ], at: To4.date),
            .do(
                seq: 3, group: 3, label: EditLabel.volume.rawValue,
                changes: [
                    .set(
                        path: try JSONPointer("/audio/tracks/take-001~1mic"), before: track,
                        after: WholeObjects.with(track, "gain", .number(0.5)))
                ], at: To4.date),
        ]
        let url = project.package.url
        try DurableFile.writeAtomically(
            Data(try lines.map { try $0.jsonLine(writingDocumentAt: 3) + "\n" }.joined().utf8), to: project.package.editLogURL)
        let last = try #require(EditReplay.replay(snapshot: nil, entries: lines, createVersion: 3))
        #expect(last.mismatchSeq == nil && last.version == 3)
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(last.json), to: project.package.editURL)

        let caches = dir.appending(path: "Caches")
        // Before the first edit, the Edit menu offers the undo of the volume: its changes are carried in memory.
        let session = try await To4.open(url, To4.context(caches: caches))
        #expect(session.notices.isEmpty)
        #expect(session.undoLabel == .volume)
        #expect(session.canUndo)
        #expect(session.document.sequence.count == 2)
        #expect(session.perform(To4.markers(session.document)) == .applied)
        // After it, every step of phase 2 comes back, in order, to the create's document.
        #expect(session.undo() == .applied)
        #expect(session.document.markers == .legacy)
        #expect(session.undo() == .applied)
        #expect(session.document.audio.tracks["take-001/mic"] == TrackGain(gain: 1, muted: false))
        #expect(session.undo() == .applied)
        #expect(session.document.sequence.count == 1)
        #expect(To4.state(session.document) == To4.state(document))
        #expect(session.undo() == .refused)
        // A redo and its undo, which the compaction drops.
        #expect(session.redo() == .applied)
        #expect(session.undo() == .applied)
        #expect(await session.flushed() == 11)
        await session.close()
        #expect(To4.state(try To4.replay(url).document) == To4.state(document))

        // Reopened, compacted on the way (its create in version 3, the migrate right after it), and redone.
        let compacting = To4.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 3))
        let again = try await To4.open(url, compacting)
        #expect(again.notices.isEmpty)
        let read = try To4.read(url)
        #expect(read.createVersion == 3)
        #expect(read.entries.count < 10)
        if read.entries.count > 1, case .migrate(_, 3, 4) = read.entries[1] {} else { Issue.record("the migrate after the create: \(read.entries)") }
        #expect(To4.state(again.document) == To4.state(document))
        #expect(again.redoLabel == .split)
        #expect(again.redo() == .applied)
        #expect(again.redo() == .applied)
        #expect(again.redo() == .applied)
        #expect(again.document.sequence.count == 2)
        #expect(again.document.audio.tracks["take-001/mic"] == TrackGain(gain: 0.5, muted: false))
        #expect(again.document.markers.items == [To4.marker])
        #expect(again.redo() == .refused)
        await again.close()
    }
}

// MARK: - The labels and collections of phase 3

@Test func phase3LabelsAndCollections() {
    // Phase 3 design §10, after the 33 of phase 1 and the 25 of phase 2: written in edit-log.jsonl, so they never change.
    let labels: [(EditLabel, String)] = [
        (.annotationAdd, "annotation.add"), (.annotationChange, "annotation.change"), (.annotationMove, "annotation.move"),
        (.annotationTrim, "annotation.trim"), (.annotationLayer, "annotation.layer"), (.annotationDelete, "annotation.delete"),
        (.clipFreeze, "clip.freeze"), (.clipCard, "clip.card"), (.clipMedia, "clip.media"), (.clipContent, "clip.content"),
        (.zoomMode, "zoom.mode"), (.audioRange, "audio.range"), (.audioShift, "audio.shift"), (.musicAdd, "music.add"),
        (.musicChange, "music.change"), (.musicMove, "music.move"), (.musicTrim, "music.trim"), (.musicDelete, "music.delete"),
        (.musicDucking, "music.ducking"), (.takeRerecord, "take.rerecord"), (.takeUse, "take.use"), (.markerAdd, "marker.add"),
        (.markerRename, "marker.rename"), (.markerMove, "marker.move"), (.markerDelete, "marker.delete"),
    ]
    #expect(labels.count == 25)
    for (label, raw) in labels {
        #expect(label.rawValue == raw)
        #expect(EditLabel(rawValue: raw) == label)
    }
    // And after them, the 2 of phases 4 and 5 (`InfoCommandsTests`) and `marker.chapters` (5b).
    #expect(EditLabel.allCases.count == 33 + 25 + 25 + 2 + 1)
    #expect(Array(EditLabel.allCases[(33 + 25)..<(33 + 25 + 25)]) == labels.map(\.0))
    // The labels of before, the same.
    #expect(EditLabel.allCases.first == .split)
    #expect(EditLabel.allCases[33 + 24] == .speedTyping)
    #expect(EditLabel.zoomAdd.rawValue == "zoom.add" && EditLabel.speedTyping.rawValue == "speed.typing")
    // The collections, the ones of before with the same raw values.
    #expect(EditCollection.annotations.rawValue == "/annotations/items")
    #expect(EditCollection.music.rawValue == "/music/items")
    #expect(EditCollection.markers.rawValue == "/markers/items")
    let ranges = EditCollection.gainRanges(track: "take-001/mic")
    #expect(ranges.rawValue == "/audio/tracks/take-001~1mic/ranges")
    #expect(ranges.pointer.components == ["audio", "tracks", "take-001/mic", "ranges"])
    let before: [(EditCollection, String)] = [
        (.sequence, "/sequence"), (.zoomRegions, "/zoom/regions"), (.zoomSuppressed, "/zoom/suppressed"),
        (.cameraChanges, "/camera/changes"), (.screenChanges, "/screens/changes"), (.cameraLayouts, "/camera/layouts"),
        (.privacyBlocks, "/privacy/blocks"), (.transcriptTakes, "/transcript/takes"),
    ]
    for (collection, raw) in before {
        #expect(collection.rawValue == raw)
        #expect(EditCollection(rawValue: raw) == collection)
        #expect(collection.pointer == (try? JSONPointer(raw)))
    }
    #expect(EditCollection(rawValue: "") == nil)
    #expect(EditCollection(rawValue: "sequence") == nil)
}

// MARK: - What the editor may do by itself

/// Only a document of version 4 on disk is: an untouched project of phase 2, 1c or 1b is not until its first edit, and
/// then is.
@MainActor @Test func theDocumentIsCurrentOnDiskOnlyOnceVersion4IsWritten() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        for version in [3, 2, 1] {
            let url = try await To4.project(version, in: dir, steps: 2, snapshotAt: 2)
            let session = try await To4.open(url, To4.context(caches: caches))
            #expect(!session.documentIsCurrentOnDisk, "\(version)")
            #expect(session.perform(try To4.padding(session.document, 0.1)) == .applied)
            #expect(session.documentIsCurrentOnDisk, "\(version)")
            await session.close()
            #expect(try To4.snapshotVersion(url) == EditDocument.currentVersion, "\(version)")
            let again = try await To4.open(url, To4.context(caches: caches))
            #expect(again.documentIsCurrentOnDisk, "\(version)")
            await again.close()
        }
    }
}


// MARK: - Helpers

/// A session of 300 random operations on a project of phase 2 (its create in version 3), with the migrate of its first
/// edit in phase 3 at the 150th, then three undos; and the `seq` of the migrate.
private func edited(seed: UInt64) throws -> (editor: Editor, migrateSeq: Int) {
    var generator = SplitMix64(seed: seed)
    var editor = Editor(SmallDocument.document)
    var clock = To4.date
    var migrateSeq = 0
    for operation in 0..<300 {
        if operation == 150 {
            // The first edit in phase 3: its migrate and its step, together.
            migrateSeq = editor.history.nextSeq
            editor.migrate()
            clock += 2
            try editor.perform(To4.markers(editor.document), at: clock)
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

/// An editor over `UndoHistory` the way the session uses it on a project of phase 2 (its create in version 3), with the
/// migrate of its first edit in phase 3.
private struct Editor {
    var history: UndoHistory
    private(set) var entries: [EditLogEntry]
    private(set) var document: EditDocument
    private var groups: [Int: [EditChange]] = [:]

    init(_ document: EditDocument) {
        history = UndoHistory(entries: [SmallDocument.create], createVersion: 3)
        entries = [SmallDocument.create]
        self.document = document
    }

    mutating func migrate() {
        append(.migrate(seq: history.nextSeq, from: 3, to: 4))
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

/// A step of phase 2 on `document` that version 3 writes the same (the padding, the corners, a suppressed range, the
/// captions' capitals, the keys on screen), or, once `migrated`, also one only version 4 has (a marker renamed, the
/// ducking's amount, the automatic zoom's mode, a clip's sound cut); `nil` if it would change nothing.
private func randomStep(_ document: EditDocument, migrated: Bool, using generator: inout SplitMix64) -> EditStep? {
    let level = Double(Int.random(in: 0...20, using: &generator)) / 100
    switch Int.random(in: 0..<(migrated ? 9 : 5), using: &generator) {
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
        return document.setChange("/captions/style/uppercase", !document.captions.style.uppercase).map {
            EditStep(label: .captionsStyle, target: "/captions/style/uppercase", changes: [$0])
        }
    case 4:
        let mode = KeyOverlayMode.allCases.randomElement(using: &generator) ?? .off
        return document.setChange("/keys/mode", mode).map { EditStep(label: .keysOverlay, target: "/keys/mode", changes: [$0]) }
    case 5:
        guard var marker = document.markers.items.first else { return nil }
        marker.name = "Marker \(Int(level * 100))"
        return document.replaceChange(.markers, id: marker.id, with: marker).map {
            EditStep(label: .markerRename, target: marker.id, changes: [$0])
        }
    case 6:
        return document.setChange("/music/ducking/amount", -level * 60).map {
            EditStep(label: .musicDucking, target: "/music/ducking/amount", changes: [$0])
        }
    case 7:
        let mode = ZoomMode.allCases.randomElement(using: &generator) ?? .classic
        return document.setChange("/zoom/auto/mode", mode).map { EditStep(label: .zoomMode, target: "/zoom/auto/mode", changes: [$0]) }
    default:
        return document.setChange("/sequence/0/audioShift", Int64(level * 1e9)).map {
            EditStep(label: .audioShift, target: "/sequence/0/audioShift", changes: [$0])
        }
    }
}

/// The documents met undoing every group of `entries` and then redoing every one, each line appended and replayed from
/// the document before it, its create in version 3.
private func walkThroughTheHistory(_ entries: [EditLogEntry]) throws -> [EditDocument] {
    var entries = entries
    var history = UndoHistory(entries: entries, createVersion: 3)
    let start = try #require(EditReplay.replay(snapshot: nil, entries: entries, createVersion: 3))
    var document = start.document
    var version = start.version
    var documents = [document]
    func append(_ line: EditLogEntry) throws {
        entries.append(line)
        history.record(line)
        let replayed = try #require(
            EditReplay.replay(snapshot: document, snapshotVersion: version, entries: entries, createVersion: 3))
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
