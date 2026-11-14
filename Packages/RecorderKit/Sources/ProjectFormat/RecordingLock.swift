// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

/// Who holds a recording lock. Informative only: whether a take is being recorded
/// is decided by the `flock` lock on `recording.lock`, never by this content.
public struct RecordingLockInfo: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bootSessionUUID: String
    public var startedAt: Date

    public init(pid: Int32, bootSessionUUID: String, startedAt: Date) {
        self.pid = pid
        self.bootSessionUUID = bootSessionUUID
        self.startedAt = startedAt
    }

    /// This process, in this boot session, starting at `now` rounded down to a whole second.
    public static func current(now: Date) -> RecordingLockInfo {
        RecordingLockInfo(pid: getpid(), bootSessionUUID: bootSessionUUID(), startedAt: now.roundedToWholeSeconds)
    }

    /// `kern.bootsessionuuid`, which changes on every boot. Empty if the kernel does not report it.
    private static func bootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// An acquired recording lock. The lock lasts while its file descriptor is open.
///
/// Dropping the last reference releases the lock (`deinit` calls `release()`), so the
/// owner must keep a strong reference for the whole take.
public final class HeldRecordingLock: Sendable {
    private let path: String
    private let descriptor: Mutex<Int32?>

    init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = Mutex(descriptor)
    }

    deinit {
        release()
    }

    /// Deletes the lock file and closes the descriptor, which releases the lock.
    /// Calling it again does nothing.
    public func release() {
        guard let fd = descriptor.withLock({ $0.take() }) else { return }
        // Unlink before closing: a process that opens the path after this point creates a
        // new file, so it can never hold a lock on the old, unlinked one.
        unlink(path)
        close(fd)
    }
}

/// The lock that marks a take as being recorded right now.
///
/// It is a `flock` lock taken with `open(2)` and `O_EXLOCK`. The kernel drops it when
/// the process dies, so a crash never leaves a take that looks like it is still recording,
/// even if the lock file stays behind.
public enum RecordingLock {
    /// Takes the lock and writes `info` into the file.
    /// Throws `POSIXError(.EWOULDBLOCK)` if another open file holds it, even in this process, and
    /// `ELOOP` or `EFTYPE` if `url` is a symlink or not a regular file: a symlink is never followed, so
    /// a lock file planted in a package cannot make this truncate a file elsewhere.
    public static func acquire(at url: URL, info: RecordingLockInfo) throws -> HeldRecordingLock {
        let path = url.path
        let fd = try openLocked(path)
        do {
            let data = try ProjectJSON.encoder().encode(info)
            guard ftruncate(fd, 0) == 0 else { throw POSIXError.current() }
            try DurableFile.writeAll(data, to: fd)
        } catch {
            unlink(path)
            close(fd)
            throw error
        }
        return HeldRecordingLock(path: path, descriptor: fd)
    }

    /// `acquire(at:info:)`, tried again up to `retries` more times, `retryDelay` apart, while another open
    /// file holds the lock: `isHeld` probes by taking the lock for a moment, so an `acquire` that races a
    /// probe fails with `EWOULDBLOCK` although nobody is recording. Waits with `Task.sleep`, so no thread
    /// is blocked meanwhile, and runs on the caller's actor.
    ///
    /// Throws the last `POSIXError(.EWOULDBLOCK)` once the retries run out, any other error of `acquire` at
    /// once, and `CancellationError` if the task is cancelled while it waits.
    public nonisolated(nonsending) static func acquire(
        at url: URL, info: RecordingLockInfo, retries: Int, retryDelay: Duration = .milliseconds(20)
    ) async throws -> HeldRecordingLock {
        var retriesLeft = retries
        while true {
            do {
                return try acquire(at: url, info: info)
            } catch let error as POSIXError where error.code == .EWOULDBLOCK && retriesLeft > 0 {
                retriesLeft -= 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// Whether some open file holds the lock. `false` if the file does not exist, or is a symlink
    /// (never followed) or not a regular file. Never creates the file.
    public static func isHeld(at url: URL) -> Bool {
        let fd = openRetryingInterrupts(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The informative content of the lock file, or `nil` if it is missing or unreadable.
    public static func readInfo(at url: URL) -> RecordingLockInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ProjectJSON.decoder().decode(RecordingLockInfo.self, from: data)
    }

    /// Opens and locks `path`, a regular file and never a symlink, retrying if the file was unlinked
    /// between the `open` and the lock, so the lock always belongs to the file at `path`.
    private static func openLocked(_ path: String) throws -> Int32 {
        while true {
            let fd = openRetryingInterrupts(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError.current() }
            var opened = stat()
            var current = stat()
            guard fstat(fd, &opened) == 0 else {
                let error = POSIXError.current()
                close(fd)
                throw error
            }
            guard opened.st_mode & S_IFMT == S_IFREG else {
                close(fd)
                throw POSIXError(.EFTYPE)
            }
            // `lstat`: a symlink put at `path` since the `open` names another file, never this one.
            guard lstat(path, &current) == 0 else {
                let error = POSIXError.current()
                close(fd)
                if error.code == .ENOENT { continue }
                throw error
            }
            if current.st_dev == opened.st_dev, current.st_ino == opened.st_ino {
                return fd
            }
            close(fd)
        }
    }

    private static func openRetryingInterrupts(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
        while true {
            let fd = open(path, flags, mode)
            if fd >= 0 || errno != EINTR { return fd }
        }
    }
}
