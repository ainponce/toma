// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import Synchronization

private let newline = UInt8(ascii: "\n")

/// Appends events to `events.jsonl`, one whole line per event. `append` may be called from any
/// thread, concurrently.
///
/// `append` only adds the line to a buffer in memory. A timer on the writer's own queue writes
/// the buffer to the file every `flushInterval` and orders it on disk with `F_BARRIERFSYNC` every
/// `syncInterval`. `close()` writes what is left, full-syncs and closes the file. A crash of the
/// app therefore loses at most the events of the last `flushInterval` (plus the timer's latency),
/// and the file always ends either at a line break or inside its last line, which
/// `EventLogReader` drops unless it is a whole event that only lacks its line break.
///
/// A write that fails, for example on a full disk, keeps its bytes in memory: the next timer tick,
/// `flush()` or `close()` writes them again from the byte where the failed write stopped, so lines
/// stay whole. `flush()` and `close()` throw if the write keeps failing.
///
/// An existing file is appended to, after making it end at a line break the way
/// `EventLogReader.truncateIncompleteTail` does. Use one writer per file.
public final class EventLogWriter: Sendable {
    public static let flushInterval: Duration = .milliseconds(250)
    public static let syncInterval: Duration = .seconds(2)

    private static let ticksPerSync = Int((syncInterval / flushInterval).rounded())

    /// The only state `append` touches, so it never waits for disk I/O.
    private struct Pending {
        var bytes: [UInt8] = []
        var encodingError: (any Error)?
        var isClosed = false
    }

    /// The file side. Holding this lock serializes writes, so they keep the order of `append`.
    private struct FileState {
        /// `nil` once closed.
        var fd: Int32?
        /// Bytes taken from `Pending` that are not in the file yet.
        var unwritten: [UInt8] = []
        /// The first event since the last report that could not be encoded.
        var encodingError: (any Error)?
        /// Something was written since the last successful sync.
        var needsSync = false
        var ticksSinceSync = 0
    }

    // Lock order: `file`, then `pending`. `append` takes only `pending`.
    private let pending = Mutex(Pending())
    private let file: Mutex<FileState>
    private let timer: any DispatchSourceTimer

    /// Opens `url` for appending, creating it if needed. The folder must exist.
    public init(url: URL) throws {
        let path = url.path
        var created = true
        var fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0, errno == EEXIST {
            created = false
            fd = open(path, O_RDWR | O_APPEND | O_CLOEXEC)
        }
        guard fd >= 0 else { throw POSIXError.current() }
        do {
            if created {
                try DurableFile.syncDirectory(url.deletingLastPathComponent())
            } else {
                _ = try EventLogReader.endAtLineBoundary(fd)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        file = Mutex(FileState(fd: fd))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.toma.EventLogWriter", qos: .utility))
        self.timer = timer
        // Weak, so the timer never keeps an abandoned writer alive; `close()` cancels it.
        timer.setEventHandler { [weak self] in self?.tick() }
        let interval = Self.flushInterval.dispatchInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(25))
        timer.activate()
    }

    deinit {
        // An owner that drops the writer without `close()` cannot hear about errors any more:
        // this is only a best effort to keep its last lines and release the file and the timer.
        try? close()
    }

    /// Adds `event` to the buffer. Does nothing after `close()`.
    ///
    /// An event that cannot be encoded (a non-finite number) is dropped, and the next `flush()`
    /// or `close()` throws its `EncodingError`.
    public func append(_ event: InputEvent) {
        do {
            var line = try event.jsonLineData()
            line.append(newline)
            pending.withLock { pending in
                guard !pending.isClosed else { return }
                pending.bytes.append(contentsOf: line)
            }
        } catch {
            pending.withLock { pending in
                guard !pending.isClosed, pending.encodingError == nil else { return }
                pending.encodingError = error
            }
        }
    }

    /// Writes the buffer to the file now, without syncing it. Does nothing after `close()`.
    ///
    /// Throws the write error if the write fails (the bytes stay buffered), or else the error of
    /// the first event `append` could not encode since the last time it was thrown.
    public func flush() throws {
        try file.withLock { file in
            guard let fd = file.fd else { return }
            drainPending(into: &file)
            try Self.writeUnwritten(&file, to: fd)
            if let error = file.encodingError {
                file.encodingError = nil
                throw error
            }
        }
    }

    /// Writes the buffer, full-syncs the file with `F_FULLFSYNC` and closes it. Later calls to
    /// `append`, `flush()` and `close()` do nothing.
    ///
    /// The writer is closed even when this throws: it throws the first error of the write, the sync
    /// or `close(2)`, and else the error of an event `append` could not encode. Bytes that could not
    /// be written are lost.
    public func close() throws {
        try file.withLock { file in
            pending.withLock { $0.isClosed = true }
            guard let fd = file.fd else { return }
            file.fd = nil
            timer.cancel()
            drainPending(into: &file)

            var firstError: (any Error)?
            do { try Self.writeUnwritten(&file, to: fd) } catch { firstError = error }
            do { try DurableFile.fullSync(fd) } catch { firstError = firstError ?? error }
            if Darwin.close(fd) != 0, firstError == nil { firstError = POSIXError.current() }
            let encodingError = file.encodingError
            file.unwritten = []
            file.encodingError = nil
            if let error = firstError ?? encodingError { throw error }
        }
    }

    /// Every `flushInterval`, on the timer's queue.
    private func tick() {
        file.withLock { file in
            guard let fd = file.fd else { return }
            drainPending(into: &file)
            // A failed write keeps its bytes for the next tick, `flush()` or `close()`, and those two
            // throw if it keeps failing.
            try? Self.writeUnwritten(&file, to: fd)
            file.ticksSinceSync += 1
            guard file.ticksSinceSync >= Self.ticksPerSync else { return }
            if file.needsSync {
                // A failed sync is retried on the next tick; `close()` full-syncs and throws if the
                // file cannot be synced.
                guard (try? DurableFile.barrierSync(fd)) != nil else { return }
                file.needsSync = false
            }
            file.ticksSinceSync = 0
        }
    }

    /// Moves what `append` buffered to the file side. Called with the `file` lock held.
    private func drainPending(into file: inout FileState) {
        let (bytes, encodingError) = pending.withLock { pending in
            let taken = (pending.bytes, pending.encodingError)
            pending.bytes = []
            pending.encodingError = nil
            return taken
        }
        if file.unwritten.isEmpty {
            file.unwritten = bytes
        } else {
            file.unwritten.append(contentsOf: bytes)
        }
        if file.encodingError == nil {
            file.encodingError = encodingError
        }
    }

    /// Writes `unwritten`, keeping whatever a failed write did not reach.
    private static func writeUnwritten(_ file: inout FileState, to fd: Int32) throws {
        var written = 0
        defer {
            if written > 0 {
                file.unwritten.removeFirst(written)
                file.needsSync = true
            }
        }
        try file.unwritten.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let result = write(fd, base + written, buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                written += result
            }
        }
    }
}

