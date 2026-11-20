// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The automatic zoom with the keyboard's focus, `focusZoom-1` (fases 4 y 5 design §5.2; plan 4a decisions 7 to 11):
/// what `ActivityExtraction` reads of a take's `focus` events (`Activity.caretRuns` and `Activity.focusChanges`), and the
/// blocks `AutoZoomPlanner` makes of them with `AutoZoomSettings.followsFocus`. The id names that extraction and those
/// rules: changing any of them is another id. The blocks keep the ids of `autoZoom-1` (`AutoZoomPlanner.regionID`), and
/// the document holds nothing of it but `followsFocus`.
///
/// - The text cursor while typing. The `caret`s of a span of typing (`Activity.typing`, of `keyActivity`) are those kept
///   in the span whose centre is shown on the stage (`StagePoints`); one before the span is not, as it can be another
///   app's. Without `keyActivity` there are no spans, so the focus zooms only on changes of the element.
/// - A change of the focused element: an `element` that is not the first `focus` of the take nor the first at or after a
///   `resumed` (the state, not a change), with no left or right `mouseDown` in the `clickClearance` of source before it
///   (it came from a click), no other `element` in the `stableDuration` of source after it (stable), kept outside the
///   spans with text cursors (a field that grows as it is typed in), no larger than `largestFraction` of what is shown of
///   the screen on either axis, and with its centre shown.
public enum FocusZoom {
    public static let id = "focusZoom-1"

    /// How long of source an element stays before it is a change: no other `element` comes in it. Nanoseconds.
    static let stableDuration: Int64 = 400_000_000
    /// How long of source after a left or right `mouseDown` an element came from the click. Nanoseconds.
    static let clickClearance: Int64 = 500_000_000
    /// An element larger than this fraction of what is shown of the screen, on either axis, makes no zoom.
    static let largestFraction = 0.7
    /// The deepest a block with a change of the element zooms.
    static let maximumDepth = 2.5
}

extension Activity {
    /// The text cursor at an instant of a span of typing.
    public struct Caret: Equatable, Sendable {
        /// Output time.
        public var output: Int64
        /// In stage units: its rect cut to what is shown of the screen.
        public var box: Rect
        /// The source instant.
        public var host: HostTime

        public init(output: Int64, box: Rect, host: HostTime) {
            self.output = output
            self.box = box
            self.host = host
        }
    }

    /// A span of typing with the text cursors in it, in output order.
    public struct CaretRun: Equatable, Sendable {
        /// The span, as in `Activity.typing`.
        public var span: Range<Int64>
        public var carets: [Caret]

        public init(span: Range<Int64>, carets: [Caret]) {
            self.span = span
            self.carets = carets
        }
    }

    /// A change of the focused element (`FocusZoom`).
    public struct FocusChange: Equatable, Sendable {
        /// Output time.
        public var output: Int64
        /// In stage units: its rect cut to what is shown of the screen.
        public var box: Rect
        /// The source instant.
        public var host: HostTime

        public init(output: Int64, box: Rect, host: HostTime) {
            self.output = output
            self.box = box
            self.host = host
        }
    }
}

/// What `focusZoom-1` reads of a take's events (`FocusZoom`).
enum FocusExtraction {
    /// The spans of `typing` (in output order, apart) with text cursors in them, and the changes of the element, from the
    /// take's events sorted by time (`ordered`), `kept` the output of a source instant (`nil` where it is cut).
    static func extract(
        _ ordered: [InputEvent], typing: [Range<Int64>], kept: (HostTime) -> Int64?, stage: StagePoints
    ) -> (caretRuns: [Activity.CaretRun], focusChanges: [Activity.FocusChange]) {
        let runs = caretRuns(ordered, typing: typing, kept: kept, stage: stage)
        return (runs, focusChanges(ordered, caretRuns: runs.map(\.span), kept: kept, stage: stage))
    }

    private static func caretRuns(
        _ ordered: [InputEvent], typing: [Range<Int64>], kept: (HostTime) -> Int64?, stage: StagePoints
    ) -> [Activity.CaretRun] {
        var carets = [[Activity.Caret]](repeating: [], count: typing.count)
        for event in ordered {
            guard case let .focus(x, y, width, height, .caret) = event.kind, let output = kept(event.t),
                let index = span(containing: output, in: typing)
            else { continue }
            let rect = Rect(x: x, y: y, width: width, height: height)
            guard stage.stagePoint(global: center(of: rect), at: event.t) != nil, let box = stage.stageRect(global: rect, at: event.t)
            else { continue }
            carets[index].append(Activity.Caret(output: output, box: box, host: event.t))
        }
        return zip(typing, carets).compactMap { $1.isEmpty ? nil : Activity.CaretRun(span: $0, carets: $1) }
    }

