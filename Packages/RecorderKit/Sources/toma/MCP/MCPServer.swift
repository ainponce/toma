// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import Synchronization

/// The MCP server of `toma mcp` (fases 4 y 5 design §6.3, plan 4b decision 15), written by hand: JSON-RPC 2.0, one
/// message per line. It answers `initialize` (always with protocol version `2025-06-18`, whatever the client asks), `ping`,
/// `tools/list` (every tool, no pages) and `tools/call`; it takes the notifications `notifications/initialized` and
/// `notifications/cancelled`, and answers no notification. It answers before `initialize` too.
///
/// A call runs in a task of its own, so others are answered while an export runs, but the calls on one package go one
/// at a time (`MCPContext.serialized`). A call keeps nothing open: each opens its project and closes it. A cancelled call
/// (`notifications/cancelled`, or the end of the input) gets no answer; an export cancelled leaves no file.
actor MCPServer {
    static let protocolVersion = "2025-06-18"
    /// The longest line read: a longer one is answered as an invalid request and skipped.
    static let maximumLine = 16 << 20

    private let tools: [any MCPTool]
    private let byName: [String: any MCPTool]
    private let environment: APIEnvironment
    private let workingDirectory: URL
    private let output: LineOutput
    private let locks = PackageLocks()
    private var calls: [RequestKey: Call] = [:]

    private struct Call {
        let task: Task<Void, Never>
        let progress: ProgressNotifier?
        /// Released when the call ends, whether it used it or not.
        let reservation: PackageLocks.Reservation?
        /// The client cancelled it, or the input ended: it gets no answer.
        var cancelled = false
    }

    /// `write` is given each message as one line ending in `\n`, never two at once.
    init(
        tools: [any MCPTool], environment: APIEnvironment, workingDirectory: URL, write: @escaping @Sendable (Data) -> Void
    ) {
        self.tools = tools
        byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.environment = environment
        self.workingDirectory = workingDirectory
        output = LineOutput(write)
    }

    /// Reads `input` line by line (only `\n` ends one; a `\r` before it is dropped) and answers each message, until the
    /// end of the input; then cancels the calls still running and waits for them, so an export cancelled removes its
    /// file before this returns.
    nonisolated func run(input: FileHandle) async {
        var line: [UInt8] = []
        var tooLong = false
        do {
            for try await byte in input.bytes {
                guard byte == 0x0A else {
                    if tooLong { continue }
                    if line.count == Self.maximumLine {
                        tooLong = true
                        line = []
                    } else {
                        line.append(byte)
                    }
                    continue
                }
                if tooLong {
                    tooLong = false
                    await refuseLongLine()
                } else {
                    await receive(String(decoding: line, as: UTF8.self))
                }
                line.removeAll(keepingCapacity: true)
            }
        } catch {
            FileHandle.standardError.write(Data("toma mcp: the input could not be read: \(error)\n".utf8))
        }
        if !line.isEmpty, !tooLong { await receive(String(decoding: line, as: UTF8.self)) }
        await stop()
    }

    /// Answers one message (a line without its `\n`). A call starts in its own task and is answered when it ends; the
    /// rest is answered before this returns.
    func receive(_ line: String) async {
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard !text.allSatisfy(\.isWhitespace) else { return }
        guard let message = JSONRPC.parse(text) else {
            return send(JSONRPC.error(id: .null, .parseError, "Parse error: the message is not JSON"))
        }
        guard case let .object(members) = message else {
            if case .array = message {
                return send(JSONRPC.error(
                    id: .null, .invalidRequest, "Invalid Request: batches are not supported; send one message per line"))
            }
            return send(JSONRPC.error(id: .null, .invalidRequest, "Invalid Request: a message is a JSON object"))
        }
        let id = members["id"]
        guard case let .string(method)? = members["method"] else {
            // A response, which this server never asked for, is no business of it.
            if id != nil, members["result"] != nil || members["error"] != nil { return }
            return send(JSONRPC.error(id: id.flatMap { RequestKey($0) == nil ? nil : $0 } ?? .null, .invalidRequest,
                "Invalid Request: no method"))
        }
        guard members["jsonrpc"] == .string("2.0") else {
            guard let id else { return }
            return send(JSONRPC.error(
                id: RequestKey(id) == nil ? .null : id, .invalidRequest, "Invalid Request: jsonrpc is \"2.0\""))
        }
        let params = members["params"]
        guard let id else { return notification(method, params) }
        guard let key = RequestKey(id) else {
            return send(JSONRPC.error(id: .null, .invalidRequest, "Invalid Request: an id is a string or a number"))
        }
        switch method {
        case "initialize":
            send(JSONRPC.response(id: id, result: initializeResult))
        case "ping":
            send(JSONRPC.response(id: id, result: .object([:])))
        case "tools/list":
            send(JSONRPC.response(id: id, result: .object(["tools": .array(tools.map(Self.describe))])))
        case "tools/call":
            startCall(id: id, key: key, params: params)
        default:
            send(JSONRPC.error(id: id, .methodNotFound, "Method not found: \(method)"))
        }
    }

    /// Cancels every call that runs and waits for them: none is answered.
    func stop() async {
        let running = calls
        for key in running.keys {
            calls[key]?.cancelled = true
            running[key]?.task.cancel()
        }
        for call in running.values { await call.task.value }
    }

    /// How many calls run now (for the tests).
    var runningCalls: Int { calls.count }

    // MARK: - Private

    private var initializeResult: JSONValue {
        .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string("toma"), "title": .string("Toma"), "version": .string(ProjectAPI.version),
            ]),
            "instructions": .string(
                "Toma's screen recordings are .toma packages. List them with list_projects, read one with project_info, "
                    + "get_transcript and get_markers, edit it with apply_commands (each command one undo step, as in "
                    + "the app; times in seconds of the output as it plays then), undo and redo, and export it with "
                    + "export_video. Paths are absolute or from the server's working directory; an export never goes "
                    + "inside a .toma package."),
        ])
    }

    private static func describe(_ tool: any MCPTool) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema,
        ]
        if let annotations = tool.annotations {
            object["annotations"] = annotations
            if let title = annotations.member("title") { object["title"] = title }
        }
        return .object(object)
    }

    private func notification(_ method: String, _ params: JSONValue?) {
        switch method {
        case "notifications/cancelled":
            guard let id = params?.member("requestId"), let key = RequestKey(id), calls[key] != nil else { return }
            calls[key]?.cancelled = true
            calls[key]?.task.cancel()
        default:
            // `notifications/initialized`, and any other: nothing to answer.
            break
        }
    }

    private func startCall(id: JSONValue, key: RequestKey, params: JSONValue?) {
        guard let params = params?.objectValue, let name = params["name"]?.stringValue else {
            return send(JSONRPC.error(id: id, .invalidParams, "Invalid params: tools/call takes {\"name\", \"arguments\"}"))
        }
        guard let tool = byName[name] else {
            return send(JSONRPC.error(
                id: id, .invalidParams,
                "Unknown tool: \(name). The tools are \(tools.map(\.name).joined(separator: ", "))"))
        }
        let arguments = params["arguments"] ?? .object([:])
        switch arguments {
        case .object, .null: break
        default: return send(JSONRPC.error(id: id, .invalidParams, "Invalid params: the arguments are an object"))
        }
        guard calls[key] == nil else {
            return send(JSONRPC.error(id: id, .invalidRequest, "Invalid Request: a call with this id is still running"))
        }
        var notifier: ProgressNotifier?
        if let token = params["_meta"]?.member("progressToken"), RequestKey(token) != nil {
            notifier = ProgressNotifier(token: token, output: output)
        }
        var progress: (@Sendable (Double, String?) -> Void)?
        if let notifier { progress = { fraction, message in notifier.report(fraction, message) } }
        // The call's place in the line of its package, now: the calls on a package run in the order they came.
        let reservation = arguments.member("project")?.stringValue
            .flatMap { try? ProjectPaths.package($0, relativeTo: workingDirectory) }
            .map { PackageLocks.Reservation(locks.reserve(PackageKey($0))) }
        let context = MCPContext(
            environment: environment, workingDirectory: workingDirectory, progress: progress, locks: locks,
            reservation: reservation)
        let task = Task {
            let result: MCPToolResult?
            do {
                result = try await tool.call(arguments, context: context)
            } catch _ where Task.isCancelled {
                result = nil
            } catch let error as APIError {
                result = .error(error)
            } catch is CancellationError {
                result = .error(APIError(.refused, "the call was cancelled"))
            } catch {
                result = .error(APIError(.refused, "\(name) failed: \(error)"))
            }
            // The task is the server's (isolated to it); the tool's call runs off it.
            self.finish(key, id: id, result: result)
        }
        calls[key] = Call(task: task, progress: notifier, reservation: reservation)
    }

    /// Answers the call `key` with `result`, unless it was cancelled; after this, its progress is never sent.
    private func finish(_ key: RequestKey, id: JSONValue, result: MCPToolResult?) {
        guard let call = calls.removeValue(forKey: key) else { return }
        if let reservation = call.reservation { locks.release(reservation.ticket) }
        call.progress?.close()
        guard !call.cancelled, let result else { return }
        send(JSONRPC.response(id: id, result: Self.toolResult(result)))
    }

    /// `CallToolResult`: the JSON as text in `content`, the same as `structuredContent`, and `isError`.
    private static func toolResult(_ result: MCPToolResult) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(JSONRPC.text(result.structured))])]),
            "structuredContent": result.structured,
            "isError": .bool(result.isError),
        ])
    }

    private func refuseLongLine() {
        send(JSONRPC.error(
            id: .null, .invalidRequest, "Invalid Request: a message is at most \(Self.maximumLine >> 20) MiB"))
    }

    private func send(_ line: Data) {
        output.write(line)
    }
}

