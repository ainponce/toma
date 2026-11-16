// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The panel's sliders show an integer from 0 to 100 and the document keeps the render's measure (design §5.4): each
/// pair converts one way and back, rounding to the nearest integer.
public enum PanelValues {
    /// The cursor's size as a percentage of the real size.
    public static let cursorScaleRange = 50...300
    /// What a slider's integer goes over.
    public static let sliderRange = 0...100

    /// Padding: `v / 100 × 0.20` of the output's width, on each side.
    public static func padding(slider: Int) -> Double { Double(slider) * 0.20 / 100 }
    public static func slider(padding: Double) -> Int { integer(padding / 0.20 * 100) }

    /// Corners: `v / 100 × 0.04` of the output's width.
    public static func cornerRadius(slider: Int) -> Double { Double(slider) * 0.04 / 100 }
    public static func slider(cornerRadius: Double) -> Int { integer(cornerRadius / 0.04 * 100) }

    /// The background's blur: `v / 100` (σ = that × 0.04 × the output's width).
    public static func backgroundBlur(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(backgroundBlur: Double) -> Int { integer(backgroundBlur * 100) }

    /// The shadow: `v / 100`.
    public static func shadow(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(shadow: Double) -> Int { integer(shadow * 100) }

    /// Motion blur (the shutter, as a fraction of a frame): `v / 100`.
    public static func motionBlur(slider: Int) -> Double { Double(slider) / 100 }
    public static func slider(motionBlur: Double) -> Int { integer(motionBlur * 100) }

    /// The cursor's scale: `percent / 100`, and the percentage of a scale.
    public static func cursorScale(percent: Int) -> Double { Double(percent) / 100 }
    public static func percent(cursorScale: Double) -> Int { integer(cursorScale * 100, in: cursorScaleRange) }

    /// Where a gradient of `angle` degrees (as in CSS: 0 goes up, 90 to the right, 135 down and to the right) starts and
    /// ends in a box, as fractions of it with y down: through the centre, along the angle.
    public static func gradientEnds(angle: Double) -> (start: SIMD2<Double>, end: SIMD2<Double>) {
        let radians = (angle.isFinite ? angle : 180) * Double.pi / 180
        let direction = SIMD2(sin(radians), -cos(radians)) / 2
        let center = SIMD2(0.5, 0.5)
        return (center - direction, center + direction)
    }

    /// The corners slider's integer for the window frame's cover: a cover can need more than the slider's top (a 300 pt
    /// window gives 0.0465), so it is kept to the slider's range.
    private static func integer(_ value: Double, in range: ClosedRange<Int> = sliderRange) -> Int {
        guard value.isFinite else { return range.lowerBound }
        return min(max(Int(value.rounded()), range.lowerBound), range.upperBound)
    }
}
