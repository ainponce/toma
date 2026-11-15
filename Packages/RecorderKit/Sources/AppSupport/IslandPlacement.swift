// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Which display the island goes to when it is called up (the shortcut, the menu, the pointer over a
/// hover zone): the one with the pointer.
public enum IslandPlacement {
    /// The display whose frame contains `point` (global coordinates, like `DisplayInfo.frame`); off every
    /// display, the main one (or the first, if none is marked main); `nil` without displays.
    public static func displayID(containing point: CGPoint, displays: [DisplayInfo]) -> UInt32? {
        let x = Double(point.x)
        let y = Double(point.y)
        let under = displays.first { display in
            let frame = display.frame
            return x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
        }
        return (under ?? displays.first(where: \.isMain) ?? displays.first)?.id
    }
}
