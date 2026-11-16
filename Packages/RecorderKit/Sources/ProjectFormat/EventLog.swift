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
/// `syncInterval`. `close()` writes what is left, full-syncs and closes the file. While writes
/// succeed, a crash of the app loses at most the events of the last `flushInterval` (plus the
/// timer's latency), and the file always ends either at a line break or inside its last line,
/// which `EventLogReader` drops unless it is a whole JSON object that only lacks its line break.
///
/// A write that fails, for example on a full disk, keeps its bytes in memory: the next timer tick,
/// `flush()` or `close()` writes them again from the byte where the failed write stopped, so lines
/// stay whole. A failed sync is retried on the next tick.
///
/// No failure goes unreported. The first write or sync of the timer that fails is kept and thrown
/// once by the next `flush()` or `close()`, even if a later retry succeeded: a later successful
/// sync does not prove the earlier data reached the disk.
///
/// An existing file is appended to, after making it end at a line break the way
/// `EventLogReader.truncateIncompleteTail` does. Use one writer per file.
public final class EventLogWriter: Sendable {
    public static let flushInterval: Duration = .milliseconds(250)
    public static let syncInterval: Duration = .seconds(2)

    /// The file it appends to.
    public let url: URL

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
        /// The first write or sync of the timer that failed since the last time one was thrown.
        var ioError: (any Error)?
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
    private let io: EventLogIO
    private let ticksPerSync: Int

    /// Opens `url` for appending, creating it if needed. The folder must exist. Throws `ELOOP` or
    /// `EFTYPE` if `url` is a symlink (never followed) or not a regular file.
    public convenience init(url: URL) throws {
        try self.init(url: url, flushInterval: Self.flushInterval, syncInterval: Self.syncInterval, io: .system)
    }

