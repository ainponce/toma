// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Darwin
import Dispatch
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum SessionFixture {
    static let app = AppInfo(name: "Toma", version: "0.2.0")
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// A clock that moves `step` seconds each time it is read, from 2026-11-15T20:12:03Z: with the default 2 s, every
    /// step is a group of its own.
    final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        private let step: TimeInterval

        init(step: TimeInterval = 2) {
            self.step = step
        }

        func now() -> Date {
            date.withLock { date in
                defer { date += step }
                return date
            }
        }
    }

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    static func context(
        caches: URL, compaction: (maxBytes: Int, maxEntries: Int) = (LogCompaction.maxBytes, LogCompaction.maxEntries),
        io: EditJournalIO = .system, clock: Clock = Clock()
    ) -> EditContext {
        let ids = IDs()
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma, now: { clock.now() }, makeID: { ids.make($0) },
            compaction: compaction, journalIO: io)
    }

    /// A take of 1 s of one display with the cursor moving over it, in a new package `<name>.toma` of `formatVersion`.
    /// Written off the main actor, where the tests' sessions live.
    @concurrent static func package(
        in dir: URL, name: String = "Fixture", formatVersion: Int = 3, upgradedFrom: Int? = nil
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion, upgradedFrom: upgradedFrom)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents((0..<20).map { i in
            InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: 100 + Double(i) * 10, y: 100))
        })
        return try builder.write()
    }

    static func open(_ project: LoadedProject, _ context: EditContext) async throws -> EditSession {
        try await EditSession.open(project.package.url, take: nil, context: context)
    }

    static func step(_ document: EditDocument, _ path: String, _ value: Double, _ label: EditLabel) throws -> EditStep {
        EditStep(label: label, target: path, changes: [try #require(document.setChange(path, value))])
    }

    static func padding(_ document: EditDocument, _ value: Double) throws -> EditStep {
        try step(document, "/style/padding", value, .padding)
    }

    static func entries(_ package: ProjectPackage) throws -> [EditLogEntry] {
        try EditLogReader.read(package.editLogURL).entries
    }

    static func snapshot(_ package: ProjectPackage) throws -> EditDocument {
        try EditDocument.decode(Data(contentsOf: package.editURL))
    }

    static func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    static func write(_ lines: [String], to url: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    /// `document` at another line of the log, to compare states whatever line they are at.
    static func state(_ document: EditDocument) -> EditDocument {
        var document = document
        document.logSequence = 0
        return document
    }

    /// The files of `package` whose names start with `edit-log.jsonl.damaged-`.
    static func damagedCopies(_ package: ProjectPackage) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: package.url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("edit-log.jsonl.damaged-") }
    }

    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func inode(_ url: URL) -> UInt64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_ino : 0
    }

    /// The system's calls, with the writes failing while `failingWrites` is set and the full syncs waiting while
    /// `holdsSyncs` is.
    final class IO: Sendable {
        private struct State {
            var failingWrites: POSIXErrorCode?
            var holdsSyncs = false
        }

        private let state = Mutex(State())
        private let released = DispatchSemaphore(value: 0)

        func failWrites(with code: POSIXErrorCode?) { state.withLock { $0.failingWrites = code } }

        func holdSyncs() { state.withLock { $0.holdsSyncs = true } }

        func releaseSyncs() {
            state.withLock { $0.holdsSyncs = false }
            released.signal()
        }

        var io: EditJournalIO {
            EditJournalIO(
                open: { try EditJournalIO.system.open($0, $1, $2) },
                write: { [self] descriptor, bytes in
                    if let code = state.withLock({ $0.failingWrites }) { throw POSIXError(code) }
                    return try EditJournalIO.system.write(descriptor, bytes)
                },
                fullSync: { [self] descriptor in
                    if state.withLock({ $0.holdsSyncs }) { released.wait() }
                    try EditJournalIO.system.fullSync(descriptor)
                },
                fsync: { try EditJournalIO.system.fsync($0) },
                syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
        }
    }
}

// MARK: - Legacy and new projects

