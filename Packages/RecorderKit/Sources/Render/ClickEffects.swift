// SPDX-License-Identifier: GPL-3.0-or-later

/// A click effect over the stage (`ClickEffects`): in stage coordinates, output pixels with the stage unzoomed, like
/// the cursor, so the zoom enlarges it with the stage; drawn over the cursor, and never blurred (plan decision 26).
/// Nothing is drawn of one at opacity 0 or of no size.
public struct ClickEffectLayer: Equatable, Sendable {
    public enum Kind: Sendable {
        /// A white ring `thickness` across, centred on the circle of `radius`, with a 1 px black outline along both its
        /// edges (`ClickEffects.outlineOpacity(of:)`) so it shows on white.
        case ripple
        /// A white disc of `radius`.
        case circle
    }

    public var kind: Kind
    /// In output pixels, origin at the top left: where the click went down.
    public var center: SIMD2<Double>
    /// In output pixels.
    public var radius: Double
    /// In output pixels: a ripple's ring, across; 0 for a circle, which is filled.
    public var thickness: Double
    /// Of the white: 0 to 1.
    public var opacity: Double

    public init(kind: Kind, center: SIMD2<Double>, radius: Double, thickness: Double, opacity: Double) {
        self.kind = kind
        self.center = center
        self.radius = radius
        self.thickness = thickness
        self.opacity = opacity
    }
}

/// The click effects of the cursor's `clickEffect` at one instant of the output (design §7.5), each frozen with its id.
/// `h` is the height of the cursor drawn at the click (`CursorLayer.height`, before its press); times are output times.
///
/// - `ripple-1`: for 0.5 s from each click, τ seconds after it, a ring of radius `h × (0.25 + 1.35 × easeOutCubic(τ /
///   0.5))` and `0.08 h` across, white at opacity `0.55 × (1 − τ / 0.5)²`, with a 1 px outline of black at 25 % at the
///   click that fades with the white (`outlineOpacity(of:)`). The fading outline is part of `ripple-1`'s look, frozen
///   with it: a constant 25 % would leave a dark ring alone once the white is gone, and vanish at 0.5 s.
/// - `circle-1`: from each click until its press ends, a white disc at 22 % of radius `0.9 h`, which enters scaling
///   linearly from 0.6 to 1 over its first 0.12 s; from the end of the press on, its opacity goes down linearly to 0
///   over 0.20 s. A press ends at the first release at or after its click, or at the next click if that comes first: a
///   release the events lost never holds a circle past the next click.
/// - `none`, and an id this version does not know: nothing.
public enum ClickEffects {
    static let rippleID = "ripple-1"
    static let circleID = "circle-1"

    static let rippleDuration: Int64 = 500_000_000
    static let rippleOpacity = 0.55
    /// At the click; it fades with the white (`ripple-1`'s look).
    static let rippleOutline = 0.25
    static let circleOpacity = 0.22
    static let circleGrowth: Int64 = 120_000_000
    static let circleFade: Int64 = 200_000_000

    /// The effects shown at output time `τ`, in click order (the latest drawn last).
    ///
    /// - Parameters:
    ///   - clicks: the output times of the kept clicks, in output order (`CursorPath.clicks`).
    ///   - releases: when a button goes up and none is down any more, in output order (`CursorPath.releases`).
    ///   - effect: the document's `cursor.clickEffect`.
    ///   - place: where the effect of the click at an index of `clicks` is on the frame drawn, in output pixels, and
    ///     its `h` there, both as the click was (its point and its cursor at its own instant); `nil` when it is not
    ///     shown (not on the screen shown). Called only for the clicks whose effect is under way; one without a
    ///     placement, or with an `h` that is not positive and finite, has no effect.
    public static func layers(
        atOutput τ: Int64, clicks: [Int64], releases: [Int64], effect: String,
        place: (_ click: Int) throws -> (center: SIMD2<Double>, cursorHeight: Double)?
    ) rethrows -> [ClickEffectLayer] {
        // The clicks whose effect is under way at `τ` are `start..<end`: effects begin in click order and end in click
        // order too (a ripple 0.5 s after its click, a circle 0.20 s after its press, and presses end in click order).
        let end = partitionPoint(clicks.count) { clicks[$0] > τ }
        let kind: ClickEffectLayer.Kind, start: Int
        switch effect {
        case rippleID:
            kind = .ripple
            start = partitionPoint(end) { τ - clicks[$0] < rippleDuration }
        case circleID:
            kind = .circle
            start = partitionPoint(end) { i in
                pressEnd(of: i, clicks: clicks, releases: releases).map { τ - $0 < circleFade } ?? true
            }
        default:
            return []
        }
        guard start < end else { return [] }
        var layers: [ClickEffectLayer] = []
        layers.reserveCapacity(end - start)
        for i in start..<end {
            guard let (center, h) = try place(i), h > 0, h.isFinite else { continue }
            let since = seconds(τ - clicks[i])
            switch kind {
            case .ripple:
                let progress = since / seconds(rippleDuration)
                let eased = 1 - (1 - progress) * (1 - progress) * (1 - progress)
                let fade = (1 - progress) * (1 - progress)
                layers.append(ClickEffectLayer(
                    kind: .ripple, center: center, radius: h * (0.25 + 1.35 * eased), thickness: 0.08 * h,
                    opacity: rippleOpacity * fade))
            case .circle:
                var opacity = circleOpacity
                if let pressEnd = pressEnd(of: i, clicks: clicks, releases: releases), τ >= pressEnd {
                    opacity *= 1 - seconds(τ - pressEnd) / seconds(circleFade)
                }
                let scale = 0.6 + 0.4 * min(since / seconds(circleGrowth), 1)
                layers.append(
                    ClickEffectLayer(kind: .circle, center: center, radius: 0.9 * h * scale, thickness: 0, opacity: opacity))
            }
        }
        return layers
    }

    /// When the press of click `i` ends: at the first of `releases` at or after it, or at the next click if that comes
    /// first; `nil` while it is held to the end. In click order, since both are: an earlier click's press never ends
    /// after a later one's.
    private static func pressEnd(of i: Int, clicks: [Int64], releases: [Int64]) -> Int64? {
        let first = partitionPoint(releases.count) { releases[$0] >= clicks[i] }
        let release = first < releases.count ? releases[first] : nil
        let next = i + 1 < clicks.count ? clicks[i + 1] : nil
        guard let release else { return next }
        return next.map { min($0, release) } ?? release
    }

    /// The opacity of the 1 px black outline of `layer`: a ripple's is 25 % at the click and fades with its white
    /// (`0.25 × (1 − τ / 0.5)²`, so `0.25 / 0.55` of the white's opacity); a circle has none.
    static func outlineOpacity(of layer: ClickEffectLayer) -> Double {
        switch layer.kind {
        case .ripple: layer.opacity * rippleOutline / rippleOpacity
        case .circle: 0
        }
    }

    /// The first index of `0..<count` at which `isPast` holds, with `isPast` false before some index and true from it
    /// on.
    private static func partitionPoint(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if isPast(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private static func seconds(_ nanoseconds: Int64) -> Double {
        Double(nanoseconds) / 1e9
    }
}
