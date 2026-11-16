// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the session uses only the public API.
import Editing
import ProjectFormat

/// The system's calls, with failures on demand, and the calls made, in order.
private final class TestIO: Sendable {
    enum Call: Equatable {
        case open(created: Bool), write, fullSync, fsync, syncDirectory
    }

    struct State {
        var calls: [Call] = []
        /// The next writes throw these, one each.
        var writeFailures: [POSIXErrorCode] = []
        /// Every write throws this while it is set.
        var failingWrites: POSIXErrorCode?
        /// The next write writes half of its bytes.
        var halfNextWrite = false
        /// Every full sync throws this.
        var fullSyncError: POSIXErrorCode?
        /// The next folder syncs throw these, one each.
        var directorySyncFailures: [POSIXErrorCode] = []
        /// The first full sync waits for it.
        var firstFullSyncGate: DispatchSemaphore?
        /// The first full sync takes this long.
        var firstFullSyncDelay: Duration?
        var isSyncing = false
    }

    let state = Mutex(State())

    func count(_ call: Call) -> Int { state.withLock { $0.calls.filter { $0 == call }.count } }

    var opens: Int {
        state.withLock { $0.calls.filter { if case .open = $0 { true } else { false } }.count }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    var io: EditJournalIO {
        EditJournalIO(
            open: { [self] directory, name in
                let opened = try EditJournalIO.system.open(directory, name)
                state.withLock { $0.calls.append(.open(created: opened.created)) }
                return opened
            },
            write: { [self] descriptor, bytes in try write(descriptor, bytes) },
            fullSync: { [self] descriptor in try fullSync(descriptor) },
            fsync: { [self] descriptor in
                state.withLock { $0.calls.append(.fsync) }
                try EditJournalIO.system.fsync(descriptor)
            },
            syncDirectory: { [self] directory in
                let failure = state.withLock { state -> POSIXErrorCode? in
                    state.calls.append(.syncDirectory)
                    return state.directorySyncFailures.isEmpty ? nil : state.directorySyncFailures.removeFirst()
                }
                if let failure { throw POSIXError(failure) }
                try EditJournalIO.system.syncDirectory(directory)
            }
        )
    }

    private enum WriteStep {
        case fail(POSIXErrorCode), half, normal
    }

    private func write(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws -> Int {
        let step = state.withLock { state -> WriteStep in
            state.calls.append(.write)
            if state.halfNextWrite {
                state.halfNextWrite = false
                return .half
            }
            if !state.writeFailures.isEmpty { return .fail(state.writeFailures.removeFirst()) }
            if let code = state.failingWrites { return .fail(code) }
            return .normal
        }
        switch step {
        case let .fail(code): throw POSIXError(code)
        case .half:
            let half = UnsafeRawBufferPointer(rebasing: bytes.prefix(bytes.count / 2))
            return try EditJournalIO.system.write(descriptor, half)
        case .normal: return try EditJournalIO.system.write(descriptor, bytes)
        }
    }

    private func fullSync(_ descriptor: Int32) throws {
        let (gate, delay, failure) = state.withLock { state in
            let first = !state.calls.contains(.fullSync)
            state.calls.append(.fullSync)
            state.isSyncing = true
            return (first ? state.firstFullSyncGate : nil, first ? state.firstFullSyncDelay : nil, state.fullSyncError)
        }
        defer { state.withLock { $0.isSyncing = false } }
        gate?.wait()
        if let delay { Thread.sleep(forTimeInterval: delay.seconds) }
        if let failure { throw POSIXError(failure) }
        try EditJournalIO.system.fullSync(descriptor)
    }
}

/// The states a journal goes into, as its handler gets them, and whether it got each on the main thread.
private final class StateRecorder: Sendable {
    private let recorded = Mutex<[(state: JournalState, onMain: Bool)]>([])

    func listen(to journal: EditJournal) {
        journal.onStateChange { [self] state in
            let onMain = Thread.isMainThread
            recorded.withLock { $0.append((state, onMain)) }
        }
    }

    var states: [JournalState] { recorded.withLock { $0.map(\.state) } }
    var allOnMain: Bool { recorded.withLock { $0.allSatisfy(\.onMain) } }
}

private func line(_ number: Int) -> String { #"{"line":\#(number)}"# }

/// The file holding `lines`.
private func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

private func contents(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

private func logURL(in directory: URL) -> URL { directory.appending(path: "edit-log.jsonl") }

private func fileNumber(_ url: URL) throws -> UInt64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return info.st_ino
}

// MARK: - One sync per burst, and nobody waits

@Test func eachBurstIsSyncedOnce() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        // The first sync waits until every line was appended: whatever the first batch took, the rest is one more.
        let gate = DispatchSemaphore(value: 0)
        io.state.withLock { $0.firstFullSyncGate = gate }
        let journal = try EditJournal(logURL: url, io: io.io)
        let lines = (1...5).map(line)
        for line in lines { journal.append(line) }
        gate.signal()
        #expect(await journal.flushed() == 5)
        #expect(io.count(.fullSync) <= 2)
        #expect(try contents(url) == text(lines))
        #expect(journal.state == .saved)
        await journal.close()
    }
}

@Test func callerNeverWaits() async throws {
    try await withTemporaryDirectory { directory in
        let io = TestIO()
        io.state.withLock { $0.firstFullSyncDelay = .seconds(1) }
        let journal = try EditJournal(logURL: logURL(in: directory), io: io.io)
        let clock = ContinuousClock()
        let first = clock.measure { journal.append(line(1)) }
        #expect(await eventually { io.state.withLock { $0.isSyncing } })
        // While the journal is in the middle of a sync of a second.
        let second = clock.measure { journal.append(line(2)) }
        #expect(first < .milliseconds(10))
        #expect(second < .milliseconds(10))
        #expect(journal.state == .pending(2))
        #expect(await journal.flushed() == 2)
        await journal.close()
    }
}

// MARK: - Failures keep the lines and are retried

@Test func diskFullKeepsEntriesAndRetries() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        io.state.withLock { $0.writeFailures = [.ENOSPC, .ENOSPC] }
        let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
        let recorder = StateRecorder()
        recorder.listen(to: journal)
        let lines = (1...5).map(line)
        for line in lines { journal.append(line) }
        #expect(await eventually { journal.state == .saved })
        #expect(await eventually { recorder.states.last == .saved })
        let states = recorder.states
        let failing = try #require(states.firstIndex(of: .failing(.ENOSPC)))
        #expect(states[failing...].contains(.saved))
        #expect(io.count(.write) >= 3)
        #expect(try contents(url) == text(lines))
        #expect(await journal.flushed() == 5)
        await journal.close()
    }
}

