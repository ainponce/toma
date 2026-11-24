// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import Synchronization
import os

/// The app's end of the control socket (fases 4 y 5 design §6.4, plan 4b decision 19): a Unix socket at `path`, of mode
/// `0600`, answered only for a peer of this user (`getpeereid` and `peerCheck`). Each connection carries one request, a
/// line of JSON of at most `maxRequestBytes` that must arrive within `requestTimeout`, and gets one answer, the
/// `handler`'s. A peer of another user, a request too long, too slow or that is not one, is dropped without the handler
/// hearing of it; the other connections are answered meanwhile (each its own, at most `maxConnections` at once). No
/// network: `AF_UNIX` only.
///
/// One server per path: it holds `flock` on the file next to the socket named like it with `.lock`
/// (`control.lock` for `control.sock`, `ControlWire.lockPath`) for as long as it listens, and the kernel lets go of it
/// when the process ends, crash included. `start()` without that lock is `inUse` (another copy of the app listens, even
/// one too busy to accept): nothing is probed nor removed. With it, a socket of this user at the path is a crash's and
/// is replaced; anything else there (a file, a folder, a link, another user's socket) is `notASocket` and never
/// removed. `stop()` removes the socket only while it is still its own (the same inode), then lets go of the lock; the
/// lock file stays (removing it would let two servers lock two files of one name).
public final class ControlServer: Sendable {
    /// A request's most bytes, its `\n` included: 1 MiB.
    public static let maxRequestBytes = 1 << 20
    /// How long a connection has to send its request: 5 s.
    public static let requestTimeout: Duration = .seconds(5)
    /// The most connections answered at once; one more is closed at once.
    public static let maxConnections = 32
    /// The longest path a `sockaddr_un` holds, in bytes (without its terminating zero).
    public static let maxPathBytes = 103
    /// `~/Library/Application Support/dev.toma.Toma/control.sock`.
    public static var defaultPath: URL { APIEnvironment.defaultControlSocket }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "ControlSocket")

    public let path: URL
    private let peerCheck: @Sendable (uid_t) -> Bool
    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    private let timeout: Duration
    private let connections = DispatchQueue(
        label: "dev.toma.ControlServer.connections", qos: .userInitiated, attributes: .concurrent)

    private struct Listening {
        var source: any DispatchSourceRead
        /// The open lock file (`ControlWire.lockPath`), locked: closed, it lets go, once the socket is removed.
        var lock: Int32
        /// The socket file this server made: removed by `stop()` only while it is still there.
        var device: dev_t
        var inode: ino_t
    }

    private let listening = Mutex<Listening?>(nil)
    private let active = Mutex(0)

    /// - Parameters:
    ///   - peerCheck: whether a peer of this user id is answered; this user's alone by default.
    ///   - requestTimeout: how long a connection has to send its request (`ControlServer.requestTimeout`).
    ///   - handler: the answer to a request; called on no particular thread, once per request, never for one dropped.
    public init(
        path: URL, peerCheck: @escaping @Sendable (uid_t) -> Bool = { $0 == geteuid() },
        requestTimeout: Duration = ControlServer.requestTimeout,
        handler: @escaping @Sendable (ControlRequest) async -> ControlResponse
    ) {
        self.path = path
        self.peerCheck = peerCheck
        self.timeout = requestTimeout
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Listens on `path`, holding the lock of its server (`ControlWire.lockPath`): the socket is made there with mode
    /// `0600` (its folder is the caller's: the app's is `0700`). A socket of this user left there is removed first;
    /// anything else there is left as it is. Starting a server that is listening does nothing.
    /// - Throws: `pathTooLong`, `inUse` (another server holds the lock), `notASocket` (a file, a folder, a link, or a
    ///   socket of another user at the path, or a lock file that is not a file of this user), `system` (the call that
    ///   failed).
    public func start() throws(ControlSocketError) {
        guard listening.withLock({ $0 == nil }) else { return }
        let file = path.path
        guard let address = ControlWire.address(file) else { throw .pathTooLong }
        let lock = try Self.lock(ControlWire.lockPath(for: path))
        do throws(ControlSocketError) {
            try Self.clearStale(file)
            try bindAndListen(at: file, address: address, lock: lock)
        } catch {
            close(lock)
            throw error
        }
    }

    /// Binds and listens at `file` (`address`), holding `lock`.
    private func bindAndListen(at file: String, address: sockaddr_un, lock: Int32) throws(ControlSocketError) {
        let fd = try ControlWire.socket()
        var bound = address
        let result = withUnsafePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            // Something bound it since it was looked at, without the lock.
            throw code == EADDRINUSE ? .inUse : .system(code)
        }
        // Before anyone could connect (`listen`), and the socket made by `bind` has no write permission for the others
        // (the umask's) meanwhile.
        var info = stat()
        guard chmod(file, 0o600) == 0, lstat(file, &info) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(file)
            throw .system(code)
        }
        ControlWire.setBlocking(fd, false)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "dev.toma.ControlServer.accept", qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        listening.withLock { $0 = Listening(source: source, lock: lock, device: info.st_dev, inode: info.st_ino) }
        source.resume()
    }

    /// Stops listening: the socket is removed if it is still the one `start()` made (a newer server's is left), and
    /// the connections under way are answered.
    public func stop() {
        guard let stopping = listening.withLock({ state -> Listening? in
            defer { state = nil }
            return state
        }) else { return }
        stopping.source.cancel()
        var info = stat()
        if lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_dev == stopping.device,
           info.st_ino == stopping.inode
        {
            unlink(path.path)
        }
        // After the socket is gone: the next server finds nothing of this one's.
        close(stopping.lock)
    }

    // MARK: - Private

    /// Takes the lock of the server of a path (`ControlWire.lockPath`): `inUse` while another server holds it. A
    /// client's look at it (`ControlWire.isServing`, a shared lock for an instant) is waited out for a moment.
    private static func lock(_ lockPath: String) throws(ControlSocketError) -> Int32 {
        var tries = 0
        while true {
            let fd = open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                    close(fd)
                    throw .notASocket
                }
                return fd
            }
            switch errno {
            case EWOULDBLOCK where tries < 10:
                tries += 1
                usleep(20_000)
            case EWOULDBLOCK: throw .inUse
            case EINTR: continue
            case ELOOP, EISDIR: throw .notASocket
            case let code: throw .system(code)
            }
        }
    }

    /// With the lock held, nobody else listens at `file`: a socket of this user there is a crash's, and is removed.
    /// Anything else is left as it is.
    private static func clearStale(_ file: String) throws(ControlSocketError) {
        var info = stat()
        guard lstat(file, &info) == 0 else {
            guard errno == ENOENT else { throw .system(errno) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw .notASocket }
        guard unlink(file) == 0 || errno == ENOENT else { throw .system(errno) }
    }

    /// Takes every connection waiting, each answered on its own.
    private func acceptAll(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR: continue
                case EMFILE, ENFILE:
                    // No descriptor to take it with: the event would come back at once and spin. A pause, then again.
                    pauseAccepting()
                default: break  // EAGAIN: none left; anything else: the next event tries again.
                }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // An accepted socket takes the listener's O_NONBLOCK here: reads wait with `poll`, writes with a timeout.
            ControlWire.setBlocking(client, true)
            let admitted = active.withLock { count in
                guard count < Self.maxConnections else { return false }
                count += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            connections.async { [self] in serve(client) }
        }
    }

    /// Stops taking connections for `acceptPause` (the process is out of descriptors), then takes them again.
    private func pauseAccepting() {
        guard let source = listening.withLock({ $0?.source }) else { return }
        Self.logger.error("Control socket: out of file descriptors; connections wait")
        source.suspend()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) { source.resume() }
    }

    /// One connection, from its peer's check to its answer; closed in every case.
    private func serve(_ fd: Int32) {
        var finished = true
        defer {
            if finished { finish(fd) }
        }
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, peerCheck(uid) else {
            Self.logger.notice("Control socket: a peer of user \(uid, privacy: .public) was refused")
            return
        }
        let line: Data
        switch ControlWire.readLine(fd, limit: Self.maxRequestBytes, deadline: .now + timeout) {
        case let .success(read): line = read
        case let .failure(why):
            Self.logger.notice("Control socket: a request was dropped (\(String(describing: why), privacy: .public))")
            return
        }
        let request: ControlRequest
        do {
            request = try ControlWire.decode(ControlRequest.self, from: line)
        } catch {
            let message = (error as? APIError)?.message ?? "the request is not one of Toma's control socket"
            respond(.refused(APIError(.invalidCommand, message)), on: fd)
            return
        }
        guard request.version == ControlRequest.currentVersion else {
            respond(
                .refused(APIError(.notAvailable, "this Toma speaks version \(ControlRequest.currentVersion) of the control socket, not \(request.version)")),
                on: fd)
            return
        }
        finished = false
        let handler = handler
        Task {
            let response = await handler(request)
            connections.async { [self] in
                respond(response, on: fd)
                finish(fd)
            }
        }
    }

    private func respond(_ response: ControlResponse, on fd: Int32) {
        ControlWire.setSendTimeout(fd, timeout)
        guard let data = try? ControlWire.line(response), ControlWire.writeAll(fd, data) else {
            Self.logger.notice("Control socket: an answer could not be sent")
            return
        }
    }

    private func finish(_ fd: Int32) {
        close(fd)
        active.withLock { $0 -= 1 }
    }
}
