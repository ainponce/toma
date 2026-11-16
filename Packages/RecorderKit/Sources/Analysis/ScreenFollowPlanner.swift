// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat

/// The screen that follows the pointer, `screenFollow-1` (design §8.7): which of a take's recorded screens the output
/// shows over time, as the screen the take starts on and the changes from it. A pure function of the take, its events
/// and which of its segment files are on disk (none is opened).
///
/// It works in an output, so a stay is measured in what the output shows: by default the take's new document's, its
/// recorded spans (`TakeTimeline.recordedSpans`) at 1× with the pauses closed; or a document's, with its cuts, speeds
/// and still pauses (`plan(take:events:package:timeMap:)`), of which only the take's clips count. These are the steps:
/// 1. A screen (a track whose `kind.isScreen`) counts at a source instant only inside one of its segments that is
///    readable (plan decision 23): `SegmentAvailability.classify` finds it `present`, so its `endReason` is neither
///    `empty` nor `unreadable` and its file is there, with bytes; nothing is decoded. A segment counts from its start on
///    to the start of the track's next segment, where the output holds its last frame until then (a pause a document
///    shows as a still, the stream starting again): to its end when it is the last, on while it is open.
/// 2. The pointer at a source instant is where the last pointer event (`cursor`, `mouseDown` or `mouseUp`) at or
///    before it puts it, or the first one, before any. It is on the first screen, in track order, that counts then and
///    whose shown region (`ScreenGeometry`: its `globalFrame` until a geometry event moves it) holds it, or on none.
/// 3. The take starts on the screen the pointer is on at its first instant in the output: among those that count, the
///    one that holds the take's first pointer, as `ScreenChoice` picks it (or the last one before that instant, if the
///    pointer moved before the output starts). With none, at the earliest instant of the output where a screen counts,
///    on the one the pointer is on then or else the first that counts; with none in the whole output, on
///    `ScreenChoice`'s pick, which shows nothing either; `nil` for a take without a screen.
/// 4. A visit is a stretch of the output, as long as it can be, in which the pointer is on one screen; the take's last
///    one ends where its last clip does. A visit of at least `dwell` to a screen other than the one shown switches to it
///    from the visit's start: the instant the pointer entered it, or the one it started to count with the pointer on it.
/// 5. Each change is at the source instant of the visit's start: a kept instant, so a pointer that entered a screen
///    during a pause or a cut switches at the first instant kept after it, the start of the next clip. `origin: .auto`,
///    and the id of plan decision 10 (`changeID`). A change rules at least `dwell` of output before the next, so the
///    changes are in time order, never two at one instant, and each to a screen other than the one before it.
public enum ScreenFollowPlanner {
    public static let id = "screenFollow-1"
    /// How long the pointer stays on a screen before the output switches to it, in nanoseconds of output.
    public static let dwell: Int64 = 800_000_000

    public static func plan(take: TakeRecord, events: [InputEvent], package: ProjectPackage)
        -> (initial: String?, changes: [ScreenChange])
    {
        let spans = TakeTimeline.recordedSpans(take: take, events: events)
        let timeMap = TimeMap(
            sequence: spans.map { Clip(id: "", take: take.id, start: $0.lowerBound, end: $0.upperBound, speed: 1) })
        return plan(take: take, events: events, package: package, timeMap: timeMap)
    }

    /// The same plan measured in the output `timeMap` maps, a document's (its cuts, its speeds and, in a legacy
    /// document, the pauses it shows as a still frame), to make the automatic changes again for an edited document.
    /// Only the clips of `take` count: a stay ends where the take's last clip ends in the output.
    public static func plan(take: TakeRecord, events: [InputEvent], package: ProjectPackage, timeMap: TimeMap)
        -> (initial: String?, changes: [ScreenChange])
    {
        let ordered = events.sortedByTime()
        let screens = take.tracks.filter(\.kind.isScreen).map { Screen(track: $0, events: ordered, package: package) }
        let pointer = ordered.compactMap { event in event.kind.pointerPosition.map { (t: event.t, point: $0) } }
        let starts = clipStarts(in: timeMap)
        let end = timeMap.outputRange(ofSource: HostTime(nanoseconds: 0)..<HostTime.max, take: take.id)?.upperBound ?? 0

        // Steps 2 and 4: where the pointer is from each instant on where that can change, in output order.
        var visits: [Visit] = []
        // Step 3: at the earliest instant of the output where a screen counts, the pointer's, or else the first that does.
        var firstCounting: Int?
        var last = -1
        for instant in breakpoints(screens: screens, pointer: pointer, clipStarts: starts, events: ordered) {
            guard let output = timeMap.output(atSource: instant, take: take.id) else { continue }
            while last + 1 < pointer.count, pointer[last + 1].t <= instant { last += 1 }
            let point = pointer.isEmpty ? nil : pointer[max(last, 0)].point
            let screen = point.flatMap { point in screens.firstIndex { $0.counts(at: instant) && $0.holds(point, at: instant) } }
            if firstCounting == nil { firstCounting = screen ?? screens.firstIndex { $0.counts(at: instant) } }
            // Faster than 1×, two instants can be shown at one output instant: the later one is what is seen from it.
            if visits.last?.output == output { visits.removeLast() }
            if visits.last.map({ $0.screen == screen }) ?? false { continue }
            visits.append(Visit(source: instant, output: output, screen: screen))
        }

        // The first visit is at the take's first instant in the output, the start of its first clip.
        let initial = (visits.first?.screen ?? firstCounting).map { screens[$0].id }
            ?? ScreenChoice.screenTrack(in: take, events: ordered)?.id
        var shown = initial
        var changes: [ScreenChange] = []
        for (k, visit) in visits.enumerated() {
            guard let index = visit.screen, screens[index].id != shown else { continue }
            let visitEnd = k + 1 < visits.count ? visits[k + 1].output : end
            guard visitEnd - visit.output >= dwell else { continue }
            let track = screens[index].id
            changes.append(
                ScreenChange(
                    id: changeID(take: take.id, t: visit.source, track: track), take: take.id, t: visit.source, track: track,
                    origin: .auto))
            shown = track
        }
        return (initial, changes)
    }

