// SPDX-License-Identifier: GPL-3.0-or-later

/// What the output hides of the screen (phase 2 design §7.1 and §7.2): `EditDocument.privacy`. A value that is not one of
/// these makes the document invalid, not newer.
public struct PrivacyPlan: Codable, Equatable, Sendable {
    /// The blocks (`EditCollection.privacyBlocks`), in no particular order; they may overlap.
    public var blocks: [PrivacyBlock]

    /// What a document of phase 1 has once migrated, and a new one: no block.
    public static let legacy = PrivacyPlan(blocks: [])

    public init(blocks: [PrivacyBlock]) {
        self.blocks = blocks
    }
}

/// Over the source times `[start, end)` of `take`, a rect of the screen's content hidden by `effect`.
public struct PrivacyBlock: Codable, Equatable, Sendable {
    /// `p-` and 8 random hex digits.
    public var id: String
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    public var effect: PrivacyEffect
    /// 0 to 1: how much `blur` and `pixelate` hide.
    public var strength: Double
    /// The colour of `fill`: sRGB from 0 to 1, written to the output as it is.
    public var color: RGBA
    /// Where it is, in fractions of the screen's content; with `keys`, where it is before the first one.
    public var rect: NormalizedRect
    /// Where it moves, for the automatic blocks: the rect at each time, in time order; `[]` keeps `rect` all along.
    public var keys: [RectKey]
    /// Who made it: the user, or the scan of sensitive data and what it found.
    public var origin: PrivacyOrigin

    public init(
        id: String, take: String, start: HostTime, end: HostTime, effect: PrivacyEffect, strength: Double = 0.6,
        color: RGBA = RGBA(0, 0, 0, 1), rect: NormalizedRect, keys: [RectKey] = [], origin: PrivacyOrigin = .manual
    ) {
        self.id = id
        self.take = take
        self.start = start
        self.end = end
        self.effect = effect
        self.strength = strength
        self.color = color
        self.rect = rect
        self.keys = keys
        self.origin = origin
    }
}

public enum PrivacyEffect: String, Codable, Sendable, CaseIterable {
    case blur, pixelate, fill
}

/// Who made a privacy block: the user by hand, or the scan of sensitive data, by what it found (`sensitiveScan-1`).
public enum PrivacyOrigin: String, Codable, Sendable, CaseIterable {
    case manual, email, phone, card, secret, face
}

/// At source time `t`, the block's rect is `rect`.
public struct RectKey: Codable, Equatable, Sendable {
    public var t: HostTime
    public var rect: NormalizedRect

    public init(t: HostTime, rect: NormalizedRect) {
        self.t = t
        self.rect = rect
    }
}

/// A rect in fractions of something (the screen's content), each from 0 to 1: its top left corner and its size, with y
/// going down.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// The whole of it.
    public static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
