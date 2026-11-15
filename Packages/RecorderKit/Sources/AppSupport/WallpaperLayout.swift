// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Where macOS draws a display's wallpaper image, from the options it was set with
/// (`NSWorkspace.desktopImageOptions(for:)`): the covers' fallback when the wallpaper cannot be captured.
public enum WallpaperLayout {
    /// The image's rectangle on a screen of `screenSize`, centered, in the screen's points:
    /// - `.scaleProportionallyUpOrDown`: "Fill Screen" with `allowsClipping` (the whole screen, the image cut on one
    ///   axis), "Fit to Screen" without it (the whole image, the fill color around it);
    /// - `.scaleProportionallyDown`: the same, but never larger than the image;
    /// - `.scaleAxesIndependently`: "Stretch to Fill Screen", the screen;
    /// - `.scaleNone`: "Center", the image at its size.
    ///
    /// An image without a size fills the screen.
    public static func imageRect(imageSize: CGSize, screenSize: CGSize, scaling: NSImageScaling, allowsClipping: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: screenSize) }
        let fit = min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
        let fill = max(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
        let scale: CGFloat
        switch scaling {
        case .scaleAxesIndependently:
            return CGRect(origin: .zero, size: screenSize)
        case .scaleNone:
            scale = 1
        case .scaleProportionallyDown:
            scale = min(1, allowsClipping ? fill : fit)
        case .scaleProportionallyUpOrDown:
            scale = allowsClipping ? fill : fit
        @unknown default:
            scale = fit
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (screenSize.width - size.width) / 2, y: (screenSize.height - size.height) / 2, width: size.width, height: size.height)
    }
}
