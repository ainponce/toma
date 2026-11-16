// SPDX-License-Identifier: GPL-3.0-or-later

/// The stage's measures: the output sizes of each aspect, and where the screen goes inside the padding (design §7.1
/// and §7.3). Positions are in output pixels, origin at the top left.
public enum StageLayout {
    /// The output of `aspect` whose shorter side is `shortSide` (720, 1080, 1440 or 2160 in the export sheet): the
    /// longer side is `round(shortSide × 16/9 / 2) × 2`, so both are even as H.264 needs; a square's are both
    /// `shortSide`.
    public static func outputSize(aspect: Aspect, shortSide: Int) -> SIMD2<Int> {
        let longSide = Int((Double(shortSide) * 16 / 9 / 2).rounded()) * 2
        switch aspect {
        case .landscape: return SIMD2(longSide, shortSide)
        case .portrait: return SIMD2(shortSide, longSide)
        case .square: return SIMD2(shortSide, shortSide)
        }
    }

    /// The screen's rect in an output of `outputSize`: the largest rect of `contentAspect` (width over height)
    /// centred inside `padding × width` of space on every side; the whole area inside the padding without an aspect,
    /// and an empty rect at the centre when the padding leaves no room.
    public static func screenRect(contentAspect: Double?, padding: Double, outputSize: SIMD2<Double>) -> Rect {
        let width = outputSize.x, height = outputSize.y
        let margin = padding * width
        let available = SIMD2(max(width - 2 * margin, 0), max(height - 2 * margin, 0))
        var size = available
        if let contentAspect, available.x > 0, available.y > 0 {
            size = available.x / available.y > contentAspect
                ? SIMD2(available.y * contentAspect, available.y)
                : SIMD2(available.x, available.x / contentAspect)
        }
        return Rect(x: (width - size.x) / 2, y: (height - size.y) / 2, width: size.x, height: size.y)
    }
}
