// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProjectFormat

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectFormatTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

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
        #expect(package.relativePath(of: segment) == "takes/take-001/display-1/seg-0001.mov")
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

@Test func atomicWriteNeverLeavesPartialManifest() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Demo", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        let reader = Task.detached { () -> (reads: Int, failures: Int) in
            var reads = 0
            var failures = 0
            while !Task.isCancelled {
                reads += 1
                do {
                    _ = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
                } catch {
                    failures += 1
                }
            }
            return (reads, failures)
        }
        for i in 1...200 {
            try store.update { $0.takes.append(take("take-\(i)")) }
        }
        reader.cancel()
        let result = await reader.value
        #expect(result.reads > 0)
        #expect(result.failures == 0)
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
