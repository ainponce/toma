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

    static func context(
        caches: URL, clock: Clock = Clock(), io: EditJournalIO = .system, upgradeIO: PackageUpgradeIO = .system
    ) -> EditContext {
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma, now: { clock.now() },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            journalIO: io, upgradeIO: upgradeIO)
    }

    /// The upgrade's writes, failing for a file while a code is set for its name, and those that went through counted;
    /// and its pauses at the lock, counted and handed to `onPause` in place of the wait.
    final class Writes: Sendable {
        private struct State {
            var failing: [String: POSIXErrorCode] = [:]
            var written: [String: Int] = [:]
            var pauses = 0
        }

        private let state = Mutex(State())
        private let onPause: @Sendable () -> Void

        init(onPause: @escaping @Sendable () -> Void = {}) {
            self.onPause = onPause
        }

        func fail(_ name: String, with code: POSIXErrorCode?) { state.withLock { $0.failing[name] = code } }
        func written(_ name: String) -> Int { state.withLock { $0.written[name, default: 0] } }
        var pauses: Int { state.withLock { $0.pauses } }

        var io: PackageUpgradeIO {
            PackageUpgradeIO(
                write: { [self] data, name, directory in
                    if let code = state.withLock({ $0.failing[name] }) { throw POSIXError(code) }
                    try PackageUpgradeIO.system.write(data, name, directory)
                    state.withLock { $0.written[name, default: 0] += 1 }
                },
                pause: { [self] _ in
                    state.withLock { $0.pauses += 1 }
                    onPause()
                })
        }
    }

    /// The kind of each line of the log, its `seq` and group: `do 2 2 style.padding`.
    static func shape(_ package: ProjectPackage) throws -> [String] {
        try entries(package).map { entry in
            switch entry {
            case let .create(seq, _, _): "create \(seq)"
            case let .do(seq, group, label, _, _): "do \(seq) \(group) \(label)"
            case let .undo(seq, group): "undo \(seq) \(group)"
            case let .redo(seq, group): "redo \(seq) \(group)"
            case let .migrate(seq, _, _): "migrate \(seq)"
            }
        }
    }

    static func isSaveFailed(_ notice: EditNotice) -> Bool {
        if case .saveFailed = notice { true } else { false }
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
        // It is not a project without edits any more.
        #expect(!session.notices.contains(.legacyLook))
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
        #expect(
            try UpgradeFixture.shape(project.package) == ["create 1", "do 2 2 style.padding", "do 3 3 style.shadow", "undo 4 3"])
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

// MARK: - Errors that pass

@MainActor @Test func aLogThatCannotBeOpenedYetKeepsEveryStep() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let context = UpgradeFixture.context(caches: dir.appending(path: "Caches"), io: UpgradeFixture.failingOpens(1))
        let session = try await UpgradeFixture.open(project, context)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        // The upgrade is on disk, its log not open for appending yet: the step after the first waits in memory.
        #expect(await session.flushed() == 2)
        #expect(session.notices.contains(.saveFailed(.EMFILE)))
        #expect(session.hasUnsavedChanges)
        #expect(session.access == .editable)
        #expect(session.document.style.shadow == 0.3)
        #expect(session.project.manifest == UpgradeFixture.upgraded(project.manifest))
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        // The next attempt opens it, and the step goes after the first.
        #expect(await eventually(timeout: .seconds(10)) { !session.hasUnsavedChanges })
        #expect(!session.notices.contains(where: UpgradeFixture.isSaveFailed))
        #expect(try UpgradeFixture.shape(project.package) == ["create 1", "do 2 2 style.padding", "do 3 3 style.shadow"])
        #expect(session.document.style.shadow == 0.3)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.2)) == .applied)
        #expect(await session.flushed() == 4)
        await session.close()
    }
}

