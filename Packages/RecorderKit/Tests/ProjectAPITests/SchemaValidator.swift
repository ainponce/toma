// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// A small JSON Schema (draft 2020-12) validator, enough for the format's schemas in `docs/format/schema/` (plan 4b
/// decision 17, with the keywords the format's tagged objects need): `type` (a name or a list of them; `integer` is a
/// number without a fraction), `enum`, `const`, `properties`, `required`, `additionalProperties` (a schema, never
/// `false`), `items`, `minItems`, `maxItems`, `minimum`, `maximum`, `$ref` to `#/$defs/<name>`, `allOf`, `oneOf` and
/// `if`/`then`. Like the standard, a keyword about objects says nothing about a value that is not one (and so on for
/// arrays and numbers). `$schema`, `$id`, `$defs`, `title`, `description` and `examples` are annotations; any other
/// keyword is one the schemas must not use (`unknownKeywords(in:)`).
struct SchemaValidator {
    /// The keywords this validator checks.
    static let keywords: Set<String> = [
        "type", "enum", "const", "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
        "minimum", "maximum", "$ref", "allOf", "oneOf", "if", "then",
    ]
    /// The keywords that only annotate.
    static let annotations: Set<String> = ["$schema", "$id", "$defs", "title", "description", "examples"]

    let schema: JSONValue

    init(schema: JSONValue) {
        self.schema = schema
    }

    /// What in `value` the schema does not accept, one line per problem, each starting with its JSON pointer (`""` is
    /// the whole value). Empty if it accepts it.
    func problems(in value: JSONValue) -> [String] {
        var problems: [String] = []
        check(value, against: schema, at: "", into: &problems)
        return problems
    }

    /// The pointers of the members of `value`'s objects that no `properties` of the schema names and no
    /// `additionalProperties` covers: what the schema does not describe, though it accepts it.
    func undescribedKeys(in value: JSONValue) -> [String] {
        var keys: [String] = []
        collectUndescribed(value, schemas: [schema], at: "", into: &keys)
        return keys
    }

    /// The places in `schema` that use a keyword this validator neither checks nor treats as an annotation, and those
    /// that say `additionalProperties: false` (a reader ignores keys it does not know). Walks only where a schema is.
    static func unknownKeywords(in schema: JSONValue, at path: String = "") -> [String] {
        guard case let .object(members) = schema else { return [] }
        var found: [String] = []
        for (key, member) in members.sorted(by: { $0.key < $1.key }) {
            let place = path + "/" + JSONPointer.escape(key)
            if !keywords.contains(key) && !annotations.contains(key) { found.append(place) }
            switch key {
            case "properties", "$defs":
                if case let .object(children) = member {
                    for (name, child) in children { found += unknownKeywords(in: child, at: place + "/" + JSONPointer.escape(name)) }
                }
            case "allOf", "oneOf":
                if case let .array(children) = member {
                    for (index, child) in children.enumerated() { found += unknownKeywords(in: child, at: place + "/\(index)") }
                }
            case "additionalProperties":
                if member == .bool(false) { found.append(place + " is false") }
                found += unknownKeywords(in: member, at: place)
            case "items", "if", "then":
                found += unknownKeywords(in: member, at: place)
            default:
                break
            }
        }
        return found
    }

    // MARK: - Checking

    private func check(_ value: JSONValue, against schema: JSONValue, at path: String, into problems: inout [String]) {
        switch schema {
        case .bool(true):
            return
        case .bool(false):
            problems.append("\(path): no value is allowed here")
            return
        case let .object(keywords):
            if case let .string(reference) = keywords["$ref"] {
                if let target = resolve(reference) {
                    check(value, against: target, at: path, into: &problems)
                } else {
                    problems.append("\(path): the schema's \(reference) does not resolve")
                }
            }
            if let type = keywords["type"], !Self.matches(value, type: type) {
                problems.append("\(path): \(Self.describe(value)) is not of type \(Self.compact(type))")
            }
            if case let .array(values) = keywords["enum"], !values.contains(value) {
                problems.append("\(path): \(Self.compact(value)) is not one of \(Self.compact(.array(values)))")
            }
            if let constant = keywords["const"], value != constant {
                problems.append("\(path): \(Self.compact(value)) is not \(Self.compact(constant))")
            }
            checkNumber(value, keywords, at: path, into: &problems)
            checkObject(value, keywords, at: path, into: &problems)
            checkArray(value, keywords, at: path, into: &problems)
            if case let .array(all) = keywords["allOf"] {
                for subschema in all { check(value, against: subschema, at: path, into: &problems) }
            }
            if case let .array(branches) = keywords["oneOf"] {
                let matching = branches.filter { accepts(value, $0) }.count
                if matching != 1 { problems.append("\(path): matches \(matching) of the \(branches.count) schemas of oneOf, not 1") }
            }
            if let condition = keywords["if"], let then = keywords["then"], accepts(value, condition) {
                check(value, against: then, at: path, into: &problems)
            }
        default:
            problems.append("\(path): the schema \(Self.compact(schema)) is not a schema")
        }
    }