/// The server's `write`, one line at a time whoever calls it.
final class LineOutput: Sendable {
    private let lock = Mutex(())
    private let write: @Sendable (Data) -> Void

    init(_ write: @escaping @Sendable (Data) -> Void) {
        self.write = write
    }

    func write(_ line: Data) {
        lock.withLock { _ in write(line) }
    }
}

/// The `notifications/progress` of one call: `progress` from 0 to 1 with `total: 1`, sent each time the whole percent
/// rises (so it always increases, as MCP asks), and never once the call has answered.
final class ProgressNotifier: Sendable {
    private let token: JSONValue
    private let output: LineOutput
    private let state = Mutex((percent: -1, open: true))

    init(token: JSONValue, output: LineOutput) {
        self.token = token
        self.output = output
    }

    func report(_ fraction: Double, _ message: String?) {
        guard fraction.isFinite else { return }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        state.withLock { state in
            guard state.open, percent > state.percent else { return }
            state.percent = percent
            var params: [String: JSONValue] = [
                "progressToken": token, "progress": .number(Double(percent) / 100), "total": .integer(1),
            ]
            if let message { params["message"] = .string(message) }
            // Inside the lock: once `close` returns, no notification is on its way.
            output.write(JSONRPC.notification("notifications/progress", params))
        }
    }

    func close() {
        state.withLock { $0.open = false }
    }
}
