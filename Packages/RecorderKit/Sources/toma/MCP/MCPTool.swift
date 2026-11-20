// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat

/// A tool of `toma mcp` (fases 4 y 5 design §6.3): its name, what it does for an agent to read, the JSON Schema of its
/// arguments, and the call. `MCPToolCatalog.all` lists them. A call throws an `APIError` for what it refuses (the server
/// answers it as a result with `isError: true` and the error's code), or returns one (`MCPToolResult.error`) with
/// more than the error in it.
public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// An object schema (`"type": "object"`).
    var inputSchema: JSONValue { get }
    /// MCP's `annotations` of the tool (`title`, `readOnlyHint`, `destructiveHint`…); `nil` for none.
    var annotations: JSONValue? { get }
    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult
}

extension MCPTool {
    public var annotations: JSONValue? { nil }
}

/// What a tool's call has to hand: the API's folders, the server's working directory (for a relative path), the
/// progress of the call (only when the client asked for it with a `progressToken`), the rules of the paths, and the
/// lock that makes the calls on one package go one at a time.
public struct MCPContext: Sendable {
    public let environment: APIEnvironment
    public let workingDirectory: URL
    /// `nil` if the client sent no `progressToken`. The server sends a `notifications/progress` only when the whole
    /// percent rises, and none once the call has answered.
    public let progress: (@Sendable (_ fraction: Double, _ message: String?) -> Void)?
    let locks: PackageLocks
    /// The place the server kept for this call in the line of the package its `project` argument names, when the call
    /// came; `nil` without one.
    let reservation: PackageLocks.Reservation?
    /// The exports running in the background (`export_video` with `background: true`), the server's.
    let jobs: ExportJobs

    public init(
        environment: APIEnvironment, workingDirectory: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String?) -> Void)?
    ) {
        self.init(
            environment: environment, workingDirectory: workingDirectory, progress: progress, locks: PackageLocks(),
            reservation: nil, jobs: ExportJobs())
    }

    init(
        environment: APIEnvironment, workingDirectory: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String?) -> Void)?, locks: PackageLocks,
        reservation: PackageLocks.Reservation?, jobs: ExportJobs
    ) {
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.progress = progress
        self.locks = locks
        self.reservation = reservation
        self.jobs = jobs
    }

    /// The package at `path` (`ProjectPaths.package`): `notAProject` for a path with `..`, a link, or what is not a
    /// `.toma` folder with its `manifest.json`.
    public func packageURL(_ path: String) throws -> URL {
        try ProjectPaths.package(path, relativeTo: workingDirectory)
    }

    /// Where an export goes (`ProjectPaths.output`): `refused` for a path with `..` or one inside a package.
    public func outputURL(_ path: String) throws -> URL {
        try ProjectPaths.output(path, relativeTo: workingDirectory)
    }

    /// `body`, once no other call of this server is working on the package at `url` (plan 4b decision 15): the calls on
    /// one package go one at a time, so two edits never meet at `edit.lock`, and in the order they came (the server
    /// keeps each call's place when it reads it), so an export asked for after an edit exports the edit. The package is
    /// known by its folder (device and inode), whatever path names it. A call cancelled while it waits never runs.
    ///
    /// The rules of a tool: the package is the one its `project` argument names (the server keeps that line's place
    /// for the call until the call ends); `serialized` is never called inside another `serialized` (it would wait for
    /// itself); and what takes long goes inside `body`.
    public func serialized<T: Sendable>(_ url: URL, _ body: @Sendable () async throws -> T) async throws -> T {
        try await locks.holding(place(for: url), body)
    }

    /// This call's ticket in the line of the package at `url`: the one the server kept for it, or a new one, last.
    /// Every ticket taken is released (`PackageLocks.holding` does it).
    func place(for url: URL) -> PackageLocks.Ticket {
        let key = PackageKey(url)
        return reservation?.take(for: key) ?? locks.reserve(key)
    }
}

/// What a tool's call gives: its result as a JSON object (`structuredContent`, and the same JSON as the text of
/// `content`), and whether it is an error.
public struct MCPToolResult: Sendable {
    public var structured: JSONValue
    public var isError: Bool

    public init(structured: JSONValue, isError: Bool) {
        self.structured = structured
        self.isError = isError
    }