/// A full disk at `name` (the manifest or the log) during the upgrade: the steps wait in memory, in order, with the amber
/// notice, and are all on disk once there is room; the manifest is written once.
@MainActor private func fullDiskKeepsEveryStep(at name: String) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        let writes = UpgradeFixture.Writes()
        writes.fail(name, with: .ENOSPC)
        let session = try await UpgradeFixture.open(
            project, UpgradeFixture.context(caches: dir.appending(path: "Caches"), upgradeIO: writes.io))
        let manifest = try Data(contentsOf: project.package.manifestURL)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.notices.contains(.saveFailed(.ENOSPC)))
        #expect(session.hasUnsavedChanges)
        #expect(session.access == .editable)
        // The lock stays: nobody else gets in between two attempts.
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        if name == "manifest.json" {
            #expect(try Data(contentsOf: project.package.manifestURL) == manifest)
        } else {
            #expect(try UpgradeFixture.manifest(project.package) == UpgradeFixture.upgraded(project.manifest))
            #expect(session.project.manifest == UpgradeFixture.upgraded(project.manifest))
        }
        #expect(!FileManager.default.fileExists(atPath: project.package.editLogURL.path))
        // Editing goes on.
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        #expect(session.undo() == .pendingUpgrade)
        #expect(session.redo() == .pendingUpgrade)
        #expect(session.document.style.shadow == 0.3)

        writes.fail(name, with: nil)
        #expect(await eventually(timeout: .seconds(10)) { !session.hasUnsavedChanges })
        #expect(!session.notices.contains(where: UpgradeFixture.isSaveFailed))
        #expect(
            try UpgradeFixture.shape(project.package)
                == ["create 1", "do 2 2 style.padding", "do 3 3 style.shadow", "undo 4 3", "redo 5 3"])
        #expect(try UpgradeFixture.manifest(project.package) == UpgradeFixture.upgraded(project.manifest))
        #expect(writes.written("manifest.json") == 1)
        #expect(writes.written("edit-log.jsonl") == 1)
        #expect(session.document.style.padding == 0.1)
        #expect(session.document.style.shadow == 0.3)
        await session.close()

        let again = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(UpgradeFixture.state(again.document) == UpgradeFixture.state(session.document))
        await again.close()
    }
}

@MainActor @Test func aFullDiskAtTheManifestKeepsEveryStepAndTriesAgain() async throws {
    try await fullDiskKeepsEveryStep(at: "manifest.json")
}

@MainActor @Test func aFullDiskAtTheLogKeepsEveryStepAndTriesAgain() async throws {
    try await fullDiskKeepsEveryStep(at: "edit-log.jsonl")
}

@MainActor @Test func aManifestMissingAtTheLockIsAskedAboutAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        // For a moment the manifest cannot be read at step 1: the lock is let go and it is all asked again.
        let aside = dir.appending(path: "manifest.aside")
        try FileManager.default.moveItem(at: project.package.manifestURL, to: aside)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.notices.contains(.saveFailed(.ENOENT)))
        #expect(!RecordingLock.isHeld(at: project.package.editLockURL))
        try FileManager.default.moveItem(at: aside, to: project.package.manifestURL)
        #expect(await eventually(timeout: .seconds(10)) { !session.hasUnsavedChanges })
        #expect(try UpgradeFixture.shape(project.package) == ["create 1", "do 2 2 style.padding"])
        #expect(try UpgradeFixture.manifest(project.package) == UpgradeFixture.upgraded(project.manifest))
        await session.close()
    }
}

// MARK: - Errors that never pass, and other processes

@MainActor @Test func aReadOnlyVolumeDiscardsTheFirstEdit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let writes = UpgradeFixture.Writes()
        writes.fail("manifest.json", with: .EROFS)
        let before = try await UpgradeFixture.hash(project.package)
        let session = try await UpgradeFixture.open(
            project, UpgradeFixture.context(caches: dir.appending(path: "Caches"), upgradeIO: writes.io))
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.document == .legacy(for: project))
        #expect(session.access == .readOnly(.diskNotWritable))
        #expect(!session.notices.contains(where: UpgradeFixture.isSaveFailed))
        #expect(!session.hasUnsavedChanges)
        await session.close()
        #expect(try await UpgradeFixture.hash(project.package) == before)
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
        // What `RecordingLock.isHeld` does from another opener, on the lock file a crash left: the lock for a moment. It
        // lets go at the upgrade's first pause, which comes only after an attempt met it.
        try Data().write(to: project.package.editLockURL)
        let probe = Mutex(open(project.package.editLockURL.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC))
        #expect(probe.withLock { $0 } >= 0)
        let writes = UpgradeFixture.Writes {
            probe.withLock { fd in
                if fd >= 0 { close(fd) }
                fd = -1
            }
        }
        let legacy = EditDocument.legacy(for: project)
        let result = try UpgradeFixture.withFolder(project.package) { folder in
            try PackageUpgrade.upgrade(
                project.package, folder: folder, opened: project.manifest, legacy: legacy, first: nil,
                context: UpgradeFixture.context(caches: dir.appending(path: "Caches"), upgradeIO: writes.io))
        }
        guard case let .upgraded(lock, _) = result else {
            Issue.record("not upgraded: \(result)")
            return
        }
        #expect(writes.pauses == 1)
        lock.release()
    }
}

