// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// The measures of the editor's window (design §5.1), in points.
public enum EditorLayout {
    public static let minimumSize = CGSize(width: 1024, height: 680)
    /// The largest initial size.
    static let largestInitialSize = CGSize(width: 1440, height: 900)

    /// The size a window opens at on a screen whose visible area (without the menu bar and the Dock) is `visible`: the
    /// smaller of 1440 × 900 and 85 % of it, side by side, in whole points, and never smaller than `minimumSize`.
    public static func initialSize(visible: CGSize) -> CGSize {
        // × 85 / 100 rather than × 0.85, which is not exact: 1440 × 0.85 is a hair under 1224.
        func side(_ visible: CGFloat, _ largest: CGFloat, _ minimum: CGFloat) -> CGFloat {
            max(min((visible * 85 / 100).rounded(.down), largest), minimum)
        }
        return CGSize(
            width: side(visible.width, largestInitialSize.width, minimumSize.width),
            height: side(visible.height, largestInitialSize.height, minimumSize.height))
    }

    /// The panel's width, and what dragging its edge allows.
    public static let panelWidth = 300.0
    public static let panelWidthRange = 260.0...380.0

    /// The timeline's height when a window opens.
    public static let timelineHeight = 236.0

    /// The heights the timeline's divider can be dragged to in a window `windowHeight` tall: from 180 pt to half of it
    /// (180 pt still, in a window too short for that).
    public static func timelineHeightRange(windowHeight: Double) -> ClosedRange<Double> {
        let lowest = 180.0
        return lowest...max(lowest, windowHeight / 2)
    }
}
