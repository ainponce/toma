// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Any JSON value: what a change of the edit log writes into the document (`EditChange`), whatever its type.
///
/// Decoding reads an integral number as the exact `integer` (`unsigned` only when it does not fit in `Int64`), and
/// only a number that is not an integer as `number`. Integers are written with digits only, without an exponent or
/// decimals. So a `HostTime` of a Mac that has been up more than 104 days (2⁵³ ns, past which a `Double` no longer
/// holds every nanosecond) comes back as it was.
///
/// `==` compares numbers by their exact value, whatever case holds them: integers as integers, never through a
/// `Double`, and a `number` equals an integer only if it is exactly that integer (`1.0` is `1`, as JSON writes it).
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// An integer above `Int64.max`.
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// `value` as `ProjectJSON` encodes it. Throws what encoding throws (a non-finite number).
    public init(encoding value: some Encodable) throws {
        let data = try ProjectJSON.compactEncoder().encode(value)
        // `JSONSerialization` reads a whole document many times faster than `init(from:)`, whose every guess at a
        // type throws, and it keeps integers exact (an `NSNumber` of `long long` or `unsigned long long`).
        self.init(serialized: try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
    }

    /// What `JSONSerialization` read, with the rules of `init(from:)`.
    private init(serialized object: Any) {
        switch object {
        case let number as NSNumber: self.init(number)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(serialized:)))
        case let members as [String: Any]: self = .object(members.mapValues(JSONValue.init(serialized:)))
        default: self = .null
        }
    }

    private init(_ number: NSNumber) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        switch UInt8(bitPattern: number.objCType.pointee) {
        case UInt8(ascii: "q"), UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "s"), UInt8(ascii: "c"):
            self = .integer(number.int64Value)
        case UInt8(ascii: "Q"), UInt8(ascii: "L"), UInt8(ascii: "I"), UInt8(ascii: "S"), UInt8(ascii: "C"):
            let value = number.uint64Value
            self = Int64(exactly: value).map(JSONValue.integer) ?? .unsigned(value)
        default:
            // A number with a fraction or an exponent; one that is an integer still reads as one, as in `init(from:)`.
            let value = number.doubleValue
            if let integer = Int64(exactly: value) {
                self = .integer(integer)
            } else if let integer = UInt64(exactly: value) {
                self = .unsigned(integer)
            } else {
                self = .number(value)
            }
        }
    }

    /// This value decoded as `T` with `ProjectJSON.decoder()`.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try ProjectJSON.decoder().decode(type, from: ProjectJSON.compactEncoder().encode(self))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsigned(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a == b
        default:
            if let a = lhs.exactNumber, let b = rhs.exactNumber { a == b } else { false }
        }
    }

    /// A number by its exact value, so the three numeric cases compare with each other.
    private enum ExactNumber: Equatable {
        case integral(negative: Bool, magnitude: UInt64)
        /// Not an integer, or beyond the integers the other cases hold.
        case other(Double)
    }

    private var exactNumber: ExactNumber? {
        switch self {
        case let .integer(value): .integral(negative: value < 0, magnitude: value.magnitude)
        case let .unsigned(value): .integral(negative: false, magnitude: value)
        case let .number(value):
            if let integer = Int64(exactly: value) {
                .integral(negative: integer < 0, magnitude: integer.magnitude)
            } else if let integer = UInt64(exactly: value) {
                .integral(negative: false, magnitude: integer)
            } else {
                .other(value)
            }
        default: nil
        }
    }

    /// The value at `pointer`, or `nil` if there is none.
    func value(at pointer: JSONPointer) -> JSONValue? {
        var value = self
        for component in pointer.components {
            switch value {
            case let .object(members):
                guard let member = members[component] else { return nil }
                value = member
            case let .array(elements):
                guard let index = JSONPointer.arrayIndex(component), elements.indices.contains(index) else { return nil }
                value = elements[index]
            default:
                return nil
            }
        }
        return value
    }

    /// The pointer of the first place, in key and index order, where this value and `other` differ; `nil` if they are
    /// equal.
    func firstDifference(from other: JSONValue, at path: [String] = []) -> JSONPointer? {
        switch (self, other) {
        case let (.object(a), .object(b)):
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let x = a[key], let y = b[key] else { return JSONPointer(components: path + [key]) }
                if let difference = x.firstDifference(from: y, at: path + [key]) { return difference }
            }
            return nil
        case let (.array(a), .array(b)):
            for index in 0..<max(a.count, b.count) {
                guard index < a.count, index < b.count else { return JSONPointer(components: path + [String(index)]) }
                if let difference = a[index].firstDifference(from: b[index], at: path + [String(index)]) { return difference }
            }
            return nil
        default:
            return self == other ? nil : JSONPointer(components: path)
        }
    }
}

/// A place in a JSON value (RFC 6901): `/style/padding`, `/sequence/0/end`. In each component, `~` is written `~0`
/// and `/` is written `~1`: `/audio/tracks/take-001~1mic/gain`. The empty pointer is the whole value. Encoded as its
/// string.
public struct JSONPointer: Hashable, Sendable, Codable {
    public var components: [String]

    public init(components: [String]) {
        self.components = components
    }

    /// Throws `EditChangeError.noSuchPath` if `string` is not a pointer: not empty and not starting with `/`, or with a
    /// `~` that is not `~0` or `~1`.
    public init(_ string: String) throws {
        guard !string.isEmpty else {
            self.init(components: [])
            return
        }
        guard string.hasPrefix("/") else { throw EditChangeError.noSuchPath(string) }
        var components: [String] = []
        for escaped in string.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let component = Self.unescape(escaped) else { throw EditChangeError.noSuchPath(string) }
            components.append(component)
        }
        self.init(components: components)
    }

    public var string: String {
        components.map { "/" + Self.escape($0) }.joined()
    }

    /// `component` as it is written in a pointer: `~` as `~0` and `/` as `~1`.
    public static func escape(_ component: String) -> String {
        component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// `nil` if a `~` is not followed by `0` or `1`.
    private static func unescape(_ escaped: Substring) -> String? {
        var component = ""
        var iterator = escaped.makeIterator()
        while let character = iterator.next() {
            guard character == "~" else {
                component.append(character)
                continue
            }
            switch iterator.next() {
            case "0": component.append("~")
            case "1": component.append("/")
            default: return nil
            }
        }
        return component
    }

    /// The index an array component names: `0` or digits without a leading zero. `-` (past the end) names no element.
    static func arrayIndex(_ component: String) -> Int? {
        let digits = component.utf8
        guard let first = digits.first, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            first != UInt8(ascii: "0") || digits.count == 1
        else { return nil }
        return Int(component)
    }

    /// The pointer of the element at `index` of the array this pointer names.
    func appending(_ index: Int) -> JSONPointer {
        JSONPointer(components: components + [String(index)])
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not a JSON pointer.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

extension ProjectJSON {
    /// `encoder()` without the indentation: the edit log's lines (the rules of `events.jsonl`: compact, keys in
    /// order) and the bytes a `JSONValue` goes through.
    static func compactEncoder() -> JSONEncoder {
        let encoder = encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