@Test func partialWriteIsCompletedNotRepeated() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        io.state.withLock { state in
            state.halfNextWrite = true
            state.writeFailures = [.ENOSPC]
        }
        let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
        let recorder = StateRecorder()
        recorder.listen(to: journal)
        let whole = #"{"line":1,"padding":"\#(String(repeating: "x", count: 101))"}"#
        journal.append(whole)
        #expect(await eventually { journal.state == .saved })
        #expect(await eventually { recorder.states == [.pending(1), .failing(.ENOSPC), .saved] })
        #expect(try contents(url) == text([whole]))
        await journal.close()
    }
}

@Test func ioErrorKeepsEntriesAndRetries() async throws {
    // EIO, and ENXIO of an ejected volume: the descriptor is dead, the retry opens the log again by its name.
    for code in [POSIXErrorCode.EIO, .ENXIO] {
        try await withTemporaryDirectory { directory in
            let url = logURL(in: directory)
            let io = TestIO()
            let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
            let recorder = StateRecorder()
            recorder.listen(to: journal)
            journal.append(line(1))
            #expect(await journal.flushed() == 1)
            io.state.withLock { $0.writeFailures = [code] }
            journal.append(line(2))
            // The attempt failed: the line is in memory, not on disk.
            #expect(await journal.flushed() == 1)
            #expect(await eventually { journal.state == .saved })
            #expect(io.opens == 2)
            #expect(try contents(url) == text([line(1), line(2)]))
            #expect(await eventually { recorder.states.count == 5 })
            #expect(recorder.states == [.pending(1), .saved, .pending(1), .failing(code), .saved])
            await journal.close()
        }
    }

    // A file that no longer ends with the last line confirmed (cut short, or with something else after it) is not the
    // one the journal was writing: it stays failing and never writes the line blind; closing does not hide it.
    let damages: [(URL) throws -> Void] = [
        { url in #expect(truncate(url.path, off_t(text([line(1)]).utf8.count - 1)) == 0) },
        { url in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"other\":1}\n".utf8))
            try handle.close()
        },
    ]
    for damage in damages {
        try await withTemporaryDirectory { directory in
            let url = logURL(in: directory)
            let io = TestIO()
            let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
            journal.append(line(1))
            #expect(await journal.flushed() == 1)
            io.state.withLock { $0.failingWrites = .EIO }
            journal.append(line(2))
            #expect(await journal.flushed() == 1)
            try damage(url)
            let damaged = try contents(url)
            io.state.withLock { $0.failingWrites = nil }
            #expect(await eventually { journal.state == .failing(.ESTALE) })
            let opens = io.opens
            #expect(await eventually { io.opens >= opens + 3 })
            #expect(journal.state == .failing(.ESTALE))
            #expect(await journal.flushed() == 1)
            #expect(try contents(url) == damaged)
            await journal.close()
            #expect(journal.state == .failing(.ESTALE))
        }
    }
}

