// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// JSON-RPC 2.0 as MCP's stdio transport carries it (fases 4 y 5 design §6.3): one message per line, written without a
/// line break inside (`JSONEncoder` escapes every control character of a string), each line ending in `\n`.
enum JSONRPC {
    /// The error codes of JSON-RPC 2.0 the server gives (plan 4b decision 15).
    enum ErrorCode: Int64 {
        /// The line is not JSON.
        case parseError = -32700
        /// JSON that is not a request: an array (a batch, which MCP `2025-06-18` does not have), not an object, without
        /// `"jsonrpc": "2.0"` or a `method`, or with an `id` that is not a string or a number.
        case invalidRequest = -32600
        case methodNotFound = -32601
        /// The parameters of a method are not what it takes: also a tool that is not one (MCP's rule).
        case invalidParams = -32602
        case internalError = -32603
    }

    /// The line of a response to the request `id` with `result`.
    static func response(id: JSONValue, result: JSONValue) -> Data {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    /// The line of an error answering the request `id` (`null` when it could not be read).
    static func error(id: JSONValue, _ code: ErrorCode, _ message: String) -> Data {
        line(.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .integer(code.rawValue), "message": .string(message)]),
        ]))
    }

    /// The line of a notification.
    static func notification(_ method: String, _ params: [String: JSONValue]) -> Data {
        line(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]))
    }

    /// `value` as compact JSON, its keys in order, and `\n`. A value that cannot be written (a number that is not
    /// finite, which no result of the API has) is replaced by an internal error, so a line is always JSON-RPC.
    static func line(_ value: JSONValue) -> Data {
        var data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            let id = value.member("id") ?? .null
            let failure = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object([
                    "code": .integer(ErrorCode.internalError.rawValue),
                    "message": .string("the answer could not be written as JSON"),
                ]),
            ])
            data = (try? encoder.encode(failure))
                ?? Data(#"{"error":{"code":-32603,"message":"internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8)
        }
        data.append(0x0A)
        return data
    }

    /// The text `value` is in a result's `content`: the same JSON as the line's, without the `\n`.
    static func text(_ value: JSONValue) -> String {
        String(decoding: line(value).dropLast(), as: UTF8.self)
    }

    /// `text` read as JSON: `nil` if it is not.
    static func parse(_ text: some StringProtocol) -> JSONValue? {
        try? ProjectJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// The id of a request, to find its call again (`notifications/cancelled`): a string or a number, as JSON-RPC has them.
enum RequestKey: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)

    /// `nil` for an id that is neither (`null`, a boolean, an array, an object).
    init?(_ id: JSONValue) {
        switch id {
        case let .string(value): self = .string(value)
        case let .integer(value): self = .integer(value)
        case let .unsigned(value): self = Int64(exactly: value).map(Self.integer) ?? .number(Double(value))
        case let .number(value): self = Int64(exactly: value).map(Self.integer) ?? .number(value)
        default: return nil
        }
    }
}

extension JSONValue {
    /// The members of an object; `nil` for another value.
    var objectValue: [String: JSONValue]? {
        if case let .object(members) = self { members } else { nil }
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    /// The member `key` of an object.
    func member(_ key: String) -> JSONValue? {
        objectValue?[key]
    }
}
