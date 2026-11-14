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