// MARK: - Opening

@Test func newLogSyncsItsFolderBeforeTheFirstLine() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        let journal = try EditJournal(logURL: url, io: io.io)
        journal.append(line(1))
        #expect(await journal.flushed() == 1)
        await journal.close()
        let calls = io.calls
        #expect(calls.first == .open(created: true))
        let folder = try #require(calls.firstIndex(of: .syncDirectory))
        let sync = try #require(calls.firstIndex(of: .fullSync))
        #expect(folder < sync)

        // A log that was there: its folder is not synced.
        let again = TestIO()
        let reopened = try EditJournal(logURL: url, io: again.io)
        reopened.append(line(2))
        #expect(await reopened.flushed() == 1)
        await reopened.close()
        #expect(again.calls.first == .open(created: false))
        #expect(!again.calls.contains(.syncDirectory))
        #expect(try contents(url) == text([line(1), line(2)]))
    }

    // Until the folder is synced, the first line is not confirmed.
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        io.state.withLock { $0.directorySyncFailures = [.EIO] }
        let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
        journal.append(line(1))
        #expect(await journal.flushed() == 0)
        #expect(await eventually { journal.state == .saved })
        #expect(io.count(.syncDirectory) == 2)
        #expect(try contents(url) == text([line(1)]))
        await journal.close()
    }
}

@Test func symlinkedLogIsRefused() throws {
    try withTemporaryDirectory { directory in
        let target = directory.appending(path: "elsewhere.jsonl")
        try Data(text([line(0)]).utf8).write(to: target)
        let package = directory.appending(path: "package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let link = logURL(in: package)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: POSIXError(.ELOOP)) { try EditJournal(logURL: link) }
        #expect(try contents(target) == text([line(0)]))

        // Nor through a package folder that is a symlink.
        let linkedPackage = directory.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: directory)
        let throughLink = linkedPackage.appending(path: "elsewhere.jsonl")
        #expect(throws: POSIXError(.ENOTDIR)) { try EditJournal(logURL: throughLink) }

        // A FIFO without a reader: refused at once, never stuck.
        let fifo = logURL(in: directory)
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let elapsed = ContinuousClock().measure {
            #expect(throws: POSIXError(.ENXIO)) { try EditJournal(logURL: fifo) }
        }
        #expect(elapsed < .milliseconds(100))
    }
}

@Test func logEndingInsideALineIsRefused() throws {
    try withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        try Data((text([line(1)]) + #"{"line":2,"#).utf8).write(to: url)
        #expect(throws: POSIXError(.EILSEQ)) { try EditJournal(logURL: url) }
    }
}

@Test func fallsBackToFsyncWhenFullSyncIsUnsupported() async throws {
    for code in [POSIXErrorCode.ENOTSUP, .EINVAL] {
        try await withTemporaryDirectory { directory in
            let url = logURL(in: directory)
            let io = TestIO()
            io.state.withLock { $0.fullSyncError = code }
            let journal = try EditJournal(logURL: url, io: io.io)
            journal.append(line(1))
            #expect(await journal.flushed() == 1)
            #expect(io.count(.fsync) == 1)
            #expect(journal.state == .saved)
            #expect(try contents(url) == text([line(1)]))
            await journal.close()
        }
    }
}

@Test func movedPackageKeepsWriting() async throws {
    try await withTemporaryDirectory { directory in
        let package = directory.appending(path: "Project.toma")
        let moved = directory.appending(path: "Renamed.toma")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let io = TestIO()
        let journal = try EditJournal(logURL: logURL(in: package), io: io.io, retryInterval: .milliseconds(20))
        journal.append(line(1))
        #expect(await journal.flushed() == 1)
        try FileManager.default.moveItem(at: package, to: moved)
        journal.append(line(2))
        #expect(await journal.flushed() == 2)
        #expect(journal.state == .saved)
        #expect(try contents(logURL(in: moved)) == text([line(1), line(2)]))

        // Opening the log again after an error follows the moved package too.
        io.state.withLock { $0.writeFailures = [.EIO] }
        journal.append(line(3))
        #expect(await eventually { journal.state == .saved })
        #expect(io.opens == 2)
        #expect(try contents(logURL(in: moved)) == text([line(1), line(2), line(3)]))
        #expect(!FileManager.default.fileExists(atPath: package.path))
        await journal.close()
    }
}

/// A disk image of the test's own, to eject while the journal has its files open and to mount again where it was.
private struct EjectableVolume {
    let image: URL
    let mountPoint: URL

    init(in directory: URL) throws {
        image = directory.appending(path: "volume.dmg")
        mountPoint = directory.appending(path: "volume", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        try Self.hdiutil(["create", "-size", "10m", "-fs", "APFS", "-volname", "TomaJournalTest", image.path])
        try mount()
    }

    func mount() throws { try Self.hdiutil(["attach", "-nobrowse", "-mountpoint", mountPoint.path, image.path]) }

    /// Unmounts it with files open on it, as when a disk is pulled out: their descriptors die.
    func eject() throws { try Self.hdiutil(["detach", "-force", mountPoint.path]) }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestSupportError.failed("hdiutil \(arguments.joined(separator: " ")): \(output)")
        }
    }
}

