// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

extension RecordingLockInfo {
    static let fixture = RecordingLockInfo(
        pid: 4242,
        bootSessionUUID: "5B1C3F0E-7C55-4E0F-9B67-3D1E2A9C8F10",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func heldLockIsDetectedFromSecondOpen() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("recording.lock")
        let held = try RecordingLock.acquire(at: url, info: .fixture)
        #expect(RecordingLock.isHeld(at: url))
        #expect(throws: (any Error).self) { try RecordingLock.acquire(at: url, info: .fixture) }
        held.release()
    }
}

@Test func secondAcquireFailsWithWouldBlock() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("recording.lock")
        let held = try RecordingLock.acquire(at: url, info: .fixture)
        defer { held.release() }
        let error = #expect(throws: POSIXError.self) { try RecordingLock.acquire(at: url, info: .fixture) }
        #expect(error?.code == .EWOULDBLOCK)
        #expect(RecordingLock.readInfo(at: url) == .fixture)
    }
}

@Test func acquireRetriesWhileAnotherHolderReleases() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("recording.lock")
        let held = try RecordingLock.acquire(at: url, info: .fixture)
        let error = await #expect(throws: POSIXError.self) {
            try await RecordingLock.acquire(at: url, info: .fixture, retries: 0)
        }
        #expect(error?.code == .EWOULDBLOCK)

        // Another thread lets go 30 ms in; four retries 100 ms apart wait for it.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.030)
            held.release()
        }
        let lock = try await RecordingLock.acquire(at: url, info: .fixture, retries: 4, retryDelay: .milliseconds(100))
        #expect(RecordingLock.isHeld(at: url))
        #expect(RecordingLock.readInfo(at: url) == .fixture)
        lock.release()
    }
}

@Test func releasedLockIsFree() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("recording.lock")
        let held = try RecordingLock.acquire(at: url, info: .fixture)
        held.release()
        #expect(!RecordingLock.isHeld(at: url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        held.release()
        let again = try RecordingLock.acquire(at: url, info: .fixture)
        again.release()
    }
}

/// `<dir>/A/edit.lock` held, then `A` moved to `B` and another folder put at `A` with its own lock, held by someone
/// else: what a session closing a moved package finds.
private func withMovedLock(
    _ body: (_ moved: HeldRecordingLock, _ old: URL, _ new: URL, _ other: HeldRecordingLock) throws -> Void
) throws {
    try withTemporaryDirectory { dir in
        let old = dir.appendingPathComponent("A", isDirectory: true)
        let new = dir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let moved = try RecordingLock.acquire(at: old.appendingPathComponent("edit.lock"), info: .fixture)
        try FileManager.default.moveItem(at: old, to: new)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let other = try RecordingLock.acquire(at: old.appendingPathComponent("edit.lock"), info: .fixture)
        defer { other.release() }
        try body(moved, old, new, other)
    }
}

@Test func releaseAfterAMoveLeavesTheLockAtTheOldPath() throws {
    try withMovedLock { moved, old, new, _ in
        moved.release()
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("edit.lock").path))
        #expect(RecordingLock.isHeld(at: old.appendingPathComponent("edit.lock")))
        // Its own file went with the folder, and locks nothing now.
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("edit.lock").path))
        #expect(!RecordingLock.isHeld(at: new.appendingPathComponent("edit.lock")))
    }
}

@Test func releaseInTheFolderRemovesTheLockOfAMovedFolderOnly() throws {
    try withMovedLock { moved, old, new, _ in
        let folder = open(new.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(folder >= 0)
        defer { close(folder) }
        moved.release(inDirectory: folder)
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("edit.lock").path))
        #expect(RecordingLock.isHeld(at: old.appendingPathComponent("edit.lock")))
        moved.release(inDirectory: folder)
        #expect(RecordingLock.isHeld(at: old.appendingPathComponent("edit.lock")))
    }
}

@Test func staleLockFileFromACrashIsNotHeld() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("recording.lock")
        try Data("left behind by a crashed recorder".utf8).write(to: url)
        #expect(!RecordingLock.isHeld(at: url))
        #expect(RecordingLock.readInfo(at: url) == nil)
        let held = try RecordingLock.acquire(at: url, info: .fixture)
        #expect(RecordingLock.readInfo(at: url) == .fixture)
        held.release()
    }
}

@Test func currentInfoDescribesThisProcess() {
    let info = RecordingLockInfo.current(now: Date(timeIntervalSince1970: 1_700_000_000.9))
    #expect(info.pid == getpid())
    #expect(UUID(uuidString: info.bootSessionUUID) != nil)
    #expect(info.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
}