@MainActor @Test func openingALegacyPackageWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        for version in [1, 2] {
            let project = try await SessionFixture.package(in: dir, name: "v\(version)", formatVersion: version)
            let before = try treeHash(project.package.url)
            let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
            #expect(session.document == .legacy(for: project))
            #expect(session.notices == [.legacyLook])
            #expect(session.access == .editable)
            // Only the first edit writes (PackageUpgradeTests); there is nothing to undo before it.
            #expect(session.undo() == .refused)
            #expect(await session.flushed() == 0)
            #expect(!session.hasUnsavedChanges)
            await session.close()
            #expect(try treeHash(project.package.url) == before)
            #expect(!FileManager.default.fileExists(atPath: project.package.editLockURL.path))
            let derived = ProjectID.derived(from: project.manifest)
            #expect(session.caches.directory.path == caches.appending(path: derived).path)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: session.caches.directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}

@MainActor @Test func newV3OpensWithTheNewDocumentWrittenOnce() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        var expected = NewDocument.make(project: project, defaultStyle: .toma, makeID: SessionFixture.IDs().make)
        expected.logSequence = 1
        #expect(session.access == .editable)
        #expect(session.notices.isEmpty)
        #expect(session.document == expected)
        #expect(try SessionFixture.entries(project.package) == [.create(seq: 1, document: expected, app: SessionFixture.app)])
        #expect(try SessionFixture.snapshot(project.package) == expected)
        #expect(await session.flushed() == 1)
        #expect(!session.hasUnsavedChanges)
        await session.close()

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.document == expected)
        #expect(again.undoLabel == nil)
        await again.close()
        #expect(try SessionFixture.entries(project.package) == [.create(seq: 1, document: expected, app: SessionFixture.app)])
    }
}

@MainActor @Test func upgradedPackageWithoutALogStartsFromTheLegacyDocument() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir, upgradedFrom: 2)
        let manifest = try Data(contentsOf: project.package.manifestURL)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        let legacy = EditDocument.legacy(for: project)
        #expect(session.document == legacy)
        #expect(session.notices == [.legacyLook])
        #expect(session.access == .editable)
        #expect(!FileManager.default.fileExists(atPath: project.package.editURL.path))
        #expect(try SessionFixture.entries(project.package).isEmpty)

        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 2)
        var created = legacy
        created.logSequence = 1
        let entries = try SessionFixture.entries(project.package)
        #expect(entries.count == 2)
        #expect(entries.first == .create(seq: 1, document: created, app: SessionFixture.app))
        if case let .do(seq, group, label, _, _)? = entries.last {
            #expect((seq, group, label) == (2, 2, "style.padding"))
        } else {
            Issue.record("no do line: \(entries)")
        }
        #expect(session.undo() == .applied)
        #expect(SessionFixture.state(session.document) == SessionFixture.state(legacy))
        await session.close()
        #expect(try Data(contentsOf: project.package.manifestURL) == manifest)
    }
}

@MainActor @Test func cachesUseTheDerivedIDForLegacyAndTheManifestIDForV3() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let legacy = try await SessionFixture.package(in: dir, name: "Legacy", formatVersion: 1)
        let current = try await SessionFixture.package(in: dir, name: "Current")
        let legacySession = try await SessionFixture.open(legacy, SessionFixture.context(caches: caches))
        let currentSession = try await SessionFixture.open(current, SessionFixture.context(caches: caches))
        let derived = ProjectID.derived(from: legacy.manifest)
        let projectID = try #require(current.manifest.projectID)
        #expect(legacySession.caches.directory.path == caches.appending(path: derived).path)
        #expect(currentSession.caches.directory.path == caches.appending(path: projectID).path)
        #expect(derived != projectID)
        #expect(currentSession.caches.thumbnails.path == caches.appending(path: "\(projectID)/thumbnails").path)
        #expect(currentSession.caches.waveforms.path == caches.appending(path: "\(projectID)/waveforms").path)
        #expect(currentSession.caches.suggestions.path == caches.appending(path: "\(projectID)/suggestions").path)
        #expect(currentSession.caches.editorState.path == caches.appending(path: "\(projectID)/editor-state.json").path)
        await legacySession.close()
        await currentSession.close()
    }
}

@Test func aProjectIDThatIsNotHexNeverLeavesTheCachesFolder() async throws {
    let root = URL(fileURLWithPath: "/tmp/Caches/Projects", isDirectory: true)
    for id in ["../../x", "", "/etc", "ABCDEF0123456789ABCDEF0123456789"] {
        let caches = ProjectCaches(root: root, projectID: id)
        #expect(caches.directory.deletingLastPathComponent().path == root.path, "\(id)")
        #expect(ProjectID.isValid(caches.directory.lastPathComponent), "\(id)")
    }
    // A loaded manifest never gets that far: its projectID is checked first.
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        var manifest = project.manifest
        manifest.projectID = "../../escape"
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: project.package.manifestURL)
        let caches = dir.appending(path: "Caches/Projects")
        await #expect(throws: LoadedProjectError.invalidPath(.invalidProjectID("../../escape"))) {
            try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "escape").path))
        #expect(!FileManager.default.fileExists(atPath: project.package.editLockURL.path))
    }
}

@Test func readDocumentNeverWrites() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let before = try treeHash(project.package.url)
        let (read, document) = try EditSession.readDocument(
            project.package.url, take: nil, context: SessionFixture.context(caches: dir.appending(path: "Caches")))
        #expect(read.take == project.take)
        #expect(document == NewDocument.make(project: project, defaultStyle: .toma, makeID: SessionFixture.IDs().make))
        #expect(try treeHash(project.package.url) == before)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Caches").path))
    }
}

