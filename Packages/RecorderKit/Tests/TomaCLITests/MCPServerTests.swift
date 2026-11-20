// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import toma

/// The protocol of `toma mcp` (plan 4b, Task A5, decision 15), with an `MCPServer` in this process whose lines are kept:
/// JSON-RPC 2.0 one message a line, the answers MCP `2025-06-18` asks for, and the errors of the protocol.
@Suite struct MCPServerTests {
    @Test func initializeAnswersTheProtocolVersion() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            let answer = try await mcp.request("initialize", id: .integer(1), params: Self.initialize("2025-06-18"))
            let result = try #require(answer["result"])
            #expect(result["protocolVersion"] == .string("2025-06-18"))
            #expect(result["serverInfo"]?["name"] == .string("toma"))
            #expect(result["serverInfo"]?["version"] == .string("1.0"))
            #expect(result["capabilities"]?["tools"]?.objectValue != nil)
            #expect(answer["jsonrpc"] == .string("2.0"))
        }
    }

    @Test func anotherClientVersionStillGets2025_06_18() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            for (k, version) in ["2024-11-05", "2025-03-26", "2099-01-01"].enumerated() {
                let answer = try await mcp.request("initialize", id: .integer(Int64(k)), params: Self.initialize(version))
                #expect(answer["result"]?["protocolVersion"] == .string("2025-06-18"))
            }
        }
    }

    @Test func initializedNotificationGetsNoAnswer() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            await mcp.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            // Nor any other notification, known or not, nor a cancellation of a call that is not running.
            await mcp.send(#"{"jsonrpc":"2.0","method":"notifications/whatever","params":{"a":1}}"#)
            await mcp.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#)
            // Nor a response, which the server never asked for.
            await mcp.send(#"{"jsonrpc":"2.0","id":5,"result":{}}"#)
            _ = try await mcp.request("ping", id: .integer(2))
            #expect(mcp.messages.count == 1)
            #expect(mcp.messages.first?["id"] == .integer(2))
        }
    }

    @Test func pingAnswersEmpty() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            // Before initialize too.
            let answer = try await mcp.request("ping", id: .integer(1))
            #expect(answer["result"] == .object([:]))
            #expect(answer["error"] == nil)
        }
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            let answer = try await mcp.request("resources/list", id: .integer(3))
            #expect(answer["error"]?["code"] == .integer(-32601))
            #expect(answer["id"] == .integer(3))
            #expect(answer["result"] == nil)
        }
    }

    @Test func unknownToolIsInvalidParams() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            let answer = try await mcp.request(
                "tools/call", id: .integer(4), params: .object(["name": .string("make_coffee"), "arguments": .object([:])]))
            #expect(answer["error"]?["code"] == .integer(-32602))
            #expect(answer["error"]?["message"]?.stringValue?.contains("make_coffee") == true)
            // Without a name, or with arguments that are not an object.
            let noName = try await mcp.request("tools/call", id: .integer(5), params: .object([:]))
            #expect(noName["error"]?["code"] == .integer(-32602))
            let notAnObject = try await mcp.request(
                "tools/call", id: .integer(6), params: .object(["name": .string("project_info"), "arguments": .array([])]))
            #expect(notAnObject["error"]?["code"] == .integer(-32602))
        }
    }

    @Test func parseErrorHasNullID() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            await mcp.send(#"{"jsonrpc":"2.0","id":1,"method":"ping""#)
            let answer = try #require(mcp.messages.last)
            #expect(answer["error"]?["code"] == .integer(-32700))
            #expect(answer["id"] == .null)
            #expect(answer.objectValue?.keys.contains("id") == true)
        }
    }

    @Test func batchArrayIsInvalidRequest() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            await mcp.send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
            #expect(mcp.messages.count == 1)
            #expect(mcp.messages.last?["error"]?["code"] == .integer(-32600))
            #expect(mcp.messages.last?["id"] == .null)
            // Not an object, an id that is neither a string nor a number, no jsonrpc 2.0.
            await mcp.send("42")
            await mcp.send(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#)
            await mcp.send(#"{"jsonrpc":"1.0","id":3,"method":"ping"}"#)
            #expect(mcp.messages.count == 4)
            #expect(mcp.messages.dropFirst().allSatisfy { $0["error"]?["code"] == .integer(-32600) })
            #expect(mcp.messages.last?["id"] == .integer(3))
        }
    }

    @Test func idIsEchoedAsGiven() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            _ = try await mcp.request("ping", id: .string("abc-1"))
            _ = try await mcp.request("ping", id: .integer(7))
            _ = try await mcp.request("ping", id: .string("7"))
            // A line separator inside a string is no end of a line.
            _ = try await mcp.request("ping", id: .string("a\u{2028}b"))
            let lines = mcp.texts
            #expect(lines[0].contains(#""id":"abc-1""#))
            #expect(lines[1].contains(#""id":7,"#))
            #expect(lines[2].contains(#""id":"7""#))
            #expect(mcp.messages[3]["id"] == .string("a\u{2028}b"))
            // An error answers the id too.
            _ = try await mcp.request("nope", id: .string("x"))
            #expect(mcp.messages.last?["id"] == .string("x"))
        }
    }

    @Test func everyLineIsOneMessageWithoutNewlines() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            _ = try await mcp.request("initialize", id: .integer(1), params: Self.initialize("2025-06-18"))
            _ = try await mcp.request("tools/list", id: .integer(2))
            _ = try await mcp.call("project_info", ["project": .string(url.path)], id: 3)
            // An error whose message has line breaks in it, from the path.
            _ = try await mcp.call("project_info", ["project": .string("two\nlines\r.toma")], id: 4)
            await mcp.send("not json\u{2028}at all")
            #expect(mcp.lines.count == 5)
            for line in mcp.lines {
                #expect(line.last == 0x0A)
                #expect(line.dropLast().allSatisfy { $0 != 0x0A && $0 != 0x0D })
                let message = try #require(JSONRPC.parse(String(decoding: line, as: UTF8.self)))
                #expect(message["jsonrpc"] == .string("2.0"))
            }
            #expect(mcp.messages[3]["result"]?["structuredContent"]?["error"]?["message"]?.stringValue?.contains("two\nlines") == true)
        }
    }

    @Test func runReadsLinesUntilTheEnd() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            let pipe = Pipe()
            let reading = Task { await mcp.server.run(input: pipe.fileHandleForReading) }
            // A `\r\n` line, an empty one, and a last one without its `\n`.
            let text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n"
                + "{\"jsonrpc\":\"2.0\",\"id\":\"last\",\"method\":\"ping\"}"
            try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            await reading.value
            #expect(mcp.messages.map { $0["id"] } == [.integer(1), .integer(2), .string("last")])
            #expect(mcp.messages.allSatisfy { $0["result"] == .object([:]) })
        }
    }

    static func initialize(_ version: String) -> JSONValue {
        .object([
            "protocolVersion": .string(version), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")]),
        ])
    }
}

