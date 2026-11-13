// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Maps global cursor positions onto a display, for any display including ones with a negative origin.
public enum CursorGeometry {
    /// `p` as a fraction of `displayFrame`: (0, 0) at its origin, (1, 1) at its far corner.
    /// Points outside the frame give values outside 0...1.
    public static func normalized(_ p: CGPoint, in displayFrame: Rect) -> SIMD2<Double> {
        SIMD2((Double(p.x) - displayFrame.x) / displayFrame.width,
              (Double(p.y) - displayFrame.y) / displayFrame.height)
    }

    /// Whether `p` lies in the half-open rectangle [x, x + width) × [y, y + height).
    public static func contains(_ p: CGPoint, _ displayFrame: Rect) -> Bool {
        let x = Double(p.x), y = Double(p.y)
        return x >= displayFrame.x && x < displayFrame.x + displayFrame.width
            && y >= displayFrame.y && y < displayFrame.y + displayFrame.height
    }
}