// MARK: - Editing

@MainActor @Test func performUndoRedoOnV3() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        var changes = 0
        session.onChange = { changes += 1 }
        #expect(session.document.style.padding == 0.08)
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        #expect(session.document.style.padding == 0.1)
        #expect(session.undoLabel == .padding)
        #expect(session.undo() == .applied)
        #expect(session.document.style.padding == 0.08)
        #expect(session.undoLabel == nil)
        #expect(session.redoLabel == .padding)
        #expect(session.redo() == .applied)
        #expect(session.document.style.padding == 0.1)
        #expect(session.redo() == .refused)
        #expect(session.perform(EditStep(label: .padding, target: "/style/padding", changes: [])) == .refused)
        // The new document's `create` is in the oldest version that holds it, 2, and the first edit migrates it.
        #expect(await session.flushed() == 5)
        #expect(session.revision == 3)
        #expect(changes == 3)
        #expect(session.document.logSequence == 5)
        await session.close()
        #expect(session.perform(try SessionFixture.padding(session.document, 0.2)) == .refused)
        let entries = try SessionFixture.entries(project.package)
        #expect(entries.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(entries[1] == .migrate(seq: 2, from: 2, to: 3))
        #expect(entries[3] == .undo(seq: 4, group: 3))
        #expect(entries[4] == .redo(seq: 5, group: 3))

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.document.style.padding == 0.1)
        #expect(again.undoLabel == .padding)
        #expect(again.undo() == .applied)
        #expect(again.document.style.padding == 0.08)
        #expect(await again.flushed() == 6)
        await again.close()
    }
}

@MainActor @Test func canUndoAndCanRedoSayWhatUndoAndRedoWouldDo() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(!session.canUndo && !session.canRedo)
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        #expect(session.canUndo && !session.canRedo)
        let before = session.revision
        // Asking changes nothing.
        #expect(session.canUndo)
        #expect(session.revision == before && session.document.style.padding == 0.1)
        #expect(session.undo() == .applied)
        #expect(!session.canUndo && session.canRedo)
        #expect(session.redo() == .applied)
        #expect(session.canUndo && !session.canRedo)
        #expect(await session.flushed() == 5)
        await session.close()
        #expect(!session.canUndo && !session.canRedo)

        // After opening again, from the log.
        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.canUndo && !again.canRedo)
        #expect(again.undo() == .applied)
        #expect(!again.canUndo && again.canRedo)
        await again.close()

        // Read-only: nothing.
        let lock = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { lock.release() }
        let readOnly = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(readOnly.access == .readOnly(.openElsewhere))
        #expect(!readOnly.canUndo && !readOnly.canRedo)
        await readOnly.close()
    }
}

@MainActor @Test func snapshotWithoutALogStartsALogOfIt() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        await session.close()
        let snapshot = try SessionFixture.snapshot(project.package)
        #expect(snapshot.logSequence == 3)
        try FileManager.default.removeItem(at: project.package.editLogURL)

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.document == snapshot)
        #expect(again.undoLabel == nil)
        #expect(try SessionFixture.entries(project.package) == [.create(seq: 3, document: snapshot, app: SessionFixture.app)])
        #expect(again.perform(try SessionFixture.padding(again.document, 0.2)) == .applied)
        #expect(await again.flushed() == 4)
        await again.close()
    }
}

// MARK: - Read-only

@MainActor @Test func lockHeldAtOpenIsReadOnly() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let lock = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { lock.release() }
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .readOnly(.openElsewhere))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .refused)
        #expect(session.undo() == .refused)
        #expect(await session.flushed() == 0)
        await session.close()
        #expect(!FileManager.default.fileExists(atPath: project.package.editLogURL.path))
        #expect(!FileManager.default.fileExists(atPath: project.package.editURL.path))
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
    }
}

@MainActor @Test func newerDocumentIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let context = SessionFixture.context(caches: dir.appending(path: "Caches"))
        await (try await SessionFixture.open(project, context)).close()
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project.package.editURL)) as? [String: Any])
        json["documentVersion"] = 4
        try JSONSerialization.data(withJSONObject: json).write(to: project.package.editURL)
        let before = try treeHash(project.package.url)

        let session = try await SessionFixture.open(project, context)
        #expect(session.access == .readOnly(.newerDocument(4)))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .refused)
        await session.close()
        #expect(try treeHash(project.package.url) == before)
        #expect(throws: EditDocumentError.newerVersion(4)) {
            try EditSession.readDocument(project.package.url, take: nil, context: context)
        }
    }
}

