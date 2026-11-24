// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable only for the I/O seam, so a write to the old file can fail; the Replay rotates through the public API.
@testable import ProjectFormat

// Milestone 5c, Task R1 (fases 4 y 5 design §10.2, plan decision 3): the Replay's one event log goes on in a new file
// every segment of time; a writer that never rotates is the writer of always.

private func marker(_ t: UInt64) -> InputEvent {
    InputEvent(t: HostTime(nanoseconds: t), kind: .marker)
}

private func lines(of events: [InputEvent]) throws -> Data {
    Data(try events.map { try $0.jsonLine() + "\n" }.joined().utf8)
}

@Suite struct EventLogRotationTests {
    @Test func rotatedLinesLandInTheirFiles() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let writer = try EventLogWriter(url: first)
            writer.append(marker(1))
            writer.append(marker(2))
            try writer.rotate(to: second)
            writer.append(marker(3))
            try writer.close()

            // Whole lines only, each in its own file.
            #expect(try Data(contentsOf: first) == lines(of: [marker(1), marker(2)]))
            #expect(try Data(contentsOf: second) == lines(of: [marker(3)]))
            #expect(try EventLogReader.read(first).events == [marker(1), marker(2)])
            #expect(try EventLogReader.read(second).events == [marker(3)])
        }
    }

    @Test func linesAppendedBeforeTheRotationStayInTheOldFile() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let writer = try EventLogWriter(url: first)
            // No `flush()`: what `append` buffered goes to the old file, written and closed by the rotation itself.
            for t in 1...50 { writer.append(marker(UInt64(t))) }
            try writer.rotate(to: second)

            #expect(try Data(contentsOf: first) == lines(of: (1...50).map { marker(UInt64($0)) }))
            #expect(try Data(contentsOf: second).isEmpty)

            writer.append(marker(51))
            try writer.flush()
            #expect(try Data(contentsOf: second) == lines(of: [marker(51)]))
            try writer.close()
            #expect(try Data(contentsOf: first) == lines(of: (1...50).map { marker(UInt64($0)) }))
        }
    }

    @Test func rotatingOntoAnExistingFileThrowsAndKeepsWriting() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let taken = dir.appendingPathComponent("events-0002.jsonl")
            try Data("someone else's\n".utf8).write(to: taken)
            let writer = try EventLogWriter(url: first)
            writer.append(marker(1))

            #expect(throws: POSIXError(.EEXIST)) { try writer.rotate(to: taken) }
            #expect(writer.url == first)

            writer.append(marker(2))
            try writer.close()
            #expect(try Data(contentsOf: first) == lines(of: [marker(1), marker(2)]))
            #expect(try Data(contentsOf: taken) == Data("someone else's\n".utf8))
        }
    }

    @Test func rotatingOntoALinkNeverFollowsIt() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let link = dir.appendingPathComponent("events-0002.jsonl")
            let target = dir.appendingPathComponent("target.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let writer = try EventLogWriter(url: first)

            #expect(throws: (any Error).self) { try writer.rotate(to: link) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(writer.url == first)
            writer.append(marker(1))
            try writer.close()
            #expect(try Data(contentsOf: first) == lines(of: [marker(1)]))
        }
    }

    @Test func aFailureOfTheOldFileIsThrownAndTheWriterMovesOn() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let failingWrites = Mutex(0)
            let io = EventLogIO(
                write: { fd, buffer in
                    let fails = failingWrites.withLock { count in
                        guard count > 0 else { return false }
                        count -= 1
                        return true
                    }
                    if fails { throw POSIXError(.EIO) }
                    return try EventLogIO.system.write(fd, buffer)
                },
                barrierSync: EventLogIO.system.barrierSync, fullSync: EventLogIO.system.fullSync)
            // Long intervals: only the calls of the test write.
            let writer = try EventLogWriter(url: first, flushInterval: .seconds(3600), syncInterval: .seconds(3600), io: io)
            writer.append(marker(1))
            try writer.flush()
            writer.append(marker(2))
            failingWrites.withLock { $0 = 1 }

            #expect(throws: POSIXError(.EIO)) { try writer.rotate(to: second) }

            // As `close()`: the old file keeps what reached it, and the writer goes on in the new one.
            #expect(writer.url == second)
            writer.append(marker(3))
            try writer.close()
            #expect(try Data(contentsOf: first) == lines(of: [marker(1)]))
            #expect(try Data(contentsOf: second) == lines(of: [marker(3)]))
        }
    }

    /// The Replay's working package is never recovered: its writer writes as always and never syncs (no barrier on a
    /// tick, no full sync when it rotates or closes). A durable writer, as always, does.
    @Test(arguments: [true, false])
    func onlyADurableWriterSyncs(durable: Bool) throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let syncs = Mutex((barrier: 0, full: 0))
            let io = EventLogIO(
                write: EventLogIO.system.write,
                barrierSync: { fd in
                    syncs.withLock { $0.barrier += 1 }
                    try EventLogIO.system.barrierSync(fd)
                },
                fullSync: { fd in
                    syncs.withLock { $0.full += 1 }
                    try EventLogIO.system.fullSync(fd)
                })
            // Long intervals: only the test's calls run, and every tick is a sync tick.
            let writer = try EventLogWriter(
                url: first, flushInterval: .seconds(3600), syncInterval: .seconds(3600), io: io, durable: durable)
            writer.append(marker(1))
            writer.tick()
            try writer.rotate(to: second)
            writer.append(marker(2))
            writer.tick()
            try writer.close()

            #expect(try Data(contentsOf: first) == lines(of: [marker(1)]))
            #expect(try Data(contentsOf: second) == lines(of: [marker(2)]))
            let counted = syncs.withLock { $0 }
            #expect(counted.barrier == (durable ? 2 : 0))
            #expect(counted.full == (durable ? 2 : 0))
        }
    }

    @Test func urlNamesTheNewFile() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let third = dir.appendingPathComponent("events-0003.jsonl")
            let writer = try EventLogWriter(url: first)
            #expect(writer.url == first)
            try writer.rotate(to: second)
            #expect(writer.url == second)
            try writer.rotate(to: third)
            #expect(writer.url == third)
            try writer.close()
            #expect(writer.url == third)
            // Every file it made stays, empty or not.
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["events-0001.jsonl", "events-0002.jsonl", "events-0003.jsonl"])
        }
    }

    @Test func unrotatedWriterKeepsItsFileAndURL() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let writer = try EventLogWriter(url: url)
            let events = (1...20).map { marker(UInt64($0)) }
            for event in events[..<10] { writer.append(event) }
            try writer.flush()
            for event in events[10...] { writer.append(event) }
            try writer.close()

            #expect(writer.url == url)
            #expect(try Data(contentsOf: url) == lines(of: events))
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["events.jsonl"])
        }
    }

    @Test func rotateAfterCloseDoesNothing() throws {
        try withTemporaryDirectory { dir in
            let first = dir.appendingPathComponent("events-0001.jsonl")
            let second = dir.appendingPathComponent("events-0002.jsonl")
            let writer = try EventLogWriter(url: first)
            writer.append(marker(1))
            try writer.close()

            try writer.rotate(to: second)

            #expect(!FileManager.default.fileExists(atPath: second.path))
            #expect(writer.url == first)
            writer.append(marker(2))
            #expect(try Data(contentsOf: first) == lines(of: [marker(1)]))
        }
    }
}
