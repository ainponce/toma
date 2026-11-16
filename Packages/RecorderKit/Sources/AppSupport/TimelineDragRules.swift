// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat

/// The rules of the timeline's drags (design §5.5), as pure functions: where a trimmed edge goes in the source, what snaps
/// to what, when a drag in an empty place makes a zoom, the marks of a drag on the ruler and the trim's label.
public enum TimelineDragRules {
    /// How far, in points, the mouse goes from where it went down before a click is a drag.
    public static let dragThreshold = 3.0

    public static func isDrag(from down: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - down.x, point.y - down.y) >= dragThreshold
    }

    /// The source instant a clip that starts at `clipStart` in the source and `clipOutputStart` in the output, at `speed`,
    /// shows at output time `output` if it went on (or began) as it is: `clipStart + round((output − clipOutputStart) ×
    /// speed)`, never before 0 or past the largest instant. The edge being trimmed to `output` is that source instant.
    public static func sourceInstant(atOutput output: Int64, clipOutputStart: Int64, clipStart: HostTime, speed: Double) -> HostTime {
        let speed = ClipSpeed.clamped(speed)
        let (difference, overflow) = output.subtractingReportingOverflow(clipOutputStart)
        let span = overflow ? (output > clipOutputStart ? Int64.max : Int64.min) : difference
        let scaled = (Double(span) * speed).rounded()
        let offset: Int64 = scaled >= Double(Int64.max) ? .max : scaled <= Double(Int64.min) ? .min : Int64(scaled)
        if offset >= 0 {
            let (sum, over) = clipStart.nanoseconds.addingReportingOverflow(UInt64(offset))
            return HostTime(nanoseconds: over ? .max : sum)
        }
        let back = offset.magnitude
        return HostTime(nanoseconds: clipStart.nanoseconds > back ? clipStart.nanoseconds - back : 0)
    }

    /// Snapping is on, N toggles it and ⌘ held while dragging inverts it.
    public static func snapActive(enabled: Bool, commandHeld: Bool) -> Bool {
        enabled != commandHeld
    }

    /// `t` at the closest of `points` (the edit points) and `extra` (the playhead, the marks) if one is within `tolerance`;
    /// otherwise `t`. Of two as close, the earlier. With `active` off, `t`.
    public static func snap(_ t: Int64, points: [Int64], extra: [Int64], tolerance: Int64, active: Bool) -> Int64 {
        guard active, tolerance >= 0 else { return t }
        var best: Int64?
        for candidate in points + extra {
            let distance = candidate > t ? candidate.subtractingReportingOverflow(t) : t.subtractingReportingOverflow(candidate)
            guard !distance.overflow, distance.partialValue <= tolerance else { continue }
            if let current = best {
                let known = current > t ? current - t : t - current
                if distance.partialValue < known || (distance.partialValue == known && candidate < current) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best ?? t
    }

    /// The shift to move `range` by when the mouse moved it `delta`: `delta`, or the one that puts its start or its end on a
    /// point it is within `tolerance` of, the smaller change if both could.
    public static func snapShift(
        of range: Range<Int64>, by delta: Int64, points: [Int64], extra: [Int64], tolerance: Int64, active: Bool
    ) -> Int64 {
        guard active else { return delta }
        let start = range.lowerBound + delta, end = range.upperBound + delta
        let snappedStart = snap(start, points: points, extra: extra, tolerance: tolerance, active: true) - start
        let snappedEnd = snap(end, points: points, extra: extra, tolerance: tolerance, active: true) - end
        let changes = [snappedStart, snappedEnd].filter { $0 != 0 }
        guard let smallest = changes.min(by: { ($0.magnitude, $0) < ($1.magnitude, $1) }) else { return delta }
        return delta + smallest
    }

    /// The zoom block a drag in an empty place of the Zoom track makes, from output `a` to `b` in either direction, cut to
    /// the output; `nil` while it is shorter than `minimum` (0.3 s: `ZoomCommands.minimumDuration`).
    public static func creationRange(from a: Int64, to b: Int64, duration: Int64, minimum: Int64 = 300_000_000) -> Range<Int64>? {
        let lower = min(max(min(a, b), 0), duration), upper = min(max(max(a, b), 0), duration)
        guard upper - lower >= minimum else { return nil }
        return lower..<upper
    }

    /// The in and out marks.
    public struct Marks: Equatable, Sendable {
        public var `in`: Int64
        public var out: Int64

        public init(in: Int64, out: Int64) {
            self.in = `in`
            self.out = out
        }
    }

    /// The marks a ⌥-drag on the ruler from `a` to `b` makes, in either direction, cut to the output; `nil` for an empty range.
    public static func marks(from a: Int64, to b: Int64, duration: Int64) -> Marks? {
        let lower = min(max(min(a, b), 0), duration), upper = min(max(max(a, b), 0), duration)
        return lower < upper ? Marks(in: lower, out: upper) : nil
    }

    /// The label of a trim (design §5.5), "−1,20 s · 0:18,40": how far the edge moved in output time, and where it is, in
    /// the user's decimal separator; `total` is what the output lasts, so a long one reads its times with hours.
    public static func trimLabel(delta: Int64, position: Int64, total: Int64, locale: Locale) -> String {
        let separator = locale.decimalSeparator ?? "."
        let hundredths = Int64((Double(delta.magnitude) / 1e7).rounded())
        let sign = hundredths == 0 ? "" : (delta < 0 ? "\u{2212}" : "+")
        let fraction = hundredths % 100
        let change = "\(sign)\(hundredths / 100)\(separator)\(fraction < 10 ? "0" : "")\(fraction) s"
        let time = Timecode.precise(Double(position) / 1e9, total: Double(total) / 1e9, locale: locale)
        return change + " \u{00B7} " + time
    }

    // MARK: - The scale's slider

    /// Where `scale` is on the bar's slider, from 0 (`fit`, the whole sequence in the width) to 1 (`TimelineLayout.maxPointsPerSecond`),
    /// by the logarithm: equal steps change the scale by the same ratio. 0 when there is no range.
    public static func sliderValue(scale: Double, fit: Double) -> Double {
        let top = TimelineLayout.maxPointsPerSecond
        guard fit > 0, fit < top, scale > 0, scale.isFinite else { return 0 }
        return min(max(log(scale / fit) / log(top / fit), 0), 1)
    }

    /// The scale at `value` of the slider (0 to 1), the inverse of `sliderValue(scale:fit:)`.
    public static func sliderScale(value: Double, fit: Double) -> Double {
        let top = TimelineLayout.maxPointsPerSecond
        guard fit > 0, fit < top, value.isFinite else { return min(max(fit, 0), top) }
        return fit * pow(top / fit, min(max(value, 0), 1))
    }
}
