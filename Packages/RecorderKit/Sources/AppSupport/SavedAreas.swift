// SPDX-License-Identifier: GPL-3.0-or-later

/// The areas the user saved ("Save Area"), the most recent first, each once.
public struct SavedAreas: Codable, Equatable, Sendable {
    /// No more are kept: the oldest goes.
    public static let limit = 8

    public private(set) var areas: [AreaChoice]

    /// `areas`, the most recent first, under the same rules: each once (where it is first), and at most `limit`.
    public init(areas: [AreaChoice] = []) {
        self.areas = []
        for area in areas.reversed() { remember(area) }
    }

    /// What was saved, under the same rules (`init(areas:)`), whatever another version wrote.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(areas: try container.decode([AreaChoice].self, forKey: .areas))
    }

    /// `area` is now the most recent: first, and not anywhere else.
    public mutating func remember(_ area: AreaChoice) {
        areas.removeAll { $0 == area }
        areas.insert(area, at: 0)
        if areas.count > Self.limit { areas.removeLast(areas.count - Self.limit) }
    }
}
