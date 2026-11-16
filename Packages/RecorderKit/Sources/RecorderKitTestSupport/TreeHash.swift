// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

/// SHA-256, in lowercase hex, of everything inside the folder `url`, to show that something wrote nothing in it: for
/// each file and folder below it, depth first and in the byte order of their names, its path relative to `url`, its type
/// and its contents (the bytes of a regular file, the target of a symlink). Symlinks are never followed, and a FIFO or
/// anything else that is not a regular file is hashed by its type alone, never opened. Dates and permissions do not count.
public func treeHash(_ url: URL) throws -> String {
    var hasher = SHA256()
    try hashEntries(in: url.path, relative: "", into: &hasher)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func hashEntries(in path: String, relative: String, into hasher: inout SHA256) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    for name in names {
        let entryPath = path + "/" + name
        let entryRelative = relative.isEmpty ? name : relative + "/" + name
        var info = stat()
        guard lstat(entryPath, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let type: UInt8
        switch info.st_mode & S_IFMT {
        case S_IFDIR: type = UInt8(ascii: "d")
        case S_IFREG: type = UInt8(ascii: "f")
        case S_IFLNK: type = UInt8(ascii: "l")
        default: type = UInt8(ascii: "o")
        }
        hasher.update(data: Data(entryRelative.utf8) + [0, type, 0])
        switch type {
        case UInt8(ascii: "d"):
            try hashEntries(in: entryPath, relative: entryRelative, into: &hasher)
        case UInt8(ascii: "f"):
            let bytes = try regularFileBytes(entryPath)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        case UInt8(ascii: "l"):
            hasher.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: entryPath).utf8))
        default:
            break
        }
    }
}

/// The bytes of the regular file at `path`, read without following a symlink and without blocking.
private func regularFileBytes(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 { return data }
        data.append(contentsOf: buffer[..<count])
    }
}
