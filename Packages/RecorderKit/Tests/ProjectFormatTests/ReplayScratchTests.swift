// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the Replay uses only the public API.
import ProjectFormat

// Milestone 5c, Task R1 (fases 4 y 5 design §10.2): the Replay's working package lives outside the library, carries a
// marker before any take, is never a project and is deleted whole.

private let testApp = AppInfo(name: "Toma", version: "0.5.0")

private func fileType(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}

/// Gives the scratch its take folder and a lock file, as the recorder does, holding the lock if `held`.
private func addTakeFolder(to package: ProjectPackage, held: Bool) throws -> HeldRecordingLock? {
    let take = package.takeDirectory(ReplayScratch.takeID)
    try FileManager.default.createDirectory(
        at: take.appendingPathComponent("display-1", isDirectory: true), withIntermediateDirectories: true)
    try Data("frames".utf8).write(to: take.appendingPathComponent("display-1/seg-0001.mov"))
    let lock = try RecordingLock.acquire(at: package.lockURL(take: ReplayScratch.takeID), info: .current(now: Date()))
    guard held else {
        // The lock file a crashed recorder leaves: nobody holds it.
        lock.release()
        try Data("{}".utf8).write(to: package.lockURL(take: ReplayScratch.takeID))
        return nil
    }
    return lock
}

