// SPDX-License-Identifier: GPL-3.0-or-later

/// The music under the video (phase 3 design §7.4 to §7.6 and §10): `EditDocument.music`. Anchored to the output: cuts
/// never move it. A value that is not one of these makes the document invalid, not newer.
public struct MusicPlan: Codable, Equatable, Sendable {
    /// The pieces (`EditCollection.music`), never overlapping.
    public var items: [MusicItem]
    /// How the music goes down while someone speaks (`ducking-1`).
    public var ducking: Ducking

    /// What a document of phases 1 and 2 has once migrated, and a new one: no music, the default ducking.
    public static let legacy = MusicPlan(items: [], ducking: .default)

    public init(items: [MusicItem], ducking: Ducking = .default) {
        self.items = items
        self.ducking = ducking
    }
}

/// A piece of music over the output times `[start, end)`.
public struct MusicItem: Codable, Equatable, Sendable {
    /// `mu-` and 8 random hex digits.
    public var id: String
    /// `library:music-1/<id>` for a piece of Toma's library, or its path from the package root, `assets/<32 hex>.<ext>`.
    public var source: String
    /// Nanoseconds of output.
    public var start: Int64
    /// Excluded.
    public var end: Int64
    /// Where in the piece it starts, in ns.
    public var offset: Int64
    /// In dB.
    public var gain: Double
    /// In ns.
    public var fadeIn: Int64
    /// In ns.
    public var fadeOut: Int64
    /// Whether it starts again when the piece ends.
    public var loop: Bool

    public init(
        id: String, source: String, start: Int64, end: Int64, offset: Int64 = 0, gain: Double = -14, fadeIn: Int64 = 1_000_000_000,
        fadeOut: Int64 = 2_000_000_000, loop: Bool = true
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.offset = offset
        self.gain = gain
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.loop = loop
    }
}

/// How the music goes down while someone speaks (§7.5).
public struct Ducking: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// In dB.
    public var amount: Double
    /// In seconds.
    public var attack: Double
    /// In seconds.
    public var release: Double

    /// On, −12 dB, an attack of 0.3 s and a release of 0.8 s.
    public static let `default` = Ducking()

    public init(enabled: Bool = true, amount: Double = -12, attack: Double = 0.3, release: Double = 0.8) {
        self.enabled = enabled
        self.amount = amount
        self.attack = attack
        self.release = release
    }
}
