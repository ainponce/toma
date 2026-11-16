// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Trees of files through descriptors, for the library's copies and deletions (`LibraryOperations`): nothing here ever
/// follows a link.
enum FileTree {
    /// Removes the item `name` of the folder open at `folder` and, if it is a folder, everything in it, depth first;
    /// `beforeEach` before each item is removed. A link is removed itself, never followed, and what is already gone
    /// counts as removed. Stops at the first item that cannot be removed and throws its error.
    static func removeTree(named name: String, in folder: Int32, beforeEach: () -> Void) throws {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(errnoCode())
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let inner = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard inner >= 0 else {
                if errno == ENOENT { return }
                throw POSIXError(errnoCode())
            }
            defer { close(inner) }
            for entry in try names(in: inner) {
                try removeTree(named: entry, in: inner, beforeEach: beforeEach)
            }
        }
        beforeEach()
        let flags = info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
        guard unlinkat(folder, name, flags) == 0 || errno == ENOENT else { throw POSIXError(errnoCode()) }
    }

    static func realPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    /// Where the item open at `fd` is now (`F_GETPATH`), or `nil` if the system does not say.
    static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The names in the folder open at `fd`, but `.` and `..`.
    static func names(in fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw POSIXError(errnoCode()) }
        guard let stream = fdopendir(copy) else {
            let error = POSIXError(errnoCode())
            close(copy)
            throw error
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(errnoCode()) }
                return names
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    static func errnoCode() -> POSIXErrorCode { POSIXErrorCode(rawValue: errno) ?? .EIO }
}

/// A copy of a folder, through descriptors: the original or its folder can be renamed meanwhile. Never follows a link
/// (a link is copied as one); a FIFO is made again; anything else that is not a file or a folder is left out. Files are
/// copied in steps of `stepBytes`, with `beforeEachStep` before each (it pauses) and `progress` after (the bytes copied
/// over those of the original, below 1); each file and folder gets the original's permissions and dates, and each file
/// is synced (`fsync`) before it is closed: the caller makes the whole copy durable with one `F_FULLFSYNC` before it
/// shows it.
final class FolderCopy {
    /// The size of each read and write: a take that starts stops the copy within one of these.
    static let stepBytes = 1 << 20

    private let source: Int32
    private let total: Int64
    private var copied: Int64 = 0
    private let progress: (Double) -> Void
    private let beforeEachStep: () -> Void
    private var buffer = [UInt8](repeating: 0, count: FolderCopy.stepBytes)

    init(_ source: Int32, progress: @escaping (Double) -> Void, beforeEachStep: @escaping () -> Void) throws {
        self.source = source
        self.progress = progress
        self.beforeEachStep = beforeEachStep
        total = try Self.bytes(in: source)
    }

    /// Makes the folder `name` in the folder open at `parent` a copy of the source.
    func copy(into parent: Int32, named name: String) throws {
        var info = stat()
        guard fstat(source, &info) == 0 else { throw POSIXError(FileTree.errnoCode()) }
        try copyFolder(source, info: info, into: parent, named: name)
    }

    private func copyFolder(_ folder: Int32, info: stat, into parent: Int32, named name: String) throws {
        guard mkdirat(parent, name, 0o700) == 0 else { throw POSIXError(FileTree.errnoCode()) }
        let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { throw POSIXError(FileTree.errnoCode()) }
        defer { close(target) }
        for entry in try FileTree.names(in: folder) {
            var item = stat()
            guard fstatat(folder, entry, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
                // Gone meanwhile: the editor replaces its files by renames.
                if errno == ENOENT { continue }
                throw POSIXError(FileTree.errnoCode())
            }
            switch item.st_mode & S_IFMT {
            case S_IFDIR:
                let inner = openat(folder, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard inner >= 0 else { throw POSIXError(FileTree.errnoCode()) }
                defer { close(inner) }
                try copyFolder(inner, info: item, into: target, named: entry)
            case S_IFREG:
                try copyFile(entry, in: folder, into: target)
            case S_IFLNK:
                var destination = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
                let length = readlinkat(folder, entry, &destination, Int(MAXPATHLEN))
                guard length >= 0 else { throw POSIXError(FileTree.errnoCode()) }
                destination[length] = 0
                guard symlinkat(destination, target, entry) == 0 else { throw POSIXError(FileTree.errnoCode()) }
            case S_IFIFO:
                guard mkfifoat(target, entry, item.st_mode & 0o7777) == 0 else { throw POSIXError(FileTree.errnoCode()) }
            default:
                continue
            }
        }
        try Self.setModeAndDates(of: target, as: info)
    }

    private func copyFile(_ name: String, in folder: Int32, into target: Int32) throws {
        let input = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(FileTree.errnoCode()) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw POSIXError(FileTree.errnoCode()) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        let output = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(FileTree.errnoCode()) }
        defer { close(output) }
        while true {
            beforeEachStep()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(FileTree.errnoCode())
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = write(output, bytes.baseAddress! + offset, count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(FileTree.errnoCode())
                    }
                    offset += written
                }
            }
            copied += Int64(count)
            progress(min(Double(copied) / Double(max(total, 1)), 1.0.nextDown))
        }
        try Self.setModeAndDates(of: output, as: info)
        guard fsync(output) == 0 else { throw POSIXError(FileTree.errnoCode()) }
    }

    /// The permissions and the access and modification dates of `info`, on the item open at `fd`.
    private static func setModeAndDates(of fd: Int32, as info: stat) throws {
        guard fchmod(fd, info.st_mode & 0o7777) == 0 else { throw POSIXError(FileTree.errnoCode()) }
        let times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(fd, times) == 0 else { throw POSIXError(FileTree.errnoCode()) }
    }

    /// The bytes of every regular file in the folder open at `folder`, links not followed.
    private static func bytes(in folder: Int32) throws -> Int64 {
        var total: Int64 = 0
        for entry in try FileTree.names(in: folder) {
            var item = stat()
            guard fstatat(folder, entry, &item, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch item.st_mode & S_IFMT {
            case S_IFREG:
                total += Int64(item.st_size)
            case S_IFDIR:
                let inner = openat(folder, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard inner >= 0 else { throw POSIXError(FileTree.errnoCode()) }
                defer { close(inner) }
                total += try bytes(in: inner)
            default:
                break
            }
        }
        return total
    }
}
