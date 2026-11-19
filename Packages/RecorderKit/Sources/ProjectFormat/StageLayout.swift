// SPDX-License-Identifier: GPL-3.0-or-later

/// The stage's measures: the output sizes of each aspect, and where the screen, or the macOS window around it, goes inside
/// the padding (design §7.1 and §7.3). Positions are in output pixels, origin at the top left.
public enum StageLayout {
    /// The longest side of an output, in pixels: the most the video encoders take.
    public static let maximumSide = 16_384

    /// The output of `aspect` whose shorter side is `shortSide` (720, 1080, 1440 or 2160 in the export sheet). 16:9 and
    /// 9:16: the longer side is `round(shortSide × 16/9 / 2) × 2`, so both are even as H.264 needs; a square's are both
    /// `shortSide`. The others (and `auto`, from `contentRatio`, 16:9 without it, held to `Aspect.autoRange`): the shorter
    /// side is `shortSide` and the longer `round(shortSide × r / 2) × 2`, `r` the ratio of the longer over the shorter.
    /// An output whose longer side would pass `maximumSide` is scaled down to it, the other side in proportion and even.
    public static func outputSize(aspect: Aspect, shortSide: Int, contentRatio: Double? = nil) -> SIMD2<Int> {
        let longSide = Int((Double(shortSide) * 16 / 9 / 2).rounded()) * 2
        let size: SIMD2<Int>
        switch aspect {
        case .landscape: size = SIMD2(longSide, shortSide)
        case .portrait: size = SIMD2(shortSide, longSide)
        case .square: size = SIMD2(shortSide, shortSide)
        case .fourByFive, .fourByThree, .threeByFour, .auto:
            let ratio = aspect.ratio(contentRatio: contentRatio)
            let wide = ratio >= 1
            let long = Int((Double(shortSide) * (wide ? ratio : 1 / ratio) / 2).rounded()) * 2
            size = wide ? SIMD2(long, shortSide) : SIMD2(shortSide, long)
        }
        return held(size)
    }

    /// `size` with its longer side at most `maximumSide`: scaled down to it, the shorter in proportion, rounded to an
    /// even number of pixels (2 at least).
    private static func held(_ size: SIMD2<Int>) -> SIMD2<Int> {
        let long = max(size.x, size.y)
        guard long > maximumSide else { return size }
        let scale = Double(maximumSide) / Double(long)
        func side(_ pixels: Int) -> Int {
            pixels == long ? maximumSide : min(max(2, Int((Double(pixels) * scale / 2).rounded()) * 2), maximumSide)
        }
        return SIMD2(side(size.x), side(size.y))
    }

