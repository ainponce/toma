// SPDX-License-Identifier: GPL-3.0-or-later

/// How the camera and the screen share the output (1c design §5.1). The project has one layout (`CameraPlan.layout`),
/// and each block of `CameraPlan.layouts` has its own over its source times. A value that is not one of these makes the
/// document invalid, not newer: a new layout comes with a new `documentVersion`.
public enum LayoutKind: String, Codable, Sendable, CaseIterable {
    /// The camera in its bubble, over the screen: as in 1b.
    case bubble
    /// The screen without the camera.
    case screenOnly
    /// The screen and the camera side by side (wide outputs) or one above the other (square and tall ones), each in its
    /// card.
    case split
    /// The camera where the screen would be, on the background, without the screen.
    case cameraOnly
    /// The camera filling the output from edge to edge.
    case cameraFull
}

/// Where the camera goes in a split.
public enum CameraSide: String, Codable, Sendable {
    /// First: on the left, or above.
    case start
    /// Second: on the right, or below.
    case end
}

/// The settings of a split. Written the first time a block, or the project, becomes a split, and never removed: a block
/// that goes back to the bubble and then to a split again finds them as they were.
public struct SplitLayout: Codable, Equatable, Sendable {
    public var side: CameraSide
    /// The camera's part of the length along the split, in `shareRange`; without it, the automatic part (1c design
    /// §5.2), which gives the screen what it needs to be seen whole.
    public var share: Double?

    /// The parts the camera can be given.
    public static let shareRange: ClosedRange<Double> = 0.25...0.60

    public init(side: CameraSide = .end, share: Double? = nil) {
        self.side = side
        self.share = share
    }
}

/// The settings of a bubble block: its own style, copied once, when the block first becomes a bubble, from the style that
/// rules the take's bubble at its start, and never removed.
public struct BubbleLayout: Codable, Equatable, Sendable {
    public var style: CameraStyle

    public init(style: CameraStyle) {
        self.style = style
    }
}

/// The project's layout, the one outside the blocks. Its bubble is always the take's (`CameraPlan.initial` and
/// `changes`), so it has no `bubble` settings; it keeps its `split` as a block does.
public struct CameraLayout: Codable, Equatable, Sendable {
    public var kind: LayoutKind
    public var split: SplitLayout?

    /// The bubble, without settings: every project's layout until the user picks another one.
    public static let bubble = CameraLayout(kind: .bubble)

    public init(kind: LayoutKind, split: SplitLayout? = nil) {
        self.kind = kind
        self.split = split
    }
}

/// A block of the camera track: over the source times `[start, end)` of `take`, the layout `kind` rules instead of the
/// project's. Blocks of a take are in order and never overlap. Each one keeps the settings of every layout it has been
/// (`bubble`, `split`), whatever its `kind` now; a block whose `kind` is `bubble` always has its `bubble`, and decoding
/// one without it throws.
public struct LayoutBlock: Codable, Equatable, Sendable {
    /// `l-` and 8 random hex digits.
    public var id: String
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    public var kind: LayoutKind
    /// Whether the layout jumps at the block's edges instead of blending with the spring.
    public var instant: Bool
    public var bubble: BubbleLayout?
    public var split: SplitLayout?

    public init(
        id: String, take: String, start: HostTime, end: HostTime, kind: LayoutKind, instant: Bool, bubble: BubbleLayout? = nil,
        split: SplitLayout? = nil
    ) {
        self.id = id
        self.take = take
        self.start = start
        self.end = end
        self.kind = kind
        self.instant = instant
        self.bubble = bubble
        self.split = split
    }

    private enum CodingKeys: String, CodingKey {
        case id, take, start, end, kind, instant, bubble, split
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(LayoutKind.self, forKey: .kind)
        let bubble = try container.decodeIfPresent(BubbleLayout.self, forKey: .bubble)
        guard kind != .bubble || bubble != nil else {
            throw DecodingError.keyNotFound(
                CodingKeys.bubble,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "A bubble block has its own style."))
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            take: try container.decode(String.self, forKey: .take),
            start: try container.decode(HostTime.self, forKey: .start),
            end: try container.decode(HostTime.self, forKey: .end),
            kind: kind,
            instant: try container.decode(Bool.self, forKey: .instant),
            bubble: bubble,
            split: try container.decodeIfPresent(SplitLayout.self, forKey: .split))
    }
}

/// The border drawn inside the camera's rounded rect.
public struct CameraBorder: Codable, Equatable, Sendable {
    /// 0 to 1: the border is `width × widthFactor ×` the output's short side wide (1c design §14.3).
    public var width: Double
    /// sRGB from 0 to 1, written to the output as it is, like the background's colours.
    public var color: RGBA

    /// No border: 0 wide, white.
    public static let none = CameraBorder(width: 0, color: RGBA(1, 1, 1, 1))
    /// The width of a border of `width` 1, as a fraction of the output's short side.
    public static let widthFactor = 0.012

    public init(width: Double, color: RGBA) {
        self.width = width
        self.color = color
    }
}

/// What the bubble's size, margin and corners are measured against.
public enum SizeReference: String, Codable, Sendable {
    /// The output's height, as in 1a and 1b.
    case height
    /// The output's short side, so a Medium bubble looks the same in every aspect: new projects from 1c on.
    case shortSide
}

/// The rules of the layouts' geometry, transitions and zoom in a card (1c design §5.2 to §5.4), a look defined in code:
/// its id is written in the document (`CameraPlan.layoutRules`) and frozen.
public enum CameraLayoutRules {
    public static let id = "cameraLayout-1"
    /// The spring of the transitions between layouts: the bubble's shape and size spring.
    public static let spring = SpringSpec(damping: 0.95, response: 0.5)
}
