// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation

/// The command line's end of the control socket (plan 4b decision 19): one request, one answer, over a connection of its
/// own. It talks only to a server of this user (`getpeereid`), and never waits on a thread of Swift's cooperative pool.
public enum ControlClient {
    /// The most bytes of an answer, its `\n` included: 4 MiB.
    public static let maxResponseBytes = 4 << 20

    /// Sends `request` to the server at `path` and waits for its answer, `timeout` at most from the connection on.
    /// - Throws: `pathTooLong`; `noServer` when nobody listens there (nothing was sent); `timedOut`; `system` (`EBADMSG`
    ///   for an answer that is not one, `EMSGSIZE` for a request longer than `ControlServer.maxRequestBytes`, `EPERM` for
    ///   a server of another user, `ECONNRESET` for one that closed without answering).
    public static func send(
        _ request: ControlRequest, to path: URL, timeout: Duration
    ) async throws(ControlSocketError) -> ControlResponse {
        guard let address = ControlWire.address(path.path) else { throw .pathTooLong }
        let line: Data
        do {
            line = try ControlWire.line(request)
        } catch {
            throw .system(EINVAL)
        }
        guard line.count <= ControlServer.maxRequestBytes else { throw .system(EMSGSIZE) }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<ControlResponse, ControlSocketError>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { () throws(ControlSocketError) -> ControlResponse in
                    try exchange(line, with: address, timeout: timeout)
                })
            }
        }
        return try result.get()
    }

    /// The connection, the request and the answer, blocking.
    private static func exchange(_ line: Data, with address: sockaddr_un, timeout: Duration) throws(ControlSocketError) -> ControlResponse {
        let deadline = ContinuousClock.now + timeout
        let fd = try ControlWire.socket()
        defer { close(fd) }
        if let code = ControlWire.connect(fd, to: address) {
            switch code {
            case ENOENT, ECONNREFUSED: throw .noServer
            case ENOTSOCK: throw .notASocket
            default: throw .system(code)
            }
        }
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { throw .system(errno) }
        guard uid == geteuid() else { throw .system(EPERM) }
        ControlWire.setSendTimeout(fd, timeout)
        guard ControlWire.writeAll(fd, line) else {
            switch errno {
            case EAGAIN, EWOULDBLOCK: throw .timedOut
            // The server closed the connection before taking the request (a peer it refuses).
            case EPIPE: throw .system(ECONNRESET)
            case let code: throw .system(code)
            }
        }
        switch ControlWire.readLine(fd, limit: maxResponseBytes, deadline: deadline) {
        case let .success(answer):
            do {
                return try ControlWire.decode(ControlResponse.self, from: answer)
            } catch {
                throw .system(EBADMSG)
            }
        case .failure(.timedOut): throw .timedOut
        case .failure(.tooLong): throw .system(EMSGSIZE)
        case .failure(.closed): throw .system(ECONNRESET)
        case let .failure(.failed(code)): throw .system(code)
        }
    }
}