    /// The ratio `auto` ("like the recording") takes: the region of the screen of `screens.initial` for `take`, with the
    /// Area crop, at the start of its first segment, as width over height (design §6.4). Later window or screen changes
    /// do not move it, so the output keeps one size. `nil` without a screen of the take, a segment, a region, or one
    /// whose ratio is not finite and positive.
    public static func contentRatio(
        take: TakeRecord, document: EditDocument, geometry: (TrackRecord) -> ScreenGeometry
    ) -> Double? {
        guard let id = document.screens.initial[take.id], let track = take.track(id), track.kind.isScreen,
              let start = track.segments.map(\.startHostTime).min(),
              let region = geometry(track).shown(at: start)?.region,
              region.width.isFinite, region.height.isFinite, region.width > 0, region.height > 0
        else { return nil }
        let ratio = region.width / region.height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    /// `contentRatio(take:document:geometry:)` from the take's `events`, in any order.
    public static func contentRatio(take: TakeRecord, document: EditDocument, events: [InputEvent]) -> Double? {
        let ordered = events.sortedByTime()
        return contentRatio(take: take, document: document) { ScreenGeometry(track: $0, events: ordered) }
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

// MARK: - Device frames

/// `deviceFrame-1`'s measures (phase 2 design §6.7 and plan 2b decision 10), as fractions of the screen inside the device:
/// frozen, as the device is drawn from them. An iPhone's are of its own width and height, the screen's shorter and longer
/// sides (on its side with a content wider than tall, its top to the left); an iPad's of the screen's shorter side; a
/// MacBook's of the screen's width, and its base of the lid's.
public enum DeviceMeasures {
    /// The iPhone's black bezel and the coloured band outside it, of its width.
    public static let iPhoneBezel = 0.045
    public static let iPhoneBand = 0.012
    /// The iPhone's outer corners, of its body's width.
    public static let iPhoneBodyCorners = 0.16
    /// The island: of the width across, of the height along and of the height under the screen's top edge.
    public static let iPhoneIslandWidth = 0.30
    public static let iPhoneIslandHeight = 0.034
    public static let iPhoneIslandInset = 0.018
    /// The side buttons, of the width across.
    public static let iPhoneButtonWidth = 0.008
    /// Where each side button starts from the body's top edge and how long it is, of the height: on the left the action
    /// button and the volume buttons, on the right the side button.
    public static let iPhoneLeftButtons: [(start: Double, length: Double)] = [(0.13, 0.04), (0.20, 0.07), (0.29, 0.07)]
    public static let iPhoneRightButtons: [(start: Double, length: Double)] = [(0.24, 0.11)]
    /// The iPad's bezel and band, of the screen's shorter side, and its outer corners, of the body's.
    public static let iPadBezel = 0.05
    public static let iPadBand = 0.01
    public static let iPadBodyCorners = 0.06
    /// The MacBook's bezel at the sides and the bottom and at the top, the lid's rim, its top and bottom corners and the
    /// notch, of the screen's width.
    public static let macBookSideBezel = 0.02
    public static let macBookTopBezel = 0.035
    public static let macBookRim = 0.004
    public static let macBookLidCorners = 0.02
    public static let macBookLidBottomCorners = 0.004
    public static let macBookNotchWidth = 0.11
    public static let macBookNotchHeight = 0.025
    /// The base under the lid: of the lid's width and height. Its front is round by half its height.
    public static let macBookBaseWidth = 1.12
    public static let macBookBaseHeight = 0.035
    /// The groove at the middle of the base's top edge, of the base's width and height, in the base's colour times
    /// `macBookGrooveShade`.
    public static let macBookGrooveWidth = 0.16
    public static let macBookGrooveHeight = 0.35
    public static let macBookGrooveShade = 0.8
}

extension StageLayout {
    /// Where each part of a `model` device goes around a screen at `screen` (`deviceFrame-1`, `DeviceMeasures`), in its
    /// coordinates. The device's body is the screen with its bezel and band (the MacBook's lid, its bezel and rim) on
    /// every side, its corners concentric with the screen's; the iPhone's island and the MacBook's notch are over the
    /// screen, at its top (at its left, an iPhone on its side); the iPhone's buttons outside the body, the MacBook's
    /// base under the lid.
    public static func deviceRects(around screen: Rect, model: DeviceModel) -> DeviceRects {
        let x = screen.x, y = screen.y, w = screen.width, h = screen.height
        func inflated(_ rect: Rect, by edge: Double) -> Rect {
            Rect(x: rect.x - edge, y: rect.y - edge, width: rect.width + 2 * edge, height: rect.height + 2 * edge)
        }
        switch model {
        case .iPhone:
            typealias M = DeviceMeasures
            // The phone's own width and height: on its side when the screen is wider than tall, its top to the left.
            let upright = h >= w
            let across = min(w, h), along = max(w, h)
            let edge = (M.iPhoneBezel + M.iPhoneBand) * across
            let body = inflated(screen, by: edge)
            let bodyCorners = M.iPhoneBodyCorners * (across + 2 * edge)
            let islandAcross = M.iPhoneIslandWidth * across, islandAlong = M.iPhoneIslandHeight * along
            let inset = M.iPhoneIslandInset * along
            let island = upright
                ? Rect(x: x + (w - islandAcross) / 2, y: y + inset, width: islandAcross, height: islandAlong)
                : Rect(x: x + inset, y: y + (h - islandAcross) / 2, width: islandAlong, height: islandAcross)
            let thickness = M.iPhoneButtonWidth * across
            // Upright, the left side's buttons beside the body's left edge and the right side's beside its right one;
            // on its side, they go under the body and over it, from its left edge.
            func button(_ spec: (start: Double, length: Double), left: Bool) -> Rect {
                let start = spec.start * along, length = spec.length * along
                if upright {
                    return Rect(x: left ? body.x - thickness : body.x + body.width, y: body.y + start, width: thickness, height: length)
                }
                return Rect(x: body.x + start, y: left ? body.y + body.height : body.y - thickness, width: length, height: thickness)
            }
            let buttons = M.iPhoneLeftButtons.map { button($0, left: true) } + M.iPhoneRightButtons.map { button($0, left: false) }
            let bounds = upright
                ? Rect(x: body.x - thickness, y: body.y, width: body.width + 2 * thickness, height: body.height)
                : Rect(x: body.x, y: body.y - thickness, width: body.width, height: body.height + 2 * thickness)
            return DeviceRects(
                screen: screen, screenCornerRadius: bodyCorners - edge, body: body, bodyCornerRadius: bodyCorners,
                bandWidth: M.iPhoneBand * across, cutout: island, buttons: buttons, base: nil, baseFrontRadius: 0, bounds: bounds)
        case .iPad:
            typealias M = DeviceMeasures
            let short = min(w, h)
            let edge = (M.iPadBezel + M.iPadBand) * short
            let body = inflated(screen, by: edge)
            let bodyCorners = M.iPadBodyCorners * min(body.width, body.height)
            return DeviceRects(
                screen: screen, screenCornerRadius: max(bodyCorners - edge, 0), body: body, bodyCornerRadius: bodyCorners,
                bandWidth: M.iPadBand * short, cutout: nil, buttons: [], base: nil, baseFrontRadius: 0, bounds: body)
        case .macBook:
            typealias M = DeviceMeasures
            let rim = M.macBookRim * w
            let side = M.macBookSideBezel * w + rim, top = M.macBookTopBezel * w + rim
            let lid = Rect(x: x - side, y: y - top, width: w + 2 * side, height: h + top + side)
            let notchWidth = M.macBookNotchWidth * w
            let notch = Rect(x: x + (w - notchWidth) / 2, y: y, width: notchWidth, height: M.macBookNotchHeight * w)
            let baseWidth = M.macBookBaseWidth * lid.width, baseHeight = M.macBookBaseHeight * lid.height
            let base = Rect(x: lid.x + (lid.width - baseWidth) / 2, y: lid.y + lid.height, width: baseWidth, height: baseHeight)
            return DeviceRects(
                screen: screen, screenCornerRadius: 0, body: lid, bodyCornerRadius: M.macBookLidCorners * w, bandWidth: rim,
                cutout: notch, buttons: [], base: base, baseFrontRadius: baseHeight / 2,
                bounds: Rect(x: base.x, y: lid.y, width: base.width, height: lid.height + base.height))
        }
    }

    /// The largest `model` device around a screen of `contentAspect` (width over height; the room's own without one) whose
    /// bounds fit inside `padding × width` of space on every side of an output of `outputSize`, centred there:
    /// `deviceRects(around:model:)` of that screen. Every measure of a device is a fraction of its screen, so its bounds
    /// grow with it and touch the room along one axis. `nil` when the padding leaves no room.
    public static func deviceRects(
        contentAspect: Double?, padding: Double, outputSize: SIMD2<Double>, model: DeviceModel
    ) -> DeviceRects? {
        let margin = padding * outputSize.x
        let room = SIMD2(outputSize.x - 2 * margin, outputSize.y - 2 * margin)
        guard room.x > 0, room.y > 0, room.x.isFinite, room.y.isFinite else { return nil }
        let aspect = contentAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? room.x / room.y
        // Around a screen 1 tall, then scaled: the bounds are a fixed shape of the screen's.
        let unit = deviceRects(around: Rect(x: 0, y: 0, width: aspect, height: 1), model: model).bounds
        let scale = min(room.x / unit.width, room.y / unit.height)
        guard scale > 0, scale.isFinite else { return nil }
        let bounds = SIMD2(unit.width, unit.height) * scale
        let origin = (outputSize - bounds) / 2 - SIMD2(unit.x, unit.y) * scale
        return deviceRects(around: Rect(x: origin.x, y: origin.y, width: aspect * scale, height: scale), model: model)
    }
}
