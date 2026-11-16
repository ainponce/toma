// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the export sheet remembers between exports (design §5.6), in the app's settings and never in a project: the
/// resolution, by the output's shorter side, and the quality. The frames per second start at the project's every time
/// and are not remembered. The editor draws its paused preview at the remembered resolution too (plan decision 11).
public struct ExportPreferences: Codable, Equatable, Sendable {
    /// The output's shorter side, in pixels: one of `shortSides`.
    public var shortSide: Int = 1080
    /// High quality (0.14 bits per pixel and frame) instead of Standard (0.08).
    public var highQuality: Bool = false

    /// The resolutions the sheet offers: 720p, 1080p, 1440p and 4K.
    public static let shortSides = [720, 1080, 1440, 2160]

    public init(shortSide: Int = 1080, highQuality: Bool = false) {
        self.shortSide = shortSide
        self.highQuality = highQuality
    }

    /// A field missing from what was saved, or that the sheet cannot show (a resolution it does not offer), takes its
    /// default; the other is kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportPreferences()
        let side = (try? container.decodeIfPresent(Int.self, forKey: .shortSide)) ?? defaults.shortSide
        shortSide = Self.shortSides.contains(side) ? side : defaults.shortSide
        highQuality = (try? container.decodeIfPresent(Bool.self, forKey: .highQuality)) ?? defaults.highQuality
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
