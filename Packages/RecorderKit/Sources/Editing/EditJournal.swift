// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

private let newline = UInt8(ascii: "\n")

/// Whether the lines given to an `EditJournal` are on disk.
public enum JournalState: Equatable, Sendable {
    /// Every line is on disk.
    case saved
    /// This many lines are on their way to the disk.
    case pending(Int)
    /// The last attempt to write or sync them failed with this error: the lines wait in memory, in order, for the next
    /// retry. `ESTALE` is a file that is not the one the journal was writing any more (replaced, removed, or not ending
    /// with the last line it confirmed).
    case failing(POSIXErrorCode)
}

/// The calls through which `EditJournal` touches the disk, so tests can make them fail or count them (like
/// `EventLogIO`). Each throws a `POSIXError`.
public struct EditJournalIO: Sendable {
    /// Opens the file `name` of the folder `directory` for appending with `O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW |
    /// O_NONBLOCK | O_CLOEXEC` (without `O_CREAT` when `create` is false: a file that is gone gives `ENOENT`): never
    /// through a symlink (`ELOOP`), and never blocking (a FIFO without a reader gives `ENXIO`). Gives the descriptor and
    /// whether it created the file.
    public var open:
        @Sendable (_ directory: Int32, _ name: String, _ create: Bool) throws -> (descriptor: Int32, created: Bool)
    /// Writes some of the bytes, retrying `EINTR`, and returns how many it wrote.
    public var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws -> Int
    /// `F_FULLFSYNC`: the file down to the drive's permanent storage.
    public var fullSync: @Sendable (_ descriptor: Int32) throws -> Void
    /// `fsync(2)`, for a volume that does not support `F_FULLFSYNC`.
    public var fsync: @Sendable (_ descriptor: Int32) throws -> Void
    /// Makes the entries of the folder durable: `F_FULLFSYNC` on it, with `fsync` where that is not supported.
    public var syncDirectory: @Sendable (_ directory: Int32) throws -> Void

    public init(
        open: @escaping @Sendable (
            _ directory: Int32, _ name: String, _ create: Bool
        ) throws -> (descriptor: Int32, created: Bool),
        write: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws -> Int,
        fullSync: @escaping @Sendable (_ descriptor: Int32) throws -> Void,
        fsync: @escaping @Sendable (_ descriptor: Int32) throws -> Void,
        syncDirectory: @escaping @Sendable (_ directory: Int32) throws -> Void
    ) {
        self.open = open
        self.write = write
        self.fullSync = fullSync
        self.fsync = fsync
        self.syncDirectory = syncDirectory
    }

    public static let system = EditJournalIO(
        open: { directory, name, create in
            let flags = O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            while !create {
                let existing = openat(directory, name, flags & ~O_CREAT)
                if existing >= 0 { return (existing, false) }
                guard errno == EINTR else { throw POSIXError(.current) }
            }
            // `O_EXCL` first, to know whether it is a new file; without `O_CREAT` if it is there (the same flags
            // otherwise), and from the top if it went away between the two.
            while true {
                let created = openat(directory, name, flags | O_EXCL, 0o644)
                if created >= 0 { return (created, true) }
                guard errno == EEXIST || errno == EINTR else { throw POSIXError(.current) }
                let existing = openat(directory, name, flags & ~O_CREAT)
                if existing >= 0 { return (existing, false) }
                guard errno == ENOENT || errno == EINTR else { throw POSIXError(.current) }
            }
        },
        write: { descriptor, bytes in
            while true {
                let count = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                if count >= 0 { return count }
                guard errno == EINTR else { throw POSIXError(.current) }
            }
        },
        fullSync: { descriptor in
            guard fcntl(descriptor, F_FULLFSYNC) != -1 else { throw POSIXError(.current) }
        },
        fsync: { descriptor in
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.current) }
        },
        syncDirectory: { try DurableFile.fullSync($0) }
    )
}