    private static func focusChanges(
        _ ordered: [InputEvent], caretRuns: [Range<Int64>], kept: (HostTime) -> Int64?, stage: StagePoints
    ) -> [Activity.FocusChange] {
        // The source instants of the elements, in order: whether another one comes in `stableDuration`.
        let elements = ordered.compactMap { event -> HostTime? in
            if case .focus(_, _, _, _, .element) = event.kind { event.t } else { nil }
        }
        var next = 0
        var changes: [Activity.FocusChange] = []
        // The focus is the state at the start of the take and again from each `resumed`: the instant of the first `focus`
        // since then, `nil` while none came.
        var awaitingState = true
        var stateInstant: HostTime?
        var lastDown: HostTime?
        for event in ordered {
            switch event.kind {
            case .resumed:
                awaitingState = true
            case let .mouseDown(button, _, _) where button != .other:
                lastDown = event.t
            case let .focus(x, y, width, height, kind):
                if awaitingState {
                    (awaitingState, stateInstant) = (false, event.t)
                }
                guard kind == .element else { continue }
                // This element is `elements[next]`: the following one is after it.
                next += 1
                guard event.t != stateInstant else { continue }
                if let down = lastDown, event.t.nanoseconds - down.nanoseconds <= UInt64(FocusZoom.clickClearance) { continue }
                if next < elements.count, elements[next].nanoseconds - event.t.nanoseconds <= UInt64(FocusZoom.stableDuration) { continue }
                guard let output = kept(event.t), span(containing: output, in: caretRuns) == nil else { continue }
                let rect = Rect(x: x, y: y, width: width, height: height)
                guard let shown = stage.shownPart(global: rect, at: event.t), let region = shown.view.region,
                    shown.rect.width / region.width <= FocusZoom.largestFraction,
                    shown.rect.height / region.height <= FocusZoom.largestFraction,
                    stage.stagePoint(global: center(of: rect), at: event.t) != nil,
                    let box = stage.stageRect(global: rect, at: event.t)
                else { continue }
                changes.append(Activity.FocusChange(output: output, box: box, host: event.t))
            default:
                break
            }
        }
        return changes
    }

    /// The index of the one of `spans` (in order and apart) that contains `t`; `nil` outside them.
    private static func span(containing t: Int64, in spans: [Range<Int64>]) -> Int? {
        var (low, high) = (0, spans.count)
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].upperBound <= t { low = middle + 1 } else { high = middle }
        }
        return low < spans.count && spans[low].contains(t) ? low : nil
    }

    private static func center(of rect: Rect) -> SIMD2<Double> {
        SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2)
    }
}

extension StagePoints {
    /// Where `global` (a rect in global points, of finite numbers, 0 or more wide and tall) is on the stage at source
    /// instant `host`: cut to the region the screen shown then shows, its corners placed as `stagePoint(global:at:)` places
    /// a point (the far edges of the region included, so a text cursor 0 wide there is still there). `nil` when none of it
    /// is in that region (a rect only touching it is in it), and where `stagePoint(global:at:)` places nothing: no screen
    /// shown, one without a usable frame or a window off screen.
    func stageRect(global: Rect, at host: HostTime) -> Rect? {
        guard let shown = shownPart(global: global, at: host), let region = shown.view.region else { return nil }
        let rect = rects(of: shown.view).screen
        /// As `CursorGeometry.normalized`, then on the screen's rect.
        func placed(_ point: SIMD2<Double>) -> SIMD2<Double> {
            let fraction = (point - SIMD2(region.x, region.y)) / SIMD2(region.width, region.height)
            return SIMD2(rect.x, rect.y) + fraction * SIMD2(rect.width, rect.height)
        }
        let low = placed(SIMD2(shown.rect.x, shown.rect.y))
        let high = placed(SIMD2(shown.rect.x + shown.rect.width, shown.rect.y + shown.rect.height))
        return Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

    /// The part of `global` in the region of the screen shown at `host`, in global points, with that view; `nil` as for
    /// `stageRect(global:at:)`.
    func shownPart(global: Rect, at host: HostTime) -> (rect: Rect, view: ShownScreen)? {
        guard [global.x, global.y, global.width, global.height].allSatisfy(\.isFinite), global.width >= 0, global.height >= 0,
            let view = shownScreen(at: host)?.view, view.onScreen, let region = view.region
        else { return nil }
        let low = SIMD2(max(global.x, region.x), max(global.y, region.y))
        let high = SIMD2(min(global.x + global.width, region.x + region.width), min(global.y + global.height, region.y + region.height))
        guard low.x <= high.x, low.y <= high.y else { return nil }
        return (Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y), view)
    }
}

