// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable for the I/O seam and `tick()`, so failures can be injected and the timer driven by hand.
@testable import ProjectFormat

/// File I/O for `EventLogWriter` that fails on demand and counts the syncs.
private final class FaultyIO: Sendable {
    struct State {
        /// The next write writes only this many bytes.
        var shortWrite: Int?
        var failingWrites = 0
        var failingBarrierSyncs = 0
        var barrierSyncs = 0
        var fullSyncs = 0
    }

    let state = Mutex(State())

    var io: EventLogIO {
        EventLogIO(
            write: { [self] fd, buffer in try write(fd, buffer) },
            barrierSync: { [self] fd in try barrierSync(fd) },
            fullSync: { [self] fd in try fullSync(fd) }
        )
    }

    private enum WriteStep {
        case short(Int), fail, normal
    }

    private func write(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) throws -> Int {
        let step = state.withLock { state -> WriteStep in
            if let count = state.shortWrite {
                state.shortWrite = nil
                return .short(count)
            }
            if state.failingWrites > 0 {
                state.failingWrites -= 1
                return .fail
            }
            return .normal
        }
        switch step {
        case let .short(count): return try EventLogIO.system.write(fd, UnsafeRawBufferPointer(rebasing: buffer.prefix(count)))
        case .fail: throw POSIXError(.EIO)
        case .normal: return try EventLogIO.system.write(fd, buffer)
        }
    }

    private func barrierSync(_ fd: Int32) throws {
        let fails = state.withLock { state -> Bool in
            state.barrierSyncs += 1
            guard state.failingBarrierSyncs > 0 else { return false }
            state.failingBarrierSyncs -= 1
            return true
        }
        if fails { throw POSIXError(.EIO) }
        try DurableFile.barrierSync(fd)
    }

    private func fullSync(_ fd: Int32) throws {
        state.withLock { $0.fullSyncs += 1 }
        try DurableFile.fullSync(fd)
    }
}

/// A writer whose timer does not fire during a test, so the test drives it with `tick()`.
/// Every tick writes and, if something was written, syncs.
private func manualWriter(_ url: URL, _ io: FaultyIO) throws -> EventLogWriter {
    try EventLogWriter(url: url, flushInterval: .seconds(3600), syncInterval: .seconds(3600), io: io.io)
}

private func marker(_ t: UInt64) -> InputEvent {
    InputEvent(t: HostTime(nanoseconds: t), kind: .marker)
}

private func line(_ event: InputEvent) throws -> String {
    try event.jsonLine() + "\n"
}

@Test func timerSyncFailureIsThrownOnceByTheNextFlush() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock { $0.failingBarrierSyncs = 1 }
        let writer = try manualWriter(url, io)
        writer.append(marker(1))
        writer.tick()
        writer.tick()
        #expect(io.state.withLock { $0.barrierSyncs } == 2, "the failed sync is retried on the next tick")

        let error = #expect(throws: POSIXError.self) { try writer.flush() }
        #expect(error?.code == .EIO)
        try writer.flush()
        try writer.close()
        #expect(try EventLogReader.read(url).events == [marker(1)])
    }
}

@Test func timerWriteFailureIsThrownOnceByTheNextFlush() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock { $0.failingWrites = 1 }
        let writer = try manualWriter(url, io)
        writer.append(marker(1))
        writer.tick()
        #expect(try Data(contentsOf: url).isEmpty)
        writer.tick()
        #expect(try String(contentsOf: url, encoding: .utf8) == (try line(marker(1))))

        let error = #expect(throws: POSIXError.self) { try writer.flush() }
        #expect(error?.code == .EIO)
        try writer.flush()
        try writer.close()
    }
}

@Test func closeThrowsAnEarlierSyncFailureEvenWhenItsOwnSyncSucceeds() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock { $0.failingBarrierSyncs = 1 }
        let writer = try manualWriter(url, io)
        writer.append(marker(1))
        writer.tick()

        let error = #expect(throws: POSIXError.self) { try writer.close() }
        #expect(error?.code == .EIO)
        #expect(io.state.withLock { $0.fullSyncs } == 1)
        try writer.close()
        #expect(try EventLogReader.read(url).events == [marker(1)])
    }
}

@Test func shortWriteResumesFromTheByteWhereItStopped() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock {
            $0.shortWrite = 5
            $0.failingWrites = 1
        }
        let writer = try manualWriter(url, io)
        writer.append(marker(1))
        writer.append(marker(2))
        writer.tick()
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"t":"#)
        #expect(try EventLogReader.read(url).droppedTruncatedTail)

        writer.tick()
        #expect(try String(contentsOf: url, encoding: .utf8) == (try line(marker(1)) + line(marker(2))))
        #expect(throws: POSIXError.self) { try writer.flush() }
        try writer.close()
        let result = try EventLogReader.read(url)
        #expect(result.events == [marker(1), marker(2)])
        #expect(result.skippedLines == 0 && !result.droppedTruncatedTail)
    }
}

@Test func flushThrowsItsOwnWriteFailureOnlyOnce() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock { $0.failingWrites = 1 }
        let writer = try manualWriter(url, io)
        writer.append(marker(1))
        let error = #expect(throws: POSIXError.self) { try writer.flush() }
        #expect(error?.code == .EIO)
        try writer.flush()
        #expect(try EventLogReader.read(url).events == [marker(1)])
        try writer.close()
    }
}

@Test func eachEarlierFailureIsThrownOnce() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let io = FaultyIO()
        io.state.withLock { $0.failingBarrierSyncs = 1 }
        let writer = try manualWriter(url, io)
        writer.append(InputEvent(t: HostTime(nanoseconds: 1), kind: .cursor(x: .nan, y: 0)))
        writer.append(marker(2))
        writer.tick()

        #expect(throws: POSIXError.self) { try writer.flush() }
        #expect(throws: EncodingError.self) { try writer.flush() }
        try writer.flush()
        try writer.close()
        #expect(try EventLogReader.read(url).events == [marker(2)])
    }
}
