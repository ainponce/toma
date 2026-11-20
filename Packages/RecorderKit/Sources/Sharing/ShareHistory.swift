// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// The links shared from a project, `shares.json` at the root of its package (fases 4 y 5 design §8.3, plan 5a decision
/// 4): `{"version": 1, "shares": [ShareRecord…]}`, written with `ProjectJSON.encoder()`, outside the manifest. The app and
/// `toma` may share the same package at once: reading, adding and writing go under an exclusive `flock` of a descriptor
/// of the package's folder, and the file is replaced whole and atomically from that descriptor
/// (`DurableFile.writeAtomically(_:named:inDirectory:)`), so a reader sees the rows of before or of after, never a part,
/// and two appends never lose one.
///
/// What it does not know survives a write: the keys of the file it does not know, the fields of a row it does not know,
/// and the rows it cannot decode (kept as they are, not listed). A file it cannot read (not JSON, not an object of
/// version 1 with a list of `shares`, a version newer than 1, more than `maxBytes`, a link, anything but a regular file)
/// is `ShareError.historyUnreadable` and is never written over. It is the only file milestone 5a writes in a package,
/// and it never holds the secret.
public struct ShareHistory: Sendable {
    public static let fileName = "shares.json"
    /// The largest `shares.json` read, and written: a few thousand links.
    public static let maxBytes = 1_048_576
    /// The format of the file this reads and writes.
    static let version: Int64 = 1

    public let package: ProjectPackage

    public init(package: ProjectPackage) {
        self.package = package
    }

    /// The links, newest first (of two in the same second, the one added last first); none without a file.
    /// - Throws: `ShareError.historyUnreadable` for a file this cannot read; the `POSIXError` of a package that cannot be
    ///   opened.
    public func records() throws -> [ShareRecord] {
        let file = try locked { _ in try read() }
        let decoded = file.rows.enumerated().compactMap { index, row in
            (try? row.decoded(as: ShareRecord.self)).map { (index, $0) }
        }
        return decoded.sorted { ($0.1.createdAt, $0.0) > ($1.1.createdAt, $1.0) }.map(\.1)
    }

    /// `record` added after the links there are, in one atomic write.
    /// - Throws: `ShareError.historyUnreadable` for a file this cannot read, which is left as it is; `POSIXError(.EFBIG)`,
    ///   writing nothing, if the file would grow past `maxBytes`; the `POSIXError` of a call that fails.
    public func append(_ record: ShareRecord) throws {
        let row = try JSONValue(encoding: record)
        try locked { folder in
            var file = try read()
            file.rows.append(row)
            try write(file, in: folder)
        }
    }

    /// The rows of the link `id` taken out, in one atomic write; nothing is written if there are none (or no file).
    /// - Throws: as `append(_:)`.
    public func remove(id: String) throws {
        try locked { folder in
            var file = try read()
            let kept = file.rows.filter { row in
                guard case let .object(members) = row, case let .string(rowID)? = members["id"] else { return true }
                return rowID != id
            }
            guard kept.count != file.rows.count else { return }
            file.rows = kept
            try write(file, in: folder)
        }
    }

    // MARK: - Private

    /// The file as read: its members but `shares`, and its rows as they are.
    private struct File {
        var others: [String: JSONValue] = [:]
        var rows: [JSONValue] = []
    }

    /// `body` with an exclusive `flock` of a descriptor of the package's folder (where it is now), given to it. On a
    /// volume without `flock` (SMB, exFAT), without the lock: each write is still whole and atomic.
    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        let folder = open(package.currentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw Self.posixError() }
        defer { close(folder) }
        while flock(folder, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            guard errno == ENOTSUP || errno == EOPNOTSUPP else { throw Self.posixError() }
            break
        }
        return try body(folder)
    }

    /// `shares.json`, read through no link (`SafeRead`), within `maxBytes`; an empty file when there is none.
    private func read() throws -> File {
        let url = package.currentURL.appending(path: Self.fileName, directoryHint: .notDirectory)
        let data: Data
        do {
            data = try SafeRead.regularFile(at: url, maxBytes: Self.maxBytes)
        } catch let error as POSIXError where error.code == .ENOENT {
            return File()
        } catch {
            throw ShareError.historyUnreadable
        }
        guard let value = try? ProjectJSON.decoder().decode(JSONValue.self, from: data),
            case var .object(members) = value, members["version"] == .integer(Self.version),
            case let .array(rows)? = members.removeValue(forKey: "shares")
        else { throw ShareError.historyUnreadable }
        return File(others: members, rows: rows)
    }

    /// `file` written over `shares.json` in the folder `fd` is open on, whole and atomically.
    private func write(_ file: File, in fd: Int32) throws {
        var members = file.others
        members["version"] = .integer(Self.version)
        members["shares"] = .array(file.rows)
        let data = try ProjectJSON.encoder().encode(JSONValue.object(members))
        guard data.count <= Self.maxBytes else { throw POSIXError(.EFBIG) }
        try DurableFile.writeAtomically(data, named: Self.fileName, inDirectory: fd)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