/// What `EventLogReader.read` found in an `events.jsonl`.
public struct EventLogReadResult: Sendable {
    /// The events in file order, which is the order they were appended, not always the order of `t`.
    public var events: [InputEvent]
    /// The file ended inside a line that is not an event: a write cut short by a crash. It was ignored.
    public var droppedTruncatedTail: Bool
    /// Whole lines that are not an event this version can read (damaged, or of a newer type).
    /// They were ignored.
    public var skippedLines: Int

    public init(events: [InputEvent], droppedTruncatedTail: Bool, skippedLines: Int) {
        self.events = events
        self.droppedTruncatedTail = droppedTruncatedTail
        self.skippedLines = skippedLines
    }
}

/// Reads `events.jsonl` the way it can be after a crash.
///
/// A line is whole when it ends with a line break. A last line without one is kept if it is an
/// event (only its line break is missing) and dropped if not (a write cut short). A whole line
/// that is not an event is skipped and counted, and the lines after it are still read.
public enum EventLogReader {
    /// Throws only if the file cannot be read.
    public static func read(_ url: URL) throws -> EventLogReadResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var result = EventLogReadResult(events: [], droppedTruncatedTail: false, skippedLines: 0)
        // A line that fails to decode is not an error of the file as a whole: it is counted.
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                guard let found = memchr(base + start, Int32(newline), buffer.count - start) else {
                    let tail = data[(data.startIndex + start)...]
                    if let event = try? decoder.decode(InputEvent.self, from: tail) {
                        result.events.append(event)
                    } else {
                        result.droppedTruncatedTail = true
                    }
                    return
                }
                let end = base.distance(to: UnsafeRawPointer(found))
                let line = data[(data.startIndex + start)..<(data.startIndex + end)]
                if let event = try? decoder.decode(InputEvent.self, from: line) {
                    result.events.append(event)
                } else {
                    result.skippedLines += 1
                }
                start = end + 1
            }
        }
        return result
    }

    /// Makes the file end at a line break before more lines are appended to it, and full-syncs it.
    ///
    /// A last line without its line break that is not an event (a write cut short by a crash) is
    /// truncated away; one that is an event gets its line break. Returns `true` if the file changed.
    /// Whole lines are never touched.
    public static func truncateIncompleteTail(_ url: URL) throws -> Bool {
        let fd = open(url.path, O_RDWR | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        let changed: Bool
        do {
            changed = try endAtLineBoundary(fd)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw POSIXError.current() }
        return changed
    }

    /// `truncateIncompleteTail` on a file opened with `O_RDWR | O_APPEND`.
    static func endAtLineBoundary(_ fd: Int32) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError.current() }
        let size = info.st_size
        guard size > 0, try readBytes(fd, at: size - 1, count: 1) != [newline] else { return false }
        let tailStart = try startOfLastLine(fd, size: size)
        let tail = try readBytes(fd, at: tailStart, count: Int(size - tailStart))
        if (try? JSONDecoder().decode(InputEvent.self, from: Data(tail))) != nil {
            try DurableFile.writeAll(Data([newline]), to: fd)
        } else {
            guard ftruncate(fd, tailStart) == 0 else { throw POSIXError.current() }
        }
        try DurableFile.fullSync(fd)
        return true
    }

    private static let chunkSize: off_t = 64 * 1024

    /// The offset right after the last line break before `size`, or 0 if there is none.
    private static func startOfLastLine(_ fd: Int32, size: off_t) throws -> off_t {
        var end = size
        while end > 0 {
            let start = max(0, end - chunkSize)
            let chunk = try readBytes(fd, at: start, count: Int(end - start))
            if let index = chunk.lastIndex(of: newline) {
                return start + off_t(index) + 1
            }
            end = start
        }
        return 0
    }

    /// Up to `count` bytes at `offset`; fewer only if the file ends first.
    private static func readBytes(_ fd: Int32, at offset: off_t, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while done < count {
                let result = pread(fd, base + done, count - done, offset + off_t(done))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                if result == 0 { break }
                done += result
            }
        }
        bytes.removeLast(count - done)
        return bytes
    }
}

extension Duration {
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
