// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// How the screen's shape moves on the stage when it changes (design §7.6, plan decision 30), with the document's
/// `geometryTransition` `spring`: its rect goes from the old shape to the new one along `progress` of the time since the
/// change, in output time, and a change of screen crossfades the content over `crossfade`. A change while another moves
/// starts from the rect shown then, as `CameraStyleTimeline` does. With `none`, the rect jumps (phase 0 and 1a).
public enum GeometryTransitions {
    /// The spring of the screen's rect: critically damped, 0.30 s (about 200 ms to 90 %).
    public static let spring = SpringSpec(damping: 1.0, response: 0.30)
    /// How long a change of screen crossfades the content, in output nanoseconds: 0.25 s.
    public static let crossfade: Int64 = 250_000_000
    /// From this long after a change on, it is done: `progress` is 1, and the rect exactly the new one.
    static let settleSeconds = 1.5

    /// How far a change has got `seconds` after it, 0 to 1: the step response of the critically damped `spring`,
    /// `1 − (1 + ωt)e^(−ωt)` with ω = 2π / 0.30 s. 0 up to 0 s (and for NaN), 1 from `settleSeconds` on (where the
    /// formula is within 10⁻¹² of it).
    public static func progress(seconds t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < settleSeconds else { return 1 }
        let omega = 2 * Double.pi / spring.response
        return 1 - (1 + omega * t) * exp(-omega * t)
    }

    /// The rect `progress` of the way from `from` to `to`: each of its values mixed linearly, `from`'s at 0 and `to`'s at
    /// 1 exactly, and one that is the same in both as it is.
    public static func rect(from: Rect, to: Rect, progress p: Double) -> Rect {
        Rect(x: mix(from.x, to.x, p), y: mix(from.y, to.y, p), width: mix(from.width, to.width, p), height: mix(from.height, to.height, p))
    }

    /// `a` at 0, `b` at 1, exactly; `a` when they are equal.
    static func mix(_ a: Double, _ b: Double, _ p: Double) -> Double {
        a == b ? a : a * (1 - p) + b * p
    }

    /// The part of a content of `aspect` (width over height) that fills `rect` without stretching, centred, as fractions
    /// of it (0, 0 its top-left corner, 1, 1 the bottom-right one): all of it along the axis where it is narrower than the
    /// rect, its middle along the other. All of it for an aspect or a rect that is not usable.
    static func aspectFill(aspect: Double, in rect: Rect) -> Rect {
        let whole = Rect(x: 0, y: 0, width: 1, height: 1)
        guard aspect.isFinite, aspect > 0, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            return whole
        }
        let rectAspect = rect.width / rect.height
        if aspect > rectAspect {
            let width = rectAspect / aspect
            return Rect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = aspect / rectAspect
        return Rect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }
}

/// Where the screen goes on a stage of the output's size: its rect and, with a macOS window frame, the window around it
/// and the window's bar (without a frame, the screen's rect and 0).
struct ScreenPlacement: Equatable, Sendable {
    var screen: Rect
    var window: Rect
    var barHeight: Double

    /// `progress` of the way from `from` to `to` (`GeometryTransitions.rect`): the screen still under the bar.
    static func mix(_ from: ScreenPlacement, _ to: ScreenPlacement, _ progress: Double) -> ScreenPlacement {
        ScreenPlacement(
            screen: GeometryTransitions.rect(from: from.screen, to: to.screen, progress: progress),
            window: GeometryTransitions.rect(from: from.window, to: to.window, progress: progress),
            barHeight: GeometryTransitions.mix(from.barHeight, to.barHeight, progress))
    }
}

/// The changes of what a document shows of its screens, in output time, for the frames of one take at one output size:
/// how the screen's rect moves and how a change of screen crossfades (`GeometryTransitions`), and which screen is shown
/// where, the one being left included while it fades.
///
/// A change is a source instant (a `screens.changes` of the take, or a `displayGeometry` or `windowGeometry` event) where
/// the screen shown (`StagePoints.shownScreen(at:)`), or where it goes (its placement, of its region's aspect), is not the
/// same just before it as from it on. It starts at `TimeMap.output(ofChangeAt:take:)`, as the camera's changes: one in a
/// cut from the first instant kept after it, one before the first clip under way at output 0 by its time through that
/// clip's mapping, one after the last clip never. The changes that start at one output instant (all those of a cut) are
/// one, from what was shown before the first to what is shown after the last. With `geometryTransition` `none` there are
/// none: everything jumps.
struct ScreenTransitions: Sendable {
    /// A screen shown, and where it goes.
    private struct Shown: Equatable, Sendable {
        var track: String
        var placement: ScreenPlacement
    }

    /// From output time `output` on, `to` is shown instead of `from` (`nil`: no screen).
    private struct Change: Sendable {
        var output: Int64
        var from: Shown?
        var to: Shown?
    }

    /// What a frame shows of a change under way.
    struct State {
        /// Where the screen is while its rect moves; `nil` when it is not moving (it is where it is shown).
        var placement: ScreenPlacement?
        /// The screen being left while it fades, and the opacity of the one coming over it.
        var previous: (track: String, opacity: Double)?
    }

    /// In output order.
    private let changes: [Change]
    /// Where each of the document's screen tracks is, to show the one being left; only with the spring.
    private let geometries: [String: ScreenGeometry]
    /// The output ranges in which each of the document's screen tracks is shown (`StagePoints.screenTrackIDs`): from the
    /// change of the plan to it to the next change away from it (from 0 for the take's initial screen, to the output's end
    /// for the last), and on through a crossfade away from it; in order, merged where they touch.
    let shownRanges: [String: [Range<Int64>]]

