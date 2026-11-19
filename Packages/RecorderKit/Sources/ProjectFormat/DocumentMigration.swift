// SPDX-License-Identifier: GPL-3.0-or-later

/// The migrations of the edit document from one `documentVersion` to the next, on its JSON (1c design §13.2, phase 2
/// design §8): pure functions, so the same document always migrates the same, wherever it is read.
///
/// Each one is a row of a table (plan decision 3): the places it adds, as JSON pointers (`*` standing for each member of
/// the object it is in), each with its value, frozen. From 1 to 2 it adds the camera's layouts and look; from 2 to 3 the
/// captions, the privacy blocks, the keys on screen and the new fields of the stage, the camera and the sound, all with
/// the values that draw and sound exactly what phase 1 did, and it changes nothing else. One algorithm migrates
/// (`migrate`), goes back (`reverted`) and tells what commutes with a migration (`touchesAddedFields`) for every row.
///
/// Both are *additive*: every place the older version writes still exists, with the same meaning, so a change of the
/// older version commutes with the migration once it is carried through it (`carried(_:from:)`): one that writes a place
/// holding a place the migration adds (a whole `TrackGain`, the whole `style`) gets it in its values, at its frozen value.
/// Only a change that writes a place the migration adds, or under one, the whole document or `documentVersion` does not
/// (`touchesAddedFields`).
public enum DocumentMigration {
    /// The members the migration from version 1 adds to `camera`, in key order.
    public static let addedCameraFields = [
        "border", "layout", "layoutRules", "layouts", "mirror", "shadow", "sizeReference", "spring",
    ]

    /// The places each migration adds, by the version it migrates from, as JSON pointers: `*` stands for each member of
    /// the object it is in, or each element of the array (`/audio/tracks/*/cleanup`, the `cleanup` of every track).
    public static let addedPlaces: [Int: [String]] = migrations.mapValues { migration in
        migration.added.map { JSONPointer(components: $0.place).string }
    }

    /// One row of the table: what the migration from a version writes, and what the next version can hold that it
    /// cannot.
    private struct Migration: Sendable {
        /// Each place it adds, in order, and the value it writes there. Frozen, never taken from the defaults of the
        /// types, which a later version may change: a document migrates the same in every version of the app.
        let added: [(place: [String], value: JSONValue)]
        /// The places of the next version that are left out at their legacy value (an optional that is `nil`): a document
        /// that has one has no older version.
        let absent: [[String]]
        /// The values the next version can have at a place the older one has too, which the older one cannot: a
        /// document that has one has no older version. A later version that adds a case to a type of an older one (an
        /// aspect, a frame) adds it here.
        let newValues: [(place: [String], value: JSONValue)]
    }

    /// The migrations, by the version they migrate from: 1c design §13.2 and phase 2 design §8.
    private static let migrations: [Int: Migration] = [
        1: Migration(
            added: [
                (
                    ["camera", "border"],
                    .object(["color": .array([.integer(1), .integer(1), .integer(1), .integer(1)]), "width": .integer(0)])
                ),
                (["camera", "layout"], .object(["kind": .string("bubble")])),
                (["camera", "layoutRules"], .string("cameraLayout-1")),
                (["camera", "layouts"], .array([])),
                (["camera", "mirror"], .bool(false)),
                (["camera", "shadow"], .integer(0)),
                (["camera", "sizeReference"], .string("height")),
                (["camera", "spring"], .object(["damping": .number(0.95), "response": .number(0.5)])),
            ],
            absent: [], newValues: []),
        2: Migration(
            added: [
                (
                    ["captions"],
                    .object([
                        "show": .bool(false),
                        "style": .object([
                            "highlight": .bool(true),
                            // #FFD60A.
                            "highlightColor": .array([.integer(1), .number(214.0 / 255), .number(10.0 / 255), .integer(1)]),
                            "position": .string("bottom"), "preset": .string("bold"), "size": .string("medium"),
                            "uppercase": .bool(false),
                        ]),
                    ])
                ),
                (["keys"], .object(["mode": .string("off"), "position": .string("bottomCenter"), "size": .string("medium")])),
                (["privacy"], .object(["blocks": .array([])])),
                (["style", "reframe"], .string("fit")),
                (["camera", "background"], .string("original")),
                (
                    ["camera", "framing"],
                    .object(["center": .object(["x": .number(0.5), "y": .number(0.5)]), "mode": .string("center"), "zoom": .integer(1)])
                ),
                (["camera", "look"], .object(["intensity": .integer(1), "preset": .string("natural")])),
                (["camera", "syncOffset"], .integer(0)),
                (["audio", "normalize"], .bool(false)),
                (["audio", "tracks", "*", "cleanup"], .integer(0)),
            ],
            absent: [["transcript"]],
            newValues: [(["style", "frame", "type"], .string("device"))]),
    ]

