// SPDX-License-Identifier: GPL-3.0-or-later

/// What the compositor draws behind everything else, over the whole stage.
public enum BackgroundLayer: Equatable, Sendable {
    /// The frame's gradient: `RenderFrame.gradientStart`, `gradientEnd` and `gradientAngleDegrees`, as today.
    case gradient
    /// One colour, RGBA 0...1 written to the output as it is: the gradient's pipeline with both ends of that colour.
    case color(SIMD4<Float>)
    /// One of Toma's procedural wallpapers: its mesh gradient over the stage, with a grain of the output's pixels.
    case wallpaper(WallpaperPreset)
    /// An image of the package covering the stage (aspect fill, centred), blurred; the frame's gradient (Toma classic)
    /// when the image is missing or cannot be read.
    case image(BackgroundImage)
}

/// An image of the package behind the stage: the user's own or the desktop picture a take saved.
public struct BackgroundImage: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// `assets/<sha>.<ext>`, as the document names it (`ProjectPackage.asset(_:)`).
        case asset(String)
        /// The desktop picture of display `displayID` as take `take` started (`ProjectPackage.wallpaper(take:displayID:)`).
        case desktop(take: String, displayID: UInt32)
    }

    public var source: Source
    /// σ of the Gaussian blur, in output pixels: `StageStyle.backgroundBlur × 0.04 ×` the output width. 0 draws the image
    /// sharp.
    public var blurSigma: Double

    public init(source: Source, blurSigma: Double) {
        self.source = source
        self.blurSigma = blurSigma
    }
}
