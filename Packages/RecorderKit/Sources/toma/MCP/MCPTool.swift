// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectAPI
import ProjectFormat
import Synchronization

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

    public init(
        environment: APIEnvironment, workingDirectory: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String?) -> Void)?
    ) {
        self.init(
            environment: environment, workingDirectory: workingDirectory, progress: progress, locks: PackageLocks(),
            reservation: nil)
    }

    init(
        environment: APIEnvironment, workingDirectory: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String?) -> Void)?, locks: PackageLocks,
        reservation: PackageLocks.Reservation?
    ) {
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.progress = progress
        self.locks = locks
        self.reservation = reservation
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
    public func serialized<T: Sendable>(_ url: URL, _ body: @Sendable () async throws -> T) async throws -> T {
        let key = PackageKey(url)
        let ticket = reservation?.take(for: key) ?? locks.reserve(key)
        do {
            try await locks.wait(ticket)
            try Task.checkCancellation()
            let value = try await body()
            locks.release(ticket)
            return value
        } catch {
            locks.release(ticket)
            throw error
        }
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

/// A package by its folder's device and inode (the identity plan 4b decision 19 gives the control socket's), so two
/// paths to one package are one; by its path if its folder cannot be read.
struct PackageKey: Hashable, Sendable {
    private let device: Int64
    private let inode: UInt64
    private let path: String

    init(_ url: URL) {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            path = ""
        } else {
            device = -1
            inode = 0
            path = url.standardizedFileURL.path
        }
    }
}

/// One line per package (`MCPContext.serialized`): a call takes a ticket (`reserve`), waits until it is the first of
/// its line (`wait`) and leaves it when done (`release`), so the calls on a package go one at a time, in the order of
/// their tickets. The server takes a call's ticket when it reads the call, before the call's task starts.
final class PackageLocks: Sendable {
    struct Ticket: Hashable, Sendable {
        let key: PackageKey
        let number: UInt64
    }

    /// The ticket the server took for a call, which the call's first `serialized` on that package uses.
    final class Reservation: Sendable {
        let ticket: Ticket
        private let taken = Mutex(false)

        init(_ ticket: Ticket) {
            self.ticket = ticket
        }

        /// The ticket, the first time it is asked for with its package; `nil` after, or for another package.
        func take(for key: PackageKey) -> Ticket? {
            guard ticket.key == key else { return nil }
            return taken.withLock { taken in
                defer { taken = true }
                return taken ? nil : ticket
            }
        }
    }

    private struct Line {
        var tickets: [UInt64] = []
        /// The tickets waiting to be first, and how to tell them.
        var waiting: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex((next: UInt64(0), lines: [PackageKey: Line]()))

    /// A new ticket, last in the line of `key`.
    func reserve(_ key: PackageKey) -> Ticket {
        state.withLock { state in
            let ticket = Ticket(key: key, number: state.next)
            state.next += 1
            state.lines[key, default: Line()].tickets.append(ticket.number)
            return ticket
        }
    }

    /// Returns once `ticket` is the first of its line. Throws `CancellationError`, the ticket out of the line, if the
    /// task is cancelled before, or if the ticket left the line already.
    func wait(_ ticket: Ticket) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let now: Result<Void, any Error>? = state.withLock { state in
                    guard let line = state.lines[ticket.key], line.tickets.contains(ticket.number) else {
                        return .failure(CancellationError())
                    }
                    if line.tickets.first == ticket.number { return .success(()) }
                    if Task.isCancelled {
                        // Not the first: nobody goes next because it leaves.
                        _ = Self.remove(ticket, from: &state.lines)
                        return .failure(CancellationError())
                    }
                    state.lines[ticket.key]?.waiting[ticket.number] = continuation
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: {
            // Only a ticket still waiting leaves: one that is first already is its call's until it releases it.
            let waiter: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard let waiter = state.lines[ticket.key]?.waiting[ticket.number] else { return nil }
                // A ticket waiting is never the first.
                _ = Self.remove(ticket, from: &state.lines)
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Takes `ticket` out of its line (its call is done, or never ran); the next one goes if it was first. Releasing a
    /// ticket twice does nothing.
    func release(_ ticket: Ticket) {
        let next: CheckedContinuation<Void, any Error>? = state.withLock { state in
            Self.remove(ticket, from: &state.lines)
        }
        next?.resume()
    }

    /// Takes `ticket` out of `lines`, and gives the first ticket's waiter when that ticket just became first.
    private static func remove(
        _ ticket: Ticket, from lines: inout [PackageKey: Line]
    ) -> CheckedContinuation<Void, any Error>? {
        guard var line = lines[ticket.key], let index = line.tickets.firstIndex(of: ticket.number) else { return nil }
        line.tickets.remove(at: index)
        line.waiting[ticket.number] = nil
        var next: CheckedContinuation<Void, any Error>?
        if index == 0, let first = line.tickets.first {
            next = line.waiting.removeValue(forKey: first)
        }
        lines[ticket.key] = line.tickets.isEmpty ? nil : line
        return next
    }
}
