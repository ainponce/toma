// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing

@testable import Recording

@Suite struct DiskSpaceTests {
    @Test(arguments: [
        (DiskCapacity(importantUsage: 1_500_000_000, available: 1_500_000_000), false, DiskSpaceVerdict.refuseToStart(availableBytes: 1_500_000_000)),
        (DiskCapacity(importantUsage: 3_000_000_000, available: 3_000_000_000), false, .warn(availableBytes: 3_000_000_000)),
        (DiskCapacity(importantUsage: 10_000_000_000, available: 10_000_000_000), false, .ok),
        (DiskCapacity(importantUsage: 9_000_000_000, available: 900_000_000), true, .stopNow(availableBytes: 900_000_000)),
        (DiskCapacity(importantUsage: 4_000_000_000, available: 4_000_000_000), true, .warn(availableBytes: 4_000_000_000)),
    ])
    func policy(capacity: DiskCapacity, recording: Bool, expected: DiskSpaceVerdict) {
        #expect(DiskSpacePolicy().evaluate(capacity, isRecording: recording) == expected)
    }

    @Test func iCloudFolderIsNotAllowedEvenIfMissing() throws {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/nope/x.toma")
        #expect(try VolumeEligibility.check(u) == .syncedFolder)
    }

    @Test func cloudStorageFolderIsNotAllowed() throws {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage/Dropbox/x.toma")
        #expect(try VolumeEligibility.check(u) == .syncedFolder)
    }

    @Test func notYetCreatedPackageInTempIsAllowed() throws {
        let u = FileManager.default.temporaryDirectory.appending(path: "nuevo/x.toma")
        #expect(try VolumeEligibility.check(u) == .allowed)
    }

    @Test func realVolumeCapacityIsReadable() throws {
        let c = try DiskSpaceMonitor.capacity(FileManager.default.temporaryDirectory)
        #expect(c.available > 0)
        #expect(c.importantUsage > 0)
    }

    @Test func monitorReportsStopNow() async throws {
        let monitor = DiskSpaceMonitor(
            volumeURL: FileManager.default.temporaryDirectory,
            interval: .milliseconds(200),
            query: { _ in DiskCapacity(importantUsage: 9_000_000_000, available: 500_000_000) })
        let (stream, continuation) = AsyncStream.makeStream(of: DiskSpaceVerdict.self)
        monitor.start { continuation.yield($0) }
        defer { monitor.stop() }
        let first = try #require(await firstVerdict(of: stream))
        #expect(first == .stopNow(availableBytes: 500_000_000))
    }

    @Test func throwingQueryIsRetriedOnNextTick() async throws {
        struct Boom: Error {}
        let calls = Mutex(0)
        let monitor = DiskSpaceMonitor(
            volumeURL: FileManager.default.temporaryDirectory,
            interval: .milliseconds(50),
            query: { _ in
                let n = calls.withLock { $0 += 1; return $0 }
                if n == 1 { throw Boom() }
                return DiskCapacity(importantUsage: 10_000_000_000, available: 10_000_000_000)
            })
        let (stream, continuation) = AsyncStream.makeStream(of: DiskSpaceVerdict.self)
        monitor.start { continuation.yield($0) }
        defer { monitor.stop() }
        let first = try #require(await firstVerdict(of: stream))
        #expect(first == .ok)
        #expect(calls.withLock { $0 } >= 2)
    }

    @Test func stopIsIdempotentAndHaltsVerdicts() async throws {
        let count = Mutex(0)
        let monitor = DiskSpaceMonitor(
            volumeURL: FileManager.default.temporaryDirectory,
            interval: .milliseconds(20),
            query: { _ in DiskCapacity(importantUsage: 10_000_000_000, available: 10_000_000_000) })
        monitor.start { _ in count.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(100))
        monitor.stop()
        monitor.stop()
        try await Task.sleep(for: .milliseconds(50))
        let frozen = count.withLock { $0 }
        #expect(frozen >= 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(count.withLock { $0 } == frozen)
    }

    @Test func startTwiceReplacesPreviousTimer() async throws {
        let a = Mutex(0), b = Mutex(0)
        let monitor = DiskSpaceMonitor(
            volumeURL: FileManager.default.temporaryDirectory,
            interval: .milliseconds(20),
            query: { _ in DiskCapacity(importantUsage: 10_000_000_000, available: 10_000_000_000) })
        monitor.start { _ in a.withLock { $0 += 1 } }
        monitor.start { _ in b.withLock { $0 += 1 } }
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(50))
        let frozenA = a.withLock { $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.withLock { $0 } == frozenA)
        #expect(b.withLock { $0 } > 1)
    }

    @Test func droppedMonitorStopsPolling() async throws {
        let calls = Mutex(0)
        do {
            let monitor = DiskSpaceMonitor(
                volumeURL: FileManager.default.temporaryDirectory,
                interval: .milliseconds(20),
                query: { _ in
                    calls.withLock { $0 += 1 }
                    return DiskCapacity(importantUsage: 10_000_000_000, available: 10_000_000_000)
                })
            monitor.start { _ in }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(100))
        let frozen = calls.withLock { $0 }
        #expect(frozen >= 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.withLock { $0 } == frozen)
    }

    @Test func verdictUsesInjectedQuery() throws {
        let monitor = DiskSpaceMonitor(
            volumeURL: FileManager.default.temporaryDirectory,
            query: { _ in DiskCapacity(importantUsage: 1_500_000_000, available: 1_500_000_000) })
        #expect(try monitor.verdict(isRecording: false) == .refuseToStart(availableBytes: 1_500_000_000))
    }
}

/// First verdict from `stream`, or nil after 5 s so a timer that never fires fails instead of hanging.
private func firstVerdict(of stream: AsyncStream<DiskSpaceVerdict>) async -> DiskSpaceVerdict? {
    await withTaskGroup(of: DiskSpaceVerdict?.self) { group in
        group.addTask { await stream.first { _ in true } }
        group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
