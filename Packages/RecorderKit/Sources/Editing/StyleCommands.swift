// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the panel's style values (design §5.4) and of the Project menu (§5.1), as pure functions of the
/// document: each gives the step that does it (`EditStep`), or `nil` when the value is what the document has already.
///
/// The changes are built from the values they touch, never from the whole document encoded again: a `set` reads what it
/// replaces from the encoding of the document's top-level member it names (`/style`, `/cursor`, `/zoom`…) alone.
public enum StyleCommands {
    /// The frame rates of the Project menu: `EditDocument.frameRates`.
    public static let frameRates = EditDocument.frameRates

    /// Sets the value at `pointer` (`/style/padding`, `/cursor/scale`…) to `value`, as the step `label` with the pointer
    /// as its target, so a burst of steps on one control is one undo (design §6.4). `nil` if the pointer names nothing in
    /// the document (an optional value that is not there: one is added or taken away with its parent's `set`), names
    /// `documentVersion` or `logSequence`, which no edit changes, if `value` is what is there or cannot be encoded.
    public static func set(_ doc: EditDocument, _ pointer: String, _ value: some Encodable, label: EditLabel) -> EditStep? {
        guard let path = try? JSONPointer(pointer), let before = DocumentValues.value(at: path, in: doc),
            let after = try? JSONValue(encoding: value), after != before
        else { return nil }
        return EditStep(label: label, target: path.string, changes: [.set(path: path, before: before, after: after)])
    }

    /// The shape of the output (design §5.2): the stage rearranges itself, and the zooms, kept in the screen's
    /// coordinates, still hold.
    public static func setAspect(_ doc: EditDocument, _ aspect: Aspect) -> EditStep? {
        set(doc, "/aspect", aspect, label: .aspect)
    }

    /// The project's frame rate, one of `frameRates`; `nil` for any other.
    public static func setFrameRate(_ doc: EditDocument, _ fps: Int) -> EditStep? {
        guard frameRates.contains(fps) else { return nil }
        return set(doc, "/frameRate", fps, label: .frameRate)
    }

    /// "Apply Default Style" (design §5.4 and §5.9), one step: the stage of `style` (with mipmapped sampling and the
    /// spring between shapes, as a new document has them: `NewDocument`), its whole cursor and the zoom's settings
    /// (`show`, `auto`, `spring` and `motionBlur`). Never the sequence, the screens, the zoom blocks, the camera, the
    /// sound, the aspect nor the frame rate. The blocks are not planned again here: that is `ZoomCommands.regenerate`.
    /// An image background names `assets/<sha>.<ext>`: the caller copies it into the package first (`importAsset` of
    /// `Style/<sha>.<ext>`, which gives the same path). `nil` if the document has all of it already.
    public static func applyDefaultStyle(_ doc: EditDocument, _ style: DefaultStyle) -> EditStep? {
        var stage = style.style
        stage.screenSampling = .mipmapped
        stage.geometryTransition = .spring
        var changes = DocumentChanges()
        changes.set(["style"], from: doc.style, to: stage)
        changes.set(["cursor"], from: doc.cursor, to: style.cursor)
        changes.set(["zoom", "show"], from: doc.zoom.show, to: style.zoomShow)
        changes.set(["zoom", "auto"], from: doc.zoom.auto, to: style.zoomAuto)
        changes.set(["zoom", "spring"], from: doc.zoom.spring, to: style.zoomSpring)
        changes.set(["zoom", "motionBlur"], from: doc.zoom.motionBlur, to: style.zoomMotionBlur)
        return changes.step(label: .applyDefaultStyle, target: "/style")
    }
}

// MARK: - What the commands share

/// The values of a document at a pointer, each read from the encoding of the top-level member it is in alone.
enum DocumentValues {
    /// The value at `path`; `nil` if it names nothing, the whole document, `documentVersion` or `logSequence`.
    static func value(at path: JSONPointer, in doc: EditDocument) -> JSONValue? {
        guard let member = path.components.first, var value = memberValue(member, of: doc) else { return nil }
        for component in path.components.dropFirst() {
            switch value {
            case let .object(members):
                guard let next = members[component] else { return nil }
                value = next
            case let .array(elements):
                // RFC 6901: digits only, without leading zeros.
                guard let index = Int(component), String(index) == component, elements.indices.contains(index) else { return nil }
                value = elements[index]
            default:
                return nil
            }
        }
        return value
    }

