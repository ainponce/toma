// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing
@testable import ProjectFormat

private let testApp = AppInfo(name: "Toma", version: "0.1.0")
private let testDate = Date(timeIntervalSince1970: 1_700_000_000)

private func take(_ id: String) -> TakeRecord {
    TakeRecord(id: id, status: .complete, startedAt: testDate, tracks: [])
}

// MARK: - ProjectPackage

@Test func packageLayout() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate.addingTimeInterval(0.75))
        #expect(ProjectPackage.fileExtension == "toma")
        #expect(package.url.lastPathComponent == "Demo.toma")
        #expect(package.url.pathExtension == "toma")
        #expect(package.manifestURL.lastPathComponent == "manifest.json")
        #expect(FileManager.default.fileExists(atPath: package.manifestURL.path))
        #expect(package.editURL.path.hasSuffix("Demo.toma/edit.json"))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: package.url.appendingPathComponent("takes").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: package.cacheURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(package.cacheURL.path.hasSuffix("Demo.toma/cache"))

        let segment = package.segmentURL(take: "take-001", track: "display-1", index: 1)
        #expect(segment.path.hasSuffix("Demo.toma/takes/take-001/display-1/seg-0001.mov"))
        #expect(package.segmentURL(take: "take-001", track: "mic", index: 12).lastPathComponent == "seg-0012.mov")
        #expect(try package.relativePath(of: segment) == "takes/take-001/display-1/seg-0001.mov")
        #expect(package.takeDirectory("take-001").path.hasSuffix("Demo.toma/takes/take-001"))
        #expect(package.trackDirectory(take: "take-001", track: "mic").path.hasSuffix("Demo.toma/takes/take-001/mic"))
        #expect(package.eventsURL(take: "take-001").path.hasSuffix("Demo.toma/takes/take-001/events.jsonl"))
        #expect(package.lockURL(take: "take-001").path.hasSuffix("Demo.toma/takes/take-001/recording.lock"))

        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
        #expect(manifest == Manifest(formatVersion: Manifest.currentFormatVersion, app: testApp, createdAt: testDate, takes: []))
        #expect(!FileManager.default.fileExists(atPath: package.manifestURL.path + ".tmp"))
    }
}

@Test func createRefusesExistingPackage() async throws {
    try await withTemporaryDirectory { dir in
        let first = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let before = try Data(contentsOf: first.manifestURL)
        let error = #expect(throws: CocoaError.self) {
            try ProjectPackage.create(in: dir, name: "Demo", app: AppInfo(name: "Other", version: "9"), now: testDate.addingTimeInterval(60))
        }
        #expect(error?.code == .fileWriteFileExists)
        #expect(try Data(contentsOf: first.manifestURL) == before)
    }
}

@Test func createDoesNotMakeIntermediateDirectories() async throws {
    try await withTemporaryDirectory { dir in
        #expect(throws: (any Error).self) {
            try ProjectPackage.create(in: dir.appendingPathComponent("missing"), name: "Demo", app: testApp, now: testDate)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing").path))
    }
}

@Test func nextTakeIDSkipsFoldersOnDisk() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        #expect(package.nextTakeID(existing: []) == "take-001")
        try FileManager.default.createDirectory(at: package.takeDirectory("take-002"), withIntermediateDirectories: false)
        #expect(package.nextTakeID(existing: [take("take-001")]) == "take-003")
    }
}

@Test func nextTakeIDNeverReusesNumbers() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        #expect(package.nextTakeID(existing: [take("take-003")]) == "take-004")
    }
}

@Test func relativePathRejectsURLsOutsideThePackage() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        for outside in [
            dir.appendingPathComponent("elsewhere.mov"),
            dir.appendingPathComponent("Demo.toma-copy/takes/take-001/mic/seg-0001.mov"),
            package.url,
        ] {
            #expect(throws: ProjectPackageError.notInsidePackage(outside)) { try package.relativePath(of: outside) }
        }
    }
}

@Test func relativePathResolvesASymlinkedParent() async throws {
    try await withTemporaryDirectory { dir in
        let real = dir.appendingPathComponent("real", isDirectory: true)
        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let package = try ProjectPackage.create(in: real, name: "Demo", app: testApp, now: testDate)
        let viaLink = ProjectPackage(url: link.appendingPathComponent("Demo.toma", isDirectory: true))

        // A file that exists, reached through the link.
        let takeDirectory = package.takeDirectory("take-001")
        try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: false)
        try Data().write(to: package.eventsURL(take: "take-001"))
        #expect(try package.relativePath(of: viaLink.eventsURL(take: "take-001")) == "takes/take-001/events.jsonl")

        // A segment that does not exist yet, under a package opened through the link.
        let segment = package.segmentURL(take: "take-001", track: "display-1", index: 1)
        #expect(try viaLink.relativePath(of: segment) == "takes/take-001/display-1/seg-0001.mov")

        // The temporary directory is itself under a symlink (/var -> /private/var).
        if dir.path.hasPrefix("/var/") {
            let privateSegment = URL(fileURLWithPath: "/private" + segment.path)
            #expect(try package.relativePath(of: privateSegment) == "takes/take-001/display-1/seg-0001.mov")
        }
    }
}