    /// `value` as `ProjectJSON` encodes it; a value that is not an object goes in one, as `{"result": …}`
    /// (`structuredContent` is always an object).
    public static func json(_ value: some Encodable) throws -> MCPToolResult {
        let json = try JSONValue(encoding: value)
        if case .object = json { return MCPToolResult(structured: json, isError: false) }
        return MCPToolResult(structured: .object(["result": json]), isError: false)
    }

    /// `{"error": {"code", "message"}}` with `isError`.
    public static func error(_ error: APIError) -> MCPToolResult {
        MCPToolResult(structured: .object(["error": errorJSON(error)]), isError: true)
    }

    /// `{"code", "message"}`.
    static func errorJSON(_ error: APIError) -> JSONValue {
        .object(["code": .string(error.code.rawValue), "message": .string(error.message)])
    }
}

/// The arguments of a call, read strictly (as the commands are, plan 4b decision 3): one the tool does not take, one
/// that is missing or one of another type is `invalidCommand`, naming it.
struct MCPArguments {
    let tool: String
    private let members: [String: JSONValue]

    /// `arguments` (an object, or `null` for none) of `tool`, which takes `keys`.
    init(_ arguments: JSONValue, tool: String, keys: Set<String>) throws(APIError) {
        self.tool = tool
        switch arguments {
        case .null: members = [:]
        case let .object(object): members = object.filter { $0.value != .null }
        default: throw APIError(.invalidCommand, "\(tool): the arguments are an object")
        }
        if let unknown = members.keys.sorted().first(where: { !keys.contains($0) }) {
            let known = keys.sorted().map { "“\($0)”" }.joined(separator: ", ")
            throw APIError(
                .invalidCommand, "\(tool) has no argument “\(unknown)”; it takes \(known.isEmpty ? "none" : known)")
        }
    }

    func value(_ key: String) -> JSONValue? { members[key] }

    func string(_ key: String) throws(APIError) -> String {
        guard let value = try optionalString(key) else {
            throw APIError(.invalidCommand, "\(tool) needs the argument “\(key)”")
        }
        return value
    }

    func optionalString(_ key: String) throws(APIError) -> String? {
        guard let value = members[key] else { return nil }
        guard case let .string(string) = value else { throw wrong(key, "a string") }
        return string
    }

    /// An integer, also written `1080.0`.
    func optionalInt(_ key: String) throws(APIError) -> Int? {
        guard let value = members[key] else { return nil }
        let integer: Int? =
            switch value {
            case let .integer(value): Int(exactly: value)
            case let .unsigned(value): Int(exactly: value)
            case let .number(value): Int(exactly: value)
            default: nil
            }
        guard let integer else { throw wrong(key, "an integer") }
        return integer
    }

    /// A finite number, an integer or not.
    func optionalNumber(_ key: String) throws(APIError) -> Double? {
        guard let value = members[key] else { return nil }
        let number: Double? =
            switch value {
            case let .integer(value): Double(value)
            case let .unsigned(value): Double(value)
            case let .number(value): value
            default: nil
            }
        guard let number, number.isFinite else { throw wrong(key, "a number") }
        return number
    }

    func optionalBool(_ key: String) throws(APIError) -> Bool? {
        guard let value = members[key] else { return nil }
        guard case let .bool(bool) = value else { throw wrong(key, "true or false") }
        return bool
    }

    private func wrong(_ key: String, _ kind: String) -> APIError {
        APIError(.invalidCommand, "\(tool): the argument “\(key)” is \(kind)")
    }
}

/// The pieces of the tools' input schemas (JSON Schema, as `CommandSchema` writes the commands').
enum MCPSchema {
    /// An object with `properties`, `required` of them.
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    static func string(_ description: String, choices: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let choices { schema["enum"] = .array(choices.map(JSONValue.string)) }
        return .object(schema)
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func number(_ description: String, minimum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let minimum { schema["minimum"] = .number(minimum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    /// The `project` argument every tool on a project takes.
    static let project = string(
        "The .toma package: an absolute path (~ is the home folder), or one from the server's working directory. "
            + "A link or a path with “..” is refused.")

    /// MCP's annotations: a title, whether the tool only reads, whether it can replace what is there, and that it never
    /// reaches outside this Mac.
    static func annotations(_ title: String, readOnly: Bool, destructive: Bool = false) -> JSONValue {
        var hints: [String: JSONValue] = [
            "title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false),
        ]
        if !readOnly { hints["destructiveHint"] = .bool(destructive) }
        return .object(hints)
    }
}
