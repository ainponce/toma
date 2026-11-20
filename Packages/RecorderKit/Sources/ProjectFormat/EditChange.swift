// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One operation on the edit document (design §6.3), invertible by construction: each one carries what it replaces,
/// so `inverse` undoes it, and applying it checks that this is what the document holds.
///
/// Encoded flat with its `op`: `{"after":…,"before":…,"op":"set","path":"/style/padding"}`,
/// `{"collection":"/zoom/regions","index":0,"op":"insert","value":{…}}`, the same with `"op":"remove"` and
/// `{"after":{…},"before":{…},"collection":"/sequence","id":"c-00a1b2c3","op":"replace"}`.
public enum EditChange: Codable, Equatable, Sendable {
    /// The value at `path` goes from `before` to `after`. It exists, unless it is a member of an object that exists and
    /// one of them is `null` (plan decision 4 of phase 2): a member that is not there is `null`, so a `set` from `null`
    /// adds it and one to `null` takes it away. That is how an optional member left out (a `transcript`, a `lut`) comes
    /// and goes; the document never holds a `null`.
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

    /// The place this change writes: the value of a `set`, the array of the others.
    var place: JSONPointer {
        switch self {
        case let .set(path, _, _): path
        case let .insert(collection, _, _), let .remove(collection, _, _), let .replace(collection, _, _, _): collection
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
    /// `replace`, the `value` of a `remove`, and that the index of an `insert` is a free place (0 to the count). A `set`
    /// of a member of an object reads a member that is not there as `null`, and writing `null` takes the member away.
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
            guard let last = path.components.last else {
                guard self == before else { throw EditChangeError.mismatch(path.string) }
                self = after
                return
            }
            try modify(path.components.dropLast(), of: path) { (parent: inout JSONValue) throws(EditChangeError) in
                switch parent {
                case var .object(members):
                    guard (members[last] ?? .null) == before else { throw EditChangeError.mismatch(path.string) }
                    members[last] = after == .null ? nil : after
                    parent = .object(members)
                case var .array(elements):
                    guard let index = JSONPointer.arrayIndex(last), elements.indices.contains(index) else {
                        throw EditChangeError.noSuchPath(path.string)
                    }
                    guard elements[index] == before else { throw EditChangeError.mismatch(path.string) }
                    elements[index] = after
                    parent = .array(elements)
                default:
                    throw EditChangeError.noSuchPath(path.string)
                }
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

/// The arrays of the edit document whose elements are inserted, removed and replaced, by their pointer (its `rawValue`,
/// the pointer's string). A struct, not an enum, from phase 3 (plan decision 5), so that it can name the collection of
/// one member of an object: the ranges of a track (`gainRanges(track:)`).
public struct EditCollection: RawRepresentable, Hashable, Sendable {
    /// The array, as a pointer: read with `JSONPointer(_:)`, never by splitting `rawValue` at `/` (a track's key has one,
    /// written `~1`).
    public let pointer: JSONPointer

    public var rawValue: String { pointer.string }

    /// `nil` if `rawValue` is not a pointer, or is the whole document.
    public init?(rawValue: String) {
        guard let pointer = try? JSONPointer(rawValue), !pointer.components.isEmpty else { return nil }
        self.pointer = pointer
    }

    private init(_ components: String...) {
        pointer = JSONPointer(components: components)
    }

    public static let sequence = EditCollection("sequence")
    public static let zoomRegions = EditCollection("zoom", "regions")
    public static let zoomSuppressed = EditCollection("zoom", "suppressed")
    public static let cameraChanges = EditCollection("camera", "changes")
    public static let screenChanges = EditCollection("screens", "changes")
    public static let cameraLayouts = EditCollection("camera", "layouts")
    // Phase 2 design §8.
    public static let privacyBlocks = EditCollection("privacy", "blocks")
    /// Only while there is a transcription; its takes are inserted and removed, never replaced (they have no `id`).
    public static let transcriptTakes = EditCollection("transcript", "takes")
    // Phase 3 design §10.
    public static let annotations = EditCollection("annotations", "items")
    public static let music = EditCollection("music", "items")
    public static let markers = EditCollection("markers", "items")

    /// The stretches at another volume of the track whose key in `AudioPlan.tracks` is `key` (`take-001/mic`):
    /// `/audio/tracks/take-001~1mic/ranges`. Only while the track is there.
    public static func gainRanges(track key: String) -> EditCollection {
        EditCollection("audio", "tracks", key, "ranges")
    }
}

extension EditDocument {
    /// This document with `changes` applied, as `JSONValue.applying` does on the document as `ProjectJSON` encodes
    /// it. Throws `invalidDocument` if the result does not decode as an edit document, or decodes without something the
    /// changes wrote (a key it has no place for, a `null` optional): undoing such a change would no longer match.
    public func applying(_ changes: [EditChange]) throws(EditChangeError) -> EditDocument {
        try Self.holding(jsonValue().applying(changes)).document
    }

    /// `applying(_:)`, with the JSON of the document it gives (equal to its `jsonValue()`), from `json`, this document's
    /// JSON as an earlier call or `heldJSON()` gave it; from `jsonValue()` when `nil` (and for a document of an older
    /// version, which decoding migrates). The same document, or the same error, without encoding and decoding the whole
    /// document again: the changes go to `json`, and only the members they touch (`/zoom`, `/style`…) are decoded from it
    /// and checked to hold all of it, the others kept as they are; of the transcript, only the words they touch, when
    /// they touch nothing else of it (a correction, a break). A change of the whole document, of its `documentVersion` or
    /// of a member it has no place for, and a member that does not decode or hold, go the way of `applying(_:)`, so
    /// their error is its own. The editor applies each step this way, so a long transcript costs a small edit nothing.
    public func applying(
        _ changes: [EditChange], json: JSONValue?
    ) throws(EditChangeError) -> (document: EditDocument, json: JSONValue) {
        guard let json, documentVersion == Self.currentVersion else {
            return try Self.holding(jsonValue().applying(changes))
        }
        let next = try json.applying(changes)
        guard case var .object(members) = next else { return try Self.holding(next) }
        var touched: [String] = []
        // The words of the transcript the changes touch, `nil` once one touches something else of it.
        var words: [JSONPointer]? = []
        for change in changes {
            let place = change.place.components
            guard let key = place.first else { return try Self.holding(next) }
            if !touched.contains(key) { touched.append(key) }
            if key == "transcript" {
                if let word = transcriptWord(at: place) {
                    if words?.contains(word) == false { words?.append(word) }
                } else {
                    words = nil
                }
            }
        }
        var document = self
        for key in touched {
            if key == "transcript", let words, var transcript = members[key] {
                for word in words {
                    guard let value = transcript.value(at: word), let (decoded, own) = Self.held(TranscriptWord.self, value),
                        let (take, index) = Self.wordIndices(word), document.transcript != nil
                    else { return try Self.holding(next) }
                    document.transcript?.takes[take].words[index] = decoded
                    if let canonical = try? transcript.applying([.set(path: word, before: value, after: own)]) {
                        transcript = canonical
                    }
                }
                members[key] = transcript
                continue
            }
            guard let held = Self.decode(key, members[key], into: &document) else { return try Self.holding(next) }
            members[key] = held
        }
        return (document, .object(members))
    }

    /// This document's JSON (`jsonValue()`), for `applying(_:json:)` to start from, if decoding it gives this document
    /// back (as it does for one that was decoded); `nil` if not, or if it cannot be encoded. Encodes the whole document
    /// once, and reads it as JSON and as a document.
    public func heldJSON() -> JSONValue? {
        guard let data = try? ProjectJSON.compactEncoder().encode(self),
            let decoded = try? ProjectJSON.decoder().decode(EditDocument.self, from: data), decoded == self
        else { return nil }
        return try? JSONValue(parsing: data)
    }

    /// The word of this document's transcript that a change at `place` (`/transcript/takes/<i>/words/<j>…`) writes in
    /// or replaces, as a pointer inside the transcript (`/takes/<i>/words/<j>`); `nil` for any other place, or a word
    /// the transcript does not have (the change then refuses it, or goes the way of `applying(_:)`).
    private func transcriptWord(at place: [String]) -> JSONPointer? {
        guard place.count >= 5, place[1] == "takes", place[3] == "words",
            let take = JSONPointer.arrayIndex(place[2]), let word = JSONPointer.arrayIndex(place[4]),
            let takes = transcript?.takes, takes.indices.contains(take), takes[take].words.indices.contains(word)
        else { return nil }
        return JSONPointer(components: Array(place[1...4]))
    }

    /// The take and the word of `/takes/<i>/words/<j>`.
    private static func wordIndices(_ word: JSONPointer) -> (take: Int, word: Int)? {
        guard word.components.count == 4, let take = JSONPointer.arrayIndex(word.components[1]),
            let index = JSONPointer.arrayIndex(word.components[3])
        else { return nil }
        return (take, index)
    }

    /// `value` decoded as a `T`, as a document decodes its members, and the JSON it holds: `value` when it encodes back
    /// to its bytes, its own JSON when only the bytes differ. `nil` if `value` is not there or `null`, does not decode or
    /// holds something the `T` drops.
    private static func held<T: Codable>(_ type: T.Type, _ value: JSONValue?) -> (T, JSONValue)? {
        guard let value, value != .null, let data = try? ProjectJSON.compactEncoder().encode(value),
            let decoded = try? ProjectJSON.decoder().decode(T.self, from: data)
        else { return nil }
        guard (try? ProjectJSON.compactEncoder().encode(decoded)) != data else { return (decoded, value) }
        guard let own = try? JSONValue(encoding: decoded), own.firstDifference(from: value) == nil else { return nil }
        return (decoded, own)
    }

    /// Decodes member `key` of a document, `value` (`nil` when it is not there), into `document`, as `init(from:)`
    /// decodes it, and gives the JSON it holds (`held`; `nil` for a `transcript` that is not there). `nil` if `key` is
    /// the `documentVersion` or no member, or the member is not there, does not decode or drops something of `value`.
    private static func decode(_ key: String, _ value: JSONValue?, into document: inout EditDocument) -> JSONValue?? {
        func member<T: Codable>(_ type: T.Type, _ set: (inout EditDocument, T) -> Void) -> JSONValue?? {
            guard let (decoded, json) = held(T.self, value) else { return nil }
            set(&document, decoded)
            return .some(json)
        }
        switch key {
        case "logSequence": return member(Int.self) { $0.logSequence = $1 }
        case "aspect": return member(Aspect.self) { $0.aspect = $1 }
        case "frameRate": return member(Int.self) { $0.frameRate = $1 }
        case "sequence": return member([Clip].self) { $0.sequence = $1 }
        case "screens": return member(ScreenPlan.self) { $0.screens = $1 }
        case "style": return member(StageStyle.self) { $0.style = $1 }
        case "cursor": return member(CursorStyle.self) { $0.cursor = $1 }
        case "zoom": return member(ZoomPlan.self) { $0.zoom = $1 }
        case "camera": return member(CameraPlan.self) { $0.camera = $1 }
        case "audio": return member(AudioPlan.self) { $0.audio = $1 }
        case "transcript":
            guard value != nil else {
                document.transcript = nil
                return .some(nil)
            }
            return member(Transcript.self) { $0.transcript = $1 }
        case "captions": return member(CaptionPlan.self) { $0.captions = $1 }
        case "privacy": return member(PrivacyPlan.self) { $0.privacy = $1 }
        case "keys": return member(KeyOverlayPlan.self) { $0.keys = $1 }
        case "annotations": return member(AnnotationPlan.self) { $0.annotations = $1 }
        case "music": return member(MusicPlan.self) { $0.music = $1 }
        case "markers": return member(MarkerPlan.self) { $0.markers = $1 }
        default: return nil
        }
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
    /// is what is there already or `value` cannot be encoded. An optional member left out (a `transcript` that is `nil`)
    /// is named if the document has a place for it: the change adds it from `null`, as one with a `nil` value takes it
    /// away to `null` (plan decision 4 of phase 2). `value` is written as the document writes it: one its type leaves out
    /// of the JSON (a `breakBefore` of `false`) takes the member away, so the change is one `applying` takes.
    public func setChange(_ pointer: String, _ value: some Encodable) -> EditChange? {
        guard let path = try? JSONPointer(pointer), let json = try? jsonValue(), let after = try? JSONValue(encoding: value)
        else { return nil }
        if let before = json.value(at: path) {
            guard after != before else { return nil }
            let written = Self.written(after, at: path, replacing: before, in: json)
            return written == before ? nil : .set(path: path, before: before, after: written)
        }
        // Not there: a member of an object that is, which the document can hold once added.
        let parent = JSONPointer(components: Array(path.components.dropLast()))
        guard !path.components.isEmpty, after != .null, case .object? = json.value(at: parent) else { return nil }
        let change = EditChange.set(path: path, before: .null, after: after)
        return (try? applying([change])) == nil ? nil : change
    }

    /// `value` at `path` of `json`, a document, as the document writes it once it holds it there instead of `before`:
    /// `null` for one its type leaves out of the JSON (a default that is not written), `value` itself for any other, and
    /// for one the document cannot hold (`applying` refuses it, and says where).
    private static func written(_ value: JSONValue, at path: JSONPointer, replacing before: JSONValue, in json: JSONValue) -> JSONValue {
        guard let changed = try? json.applying([.set(path: path, before: before, after: value)]),
            let document = try? changed.decoded(as: EditDocument.self), let canonical = try? document.jsonValue()
        else { return value }
        return canonical.value(at: path) ?? .null
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
