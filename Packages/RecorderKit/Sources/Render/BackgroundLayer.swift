// SPDX-License-Identifier: GPL-3.0-or-later

/// What the compositor draws behind everything else, over the whole stage.
public enum BackgroundLayer: Equatable, Sendable {
    /// The frame's gradient: `RenderFrame.gradientStart`, `gradientEnd` and `gradientAngleDegrees`, as today.
    case gradient
    /// One colour, RGBA 0...1 written to the output as it is: the gradient's pipeline with both ends of that colour.
    case color(SIMD4<Float>)
    /// One of Toma's procedural wallpapers: its mesh gradient over the stage, with a grain of the output's pixels.
    case wallpaper(WallpaperPreset)
}
