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
/// `h` is the drawn cursor's height (`CursorLayer.height`, before its press); times are output times.
///
/// - `ripple-1`: for 0.5 s from each click, τ seconds after it, a ring of radius `h × (0.25 + 1.35 × easeOutCubic(τ /
///   0.5))` and `0.08 h` across, white at opacity `0.55 × (1 − τ / 0.5)²`, with a 1 px outline of black at 25 % at the
///   click, fading with the white (`outlineOpacity(of:)`).
/// - `circle-1`: from each click until its release, a white disc at 22 % of radius `0.9 h`, which enters scaling
///   linearly from 0.6 to 1 over its first 0.12 s; from the release on, its opacity goes down linearly to 0 over
///   0.20 s.
/// - `none`, and an id this version does not know: nothing.
public enum ClickEffects {
    static let rippleID = "ripple-1"
    static let circleID = "circle-1"

    static let rippleDuration: Int64 = 500_000_000
    static let rippleOpacity = 0.55
    static let rippleOutline = 0.25
    static let circleOpacity = 0.22
    static let circleGrowth: Int64 = 120_000_000
    static let circleFade: Int64 = 200_000_000

    /// The effects shown at output time `τ`, in click order (the latest drawn last).
    ///
    /// - Parameters:
    ///   - clicks: the kept clicks, in output order (`CursorPath.clicks`), each where it went down; one for which `place`
    ///     has no point has no effect.
    ///   - releases: when a button goes up and none is down any more, in output order; a click is pressed until the
    ///     first of them at or after it, or to the end without one.
    ///   - effect: the document's `cursor.clickEffect`.
    ///   - cursorHeight: `h`, in output pixels; nothing without a positive, finite one.
    ///   - place: where a click's point is on the stage, in output pixels; `nil` off what is shown of the screen.
    public static func layers(
        atOutput τ: Int64, clicks: [(output: Int64, point: SIMD2<Double>)], releases: [Int64], effect: String,
        cursorHeight: Double, place: (SIMD2<Double>) -> SIMD2<Double>?
    ) -> [ClickEffectLayer] {
        guard cursorHeight > 0, cursorHeight.isFinite else { return [] }
        let h = cursorHeight
        // The clicks at or before `τ`, from the latest back while they are still shown.
        var index = partitionPoint(clicks.count) { clicks[$0].output > τ }
        var layers: [ClickEffectLayer] = []
        switch effect {
        case rippleID:
            while index > 0, τ - clicks[index - 1].output < rippleDuration {
                index -= 1
                guard let center = place(clicks[index].point) else { continue }
                let progress = seconds(τ - clicks[index].output) / seconds(rippleDuration)
                let eased = 1 - (1 - progress) * (1 - progress) * (1 - progress)
                let fade = (1 - progress) * (1 - progress)
                layers.append(ClickEffectLayer(
                    kind: .ripple, center: center, radius: h * (0.25 + 1.35 * eased), thickness: 0.08 * h,
                    opacity: rippleOpacity * fade))
            }
        case circleID:
            while index > 0 {
                index -= 1
                let click = clicks[index].output
                let first = partitionPoint(releases.count) { releases[$0] >= click }
                let release = first < releases.count ? releases[first] : nil
                var opacity = circleOpacity
                if let release, τ >= release {
                    // A click before this one is released at or before this one's release: out by now too.
                    guard τ - release < circleFade else { break }
                    opacity *= 1 - seconds(τ - release) / seconds(circleFade)
                }
                guard let center = place(clicks[index].point) else { continue }
                let scale = 0.6 + 0.4 * min(seconds(τ - click) / seconds(circleGrowth), 1)
                layers.append(
                    ClickEffectLayer(kind: .circle, center: center, radius: 0.9 * h * scale, thickness: 0, opacity: opacity))
            }
        default:
            return []
        }
        return layers.reversed()
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
