// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import ProjectAPI

/// The control socket (fases 4 y 5 design §6.4; plan 4b, Task A6, Review Focus 5): one request and one answer per
/// connection, only for this user, never left deaf, insecure or stuck by an old socket, another copy of the app, a file in
/// its place or a slow client. Every socket is in a folder of its own with a short path (a `sockaddr_un` holds 103 bytes).
@Suite struct ControlSocketTests {
    @Test func roundTripOverTheSocket() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let seen = Mutex<[ControlRequest]>([])
            let server = ControlServer(path: path) { request in
                seen.withLock { $0.append(request) }
                return ControlResponse(handled: true, results: [Self.result], error: nil, failedIndex: nil)
            }
            try server.start()
            defer { server.stop() }
            let request = ControlRequest(
                op: .apply, package: "/tmp/Demo.toma", commands: [.addMarker(at: 1.5, name: "CLI"), .setTitle("Demo / prueba")])
            let response = try await ControlClient.send(request, to: path, timeout: .seconds(5))
            #expect(response == ControlResponse(handled: true, results: [Self.result], error: nil, failedIndex: nil))
            #expect(seen.withLock { $0 } == [request])
            // A refusal with its error comes back as it was.
            let ping = try await ControlClient.send(ControlRequest(op: .ping, package: nil, commands: nil), to: path, timeout: .seconds(5))
            #expect(ping.handled)
        }
    }

    @Test func socketIsUserOnly0600() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let server = ControlServer(path: path) { _ in .done }
            try server.start()
            defer { server.stop() }
            var info = stat()
            #expect(lstat(path.path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFSOCK)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(info.st_uid == geteuid())
        }
    }

    @Test func peerOfAnotherUserIsRefused() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let called = Mutex(0)
            let checked = Mutex<[uid_t]>([])
            let server = ControlServer(path: path, peerCheck: { uid in
                checked.withLock { $0.append(uid) }
                return false
            }) { _ in
                called.withLock { $0 += 1 }
                return .done
            }
            try server.start()
            defer { server.stop() }
            let error = await socketError {
                _ = try await ControlClient.send(ControlRequest(op: .ping, package: nil, commands: nil), to: path, timeout: .seconds(5))
            }
            // Closed without an answer.
            #expect(error == .system(ECONNRESET))
            #expect(called.withLock { $0 } == 0)
            #expect(checked.withLock { $0 } == [geteuid()])
        }
    }

    @Test func staleSocketIsReplacedLiveOneIsKept() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            // A crash's: a socket bound and never listened on again.
            let stale = try boundSocket(at: path)
            close(stale)
            #expect(isSocket(path))
            let first = ControlServer(path: path) { _ in ControlResponse(handled: true, results: [], error: nil, failedIndex: 1) }
            try first.start()
            defer { first.stop() }
            #expect(try await ControlClient.send(.ping, to: path).failedIndex == 1)

            // Another copy of the app: the live one keeps the socket, and goes on answering.
            let second = ControlServer(path: path) { _ in ControlResponse(handled: true, results: [], error: nil, failedIndex: 2) }
            #expect(throws: ControlSocketError.inUse) { try second.start() }
            second.stop()
            #expect(isSocket(path))
            #expect(try await ControlClient.send(.ping, to: path).failedIndex == 1)
        }
    }

    @Test func regularFileOrLinkAtThePathIsNeverRemoved() async throws {
        try await withShortDirectory { dir in
            let file = dir.appending(path: "file.sock")
            try Data("not a socket".utf8).write(to: file)
            let server = ControlServer(path: file) { _ in .done }
            #expect(throws: ControlSocketError.notASocket) { try server.start() }
            #expect(try Data(contentsOf: file) == Data("not a socket".utf8))

            // A link, even to a stale socket, is not followed nor removed.
            let target = dir.appending(path: "target.sock")
            close(try boundSocket(at: target))
            let link = dir.appending(path: "link.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let linked = ControlServer(path: link) { _ in .done }
            #expect(throws: ControlSocketError.notASocket) { try linked.start() }
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
            #expect(isSocket(target))

            // A folder.
            let folder = dir.appending(path: "folder.sock", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            #expect(throws: ControlSocketError.notASocket) { try ControlServer(path: folder) { _ in .done }.start() }
            #expect(FileManager.default.fileExists(atPath: folder.path))

            // No server on any of them: a client is told so, and sends nothing.
            for path in [file, link, folder] {
                let error = await socketError { _ = try await ControlClient.send(.ping, to: path) }
                #expect(error == .noServer || error == .notASocket, "\(path.lastPathComponent): \(String(describing: error))")
            }
        }
    }

    @Test func oversizedOrSlowRequestIsDropped() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let called = Mutex(0)
            let server = ControlServer(path: path, requestTimeout: .seconds(3)) { _ in
                called.withLock { $0 += 1 }
                return .done
            }
            try server.start()
            defer { server.stop() }

            // 1 MiB + 1 bytes, its `\n` included: closed unanswered.
            let big = try connected(to: path)
            defer { close(big) }
            var line = Data(repeating: 0x20, count: ControlServer.maxRequestBytes)
            line.append(0x0A)
            _ = line.withUnsafeBytes { Darwin.write(big, $0.baseAddress!, $0.count) }
            #expect(readAll(big, within: .seconds(5)).isEmpty)

            // Exactly 1 MiB with its `\n`: read (and refused as not a request, but answered).
            let fits = try connected(to: path)
            defer { close(fits) }
            var just = Data(repeating: 0x20, count: ControlServer.maxRequestBytes - 1)
            just.append(0x0A)
            _ = just.withUnsafeBytes { Darwin.write(fits, $0.baseAddress!, $0.count) }
            let answer = readAll(fits, within: .seconds(5))
            let refused = try JSONDecoder().decode(ControlResponse.self, from: answer.prefix { $0 != 0x0A })
            #expect(refused.error?.code == .invalidCommand)

            // A client that says nothing: dropped once its time is up, and the others are answered meanwhile.
            let silent = try connected(to: path)
            defer { close(silent) }
            let started = ContinuousClock.now
            for _ in 0..<3 {
                #expect(try await ControlClient.send(.ping, to: path).handled)
            }
            #expect(readAll(silent, within: .seconds(10)).isEmpty)
            #expect(ContinuousClock.now - started >= .milliseconds(2900))
            // One that sends half a line and stops, the same.
            let slow = try connected(to: path)
            defer { close(slow) }
            _ = Array(#"{"op":"pi"#.utf8).withUnsafeBytes { Darwin.write(slow, $0.baseAddress!, $0.count) }
            #expect(readAll(slow, within: .seconds(10)).isEmpty)
            #expect(called.withLock { $0 } == 3)
        }
    }

    /// A client that says nothing never holds up the others: they are answered while it still waits (with a time long
    /// enough that a loaded Mac never reaches it first).
    @Test func othersAreAnsweredWhileOneSaysNothing() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let server = ControlServer(path: path, requestTimeout: .seconds(60)) { _ in .done }
            try server.start()
            defer { server.stop() }
            let silent = try connected(to: path)
            defer { close(silent) }
            for _ in 0..<3 {
                #expect(try await ControlClient.send(.ping, to: path, timeout: .seconds(30)).handled)
            }
            #expect(isOpen(silent), "the silent client was dropped before the others were answered")
        }
    }

    @Test func pathTooLongIsAnError() async throws {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: ControlServer.maxPathBytes - 4))
        #expect(long.path.utf8.count == ControlServer.maxPathBytes + 1)
        #expect(throws: ControlSocketError.pathTooLong) { try ControlServer(path: long) { _ in .done }.start() }
        #expect(await socketError { _ = try await ControlClient.send(.ping, to: long) } == .pathTooLong)
        #expect(!FileManager.default.fileExists(atPath: long.path))
    }

    @Test func stopRemovesOnlyItsOwnSocket() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let server = ControlServer(path: path) { _ in .done }
            try server.start()
            server.stop()
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(await socketError { _ = try await ControlClient.send(.ping, to: path) } == .noServer)

            // Its socket was replaced (by hand, as another copy of the app after a crash would): left as it is.
            let again = ControlServer(path: path) { _ in .done }
            try again.start()
            unlink(path.path)
            let other = try boundSocket(at: path)
            defer { close(other) }
            again.stop()
            #expect(isSocket(path))
            // Stopping twice does nothing.
            again.stop()
        }
    }

    @Test func concurrentClientsEachGetTheirAnswer() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            let server = ControlServer(path: path) { request in
                // Out of order on purpose.
                let n = request.commands?.count ?? 0
                try? await Task.sleep(for: .milliseconds(10 * (20 - n)))
                return ControlResponse(handled: true, results: [], error: nil, failedIndex: n)
            }
            try server.start()
            defer { server.stop() }
            let answers = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
                for n in 1...20 {
                    group.addTask {
                        let commands = Array(repeating: ProjectCommand.removeMusic, count: n)
                        let response = try await ControlClient.send(
                            ControlRequest(op: .apply, package: "/p.toma", commands: commands), to: path, timeout: .seconds(10))
                        return (n, response.failedIndex)
                    }
                }
                var all: [Int: Int?] = [:]
                for try await (n, index) in group { all[n] = index }
                return all
            }
            #expect(answers.count == 20)
            for (n, index) in answers { #expect(index == n) }
        }
    }

    /// Review M1: one server per path by the lock next to it (`control.lock`), never by probing the socket. A server
    /// whose socket went away (or is too busy to accept) still has the path: another one is `inUse` and removes nothing;
    /// once it stops, the lock file stays and the next one starts.
    @Test func theLockNotAProbeSaysWhoServes() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock"), lock = dir.appending(path: "control.lock")
            let first = ControlServer(path: path) { _ in .done }
            try first.start()
            #expect(FileManager.default.fileExists(atPath: lock.path))
            // Its socket gone: a probe would say nobody serves, but the lock says it does.
            unlink(path.path)
            let second = ControlServer(path: path) { _ in .done }
            #expect(throws: ControlSocketError.inUse) { try second.start() }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            // A client is told that a server is there but does not take it: after its time, not at once.
            let started = ContinuousClock.now
            #expect(await socketError { _ = try await ControlClient.send(.ping, to: path, timeout: .milliseconds(300)) } == .timedOut)
            #expect(ContinuousClock.now - started >= .milliseconds(250))
            first.stop()
            #expect(FileManager.default.fileExists(atPath: lock.path))
            #expect(await socketError { _ = try await ControlClient.send(.ping, to: path) } == .noServer)
            try second.start()
            defer { second.stop() }
            #expect(try await ControlClient.send(.ping, to: path).handled)
        }
    }

    /// A crash leaves the socket and the lock file, unlocked (the kernel let go of it): the next server takes both.
    @Test func aCrashsSocketAndLockAreTakenOver() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock")
            close(try boundSocket(at: path))
            FileManager.default.createFile(atPath: dir.appending(path: "control.lock").path, contents: nil)
            let server = ControlServer(path: path) { _ in .done }
            try server.start()
            defer { server.stop() }
            #expect(try await ControlClient.send(.ping, to: path).handled)
        }
    }

    /// A lock file that is a link, or a folder, is not this server's: nothing is followed nor removed.
    @Test func aLockThatIsALinkIsNotTaken() async throws {
        try await withShortDirectory { dir in
            let path = dir.appending(path: "control.sock"), target = dir.appending(path: "elsewhere")
            try Data("x".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: dir.appending(path: "control.lock"), withDestinationURL: target)
            #expect(throws: ControlSocketError.notASocket) { try ControlServer(path: path) { _ in .done }.start() }
            #expect(try Data(contentsOf: target) == Data("x".utf8))
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test func packageIDFollowsTheFolderNotThePath() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await APIFixtures.package(in: dir).package.url
            let id = try ControlHandling.packageID(url.path)
            // Another path to it: a link to the folder above.
            let above = dir.appending(path: "Above")
            try FileManager.default.createSymbolicLink(at: above, withDestinationURL: dir)
            #expect(try ControlHandling.packageID(above.appending(path: url.lastPathComponent).path) == id)
            #expect(ControlPackageID(url: url) == id)
            // Renamed: still itself.
            let renamed = dir.appending(path: "Renamed.toma")
            try FileManager.default.moveItem(at: url, to: renamed)
            #expect(try ControlHandling.packageID(renamed.path) == id)
            // What is not a package, or not by an absolute path without `..`, a link to it included.
            let link = dir.appending(path: "Link.toma")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: renamed)
            for path in [nil, "Renamed.toma", dir.path + "/Above/../Renamed.toma", link.path, dir.path] as [String?] {
                #expect(throws: APIError.self) { try ControlHandling.packageID(path) }
            }
        }
    }
}

