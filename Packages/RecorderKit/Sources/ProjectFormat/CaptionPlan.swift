// SPDX-License-Identifier: GPL-3.0-or-later

/// The captions drawn from the transcription (phase 2 design §5.2): whether they show and how they look.
/// `EditDocument.captions`; a value that is not one of these makes the document invalid, not newer.
public struct CaptionPlan: Codable, Equatable, Sendable {
    public var show: Bool
    public var style: CaptionStyle

    /// What a document of phase 1 has once migrated, and a new one: hidden, in the default style.
    public static let legacy = CaptionPlan(show: false, style: .default)

    public init(show: Bool, style: CaptionStyle) {
        self.show = show
        self.style = style
    }
}

/// How the captions look. The look of each preset is defined in code (`captionStyle-1`).
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var preset: CaptionPreset
    public var size: OverlaySize
    public var position: CaptionPosition
    public var uppercase: Bool
    /// Whether the word being spoken is drawn in `highlightColor`.
    public var highlight: Bool
    /// sRGB from 0 to 1, written to the output as it is, like the background's colours.
    public var highlightColor: RGBA

    /// Bold, medium, at the bottom, as written, with the spoken word in yellow (#FFD60A).
    public static let `default` = CaptionStyle(
        preset: .bold, size: .medium, position: .bottom, uppercase: false, highlight: true,
        highlightColor: RGBA(1, 214.0 / 255, 10.0 / 255, 1))

    public init(
        preset: CaptionPreset, size: OverlaySize, position: CaptionPosition, uppercase: Bool, highlight: Bool, highlightColor: RGBA
    ) {
        self.preset = preset
        self.size = size
        self.position = position
        self.uppercase = uppercase
        self.highlight = highlight
        self.highlightColor = highlightColor
    }
}

public enum CaptionPreset: String, Codable, Sendable, CaseIterable {
    case classic
    /// "Destacado" in Spanish (plan decision 6).
    case bold
    case minimal
}

/// The size of what is drawn over the output: the captions' (`CaptionStyle.size`) and the keys' (`KeyOverlayPlan.size`).
public enum OverlaySize: String, Codable, Sendable, CaseIterable {
    case small, medium, large
}

public enum CaptionPosition: String, Codable, Sendable, CaseIterable {
    case bottom, top
}
