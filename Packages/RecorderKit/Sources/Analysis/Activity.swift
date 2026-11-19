// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the user did during a take, as the automatic zoom reads it (design §8.1), in output time (integer nanoseconds
/// of `TimeMap`): clicks, drags, pauses of the cursor, typing and scrolling.
///
/// Only what is in a kept clip counts (what the time map cuts does not exist for it), and only what happens inside
/// what is shown of the screen shown at that instant (`StagePoints`); typing, which has no position, only has to be
/// kept. Points and boxes are in stage units; distances between pointer positions are in global points.
///
/// - Click: a left or right `mouseDown` that is not a drag. One less than 0.35 s and less than 6 pt after the previous
///   click is the same click (a double or triple click): the first stands for them all.
/// - Drag: a left or right `mouseDown` whose pointer goes more than 8 pt from where it went down before the `mouseUp`
///   of the same button (or the next `mouseDown` of it, or the end of the events): from its first kept pointer position
///   to its last, with the box of those that are shown.
/// - Pause of the cursor: once it went at least 80 pt since it last stood still, the cursor stays within 3 pt of a
///   position for at least 1.2 s (until a position farther away comes, or the output ends), with no left or right
///   `mouseDown` less than 1 s before or after: at the instant it stopped, where it stopped. Standing still, a pause or
///   not, starts the 80 pt again from where it leaves.
/// - Typing: `keyActivity` events at most 1.0 s apart, from the first to 0.25 s after the last (the 250 ms each one
///   stands for). `keyPress` events (version 4) never count: typing is the same with or without the keys recorded.
/// - Scroll: `scroll` events at most 0.5 s apart, from the first to the last.
///
/// The clips of a take are in source order (as `TimeMap` reads them in 1b), so source order is output order.
public struct Activity: Equatable, Sendable {
    /// A click, or a pause of the cursor.
    public struct Click: Equatable, Sendable {
        /// Output time.
        public var output: Int64
        /// In stage units.
        public var point: SIMD2<Double>
        /// The source instant.
        public var host: HostTime

        public init(output: Int64, point: SIMD2<Double>, host: HostTime) {
            self.output = output
            self.point = point
            self.host = host
        }
    }

    public struct Drag: Equatable, Sendable {
        /// Output times of its first and last kept pointer positions.
        public var start: Int64
        public var end: Int64
        /// The box of its shown pointer positions, in stage units.
        public var box: Rect

        public init(start: Int64, end: Int64, box: Rect) {
            self.start = start
            self.end = end
            self.box = box
        }
    }

    public var clicks: [Click]
    public var drags: [Drag]
    public var pauses: [Click]
    public var typing: [Range<Int64>]
    public var scrolls: [Range<Int64>]

    public init(clicks: [Click], drags: [Drag], pauses: [Click], typing: [Range<Int64>], scrolls: [Range<Int64>]) {
        self.clicks = clicks
        self.drags = drags
        self.pauses = pauses
        self.typing = typing
        self.scrolls = scrolls
    }

    /// The activity of `take` in the output of `timeMap` (the one of `document.sequence`), placed on `document`'s stage.
    public static func extract(take: TakeRecord, events: [InputEvent], document: EditDocument, timeMap: TimeMap) -> Activity {
        let stage = StagePoints(take: take, events: events, document: document)
        return ActivityExtraction(take: take, events: events, timeMap: timeMap, stage: stage).activity
    }

    // Design §8.1. Times in output nanoseconds, distances in global points.
    static let doubleClickInterval: Int64 = 350_000_000
    static let doubleClickDistance = 6.0
    static let dragDistance = 8.0
    static let pauseTravel = 80.0
    static let pauseRadius = 3.0
    static let pauseDuration: Int64 = 1_200_000_000
    static let pauseClickClearance: Int64 = 1_000_000_000
    static let typingGap: Int64 = 1_000_000_000
    static let typingTail: Int64 = 250_000_000
    static let scrollGap: Int64 = 500_000_000
}

