// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Synchronization

/// `toma mcp`: Toma's tools for an agent, as an MCP server on standard input and output (fases 4 y 5 design §6.3,
/// `MCPServer`). Standard output carries only JSON-RPC messages, one a line: the process keeps the real standard output
/// for them and points its file descriptor 1 at standard error, so nothing else (a library's `print`) can reach the
/// client. It ends when standard input ends (exit code 0), or on SIGINT or SIGTERM, after cancelling the calls still
/// running; a client gone (SIGPIPE) never ends it with a signal.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Toma's tools to an agent over MCP, on standard input and output.",
        discussion: """
            Speaks the Model Context Protocol (version 2025-06-18) as JSON-RPC 2.0, one message per line: standard \
            output carries only those messages; anything else goes to standard error. It ends when standard input \
            ends. Connect it to Claude Code with: claude mcp add toma -- toma mcp. docs/automation.md tells more.
            """)

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)
        let output = ProtocolOutput.takingStandardOutput()
        let server = MCPServer(
            tools: MCPToolCatalog.all, environment: CLI.environment, workingDirectory: CLI.workingDirectory,
            write: { output.write($0) })
        let stopping = StopSignals {
            Task {
                await server.stop()
                Darwin.exit(0)
            }
        }
        await server.run(input: .standardInput)
        stopping.stop()
    }
}

/// Where the protocol's lines go: the process's standard output as it was at the start, written whole, one line at a
/// time. A write to a client that is gone fails quietly (SIGPIPE is ignored).
final class ProtocolOutput: Sendable {
    private let handle: FileHandle
    private let lock = Mutex(())

    private init(handle: FileHandle) {
        self.handle = handle
    }

    /// A copy of standard output for the protocol, with file descriptor 1 then pointed at standard error.
    static func takingStandardOutput() -> ProtocolOutput {
        let copy = dup(STDOUT_FILENO)
        guard copy >= 0 else { return ProtocolOutput(handle: .standardOutput) }
        _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
        if dup2(STDERR_FILENO, STDOUT_FILENO) < 0 {
            close(copy)
            return ProtocolOutput(handle: .standardOutput)
        }
        return ProtocolOutput(handle: FileHandle(fileDescriptor: copy, closeOnDealloc: true))
    }

    func write(_ line: Data) {
        lock.withLock { _ in
            try? handle.write(contentsOf: line)
        }
    }
}

/// SIGINT and SIGTERM call `stop` instead of ending the process, while it lives.
private final class StopSignals: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ stop: @escaping @Sendable () -> Void) {
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: stop)
            source.resume()
            return source
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