    /// The id of an automatic change of `take` to `track` at source instant `t` (plan decision 10): `p-` and the first 4
    /// bytes, in lowercase hex, of SHA-256 of the UTF-8 of `"screenFollow-1|<take>|<t>|<track>"`, `t` in nanoseconds.
    /// Planning again without changes gives the same ids.
    static func changeID(take: String, t: HostTime, track: String) -> String {
        PlannerID.make(prefix: "p-", [id, take, "\(t.nanoseconds)", track])
    }

    /// The source instants where the clips of `timeMap` start in its output, of those that show anything (the clip shown
    /// from an output start on is the one that starts there). Those of the take are its first instant in the output and
    /// the first one kept after each cut or pause between its clips; the others are not kept in the take, so `plan`
    /// passes over them.
    private static func clipStarts(in timeMap: TimeMap) -> [HostTime] {
        timeMap.clipOutputStarts.compactMap { start in start < timeMap.duration ? timeMap.source(atOutput: start)?.source : nil }
    }

    /// The source instants where the screen the pointer is on can change, in time order: each pointer event, each start
    /// and end of a stretch in which a screen counts, each geometry event and each start of a clip (`clipStarts`). Between
    /// two of them the pointer stays where it is and the same screens count where they are.
    private static func breakpoints(
        screens: [Screen], pointer: [(t: HostTime, point: SIMD2<Double>)], clipStarts: [HostTime], events: [InputEvent]
    ) -> [HostTime] {
        var instants = pointer.map(\.t) + clipStarts
        for screen in screens {
            for stretch in screen.readable {
                instants.append(stretch.lowerBound)
                if stretch.upperBound != .max { instants.append(stretch.upperBound) }
            }
        }
        for event in events {
            switch event.kind {
            case .displayGeometry, .windowGeometry: instants.append(event.t)
            default: continue
            }
        }
        // The pointer's instants are in order already, so this mostly merges a few runs.
        instants.sort()
        var unique: [HostTime] = []
        unique.reserveCapacity(instants.count)
        for instant in instants where unique.last != instant { unique.append(instant) }
        return unique
    }
}

/// A stretch of the output from `output` (the source instant `source`) to the next visit's start, or the end, in which
/// the pointer is on `screen` (an index of the take's screens), or on none.
private struct Visit {
    var source: HostTime
    var output: Int64
    var screen: Int?
}

/// A screen track of the take: where it is, and when it can be read.
private struct Screen {
    let id: String
    let geometry: ScreenGeometry
    /// The source stretches in which it counts, in time order, apart from each other: each readable segment, on to the
    /// start of its track's next segment (an open one, to `HostTime.max`).
    let readable: [Range<HostTime>]

    init(track: TrackRecord, events: [InputEvent], package: ProjectPackage) {
        id = track.id
        geometry = ScreenGeometry(track: track, events: events)
        let segments = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        var stretches: [Range<HostTime>] = []
        for (k, segment) in segments.enumerated() where SegmentAvailability.classify(segment, in: package) == .present {
            // Until the next segment starts, the output holds this one's last frame: a pause a document shows as a still,
            // or the stream starting again.
            var end = segment.endHostTime ?? .max
            if k + 1 < segments.count { end = max(end, segments[k + 1].startHostTime) }
            if segment.startHostTime < end { stretches.append(segment.startHostTime..<end) }
        }
        var merged: [Range<HostTime>] = []
        for stretch in stretches {
            if let previous = merged.last, stretch.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, stretch.upperBound)
            } else {
                merged.append(stretch)
            }
        }
        readable = merged
    }

    /// Whether it counts at `instant` (step 1).
    func counts(at instant: HostTime) -> Bool {
        var low = 0, high = readable.count
        while low < high {
            let mid = (low + high) / 2
            if readable[mid].lowerBound <= instant { low = mid + 1 } else { high = mid }
        }
        return low > 0 && instant < readable[low - 1].upperBound
    }

    /// Whether what is shown of it at `instant` holds `point`, in global points (its far edges are out, as for the
    /// drawn cursor).
    func holds(_ point: SIMD2<Double>, at instant: HostTime) -> Bool {
        guard let view = geometry.shown(at: instant), view.onScreen, let region = view.region else { return false }
        return CursorGeometry.contains(CGPoint(x: point.x, y: point.y), region)
    }
}

extension HostTime {
    /// The latest host time there is: the end of a segment still open.
    fileprivate static let max = HostTime(nanoseconds: .max)
}