    private static func memberValue(_ name: String, of doc: EditDocument) -> JSONValue? {
        switch name {
        case "aspect": encoded(doc.aspect)
        case "frameRate": encoded(doc.frameRate)
        case "sequence": encoded(doc.sequence)
        case "screens": encoded(doc.screens)
        case "style": encoded(doc.style)
        case "cursor": encoded(doc.cursor)
        case "zoom": encoded(doc.zoom)
        case "camera": encoded(doc.camera)
        case "audio": encoded(doc.audio)
        default: nil
        }
    }

    /// `value` as the document encodes it; `nil` if it cannot be encoded (a number that is not finite).
    static func encoded(_ value: some Encodable) -> JSONValue? {
        try? JSONValue(encoding: value)
    }
}

/// The changes of a command, in order, each built from the values and the elements it touches. A value that cannot be
/// encoded (a number that is not finite) makes the whole command nothing (`step` is `nil`).
struct DocumentChanges {
    private(set) var changes: [EditChange] = []
    private var encodable = true

    /// The value at `path` goes from `before` to `after`; nothing if they are the same.
    mutating func set(_ path: [String], from before: some Encodable, to after: some Encodable) {
        guard let old = encoded(before), let new = encoded(after) else { return }
        if old != new { changes.append(.set(path: JSONPointer(components: path), before: old, after: new)) }
    }

    mutating func insert(_ element: some Encodable, into collection: EditCollection, at index: Int) {
        guard let value = encoded(element) else { return }
        changes.append(.insert(collection: Self.pointer(collection), index: index, value: value))
    }

    mutating func remove(_ element: some Encodable, from collection: EditCollection, at index: Int) {
        guard let value = encoded(element) else { return }
        changes.append(.remove(collection: Self.pointer(collection), index: index, value: value))
    }

    /// The element `id` of `collection` goes from `old` to `new`, which keeps its `id`; nothing if they are the same.
    mutating func replace(_ old: some Encodable, with new: some Encodable, in collection: EditCollection, id: String) {
        guard let before = encoded(old), let after = encoded(new) else { return }
        if before != after { changes.append(.replace(collection: Self.pointer(collection), id: id, before: before, after: after)) }
    }

    /// `collection` goes from `old` to `new`, by the elements' `id`: those of both are replaced where they differ, those
    /// only in `old` removed (from the last), those only in `new` inserted where `new` has them (from the first). When the
    /// elements of both are in the same order in each, the result is `new` exactly; otherwise it holds the same elements.
    mutating func edit<Element: Encodable>(
        _ collection: EditCollection, from old: [Element], to new: [Element], id: (Element) -> String
    ) {
        let oldIDs = Set(old.map(id)), newIDs = Set(new.map(id))
        let before = Dictionary(old.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        for element in new {
            if let previous = before[id(element)] { replace(previous, with: element, in: collection, id: id(element)) }
        }
        for (index, element) in old.enumerated().reversed() where !newIDs.contains(id(element)) {
            remove(element, from: collection, at: index)
        }
        for (index, element) in new.enumerated() where !oldIDs.contains(id(element)) {
            insert(element, into: collection, at: index)
        }
    }

    /// The step of these changes; `nil` without any, or if a value could not be encoded.
    func step(label: EditLabel, target: String) -> EditStep? {
        guard encodable, !changes.isEmpty else { return nil }
        return EditStep(label: label, target: target, changes: changes)
    }

    /// The step of these changes, for a command that always gives one: without changes when there is nothing to change or
    /// a value could not be encoded (`EditSession.perform` refuses it).
    func stepEvenIfEmpty(label: EditLabel, target: String) -> EditStep {
        EditStep(label: label, target: target, changes: encodable ? changes : [])
    }

    private mutating func encoded(_ value: some Encodable) -> JSONValue? {
        let json = DocumentValues.encoded(value)
        if json == nil { encodable = false }
        return json
    }

    private static func pointer(_ collection: EditCollection) -> JSONPointer {
        JSONPointer(components: collection.rawValue.split(separator: "/").map(String.init))
    }
}

/// New ids of the elements a command makes.
enum DocumentIDs {
    /// An id that none of `ids` is, which it joins: `makeID(prefix)`, which gives 8 random hex digits and so almost never
    /// one in use; if it gives only ids in use, the first free one counting from 1, in 8 hex digits.
    static func new(_ prefix: String, _ makeID: (String) -> String, avoiding ids: inout Set<String>) -> String {
        for _ in 0..<8 {
            let id = makeID(prefix)
            if ids.insert(id).inserted { return id }
        }
        var number = 0
        while true {
            number += 1
            let hex = String(number, radix: 16)
            let id = prefix + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
            if ids.insert(id).inserted { return id }
        }
    }
}