@MainActor @Test func symlinkedEditFilesOpenReadOnly() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        for name in ["edit-log.jsonl", "edit.json", "edit.lock"] {
            let project = try await SessionFixture.package(in: dir, name: name)
            // A file outside the package with what an edit file could hold.
            let outside = dir.appending(path: "\(name).outside")
            var foreign = EditDocument.legacy(for: project)
            foreign.style.padding = 0.3
            let contents = name == "edit-log.jsonl"
                ? Data((try EditLogEntry.create(seq: 1, document: foreign, app: SessionFixture.app).jsonLine() + "\n").utf8)
                : try ProjectJSON.encoder().encode(foreign)
            try contents.write(to: outside)
            try FileManager.default.createSymbolicLink(at: project.package.url.appending(path: name), withDestinationURL: outside)
            let before = try treeHash(project.package.url)

            let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
            #expect(session.access == .readOnly(.unsafeEditFiles), "\(name)")
            #expect(session.document.style.padding != 0.3, "\(name)")
            #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .refused, "\(name)")
            await session.close()
            #expect(try Data(contentsOf: outside) == contents, "\(name)")
            #expect(try treeHash(project.package.url) == before, "\(name)")
            if name != "edit.lock" {
                #expect(throws: POSIXError(.ELOOP), "\(name)") {
                    try EditSession.readDocument(project.package.url, take: nil, context: SessionFixture.context(caches: caches))
                }
            }
        }
    }
}

@MainActor @Test func fifoEditLogOpensReadOnlyQuickly() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        for name in ["edit-log.jsonl", "edit.json"] {
            let project = try await SessionFixture.package(in: dir, name: name)
            let fifo = project.package.url.appending(path: name).path
            #expect(mkfifo(fifo, 0o644) == 0)
            // An open that waited for the FIFO's other end would wait for good: the watchdog opens it after 30 s, and
            // the test fails instead of hanging. Nothing is timed.
            let watchdog = FIFOWatchdog(paths: [fifo])
            let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
            #expect(session.access == .readOnly(.unsafeEditFiles), "\(name)")
            await session.close()
            #expect(!watchdog.disarm(), "\(name): the open of the FIFO waited for its other end")
            #expect(throws: POSIXError(.EFTYPE), "\(name)") {
                try EditSession.readDocument(project.package.url, take: nil, context: SessionFixture.context(caches: caches))
            }
        }
    }
}

@MainActor @Test func readOnlyDiskOpensReadOnly() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        #expect(chmod(project.package.url.path, 0o555) == 0)
        defer { chmod(project.package.url.path, 0o755) }
        let before = try treeHash(project.package.url)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .readOnly(.diskNotWritable))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .refused)
        await session.close()
        #expect(try treeHash(project.package.url) == before)
    }
}

@MainActor @Test func anAbsurdFrameRateOrSpeedNeverReachesTheRender() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let cases: [(name: String, path: String, before: JSONValue, after: JSONValue)] = [
            ("frameRate", "/frameRate", .number(60), .number(1_000_000_000)),
            ("speed", "/sequence/0/speed", .number(1), .number(100)),
        ]
        for edit in cases {
            let project = try await SessionFixture.package(in: dir, name: edit.name)
            await (try await SessionFixture.open(project, SessionFixture.context(caches: caches))).close()
            // A line written by hand: the change applies, but leaves a document the render cannot draw.
            let line = EditLogEntry.do(
                seq: 2, group: 2, label: "frameRate", changes: [.set(path: try JSONPointer(edit.path), before: edit.before, after: edit.after)],
                at: Date(timeIntervalSince1970: 1_794_773_600))
            try SessionFixture.write(try SessionFixture.lines(project.package.editLogURL) + [try line.jsonLine()], to: project.package.editLogURL)
            let before = try treeHash(project.package.url)

            let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
            #expect(session.access == .readOnly(.unsafeEditFiles), "\(edit.name)")
            #expect([24, 25, 30, 50, 60].contains(session.document.frameRate), "\(edit.name)")
            #expect(session.document.sequence.allSatisfy { (0.25...16).contains($0.speed) }, "\(edit.name)")
            #expect(TimeMap(sequence: session.document.sequence).frameCount(frameRate: session.document.frameRate) > 0)
            await session.close()
            #expect(try treeHash(project.package.url) == before, "\(edit.name)")
            let (_, read) = try EditSession.readDocument(project.package.url, take: nil, context: SessionFixture.context(caches: caches))
            #expect(read == session.document, "\(edit.name)")
        }

        // A snapshot like that, beside a log that is fine, is not read: the log is the truth.
        let project = try await SessionFixture.package(in: dir, name: "snapshot")
        await (try await SessionFixture.open(project, SessionFixture.context(caches: caches))).close()
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project.package.editURL)) as? [String: Any])
        json["frameRate"] = 0
        try JSONSerialization.data(withJSONObject: json).write(to: project.package.editURL)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(session.access == .editable)
        #expect(session.document.frameRate == 60)
        await session.close()
    }
}

// MARK: - Damage