/// Appends the lines of `edit-log.jsonl` and makes each one durable (design §6.5): an edit is saved when its line is on
/// the drive's permanent storage, so neither a crash nor a power loss loses it.
///
/// `append` only hands the line over and never waits. A serial queue of the journal's own writes what came and forces
/// it to disk with `F_FULLFSYNC` (`fsync` on a volume that does not support it), one sync for every line that arrived
/// meanwhile. A line is confirmed (`flushed()`, `.saved`) only after that sync and, for a log the journal created,
/// after a sync of its folder, without which a power loss can take the whole file.
///
/// A write or sync that fails keeps the lines in memory, in order, and is retried every `retryInterval`. After a write
/// that failed, the retry goes on with a line from the byte where the write stopped, so lines stay whole and none is
/// written twice. After a sync that failed it trusts none of the batch to be on its way to the disk (a failed writeback
/// can leave its pages clean, and syncing them again would succeed without writing them): it cuts the file back to the
/// last line confirmed and writes the whole batch again. After `ENXIO`, `EIO` or `EBADF` (a volume that was ejected)
/// the descriptor is dead: each retry opens the log again, by its name in the package folder or, if that folder's
/// descriptor died too, by the folder's last known path, and goes on only if the file still ends with the bytes of the
/// last line it confirmed (plus any it wrote after it); otherwise it stays `.failing(.ESTALE)`. Once a line is
/// confirmed it opens the log without `O_CREAT`: a log removed meanwhile is `.failing(.ENOENT)`, not a new empty file.
///
/// Everything goes through the descriptor of the package folder, so a package that is renamed or moved in the Finder
/// while open keeps receiving its lines. After each sync the journal checks that the log's name in that folder is still
/// the file it wrote to: one renamed over it from outside (a compaction done while the journal is open, plan-review C1)
/// would take every later line to a file without a name, which disappears when it is closed. Such lines are never
/// confirmed. The compaction that keeps the journal writing to the new log is `replaceLog(with:)`.
///
/// While the state is not `.saved`, sudden termination is disabled, as `TakeEnvironment` does during a take.
public final class EditJournal: Sendable {
    public static let retryInterval: Duration = .seconds(2)

    private let io: EditJournalIO
    private let retryDelay: DispatchTimeInterval
    /// The log's name in its folder.
    private let name: String
    private let queue = DispatchQueue(label: "dev.toma.EditJournal", qos: .userInitiated)

    // Lock order: `file`, then `shared`. Only the queue takes `file`, and only `file` is held during I/O: `append`
    // takes `shared` alone and never waits for the disk.
    private let shared: Mutex<Shared>
    private let file: Mutex<FileSide>

    /// What callers and the queue both touch.
    private struct Shared {
        var state = JournalState.saved
        /// Waiting for the queue, in the order they came.
        var items: [Item] = []
        /// Lines `append` took.
        var appended = 0
        /// Of them, those on disk, as themselves or in a log that replaced them.
        var confirmed = 0
        /// A drain of `items` is scheduled or running: a new line waits for it.
        var isDraining = false
        var isClosed = false
        var handler: (@Sendable (JournalState) -> Void)?
        var waiters: [Waiter] = []
        /// Sudden termination is disabled on the journal's behalf.
        var holdsSuddenTermination = false
    }

    private enum Item {
        /// A line with its line break.
        case line([UInt8])
        /// A log to put in place of the current one, and who waits for it.
        case replacement([UInt8], CheckedContinuation<Void, any Error>)
    }

    private struct Waiter {
        /// Waits until this many lines are on disk.
        var target: Int
        var continuation: CheckedContinuation<Int, Never>
    }