@Suite struct ReplayScratchTests {
    @Test func createdScratchHasTheMarkerBeforeAnyTake() throws {
        try withTemporaryDirectory { dir in
            // `create` makes the root itself, intermediate folders included.
            let root = ReplayScratch.defaultRoot(
                cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true), bundleID: "dev.toma.Toma")
            #expect(root.path.hasSuffix("/Caches/dev.toma.Toma/Replay"))

            let package = try ReplayScratch.create(in: root, app: testApp, now: Date())

            #expect(package == ReplayScratch.package(in: root))
            #expect(package.url.lastPathComponent == ReplayScratch.packageName)
            #expect(ReplayScratch.isScratch(package))
            #expect(fileType(package.url.appendingPathComponent(ReplayScratch.markerName)) == S_IFREG)
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            #expect(manifest.takes.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: package.takesURL.path).isEmpty)
        }
    }

    @Test func aProjectIsNotAScratch() throws {
        try withTemporaryDirectory { dir in
            let project = try ProjectPackage.create(in: dir, name: "Mine", app: testApp, now: Date())
            #expect(!ReplayScratch.isScratch(project))
            // A link where the marker goes is never followed nor taken for one.
            let elsewhere = dir.appendingPathComponent("elsewhere")
            try Data().write(to: elsewhere)
            try FileManager.default.createSymbolicLink(
                at: project.url.appendingPathComponent(ReplayScratch.markerName), withDestinationURL: elsewhere)
            #expect(!ReplayScratch.isScratch(project))
        }
    }

    @Test func scratchInUseIsRefused() throws {
        try withTemporaryDirectory { dir in
            let package = try ReplayScratch.create(in: dir, app: testApp, now: Date())
            let lock = try addTakeFolder(to: package, held: true)

            #expect(throws: ReplayError.scratchInUse) {
                try ReplayScratch.create(in: dir, app: testApp, now: Date())
            }
            withExtendedLifetime(lock) {
                #expect(ReplayScratch.isScratch(package))
                #expect(FileManager.default.fileExists(atPath: package.segmentURL(take: "take-001", track: "display-1", index: 1).path))
            }
            lock?.release()
        }
    }

    @Test func staleScratchIsReplaced() throws {
        try withTemporaryDirectory { dir in
            let old = try ReplayScratch.create(in: dir, app: testApp, now: Date())
            let oldID = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: old.manifestURL)).projectID
            _ = try addTakeFolder(to: old, held: false)

            let package = try ReplayScratch.create(in: dir, app: testApp, now: Date())

            #expect(package == old)
            #expect(ReplayScratch.isScratch(package))
            #expect(!FileManager.default.fileExists(atPath: package.takeDirectory("take-001").path))
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            #expect(manifest.takes.isEmpty)
            #expect(manifest.projectID != oldID)
            // Nothing else is left in the root: the old one went whole.
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [ReplayScratch.packageName])
        }
    }

    @Test func onlyTheScratchAndItsHalfDeletedFoldersGo() throws {
        try withTemporaryDirectory { dir in
            let live = try ReplayScratch.create(in: dir, app: testApp, now: Date())
            let lock = try addTakeFolder(to: live, held: true)
            // What is not the Replay's stays, whatever it is: a root given by mistake (a library) loses nothing.
            let project = dir.appendingPathComponent("old.toma", isDirectory: true)
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent("takes/take-001", isDirectory: true), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("loose.txt"))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".hidden", isDirectory: true), withIntermediateDirectories: false)
            // A deletion cut short.
            let halfDeleted = dir.appendingPathComponent(".discarding-1234", isDirectory: true)
            try FileManager.default.createDirectory(
                at: halfDeleted.appendingPathComponent("takes", isDirectory: true), withIntermediateDirectories: true)

            let removed = ReplayScratch.discardLeftovers(in: dir)

            #expect(removed.map(\.lastPathComponent) == [".discarding-1234"])
            let others = [".hidden", "loose.txt", "old.toma"]
            withExtendedLifetime(lock) {
                #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() == (others + [ReplayScratch.packageName]).sorted())
                #expect(ReplayScratch.isScratch(live))
            }

            // Once its recorder is gone, the scratch is a leftover too.
            lock?.release()
            #expect(ReplayScratch.discardLeftovers(in: dir).map(\.lastPathComponent) == [ReplayScratch.packageName])
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == others)
        }
    }

    /// A `current.toma` without the marker that holds a take is not the Replay's: neither the cleanup nor `create` deletes
    /// it. A file of that name neither.
    @Test func aCurrentTomaThatIsNotAScratchIsNeverDeleted() throws {
        try withTemporaryDirectory { dir in
            let project = try ProjectPackage.create(in: dir, name: "current", app: testApp, now: Date())
            try FileManager.default.createDirectory(at: project.takeDirectory("take-001"), withIntermediateDirectories: false)
            let store = try ManifestStore(package: project)
            try store.update { $0.takes.append(TakeRecord(id: "take-001", status: .complete, startedAt: Date(), tracks: [])) }

            #expect(ReplayScratch.discardLeftovers(in: dir).isEmpty)
            #expect(throws: POSIXError(.EEXIST)) { try ReplayScratch.create(in: dir, app: testApp, now: Date()) }
            #expect(fileType(project.manifestURL) == S_IFREG)
            #expect(fileType(project.takeDirectory("take-001")) == S_IFDIR)

            try FileManager.default.removeItem(at: project.url)
            try Data("x".utf8).write(to: project.url)
            #expect(ReplayScratch.discardLeftovers(in: dir).isEmpty)
            #expect(throws: POSIXError(.EEXIST)) { try ReplayScratch.create(in: dir, app: testApp, now: Date()) }
            #expect(fileType(project.url) == S_IFREG)
        }
    }

    /// What `create` leaves if it is cut before the marker (a package without a take) goes, by the cleanup or by the next
    /// `create`.
    @Test func aScratchCutBeforeItsMarkerGoes() throws {
        try withTemporaryDirectory { dir in
            let cut = try ProjectPackage.create(in: dir, name: "current", app: testApp, now: Date())
            #expect(!ReplayScratch.isScratch(cut))
            #expect(ReplayScratch.discardLeftovers(in: dir).map(\.lastPathComponent) == [ReplayScratch.packageName])
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

            // No manifest at all (cut before it was written), and `create` replaces it.
            try FileManager.default.createDirectory(
                at: ReplayScratch.package(in: dir).takesURL, withIntermediateDirectories: true)
            let package = try ReplayScratch.create(in: dir, app: testApp, now: Date())
            #expect(ReplayScratch.isScratch(package))
        }
    }

    @Test func aLinkedRootIsLeftAlone() throws {
        try withTemporaryDirectory { dir in
            let real = dir.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            let keep = real.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: keep)
            let root = dir.appendingPathComponent("Replay", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)

            #expect(ReplayScratch.discardLeftovers(in: root).isEmpty)
            #expect(FileManager.default.fileExists(atPath: keep.path))
            #expect(throws: (any Error).self) { try ReplayScratch.create(in: root, app: testApp, now: Date()) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: real.path) == ["keep.txt"])
        }
    }

    @Test func aLinkInTheRootGoesButNotWhatItNames() throws {
        try withTemporaryDirectory { dir in
            let root = dir.appendingPathComponent("Replay", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let outside = dir.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let keep = outside.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: keep)
            // A link named like the scratch, and another one.
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(ReplayScratch.packageName), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("other"), withDestinationURL: outside)

            // The one named like the scratch goes, never what it names; the other is not the Replay's and stays.
            #expect(ReplayScratch.discardLeftovers(in: root).map(\.lastPathComponent) == [ReplayScratch.packageName])
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["other"])
            #expect(FileManager.default.fileExists(atPath: keep.path))
        }
    }

    @Test func discardRemovesTheScratchButNeverAProject() throws {
        try withTemporaryDirectory { dir in
            let package = try ReplayScratch.create(in: dir, app: testApp, now: Date())
            _ = try addTakeFolder(to: package, held: false)
            try ReplayScratch.discard(package)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            // Discarding what is not there is done already.
            try ReplayScratch.discard(package)

            let project = try ProjectPackage.create(in: dir, name: "Mine", app: testApp, now: Date())
            #expect(throws: (any Error).self) { try ReplayScratch.discard(project) }
            #expect(fileType(project.manifestURL) == S_IFREG)
        }
    }

    @Test func shardsAreNumberedInTheTakeFolder() throws {
        let package = ReplayScratch.package(in: URL(fileURLWithPath: "/tmp/Replay", isDirectory: true))
        #expect(ReplayScratch.shardURL(of: package, index: 1).path == "/tmp/Replay/current.toma/takes/take-001/events-0001.jsonl")
        #expect(ReplayScratch.shardURL(of: package, index: 12).deletingLastPathComponent().path == package.takeDirectory("take-001").path)
        #expect(ReplayScratch.shardURL(of: package, index: 12).lastPathComponent == "events-0012.jsonl")
    }
}
