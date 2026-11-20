// SPDX-License-Identifier: GPL-3.0-or-later

/// What the output draws over the take (phase 3 design §5.1 and §10): `EditDocument.annotations`. Drawn by
/// `annotation-1`. A value that is not one of these makes the document invalid, not newer.
public struct AnnotationPlan: Codable, Equatable, Sendable {
    /// The annotations (`EditCollection.annotations`), in no particular order: `layer` orders them.
    public var items: [Annotation]

    /// What a document of phases 1 and 2 has once migrated, and a new one: no annotation.
    public static let legacy = AnnotationPlan(items: [])

    public init(items: [Annotation]) {
        self.items = items
    }
}

/// One annotation: what it is (`kind`), where it is (`rect`, in the space of its `anchor`) and when (`anchor`).
public struct Annotation: Codable, Equatable, Sendable {
    /// `a-` and 8 random hex digits.
    public var id: String
    public var anchor: AnnotationAnchor
    /// Higher, on top; within the annotations of the take and within those of the output (§5.5).
    public var layer: Int
    public var kind: AnnotationKind
    /// Anchored to the take, in fractions of the stage's content rect; otherwise, of the output frame.
    public var rect: NormalizedRect
    /// Degrees, clockwise.
    public var rotation: Double
    /// 0 to 1.
    public var opacity: Double
    public var enter: AnnotationEnter
    public var exit: AnnotationExit

    public init(
        id: String, anchor: AnnotationAnchor, layer: Int, kind: AnnotationKind, rect: NormalizedRect, rotation: Double = 0,
        opacity: Double = 1, enter: AnnotationEnter = .fade, exit: AnnotationExit = .fade
    ) {
        self.id = id
        self.anchor = anchor
        self.layer = layer
        self.kind = kind
        self.rect = rect
        self.rotation = rotation
        self.opacity = opacity
        self.enter = enter
        self.exit = exit
    }
}

/// When an annotation is shown. Encoded flat with its `type`: `{"end":…,"start":…,"take":"take-001","type":"content"}`,
/// `{"end":…,"start":…,"type":"output"}` or `{"type":"whole"}`.
public enum AnnotationAnchor: Codable, Equatable, Sendable {
    /// Over the source times `[start, end)` of `take`, drawn inside the stage: it goes with the zoom, and with its stretch
    /// when it is cut.
    case content(take: String, start: HostTime, end: HostTime)
    /// Over the output times `[start, end)`, in ns, drawn over the output frame.
    case output(start: Int64, end: Int64)
    /// The whole video, over the output frame.
    case whole

    private enum CodingKeys: String, CodingKey {
        case type, take, start, end
    }

    private enum Kind: String, Codable {
        case content, output, whole
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .content:
            self = .content(
                take: try container.decode(String.self, forKey: .take), start: try container.decode(HostTime.self, forKey: .start),
                end: try container.decode(HostTime.self, forKey: .end))
        case .output:
            self = .output(start: try container.decode(Int64.self, forKey: .start), end: try container.decode(Int64.self, forKey: .end))
        case .whole:
            self = .whole
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .content(take, start, end):
            try container.encode(Kind.content, forKey: .type)
            try container.encode(take, forKey: .take)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case let .output(start, end):
            try container.encode(Kind.output, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .whole:
            try container.encode(Kind.whole, forKey: .type)
        }
    }
}