    /// The file side, only on the queue.
    private struct FileSide {
        /// `nil` while dead: the next attempt opens the log again.
        var descriptor: Int32?
        /// The package folder; -1 once closed.
        var directory: Int32
        /// Where that folder was the last time the journal looked, to open it again if its descriptor dies.
        var directoryPath: String
        /// Whole lines taken from `items` that are not confirmed yet, with their line breaks.
        var batch: [UInt8] = []
        var batchLines = 0
        /// How many bytes of `batch` are written.
        var written = 0
        /// The size of the file up to the end of the last line confirmed.
        var confirmedSize: off_t
        /// The bytes of that line (of the log's last line when it opened), to check the file after opening it again.
        var confirmedTail: [UInt8]
        /// A new file, or one renamed into place, whose entry in the folder is not synced yet: nothing is confirmed
        /// until it is.
        var needsDirectorySync: Bool
        /// A sync failed after the batch was written: the bytes the kernel holds for it may never reach the disk, and a
        /// later sync could succeed without writing them (a failed writeback can leave the pages clean). The next
        /// attempt cuts the file back to `confirmedSize` and writes the whole batch again.
        var mustRewrite = false
        var retryPending = false
        var isClosed = false
    }

    /// Opens `logURL` for appending, creating it if needed; its folder must exist. Never follows a symlink, neither as
    /// the log (`ELOOP`) nor as its folder (`ENOTDIR`), never blocks (a FIFO without a reader throws `ENXIO`) and
    /// refuses anything that is not a regular file (`EFTYPE`). A log that is there must end at a line break
    /// (`EditLogReader.truncateIncompleteTail` first): one that ends inside a line throws `EILSEQ`, since a line
    /// appended to it would join that line.
    public init(logURL: URL, io: EditJournalIO = .system, retryInterval: Duration = EditJournal.retryInterval) throws {
        let name = logURL.lastPathComponent
        let directoryPath = logURL.deletingLastPathComponent().path
        let directory = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.current) }
        let descriptor: Int32
        let created: Bool
        let size: off_t
        let tail: [UInt8]
        do {
            (descriptor, created) = try Self.openLog(name, in: directory, create: true, io: io)
            do {
                (size, tail) = try Self.lastLine(of: descriptor, named: name, in: directory)
                guard size == 0 || tail.last == newline else { throw POSIXError(.EILSEQ) }
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            Darwin.close(directory)
            throw error
        }
        self.io = io
        self.name = name
        retryDelay = retryInterval.dispatchInterval
        shared = Mutex(Shared())
        file = Mutex(
            FileSide(
                descriptor: descriptor, directory: directory, directoryPath: directoryPath, confirmedSize: size,
                confirmedTail: tail, needsDirectorySync: created))
    }

    deinit {
        // A journal dropped without `close()`: its lines that are not on disk are lost with it.
        file.withLock { file in
            if let descriptor = file.descriptor { Darwin.close(descriptor) }
            if file.directory >= 0 { Darwin.close(file.directory) }
        }
        shared.withLock { Self.releaseSuddenTermination(&$0) }
    }

    /// The state now; `onStateChange` tells each change.
    public var state: JournalState { shared.withLock { $0.state } }

    /// Calls `handler` with each state the journal goes into, in the order it went into them, on the main thread
    /// (`DispatchQueue.main.async`, so they keep that order). Replaces the handler given before.
    public func onStateChange(_ handler: @escaping @Sendable (JournalState) -> Void) {
        shared.withLock { $0.handler = handler }
    }

    /// Adds `line` (one line of the log, without its line break) to what goes to disk next, and returns at once.
    /// Throws `EBADF` after `close()`, when nothing would write the line any more.
    public func append(_ line: String) throws {
        var bytes = Array(line.utf8)
        bytes.append(newline)
        let outcome = shared.withLock { shared -> Bool? in
            guard !shared.isClosed else { return nil }
            shared.items.append(.line(bytes))
            shared.appended += 1
            // While failing, the line waits for the next retry, and the state stays what keeps it from the disk.
            if case .failing = shared.state { return false }
            Self.set(.pending(shared.appended - shared.confirmed), in: &shared)
            guard !shared.isDraining else { return false }
            shared.isDraining = true
            return true
        }
        guard let schedules = outcome else { throw POSIXError(.EBADF) }
        if schedules {
            queue.async { self.drain() }
        }
    }

    /// Waits until every line appended before the call is on disk, or until an attempt to write it failed (it does not
    /// wait for the retries), and returns how many lines of those `append` took are on disk.
    nonisolated(nonsending) public func flushed() async -> Int {
        await withCheckedContinuation { continuation in
            let now = shared.withLock { shared -> Int? in
                if shared.confirmed >= shared.appended || shared.isClosed { return shared.confirmed }
                if case .failing = shared.state { return shared.confirmed }
                shared.waiters.append(Waiter(target: shared.appended, continuation: continuation))
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    /// Replaces the log with `lines` (without their line breaks), a log that replays to the same document and stacks as
    /// everything the log holds (`LogCompaction.compact` of it): the compaction of design §6.5 while the journal holds
    /// the log, which then goes on appending to the new one (plan-review C1). The snapshot of the current state, at the
    /// last `seq`, goes first: the compaction renumbers the lines before it.
    ///
    /// It takes its turn after every line appended before the call, and only once they are all on disk: it throws the
    /// error that keeps one from the disk, at once if the journal is `.failing`, and replaces nothing (a log is never
    /// compacted with lines pending). It writes a temporary file next to the log, full-syncs it, renames it over the
    /// log (`renameat`) and syncs the folder. If that last sync fails, the new log is in place but a power loss could
    /// bring back the old one, which is equivalent: it does not throw, and no later line is confirmed until a sync of
    /// the folder succeeds. Throws `EBADF` after `close()`.
    nonisolated(nonsending) public func replaceLog(with lines: [String]) async throws {
        var bytes: [UInt8] = []
        for line in lines {
            bytes.append(contentsOf: line.utf8)
            bytes.append(newline)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome = shared.withLock { shared -> Result<Bool, POSIXError> in
                if shared.isClosed { return .failure(POSIXError(.EBADF)) }
                if case let .failing(code) = shared.state { return .failure(POSIXError(code)) }
                shared.items.append(.replacement(bytes, continuation))
                guard !shared.isDraining else { return .success(false) }
                shared.isDraining = true
                return .success(true)
            }
            switch outcome {
            case let .failure(error): continuation.resume(throwing: error)
            case .success(true): queue.async { self.drain() }
            case .success(false): break
            }
        }
    }

    /// Makes one last attempt to put every line on disk, without waiting for the retry interval, and closes the log.
    /// Later calls to `append` throw `EBADF`. A line that is still not on disk is lost with the journal, and not in
    /// silence: the state stays `.failing`. Sudden termination is enabled again: nothing can save that line any more,
    /// and the session asks before closing with lines that are not saved (design §5.9).
    nonisolated(nonsending) public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            shared.withLock { $0.isClosed = true }
            queue.async {
                self.finish()
                continuation.resume()
            }
        }
    }

    // MARK: - The queue

    private func drain() {
        file.withLock { file in
            guard !file.isClosed else { return }
            process(&file, finally: false)
        }
    }

    private func retry() {
        file.withLock { file in
            guard !file.isClosed, file.retryPending else { return }
            file.retryPending = false
            shared.withLock { $0.isDraining = true }
            process(&file, finally: false)
        }
    }

    private func finish() {
        file.withLock { file in
            guard !file.isClosed else { return }
            file.isClosed = true
            process(&file, finally: true)
            if let descriptor = file.descriptor { Darwin.close(descriptor) }
            file.descriptor = nil
            Darwin.close(file.directory)
            file.directory = -1
        }
        let (waiters, confirmed, replacements) = shared.withLock { shared in
            Self.releaseSuddenTermination(&shared)
            let waiters = shared.waiters
            shared.waiters = []
            return (waiters, shared.confirmed, Self.takeReplacements(&shared.items))
        }
        for waiter in waiters { waiter.continuation.resume(returning: confirmed) }
        for continuation in replacements { continuation.resume(throwing: POSIXError(.EBADF)) }
    }

    /// Writes and syncs what is waiting, a batch at a time (every line up to the next replacement), until nothing is
    /// left or an attempt fails. A failure schedules a retry, unless this is the attempt of `close()`.
    private func process(_ file: inout FileSide, finally isFinal: Bool) {
        while true {
            let hasBatch = !file.batch.isEmpty
            let taken = shared.withLock { shared -> (lines: [UInt8], count: Int, replacement: Item?)? in
                guard hasBatch || !shared.items.isEmpty else {
                    shared.isDraining = false
                    return nil
                }
                return Self.takeBatch(&shared.items)
            }
            guard let taken else { return }
            file.batch.append(contentsOf: taken.lines)
            file.batchLines += taken.count
            if !file.batch.isEmpty {
                if let code = attempt(&file) {
                    fail(code, &file, taken.replacement, finally: isFinal)
                    return
                }
                confirm(&file)
            }
            if case let .replacement(bytes, continuation)? = taken.replacement {
                if let code = swap(&file, to: bytes) {
                    continuation.resume(throwing: POSIXError(code))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// The lines at the front of `items`, up to and with the first replacement.
    private static func takeBatch(_ items: inout [Item]) -> (lines: [UInt8], count: Int, replacement: Item?) {
        var lines: [UInt8] = []
        var count = 0
        var taken = 0
        var replacement: Item?
        for item in items {
            taken += 1
            if case let .line(bytes) = item {
                lines.append(contentsOf: bytes)
                count += 1
            } else {
                replacement = item
                break
            }
        }
        items.removeFirst(taken)
        return (lines, count, replacement)
    }

    /// Takes every replacement out of `items`, keeping the lines in order.
    private static func takeReplacements(_ items: inout [Item]) -> [CheckedContinuation<Void, any Error>] {
        var continuations: [CheckedContinuation<Void, any Error>] = []
        items.removeAll { item in
            guard case let .replacement(_, continuation) = item else { return false }
            continuations.append(continuation)
            return true
        }
        return continuations
    }

    /// Writes the rest of the batch, syncs it (and the folder, if its entry is new) and checks that the log's name is
    /// still this file; the error if any of that fails.
    private func attempt(_ file: inout FileSide) -> POSIXErrorCode? {
        if file.descriptor == nil, let code = reopen(&file) { return code }
        guard let descriptor = file.descriptor else { return .EBADF }
        if file.mustRewrite {
            guard ftruncate(descriptor, file.confirmedSize) == 0 else { return died(.current, &file) }
            file.written = 0
            file.mustRewrite = false
        }
        // A write cut short goes on from where it stopped next time.
        if let code = write(file.batch, from: &file.written, to: descriptor) { return died(code, &file) }
        if file.needsDirectorySync {
            do {
                try io.syncDirectory(file.directory)
            } catch {
                file.mustRewrite = true
                return died(Self.code(error), &file)
            }
            file.needsDirectorySync = false
        }
        if let code = sync(descriptor) {
            file.mustRewrite = true
            return died(code, &file)
        }
        if let code = Self.stillNamed(descriptor, name, in: file.directory) {
            closeDescriptor(&file)
            return code
        }
        return nil
    }

    /// Writes `bytes` from `written` on, moving `written` past what it wrote; the error that stopped it.
    private func write(_ bytes: [UInt8], from written: inout Int, to descriptor: Int32) -> POSIXErrorCode? {
        bytes.withUnsafeBytes { buffer in
            while written < buffer.count {
                do {
                    let count = try io.write(descriptor, UnsafeRawBufferPointer(rebasing: buffer[written...]))
                    // `write(2)` on a regular file never writes 0 of a non-empty buffer; don't spin if it does.
                    guard count > 0 else { return .EIO }
                    written += count
                } catch {
                    return Self.code(error)
                }
            }
            return nil
        }
    }

    /// `F_FULLFSYNC`, or `fsync` where the volume does not support it.
    private func sync(_ descriptor: Int32) -> POSIXErrorCode? {
        do {
            try io.fullSync(descriptor)
            return nil
        } catch {
            let code = Self.code(error)
            guard code == .ENOTSUP || code == .EINVAL || code == .ENOTTY else { return code }
        }
        do {
            try io.fsync(descriptor)
            return nil
        } catch {
            return Self.code(error)
        }
    }

    /// `code`, after dropping the descriptor if the error is one after which it never works again.
    private func died(_ code: POSIXErrorCode, _ file: inout FileSide) -> POSIXErrorCode {
        if code == .ENXIO || code == .EIO || code == .EBADF { closeDescriptor(&file) }
        return code
    }

    private func closeDescriptor(_ file: inout FileSide) {
        if let descriptor = file.descriptor { Darwin.close(descriptor) }
        file.descriptor = nil
    }

    /// Opens the log again, by its name in the package folder or, if that folder's descriptor died too, by the folder's
    /// last known path, and checks that it is the file the journal was writing. A folder opened by its path is kept
    /// only if the log in it passes that check: until the volume is back, the path can name another folder.
    private func reopen(_ file: inout FileSide) -> POSIXErrorCode? {
        if let path = Self.path(of: file.directory) { file.directoryPath = path }
        var directory = file.directory
        // A folder descriptor that died with its volume is no folder any more: `openat` on it gives `ENOTDIR`.
        if !Self.isDirectory(directory) {
            directory = Darwin.open(file.directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { return .current }
        }
        let opened: (descriptor: Int32, created: Bool)
        do {
            // Once a line is confirmed, a log that is gone is an error, not a new empty file.
            opened = try Self.openLog(name, in: directory, create: file.confirmedSize == 0, io: io)
        } catch {
            if directory != file.directory { Darwin.close(directory) }
            return Self.code(error)
        }
        if let code = verify(opened.descriptor, in: directory, &file) {
            Darwin.close(opened.descriptor)
            if directory != file.directory { Darwin.close(directory) }
            return code
        }
        if directory != file.directory {
            Darwin.close(file.directory)
            file.directory = directory
        }
        file.descriptor = opened.descriptor
        if opened.created { file.needsDirectorySync = true }
        return nil
    }

    /// Whether the file `descriptor` opened in `directory` ends with the last line confirmed and then some of the
    /// batch, as the file the journal was writing does after an error: it goes on from where that file ends. `ESTALE`
    /// if not. After a failed sync (`mustRewrite`) what follows the last line confirmed is not checked: it is cut and
    /// written again.
    private func verify(_ descriptor: Int32, in directory: Int32, _ file: inout FileSide) -> POSIXErrorCode? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .current }
        let extra = info.st_size - file.confirmedSize
        guard extra >= 0, extra <= off_t(file.batch.count) else { return .ESTALE }
        let kept = file.mustRewrite ? 0 : extra
        let expected = file.confirmedTail + file.batch[..<Int(kept)]
        do {
            let reader = try Self.openForReading(descriptor, named: name, in: directory)
            defer { Darwin.close(reader) }
            let start = file.confirmedSize - off_t(file.confirmedTail.count)
            guard try Self.read(reader, start..<(file.confirmedSize + kept)) == expected else { return .ESTALE }
        } catch {
            return Self.code(error)
        }
        file.written = Int(kept)
        return nil
    }

    /// The batch is on disk.
    private func confirm(_ file: inout FileSide) {
        let lines = file.batchLines
        file.confirmedSize += off_t(file.batch.count)
        file.confirmedTail = Self.lastLine(of: file.batch)
        file.batch = []
        file.batchLines = 0
        file.written = 0
        if let path = Self.path(of: file.directory) { file.directoryPath = path }
        let (ready, confirmed) = shared.withLock { shared -> ([Waiter], Int) in
            shared.confirmed += lines
            let confirmed = shared.confirmed
            let pending = shared.appended - confirmed
            Self.set(pending > 0 ? .pending(pending) : .saved, in: &shared)
            let ready = shared.waiters.filter { $0.target <= confirmed }
            shared.waiters.removeAll { $0.target <= confirmed }
            return (ready, confirmed)
        }
        for waiter in ready { waiter.continuation.resume(returning: confirmed) }
    }

    /// An attempt failed: the batch stays for the next one, `flushed()` stops waiting, and no replacement waits for a
    /// retry.
    private func fail(_ code: POSIXErrorCode, _ file: inout FileSide, _ replacement: Item?, finally isFinal: Bool) {
        let (waiters, confirmed, replacements) = shared.withLock { shared in
            Self.set(.failing(code), in: &shared)
            shared.isDraining = false
            let waiters = shared.waiters
            shared.waiters = []
            return (waiters, shared.confirmed, Self.takeReplacements(&shared.items))
        }
        for waiter in waiters { waiter.continuation.resume(returning: confirmed) }
        if case let .replacement(_, continuation)? = replacement { continuation.resume(throwing: POSIXError(code)) }
        for continuation in replacements { continuation.resume(throwing: POSIXError(code)) }
        guard !isFinal, !file.retryPending else { return }
        file.retryPending = true
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.retry() }
    }

    /// Puts `bytes` in place of the log: a temporary file in the folder, full-synced, renamed over it and the folder
    /// synced; the journal then appends to it.
    private func swap(_ file: inout FileSide, to bytes: [UInt8]) -> POSIXErrorCode? {
        let temporary = name + ".tmp"
        let directory = file.directory
        // A stale temporary file (or a symlink) from an earlier run: `unlinkat` never follows a symlink.
        guard unlinkat(directory, temporary, 0) == 0 || errno == ENOENT else { return .current }
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = openat(directory, temporary, flags, 0o644)
        guard descriptor >= 0 else { return .current }
        var written = 0
        var failure = write(bytes, from: &written, to: descriptor) ?? sync(descriptor)
        if failure == nil, renameat(directory, temporary, directory, name) != 0 { failure = .current }
        if let failure {
            Darwin.close(descriptor)
            unlinkat(directory, temporary, 0)
            return failure
        }
        closeDescriptor(&file)
        file.descriptor = descriptor
        file.confirmedSize = off_t(bytes.count)
        file.confirmedTail = Self.lastLine(of: bytes)
        do {
            try io.syncDirectory(directory)
            file.needsDirectorySync = false
        } catch {
            file.needsDirectorySync = true
        }
        return nil
    }

    // MARK: - State

    /// Changes the state, telling the handler on the main thread in the order of the changes (this runs with the lock
    /// held), and keeps sudden termination disabled while the state is not `.saved`.
    private static func set(_ state: JournalState, in shared: inout Shared) {
        guard state != shared.state else { return }
        shared.state = state
        if state == .saved {
            releaseSuddenTermination(&shared)
        } else if !shared.holdsSuddenTermination {
            ProcessInfo.processInfo.disableSuddenTermination()
            shared.holdsSuddenTermination = true
        }
        if let handler = shared.handler {
            DispatchQueue.main.async { handler(state) }
        }
    }

    private static func releaseSuddenTermination(_ shared: inout Shared) {
        guard shared.holdsSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        shared.holdsSuddenTermination = false
    }

    // MARK: - Files

    /// `io.open`, checked to be a regular file (`EFTYPE` if not), with `O_NONBLOCK` cleared again: it only kept a FIFO
    /// from blocking the open.
    private static func openLog(
        _ name: String, in directory: Int32, create: Bool, io: EditJournalIO
    ) throws -> (descriptor: Int32, created: Bool) {
        let opened = try io.open(directory, name, create)
        var info = stat()
        guard fstat(opened.descriptor, &info) == 0 else {
            let error = POSIXError(.current)
            Darwin.close(opened.descriptor)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(opened.descriptor)
            throw POSIXError(.EFTYPE)
        }
        let flags = fcntl(opened.descriptor, F_GETFL)
        guard flags != -1, fcntl(opened.descriptor, F_SETFL, flags & ~O_NONBLOCK) != -1 else {
            let error = POSIXError(.current)
            Darwin.close(opened.descriptor)
            throw error
        }
        return opened
    }

    private static func isDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `nil` if `name` in `directory` is still the file `descriptor` is open on; otherwise `ESTALE`, or the error that
    /// keeps the name from being looked up (`ENOENT` once removed).
    private static func stillNamed(_ descriptor: Int32, _ name: String, in directory: Int32) -> POSIXErrorCode? {
        var written = stat()
        var named = stat()
        guard fstat(descriptor, &written) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .current
        }
        return written.st_dev == named.st_dev && written.st_ino == named.st_ino ? nil : .ESTALE
    }

    /// A read-only descriptor of the file `descriptor` is open on (the journal's own is write-only), opened as `name`
    /// in `directory`: `ESTALE` if that name is another file.
    private static func openForReading(_ descriptor: Int32, named name: String, in directory: Int32) throws -> Int32 {
        let reader = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard reader >= 0 else { throw POSIXError(.current) }
        var written = stat()
        var readable = stat()
        guard fstat(descriptor, &written) == 0, fstat(reader, &readable) == 0 else {
            let error = POSIXError(.current)
            Darwin.close(reader)
            throw error
        }
        guard written.st_dev == readable.st_dev, written.st_ino == readable.st_ino else {
            Darwin.close(reader)
            throw POSIXError(.ESTALE)
        }
        return reader
    }

    /// The bytes of `range`; fewer only if the file ends first.
    private static func read(_ descriptor: Int32, _ range: Range<off_t>) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(range.count))
        var done = 0
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while done < buffer.count {
                let count = pread(descriptor, base + done, buffer.count - done, range.lowerBound + off_t(done))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.current)
                }
                if count == 0 { break }
                done += count
            }
        }
        bytes.removeLast(bytes.count - done)
        return bytes
    }

    private static let chunkSize: off_t = 64 * 1024

    /// The size of the file `descriptor` is open on, and the bytes of its last line (with its line break, if it has
    /// one).
    private static func lastLine(
        of descriptor: Int32, named name: String, in directory: Int32
    ) throws -> (size: off_t, line: [UInt8]) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(.current) }
        let size = info.st_size
        guard size > 0 else { return (0, []) }
        let reader = try openForReading(descriptor, named: name, in: directory)
        defer { Darwin.close(reader) }
        // The line starts after the last line break before the last byte.
        var end = size - 1
        var start: off_t = 0
        while end > 0 {
            let chunkStart = max(0, end - chunkSize)
            if let index = try read(reader, chunkStart..<end).lastIndex(of: newline) {
                start = chunkStart + off_t(index) + 1
                break
            }
            end = chunkStart
        }
        return (size, try read(reader, start..<size))
    }

    /// The last line of `bytes`, whole lines with their line breaks.
    private static func lastLine(of bytes: [UInt8]) -> [UInt8] {
        let start = bytes.dropLast().lastIndex(of: newline).map { $0 + 1 } ?? 0
        return Array(bytes[start...])
    }

    /// Where the folder `directory` is now (`F_GETPATH`), if it can tell.
    private static func path(of directory: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return buffer.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, fcntl(directory, F_GETPATH, base) != -1 else { return nil }
            return String(cString: base)
        }
    }

    private static func code(_ error: any Error) -> POSIXErrorCode {
        (error as? POSIXError)?.code ?? .EIO
    }
}

extension POSIXErrorCode {
    /// The code of the current value of `errno`.
    fileprivate static var current: POSIXErrorCode { POSIXErrorCode(rawValue: errno) ?? .EIO }
}
