// SPDX-License-Identifier: GPL-3.0-or-later

/// A spring as the design gives it: `damping` is the damping ratio (1 never overshoots) and `response`
/// the period, in seconds, of the undamped oscillation. SwiftUI's `.spring(response:dampingFraction:)`
/// takes the same two values.
public struct Spring: Equatable, Sendable {
    public var damping: Double
    public var response: Double

    public init(damping: Double, response: Double) {
        self.damping = damping
        self.response = response
    }
}

/// The motion of the island and its parts (notch design §5.3). Desktop switches are animated by macOS,
/// not by the app.
public enum Motion {
    /// The island opening, counting down, saved, choosing on the screen and showing a notice.
    public static let islandExpand = Spring(damping: 0.86, response: 0.56)
    /// The island peeking out when the pointer is over the notch.
    public static let islandPeek = Spring(damping: 0.90, response: 0.42)
    /// The island closing to rest, collapsing and its recording wings.
    public static let islandCollapse = Spring(damping: 1.0, response: 0.48)
    /// Segmented-control indicators, switch knobs and the on-screen highlight.
    public static let selector = Spring(damping: 1.0, response: 0.32)
    /// The camera bubble once it is let go, starting with the gesture's velocity.
    public static let bubbleRelease = Spring(damping: 0.82, response: 0.50)
    /// The camera bubble's shape and size (also in the render of style changes).
    public static let bubbleShape = Spring(damping: 0.95, response: 0.50)
    /// The panel's content when its tab or what it shows changes: a fade with a rise of 6 pt.
    public static let panelSwap = Spring(damping: 1.0, response: 0.30)
    /// Clips and blocks of the timeline settling (after a delete, a trim, a snap).
    public static let trackItem = Spring(damping: 0.90, response: 0.30)
    /// The timeline's scale with the keyboard or the buttons.
    public static let timelineZoom = Spring(damping: 1.0, response: 0.28)
    /// The timeline scrolling by itself.
    public static let timelineScroll = Spring(damping: 1.0, response: 0.36)
    /// The highlight when the pointer goes over clips, blocks and edges.
    public static let hover = Spring(damping: 1.0, response: 0.20)
    /// How far, in points, the panel's content rises as it appears.
    public static let panelSwapRise = 6.0

    /// How long after the island starts to change a state's content starts to appear.
    public static let contentDelay: Duration = .milliseconds(60)
    /// How long the content of the state being left takes to fade out.
    public static let contentExit: Duration = .milliseconds(170)
    /// The blur, in points, content appears from (to 0) and fades out to (from 0).
    public static let contentEnterBlur = 10.0
    public static let contentExitBlur = 8.0
    /// The scale content appears from (to 1).
    public static let contentEnterScale = 0.94
    /// With "Reduce motion", everything is a fade of this long, without scale or bounce.
    public static let reducedMotionFade: Duration = .milliseconds(200)
    /// A number of the countdown leaving, growing and blurring out (ease-in): the prototype's timing, which the
    /// design's table does not list.
    public static let countdownDigitExit: Duration = .milliseconds(280)
    /// The island's fade between the notch's black and the glass (ease-in-out): the prototype's timing, which the
    /// design's table does not list; `reducedMotionFade` with "Reduce motion".
    public static let notchBlend: Duration = .milliseconds(320)
}

/// One animated number (a width, a height, a radius) driven by a `Spring` toward its target. It can be
/// sent somewhere else midway: it keeps its value and velocity, so the motion never jumps.
public struct SpringValue: Equatable, Sendable {
    /// The longest substep `step` integrates at once, in seconds.
    private static let substep = 1.0 / 480
    /// Closer than this to the target, and slower than `settleVelocity`, the value is at rest.
    private static let settleDistance = 0.05
    private static let settleVelocity = 0.5

    public var value: Double
    /// Per second.
    public var velocity: Double
    public private(set) var target: Double
    public private(set) var spring: Spring

    /// At rest on `value`.
    public init(value: Double, spring: Spring) {
        self.value = value
        velocity = 0
        target = value
        self.spring = spring
    }

    /// Heads for `target` with `spring` from where it is now, at the speed it has now.
    public mutating func retarget(_ target: Double, spring: Spring) {
        self.target = target
        self.spring = spring
    }

    /// Advances `seconds` (nothing for zero or less): `a = −ω²(x − target) − 2ζωv`, with ω = 2π / response
    /// and ζ = damping, in substeps of 1/480 s at most (semi-implicit Euler). Once close enough and slow
    /// enough it lands exactly on the target.
    public mutating func step(by seconds: Double) {
        guard seconds > 0, seconds.isFinite, !isSettled else { return }
        let omega = 2 * Double.pi / spring.response
        let zeta = spring.damping
        let count = (seconds / Self.substep).rounded(.up)
        let dt = seconds / count
        for _ in 0..<Int(count) {
            let acceleration = -omega * omega * (value - target) - 2 * zeta * omega * velocity
            velocity += acceleration * dt
            value += velocity * dt
        }
        if abs(value - target) < Self.settleDistance, abs(velocity) < Self.settleVelocity {
            value = target
            velocity = 0
        }
    }

    /// On its target and still.
    public var isSettled: Bool {
        value == target && velocity == 0
    }
}
