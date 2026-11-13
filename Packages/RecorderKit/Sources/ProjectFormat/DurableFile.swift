// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// File writes that survive a crash or a power loss.
public enum DurableFile {
    /// Replaces `url` with `data` so that a reader, or the next launch after a crash,
    /// sees either the old file or the new one, never a partial one.
    ///
    /// Writes `<url>.tmp`, flushes it to the drive with `F_FULLFSYNC`, renames it over `url`
    /// with `rename(2)` and syncs the parent directory so the rename is durable too.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporaryPath = url.path + ".tmp"
        do {
            try writeAndFullSync(data, toNewFileAt: temporaryPath)
            guard rename(temporaryPath, url.path) == 0 else { throw POSIXError.current() }
        } catch {
            unlink(temporaryPath)
            throw error
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    /// Flushes the file and asks the drive to write its cache to permanent storage.
    public static func fullSync(_ fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) != -1 else { throw POSIXError.current() }
    }

    /// Flushes the file and orders it before later writes, without waiting for the drive cache.
    /// Cheaper than `fullSync`; meant for files that are appended to while recording.
    public static func barrierSync(_ fd: Int32) throws {
        guard fcntl(fd, F_BARRIERFSYNC) != -1 else { throw POSIXError.current() }
    }

    /// Makes the creation, removal or renaming of entries in a directory durable.
    public static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError.current() }
    }

    private static func writeAndFullSync(_ data: Data, toNewFileAt path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current() }
        do {
            try writeAll(data, to: fd)
            try fullSync(fd)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw POSIXError.current() }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var next = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, next, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                next += written
                remaining -= written
            }
        }
    }
}

extension POSIXError {
    /// The error for the current value of `errno`.
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
