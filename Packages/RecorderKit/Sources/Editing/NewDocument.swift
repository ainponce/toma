// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The document a version 3 project starts with, the "New" column of design §6.7: written the first time a freshly
/// recorded project opens, with the default style of that moment.
public enum NewDocument {
    /// One clip at 1× for each span the take recorded between a `paused` and the next `resumed`
    /// (`TakeTimeline.recordedSpans`: the pauses are closed), each with an id of `makeID("c-")`; a take with no span
    /// (0 s) keeps the legacy document's single clip, so there is always one. The screen the take starts on and the
    /// changes of `screenFollow-1`, named as their planner only with two or more screens (with one there are none). The
    /// default style's stage, with mipmapped sampling and the spring between shapes; its cursor, drawn from the recorded
    /// images if the take has any `cursorImage` event and as Toma's arrow if not; its zoom settings, with the blocks
    /// `autoZoom-1` plans for the document so built. The camera as the take recorded it and every audio track at gain
    /// 1, as in the legacy document, but through the limiter. 16:9 at 60 frames per second; `logSequence` 0.
    public static func make(project: LoadedProject, defaultStyle: DefaultStyle, makeID: (String) -> String) -> EditDocument {
        let take = project.take
        let events = project.events
        let legacy = EditDocument.legacy(for: project)
        let spans = TakeTimeline.recordedSpans(take: take, events: events)
        let sequence = spans.isEmpty
            ? legacy.sequence.map { clip in
                var clip = clip
                clip.id = makeID("c-")
                return clip
            }
            : spans.map { Clip(id: makeID("c-"), take: take.id, start: $0.lowerBound, end: $0.upperBound, speed: 1) }

        let followsScreens = take.tracks.filter(\.kind.isScreen).count >= 2
        let screens = ScreenFollowPlanner.plan(take: take, events: events, package: project.package)
        var style = defaultStyle.style
        style.screenSampling = .mipmapped
        style.geometryTransition = .spring
        var cursor = defaultStyle.cursor
        let recordedImages = events.contains { if case .cursorImage = $0.kind { true } else { false } }
        cursor.style = recordedImages ? .system : .toma

        var document = EditDocument(
            documentVersion: EditDocument.currentVersion,
            logSequence: 0,
            aspect: .landscape,
            frameRate: 60,
            sequence: sequence,
            screens: ScreenPlan(
                initial: screens.initial.map { [take.id: $0] } ?? [:], changes: followsScreens ? screens.changes : [],
                planner: followsScreens ? ScreenFollowPlanner.id : nil),
            style: style,
            cursor: cursor,
            zoom: ZoomPlan(
                show: defaultStyle.zoomShow, auto: defaultStyle.zoomAuto, spring: defaultStyle.zoomSpring,
                motionBlur: defaultStyle.zoomMotionBlur, regions: [], suppressed: []),
            camera: legacy.camera,
            audio: AudioPlan(limiter: true, tracks: legacy.audio.tracks))
        document.zoom.regions = AutoZoomPlanner.plan(take: take, events: events, document: document)
        return document
    }
}
