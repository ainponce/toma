// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Converts between AppKit's screen coordinates (`NSScreen.frame`, window frames, `NSEvent.mouseLocation`:
/// origin at the bottom left of the primary display, y up) and the global coordinates of a take and of
/// `DisplayInfo` (`CGDisplayBounds`: origin at the top left of the primary display, y down).
public enum ScreenCoordinates {
    /// `primaryScreenHeight`: the height of the primary display (`NSScreen.screens[0]`), in points.
    public static func global(fromAppKit rect: CGRect, primaryScreenHeight: Double) -> Rect {
        Rect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKit(fromGlobal rect: Rect, primaryScreenHeight: Double) -> CGRect {
        CGRect(x: rect.x, y: primaryScreenHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }
}