@MainActor @Test func damagedLogIsKeptApartAndRewritten() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        for value in [0.1, 0.11, 0.12, 0.13] {
            #expect(session.perform(try SessionFixture.padding(session.document, value)) == .applied)
        }
        await session.close()
        let entries = try SessionFixture.entries(project.package)
        // The `create`, the `migrate` of the first edit and the four steps.
        #expect(entries.map(\.seq) == [1, 2, 3, 4, 5, 6])
        // No snapshot newer than the damage: the state is the last good line's.
        try FileManager.default.removeItem(at: project.package.editURL)
        var lines = try SessionFixture.lines(project.package.editLogURL)
        lines[4] = #"{"garbage":"#
        try SessionFixture.write(lines, to: project.package.editLogURL)
        let original = try Data(contentsOf: project.package.editLogURL)

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.access == .editable)
        #expect(again.document.style.padding == 0.11)
        guard case let .do(_, _, _, _, at) = entries[3] else { throw TestSupportError.failed("line 4 is no do") }
        #expect(again.notices == [.recovered(upTo: at)])
        let copies = try SessionFixture.damagedCopies(project.package)
        #expect(copies.count == 1)
        #expect(copies.first.map { $0.lastPathComponent.wholeMatch(of: /edit-log\.jsonl\.damaged-\d{8}-\d{6}/) != nil } == true)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == original)
        #expect(try SessionFixture.entries(project.package) == Array(entries.prefix(4)))
        #expect(await again.flushed() == 4)
        #expect(again.undoLabel == .padding)
        #expect(again.perform(try SessionFixture.padding(again.document, 0.2)) == .applied)
        #expect(await again.flushed() == 5)
        await again.close()
        #expect(try SessionFixture.damagedCopies(project.package) == copies)
    }
}

@MainActor @Test func aLineThatDoesNotMatchEndsTheHistoryThere() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        await session.close()
        try FileManager.default.removeItem(at: project.package.editURL)
        let good = try SessionFixture.entries(project.package)
        // A whole line that does not match the document (its `before` is not what is there), and one after it.
        let at = Date(timeIntervalSince1970: 1_794_773_700)
        let mismatch = EditLogEntry.do(
            seq: 4, group: 4, label: "style.shadow", changes: [.set(path: try JSONPointer("/style/shadow"), before: .number(0.9), after: .number(0.2))],
            at: at)
        let after = EditLogEntry.do(
            seq: 5, group: 5, label: "style.cornerRadius",
            changes: [.set(path: try JSONPointer("/style/cornerRadius"), before: .number(0.012), after: .number(0.05))], at: at)
        try SessionFixture.write(
            try SessionFixture.lines(project.package.editLogURL) + [try mismatch.jsonLine(), try after.jsonLine()],
            to: project.package.editLogURL)

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.document.style.padding == 0.1)
        #expect(again.document.style.cornerRadius == 0.012)
        // The `create`, the `migrate` of the first edit and its step.
        guard case let .do(_, _, _, _, goodAt) = good[2] else { throw TestSupportError.failed("line 3 is no do") }
        #expect(again.notices == [.recovered(upTo: goodAt)])
        // The history is only what the replay applied.
        #expect(again.undoLabel == .padding)
        #expect(again.undo() == .applied)
        #expect(again.undoLabel == nil)
        #expect(again.document.style.padding == 0.08)
        await again.close()
        #expect(try SessionFixture.entries(project.package).prefix(3) == good[...])
    }
}

@MainActor @Test func damageBeforeTheSnapshotKeepsTheSnapshot() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        for value in [0.1, 0.11, 0.12, 0.13] {
            #expect(session.perform(try SessionFixture.padding(session.document, value)) == .applied)
        }
        await session.close()
        let snapshot = try SessionFixture.snapshot(project.package)
        #expect(snapshot.logSequence == 6)
        var lines = try SessionFixture.lines(project.package.editLogURL)
        lines[2] = "garbage"
        try SessionFixture.write(lines, to: project.package.editLogURL)
        let original = try Data(contentsOf: project.package.editLogURL)

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.access == .editable)
        #expect(again.document == snapshot)
        #expect(again.undoLabel == nil)
        #expect(again.notices.count == 1)
        #expect(try SessionFixture.entries(project.package) == [.create(seq: 6, document: snapshot, app: SessionFixture.app)])
        #expect(try SessionFixture.damagedCopies(project.package).map { try Data(contentsOf: $0) } == [original])
        #expect(again.perform(try SessionFixture.padding(again.document, 0.2)) == .applied)
        #expect(await again.flushed() == 7)
        await again.close()
    }
}

