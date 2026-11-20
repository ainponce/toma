// SPDX-License-Identifier: GPL-3.0-or-later

/// What a clip of the sequence shows instead of a stretch of its take (phase 3 design §5.2, §5.3, §5.4 and §10):
/// `Clip.content`, `nil` for a stretch of the take. A clip with content is a point of its take (`start == end`, the
/// place it is at) that lasts in the output. Encoded flat with its `type`: `{"duration":2000000000,"type":"freeze"}`,
/// `{"card":{…},"duration":3000000000,"type":"card"}` or `{"media":{…},"type":"media"}`. A `type` that is not one of
/// these makes the document invalid, not newer.
public enum ClipContent: Codable, Equatable, Sendable {
    /// The frame of the take at the clip's point, still, for `duration` ns of output.
    case freeze(duration: Int64)
    /// A title card over the whole output frame, for `duration` ns of output (`titleCard-1`).
    case card(TitleCard, duration: Int64)
    /// A stretch of a video file of `assets/`, where the screens are drawn.
    case media(MediaClip)

    /// The duration of a new frozen frame: 2 s.
    public static let freezeDuration: Int64 = 2_000_000_000
    /// The duration of a new title card: 3 s.
    public static let cardDuration: Int64 = 3_000_000_000
    /// The durations a frozen frame or a title card can have: 0.1 to 60 s.
    public static let durationRange: ClosedRange<Int64> = 100_000_000...60_000_000_000

    private enum CodingKeys: String, CodingKey {
        case type, duration, card, media
    }

    private enum Kind: String, Codable {
        case freeze, card, media
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .freeze:
            self = .freeze(duration: try container.decode(Int64.self, forKey: .duration))
        case .card:
            self = .card(
                try container.decode(TitleCard.self, forKey: .card), duration: try container.decode(Int64.self, forKey: .duration))
        case .media:
            self = .media(try container.decode(MediaClip.self, forKey: .media))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .freeze(duration):
            try container.encode(Kind.freeze, forKey: .type)
            try container.encode(duration, forKey: .duration)
        case let .card(card, duration):
            try container.encode(Kind.card, forKey: .type)
            try container.encode(card, forKey: .card)
            try container.encode(duration, forKey: .duration)
        case let .media(media):
            try container.encode(Kind.media, forKey: .type)
            try container.encode(media, forKey: .media)
        }
    }
}

/// A title card (phase 3 design §5.2): a title and a subtitle over a background, in one of four styles.
public struct TitleCard: Codable, Equatable, Sendable {
    public var title: String
    /// `""` draws none.
    public var subtitle: String
    public var style: TitleCardStyle
    public var background: TitleCardBackground
    /// sRGB from 0 to 1, written to the output as it is.
    public var textColor: RGBA

    public init(
        title: String, subtitle: String = "", style: TitleCardStyle, background: TitleCardBackground, textColor: RGBA = RGBA(1, 1, 1, 1)
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.background = background
        self.textColor = textColor
    }
}

/// How a title card lays out its texts: centred, to the left, large or minimal.
public enum TitleCardStyle: String, Codable, Sendable, CaseIterable {
    case centered, leading, large, minimal
}

/// What is behind a title card. Encoded flat with its `type`: `{"type":"stage"}`, `{"color":[r,g,b,a],"type":"color"}`
/// or `{"type":"blurredFrame"}`.
public enum TitleCardBackground: Codable, Equatable, Sendable {
    /// The project's background (`StageStyle.background`).
    case stage
    case color(RGBA)
    /// The frame of the take at the card's point, blurred.
    case blurredFrame

    private enum CodingKeys: String, CodingKey {
        case type, color
    }

    private enum Kind: String, Codable {
        case stage, color, blurredFrame
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .stage: self = .stage
        case .color: self = .color(try container.decode(RGBA.self, forKey: .color))
        case .blurredFrame: self = .blurredFrame
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stage:
            try container.encode(Kind.stage, forKey: .type)
        case let .color(color):
            try container.encode(Kind.color, forKey: .type)
            try container.encode(color, forKey: .color)
        case .blurredFrame:
            try container.encode(Kind.blurredFrame, forKey: .type)
        }
    }
}

/// A stretch of an imported video (phase 3 design §5.4): the file's times `[start, end)` played at `speed`.
public struct MediaClip: Codable, Equatable, Sendable {
    /// Its path from the package root, `assets/<32 hex>.<mov|mp4|m4v>`.
    public var asset: String
    /// Nanoseconds of the file.
    public var start: Int64
    /// Excluded.
    public var end: Int64
    /// Read through `ClipSpeed.clamped(_:)`, as a clip's.
    public var speed: Double
    /// Its sound's gain, in dB.
    public var volume: Double

    public init(asset: String, start: Int64, end: Int64, speed: Double = 1, volume: Double = 0) {
        self.asset = asset
        self.start = start
        self.end = end
        self.speed = speed
        self.volume = volume
    }
}
