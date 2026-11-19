// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the keys on screen sit (`keyOverlay-1`, plan decisions 14 and 15): the one place that works it out; the render and
/// the tests read it. Output pixels, origin at the top left, `y` growing down.
public enum KeyOverlayPlacement {
    /// The distance from the edge, as a fraction of the height (above and below) or of the shorter side (to the sides).
    public static let margin = 0.10
    /// What the keys leave between them and the captions at the same edge, as a fraction of the shorter side.
    public static let captionGap = 0.02

    /// The height of a key: 0.045, 0.06 or 0.075 of the shorter side.
    public static func capHeight(_ size: OverlaySize, outputSize: SIMD2<Int>) -> Double {
        let fraction: Double
        switch size {
        case .small: fraction = 0.045
        case .medium: fraction = 0.06
        case .large: fraction = 0.075
        }
        return fraction * Double(min(outputSize.x, outputSize.y))
    }

    /// The box of `boxSize` (output pixels). At the bottom its lower edge is 10 % of the height from the bottom, at the
    /// top its upper edge 10 % from the top and at the sides 10 % of the shorter side from them; with the captions shown
    /// at the same edge it is no closer than what they reserve (`CaptionMetrics.reservedHeight`) plus 2 % of the shorter
    /// side, whether or not a caption is on at that instant, so the keys do not jump.
    public static func rect(boxSize: SIMD2<Double>, keys: KeyOverlayPlan, captions: CaptionPlan, outputSize: SIMD2<Int>) -> Rect {
        let width = Double(outputSize.x), height = Double(outputSize.y)
        let short = Double(min(outputSize.x, outputSize.y))
        let reserved = captions.show ? CaptionMetrics.reservedHeight(captions.style, outputSize: outputSize) + captionGap * short : 0
        let x: Double
        switch keys.position {
        case .bottomLeading: x = margin * short
        case .bottomTrailing: x = width - margin * short - boxSize.x
        case .bottomCenter, .top: x = (width - boxSize.x) / 2
        }
        let y: Double
        if keys.position == .top {
            let edge = max(margin * height, captions.style.position == .top ? reserved : 0)
            y = edge
        } else {
            let edge = max(margin * height, captions.style.position == .bottom ? reserved : 0)
            y = height - edge - boxSize.y
        }
        return Rect(x: x, y: y, width: boxSize.x, height: boxSize.y)
    }
}
