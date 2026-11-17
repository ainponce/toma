// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the export sheet exports (1c design §7.1): a video or an animated GIF.
public enum ExportKind: String, Codable, Sendable {
    case mp4, gif
}

/// The GIF's options the export sheet remembers (1c design §7.1): its longer side in pixels, its frames per second, its
/// quality, the dither and whether it loops. The quality is `GIFQuality`'s `rawValue` (`AppSupport` does not see
/// `Export`): the app reads it with `GIFQuality(rawValue:) ?? .balanced`.
public struct GIFPreferences: Codable, Equatable, Sendable {
    /// One of `longSides`.
    public var longSide = 800
    /// One of `framesPerSecond`.
    public var fps = 15
    /// One of `qualities`.
    public var quality = "balanced"
    public var dither = true
    public var loops = true

    /// The sizes the sheet offers, by the GIF's longer side (`GIFSettings.longSides`).
    public static let longSides = [480, 640, 800, 1080, 1280, 1920]
    /// The frames per second the sheet offers (`GIFSettings.framesPerSecond`).
    public static let framesPerSecond = [10, 15, 20, 25, 30]
    /// The qualities the sheet offers, as `GIFQuality`'s raw values: Light, Balanced and High.
    public static let qualities = ["light", "balanced", "high"]

    public init(longSide: Int = 800, fps: Int = 15, quality: String = "balanced", dither: Bool = true, loops: Bool = true) {
        self.longSide = longSide
        self.fps = fps
        self.quality = quality
        self.dither = dither
        self.loops = loops
    }

    /// A field missing from what was saved, or that the sheet cannot show (a size, a rate or a quality it does not offer),
    /// takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GIFPreferences()
        let side = (try? container.decodeIfPresent(Int.self, forKey: .longSide)) ?? defaults.longSide
        longSide = Self.longSides.contains(side) ? side : defaults.longSide
        let rate = (try? container.decodeIfPresent(Int.self, forKey: .fps)) ?? defaults.fps
        fps = Self.framesPerSecond.contains(rate) ? rate : defaults.fps
        let quality = (try? container.decodeIfPresent(String.self, forKey: .quality)) ?? defaults.quality
        self.quality = Self.qualities.contains(quality) ? quality : defaults.quality
        dither = (try? container.decodeIfPresent(Bool.self, forKey: .dither)) ?? defaults.dither
        loops = (try? container.decodeIfPresent(Bool.self, forKey: .loops)) ?? defaults.loops
    }
}

/// What the export sheet remembers between exports (design §5.6, 1c design §7.1), in the app's settings and never in a
/// project: the MP4's resolution, by the output's shorter side, and its quality; what was exported last (Export As); and
/// the GIF's options. The frames per second of the MP4 start at the project's every time, and the range at its default
/// (`ExportRangeRules.defaultRange`): neither is remembered. The editor draws its paused preview at the remembered
/// resolution too (plan decision 11).
public struct ExportPreferences: Codable, Equatable, Sendable {
    /// The output's shorter side, in pixels: one of `shortSides`.
    public var shortSide: Int = 1080
    /// High quality (0.14 bits per pixel and frame) instead of Standard (0.08).
    public var highQuality: Bool = false
    /// What the sheet exported last, which it starts at.
    public var kind: ExportKind = .mp4
    public var gif: GIFPreferences = .init()

    /// The resolutions the sheet offers: 720p, 1080p, 1440p and 4K.
    public static let shortSides = [720, 1080, 1440, 2160]

    public init(shortSide: Int = 1080, highQuality: Bool = false, kind: ExportKind = .mp4, gif: GIFPreferences = .init()) {
        self.shortSide = shortSide
        self.highQuality = highQuality
        self.kind = kind
        self.gif = gif
    }

    /// A field missing from what was saved (all but the first two, in what 1b saved), or that the sheet cannot show (a
    /// resolution it does not offer, a kind it does not know), takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportPreferences()
        let side = (try? container.decodeIfPresent(Int.self, forKey: .shortSide)) ?? defaults.shortSide
        shortSide = Self.shortSides.contains(side) ? side : defaults.shortSide
        highQuality = (try? container.decodeIfPresent(Bool.self, forKey: .highQuality)) ?? defaults.highQuality
        kind = (try? container.decodeIfPresent(ExportKind.self, forKey: .kind)) ?? defaults.kind
        gif = (try? container.decodeIfPresent(GIFPreferences.self, forKey: .gif)) ?? defaults.gif
    }

    /// What the sheet remembers once an export of `kind` starts with the options `chosen`: that `kind` was exported, and
    /// that kind's options as chosen. The other kind's stay as they were: a GIF never changes the MP4's resolution, which
    /// the paused preview is drawn at.
    public func remembering(_ kind: ExportKind, chosen: ExportPreferences) -> ExportPreferences {
        var remembered = self
        remembered.kind = kind
        switch kind {
        case .mp4:
            remembered.shortSide = chosen.shortSide
            remembered.highQuality = chosen.highQuality
        case .gif:
            remembered.gif = chosen.gif
        }
        return remembered
    }

    /// The shorter side, in pixels, of what `take` recorded of its screens, which the sheet's resolutions are compared
    /// with ("Higher than the recording"): of each display or window with a segment, its area in Area mode or its frame
    /// as the take started, times the pixels per point it recorded; the largest of them. `nil` when no screen's size is
    /// known (a take without a screen).
    public static func recordedShortSide(of take: TakeRecord) -> Int? {
        take.tracks.compactMap { track -> Int? in
            guard track.kind.isScreen, !track.segments.isEmpty, let scale = track.source.pixelScale, scale.isFinite, scale > 0,
                let rect = (track.kind == .display ? track.source.captureArea : nil) ?? track.source.globalFrame
            else { return nil }
            let side = min(rect.width, rect.height) * scale
            guard side.isFinite, side > 0, side <= Double(Int32.max) else { return nil }
            return Int(side.rounded())
        }.max()
    }
}