/// An `MCPServer` in this process with `toma`'s tools and the folders of a temporary directory (`CLIFixtures`), whose
/// lines are kept.
final class MCPHarness: Sendable {
    let server: MCPServer
    private let sink: LineSink

    init(in dir: URL, tools: [any MCPTool] = MCPToolCatalog.all) {
        let sink = LineSink()
        self.sink = sink
        server = MCPServer(
            tools: tools, environment: CLIFixtures.environment(in: dir), workingDirectory: dir, write: { sink.append($0) })
    }

    /// Every line written, as written.
    var lines: [Data] { sink.chunks }
    var texts: [String] { lines.map { String(decoding: $0, as: UTF8.self) } }
    var messages: [JSONValue] { texts.compactMap { JSONRPC.parse($0) } }

    /// The `notifications/progress` of `token`, with where each is in `messages`.
    func progress(_ token: JSONValue) -> [(index: Int, params: JSONValue)] {
        messages.enumerated().compactMap { index, message in
            guard message["method"] == .string("notifications/progress"), let params = message["params"],
                params["progressToken"] == token
            else { return nil }
            return (index, params)
        }
    }

    func send(_ line: String) async {
        await server.receive(line)
    }

    func send(_ message: JSONValue) async {
        await server.receive(JSONRPC.text(message))
    }

    /// Sends the request and waits for its answer.
    func request(_ method: String, id: JSONValue, params: JSONValue? = nil) async throws -> JSONValue {
        await send(Self.request(method, id: id, params: params))
        return try await answer(to: id)
    }

    /// Calls the tool and gives the `CallToolResult`.
    func call(_ tool: String, _ arguments: [String: JSONValue], id: Int64, progressToken: JSONValue? = nil) async throws -> JSONValue {
        await send(Self.call(tool, arguments, id: id, progressToken: progressToken))
        let answer = try await answer(to: .integer(id))
        return try #require(answer["result"], "\(answer)")
    }

    /// The answer to the request `id`, once it is written.
    func answer(to id: JSONValue, timeout: Duration = .seconds(300)) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = messages.first(where: { $0.isAnswer(to: id) }) { return answer }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestSupportError.missing("an answer to \(id)")
    }

    static func request(_ method: String, id: JSONValue, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id, "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func call(_ tool: String, _ arguments: [String: JSONValue], id: Int64, progressToken: JSONValue? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(tool), "arguments": .object(arguments)]
        if let progressToken { params["_meta"] = .object(["progressToken": progressToken]) }
        return request("tools/call", id: .integer(id), params: .object(params))
    }
}

/// What a `write` was given, in order.
final class LineSink: Sendable {
    private let state = Mutex<[Data]>([])

    func append(_ data: Data) {
        state.withLock { $0.append(data) }
    }

    var chunks: [Data] { state.withLock { $0 } }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? { member(key) }

    var arrayValue: [JSONValue]? {
        if case let .array(elements) = self { elements } else { nil }
    }

    var numberValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .unsigned(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }

    /// Whether this is the answer (a result or an error) to the request `id`.
    func isAnswer(to id: JSONValue) -> Bool {
        self["id"] == id && (self["result"] != nil || self["error"] != nil)
    }
}