// MARK: - Helpers

extension ControlSocketTests {
    static let result = CommandResult(
        command: "addMarker", changed: true, label: "marker.add", created: "m-00000001", duration: 10, undo: "marker.add", via: .app)
}

extension ControlRequest {
    static let ping = ControlRequest(op: .ping, package: nil, commands: nil)
}

extension ControlClient {
    static func send(_ request: ControlRequest, to path: URL) async throws(ControlSocketError) -> ControlResponse {
        try await send(request, to: path, timeout: .seconds(5))
    }
}

/// A fresh folder of a short path (`/tmp/toma-…`), removed when `body` returns: a socket's path has to fit 103 bytes.
nonisolated(nonsending) func withShortDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    var template = Array("/tmp/toma-XXXXXX".utf8CString)
    guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let url = URL(fileURLWithPath: String(cString: made), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

/// The `ControlSocketError` `body` throws, if it throws one.
nonisolated(nonsending) func socketError(_ body: () async throws -> Void) async -> ControlSocketError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? ControlSocketError
    }
}

/// A socket bound at `path` that never listens: what a crash leaves.
private func boundSocket(at path: URL) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = ControlWire.address(path.path) else { throw POSIXError(.EINVAL) }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return fd
}

/// A connection to the server at `path`.
private func connected(to path: URL) throws -> Int32 {
    let fd = try ControlWire.socket()
    guard let address = ControlWire.address(path.path), ControlWire.connect(fd, to: address) == nil else {
        close(fd)
        throw POSIXError(.ECONNREFUSED)
    }
    return fd
}

/// What `fd` gives until its peer closes it (or `limit` passes): nothing for a connection closed unanswered.
private func readAll(_ fd: Int32, within limit: Duration) -> Data {
    var data = Data()
    let deadline = ContinuousClock.now + limit
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while ContinuousClock.now < deadline {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 100) >= 0 else { break }
        if poller.revents == 0 { continue }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
    }
    return data
}

/// Whether the peer of `fd` has not closed it yet.
private func isOpen(_ fd: Int32) -> Bool {
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&poller, 1, 0) == 0
}

private func isSocket(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
}