/// What an annotation is. Encoded flat: the members of its value next to its `type` (`"text"`, `"arrow"`, `"shape"`,
/// `"callout"`, `"step"`, `"image"` or `"clip"`), as `{"color":[…],"type":"step"}` or
/// `{"target":{…},"text":{…},"type":"callout"}`. None of the values has a member called `type`.
public enum AnnotationKind: Codable, Equatable, Sendable {
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)
    case shape(ShapeAnnotation)
    case callout(CalloutAnnotation)
    case step(StepAnnotation)
    case image(ImageAnnotation)
    /// Only anchored to the output or the whole video.
    case clip(ClipAnnotation)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum Kind: String, Codable {
        case text, arrow, shape, callout, step, image, clip
    }

    /// The value's members are read from the same object as `type`, which the value does not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try TextAnnotation(from: decoder))
        case .arrow: self = .arrow(try ArrowAnnotation(from: decoder))
        case .shape: self = .shape(try ShapeAnnotation(from: decoder))
        case .callout: self = .callout(try CalloutAnnotation(from: decoder))
        case .step: self = .step(try StepAnnotation(from: decoder))
        case .image: self = .image(try ImageAnnotation(from: decoder))
        case .clip: self = .clip(try ClipAnnotation(from: decoder))
        }
    }

    /// The value writes its members into the object and `type` joins them there.
    public func encode(to encoder: any Encoder) throws {
        let kind: Kind
        switch self {
        case let .text(value):
            kind = .text
            try value.encode(to: encoder)
        case let .arrow(value):
            kind = .arrow
            try value.encode(to: encoder)
        case let .shape(value):
            kind = .shape
            try value.encode(to: encoder)
        case let .callout(value):
            kind = .callout
            try value.encode(to: encoder)
        case let .step(value):
            kind = .step
            try value.encode(to: encoder)
        case let .image(value):
            kind = .image
            try value.encode(to: encoder)
        case let .clip(value):
            kind = .clip
            try value.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
    }
}

extension RGBA {
    /// #FF453A, the colour of a new arrow, shape or step.
    public static let annotationRed = RGBA(1, 69.0 / 255, 58.0 / 255, 1)
}

/// A text (§5.1): in one of four styles, with its font, weight, size, colour, background and alignment.
public struct TextAnnotation: Codable, Equatable, Sendable {
    public var string: String
    public var preset: TextPreset
    public var font: TextFont
    public var weight: TextWeight
    /// A fraction of the height of its space (the stage's content, or the output frame).
    public var size: Double
    public var color: RGBA
    /// What is behind the text; `nil` draws nothing, and is left out of the JSON.
    public var fill: RGBA?
    public var align: TextAlign

    /// The background a new text of `preset` has: black at 70 % for a label and a lower third, none for the others.
    public static func defaultFill(for preset: TextPreset) -> RGBA? {
        switch preset {
        case .label, .lowerThird: RGBA(0, 0, 0, 0.7)
        case .plain, .title: nil
        }
    }

    public init(
        string: String, preset: TextPreset, font: TextFont = .system, weight: TextWeight = .semibold, size: Double = 0.05,
        color: RGBA = RGBA(1, 1, 1, 1), fill: RGBA?, align: TextAlign = .center
    ) {
        self.string = string
        self.preset = preset
        self.font = font
        self.weight = weight
        self.size = size
        self.color = color
        self.fill = fill
        self.align = align
    }

    /// A text with the background of its preset (`defaultFill(for:)`).
    public init(
        string: String, preset: TextPreset, font: TextFont = .system, weight: TextWeight = .semibold, size: Double = 0.05,
        color: RGBA = RGBA(1, 1, 1, 1), align: TextAlign = .center
    ) {
        self.init(
            string: string, preset: preset, font: font, weight: weight, size: size, color: color, fill: Self.defaultFill(for: preset),
            align: align)
    }
}

/// The four styles of a text: Plain, Label, Lower third and Title.
public enum TextPreset: String, Codable, Sendable, CaseIterable {
    case plain, label, lowerThird, title
}

public enum TextFont: String, Codable, Sendable, CaseIterable {
    case system, rounded, serif, mono
}

public enum TextWeight: String, Codable, Sendable, CaseIterable {
    case regular, semibold, bold, heavy
}

public enum TextAlign: String, Codable, Sendable, CaseIterable {
    case leading, center, trailing
}

/// An arrow from `from` to `to`, straight or curved; its `Annotation.rect` comes from its ends.
public struct ArrowAnnotation: Codable, Equatable, Sendable {
    /// In the space of its anchor, as the rect.
    public var from: NormalizedPoint
    public var to: NormalizedPoint
    /// −1 to 1: how much it bends, to one side or the other; 0 is straight.
    public var curve: Double
    public var color: RGBA
    /// A fraction of the height of its space.
    public var width: Double
    public var head: ArrowHead