    private func checkNumber(_ value: JSONValue, _ keywords: [String: JSONValue], at path: String, into problems: inout [String]) {
        guard let number = Self.double(value) else { return }
        if let minimum = keywords["minimum"].flatMap(Self.double), number < minimum {
            problems.append("\(path): \(Self.compact(value)) is below the minimum \(Self.compact(keywords["minimum"]!))")
        }
        if let maximum = keywords["maximum"].flatMap(Self.double), number > maximum {
            problems.append("\(path): \(Self.compact(value)) is above the maximum \(Self.compact(keywords["maximum"]!))")
        }
    }

    private func checkObject(_ value: JSONValue, _ keywords: [String: JSONValue], at path: String, into problems: inout [String]) {
        guard case let .object(members) = value else { return }
        if case let .array(required) = keywords["required"] {
            for case let .string(key) in required where members[key] == nil {
                problems.append("\(path): lacks the required \"\(key)\"")
            }
        }
        let properties: [String: JSONValue]
        if case let .object(named) = keywords["properties"] { properties = named } else { properties = [:] }
        for (key, member) in members.sorted(by: { $0.key < $1.key }) {
            let place = path + "/" + JSONPointer.escape(key)
            if let property = properties[key] {
                check(member, against: property, at: place, into: &problems)
            } else if let additional = keywords["additionalProperties"] {
                check(member, against: additional, at: place, into: &problems)
            }
        }
    }

    private func checkArray(_ value: JSONValue, _ keywords: [String: JSONValue], at path: String, into problems: inout [String]) {
        guard case let .array(elements) = value else { return }
        if let minimum = keywords["minItems"].flatMap(Self.double), Double(elements.count) < minimum {
            problems.append("\(path): has \(elements.count) items, fewer than \(Self.compact(keywords["minItems"]!))")
        }
        if let maximum = keywords["maxItems"].flatMap(Self.double), Double(elements.count) > maximum {
            problems.append("\(path): has \(elements.count) items, more than \(Self.compact(keywords["maxItems"]!))")
        }
        if let items = keywords["items"] {
            for (index, element) in elements.enumerated() { check(element, against: items, at: path + "/\(index)", into: &problems) }
        }
    }

    private func accepts(_ value: JSONValue, _ schema: JSONValue) -> Bool {
        var problems: [String] = []
        check(value, against: schema, at: "", into: &problems)
        return problems.isEmpty
    }

    /// The schema `#/$defs/<name>` names.
    private func resolve(_ reference: String) -> JSONValue? {
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix), case let .object(root) = schema, case let .object(definitions) = root["$defs"] else {
            return nil
        }
        return definitions[String(reference.dropFirst(prefix.count))]
    }

    // MARK: - Describing

    /// The schemas that apply to `value` at this level: each of `schemas` with what its `$ref`, `allOf`, its `then`
    /// whose `if` holds, and its one matching branch of `oneOf` bring.
    private func applicable(_ schemas: [JSONValue], to value: JSONValue) -> [[String: JSONValue]] {
        var result: [[String: JSONValue]] = []
        var pending = schemas
        while let schema = pending.popLast() {
            guard case let .object(keywords) = schema else { continue }
            result.append(keywords)
            if case let .string(reference) = keywords["$ref"], let target = resolve(reference) { pending.append(target) }
            if case let .array(all) = keywords["allOf"] { pending += all }
            if let condition = keywords["if"], let then = keywords["then"], accepts(value, condition) { pending.append(then) }
            if case let .array(branches) = keywords["oneOf"] {
                let matching = branches.filter { accepts(value, $0) }
                if matching.count == 1 { pending += matching }
            }
        }
        return result
    }

    private func collectUndescribed(_ value: JSONValue, schemas: [JSONValue], at path: String, into keys: inout [String]) {
        let nodes = applicable(schemas, to: value)
        switch value {
        case let .object(members):
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                let place = path + "/" + JSONPointer.escape(key)
                var children: [JSONValue] = nodes.compactMap { node in
                    if case let .object(properties) = node["properties"] { properties[key] } else { nil }
                }
                if children.isEmpty { children = nodes.compactMap { $0["additionalProperties"] } }
                if children.isEmpty {
                    keys.append(place)
                } else {
                    collectUndescribed(member, schemas: children, at: place, into: &keys)
                }
            }
        case let .array(elements):
            let items = nodes.compactMap { $0["items"] }
            for (index, element) in elements.enumerated() where !items.isEmpty {
                collectUndescribed(element, schemas: items, at: path + "/\(index)", into: &keys)
            }
        default:
            break
        }
    }

    // MARK: - Values

    private static func matches(_ value: JSONValue, type: JSONValue) -> Bool {
        switch type {
        case let .string(name): matches(value, typeName: name)
        case let .array(names): names.contains { if case let .string(name) = $0 { matches(value, typeName: name) } else { false } }
        default: false
        }
    }

    private static func matches(_ value: JSONValue, typeName: String) -> Bool {
        switch (typeName, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): true
        case ("number", .integer), ("number", .unsigned), ("number", .number): true
        case ("integer", .integer), ("integer", .unsigned): true
        case let ("integer", .number(number)): number.isFinite && number.rounded(.towardZero) == number
        default: false
        }
    }

    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case let .integer(integer): Double(integer)
        case let .unsigned(integer): Double(integer)
        case let .number(number): number
        default: nil
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .integer, .unsigned: "an integer"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// `value` as compact JSON with its keys in order, cut at 80 characters.
    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return text.count > 80 ? String(text.prefix(77)) + "…" : text
    }
}
