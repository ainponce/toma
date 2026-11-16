// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum UpgradeFixture {
    static let app = AppInfo(name: "Toma", version: "0.2.0")
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// A clock that moves 2 s each time it is read, from 2026-11-15T20:12:03Z: every step is a group of its own.
    final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_794_773_523))

        func now() -> Date {
            date.withLock { date in
                defer { date += 2 }
                return date
            }
        }
    }

    static func context(caches: URL, clock: Clock = Clock(), io: EditJournalIO = .system) -> EditContext {
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma, now: { clock.now() },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            journalIO: io)
    }

    /// The system's calls, with the first `count` opens of the log failing with `EMFILE`.
    static func failingOpens(_ count: Int) -> EditJournalIO {
        let left = Mutex(count)
        let system = EditJournalIO.system
        return EditJournalIO(
            open: { directory, name, create in
                let fails = left.withLock { left in
                    defer { left = max(0, left - 1) }
                    return left > 0
                }
                if fails { throw POSIXError(.EMFILE) }
                return try system.open(directory, name, create)
            },
            write: system.write, fullSync: system.fullSync, fsync: system.fsync, syncDirectory: system.syncDirectory)
    }

    /// A take of 1 s of one display with the cursor moving over it, in a new package `<name>.toma` of `formatVersion`.
    /// Written off the main actor, where the tests' sessions live.
    @concurrent static func package(
        in dir: URL, name: String = "Fixture", formatVersion: Int
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
        ])
        try builder.addEvents(cursor)
        return try builder.write()
    }

    static let cursor = (0..<20).map { i in
        InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: 100 + Double(i) * 10, y: 100))
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

    static func manifest(_ package: ProjectPackage) throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    /// What the upgrade writes as the manifest of a version 1 or 2 package: nothing else changes.
    static func upgraded(_ manifest: Manifest) -> Manifest {
        var upgraded = manifest
        upgraded.formatVersion = 3
        upgraded.upgradedFrom = manifest.formatVersion
        upgraded.projectID = ProjectID.derived(from: manifest)
        return upgraded
    }

    /// `document` at another line of the log, to compare states whatever line they are at (Task 9: the replay sets
    /// `logSequence` to the last line it applied).
    static func state(_ document: EditDocument) -> EditDocument {
        var document = document
        document.logSequence = 0
        return document
    }

    // What the tests do to the disk themselves runs off the main actor (`F_FULLFSYNC` waits, and a hash reads every
    // file), so the main-actor hops of the sessions of the other tests never wait for it.

    @concurrent static func hash(_ package: ProjectPackage) async throws -> String {
        try treeHash(package.url)
    }

    @concurrent static func write(_ manifest: Manifest, to package: ProjectPackage) async throws {
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
    }

    /// Another process upgrades the package with `first`, as it was opened, and lets it go.
    @concurrent static func upgradeElsewhere(
        _ project: LoadedProject, first: EditStep, caches: URL
    ) async throws -> UpgradeResult {
        let result = try withFolder(project.package) { folder in
            try PackageUpgrade.upgrade(
                project.package, folder: folder, opened: project.manifest, legacy: .legacy(for: project), first: first,
                context: context(caches: caches))
        }
        if case let .upgraded(lock, _) = result { lock.release() }
        return result
    }

    @concurrent static func document(_ project: LoadedProject, caches: URL) async throws -> EditDocument {
        try EditSession.readDocument(project.package.url, take: nil, context: context(caches: caches)).1
    }

    /// The package's folder open as the session holds it, for `PackageUpgrade.upgrade`.
    static func withFolder<T>(_ package: ProjectPackage, _ body: (Int32) throws -> T) throws -> T {
        let fd = Darwin.open(package.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        return try body(fd)
    }
}

// MARK: - The first edit