    /// `placement` says where the screen of a view goes, settled, at the output's size.
    init(
        take: TakeRecord, events: [InputEvent], document: EditDocument, timeMap: TimeMap, stage: StagePoints,
        placement: (ShownScreen) -> ScreenPlacement
    ) {
        var changes: [Change] = []
        var geometries: [String: ScreenGeometry] = [:]
        if document.style.geometryTransition == .spring {
            let ordered = events.sortedByTime()
            for id in stage.screenTrackIDs {
                if let track = take.track(id) { geometries[id] = ScreenGeometry(track: track, events: ordered) }
            }
            // Every instant where what is shown can change: the shown screen and its place are the same between two.
            var instants = document.screens.changes.filter { $0.take == take.id }.map(\.t)
            for event in ordered {
                switch event.kind {
                case .displayGeometry, .windowGeometry: instants.append(event.t)
                default: continue
                }
            }
            instants.sort()
            func shown(at t: HostTime) -> Shown? {
                stage.shownScreen(at: t).map { Shown(track: $0.track, placement: placement($0.view)) }
            }
            var last: HostTime?
            for x in instants where x != last {
                last = x
                let before = x.nanoseconds > 0 ? shown(at: HostTime(nanoseconds: x.nanoseconds - 1)) : nil
                let after = shown(at: x)
                guard before != after, let output = timeMap.output(ofChangeAt: x, take: take.id) else { continue }
                if let previous = changes.last, previous.output == output {
                    changes[changes.count - 1].to = after
                    if previous.from == after { changes.removeLast() }
                } else {
                    changes.append(Change(output: output, from: before, to: after))
                }
            }
        }
        self.changes = changes
        self.geometries = geometries
        shownRanges = Self.shownRanges(take: take, document: document, timeMap: timeMap, stage: stage, changes: changes)
    }

    /// What the frame at output time `τ` shows of the changes before it (see the type's notes).
    func state(atOutput τ: Int64) -> State {
        // The changes at or before `τ`.
        var low = 0, high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].output <= τ { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return State() }
        var state = State()
        // The crossfade of the last change of screen, while it lasts.
        for k in stride(from: low - 1, through: 0, by: -1) {
            let since = τ - changes[k].output
            guard since < GeometryTransitions.crossfade else { break }
            if let from = changes[k].from, let to = changes[k].to, from.track != to.track {
                state.previous = (from.track, Double(since) / Double(GeometryTransitions.crossfade))
                break
            }
        }
        // The rect: a change made once the one before it had settled starts from what it changed exactly, so go back to
        // the first change of the burst that ends at `τ`, and play the burst forward from there.
        let last = low - 1
        guard Self.seconds(τ, since: changes[last].output) < GeometryTransitions.settleSeconds else { return state }
        var first = last
        while first > 0, Self.seconds(changes[first].output, since: changes[first - 1].output) < GeometryTransitions.settleSeconds {
            first -= 1
        }
        var shown = changes[first].from?.placement
        for k in first...last {
            let until = k < last ? changes[k + 1].output : τ
            // To no screen, or from none: it jumps.
            guard let target = changes[k].to?.placement else {
                shown = nil
                continue
            }
            let progress = GeometryTransitions.progress(seconds: Self.seconds(until, since: changes[k].output))
            shown = shown.map { ScreenPlacement.mix($0, target, progress) } ?? target
        }
        state.placement = shown
        return state
    }

    /// What is shown of screen track `track` at source instant `host` (`ScreenGeometry`), for the screen being left;
    /// `nil` for a track the document does not show, without the spring, and when nothing of it is shown.
    func view(of track: String, at host: HostTime) -> ShownScreen? {
        geometries[track]?.shown(at: host)
    }

    /// Seconds from output time `b` to `a`.
    private static func seconds(_ a: Int64, since b: Int64) -> Double {
        (Double(a) - Double(b)) / 1_000_000_000
    }

    /// `shownRanges` (see there): the plan's screen at each output instant, as `StagePoints.shownScreen(at:)` picks it at
    /// the instant it shows, and the crossfades of `changes`.
    private static func shownRanges(
        take: TakeRecord, document: EditDocument, timeMap: TimeMap, stage: StagePoints, changes: [Change]
    ) -> [String: [Range<Int64>]] {
        let screens = Set(stage.screenTrackIDs), end = timeMap.duration
        var ranges: [String: [Range<Int64>]] = [:]
        func add(_ track: String?, _ from: Int64, _ to: Int64) {
            let range = max(from, 0)..<min(max(to, from, 0), end)
            guard let track, screens.contains(track), !range.isEmpty else { return }
            ranges[track, default: []].append(range)
        }
        // A change rules from the first instant kept at or after it: monotonic, as the clips of a take are in source order.
        let planned = document.screens.changes.enumerated().filter { $0.element.take == take.id }
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var current = document.screens.initial[take.id], from: Int64 = 0
        for change in planned {
            guard let output = timeMap.firstKeptOutput(atOrAfter: change.t, take: take.id) else { break }
            guard change.track != current else { continue }
            add(current, from, output)
            (current, from) = (change.track, max(output, from))
        }
        add(current, from, end)
        for change in changes {
            guard let left = change.from, let to = change.to, left.track != to.track else { continue }
            add(left.track, change.output, change.output + GeometryTransitions.crossfade)
        }
        return ranges.mapValues { spans in
            spans.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, span in
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
        }
    }
}