@MainActor @Test func cutShortLastLineIsTruncatedBeforeAppending() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        await session.close()
        let handle = try FileHandle(forWritingTo: project.package.editLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"at":"2026-11-15T2"#.utf8))
        try handle.close()

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.access == .editable)
        #expect(again.notices.isEmpty)
        #expect(again.document.style.padding == 0.1)
        #expect(again.perform(try SessionFixture.padding(again.document, 0.2)) == .applied)
        #expect(await again.flushed() == 4)
        await again.close()
        let read = try EditLogReader.read(project.package.editLogURL)
        #expect(read.entries.map(\.seq) == [1, 2, 3, 4])
        #expect(!read.droppedTruncatedTail)
        #expect(read.damagedLine == nil)
    }
}

// MARK: - Snapshots

@MainActor @Test func snapshotNeverRunsAheadOfTheLog() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        await (try await SessionFixture.open(project, SessionFixture.context(caches: caches))).close()
        #expect(try SessionFixture.snapshot(project.package).logSequence == 1)

        let io = SessionFixture.IO()
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches, io: io.io))
        io.holdSyncs()
        // The steps never wait for the disk: one that waited for the held syncs would wait for the watchdog.
        let watchdog = Watchdog { io.releaseSyncs() }
        for value in [0.1, 0.11, 0.12] {
            #expect(session.perform(try SessionFixture.padding(session.document, value)) == .applied)
        }
        #expect(!watchdog.disarm(), "a step waited for the disk")
        #expect(session.hasUnsavedChanges)
        // Past the idle delay, the snapshot is due, but its line is not on disk.
        try await Task.sleep(for: SnapshotPolicy.idleDelay + .milliseconds(700))
        #expect(try SessionFixture.snapshot(project.package).logSequence == 1)

        io.releaseSyncs()
        #expect(await session.flushed() == 5)
        #expect(await eventually { (try? SessionFixture.snapshot(project.package).logSequence) == 5 })
        #expect(!session.hasUnsavedChanges)
        await session.close()
        #expect(try SessionFixture.snapshot(project.package) == session.document)
    }
}

@MainActor @Test func snapshotIntoAMovedPackageFollowsIt() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 3)
        let moved = dir.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        let newURL = moved.appending(path: "Moved.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: project.package.url, to: newURL)
        #expect(SessionFixture.realPath(session.packageURL) == SessionFixture.realPath(newURL))

        #expect(session.perform(try SessionFixture.padding(session.document, 0.2)) == .applied)
        #expect(await session.flushed() == 4)
        let movedPackage = ProjectPackage(url: newURL)
        #expect(await eventually { (try? SessionFixture.snapshot(movedPackage).logSequence) == 4 })
        #expect(!FileManager.default.fileExists(atPath: project.package.url.path))
        #expect(!session.hasUnsavedChanges)
        #expect(!session.notices.contains { if case .saveFailed = $0 { true } else { false } })
        await session.close()
        #expect(try SessionFixture.entries(movedPackage).map(\.seq) == [1, 2, 3, 4])
        #expect(!FileManager.default.fileExists(atPath: project.package.url.path))
    }
}

@MainActor @Test func closingAMovedPackageNeverTouchesTheLockAtItsOldPath() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        let moved = ProjectPackage(url: dir.appending(path: "Moved.toma", directoryHint: .isDirectory))
        try FileManager.default.moveItem(at: project.package.url, to: moved.url)
        // Another package at the old path, edited by another process.
        try FileManager.default.createDirectory(at: project.package.url, withIntermediateDirectories: false)
        let other = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { other.release() }
        await session.close()
        #expect(FileManager.default.fileExists(atPath: project.package.editLockURL.path))
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        // The moved package's own lock file goes.
        #expect(!FileManager.default.fileExists(atPath: moved.editLockURL.path))
    }
}

@MainActor @Test func aJournalFailingBeforeTheSessionListensStillRestartsTheLog() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let io = SessionFixture.IO()
        // The `create` written at opening fails as it does in a log removed under the journal, before the session is
        // there to listen.
        io.failWrites(with: .ENOENT)
        let session = try await SessionFixture.open(
            project, SessionFixture.context(caches: dir.appending(path: "Caches"), io: io.io))
        io.failWrites(with: nil)
        #expect(session.notices.contains(.saveFailed(.ENOENT)))
        // It is acted on all the same: the log is set aside and a new one starts with the document.
        #expect(await eventually { (try? SessionFixture.damagedCopies(project.package).count) == 1 })
        #expect(await eventually { !session.hasUnsavedChanges })
        #expect(session.document.logSequence == 2)
        #expect(
            try SessionFixture.entries(project.package) == [.create(seq: 2, document: session.document, app: SessionFixture.app)])
        await session.close()
    }
}

