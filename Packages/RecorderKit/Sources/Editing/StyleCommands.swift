// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The commands of the panel's style values (design §5.4) and of the Project menu (§5.1), as pure functions of the
/// document: each gives the step that does it (`EditStep`), or `nil` when the value is what the document has already.
///
/// The changes are built from the values they touch, never from the whole document encoded again: a `set` reads what it
/// replaces from the encoding of the document's top-level member it names (`/style`, `/cursor`, `/zoom`…) alone.
public enum StyleCommands {
    /// The frame rates of the Project menu: `EditDocument.frameRates`.
    public static let frameRates = EditDocument.frameRates

    /// The values `set` changes: the panel's style values, whose every value draws (design §5.4). What has a rule of its
    /// own goes through its command instead: the clips, the blocks and the changes of the tracks (their ranges, their ids,
    /// "touching an automatic one makes it the user's"), the automatic zoom's settings (planned again:
    /// `ZoomCommands.regenerate`), the camera's styles (`TrackCommands`), the screens, the aspect and the frame rate.
    static let styleValues: [[String]] = [
        ["style"], ["cursor"], ["zoom", "show"], ["zoom", "spring"], ["zoom", "motionBlur"], ["camera", "show"], ["audio"],
    ]

    /// Sets the style value at `pointer` (`/style/padding`, `/cursor/scale`, `/audio/tracks/take-001~1mic/gain`…) to
    /// `value`, as the step `label` with the pointer as its target, so a burst of steps on one control is one undo
    /// (design §6.4). `nil` for a pointer outside `styleValues`, one that names nothing in the document (an optional value
    /// that is not there: one is added or taken away with its parent's `set`), if `value` is what is there or cannot be
    /// encoded.
    public static func set(_ doc: EditDocument, _ pointer: String, _ value: some Encodable, label: EditLabel) -> EditStep? {
        guard let path = try? JSONPointer(pointer),
            styleValues.contains(where: { path.components.starts(with: $0) })
        else { return nil }
        return setting(doc, path, value, label: label)
    }

    /// The shape of the output (design §5.2): the stage rearranges itself, and the zooms, kept in the screen's
    /// coordinates, still hold.
    public static func setAspect(_ doc: EditDocument, _ aspect: Aspect) -> EditStep? {
        setting(doc, JSONPointer(components: ["aspect"]), aspect, label: .aspect)
    }

    /// The project's frame rate, one of `frameRates`; `nil` for any other.
    public static func setFrameRate(_ doc: EditDocument, _ fps: Int) -> EditStep? {
        guard frameRates.contains(fps) else { return nil }
        return setting(doc, JSONPointer(components: ["frameRate"]), fps, label: .frameRate)
    }

    /// The `set` of the value at `path` to `value`; `nil` if the path names nothing, or the value is what is there or
    /// cannot be encoded.
    private static func setting(_ doc: EditDocument, _ path: JSONPointer, _ value: some Encodable, label: EditLabel) -> EditStep? {
        guard let before = DocumentValues.value(at: path, in: doc), let after = try? JSONValue(encoding: value), after != before
        else { return nil }
        return EditStep(label: label, target: path.string, changes: [.set(path: path, before: before, after: after)])
    }

    /// "Apply Default Style" (design §5.4 and §5.9), one step, as a new document of `take` would have it (`NewDocument`):
    /// the stage of `style`, with mipmapped sampling and the spring between shapes; its whole cursor, drawn from the
    /// recorded images if `events` has a `cursorImage` and as Toma's arrow if not; the zoom's settings (`show`, `auto`,
    /// `spring` and `motionBlur`); and, as with any change of the automatic zoom's settings (design §5.4), the automatic
    /// blocks of `take` that were not touched planned again for the document so styled (`ZoomCommands.replanned`). Never
    /// the sequence, the screens, the user's blocks, the camera, the sound, the aspect nor the frame rate.
    ///
    /// The background is `style`'s as it is: an image one must be in the package already (`EditSession.applyDefaultStyle`
    /// brings it from the style's folder, or falls back to the classic gradient). `nil` if the document has all of it
    /// already, or a value cannot be encoded.
    public static func applyDefaultStyle(
        _ doc: EditDocument, _ style: DefaultStyle, take: TakeRecord, events: [InputEvent]
    ) -> EditStep? {
        var styled = doc
        styled.style = style.style
        styled.style.screenSampling = .mipmapped
        styled.style.geometryTransition = .spring
        styled.cursor = style.cursor
        let recordedImages = events.contains { if case .cursorImage = $0.kind { true } else { false } }
        styled.cursor.style = recordedImages ? .system : .toma
        styled.zoom.show = style.zoomShow
        styled.zoom.auto = style.zoomAuto
        styled.zoom.spring = style.zoomSpring
        styled.zoom.motionBlur = style.zoomMotionBlur
        var changes = DocumentChanges()
        changes.set(["style"], from: doc.style, to: styled.style)
        changes.set(["cursor"], from: doc.cursor, to: styled.cursor)
        changes.set(["zoom", "show"], from: doc.zoom.show, to: styled.zoom.show)
        changes.set(["zoom", "auto"], from: doc.zoom.auto, to: styled.zoom.auto)
        changes.set(["zoom", "spring"], from: doc.zoom.spring, to: styled.zoom.spring)
        changes.set(["zoom", "motionBlur"], from: doc.zoom.motionBlur, to: styled.zoom.motionBlur)
        changes.edit(.zoomRegions, from: doc.zoom.regions, to: ZoomCommands.replanned(styled, take: take, events: events), id: \.id)
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
