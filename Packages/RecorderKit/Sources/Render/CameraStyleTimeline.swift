// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// Where the camera is drawn at any time of a take: its initial style, then each `cameraStyle` event reached with
/// the spring of the bubble's shape and size (notch design §5.3 and §5.6, plan decision 26), so the video follows
/// the bubble the way it moved on screen.
///
/// The region is the whole output. At an event, the position, the size and the corner radius go from what was shown
/// at that instant (the transition before it included, so a burst of changes never jumps) to the new style's
/// `CameraStyle.frame(in:)`, along `progress` of the time since the event.
public struct CameraStyleTimeline: Equatable, Sendable {
    /// The spring of the bubble's shape and size (`Motion` in the app): damping ratio and response in seconds.
    public static let damping = 0.95
    public static let response = 0.5
    /// From this long after a change on, it is done: `progress` is 1.
    public static let settleSeconds = 1.5

    private struct Change: Equatable, Sendable {
        var t: HostTime
        var style: CameraStyle
    }

    private let initial: CameraStyle
    /// The `cameraStyle` events, in time order.
    private let changes: [Change]

    public init(initial: CameraStyle, events: [InputEvent]) {
        self.initial = initial
        changes = events
            .filter { if case .cameraStyle = $0.kind { true } else { false } }
            .sortedByTime()
            .compactMap { event in
                guard case let .cameraStyle(style) = event.kind else { return nil }
                return Change(t: event.t, style: style)
            }
    }

    /// The camera at `host` in an output of `output` pixels.
    public func frame(at host: HostTime, output: SIMD2<Double>) -> CameraFrame {
        let region = Rect(x: 0, y: 0, width: output.x, height: output.y)
        // Index of the first change after `host`.
        var low = 0, high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return initial.frame(in: region) }
        // A change made once the one before it had settled starts from that one's style exactly: go back to the
        // first change of the burst that ends at `host`, and play the burst forward from there.
        var first = low - 1
        while first > 0, changes[first].t.seconds(since: changes[first - 1].t) < Self.settleSeconds { first -= 1 }
        var shown = first == 0 ? initial.frame(in: region) : changes[first - 1].style.frame(in: region)
        for k in first..<low {
            let until = k + 1 < low ? changes[k + 1].t : host
            shown = Self.blend(shown, changes[k].style.frame(in: region), Self.progress(seconds: until.seconds(since: changes[k].t)))
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
