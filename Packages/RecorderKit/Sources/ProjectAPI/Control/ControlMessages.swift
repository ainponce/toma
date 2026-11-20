// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// A package by its folder's device and inode (plan 4b decision 19): the identity the control socket finds an editor's
/// project by, so another path to the same package (a link to a folder above it, `/var` for `/private/var`) is the same
/// package, and a package renamed or moved while open still is.
public struct ControlPackageID: Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64

    /// The identity of the folder at `url`, not followed if it is a link (`lstat`): `nil` if there is nothing there, or
    /// it is not a folder.
    public init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

/// What `toma` (or the MCP server) asks the app over its control socket (fases 4 y 5 design §6.4, plan 4b decision 19):
/// one request per connection, a line of JSON of at most `ControlServer.maxRequestBytes` ended by `\n`.
///
/// - `ping`: is the app there.
/// - `apply`: the app applies `commands` to the project at `package`, which it has open, through its editor
///   (`EditorModel.perform`): each a step of the editor's own, seen at once and undone with Edit ▸ Undo.
/// - `undo`, `redo`: Edit ▸ Undo or Redo of the editor of `package`.
/// - `flush`: the app waits until what its editor of `package` shows is on the disk, before a read or an export.
public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case ping, apply, undo, redo, flush }

    /// The version of these messages: 1.
    public static let currentVersion = 1

    public var version: Int = ControlRequest.currentVersion
    public var op: Op
    /// The package's absolute path (`ProjectPaths`' rules); `nil` for `ping`.
    public var package: String?
    /// The commands of `apply`, in order.
    public var commands: [ProjectCommand]?

    public init(op: Op, package: String?, commands: [ProjectCommand]?) {
        self.op = op
        self.package = package
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey { case version, op, package, commands }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        op = try container.decode(Op.self, forKey: .op)
        package = try container.decodeIfPresent(String.self, forKey: .package)
        commands = try container.decodeIfPresent([ProjectCommand].self, forKey: .commands)
    }
}

/// What the app answers. `handled: false` without an error: the app has no editor of that package that can edit it (it
/// is not open there, or open for viewing only), so whoever holds `edit.lock` is not the app; the caller says `locked`.
/// Otherwise what an `apply` did, as `BatchResult` says it (each result `via: app`), or the result of an `undo` or a
/// `redo` (its only result) or its error.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var handled: Bool
    public var results: [CommandResult]
    public var error: APIError?
    /// The index in `commands` of the command that failed.
    public var failedIndex: Int?

    public init(handled: Bool, results: [CommandResult], error: APIError?, failedIndex: Int?) {
        self.handled = handled
        self.results = results
        self.error = error
        self.failedIndex = failedIndex
    }

    /// The app does not have the package open for editing.
    public static let notHandled = ControlResponse(handled: false, results: [], error: nil, failedIndex: nil)

    /// Done, with nothing to say: a `ping` or a `flush`.
    public static let done = ControlResponse(handled: true, results: [], error: nil, failedIndex: nil)

    /// Refused as a whole with `error`: nothing was done.
    public static func refused(_ error: APIError) -> ControlResponse {
        ControlResponse(handled: true, results: [], error: error, failedIndex: nil)
    }
}

/// Why the control socket could not be listened on or talked to.
public enum ControlSocketError: Error, Equatable, Sendable {
    /// The socket's path does not fit a `sockaddr_un` (`ControlServer.maxPathBytes`).
    case pathTooLong
    /// Another server (another copy of the app) answers on the path: it is left alone.
    case inUse
    /// Something other than a socket of this user is at the path (a file, a folder, a link): it is left alone.
    case notASocket
    /// Nobody listens on the path: no app, or one that is not running any more.
    case noServer
    /// No answer within the time given, or the request was not taken.
    case timedOut
    /// A system call failed with this `errno` (`EBADMSG`: an answer that is not one; `EMSGSIZE`: a request or an answer
    /// too long; `EPERM`: a server of another user).
    case system(Int32)
}

/// The wire format: compact JSON on one line, its keys sorted, ended by `\n`.
enum ControlWire {
    static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }

    /// `path` as a `sockaddr_un`; `nil` if it does not fit (`ControlServer.maxPathBytes`).
    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// A new stream socket of `AF_UNIX`, closed on exec and never raising `SIGPIPE`.
    static func socket() throws(ControlSocketError) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// `connect` to `address`; `errno` on failure.
    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32? {
        var address = address
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0 ? nil : errno
    }

    /// Sets or clears `O_NONBLOCK`.
    static func setBlocking(_ fd: Int32, _ blocking: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
    }

    /// A send timeout of `duration` on `fd`.
    static func setSendTimeout(_ fd: Int32, _ duration: Duration) {
        var time = timeval(duration)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all of `data`; `false` if the peer went or the send timed out.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    enum ReadFailure: Error { case timedOut, tooLong, closed, failed(Int32) }

    /// The bytes up to the first `\n` (without it), read before `deadline`, of at most `limit` bytes with the `\n`.
    static func readLine(_ fd: Int32, limit: Int, deadline: ContinuousClock.Instant) -> Result<Data, ReadFailure> {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return .failure(.timedOut) }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(clamping: max(1, Int((left / .milliseconds(1)).rounded(.up))))
            let ready = poll(&poller, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(.failed(errno))
            }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, min($0.count, limit + 1 - line.count)) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(.failed(errno))
            }
            if count == 0 { return .failure(.closed) }
            let read = chunk[0..<count]
            if let end = read.firstIndex(of: 0x0A) {
                line.append(contentsOf: read[..<end])
                return line.count + 1 <= limit ? .success(line) : .failure(.tooLong)
            }
            line.append(contentsOf: read)
            // Even if the next byte were its `\n`, the line would be too long.
            if line.count >= limit { return .failure(.tooLong) }
        }
    }
}

extension timeval {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self.init(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    }
}
