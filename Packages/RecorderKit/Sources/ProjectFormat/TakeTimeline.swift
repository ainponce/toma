// SPDX-License-Identifier: GPL-3.0-or-later

/// The source times of a take that its output can show.
public enum TakeTimeline {
    /// The take's timeline as phase 0 and 1a play it: the screen is the track `ScreenChoice` picks, and the timeline
    /// goes from the start of that track's first segment to the latest segment end (the start, for a segment still
    /// open) of the screen and of every audio track, so audio recorded after the screen's last segment is in it. A
    /// take whose screen has no segment has a timeline of 0 s at host time 0. `end` is never before `start`.
    public static func bounds(take: TakeRecord, events: [InputEvent]) -> (screen: TrackRecord?, start: HostTime, end: HostTime) {
        let screen = ScreenChoice.screenTrack(in: take, events: events)
        let segments = screen?.segments ?? []
        let start = segments.map(\.startHostTime).min() ?? HostTime(nanoseconds: 0)
        // Without a screen segment there is nothing to show, and no start to measure the audio from.
        let audio = segments.isEmpty ? [] : take.tracks.filter { !$0.kind.isVideo }.flatMap(\.segments)
        // An open segment (no end yet) counts up to its start.
        let end = (segments + audio).map { $0.endHostTime ?? $0.startHostTime }.max() ?? start
        return (screen, start, max(end, start))
    }

    /// The source times a document can show of the take (design §7.6, plan decisions 6 and 18): `bounds` when its
    /// screen has segments; without them, where `bounds` has 0 s at host time 0, the media it recorded: from the earliest
    /// start to the latest end (the start, for a segment still open) of its audio and camera tracks, so a take without a
    /// screen is edited and exported over the background, never from host time 0. With no media either, `bounds`.
    /// `screen` is `bounds`' in every case; `end` is never before `start`.
    public static func editableBounds(take: TakeRecord, events: [InputEvent]) -> (screen: TrackRecord?, start: HostTime, end: HostTime) {
        let bounds = bounds(take: take, events: events)
        guard bounds.screen?.segments.isEmpty ?? true else { return bounds }
        let media = take.tracks.filter { !$0.kind.isScreen }.flatMap(\.segments)
        guard let start = media.map(\.startHostTime).min() else { return bounds }
        let end = media.map { $0.endHostTime ?? $0.startHostTime }.max() ?? start
        return (bounds.screen, start, max(end, start))
    }

    /// `[start, end)` of `editableBounds` (with a screen, `bounds`) cut at each pause: from a `paused` event to the next
    /// `resumed`, in time order, is left out. A `resumed` without a pause before it, and a `paused` while paused, change
    /// nothing; a pause never resumed ends the last span. Empty spans are left out, so a take of 0 s has none.
    public static func recordedSpans(take: TakeRecord, events: [InputEvent]) -> [Range<HostTime>] {
        let (_, start, end) = editableBounds(take: take, events: events)
        func clamped(_ t: HostTime) -> HostTime { min(max(t, start), end) }
        var spans: [Range<HostTime>] = []
        // The start of the span being recorded; `nil` while paused.
        var spanStart: HostTime? = start
        for event in events.sortedByTime() {
            switch event.kind {
            case .paused:
                guard let from = spanStart else { continue }
                let to = clamped(event.t)
                if from < to { spans.append(from..<to) }
                spanStart = nil
            case .resumed:
                if spanStart == nil { spanStart = clamped(event.t) }
            default:
                continue
            }
        }
        if let from = spanStart, from < end { spans.append(from..<end) }
        return spans
    }
}
