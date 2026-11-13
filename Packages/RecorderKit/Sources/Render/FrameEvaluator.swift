// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Works out what an output frame shows at an output time: a pure function of the take, its events,
/// the style and the output size.
///
/// The screen is the take's first display track. Output time 0 is `timelineStart`, the start of that
/// track's first segment, and output times are clamped to `[0, duration]`. Its `TrackSource.globalFrame`
/// is the only geometry used in phase 0 (`displayGeometry` events are informational).
public struct FrameEvaluator: Sendable {
    /// Two cursor samples at most this far apart are interpolated; farther apart, the cursor stays put
    /// until the next one.
    static let maxInterpolationGap = 0.050

    /// Host time at output time 0.
    public private(set) var timelineStart: HostTime
    /// Seconds from `timelineStart` to the end of the screen's last segment.
    public private(set) var duration: Double

    private let style: StyleV0
    private let outputSize: SIMD2<Int>
    /// ID of the display track shown, `nil` if the take has none.
    let screenTrackID: String?
    /// `globalFrame` of the screen, `nil` if it is missing or empty.
    private let displayFrame: Rect?
    private let contentRect: Rect
    /// Cursor, mouse-down and mouse-up positions in global points, in time order.
    private let positions: [(t: HostTime, point: SIMD2<Double>)]

    public init(take: TakeRecord, events: [InputEvent], style: StyleV0, outputSize: SIMD2<Int>) {
        self.style = style
        self.outputSize = outputSize
        let screen = take.tracks.first { $0.kind == .display }
        screenTrackID = screen?.id
        let segments = screen?.segments ?? []
        let start = segments.map(\.startHostTime).min() ?? HostTime(nanoseconds: 0)
        // An open segment (no end yet) counts up to its start.
        let end = segments.map { $0.endHostTime ?? $0.startHostTime }.max() ?? start
        timelineStart = start
        duration = max(0, end.seconds(since: start))

        if let frame = screen?.source.globalFrame, frame.width > 0, frame.height > 0,
           [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) {
            displayFrame = frame
        } else {
            displayFrame = nil
        }
        contentRect = Self.contentRect(aspect: displayFrame.map { $0.width / $0.height }, style: style, outputSize: outputSize)

        // events.jsonl is in append order, which can be slightly out of `t` order: sort, keeping the
        // file order of events with the same `t`.
        positions = events.enumerated()
            .compactMap { offset, event -> (offset: Int, t: HostTime, point: SIMD2<Double>)? in
                switch event.kind {
                case let .cursor(x, y), let .mouseDown(_, x, y), let .mouseUp(_, x, y):
                    return (offset, event.t, SIMD2(x, y))
                default:
                    return nil
                }
            }
            .sorted { ($0.t, $0.offset) < ($1.t, $1.offset) }
            .map { ($0.t, $0.point) }
    }

    public func frame(at outputTime: Double) -> RenderFrame {
        let time = outputTime.isNaN ? 0 : min(max(outputTime, 0), duration)
        let host = timelineStart.adding(seconds: time)
        return RenderFrame(
            outputSize: outputSize,
            gradientStart: style.gradientStart,
            gradientEnd: style.gradientEnd,
            gradientAngleDegrees: style.gradientAngleDegrees,
            screen: screenTrackID.map {
                ScreenLayer(
                    trackID: $0, sourceTime: host, rect: contentRect,
                    cornerRadius: style.cornerRadiusFraction * Double(outputSize.x))
            },
            cursor: cursor(at: host)
        )
    }

    /// The screen's rect: the area inside the padding, or the largest rect of the screen's aspect
    /// centred in it. Without a usable `globalFrame`, the whole area inside the padding.
    private static func contentRect(aspect: Double?, style: StyleV0, outputSize: SIMD2<Int>) -> Rect {
        let width = Double(outputSize.x), height = Double(outputSize.y)
        let padding = style.paddingFraction * width
        let available = SIMD2(max(width - 2 * padding, 0), max(height - 2 * padding, 0))
        var size = available
        if let aspect, available.x > 0, available.y > 0 {
            size = available.x / available.y > aspect
                ? SIMD2(available.y * aspect, available.y)
                : SIMD2(available.x, available.x / aspect)
        }
        return Rect(x: (width - size.x) / 2, y: (height - size.y) / 2, width: size.x, height: size.y)
    }

    /// The cursor at `host`: the last position at or before it, moved toward the next one if that comes
    /// within `maxInterpolationGap`. `nil` before the first position, off the recorded display, or
    /// without a display geometry.
    private func cursor(at host: HostTime) -> CursorLayer? {
        guard let displayFrame, screenTrackID != nil else { return nil }
        // Index of the first position after `host`.
        var low = 0, high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid].t <= host { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let previous = positions[low - 1]
        var point = previous.point
        if low < positions.count {
            let next = positions[low]
            let gap = next.t.seconds(since: previous.t)
            if gap <= Self.maxInterpolationGap {
                point += (next.point - previous.point) * (host.seconds(since: previous.t) / gap)
            }
        }
        let global = CGPoint(x: point.x, y: point.y)
        guard CursorGeometry.contains(global, displayFrame) else { return nil }
        let normalized = CursorGeometry.normalized(global, in: displayFrame)
        let rect = contentRect
        return CursorLayer(
            hotspot: SIMD2(rect.x, rect.y) + normalized * SIMD2(rect.width, rect.height),
            height: style.cursorPointHeight * rect.height / displayFrame.height
        )
    }
}