/// A kept pointer position (`cursor`, `mouseDown` or `mouseUp`).
struct PointerSample: Sendable {
    var output: Int64
    var host: HostTime
    /// In global points.
    var point: SIMD2<Double>
}

/// The activity, with what the planner also reads: the kept pointer positions and where each click went down.
struct ActivityExtraction: Sendable {
    var activity: Activity
    /// In output order.
    var samples: [PointerSample]
    /// Where each of `activity.clicks` went down, in global points.
    var clickPoints: [SIMD2<Double>]

    init(take: TakeRecord, events: [InputEvent], timeMap: TimeMap, stage: StagePoints) {
        let ordered = events.sortedByTime()
        func kept(_ t: HostTime) -> Int64? { timeMap.output(atSource: t, take: take.id) }

        var samples: [PointerSample] = []
        // Every kept left or right `mouseDown`, drags too: no pause comes this close to one.
        var downs: [Int64] = []
        var clickCandidates: [(sample: PointerSample, point: SIMD2<Double>)] = []
        var drags: [Activity.Drag] = []
        var keys: [Int64] = []
        var scrolls: [Int64] = []
        for (index, event) in ordered.enumerated() {
            let output = kept(event.t)
            if let output, let point = event.kind.pointerPosition {
                samples.append(PointerSample(output: output, host: event.t, point: point))
            }
            switch event.kind {
            case let .mouseDown(button, x, y) where button != .other:
                if let output { downs.append(output) }
                let path = Self.path(from: index, button: button, in: ordered)
                let down = SIMD2(x, y)
                if path.contains(where: { distance($0.kind.pointerPosition ?? down, down) > Activity.dragDistance }) {
                    if let drag = Self.drag(path, kept: kept, stage: stage) { drags.append(drag) }
                } else if let output, let point = stage.stagePoint(global: down, at: event.t) {
                    clickCandidates.append((PointerSample(output: output, host: event.t, point: down), point))
                }
            case .keyActivity:
                if let output { keys.append(output) }
            case let .scroll(_, _, x, y):
                if let output, stage.stagePoint(global: SIMD2(x, y), at: event.t) != nil { scrolls.append(output) }
            default:
                break
            }
        }

        var clicks: [Activity.Click] = []
        var clickPoints: [SIMD2<Double>] = []
        var previous: PointerSample?
        for (sample, point) in clickCandidates {
            defer { previous = sample }
            if let previous, sample.output - previous.output < Activity.doubleClickInterval,
                distance(sample.point, previous.point) < Activity.doubleClickDistance
            {
                continue
            }
            clicks.append(Activity.Click(output: sample.output, point: point, host: sample.host))
            clickPoints.append(sample.point)
        }

        activity = Activity(
            clicks: clicks, drags: drags,
            pauses: Self.pauses(in: samples, downs: downs.sorted(), duration: timeMap.duration, stage: stage),
            typing: Self.spans(of: keys, gap: Activity.typingGap, tail: Activity.typingTail),
            scrolls: Self.spans(of: scrolls, gap: Activity.scrollGap, tail: 0))
        self.samples = samples
        self.clickPoints = clickPoints
    }

    /// The `mouseDown` at `index` and the pointer events after it up to the `mouseUp` of `button`, included; up to the
    /// next `mouseDown` of `button` or the end, without it, when that comes first.
    private static func path(from index: Int, button: MouseButton, in events: [InputEvent]) -> [InputEvent] {
        var path = [events[index]]
        for event in events[(index + 1)...] {
            switch event.kind {
            case let .mouseUp(other, _, _) where other == button:
                path.append(event)
                return path
            case let .mouseDown(other, _, _) where other == button:
                return path
            default:
                if event.kind.pointerPosition != nil { path.append(event) }
            }
        }
        return path
    }

