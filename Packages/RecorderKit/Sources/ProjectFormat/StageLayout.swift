// SPDX-License-Identifier: GPL-3.0-or-later

/// The stage's measures: the output sizes of each aspect, and where the screen, or the macOS window around it, goes inside
/// the padding (design §7.1 and §7.3). Positions are in output pixels, origin at the top left.
public enum StageLayout {
    /// The output of `aspect` whose shorter side is `shortSide` (720, 1080, 1440 or 2160 in the export sheet). 16:9 and
    /// 9:16: the longer side is `round(shortSide × 16/9 / 2) × 2`, so both are even as H.264 needs; a square's are both
    /// `shortSide`. The others (and `auto`, from `contentRatio`, 16:9 without it): the shorter side is `shortSide` and the
    /// longer `round(shortSide × r / 2) × 2`, `r` the ratio of the longer over the shorter.
    public static func outputSize(aspect: Aspect, shortSide: Int, contentRatio: Double? = nil) -> SIMD2<Int> {
        let longSide = Int((Double(shortSide) * 16 / 9 / 2).rounded()) * 2
        switch aspect {
        case .landscape: return SIMD2(longSide, shortSide)
        case .portrait: return SIMD2(shortSide, longSide)
        case .square: return SIMD2(shortSide, shortSide)
        case .fourByFive, .fourByThree, .threeByFour, .auto:
            let ratio = aspect.ratio(contentRatio: contentRatio)
            let wide = ratio >= 1
            let long = Int((Double(shortSide) * (wide ? ratio : 1 / ratio) / 2).rounded()) * 2
            return wide ? SIMD2(long, shortSide) : SIMD2(shortSide, long)
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

    /// The macOS window frame's rects in an output of `outputSize` (design §7.3): the largest window, a title bar on top of
    /// a screen of `contentAspect` as wide as the window, centred inside `padding × width` of space on every side; the
    /// bar is `max(0.032 × the window's width, 18)` px tall. Without an aspect, the window is the whole area inside the
    /// padding and the screen all of it under the bar. When the padding leaves no room for a window, or none for its
    /// bar, everything is an empty rect at the centre and the bar 0.
    public static func windowRect(
        contentAspect: Double?, padding: Double, outputSize: SIMD2<Double>
    ) -> (window: Rect, screen: Rect, barHeight: Double) {
        let width = outputSize.x, height = outputSize.y
        let margin = padding * width
        let available = SIMD2(max(width - 2 * margin, 0), max(height - 2 * margin, 0))
        let empty = Rect(x: width / 2, y: height / 2, width: 0, height: 0)
        func barHeight(_ windowWidth: Double) -> Double { max(0.032 * windowWidth, 18) }
        var size = available, bar = barHeight(available.x), screenHeight = available.y - bar
        if let contentAspect {
            // A window `w` wide is `w / a + bar(w)` tall: the widest that fits both ways.
            if available.x / contentAspect + bar > available.y {
                // From 562.5 px on, where 0.032 of the width is 18 px, the bar grows with the window.
                let proportional = available.y / (1 / contentAspect + 0.032)
                size.x = proportional >= 18 / 0.032 ? proportional : (available.y - 18) * contentAspect
                bar = barHeight(size.x)
            }
            screenHeight = size.x / contentAspect
            size.y = screenHeight + bar
        }
        guard size.x > 0, screenHeight > 0 else { return (empty, empty, 0) }
        let window = Rect(x: (width - size.x) / 2, y: (height - size.y) / 2, width: size.x, height: size.y)
        let screen = Rect(x: window.x, y: window.y + bar, width: window.width, height: screenHeight)
        return (window, screen, bar)
    }
}
