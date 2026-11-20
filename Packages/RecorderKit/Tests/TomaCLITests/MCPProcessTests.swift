// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import toma

/// `toma mcp`, the binary that is built, talked to over its standard input and output as a client does (plan 4b, Task
/// A5): its standard output carries JSON-RPC alone, it ends with its input, and a client gone or a signal never kills it
/// with a file left half written. Every `TOMA_*` variable is a temporary folder.
@Suite struct MCPProcessTests {
    @Test func stdoutCarriesOnlyJSONRPCLines() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let folder = dir.appending(path: "Folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            try server.send(MCPHarness.request("initialize", id: .integer(1), params: MCPServerTests.initialize("2025-06-18")))
            _ = try await server.answer(to: .integer(1))
            try server.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
            try server.send(MCPHarness.request("tools/list", id: .integer(2)))
            try server.send(MCPHarness.call("project_info", ["project": .string(folder.path)], id: 3))
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("movie"), "size": .integer(720)], id: 4,
                progressToken: .string("p")))
            // A ping while the export runs is answered at once.
            while !server.messages.contains(where: { $0["method"] == .string("notifications/progress") }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try server.send(MCPHarness.request("ping", id: .integer(5)))
            for id in Int64(2)...5 { _ = try await server.answer(to: .integer(id)) }
            let ping = server.messages.firstIndex { $0.isAnswer(to: .integer(5)) }
            let export = server.messages.firstIndex { $0.isAnswer(to: .integer(4)) }
            #expect(ping! < export!)
            try server.closeInput()
            let exit = try await server.exit()
            #expect(exit.reason == .exit && exit.status == 0, "\(server.standardError)")

            let output = server.output
            #expect(output.last == 0x0A)
            let lines = output.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
            #expect(!lines.isEmpty)
            var answers: [JSONValue] = [], notifications: [JSONValue] = []
            for line in lines {
                let message = try #require(JSONRPC.parse(String(decoding: line, as: UTF8.self)), "\(String(decoding: line, as: UTF8.self))")
                #expect(message["jsonrpc"] == .string("2.0"))
                if message["id"] != nil {
                    #expect((message["result"] == nil) != (message["error"] == nil))
                    #expect(message["method"] == nil)
                    answers.append(message)
                } else {
                    #expect(message["method"] == .string("notifications/progress"))
                    notifications.append(message)
                }
            }
            #expect(answers.compactMap { $0["id"] } == [.integer(1), .integer(2), .integer(3), .integer(5), .integer(4)])
            #expect(answers[2]["result"]?["isError"] == .bool(true))
            #expect(answers[4]["result"]?["isError"] == .bool(false), "\(answers[4])")
            #expect(!notifications.isEmpty)
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "movie.mp4").path))
        }
    }

    @Test func eofEndsTheServer() async throws {
        try await withTemporaryDirectory { dir in
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            try server.send(MCPHarness.request("ping", id: .integer(1)))
            #expect(try await server.answer(to: .integer(1))["result"] == .object([:]))
            try server.closeInput()
            let exit = try await server.exit()
            #expect(exit.reason == .exit)
            #expect(exit.status == 0)
        }
    }

    @Test func eofAnswersTheCallsInFlight() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await MCPToolsTests.transcribed(in: dir)
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            // As `printf '…' | toma mcp` does: everything, then the end of the input at once.
            try server.send(MCPHarness.call("list_projects", ["folder": .string(".")], id: 1))
            try server.send(MCPHarness.call("get_transcript", ["project": .string("Fixture.toma")], id: 2))
            try server.send(MCPHarness.call("project_info", ["project": .string("Nope.toma")], id: 3))
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("piped.gif"), "gif": .bool(true),
                                 "size": .integer(480)], id: 4))
            try server.send(MCPHarness.request("ping", id: .integer(5)))
            try server.closeInput()
            let exit = try await server.exit(timeout: .seconds(300))
            #expect(exit.reason == .exit && exit.status == 0, "\(server.standardError)")
            for id in Int64(1)...5 { #expect(server.messages.contains { $0.isAnswer(to: .integer(id)) }, "\(id)") }
            let projects = server.messages.first { $0.isAnswer(to: .integer(1)) }?["result"]?["structuredContent"]?["projects"]
            #expect(projects?.arrayValue?.count == 1)
            let transcript = server.messages.first { $0.isAnswer(to: .integer(2)) }?["result"]?["structuredContent"]
            #expect(transcript?["segments"]?.arrayValue?.isEmpty == false, "\(String(describing: transcript))")
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "piped.gif").path))
        }
    }

    @Test func aBackgroundExportOverTheProcess() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("bg.mp4"), "size": .integer(720),
                                 "background": .bool(true)], id: 1))
            let started = try await server.answer(to: .integer(1))
            let id = try #require(started["result"]?["structuredContent"]?["jobId"]?.stringValue)
            var status = JSONValue.string("running")
            var k: Int64 = 2
            let deadline = ContinuousClock.now + .seconds(300)
            while status == .string("running"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                try server.send(MCPHarness.call("export_status", ["jobId": .string(id)], id: k))
                status = try await server.answer(to: .integer(k))["result"]?["structuredContent"]?["status"] ?? .null
                k += 1
            }
            #expect(status == .string("done"))
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "bg.mp4").path))
            // The end of the input waits for an export in the background too.
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("last.gif"), "gif": .bool(true),
                                 "size": .integer(480), "background": .bool(true)], id: 1000))
            _ = try await server.answer(to: .integer(1000))
            try server.closeInput()
            let exit = try await server.exit(timeout: .seconds(300))
            #expect(exit.reason == .exit && exit.status == 0, "\(server.standardError)")
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "last.gif").path))
        }
    }

    @Test func sigpipeDoesNotCrash() async throws {
        try await withTemporaryDirectory { dir in
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            try server.send(MCPHarness.request("ping", id: .integer(1)))
            _ = try await server.answer(to: .integer(1))
            // The client stops reading: the answers go nowhere.
            server.closeOutput()
            try server.send(MCPHarness.request("ping", id: .integer(2)))
            try server.send(MCPHarness.request("tools/list", id: .integer(3)))
            try await Task.sleep(for: .milliseconds(200))
            try server.closeInput()
            let exit = try await server.exit()
            #expect(exit.reason == .exit, "\(server.standardError)")
            #expect(exit.status == 0)
        }
    }

    @Test func sigtermCancelsTheExportAndExits() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let server = try MCPProcess(in: dir)
            defer { server.kill() }
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("stopped.mp4"), "size": .integer(2160)], id: 1,
                progressToken: .integer(1)))
            // And one in the background.
            try server.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("stopped-too.mp4"), "size": .integer(2160),
                                 "background": .bool(true)], id: 2))
            let deadline = ContinuousClock.now + .seconds(120)
            while !server.messages.contains(where: { ($0["params"]?["progress"]?.numberValue ?? 0) >= 0.25 }),
                !server.messages.contains(where: { $0.isAnswer(to: .integer(1)) }), ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            server.signal(SIGTERM)
            // Promptly: the exports are cancelled, not waited for.
            let exit = try await server.exit(timeout: .seconds(20))
            #expect(exit.reason == .exit && exit.status == 0, "\(server.standardError)")
            #expect(!server.messages.contains { $0.isAnswer(to: .integer(1)) })
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("stopped") }
            #expect(left.isEmpty, "\(left)")
        }
    }
}