@Test func ejectedVolumeComesBackAndTheLogGoesOn() async throws {
    try await withTemporaryDirectory { directory in
        let volume = try EjectableVolume(in: directory)
        defer { try? volume.eject() }
        let package = volume.mountPoint.appending(path: "Project.toma")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let url = logURL(in: package)
        let journal = try EditJournal(logURL: url, retryInterval: .milliseconds(50))
        journal.append(line(1))
        #expect(await journal.flushed() == 1)
        try volume.eject()
        journal.append(line(2))
        #expect(await journal.flushed() == 1)
        #expect(await eventually { if case .failing = journal.state { true } else { false } })
        // The retries while it is away find no package at its path, and create nothing there.
        try await Task.sleep(for: .milliseconds(200))
        #expect(journal.state != .saved)
        #expect(!FileManager.default.fileExists(atPath: package.path))
        // Both descriptors died with the volume: the log is opened again by the package's path once it is back.
        try volume.mount()
        #expect(await eventually { journal.state == .saved })
        #expect(await journal.flushed() == 2)
        await journal.close()
        #expect(try contents(url) == text([line(1), line(2)]))
    }
}

// MARK: - Compaction while the journal holds the log (plan-review C1)

private let date = Date(timeIntervalSince1970: 1_794_773_523)

private func padding(_ seq: Int, group: Int, _ before: Double, _ after: Double) throws -> EditLogEntry {
    let change = EditChange.set(path: try JSONPointer("/style/padding"), before: .number(before), after: .number(after))
    return .do(seq: seq, group: group, label: EditLabel.padding.rawValue, changes: [change], at: date)
}

@Test func editsAfterACompactionLandInTheLogOnDisk() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let read = [SmallDocument.create, try padding(2, group: 2, 0.08, 0.1)]
        try Data(text(try read.map { try $0.jsonLine() }).utf8).write(to: url)
        let journal = try EditJournal(logURL: url)
        let appended = [try padding(3, group: 2, 0.1, 0.12), .undo(seq: 4, group: 2), .redo(seq: 5, group: 2)]
        for entry in appended { journal.append(try entry.jsonLine()) }
        let compacted = LogCompaction.compact(read + appended)
        #expect(compacted.count < read.count + appended.count)
        let before = try fileNumber(url)
        try await journal.replaceLog(with: try compacted.map { try $0.jsonLine() })
        #expect(try fileNumber(url) != before)
        let later = [try padding(6, group: 6, 0.12, 0.2), .undo(seq: 7, group: 6)]
        for entry in later { journal.append(try entry.jsonLine()) }
        #expect(await journal.flushed() == 5)
        #expect(journal.state == .saved)
        await journal.close()

        // Read by the path, not through the journal's descriptor: the lines after the compaction are in the log there.
        let log = try EditLogReader.read(url)
        #expect(log.entries == compacted + later)
        #expect(log.damagedLine == nil)
        #expect(!log.droppedTruncatedTail)
        let replayed = try #require(EditReplay.replay(snapshot: nil, entries: log.entries))
        let whole = try #require(EditReplay.replay(snapshot: nil, entries: read + appended + later))
        #expect(replayed.mismatchSeq == nil)
        #expect(replayed.document == whole.document)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }
}