    /// `json`, a document of `version`, in the next version: the places of `addedPlaces[version]` at their frozen values
    /// (over any value they already had) and `documentVersion` one more. Throws `invalidDocument` at `/documentVersion`
    /// from a version that has no migration or for a document that is not of `version`, and at the pointer of an object
    /// it writes in that is missing or is not an object (`/camera` from 1; `/style`, `/camera`, `/audio`, `/audio/tracks`
    /// or one of its members from 2).
    public static func migrate(_ json: JSONValue, from version: Int) throws(EditChangeError) -> JSONValue {
        guard let migration = migrations[version], case .object(let document) = json,
            document["documentVersion"] == .integer(Int64(version))
        else {
            throw .invalidDocument("/documentVersion")
        }
        var migrated = json
        for (place, value) in migration.added {
            try migrated.write(value, at: place[...], under: [])
        }
        migrated.setMember("documentVersion", to: .integer(Int64(version) + 1))
        return migrated
    }

    /// Whether the migration from `version` only adds places, at values that change nothing: from 1 and from 2.
    public static func isAdditive(from version: Int) -> Bool {
        migrations[version] != nil
    }

    /// Whether a `migrate` line from `from` to `to`, where the document is at `version`, is one the edit log goes through
    /// (1c design §13.2): to the next version, from the one the document is at, by an additive migration. The replay
    /// applies it there and goes on, and the undo history and the compaction keep the groups before it, carried through
    /// it (`carried(_:from:to:)`), unless a line before it `touchesAddedFields`. Any other `migrate` stops the replay and cuts the history, as every one did in 1b:
    /// one to the version the document is already at (`from: 1, to: 1`), one from a version it is not at (a `create` of
    /// version 2 followed by a `migrate` from 1) and one this app has no additive migration for.
    public static func follows(from: Int, to: Int, atVersion version: Int) -> Bool {
        to == from + 1 && from == version && isAdditive(from: from)
    }

    /// Whether `change`, a line written before the migration from `version`, does not commute with it even carried
    /// through it (`carried(_:from:)` is `nil`): it writes the whole document, `documentVersion`, a place the migration
    /// adds or one under it (from 1: one of `addedCameraFields` of `/camera`; from 2: `/captions`, `/style/reframe`,
    /// `/audio/tracks/<track>/cleanup`…), or a value that holds a place it adds where that place cannot be written (not an
    /// object on the way, or there already with another value). Then the `migrate` cuts the history before it, as in 1b.
    /// A change of a place that holds one the migration adds (`/camera`, `/style`, `/audio/tracks/<track>`) commutes,
    /// carried. Always `true` for a migration that is not additive, with which nothing is known to commute.
    public static func touchesAddedFields(_ change: EditChange, from version: Int) -> Bool {
        carried(change, from: version) == nil
    }

    /// `change`, a line written in `version`, as it is in the next version: what the migration from `version` does to
    /// the document it does to the values the change writes, so applying it after the migration gives the migrated
    /// document of applying it before. A value written at a place that holds a place the migration adds (a `set` of
    /// `/audio/tracks/<track>` from 2, or the elements of a collection that hold one) gets that place at its frozen value
    /// (`cleanup = 0`); a value of `null` (a member not there, plan decision 4) stays `null`; every other value stays as it
    /// is. `nil` when it does not commute (`touchesAddedFields`): from a version without an additive migration, for the
    /// whole document or `documentVersion`, a place the migration adds or one under it, and a value where the place
    /// cannot be written (not an object on the way, or there already with another value).
    ///
    /// The replay, `UndoHistory`, `LogCompaction` and the editor all carry the changes of before a `migrate` that keeps
    /// the history, so an undo or a redo after it applies them to the migrated document. The other way is never needed:
    /// a document is never "unmigrated", and a change is never applied to a version older than the one it was written in.
    public static func carried(_ change: EditChange, from version: Int) -> EditChange? {
        guard let migration = migrations[version] else { return nil }
        let place = change.place.components
        guard let first = place.first, first != "documentVersion" else { return nil }
        // A `set` writes its values at its path, the other changes theirs at an element of the collection.
        let written = if case .set = change { place } else { place + ["*"] }
        var carried = change
        for (added, frozen) in migration.added {
            switch relation(of: written, to: added) {
            case .apart:
                continue
            case .over:
                return nil
            case let .holding(rest):
                guard let next = carried.mappingValues({ $0.carrying(frozen, at: rest) }) else { return nil }
                carried = next
            }
        }
        return carried
    }

