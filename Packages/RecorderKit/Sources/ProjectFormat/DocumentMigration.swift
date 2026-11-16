// SPDX-License-Identifier: GPL-3.0-or-later

/// The migrations of the edit document from one `documentVersion` to the next, on its JSON (1c design §13.2): pure
/// functions, so the same document always migrates the same, wherever it is read.
///
/// The only one is from 1 to 2, which adds the camera's layouts and look to `camera` with the values that draw exactly
/// what 1b drew, and changes nothing else. It is *additive*: every place 1b writes still exists, with the same meaning, so
/// a change of 1b gives the same document applied before or after it, unless it writes a place the migration adds or one
/// that holds one (`touchesAddedFields`).
public enum DocumentMigration {
    /// The members the migration from version 1 adds to `camera`, in key order.
    public static let addedCameraFields = [
        "border", "layout", "layoutRules", "layouts", "mirror", "shadow", "sizeReference", "spring",
    ]

    /// What the migration from version 1 writes in `camera` (1c design §13.2). Frozen, never taken from the defaults of
    /// `CameraPlan`, which a later version may change: a document migrates the same in every version of the app.
    private static let addedCameraValues: [String: JSONValue] = [
        "border": .object(["color": .array([.integer(1), .integer(1), .integer(1), .integer(1)]), "width": .integer(0)]),
        "layout": .object(["kind": .string("bubble")]),
        "layoutRules": .string("cameraLayout-1"),
        "layouts": .array([]),
        "mirror": .bool(false),
        "shadow": .integer(0),
        "sizeReference": .string("height"),
        "spring": .object(["damping": .number(0.95), "response": .number(0.5)]),
    ]

    /// `json`, a document of `version`, in the next version. From 1: `camera` with the members of `addedCameraFields` at
    /// the values of 1c design §13.2 (over any it already had) and `documentVersion` 2. Throws `invalidDocument` at
    /// `/documentVersion` from any other version or for a document that is not of `version`, and at `/camera` if it has
    /// no `camera` object.
    public static func migrate(_ json: JSONValue, from version: Int) throws(EditChangeError) -> JSONValue {
        guard version == 1, case var .object(document) = json, document["documentVersion"] == .integer(1) else {
            throw .invalidDocument("/documentVersion")
        }
        guard case var .object(camera)? = document["camera"] else { throw .invalidDocument("/camera") }
        camera.merge(addedCameraValues) { _, added in added }
        document["camera"] = .object(camera)
        document["documentVersion"] = .integer(2)
        return .object(document)
    }

    /// Whether the migration from `version` only adds places, at values that change nothing: from 1.
    public static func isAdditive(from version: Int) -> Bool {
        version == 1
    }

    /// Whether `change`, a line written before the migration from `version`, writes a place the migration adds or one that
    /// holds one (the whole document, `camera`, or anything under one of `addedCameraFields`): then it does not commute
    /// with the migration. Always `true` for a migration that is not additive, with which nothing is known to commute.
    public static func touchesAddedFields(_ change: EditChange, from version: Int) -> Bool {
        guard isAdditive(from: version) else { return true }
        let components = change.place.components
        guard let first = components.first else { return true }
        guard first == "camera" else { return false }
        return components.count == 1 || addedCameraFields.contains(components[1])
    }

    /// `json`, a document, as it is in `version`: itself if it is of `version`; from version 2 to 1, without the members
    /// the migration adds and with `documentVersion` 1, if each of them has the value the migration gives it (`nil` if
    /// any is missing or has another value: the document uses what version 1 cannot hold). `nil` for anything else.
    public static func reverted(_ json: JSONValue, to version: Int) -> JSONValue? {
        guard case var .object(document) = json else { return nil }
        if document["documentVersion"] == .integer(Int64(version)) { return json }
        guard version == 1, document["documentVersion"] == .integer(2), case var .object(camera)? = document["camera"] else {
            return nil
        }
        for (key, value) in addedCameraValues {
            guard camera.removeValue(forKey: key) == value else { return nil }
        }
        document["camera"] = .object(camera)
        document["documentVersion"] = .integer(1)
        return .object(document)
    }
}

extension EditChange {
    /// The place this change writes: the value of a `set`, the array of the others.
    fileprivate var place: JSONPointer {
        switch self {
        case let .set(path, _, _): path
        case let .insert(collection, _, _), let .remove(collection, _, _), let .replace(collection, _, _, _): collection
        }
    }
}