@MainActor @Test func firstEditUpgradesInOrder() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let caches = dir.appending(path: "Caches")
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        let legacy = EditDocument.legacy(for: project)
        var changes = 0
        session.onChange = { changes += 1 }
        let step = try UpgradeFixture.padding(session.document, 0.1)

        // Seen at once, before anything is on disk.
        #expect(session.perform(step) == .pendingUpgrade)
        #expect(session.document.style.padding == 0.1)
        #expect(changes == 1)
        #expect(session.hasUnsavedChanges)
        #expect(session.undoLabel == .padding)

        #expect(await session.flushed() == 2)
        #expect(!session.hasUnsavedChanges)
        #expect(session.access == .editable)
        #expect(session.document.style.padding == 0.1)
        // (2) The manifest: version 3, upgraded from 1, the derived id, and nothing else.
        let expected = UpgradeFixture.upgraded(project.manifest)
        #expect(try UpgradeFixture.manifest(project.package) == expected)
        #expect(expected.takes == project.manifest.takes)
        #expect(session.project.manifest == expected)
        #expect(session.caches.directory.lastPathComponent == expected.projectID)
        // (3) The log: the legacy document's `create` and the edit.
        var created = legacy
        created.logSequence = 1
        let entries = try UpgradeFixture.entries(project.package)
        #expect(entries.count == 2)
        #expect(entries.first == .create(seq: 1, document: created, app: UpgradeFixture.app))
        if case let .do(seq, group, label, written, _)? = entries.last {
            #expect((seq, group, label) == (2, 2, "style.padding"))
            #expect(written == step.changes)
        } else {
            Issue.record("no do line: \(entries)")
        }
        // (1) The lock, held until closing.
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))

        // It goes on as a version 3 project.
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.2)) == .applied)
        #expect(await session.flushed() == 3)
        await session.close()
        #expect(!RecordingLock.isHeld(at: project.package.editLockURL))

        let again = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        #expect(again.document.style.padding == 0.2)
        #expect(again.notices.isEmpty)
        #expect(again.undo() == .applied)
        #expect(again.undo() == .applied)
        #expect(UpgradeFixture.state(again.document) == UpgradeFixture.state(legacy))
        await again.close()
    }
}

@MainActor @Test func stepsDuringTheUpgradeAreLoggedInOrder() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        let caches = dir.appending(path: "Caches")
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        // No suspension between them: the upgrade cannot come back to the main actor before the last one.
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        #expect(session.document.style.shadow == 0.3)
        #expect(session.undo() == .pendingUpgrade)
        #expect(session.document.style.padding == 0.1)
        #expect(session.document.style.shadow == 0)
        #expect(session.redoLabel == .shadow)

        #expect(await session.flushed() == 4)
        #expect(session.access == .editable)
        #expect(!session.hasUnsavedChanges)
        let entries = try UpgradeFixture.entries(project.package)
        let shape = entries.map { entry -> String in
            switch entry {
            case let .create(seq, _, _): "create \(seq)"
            case let .do(seq, group, label, _, _): "do \(seq) \(group) \(label)"
            case let .undo(seq, group): "undo \(seq) \(group)"
            case let .redo(seq, group): "redo \(seq) \(group)"
            case let .migrate(seq, _, _): "migrate \(seq)"
            }
        }
        #expect(shape == ["create 1", "do 2 2 style.padding", "do 3 3 style.shadow", "undo 4 3"])
        #expect(session.document.style.padding == 0.1)
        #expect(session.document.style.shadow == 0)
        await session.close()

        let again = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        #expect(UpgradeFixture.state(again.document) == UpgradeFixture.state(session.document))
        #expect(again.redo() == .applied)
        #expect(again.document.style.shadow == 0.3)
        await again.close()
    }
}

// MARK: - Another process

@MainActor @Test func otherProcessHoldingTheLockDiscardsTheFirstEdit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .editable)
        // Another process starts editing after this one opened.
        let other = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { other.release() }
        let before = try await UpgradeFixture.hash(project.package)
        var changes = 0
        session.onChange = { changes += 1 }

        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.document.style.padding == 0.1)
        // What comes behind the first edit is discarded with it.
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)

        #expect(session.document == .legacy(for: project))
        #expect(session.access == .readOnly(.otherAppStartedEditing))
        #expect(changes == 3)
        #expect(try await UpgradeFixture.hash(project.package) == before)
        #expect(!session.hasUnsavedChanges)
        #expect(session.undoLabel == nil)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.2)) == .refused)
        #expect(session.undo() == .refused)
        await session.close()
        #expect(try await UpgradeFixture.hash(project.package) == before)
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
    }
}