    /// `changes`, written in `version`, carried through each migration up to `target` (`carried(_:from:)`); themselves
    /// when `target` is `version`, `nil` if one of them does not commute with one of the migrations or `target` is older.
    public static func carried(_ changes: [EditChange], from version: Int, to target: Int) -> [EditChange]? {
        guard version <= target else { return nil }
        var changes = changes
        for from in version..<target {
            var next: [EditChange] = []
            next.reserveCapacity(changes.count)
            for change in changes {
                guard let carried = carried(change, from: from) else { return nil }
                next.append(carried)
            }
            changes = next
        }
        return changes
    }

    /// How the place a change writes its values at (`*` for an element of a collection) stands to a place a migration
    /// adds (`*` for each member or element).
    private enum Relation {
        /// Neither holds the other.
        case apart
        /// The change writes the added place, or under it, or the elements of a collection where the place is one of
        /// them.
        case over
        /// The change's values hold the added place, at `rest` under them.
        case holding(rest: ArraySlice<String>)
    }

    private static func relation(of written: [String], to added: [String]) -> Relation {
        for (component, place) in zip(written, added) where component != place {
            if place == "*", component != "*" { continue }
            return component == "*" ? .over : .apart
        }
        return written.count < added.count ? .holding(rest: added[written.count...]) : .over
    }

    /// `json`, a document, as it is in `version`: itself if it is of `version`; from a newer one, one version at a time
    /// down to `version`, each without the places its migration adds and with `documentVersion` one less, if each of them
    /// has the value the migration gives it and the document holds nothing that version has no place for (a
    /// transcription, a device frame, from 3 to 2). `nil` if any place is missing or has another value (the document uses
    /// what `version` cannot hold), for a version below 1, above the document's, or one this app has no migration down
    /// from, and for anything else.
    public static func reverted(_ json: JSONValue, to version: Int) -> JSONValue? {
        guard case .object(let document) = json, let written = document["documentVersion"] else { return nil }
        if written == .integer(Int64(version)) { return json }
        guard version >= 1, version < EditDocument.currentVersion,
            let from = (version..<EditDocument.currentVersion).last(where: { written == .integer(Int64($0) + 1) })
        else {
            return nil
        }
        var reverted = json
        for older in stride(from: from, through: version, by: -1) {
            guard let migration = migrations[older], let down = step(reverted, down: migration, to: older) else { return nil }
            reverted = down
        }
        return reverted
    }

