// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where the camera is drawn at any output time: its initial style, then each change reached with the spring of the
/// bubble's shape and size (notch design §5.3 and §5.6, plan decision 26), so the video follows the bubble the way it
/// moved on screen.
///
/// Times are output nanoseconds (`TimeMap`); the caller places each change of the source in the output (a change in a
/// cut rules from `TimeMap.firstKeptOutput`). The region is the whole output. At a change, the position, the size and
/// the corner radius go from what was shown at that instant (the transition before it included, so a burst of changes
/// never jumps) to the new style's `CameraStyle.frame(in:)`, along `progress` of the time since the change.
public struct CameraStyleTimeline: Equatable, Sendable {
    /// The spring of the bubble's shape and size (`Motion` in the app): damping ratio and response in seconds.
    public static let damping = 0.95
    public static let response = 0.5
    /// From this long after a change on, it is done: `progress` is 1.
    public static let settleSeconds = 1.5

    private struct Change: Equatable, Sendable {
        var t: Int64
        var style: CameraStyle
    }

    private let initial: CameraStyle
    /// In time order.
    private let changes: [Change]

    /// `changes` at their output times, in any order; changes at the same time keep the order they have here.
    public init(initial: CameraStyle, changes: [(t: Int64, style: CameraStyle)]) {
        self.initial = initial
        self.changes = changes.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map { Change(t: $0.element.t, style: $0.element.style) }
    }

    /// The camera at output time `τ` in an output of `output` pixels, each style placed with `CameraStyle
    /// .frame(in:reference:)`: against the output's height, as in 1b, bit for bit (`frame(in:)`), or against its shorter
    /// side (1c design §5.2).
    public func frame(atOutput τ: Int64, output: SIMD2<Double>, reference: SizeReference = .height) -> CameraFrame {
        let region = Rect(x: 0, y: 0, width: output.x, height: output.y)
        func frame(_ style: CameraStyle) -> CameraFrame { style.frame(in: region, reference: reference) }
        // Index of the first change after `τ`.
        var low = 0, high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].t <= τ { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return frame(initial) }
        // Settled: exactly the last style.
        if Self.seconds(τ, since: changes[low - 1].t) >= Self.settleSeconds { return frame(changes[low - 1].style) }
        // A change made once the one before it had settled starts from that one's style exactly: go back to the
        // first change of the burst that ends at `τ`, and play the burst forward from there.
        var first = low - 1
        while first > 0, Self.seconds(changes[first].t, since: changes[first - 1].t) < Self.settleSeconds { first -= 1 }
        var shown = first == 0 ? frame(initial) : frame(changes[first - 1].style)
        for k in first..<low {
            let until = k + 1 < low ? changes[k + 1].t : τ
            shown = Self.blend(shown, frame(changes[k].style), Self.progress(seconds: Self.seconds(until, since: changes[k].t)))
        }
        return shown
    }

    /// How far a change has got `seconds` after it, 0 to 1: the step response of the spring,
    /// `1 − e^(−ζωt)(cos(ω_d t) + (ζω/ω_d) sin(ω_d t))` with ζ = `damping`, ω = 2π / `response` and
    /// ω_d = ω√(1 − ζ²). 0 up to 0 s (and for NaN), 1 from `settleSeconds` on.
    public static func progress(seconds t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < settleSeconds else { return 1 }
        let omega = 2 * Double.pi / response
        let dampedOmega = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * t)
        return 1 - decay * (cos(dampedOmega * t) + damping * omega / dampedOmega * sin(dampedOmega * t))
    }

    /// Seconds from output time `b` to `a`, counted as `HostTime.seconds(since:)` counts them.
    private static func seconds(_ a: Int64, since b: Int64) -> Double {
        (Double(a) - Double(b)) / 1_000_000_000
    }

    /// `from` at 0, `to` at 1, exactly.
    private static func blend(_ from: CameraFrame, _ to: CameraFrame, _ p: Double) -> CameraFrame {
        func mix(_ a: Double, _ b: Double) -> Double { a * (1 - p) + b * p }
        return CameraFrame(
            rect: Rect(
                x: mix(from.rect.x, to.rect.x), y: mix(from.rect.y, to.rect.y),
                width: mix(from.rect.width, to.rect.width), height: mix(from.rect.height, to.rect.height)),
            cornerRadius: mix(from.cornerRadius, to.cornerRadius))
    }
}
