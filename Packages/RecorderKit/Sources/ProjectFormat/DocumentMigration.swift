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

    /// Whether a `migrate` line from `from` to `to`, where the document is at `version`, is one the edit log goes through
    /// (1c design §13.2): to the next version, from the one the document is at, by an additive migration. The replay
    /// applies it there and goes on, and the undo history and the compaction keep the groups before it, unless a line
    /// before it `touchesAddedFields`. Any other `migrate` stops the replay and cuts the history, as every one did in 1b:
    /// one to the version the document is already at (`from: 1, to: 1`), one from a version it is not at (a `create` of
    /// version 2 followed by a `migrate` from 1) and one this app has no additive migration for.
    public static func follows(from: Int, to: Int, atVersion version: Int) -> Bool {
        to == from + 1 && from == version && isAdditive(from: from)
    }

    /// Whether `change`, a line written before the migration from `version`, writes a place the migration reads or adds,
    /// or one that holds one (the whole document, `documentVersion`, `camera`, or anything under one of
    /// `addedCameraFields`): then it does not commute with the migration. Always `true` for a migration that is not
    /// additive, with which nothing is known to commute.
    public static func touchesAddedFields(_ change: EditChange, from version: Int) -> Bool {
        guard isAdditive(from: version) else { return true }
        let components = change.place.components
        guard let first = components.first else { return true }
        if first == "documentVersion" { return true }
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

extension DocumentMigration {
    /// The `documentVersion` of a document along the lines of its edit log, and what each `migrate` does to the history
    /// before it (1c design §13.2). The replay, `UndoHistory` and `LogCompaction` all walk a log with it, so a group the
    /// history keeps across a `migrate` is one the replay can undo there, and one it cuts is one the replay refuses.
    public struct LogWalk: Equatable, Sendable {
        /// The version the document is at after the lines walked: the `create`'s, raised by each `migrate` that follows.
        public private(set) var version: Int
        /// The `from` of each migration some `do` line walked writes inside of (`touchesAddedFields`).
        private var touched: Set<Int> = []

        /// A log whose `create` holds a document written in `createVersion`.
        public init(createVersion: Int) {
            version = createVersion
        }

        /// Whether a `migrate` from `from` to `to` follows where the walk is (`follows(from:to:atVersion:)`).
        public func follows(from: Int, to: Int) -> Bool {
            DocumentMigration.follows(from: from, to: to, atVersion: version)
        }

        /// Walks a `do` line, whatever its group: the migrations still ahead of it that one of its `changes` does not
        /// commute with are noted, for each `migrate` to come.
        public mutating func walkDo(_ changes: [EditChange]) {
            for from in stride(from: version, to: EditDocument.currentVersion, by: 1) where !touched.contains(from) {
                if changes.contains(where: { touchesAddedFields($0, from: from) }) {
                    touched.insert(from)
                }
            }
        }

        /// Walks a `migrate` line and says whether the groups before it are kept: it follows, and no `do` line before it
        /// writes inside of what it adds. One that follows takes `version` to `to` either way (the replay migrates there
        /// and goes on); one that does not leaves it, since the replay stops there.
        public mutating func walkMigrate(from: Int, to: Int) -> Bool {
            guard follows(from: from, to: to) else { return false }
            version = to
            return !touched.contains(from)
        }
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
