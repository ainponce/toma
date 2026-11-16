// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// One of Toma's procedural wallpapers: a mesh gradient of a few colours placed on the stage (`wallpaperFragment`),
/// drawn at any size without an image. Its look is frozen with its versioned `id`: a new look gets a new ID.
///
/// It has no name: the app names each by its `id`.
public struct WallpaperPreset: Equatable, Sendable {
    public let id: String
    /// Where each colour is, as fractions of the stage: (0, 0) is its top-left corner, (1, 1) the bottom-right one.
    public let points: [SIMD2<Float>]
    /// The colour at each point, RGBA 0...1 (sRGB-encoded values, written to the output as they are); its alpha is not
    /// read: a wallpaper is opaque.
    public let colors: [SIMD4<Float>]

    /// From one to six points, with a colour each.
    public init(id: String, points: [SIMD2<Float>], colors: [SIMD4<Float>]) {
        precondition((1...6).contains(points.count), "A wallpaper has one to six points, not \(points.count)")
        precondition(colors.count == points.count, "A wallpaper has a colour for each point")
        self.id = id
        self.points = points
        self.colors = colors
    }

    /// Each point with its colour, `0xRRGGBB`.
    private init(_ id: String, _ stops: [(point: SIMD2<Float>, color: UInt32)]) {
        self.init(
            id: id, points: stops.map(\.point),
            colors: stops.map { stop in
                SIMD4(Float((stop.color >> 16) & 0xFF), Float((stop.color >> 8) & 0xFF), Float(stop.color & 0xFF), 255) / 255
            })
    }

    /// The twelve, in the order the panel shows them (design §5.4).
    public static let all: [WallpaperPreset] = [
        WallpaperPreset("aurora-1", [
            ([0.10, 0.92], 0x0A1433), ([0.24, 0.30], 0x1FB59A), ([0.56, 0.10], 0x7CE3B1),
            ([0.90, 0.34], 0x6A4FD3), ([0.72, 0.86], 0x16245E), ([0.46, 0.56], 0x1C6E8C),
        ]),
        WallpaperPreset("dune-1", [
            ([0.14, 0.18], 0xF6D3A0), ([0.82, 0.14], 0xE9A65E), ([0.34, 0.72], 0xC8693C),
            ([0.86, 0.82], 0x8C4636), ([0.56, 0.44], 0xF0B979),
        ]),
        WallpaperPreset("lake-1", [
            ([0.10, 0.14], 0xA9DDE3), ([0.76, 0.20], 0x4DAFC0), ([0.30, 0.76], 0x1E6E8A),
            ([0.86, 0.86], 0x24476A), ([0.54, 0.50], 0x6FB58A),
        ]),
        WallpaperPreset("ember-1", [
            ([0.20, 0.86], 0xFFB54D), ([0.48, 0.64], 0xE8541E), ([0.80, 0.30], 0x8E1B17),
            ([0.14, 0.14], 0x2A0B0B), ([0.86, 0.90], 0x5A1310),
        ]),
        WallpaperPreset("mist-1", [
            ([0.14, 0.20], 0xF1F2F5), ([0.80, 0.24], 0xC9CFDA), ([0.30, 0.80], 0xA7B1C2),
            ([0.86, 0.80], 0xE3DDEA), ([0.50, 0.50], 0xD4D9E2),
        ]),
        WallpaperPreset("forest-1", [
            ([0.14, 0.20], 0x2E6B45), ([0.80, 0.14], 0x8DB26A), ([0.30, 0.86], 0x0E2B1C),
            ([0.80, 0.76], 0x1C4A33), ([0.54, 0.44], 0x4F8B4F),
        ]),
        WallpaperPreset("lavender-1", [
            ([0.14, 0.20], 0xE7DCF8), ([0.80, 0.20], 0xB79BE6), ([0.24, 0.80], 0x9A86D1),
            ([0.86, 0.80], 0x7563B8), ([0.50, 0.50], 0xCDB6EE),
        ]),
        WallpaperPreset("midnight-1", [
            ([0.14, 0.14], 0x070A18), ([0.86, 0.20], 0x1A2466), ([0.30, 0.86], 0x0C1640),
            ([0.80, 0.80], 0x3A2C7A), ([0.50, 0.44], 0x0F1A4A),
        ]),
        WallpaperPreset("coral-1", [
            ([0.14, 0.20], 0xFFD2BE), ([0.80, 0.20], 0xFF8A70), ([0.24, 0.86], 0xF0606A),
            ([0.86, 0.80], 0xFFB08F), ([0.50, 0.50], 0xFF9E86),
        ]),
        WallpaperPreset("ice-1", [
            ([0.14, 0.14], 0xF4FAFD), ([0.80, 0.20], 0xBFE4F4), ([0.30, 0.86], 0x7FC1E3),
            ([0.86, 0.80], 0xA2D6EE), ([0.50, 0.50], 0xDDF0F9),
        ]),
        WallpaperPreset("graphite-1", [
            ([0.14, 0.20], 0x4A4D55), ([0.80, 0.20], 0x2B2D33), ([0.30, 0.86], 0x1B1C20),
            ([0.86, 0.80], 0x5E626B), ([0.50, 0.50], 0x34363D),
        ]),
        WallpaperPreset("sand-1", [
            ([0.14, 0.20], 0xFAF3E6), ([0.80, 0.20], 0xE8D6B6), ([0.30, 0.86], 0xD6BE97),
            ([0.86, 0.80], 0xF1E4CB), ([0.50, 0.50], 0xE2CDA8),
        ]),
    ]

    /// The wallpaper of `id`; `nil` for one this version of Toma does not have.
    public static func preset(id: String) -> WallpaperPreset? {
        all.first { $0.id == id }
    }
}

/// Toma's ten gradients, in the order the panel shows them (design §5.4), each frozen with its versioned `id`. The
/// first is Toma classic (`Background.tomaClassic`). They have no names: the app names each by its `id`.
public enum GradientPresets {
    /// Colours as `Background.gradient` takes them; `angle` in degrees as in CSS.
    public static let all: [(id: String, start: RGBA, end: RGBA, angle: Double)] = [
        ("toma-classic-1", rgba(0x7F5AF0), rgba(0x2CB1BC), 135),
        ("sunset-1", rgba(0xFF8A5B), rgba(0xC2459A), 180),
        ("ocean-1", rgba(0x1E5BD8), rgba(0x2EC8D6), 135),
        ("meadow-1", rgba(0xA8E063), rgba(0x2E9E6A), 160),
        ("berry-1", rgba(0x8E2DE2), rgba(0xE0457B), 135),
        ("peach-1", rgba(0xFFD3A5), rgba(0xFD9F8E), 135),
        ("dusk-1", rgba(0x2C3E70), rgba(0x7A4E8E), 180),
        ("steel-1", rgba(0x5B6573), rgba(0xA4AFBC), 135),
        ("citrus-1", rgba(0xFFE259), rgba(0xFFA751), 135),
        ("mint-1", rgba(0xC3F5E1), rgba(0x5FC9C0), 135),
    ]

    /// An opaque colour from its sRGB bytes, `0xRRGGBB`.
    private static func rgba(_ hex: UInt32) -> RGBA {
        RGBA(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, 1)
    }
}