    /// Tests pass their own intervals and I/O.
    init(url: URL, flushInterval: Duration, syncInterval: Duration, io: EventLogIO) throws {
        let path = url.path
        var created = true
        var fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0, errno == EEXIST {
            created = false
            fd = try EventLogReader.openRegularFile(path)
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

        self.url = url
        file = Mutex(FileState(fd: fd))
        self.io = io
        ticksPerSync = max(1, Int((syncInterval / flushInterval).rounded()))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.toma.EventLogWriter", qos: .utility))
        self.timer = timer
        // Weak, so the timer never keeps an abandoned writer alive; `close()` cancels it.
        timer.setEventHandler { [weak self] in self?.tick() }
        let interval = flushInterval.dispatchInterval
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
    /// An event that cannot be encoded (a non-finite number) is dropped, and a later `flush()`
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
    /// Throws the write error if its own write fails (the bytes stay buffered). Otherwise it throws,
    /// once, an earlier failure the caller has not heard of: first a failed write or sync of the
    /// timer, then, on a later call, an event `append` could not encode.
    public func flush() throws {
        try file.withLock { file in
            guard let fd = file.fd else { return }
            drainPending(into: &file)
            try writeUnwritten(&file, to: fd)
            if let error = file.ioError {
                file.ioError = nil
                throw error
            }
            if let error = file.encodingError {
                file.encodingError = nil
                throw error
            }
        }
    }

    /// Writes the buffer, full-syncs the file with `F_FULLFSYNC` and closes it. Later calls to
    /// `append`, `flush()` and `close()` do nothing.
    ///
    /// The writer is closed even when this throws, and bytes that could not be written are lost.
    /// It throws the first failure the caller has not heard of: a failed write or sync of the timer
    /// (even when the final sync succeeds), else its own write, sync or `close(2)`, else an event
    /// `append` could not encode.
    public func close() throws {
        try file.withLock { file in
            pending.withLock { $0.isClosed = true }
            guard let fd = file.fd else { return }
            file.fd = nil
            timer.cancel()
            drainPending(into: &file)

            var ownError: (any Error)?
            do { try writeUnwritten(&file, to: fd) } catch { ownError = error }
            do { try io.fullSync(fd) } catch { ownError = ownError ?? error }
            if Darwin.close(fd) != 0, ownError == nil { ownError = POSIXError.current() }
            let error = file.ioError ?? ownError ?? file.encodingError
            file.unwritten = []
            file.ioError = nil
            file.encodingError = nil
            if let error { throw error }
        }
    }

    /// Every `flushInterval`, on the timer's queue.
    func tick() {
        file.withLock { file in
            guard let fd = file.fd else { return }
            drainPending(into: &file)
            do {
                try writeUnwritten(&file, to: fd)
            } catch {
                // The bytes stay for the next tick, `flush()` or `close()`; one of those two throws it.
                if file.ioError == nil { file.ioError = error }
            }
            file.ticksSinceSync += 1
            guard file.ticksSinceSync >= ticksPerSync else { return }
            if file.needsSync {
                do {
                    try io.barrierSync(fd)
                } catch {
                    // Retried on the next tick; the next `flush()` or `close()` throws it.
                    if file.ioError == nil { file.ioError = error }
                    return
                }
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
    private func writeUnwritten(_ file: inout FileState, to fd: Int32) throws {
        var written = 0
        defer {
            if written > 0 {
                file.unwritten.removeFirst(written)
                file.needsSync = true
            }
        }
        try file.unwritten.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            while written < buffer.count {
                let count = try io.write(fd, UnsafeRawBufferPointer(rebasing: buffer[written...]))
                // `write(2)` on a regular file never writes 0 of a non-empty buffer; don't spin if it does.
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
    }
}

/// The calls through which `EventLogWriter` touches its file, so tests can make them fail.
struct EventLogIO: Sendable {
    /// Writes some of the bytes, retrying `EINTR`, and returns how many it wrote.
    var write: @Sendable (Int32, UnsafeRawBufferPointer) throws -> Int
    var barrierSync: @Sendable (Int32) throws -> Void
    var fullSync: @Sendable (Int32) throws -> Void

    static let system = EventLogIO(
        write: { fd, buffer in
            while true {
                let count = Darwin.write(fd, buffer.baseAddress, buffer.count)
                if count >= 0 { return count }
                if errno != EINTR { throw POSIXError.current() }
            }
        },
        barrierSync: { try DurableFile.barrierSync($0) },
        fullSync: { try DurableFile.fullSync($0) }
    )
}

/// What `EventLogReader.read` found in an `events.jsonl`.
public struct EventLogReadResult: Sendable {
    /// The events in file order, which is the order they were appended, not always the order of `t`.
    public var events: [InputEvent]
    /// The file ended inside a line that is not a whole JSON object: a write cut short by a crash.
    /// It was ignored.
    public var droppedTruncatedTail: Bool
    /// Lines that are whole but not an event this version can read (damaged, or of a newer type).
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
/// A line is whole when it ends with a line break. A last line without one is whole too if it is a
/// complete JSON object, because a write cut short never is one: it is read like any other line.
/// Otherwise it is a write cut short and is dropped. A whole line that is not an event is skipped
/// and counted, and the lines after it are still read.
public enum EventLogReader {
    /// Throws only if the file cannot be read: with `SafeRead.regularFile(at:)`, so a symlink throws `ELOOP` and a FIFO
    /// or anything else that is not a regular file `EFTYPE`, at once, never followed nor waited on.
    public static func read(_ url: URL) throws -> EventLogReadResult {
        parse(try SafeRead.regularFile(at: url))
    }

    /// `read(_:)` of the `events.jsonl` of take `take` of `package`, reached from the package's folder through no link
    /// (`SafeRead.regularFile(_:in:)`): a `takes/` or `takes/<take>/` that is a link throws `ELOOP` too.
    public static func read(take: String, of package: ProjectPackage) throws -> EventLogReadResult {
        parse(try SafeRead.regularFile("takes/\(take)/events.jsonl", in: package.url))
    }

    private static func parse(_ data: Data) -> EventLogReadResult {
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
                    } else if isWholeObject(tail) {
                        result.skippedLines += 1
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
    /// A last line without its line break that is not a complete JSON object (a write cut short by
    /// a crash) is truncated away. One that is a complete JSON object gets its line break, even if
    /// its `type` is unknown to this version, so no event is ever deleted. Returns `true` if the
    /// file changed. Whole lines are never touched. Throws `ELOOP` or `EFTYPE` if `url` is a symlink
    /// (never followed) or not a regular file.
    public static func truncateIncompleteTail(_ url: URL) throws -> Bool {
        let fd = try openRegularFile(url.path)
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

    /// Opens the regular file at `path` with `O_RDWR | O_APPEND`, never following a symlink.
    static func openRegularFile(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = POSIXError.current()
            close(fd)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw POSIXError(.EFTYPE)
        }
        return fd
    }

    /// `truncateIncompleteTail` on a file opened with `O_RDWR | O_APPEND`.
    static func endAtLineBoundary(_ fd: Int32) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError.current() }
        let size = info.st_size
        guard size > 0, try readBytes(fd, at: size - 1, count: 1) != [newline] else { return false }
        let tailStart = try startOfLastLine(fd, size: size)
        let tail = try readBytes(fd, at: tailStart, count: Int(size - tailStart))
        if isWholeObject(Data(tail)) {
            try DurableFile.writeAll(Data([newline]), to: fd)
        } else {
            guard ftruncate(fd, tailStart) == 0 else { throw POSIXError.current() }
        }
        try DurableFile.fullSync(fd)
        return true
    }

    /// Whether `bytes` is one complete JSON object. Every line is one, and no strict prefix of a
    /// JSON object is, so this tells a whole line that lacks its line break from a write cut short,
    /// whatever its `type`.
    private static func isWholeObject(_ bytes: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) else { return false }
        return object is [String: Any]
    }

    private static let chunkSize: off_t = 64 * 1024

    /// The offset right after the last line break before `size`, or 0 if there is none.
    static func startOfLastLine(_ fd: Int32, size: off_t) throws -> off_t {
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
    static func readBytes(_ fd: Int32, at offset: off_t, count: Int) throws -> [UInt8] {
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
