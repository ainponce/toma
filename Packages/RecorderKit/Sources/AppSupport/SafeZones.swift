// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import simd

/// The safe-zone guide of the preview (`safeZones-1`, phase 2 design §6.6): where the apps of vertical video put their
/// own interface over the picture, the worst case of Reels, TikTok and Shorts together. Only the preview draws it,
/// never the render or the export.
public enum SafeZones {
    public static let id = "safeZones-1"
    /// Fractions of the output's height (`top`, `bottom`) and width (`right`).
    public static let top = 0.12, bottom = 0.22, right = 0.14

    /// Whether the guide is offered for an output of `ratio` (width over height): 0.8 (4:5) or narrower.
    public static func applies(ratio: Double) -> Bool {
        ratio.isFinite && ratio > 0 && ratio <= 0.8 + 1e-9
    }

    /// Whether the guide is offered for an output of this size in pixels.
    public static func applies(to outputSize: SIMD2<Int>) -> Bool {
        guard outputSize.x > 0, outputSize.y > 0 else { return false }
        return applies(ratio: Double(outputSize.x) / Double(outputSize.y))
    }

    /// The three zones in a frame of `size` (origin at the top left): the strip on top, the strip at the bottom and the
    /// one on the right between them, so no area is dimmed twice.
    public static func rects(in size: SIMD2<Double>) -> [Rect] {
        let topHeight = size.y * top
        let bottomHeight = size.y * bottom
        let rightWidth = size.x * right
        return [
            Rect(x: 0, y: 0, width: size.x, height: topHeight),
            Rect(x: 0, y: size.y - bottomHeight, width: size.x, height: bottomHeight),
            Rect(x: size.x - rightWidth, y: topHeight, width: rightWidth, height: size.y - topHeight - bottomHeight),
        ]
    }
}