@MainActor @Test func packageUpgradedMeanwhileIsReopened() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        let caches = dir.appending(path: "Caches")
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        let legacy = EditDocument.legacy(for: project)
        // Another process upgrades the package with an edit of its own and lets it go.
        let result = try await UpgradeFixture.upgradeElsewhere(
            project, first: try UpgradeFixture.padding(legacy, 0.3), caches: caches)
        guard case .upgraded = result else {
            Issue.record("the other process did not upgrade: \(result)")
            return
        }
        let log = try Data(contentsOf: project.package.editLogURL)
        let onDisk = try await UpgradeFixture.document(project, caches: caches)
        #expect(onDisk.style.padding == 0.3)
        var changes = 0
        session.onChange = { changes += 1 }

        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.document.style.padding == 0.1)
        #expect(await session.flushed() == 2)

        // The edit made here is not there: the project is what the disk has.
        #expect(session.document == onDisk)
        #expect(session.notices.contains(.reopenedAfterOtherApp))
        #expect(!session.notices.contains(.legacyLook))
        #expect(session.access == .editable)
        #expect(changes == 2)
        #expect(session.project.manifest == UpgradeFixture.upgraded(project.manifest))
        #expect(try Data(contentsOf: project.package.editLogURL) == log)
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        // And it goes on from there, as a version 3 project.
        #expect(session.undoLabel == .padding)
        #expect(session.undo() == .applied)
        #expect(UpgradeFixture.state(session.document) == UpgradeFixture.state(legacy))
        #expect(await session.flushed() == 3)
        await session.close()
        #expect(!RecordingLock.isHeld(at: project.package.editLockURL))
    }
}

@MainActor @Test func aLogThatCannotBeOpenedAfterTheUpgradeIsReadBackFromTheDisk() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let context = UpgradeFixture.context(caches: dir.appending(path: "Caches"), io: UpgradeFixture.failingOpens(1))
        let session = try await UpgradeFixture.open(project, context)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        #expect(await session.flushed() == 2)
        // The first edit is in the log the upgrade wrote; the one after it never got to a log.
        #expect(session.document.style.padding == 0.1)
        #expect(session.document.style.shadow == 0)
        #expect(session.access == .editable)
        #expect(!session.notices.contains(.reopenedAfterOtherApp))
        #expect(session.project.manifest == UpgradeFixture.upgraded(project.manifest))
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .applied)
        #expect(await session.flushed() == 3)
        await session.close()
    }
}

@MainActor @Test func legacyLockHeldAtOpenIsReadOnly() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let other = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { other.release() }
        let before = try await UpgradeFixture.hash(project.package)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .readOnly(.openElsewhere))
        #expect(session.notices == [.legacyLook])
        #expect(session.document == .legacy(for: project))
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .refused)
        #expect(session.undo() == .refused)
        #expect(await session.flushed() == 0)
        await session.close()
        #expect(try await UpgradeFixture.hash(project.package) == before)
        #expect(!FileManager.default.fileExists(atPath: project.package.editLogURL.path))
        #expect(try UpgradeFixture.manifest(project.package) == project.manifest)
    }
}

@MainActor @Test func aFolderThatCannotBeWrittenDiscardsTheFirstEdit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        #expect(chmod(project.package.url.path, 0o555) == 0)
        defer { chmod(project.package.url.path, 0o755) }
        let before = try await UpgradeFixture.hash(project.package)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        // A version 1 or 2 package only asks about the lock at opening: the folder is tried at the first edit.
        #expect(session.access == .editable)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.document == .legacy(for: project))
        #expect(session.access == .readOnly(.diskNotWritable))
        await session.close()
        #expect(try await UpgradeFixture.hash(project.package) == before)
    }
}

// MARK: - Crashes and undo

@MainActor @Test func crashBetweenManifestAndLogOpensLegacy() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        // The upgrade got to rewrite the manifest (2), not to write the log (3).
        try await UpgradeFixture.write(UpgradeFixture.upgraded(project.manifest), to: project.package)
        let manifest = try Data(contentsOf: project.package.manifestURL)
        let legacy = EditDocument.legacy(for: project)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.document == legacy)
        #expect(session.notices == [.legacyLook])
        #expect(session.access == .editable)
        #expect(session.caches.directory.lastPathComponent == ProjectID.derived(from: project.manifest))

        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .applied)
        #expect(await session.flushed() == 2)
        var created = legacy
        created.logSequence = 1
        let entries = try UpgradeFixture.entries(project.package)
        #expect(entries.count == 2)
        #expect(entries.first == .create(seq: 1, document: created, app: UpgradeFixture.app))
        if case let .do(seq, group, label, _, _)? = entries.last {
            #expect((seq, group, label) == (2, 2, "style.padding"))
        } else {
            Issue.record("no do line: \(entries)")
        }
        await session.close()
        #expect(try Data(contentsOf: project.package.manifestURL) == manifest)
    }
}

