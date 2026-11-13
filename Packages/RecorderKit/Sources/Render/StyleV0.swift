// SPDX-License-Identifier: GPL-3.0-or-later

/// The one look of phase 0: a diagonal gradient behind the screen, padded and with rounded corners,
/// and the cursor redrawn on top.
public struct StyleV0: Sendable, Equatable {
    /// Colour at the start of the gradient, RGBA 0...1 (sRGB-encoded values, written to the output as they are).
    public var gradientStart: SIMD4<Float>
    /// Colour at the end of the gradient.
    public var gradientEnd: SIMD4<Float>
    /// Direction of the gradient as in CSS: 0 goes up, 90 to the right, 135 down and to the right.
    public var gradientAngleDegrees: Float
    /// Space around the screen on each side, as a fraction of the output width.
    public var paddingFraction: Double
    /// Radius of the screen's corners, as a fraction of the output width.
    public var cornerRadiusFraction: Double
    /// Height of the cursor in points of the recorded display.
    public var cursorPointHeight: Double

    public init(
        gradientStart: SIMD4<Float> = SIMD4<Float>(0x7F, 0x5A, 0xF0, 255) / 255,
        gradientEnd: SIMD4<Float> = SIMD4<Float>(0x2C, 0xB1, 0xBC, 255) / 255,
        gradientAngleDegrees: Float = 135,
        paddingFraction: Double = 0.08,
        cornerRadiusFraction: Double = 0.012,
        cursorPointHeight: Double = 24.0
    ) {
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientAngleDegrees = gradientAngleDegrees
        self.paddingFraction = paddingFraction
        self.cornerRadiusFraction = cornerRadiusFraction
        self.cursorPointHeight = cursorPointHeight
    }
}
