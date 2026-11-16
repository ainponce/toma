// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One operation on the edit document (design §6.3), invertible by construction: each one carries what it replaces,
/// so `inverse` undoes it, and applying it checks that this is what the document holds.
///
/// Encoded flat with its `op`: `{"after":…,"before":…,"op":"set","path":"/style/padding"}`,
/// `{"collection":"/zoom/regions","index":0,"op":"insert","value":{…}}`, the same with `"op":"remove"` and
/// `{"after":{…},"before":{…},"collection":"/sequence","id":"c-00a1b2c3","op":"replace"}`.
public enum EditChange: Codable, Equatable, Sendable {
    /// The value at `path`, which exists, goes from `before` to `after`.
    case set(path: JSONPointer, before: JSONValue, after: JSONValue)
    /// `value` goes into the array `collection` at `index`, from 0 to its count.
    case insert(collection: JSONPointer, index: Int, value: JSONValue)
    /// The element `value` at `index` of the array `collection` goes away.
    case remove(collection: JSONPointer, index: Int, value: JSONValue)
    /// The element of the array `collection` whose `id` is `id` goes from `before` to `after`, the whole element;
    /// `after` keeps the `id`.
    case replace(collection: JSONPointer, id: String, before: JSONValue, after: JSONValue)

    /// The change that undoes this one.
    public var inverse: EditChange {
        switch self {
        case let .set(path, before, after): .set(path: path, before: after, after: before)
        case let .insert(collection, index, value): .remove(collection: collection, index: index, value: value)
        case let .remove(collection, index, value): .insert(collection: collection, index: index, value: value)
        case let .replace(collection, id, before, after): .replace(collection: collection, id: id, before: after, after: before)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op, path, before, after, collection, index, value, id
    }

    private enum Op: String, Encodable {
        case set, insert, remove, replace
    }

    public init(from decoder: any Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    /// The change `json` holds, as it is written: `init(from:)` and the edit log's reader read it so.
    init(json: JSONValue) throws {
        let members = try JSONMembers(json)
        switch try members.string(CodingKeys.op.rawValue) {
        case Op.set.rawValue:
            self = .set(path: try members.pointer("path"), before: try members.value("before"), after: try members.value("after"))
        case Op.insert.rawValue:
            self = .insert(
                collection: try members.pointer("collection"), index: try members.int("index"), value: try members.value("value"))
        case Op.remove.rawValue:
            self = .remove(
                collection: try members.pointer("collection"), index: try members.int("index"), value: try members.value("value"))
        case Op.replace.rawValue:
            self = .replace(
                collection: try members.pointer("collection"), id: try members.string("id"), before: try members.value("before"),
                after: try members.value("after"))
        case let op:
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No op \"\(op)\"."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .set(path, before, after):
            try container.encode(Op.set, forKey: .op)
            try container.encode(path, forKey: .path)
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case let .insert(collection, index, value):
            try container.encode(Op.insert, forKey: .op)
            try container.encode(collection, forKey: .collection)
            try container.encode(index, forKey: .index)
            try container.encode(value, forKey: .value)
        case let .remove(collection, index, value):
            try container.encode(Op.remove, forKey: .op)
            try container.encode(collection, forKey: .collection)
            try container.encode(index, forKey: .index)
            try container.encode(value, forKey: .value)
        case let .replace(collection, id, before, after):
            try container.encode(Op.replace, forKey: .op)
            try container.encode(collection, forKey: .collection)
            try container.encode(id, forKey: .id)
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        }
    }
}

/// Why a change could not be applied. The strings are JSON pointers: of the place, the collection or the element.
public enum EditChangeError: Error, Equatable, Sendable {
    /// What the change says is there (`before`, or the `value` it removes) is not what is there.
    case mismatch(String)
    case noSuchPath(String)
    /// The collection and the index.
    case indexOutOfRange(String, Int)
    /// The collection and the id.
    case noSuchID(String, String)
    /// The result is not an edit document, or not one that holds exactly what the changes wrote; the pointer is where.
    /// The replay of the edit log treats it as a damaged line.
    case invalidDocument(String)
}

extension JSONValue {
    /// This value with `changes` applied in order. Each change checks what it replaces: the `before` of a `set` or a
    /// `replace`, the `value` of a `remove`, and that the index of an `insert` is a free place (0 to the count).
    public func applying(_ changes: [EditChange]) throws(EditChangeError) -> JSONValue {
        var value = self
        for change in changes {
            try value.apply(change)
        }
        return value
    }

    private mutating func apply(_ change: EditChange) throws(EditChangeError) {
        switch change {
        case let .set(path, before, after):
            try modify(path.components[...], of: path) { (value: inout JSONValue) throws(EditChangeError) in
                guard value == before else { throw EditChangeError.mismatch(path.string) }
                value = after
            }
        case let .insert(collection, index, element):
            try modifyArray(collection) { (elements: inout [JSONValue]) throws(EditChangeError) in
                guard index >= 0, index <= elements.count else { throw EditChangeError.indexOutOfRange(collection.string, index) }
                elements.insert(element, at: index)
            }
        case let .remove(collection, index, element):
            try modifyArray(collection) { (elements: inout [JSONValue]) throws(EditChangeError) in
                guard elements.indices.contains(index) else { throw EditChangeError.indexOutOfRange(collection.string, index) }
                guard elements[index] == element else { throw EditChangeError.mismatch(collection.appending(index).string) }
                elements.remove(at: index)
            }
        case let .replace(collection, id, before, after):
            try modifyArray(collection) { (elements: inout [JSONValue]) throws(EditChangeError) in
                guard let index = elements.firstIndex(where: { $0.elementID == id }) else {
                    throw EditChangeError.noSuchID(collection.string, id)
                }
                // An `after` with another id could not be found by the inverse.
                guard elements[index] == before, after.elementID == id else {
                    throw EditChangeError.mismatch(collection.appending(index).string)
                }
                elements[index] = after
            }
        }
    }

    /// Runs `body` on the value at `components` of `pointer`, which exists.
    private mutating func modify(
        _ components: ArraySlice<String>, of pointer: JSONPointer, _ body: (inout JSONValue) throws(EditChangeError) -> Void
    ) throws(EditChangeError) {
        guard let component = components.first else { return try body(&self) }
        switch self {
        case var .object(members):
            guard var member = members[component] else { throw EditChangeError.noSuchPath(pointer.string) }
            try member.modify(components.dropFirst(), of: pointer, body)
            members[component] = member
            self = .object(members)
        case var .array(elements):
            guard let index = JSONPointer.arrayIndex(component), elements.indices.contains(index) else {
                throw EditChangeError.noSuchPath(pointer.string)
            }
            try elements[index].modify(components.dropFirst(), of: pointer, body)
            self = .array(elements)
        default:
            throw EditChangeError.noSuchPath(pointer.string)
        }
    }

    /// Runs `body` on the elements of the array at `collection`.
    private mutating func modifyArray(
        _ collection: JSONPointer, _ body: (inout [JSONValue]) throws(EditChangeError) -> Void
    ) throws(EditChangeError) {
        try modify(collection.components[...], of: collection) { (value: inout JSONValue) throws(EditChangeError) in
            guard case var .array(elements) = value else { throw EditChangeError.noSuchPath(collection.string) }
            try body(&elements)
            value = .array(elements)
        }
    }

    /// The `id` of an element of a collection.
    fileprivate var elementID: String? {
        guard case let .object(members) = self, case let .string(id)? = members["id"] else { return nil }
        return id
    }
}

/// The arrays of the edit document whose elements are inserted, removed and replaced, by their pointer.
public enum EditCollection: String, Sendable {
    case sequence = "/sequence"
    case zoomRegions = "/zoom/regions"
    case zoomSuppressed = "/zoom/suppressed"
    case cameraChanges = "/camera/changes"
    case screenChanges = "/screens/changes"
    case cameraLayouts = "/camera/layouts"

    var pointer: JSONPointer {
        JSONPointer(components: rawValue.split(separator: "/").map(String.init))
    }
}

extension EditDocument {
    /// This document with `changes` applied, as `JSONValue.applying` does on the document as `ProjectJSON` encodes
    /// it. Throws `invalidDocument` if the result does not decode as an edit document, or decodes without something the
    /// changes wrote (a key it has no place for, a `null` optional): undoing such a change would no longer match.
    public func applying(_ changes: [EditChange]) throws(EditChangeError) -> EditDocument {
        try Self.holding(jsonValue().applying(changes)).document
    }

    /// The document `value` encodes, if it holds all of `value`, and its JSON: the edit log's replay applies its lines
    /// to the JSON and decodes the document only once.
    static func holding(_ value: JSONValue) throws(EditChangeError) -> (document: EditDocument, json: JSONValue) {
        let data: Data
        let document: EditDocument
        do {
            data = try ProjectJSON.compactEncoder().encode(value)
            document = try ProjectJSON.decoder().decode(EditDocument.self, from: data)
        } catch {
            throw .invalidDocument(pointer(of: error))
        }
        // Decoding drops what the document has no place for. The same bytes back prove it kept everything; other
        // bytes can still be the same value (`1e+18` written for an integer), so then the values are compared.
        guard (try? ProjectJSON.compactEncoder().encode(document)) != data else { return (document, value) }
        let held = try document.jsonValue()
        if let difference = held.firstDifference(from: value) {
            throw .invalidDocument(difference.string)
        }
        return (document, held)
    }

    /// A change of the value at `pointer` to `value`; `nil` if the pointer names nothing in this document, `value`
    /// is what is there already or `value` cannot be encoded.
    public func setChange(_ pointer: String, _ value: some Encodable) -> EditChange? {
        guard let path = try? JSONPointer(pointer), let before = (try? jsonValue())?.value(at: path),
            let after = try? JSONValue(encoding: value), after != before
        else { return nil }
        return .set(path: path, before: before, after: after)
    }

    /// The insertion of `value` into `collection` at `index`. A value that cannot be encoded (a non-finite number)
    /// cannot be in the document either: it becomes a `null` element, which `applying` refuses.
    public func insertChange(_ collection: EditCollection, at index: Int, _ value: some Encodable) -> EditChange {
        .insert(collection: collection.pointer, index: index, value: (try? JSONValue(encoding: value)) ?? .null)
    }

    /// The removal of the element at `index` of `collection`; `nil` if there is none.
    public func removeChange(_ collection: EditCollection, at index: Int) -> EditChange? {
        guard case let .array(elements)? = (try? jsonValue())?.value(at: collection.pointer), elements.indices.contains(index)
        else { return nil }
        return .remove(collection: collection.pointer, index: index, value: elements[index])
    }

    /// The replacement of the element of `collection` with the `id` `id` by `value`, which keeps that `id`; `nil` if
    /// there is no such element, `value` is the same element, has another `id` or cannot be encoded.
    public func replaceChange(_ collection: EditCollection, id: String, with value: some Encodable) -> EditChange? {
        guard case let .array(elements)? = (try? jsonValue())?.value(at: collection.pointer),
            let before = elements.first(where: { $0.elementID == id }), let after = try? JSONValue(encoding: value),
            after.elementID == id, after != before
        else { return nil }
        return .replace(collection: collection.pointer, id: id, before: before, after: after)
    }

    /// This document as `ProjectJSON` encodes it; `invalidDocument` if it cannot be encoded (a non-finite number).
    func jsonValue() throws(EditChangeError) -> JSONValue {
        do {
            return try JSONValue(encoding: self)
        } catch {
            throw .invalidDocument("")
        }
    }

    /// Where in the document decoding failed, as a JSON pointer.
    private static func pointer(of error: any Error) -> String {
        let path: [any CodingKey]
        switch error {
        case let DecodingError.keyNotFound(key, context): path = context.codingPath + [key]
        case let DecodingError.typeMismatch(_, context): path = context.codingPath
        case let DecodingError.valueNotFound(_, context): path = context.codingPath
        case let DecodingError.dataCorrupted(context): path = context.codingPath
        case EditDocumentError.newerVersion: return "/documentVersion"
        default: path = []
        }
        return JSONPointer(components: path.map { key in key.intValue.map(String.init) ?? key.stringValue }).string
    }
}
