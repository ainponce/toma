// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Render

/// One frame `sensitiveScan-1` looks at: the latest frame of screen track `track` at or before source instant `t`, the
/// frame the output shows then, and of it the screen's content, `crop`.
public struct ScanSample: Equatable, Sendable {
    public var t: HostTime
    public var track: String
    /// The screen's content in the frame, in fractions of the frame (`ShownScreen.crop`): its Area in Area mode, the whole
    /// frame otherwise. What is found is placed in fractions of it, as the privacy blocks are.
    public var crop: Rect

    public init(t: HostTime, track: String, crop: Rect) {
        self.t = t
        self.track = track
        self.crop = crop
    }
}

/// Which frames `sensitiveScan-1` looks at (design §7.2, plan decision 6): 4 per second of source, wherever the output
/// can show a frame of the screen, so nothing it can show goes unlooked at for more than `interval`. Pure.
///
/// - The instants are `interval` apart from the start of the take's editable timeline (`span`, from the first frame of
///   its screen) to its end, pauses included: a document can show a pause as the frozen frame before it (`legacy`, and
///   any clip trimmed over one), and the frame held after the screen's last segment while the audio goes on. The last
///   instant is less than `interval` before the end, and `FindingTracker` stretches what it finds there past it.
/// - At each, the screen the document shows then (`StagePoints.shownScreen(at:)`): a take with several screens is looked
///   at in the one shown, from its first frame on (before that the output shows none of it). Nothing when no screen is
///   shown.
/// - With the spring (`geometryTransition` `.spring`), a change of screen crossfades the content: for
///   `GeometryTransitions.crossfade` of output the screen being left is drawn too, with its frames at the source instants
///   the output shows meanwhile (after a cut, those of the next clip; at 2×, twice as many seconds of source). It is
///   looked at too, at the first of those instants and at each of the take's instants among them, in a sample of its own
///   at the same `t` as the screen shown, which comes first. Blocks hide the same rect of whichever screen is drawn, so
///   what both have is added to the tracker at that one instant.
///
/// In time order. A take of 0 s, or without a screen, has none.
public enum ScanSampling {
    /// 250 ms of source, in nanoseconds.
    public static let interval: UInt64 = 250_000_000

    public static func samples(take: TakeRecord, events: [InputEvent], document: EditDocument) -> [ScanSample] {
        let ordered = events.sortedByTime()
        let stage = StagePoints(take: take, events: ordered, document: document)
        let span = span(take: take, events: ordered)
        // The first frame of each screen the document can show: before it, nothing of that screen is drawn.
        var firstFrame: [String: HostTime] = [:]
        for id in stage.screenTrackIDs {
            if let first = take.track(id)?.segments.map(\.startHostTime).min() { firstFrame[id] = first }
        }
        func hasFrame(_ track: String, at t: HostTime) -> Bool {
            firstFrame[track].map { $0 <= t } ?? false
        }

        var samples: [ScanSample] = []
        var t = span.lowerBound
        while t < span.upperBound {
            if let (track, view) = stage.shownScreen(at: t), hasFrame(track, at: t) {
                samples.append(ScanSample(t: t, track: track, crop: view.crop))
            }
            let (next, overflow) = t.nanoseconds.addingReportingOverflow(interval)
            if overflow { break }
            t = HostTime(nanoseconds: next)
        }

        guard document.style.geometryTransition == .spring else { return samples }
        var leaving: [ScanSample] = []
        var geometries: [String: ScreenGeometry] = [:]
        for (track, instant) in crossfadeInstants(take: take, document: document, stage: stage, span: span)
            where hasFrame(track, at: instant)
        {
            guard let record = take.track(track) else { continue }
            let geometry = geometries[track] ?? ScreenGeometry(track: record, events: ordered)
            geometries[track] = geometry
            guard let view = geometry.shown(at: instant) else { continue }
            leaving.append(ScanSample(t: instant, track: track, crop: view.crop))
        }
        guard !leaving.isEmpty else { return samples }
        // The screen shown first at each instant; one sample of a track at an instant.
        var seen = Set<String>()
        return (samples.map { ($0, 0) } + leaving.map { ($0, 1) })
            .enumerated()
            .sorted { ($0.element.0.t, $0.element.1, $0.offset) < ($1.element.0.t, $1.element.1, $1.offset) }
            .map(\.element.0)
            .filter { seen.insert("\($0.t.nanoseconds) \($0.track)").inserted }
    }

    /// The source times the scan covers: the take's editable timeline (`TakeTimeline.editableBounds`), which every clip of
    /// a document keeps within. What `FindingTracker.findings(within:)` is given for the take.
    public static func span(take: TakeRecord, events: [InputEvent]) -> Range<HostTime> {
        let bounds = TakeTimeline.editableBounds(take: take, events: events)
        return bounds.start..<bounds.end
    }

    /// Where the screen left by each change of screen is drawn while the change crossfades: its track and source instants,
    /// within `span`. A change is a `screens.changes` instant of the take where the screen shown just before it is not the
    /// one shown from it on (both shown), as the render tells them (`ScreenTransitions`); its crossfade starts at
    /// `TimeMap.output(ofChangeAt:take:)` and lasts `GeometryTransitions.crossfade` of output. Of each clip of the take that
    /// shows a part of it: the first source instant it shows then and every instant of the take's grid after it up to the
    /// last one it shows.
    private static func crossfadeInstants(
        take: TakeRecord, document: EditDocument, stage: StagePoints, span: Range<HostTime>
    ) -> [(track: String, t: HostTime)] {
        let timeMap = TimeMap(sequence: document.sequence)
        let changes = Set(document.screens.changes.filter { $0.take == take.id }.map(\.t)).sorted()
        var instants: [(track: String, t: HostTime)] = []
        for x in changes where x.nanoseconds > 0 {
            guard let from = stage.shownScreen(at: HostTime(nanoseconds: x.nanoseconds - 1))?.track,
                  let to = stage.shownScreen(at: x)?.track, from != to,
                  let change = timeMap.output(ofChangeAt: x, take: take.id)
            else { continue }
            let (windowStart, windowEnd) = (max(change, 0), min(change + GeometryTransitions.crossfade, timeMap.duration))
            guard windowStart < windowEnd else { continue }
            for (k, clip) in document.sequence.enumerated() where clip.take == take.id {
                let clipStart = timeMap.clipOutputStarts[k]
                let (lower, upper) = (max(windowStart, clipStart), min(windowEnd, clipStart + TimeMap.outputDuration(of: clip)))
                guard lower < upper, let first = timeMap.source(atOutput: lower), let last = timeMap.source(atOutput: upper - 1),
                      first.clip == k, last.clip == k
                else { continue }
                instants.append((from, first.source))
                // The grid's instants after the first, up to the last.
                let offset = first.source.nanoseconds >= span.lowerBound.nanoseconds
                    ? (first.source.nanoseconds - span.lowerBound.nanoseconds) / interval + 1 : 0
                var t = span.lowerBound.nanoseconds + offset * interval
                while t <= last.source.nanoseconds {
                    instants.append((from, HostTime(nanoseconds: t)))
                    t += interval
                }
            }
        }
        return instants.filter { span.contains($0.t) }
    }
}