    /// `json`, a document of `version + 1`, in `version`, the one `migration` migrates from: `nil` if it holds what that
    /// version cannot.
    private static func step(_ json: JSONValue, down migration: Migration, to version: Int) -> JSONValue? {
        for place in migration.absent where json.value(at: JSONPointer(components: place)) != nil {
            return nil
        }
        for (place, value) in migration.newValues where json.value(at: JSONPointer(components: place)) == value {
            return nil
        }
        var reverted = json
        for (place, value) in migration.added {
            guard reverted.remove(value, at: place[...]) else { return nil }
        }
        reverted.setMember("documentVersion", to: .integer(Int64(version)))
        return reverted
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

    /// This change with each value it writes or checks (`before`, `after`, `value`) through `transform`; `nil` if
    /// `transform` gives `nil` for one.
    fileprivate func mappingValues(_ transform: (JSONValue) -> JSONValue?) -> EditChange? {
        switch self {
        case let .set(path, before, after):
            guard let before = transform(before), let after = transform(after) else { return nil }
            return .set(path: path, before: before, after: after)
        case let .insert(collection, index, value):
            return transform(value).map { .insert(collection: collection, index: index, value: $0) }
        case let .remove(collection, index, value):
            return transform(value).map { .remove(collection: collection, index: index, value: $0) }
        case let .replace(collection, id, before, after):
            guard let before = transform(before), let after = transform(after) else { return nil }
            return .replace(collection: collection, id: id, before: before, after: after)
        }
    }
}

extension JSONValue {
    /// Writes `value` at `place` of this object, under `path` of the document: each object on the way must be there
    /// (`invalidDocument` at its pointer if it is missing or is not an object), and `*` writes under each member, or each
    /// element of an array.
    fileprivate mutating func write(
        _ value: JSONValue, at place: ArraySlice<String>, under path: [String]
    ) throws(EditChangeError) {
        guard let key = place.first else { return }
        let rest = place.dropFirst()
        if key == "*", !rest.isEmpty, case .array(var elements) = self {
            for index in elements.indices {
                try elements[index].write(value, at: rest, under: path + [String(index)])
            }
            self = .array(elements)
            return
        }
        guard case .object(var members) = self else { throw .invalidDocument(JSONPointer(components: path).string) }
        if rest.isEmpty {
            members[key] = value
        } else if key == "*" {
            for member in members.keys.sorted() {
                try members[member]?.write(value, at: rest, under: path + [member])
            }
        } else {
            guard var member = members[key] else { throw .invalidDocument(JSONPointer(components: path + [key]).string) }
            try member.write(value, at: rest, under: path + [key])
            members[key] = member
        }
        self = .object(members)
    }

    /// This object without the member `value` at `place` (`*` for each member or element on the way): `false`, and this
    /// value as it was, if one is missing or has another value.
    fileprivate mutating func remove(_ value: JSONValue, at place: ArraySlice<String>) -> Bool {
        guard let key = place.first else { return false }
        let rest = place.dropFirst()
        if key == "*", !rest.isEmpty, case .array(var elements) = self {
            for index in elements.indices {
                guard elements[index].remove(value, at: rest) else { return false }
            }
            self = .array(elements)
            return true
        }
        guard case .object(var members) = self else { return false }
        if rest.isEmpty {
            guard members.removeValue(forKey: key) == value else { return false }
        } else if key == "*" {
            for member in members.keys.sorted() {
                guard var element = members[member], element.remove(value, at: rest) else { return false }
                members[member] = element
            }
        } else {
            guard var member = members[key], member.remove(value, at: rest) else { return false }
            members[key] = member
        }
        self = .object(members)
        return true
    }

    /// This value, written by a change at a place that holds the place `rest` under it, with that place at `frozen`
    /// (`*` for each member or element): itself if it is `null` (a member not there); `nil` if an object on the way is
    /// missing or is not one, or the place is there already with another value.
    fileprivate func carrying(_ frozen: JSONValue, at rest: ArraySlice<String>) -> JSONValue? {
        guard self != .null, let key = rest.first else { return self }
        let next = rest.dropFirst()
        if key == "*", !next.isEmpty {
            switch self {
            case let .object(members):
                var carried: [String: JSONValue] = [:]
                for (name, member) in members {
                    guard let value = member.carrying(frozen, at: next) else { return nil }
                    carried[name] = value
                }
                return .object(carried)
            case let .array(elements):
                var carried: [JSONValue] = []
                carried.reserveCapacity(elements.count)
                for element in elements {
                    guard let value = element.carrying(frozen, at: next) else { return nil }
                    carried.append(value)
                }
                return .array(carried)
            default:
                return nil
            }
        }
        guard case .object(var members) = self else { return nil }
        if next.isEmpty {
            if let there = members[key], there != frozen { return nil }
            members[key] = frozen
        } else {
            guard let member = members[key], let carried = member.carrying(frozen, at: next) else { return nil }
            members[key] = carried
        }
        return .object(members)
    }

    /// Sets the member `key` of this object; nothing on anything else.
    fileprivate mutating func setMember(_ key: String, to value: JSONValue) {
        guard case .object(var members) = self else { return }
        members[key] = value
        self = .object(members)
    }
}