/// `toma mcp` running, with pipes for its standard input and output (its standard error goes to a file). What it writes
/// is kept as it comes.
final class MCPProcess: Sendable {
    private let process: Process
    private let input = Pipe()
    private let pipe = Pipe()
    private let received = Mutex(Data())
    private let ended = Mutex<(status: Int32, reason: Process.TerminationReason)?>(nil)
    private let errors: URL

    init(in dir: URL) throws {
        errors = dir.appending(path: "mcp-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = try CLIFixtures.executable
        process.arguments = ["mcp"]
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging(CLIFixtures.variables(in: dir)) { $1 }
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = try FileHandle(forWritingTo: errors)
        self.process = process
        // A write to a server gone fails instead of killing the tests.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.received.withLock { $0.append(data) }
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.ended.withLock { $0 = (process.terminationStatus, process.terminationReason) }
        }
        try process.run()
    }

    /// Everything on its standard output so far.
    var output: Data { received.withLock { $0 } }

    /// The messages of the whole lines so far.
    var messages: [JSONValue] {
        output.split(separator: 0x0A).compactMap { JSONRPC.parse(String(decoding: $0, as: UTF8.self)) }
    }

    var standardError: String { (try? String(contentsOf: errors, encoding: .utf8)) ?? "" }

    func send(_ message: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((JSONRPC.text(message) + "\n").utf8))
    }

    func closeInput() throws {
        try input.fileHandleForWriting.close()
    }

    /// Stops reading its standard output: the server's next write finds no reader.
    func closeOutput() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
    }

    func signal(_ number: Int32) {
        Darwin.kill(process.processIdentifier, number)
    }

    func answer(to id: JSONValue, timeout: Duration = .seconds(300)) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = messages.first(where: { $0.isAnswer(to: id) }) { return answer }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestSupportError.missing("an answer to \(id); standard error: \(standardError)")
    }

    /// How it ended, once it has.
    func exit(timeout: Duration = .seconds(60)) async throws -> (status: Int32, reason: Process.TerminationReason) {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let ended = ended.withLock({ $0 }) { return ended }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestSupportError.missing("the end of toma mcp")
    }

    /// Kills it if it still runs.
    func kill() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }
}