@Test func compactionNeverDropsLinesThatAreNotOnDisk() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(20))
        journal.append(line(1))
        #expect(await journal.flushed() == 1)
        io.state.withLock { $0.failingWrites = .ENOSPC }
        journal.append(line(2))
        let onDisk = try Data(contentsOf: url)
        // Before or after its attempt failed: either way the log is not replaced while a line waits.
        await #expect(throws: POSIXError(.ENOSPC)) { try await journal.replaceLog(with: [line(9)]) }
        #expect(try Data(contentsOf: url) == onDisk)
        io.state.withLock { $0.failingWrites = nil }
        #expect(await eventually { journal.state == .saved })
        #expect(try contents(url) == text([line(1), line(2)]))

        // A compaction whose own write fails leaves the log as it was, and the journal goes on appending to it.
        io.state.withLock { $0.writeFailures = [.ENOSPC] }
        await #expect(throws: POSIXError(.ENOSPC)) { try await journal.replaceLog(with: [line(9)]) }
        #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))
        journal.append(line(3))
        #expect(await journal.flushed() == 3)
        #expect(try contents(url) == text([line(1), line(2), line(3)]))
        await journal.close()
        await #expect(throws: POSIXError(.EBADF)) { try await journal.replaceLog(with: [line(9)]) }
    }
}

@Test func aLogReplacedUnderTheJournalIsNeverConfirmed() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let journal = try EditJournal(logURL: url, retryInterval: .milliseconds(20))
        journal.append(line(1))
        #expect(await journal.flushed() == 1)

        // The same bytes renamed over the log: the journal finds its last line there and follows the new file.
        try DurableFile.writeAtomically(try Data(contentsOf: url), to: url)
        journal.append(line(2))
        #expect(await eventually { journal.state == .saved })
        #expect(await journal.flushed() == 2)
        #expect(try contents(url) == text([line(1), line(2)]))

        // Another log renamed over it, as a compaction from outside would: the next line is not confirmed into the file
        // that lost its name, nor written blind after the new one.
        let other = text([#"{"other":1}"#])
        try DurableFile.writeAtomically(Data(other.utf8), to: url)
        journal.append(line(3))
        #expect(await journal.flushed() == 2)
        #expect(await eventually { journal.state == .failing(.ESTALE) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(journal.state == .failing(.ESTALE))
        #expect(await journal.flushed() == 2)
        #expect(try contents(url) == other)
        await journal.close()
        #expect(journal.state == .failing(.ESTALE))
    }
}

// MARK: - States

@Test func statesArriveInOrder() async throws {
    try await withTemporaryDirectory { directory in
        let url = logURL(in: directory)
        let io = TestIO()
        let journal = try EditJournal(logURL: url, io: io.io, retryInterval: .milliseconds(1))
        let recorder = StateRecorder()
        recorder.listen(to: journal)
        var expected: [JournalState] = []
        let lines = (0..<100).map(line)
        for (index, line) in lines.enumerated() {
            let failure: POSIXErrorCode? = index % 4 == 1 ? .ENOSPC : index % 4 == 3 ? .EIO : nil
            if let failure { io.state.withLock { $0.writeFailures = [failure] } }
            journal.append(line)
            expected.append(.pending(1))
            if let failure { expected.append(.failing(failure)) }
            expected.append(.saved)
            #expect(await eventually { journal.state == .saved })
        }
        #expect(await eventually { recorder.states.count >= expected.count })
        #expect(recorder.states == expected)
        #expect(recorder.allOnMain)
        #expect(try contents(url) == text(lines))
        await journal.close()
    }
}

// MARK: - Snapshots

@Test func snapshotIsDueAfterTwoSecondsOr200Entries() {
    let start = ContinuousClock.now
    let changed = SnapshotPolicy(entriesSinceSnapshot: 1, lastChange: start)
    #expect(!changed.isDue(now: start + .milliseconds(1_900)))
    #expect(changed.isDue(now: start + .seconds(2)))
    #expect(SnapshotPolicy(entriesSinceSnapshot: 200, lastChange: start).isDue(now: start))
    #expect(!SnapshotPolicy(entriesSinceSnapshot: 199, lastChange: start).isDue(now: start))
    // Nothing since the last snapshot: nothing to write.
    #expect(!SnapshotPolicy(entriesSinceSnapshot: 0, lastChange: start).isDue(now: start + .seconds(10)))
    #expect(SnapshotPolicy.idleDelay == .seconds(2))
    #expect(SnapshotPolicy.everyEntries == 200)
}