@MainActor @Test func aLogRemovedWhileOpenStartsAgainFromTheDocument() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(session.perform(try SessionFixture.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 3)
        try FileManager.default.removeItem(at: project.package.editLogURL)

        // The next line finds the log gone: a new one starts with the document as it is, this step included.
        #expect(session.perform(try SessionFixture.padding(session.document, 0.2)) == .applied)
        #expect(await eventually { (try? SessionFixture.entries(project.package))?.first.map { if case .create = $0 { true } else { false } } == true })
        #expect(await session.flushed() == 5)
        var expected = session.document
        expected.logSequence = 5
        #expect(try SessionFixture.entries(project.package) == [.create(seq: 5, document: expected, app: SessionFixture.app)])
        #expect(session.undoLabel == nil)
        #expect(session.perform(try SessionFixture.padding(session.document, 0.3)) == .applied)
        #expect(await session.flushed() == 6)
        #expect(await eventually { !session.notices.contains { if case .saveFailed = $0 { true } else { false } } })
        #expect(!session.hasUnsavedChanges)
        await session.close()

        let again = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(again.document.style.padding == 0.3)
        #expect(again.undo() == .applied)
        #expect(again.document.style.padding == 0.2)
        #expect(again.undo() == .refused)
        await again.close()
    }
}

// MARK: - Compaction

@MainActor @Test func editsAfterCompactionAtOpenAreInTheLog() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let first = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        let created = first.document
        // The document after each group of the undo stack, from the create's, and those of the redo stack.
        var done = [SessionFixture.state(created)]
        var undone: [EditDocument] = []
        @MainActor func record(_ session: EditSession, _ outcome: EditOutcome, _ kind: Int) {
            #expect(outcome == .applied)
            switch kind {
            case 0: done.append(SessionFixture.state(session.document)); undone = []
            case 1: undone.append(done.removeLast())
            default: done.append(undone.removeLast())
            }
        }
        // Every fourth step undoes and every fifth redoes, so the log has lines the compaction drops.
        for i in 0..<30 {
            if i % 5 == 3, done.count > 1 {
                record(first, first.undo(), 1)
            } else if i % 5 == 4, !undone.isEmpty {
                record(first, first.redo(), 2)
            } else {
                let path = ["/style/padding", "/style/cornerRadius", "/style/shadow"][i % 3]
                let label: EditLabel = [.padding, .cornerRadius, .shadow][i % 3]
                record(first, first.perform(try SessionFixture.step(first.document, path, 0.001 * Double(i + 1), label)), 0)
            }
        }
        await first.close()
        let uncompacted = try SessionFixture.entries(project.package)
        // The `create`, the `migrate` of the first edit and the thirty steps.
        #expect(uncompacted.count == 32)

        let compacting = SessionFixture.context(caches: caches, compaction: (maxBytes: .max, maxEntries: 10))
        let second = try await SessionFixture.open(project, compacting)
        let compacted = try SessionFixture.entries(project.package)
        #expect(compacted.count < uncompacted.count)
        #expect(compacted.last?.seq == uncompacted.last?.seq)
        // The snapshot went first, at the last line.
        #expect(try SessionFixture.snapshot(project.package).logSequence == uncompacted.last?.seq)
        for i in 0..<5 {
            record(second, second.perform(try SessionFixture.step(second.document, "/style/backgroundBlur", 0.1 * Double(i + 1), .background)), 0)
        }
        await second.close()

        let third = try await SessionFixture.open(project, SessionFixture.context(caches: caches))
        #expect(SessionFixture.state(third.document) == done.last)
        // Undo goes back through every group to the create's document.
        while done.count > 1 {
            done.removeLast()
            #expect(third.undo() == .applied)
            #expect(SessionFixture.state(third.document) == done.last)
        }
        #expect(third.undo() == .refused)
        #expect(SessionFixture.state(third.document) == SessionFixture.state(created))
        await third.close()
    }
}

@MainActor @Test func compactionAtCloseNeverDropsPendingLines() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let io = SessionFixture.IO()
        let session = try await SessionFixture.open(
            project, SessionFixture.context(caches: dir.appending(path: "Caches"), compaction: (maxBytes: .max, maxEntries: 10), io: io.io))
        for step in 1...15 {
            if step == 13 { io.failWrites(with: .ENOSPC) }
            let path = step.isMultiple(of: 2) ? "/style/padding" : "/style/shadow"
            #expect(session.perform(try SessionFixture.step(session.document, path, 0.01 * Double(step), step.isMultiple(of: 2) ? .padding : .shadow)) == .applied)
            // The `create`, the `migrate` of the first edit and the steps.
            if step <= 12 { #expect(await session.flushed() == step + 2 + (step > 5 ? 2 : 0)) }
            // An undo and a redo, which a compaction would drop.
            if step == 5 {
                #expect(session.undo() == .applied)
                #expect(session.redo() == .applied)
                #expect(await session.flushed() == 9)
            }
        }
        #expect(session.hasUnsavedChanges)
        #expect(await eventually { session.notices.contains(.saveFailed(.ENOSPC)) })
        let log = try Data(contentsOf: project.package.editLogURL)
        let snapshot = try Data(contentsOf: project.package.editURL)
        await session.close()
        #expect(try Data(contentsOf: project.package.editLogURL) == log)
        #expect(try Data(contentsOf: project.package.editURL) == snapshot)
        #expect(session.hasUnsavedChanges)
        #expect(try SessionFixture.entries(project.package).count == 16)
    }
}