@MainActor @Test func closingRightAfterTheFirstEditLogsEveryStep() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(session.perform(try UpgradeFixture.step(session.document, "/style/shadow", 0.3, .shadow)) == .pendingUpgrade)
        await session.close()
        #expect(!session.hasUnsavedChanges)
        #expect(try UpgradeFixture.shape(project.package) == ["create 1", "do 2 2 style.padding", "do 3 3 style.shadow"])
        #expect(try UpgradeFixture.manifest(project.package) == UpgradeFixture.upgraded(project.manifest))
        #expect(!RecordingLock.isHeld(at: project.package.editLockURL))
        #expect(!FileManager.default.fileExists(atPath: project.package.editLockURL.path))
    }
}

@MainActor @Test func aLegacyPackageChangedButNotUpgradedIsLegacyAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        // Another process rewrote the manifest (a recovery, say) and left it at version 1.
        var changed = project.manifest
        changed.app = AppInfo(name: "Recovery", version: "1")
        try await UpgradeFixture.write(changed, to: project.package)
        let before = try await UpgradeFixture.hash(project.package)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.document == .legacy(for: project))
        #expect(session.notices == [.legacyLook, .reopenedAfterOtherApp])
        #expect(session.access == .editable)
        #expect(session.project.manifest == changed)
        // Nothing was written: the lock taken for step 1 went with its file.
        #expect(try await UpgradeFixture.hash(project.package) == before)
        // The next edit upgrades the manifest as it is now.
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 2)
        #expect(try UpgradeFixture.manifest(project.package) == UpgradeFixture.upgraded(changed))
        #expect(session.access == .editable)
        await session.close()
    }
}

@MainActor @Test func aStaleLockLeftByACrashIsTakenOverAtTheFirstEdit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 2)
        // A crash after step 1: the lock file stays, and locks nothing.
        let stale = #"{"bootSessionUUID":"","pid":1,"startedAt":"2026-11-15T20:12:03Z"}"#
        try Data(stale.utf8).write(to: project.package.editLockURL)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .editable)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 2)
        #expect(session.access == .editable)
        #expect(RecordingLock.isHeld(at: project.package.editLockURL))
        #expect(RecordingLock.readInfo(at: project.package.editLockURL)?.pid == getpid())
        #expect(try UpgradeFixture.shape(project.package) == ["create 1", "do 2 2 style.padding"])
        await session.close()
    }
}

/// Another process changes the package's manifest to `manifest` before the first edit: the edit is discarded and,
/// since the package cannot be opened any more, nothing of it is shown.
@MainActor private func unopenableAfterAnotherApp(_ manifest: Data, gives reason: ReadOnlyReason) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await UpgradeFixture.package(in: dir, formatVersion: 1)
        let session = try await UpgradeFixture.open(project, UpgradeFixture.context(caches: dir.appending(path: "Caches")))
        try manifest.write(to: project.package.manifestURL)
        let before = try await UpgradeFixture.hash(project.package)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.1)) == .pendingUpgrade)
        #expect(await session.flushed() == 0)
        #expect(session.access == .readOnly(reason))
        #expect(!session.hasUnsavedChanges)
        #expect(session.undoLabel == nil)
        #expect(session.perform(try UpgradeFixture.padding(session.document, 0.2)) == .refused)
        await session.close()
        #expect(try await UpgradeFixture.hash(project.package) == before)
    }
}

@MainActor @Test func aPackageMovedToANewerFormatMeanwhileShowsNothing() async throws {
    let newer = Data(#"{"formatVersion":4,"somethingNew":true}"#.utf8)
    try await unopenableAfterAnotherApp(newer, gives: .newerDocument(4))
}

@MainActor @Test func aManifestThatNoLongerDecodesShowsNothing() async throws {
    try await unopenableAfterAnotherApp(Data("not a manifest".utf8), gives: .unreadable)
}