// MARK: - ManifestStore

@Test func concurrentUpdatesAreAllApplied() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...800 {
                group.addTask { try store.update { $0.takes.append(take("take-\(i)")) } }
            }
            try await group.waitForAll()
        }
        #expect(store.manifest.takes.count == 800)
        #expect(Set(store.manifest.takes.map(\.id)).count == 800)
        let reread = try ManifestStore(package: package)
        #expect(reread.manifest == store.manifest)
    }
}

/// Counters shared with the reader thread of `atomicWriteNeverLeavesPartialManifest`.
private final class ReaderCounters: Sendable {
    let started = Atomic<Bool>(false)
    let stop = Atomic<Bool>(false)
    let finished = Atomic<Bool>(false)
    let reads = Atomic<Int>(0)
    let failures = Atomic<Int>(0)
}

@Test func atomicWriteNeverLeavesPartialManifest() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        // A dedicated thread, so the reader runs even while other tests fill the cooperative pool.
        let counters = ReaderCounters()
        Thread {
            counters.started.store(true, ordering: .releasing)
            while !counters.stop.load(ordering: .relaxed) {
                do {
                    _ = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
                } catch {
                    counters.failures.add(1, ordering: .relaxed)
                }
                counters.reads.add(1, ordering: .relaxed)
            }
            counters.finished.store(true, ordering: .releasing)
        }.start()
        while !counters.started.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(1)) }
        for i in 1...200 {
            try store.update { $0.takes.append(take("take-\(i)")) }
        }
        counters.stop.store(true, ordering: .relaxed)
        while !counters.finished.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(1)) }
        #expect(counters.reads.load(ordering: .relaxed) > 0)
        #expect(counters.failures.load(ordering: .relaxed) == 0)
        #expect(try ManifestStore(package: package).manifest.takes.count == 200)
        #expect(!FileManager.default.fileExists(atPath: package.manifestURL.path + ".tmp"))
    }
}

@Test func failedWriteKeepsChangeAndRetries() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        let before = try Data(contentsOf: package.manifestURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path) }
            #expect(throws: (any Error).self) { try store.update { $0.takes.append(take("take-001")) } }
            #expect(store.manifest.takes.map(\.id) == ["take-001"])
            #expect(try Data(contentsOf: package.manifestURL) == before)
            #expect(throws: (any Error).self) { try store.flushPending() }
        }

        try store.flushPending()
        #expect(try ManifestStore(package: package).manifest.takes.map(\.id) == ["take-001"])
    }
}

@Test func failedWriteIsRetriedByTheNextUpdate() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        #expect(throws: (any Error).self) { try store.update { $0.takes.append(take("take-001")) } }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path)

        try store.update { $0.takes.append(take("take-002")) }
        #expect(try ManifestStore(package: package).manifest.takes.map(\.id) == ["take-001", "take-002"])
    }
}

@Test func encodingFailureDoesNotWedgeStore() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        let display = TrackRecord(id: "display-1", kind: .display, source: TrackSource(name: "Display", pixelScale: 2), segments: [])
        try store.update { $0.takes.append(TakeRecord(id: "take-001", status: .recording, startedAt: testDate, tracks: [display])) }

        #expect(throws: EncodingError.self) { try store.update { $0.takes[0].tracks[0].source.pixelScale = .nan } }
        #expect(store.manifest.takes[0].tracks[0].source.pixelScale == 2)

        try store.update { $0.takes[0].status = .complete }
        try store.flushPending()
        let reread = try ManifestStore(package: package).manifest
        #expect(reread == store.manifest)
        #expect(reread.takes[0].status == .complete)
        #expect(reread.takes[0].tracks[0].source.pixelScale == 2)
    }
}

@Test func throwingUpdateBodyChangesNothing() async throws {
    struct Abort: Error {}
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        #expect(throws: Abort.self) {
            try store.update { manifest in
                manifest.takes.append(take("take-001"))
                throw Abort()
            }
        }
        #expect(store.manifest.takes.isEmpty)
    }
}