@MainActor @Test func compactionThatShrinksNothingLeavesTheLog() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let context = SessionFixture.context(caches: dir.appending(path: "Caches"), compaction: (maxBytes: .max, maxEntries: 1))
        let session = try await SessionFixture.open(project, context)
        let inode = SessionFixture.inode(project.package.editLogURL)
        for value in [0.1, 0.11, 0.12] {
            #expect(session.perform(try SessionFixture.padding(session.document, value)) == .applied)
        }
        await session.close()
        // Each step is a group of its own: the compacted log is the log.
        #expect(SessionFixture.inode(project.package.editLogURL) == inode)
        let again = try await SessionFixture.open(project, context)
        await again.close()
        #expect(SessionFixture.inode(project.package.editLogURL) == inode)
        #expect(try SessionFixture.entries(project.package).count == 5)
    }
}

// MARK: - The cost of an edit

/// `perform` of a small edit (a zoom block added) on the main actor, with an hour of transcript in the document (9000
/// words, one every 0.4 s): p50, p95 and the longest of 200 after 10 to warm up, each undone (not timed) before the next;
/// the same for 100 corrections of a word; and the first edit after the project opens again.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func performWithAnHourOfTranscriptBench() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await SessionFixture.package(in: dir)
        let session = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        let texts = ["Hoy", "vamos", "a", "grabar", "la", "pantalla", "con", "subtítulos", "en", "español,"]
        let words = (0..<9000).map { index in
            let start = 0.4 * Double(index)
            return TranscriptWord(
                start: SessionFixture.base.adding(seconds: start), end: SessionFixture.base.adding(seconds: start + 0.3),
                text: texts[index % 10], breakBefore: index % 20 == 0)
        }
        let transcript = Transcript(
            language: "es-MX", engine: "speechTranscriber-1",
            takes: [TranscriptTake(take: project.take.id, track: "display-1", words: words)])
        #expect(session.perform(try #require(TranscriptCommands.create(session.document, transcript))) == .applied)
        let bytes = try ProjectJSON.encoder().encode(session.document).count
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3
        }
        func p95(_ times: [Double]) -> Double { times.sorted()[min(Int(Double(times.count) * 0.95), times.count - 1)] }
        func summary(_ times: [Double]) -> String {
            let times = times.sorted()
            return String(format: "p50 %.2f ms, p95 %.2f ms, longest %.2f ms", times[times.count / 2], p95(times), times.last ?? 0)
        }
        var times: [Double] = []
        for run in 0..<210 {
            let step = try #require(
                ZoomCommands.add(session.document, output: 100_000_000..<600_000_000, makeID: { $0 + String(format: "%08x", run) }))
            let elapsed = clock.measure { #expect(session.perform(step) == .applied) }
            if run >= 10 { times.append(milliseconds(elapsed)) }
            #expect(session.undo() == .applied)
        }
        print("perform with an hour of transcript (\(bytes / 1024) KB), a zoom block added: \(summary(times))")
        // A word corrected (`transcript.word`): the edit that touches the transcript itself.
        var corrections: [Double] = []
        for run in 0..<110 {
            let step = try #require(
                TranscriptCommands.correct(session.document, TranscriptWordRef(take: 0, word: 4500), text: "palabra\(run)"))
            let elapsed = clock.measure { #expect(session.perform(step) == .applied) }
            if run >= 10 { corrections.append(milliseconds(elapsed)) }
            #expect(session.undo() == .applied)
        }
        print("perform with an hour of transcript, a word corrected: \(summary(corrections))")
        // The editor's budget for an edit on the main actor (phase 2 final review).
        #expect(p95(times) <= 8 && p95(corrections) <= 8)
        #expect(session.document.transcript == transcript)
        await session.close()
        // The first edit after opening it again.
        let again = try await SessionFixture.open(project, SessionFixture.context(caches: dir.appending(path: "Caches")))
        let step = try #require(ZoomCommands.add(again.document, output: 100_000_000..<600_000_000, makeID: { $0 + "ffffffff" }))
        let first = clock.measure { #expect(again.perform(step) == .applied) }
        print(String(format: "the first edit after opening: %.2f ms", milliseconds(first)))
        #expect(milliseconds(first) <= 8)
        // What opening does for it, off the main actor: the document's JSON, checked.
        let held = clock.measure { #expect(again.document.heldJSON() != nil) }
        print(String(format: "its JSON at opening: %.1f ms", milliseconds(held)))
        await again.close()
    }
}