@MainActor @Test func undoingTheFirstEditOfALegacyProjectGivesTheLegacyDocument() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        let caches = dir.appending(path: "Caches")
        let legacy = EditDocument.legacy(for: project)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 2)
        #expect(session.undo() == .applied)
        // The legacy document, at the line of the undo.
        #expect(UpgradeFixture.state(session.document) == UpgradeFixture.state(legacy))
        #expect(session.document.logSequence == 3)
        #expect(await session.flushed() == 3)
        await session.close()

        let again = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: caches))
        #expect(UpgradeFixture.state(again.document) == UpgradeFixture.state(legacy))
        #expect(again.undoLabel == nil)
        #expect(again.redoLabel == .padding)
        #expect(again.redo() == .applied)
        #expect(again.document.style.padding == 0.1)
        await again.close()
    }
}

// MARK: - The upgrade alone

@Test func upgradeWithoutAStepWritesOnlyTheCreate() throws {
    try withTemporaryDirectory { dir in
        // A take of events only: no video to write, so it builds without suspending.
        let builder = try TakeBuilder(in: dir, formatVersion: 2)
        try builder.addEvents(UpgradeFixture.cursor)
        let project = try builder.write()
        let legacy = EditDocument.legacy(for: project)
        let result = try UpgradeFixture.withFolder(project.package) { folder in
            try PackageUpgrade.upgrade(
                project.package, folder: folder, opened: project.manifest, legacy: legacy, first: nil,
                context: UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        }
        guard case let .upgraded(lock, manifest) = result else {
            Issue.record("not upgraded: \(result)")
            return
        }
        defer { lock.release() }
        #expect(manifest == UpgradeFixture.upgraded(project.manifest))
        #expect(try UpgradeFixture.manifest(project.package) == manifest)
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        var created = legacy
        created.logSequence = 1
        let log = String(decoding: try Data(contentsOf: project.package.editLogURL), as: UTF8.self)
        #expect(log.split(separator: "\n").count == 1)
        #expect(log.hasSuffix("\n"))
        #expect(try UpgradeFixture.entries(project.package) == [.create(seq: 1, document: created, app: UpgradeFixture.app)])
        #expect(!FileManager.default.fileExists(atPath: project.package.editURL.path))
    }
}

@Test func anUpgradeThatFindsAnotherManifestWritesNothing() throws {
    try withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, formatVersion: 1)
        try builder.addEvents(UpgradeFixture.cursor)
        let project = try builder.write()
        var other = project.manifest
        other.app = AppInfo(name: "Other", version: "9")
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(other), to: project.package.manifestURL)
        let before = try treeHash(project.package.url)
        let legacy = EditDocument.legacy(for: project)
        let result = try UpgradeFixture.withFolder(project.package) { folder in
            try PackageUpgrade.upgrade(
                project.package, folder: folder, opened: project.manifest, legacy: legacy,
                first: try UpgradeFixture.padding(legacy, 0.1),
                context: UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        }
        guard case .changedMeanwhile = result else {
            Issue.record("not changedMeanwhile: \(result)")
            return
        }
        // The lock was taken and let go: its file goes with it.
        #expect(try treeHash(project.package.url) == before)
        #expect(!RecordingLock.isHeld(at: project.package.editLockURL))
    }
}

@Test func aProbeOfTheLockIsNotAnotherApp() throws {
    try withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, formatVersion: 2)
        try builder.addEvents(UpgradeFixture.cursor)
        let project = try builder.write()
        // What `RecordingLock.isHeld` does from another opener, on the lock file a crash left: the lock for a moment.
        try Data().write(to: project.package.editLockURL)
        let probe = open(project.package.editLockURL.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        #expect(probe >= 0)
        // Let go 10 ms in, on a thread of its own (a queue's worker can be late while the other tests sync): well
        // inside the retries, and after the first attempt.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.010)
            close(probe)
        }
        let legacy = EditDocument.legacy(for: project)
        let result = try UpgradeFixture.withFolder(project.package) { folder in
            try PackageUpgrade.upgrade(
                project.package, folder: folder, opened: project.manifest, legacy: legacy, first: nil,
                context: UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        }
        guard case let .upgraded(lock, _) = result else {
            Issue.record("not upgraded: \(result)")
            return
        }
        lock.release()
    }
}