    /// The drag of `path`: from its first kept position to its last, with the box of those shown; `nil` when none is
    /// both kept and shown.
    private static func drag(_ path: [InputEvent], kept: (HostTime) -> Int64?, stage: StagePoints) -> Activity.Drag? {
        let outputs = path.compactMap { kept($0.t) }
        let points = path.compactMap { event -> SIMD2<Double>? in
            guard kept(event.t) != nil, let global = event.kind.pointerPosition else { return nil }
            return stage.stagePoint(global: global, at: event.t)
        }
        guard let start = outputs.first, let end = outputs.last, let first = points.first else { return nil }
        let low = points.reduce(first) { pointwiseMin($0, $1) }
        let high = points.reduce(first) { pointwiseMax($0, $1) }
        return Activity.Drag(start: start, end: end, box: Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y))
    }

    /// The pauses of the cursor along `samples` (design §8.1), with `downs` the sorted outputs of the kept `mouseDown`s.
    private static func pauses(in samples: [PointerSample], downs: [Int64], duration: Int64, stage: StagePoints) -> [Activity.Click] {
        var pauses: [Activity.Click] = []
        // How far the cursor went since it last stood still, up to `samples[i]`.
        var traveled = 0.0
        var i = 0
        while i < samples.count {
            let anchor = samples[i]
            // The first position after the anchor that is farther than `pauseRadius` from it or `pauseDuration` after it.
            var j = i + 1
            while j < samples.count, samples[j].output - anchor.output < Activity.pauseDuration,
                distance(samples[j].point, anchor.point) <= Activity.pauseRadius
            {
                j += 1
            }
            let stillUntil = j < samples.count ? samples[j].output : duration
            guard stillUntil - anchor.output >= Activity.pauseDuration else {
                if i + 1 < samples.count { traveled += distance(samples[i + 1].point, samples[i].point) }
                i += 1
                continue
            }
            if traveled >= Activity.pauseTravel, !hasDown(near: anchor.output, in: downs),
                let point = stage.stagePoint(global: anchor.point, at: anchor.host)
            {
                pauses.append(Activity.Click(output: anchor.output, point: point, host: anchor.host))
            }
            // It stood still: the travel counts again from the first position that leaves.
            var leaving = j
            while leaving < samples.count, distance(samples[leaving].point, anchor.point) <= Activity.pauseRadius { leaving += 1 }
            traveled = leaving < samples.count ? distance(samples[leaving].point, samples[leaving - 1].point) : 0
            i = leaving
        }
        return pauses
    }

    /// Whether one of the sorted `downs` is less than `pauseClickClearance` from `t`.
    private static func hasDown(near t: Int64, in downs: [Int64]) -> Bool {
        var low = 0, high = downs.count
        while low < high {
            let mid = (low + high) / 2
            if downs[mid] <= t.subtractingSaturating(Activity.pauseClickClearance) { low = mid + 1 } else { high = mid }
        }
        return low < downs.count && downs[low] < t.addingSaturating(Activity.pauseClickClearance)
    }

    /// The spans of `times` at most `gap` apart: from the first of each to its last plus `tail`.
    private static func spans(of times: [Int64], gap: Int64, tail: Int64) -> [Range<Int64>] {
        var spans: [Range<Int64>] = []
        var current: (first: Int64, last: Int64)?
        for t in times.sorted() {
            if let span = current, t - span.last <= gap {
                current = (span.first, t)
                continue
            }
            if let span = current { spans.append(span.first..<span.last.addingSaturating(tail)) }
            current = (t, t)
        }
        if let span = current { spans.append(span.first..<span.last.addingSaturating(tail)) }
        return spans
    }
}

/// The distance from `a` to `b`.
func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    ((a - b) * (a - b)).sum().squareRoot()
}

extension Int64 {
    /// `self + other`, held at the ends of `Int64` instead of overflowing.
    func addingSaturating(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }

    /// `self - other`, held at the ends of `Int64` instead of overflowing.
    func subtractingSaturating(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : difference
    }
}