    public init(
        from: NormalizedPoint, to: NormalizedPoint, curve: Double = 0, color: RGBA = .annotationRed, width: Double = 0.006,
        head: ArrowHead
    ) {
        self.from = from
        self.to = to
        self.curve = curve
        self.color = color
        self.width = width
        self.head = head
    }
}

public enum ArrowHead: String, Codable, Sendable, CaseIterable {
    case filled, open, none
}

/// A shape that fills its rect: its border and, optionally, its inside.
public struct ShapeAnnotation: Codable, Equatable, Sendable {
    public var shape: AnnotationShape
    public var stroke: RGBA
    /// The border's width, a fraction of the height of its space.
    public var width: Double
    /// `nil` leaves the inside empty, and is left out of the JSON.
    public var fill: RGBA?

    public init(shape: AnnotationShape, stroke: RGBA = .annotationRed, width: Double = 0.004, fill: RGBA? = nil) {
        self.shape = shape
        self.stroke = stroke
        self.width = width
        self.fill = fill
    }
}

public enum AnnotationShape: String, Codable, Sendable, CaseIterable {
    case rect, roundedRect, ellipse
}

/// A text with a tail that points at `target`.
public struct CalloutAnnotation: Codable, Equatable, Sendable {
    public var text: TextAnnotation
    /// In the space of its anchor, as the rect.
    public var target: NormalizedPoint

    public init(text: TextAnnotation, target: NormalizedPoint) {
        self.text = text
        self.target = target
    }
}

/// A number in a circle; the number comes from the order of the steps in the sequence.
public struct StepAnnotation: Codable, Equatable, Sendable {
    public var color: RGBA

    public init(color: RGBA = .annotationRed) {
        self.color = color
    }
}

/// An image of `assets/` (§5.4).
public struct ImageAnnotation: Codable, Equatable, Sendable {
    /// Its path from the package root, `assets/<32 hex>.<ext>`.
    public var asset: String
    public var fit: ImageFit
    /// The radius of its corners, a fraction of the shorter side of its box: 0 to 0.5 (plan 3a decision 4).
    public var corner: Double
    public var shadow: Bool

    public init(asset: String, fit: ImageFit, corner: Double = 0, shadow: Bool = false) {
        self.asset = asset
        self.fit = fit
        self.corner = corner
        self.shadow = shadow
    }
}

/// How an image or a clip fills its rect: whole inside it, or covering it.
public enum ImageFit: String, Codable, Sendable, CaseIterable {
    case fit, fill
}

/// A stretch of an imported video drawn over the output (§5.4), with its sound; it does not repeat.
public struct ClipAnnotation: Codable, Equatable, Sendable {
    /// Its path from the package root, `assets/<32 hex>.<mov|mp4|m4v>`.
    public var asset: String
    /// Nanoseconds of the file.
    public var start: Int64
    /// Excluded.
    public var end: Int64
    /// Its sound's gain, in dB.
    public var volume: Double
    public var muted: Bool
    /// The radius of its corners, a fraction of the shorter side of its box: 0 to 0.5 (plan 3a decision 4).
    public var corner: Double
    public var shadow: Bool

    public init(
        asset: String, start: Int64, end: Int64, volume: Double = 0, muted: Bool = false, corner: Double = 0, shadow: Bool = false
    ) {
        self.asset = asset
        self.start = start
        self.end = end
        self.volume = volume
        self.muted = muted
        self.corner = corner
        self.shadow = shadow
    }
}

/// How an annotation comes in: not at all, fading, popping (from 0.9 to 1 with the critical spring) or, for an arrow or a
/// shape, being drawn.
public enum AnnotationEnter: String, Codable, Sendable, CaseIterable {
    case none, fade, pop, draw
}

/// How an annotation goes away: not at all, or fading.
public enum AnnotationExit: String, Codable, Sendable, CaseIterable {
    case none, fade
}
