// SPDX-License-Identifier: GPL-3.0-or-later

/// The markers of the project (phase 3 design §8.3 and §10): `EditDocument.markers`. A marker recorded during the take
/// without an entry here is shown without a name; naming, moving or hiding it adds its entry, with `origin` `recorded`
/// and the same `take` and `t`. A value that is not one of these makes the document invalid, not newer.
public struct MarkerPlan: Codable, Equatable, Sendable {
    /// The markers (`EditCollection.markers`), in no particular order.
    public var items: [Marker]

    /// What a document of phases 1 and 2 has once migrated, and a new one: no entry.
    public static let legacy = MarkerPlan(items: [])

    public init(items: [Marker]) {
        self.items = items
    }
}

/// A marker at source time `t` of `take`: not shown when its stretch is cut.
public struct Marker: Codable, Equatable, Sendable {
    /// `m-` and 8 random hex digits.
    public var id: String
    public var take: String
    public var t: HostTime
    /// `""` has none.
    public var name: String
    public var origin: MarkerOrigin
    public var hidden: Bool

    public init(id: String, take: String, t: HostTime, name: String = "", origin: MarkerOrigin, hidden: Bool = false) {
        self.id = id
        self.take = take
        self.t = t
        self.name = name
        self.origin = origin
        self.hidden = hidden
    }
}

/// Who made a marker: the take (⌥⌘M, the island), or the user in the editor.
public enum MarkerOrigin: String, Codable, Sendable, CaseIterable {
    case recorded, added
}