// MARK: - The planner's part (plan 4a decision 8)

extension Planner {
    /// The changes of the element, as the planner's elements: each zooms as a click with its box.
    func focusElements(_ activity: Activity) -> [Element] {
        activity.focusChanges.map { Element(start: $0.output, end: $0.output, box: $0.box, host: $0.host, isFocus: true) }
    }

    /// The spans of typing with no text cursor in them: those that hold groups (step 2) and make one alone (step 3).
    func typingWithoutCarets(_ activity: Activity) -> [Range<Int64>] {
        let runs = Set(activity.caretRuns.map(\.span))
        return activity.typing.filter { !runs.contains($0) }
    }

    /// The groups of the text cursor: each span with text cursors split into lines. The first cursor is the anchor; the
    /// first one after it whose box leaves the anchor's view (`caretView(around:)`) cuts the line there, and is the anchor
    /// of the next. A line is a group from its start (its anchor) to its cut, or to the span's end, held to there, with
    /// its anchor's box.
    func caretGroups(_ activity: Activity) -> [Group] {
        activity.caretRuns.flatMap { run -> [Group] in
            guard var anchor = run.carets.first else { return [] }
            var view = caretView(around: anchor)
            var groups: [Group] = []
            for caret in run.carets.dropFirst() where !Self.contains(view, caret.box) {
                groups.append(caretGroup(anchor, to: caret.output))
                anchor = caret
                view = caretView(around: caret)
            }
            groups.append(caretGroup(anchor, to: max(anchor.output, run.span.upperBound)))
            return groups
        }
    }

    private func caretGroup(_ anchor: Activity.Caret, to end: Int64) -> Group {
        Group(first: anchor.output, last: end, box: anchor.box, host: anchor.host, held: end, kind: .caret)
    }

    /// What a block on `anchor` shows of the stage: the crop of `min(depth, the depth whose crop fits its box)` placed
    /// over its centre (`StageCrop`, on the screen shown then, the stage itself without one), less 12 % of it
    /// (`AutoZoomPlanner.margin`) on each side. A side where the crop reaches the screen's edge, or goes past it, has no
    /// limit: nothing shown lies beyond it, so a cursor at the start of a line by that edge never leaves the view.
    func caretView(around anchor: Activity.Caret) -> (low: SIMD2<Double>, high: SIMD2<Double>) {
        let size = stage.stageSize
        let depth = min(settings.depth, Self.fittingDepth(anchor.box, stage: size))
        let screen = stage.screenRect(at: anchor.host) ?? Rect(x: 0, y: 0, width: size.x, height: size.y)
        let anchorCenter = SIMD2(anchor.box.x + anchor.box.width / 2, anchor.box.y + anchor.box.height / 2)
        let center = StageCrop.clamp(center: anchorCenter, depth: depth, stage: size, screen: screen)
        let crop = size / max(depth, 1)
        let margin = crop * AutoZoomPlanner.margin
        let low = center - crop / 2, high = center + crop / 2
        let screenLow = SIMD2(screen.x, screen.y), screenHigh = SIMD2(screen.x + screen.width, screen.y + screen.height)
        // Within this of the screen's edge, the crop reaches it.
        let tolerance = 1e-9
        var view = (low: low + margin, high: high - margin)
        for axis in 0..<2 {
            if low[axis] <= screenLow[axis] + tolerance { view.low[axis] = -.infinity }
            if high[axis] >= screenHigh[axis] - tolerance { view.high[axis] = .infinity }
        }
        return view
    }

    /// Whether `box` is all inside `view`.
    private static func contains(_ view: (low: SIMD2<Double>, high: SIMD2<Double>), _ box: Rect) -> Bool {
        box.x >= view.low.x && box.y >= view.low.y && box.x + box.width <= view.high.x && box.y + box.height <= view.high.y
    }
}
