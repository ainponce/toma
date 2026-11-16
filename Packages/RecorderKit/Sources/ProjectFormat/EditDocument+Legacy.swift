// SPDX-License-Identifier: GPL-3.0-or-later

extension EditDocument {
    /// The document of a project of version 1 or 2 without edits (or of version 3 with `upgradedFrom` and no edit log),
    /// the "Legacy" column of design §6.7: what phase 0 and 1a draw and play, so it renders the same bytes as they do.
    ///
    /// One clip at 1× over `TakeTimeline.bounds`, pauses included (shown as the frozen frame), with the ID
    /// `c-00000001`; the screen `ScreenChoice` picks, without changes; the classic gradient with phase 0's padding
    /// and corners and nothing else on the stage; Toma's 24 pt arrow, interpolated as recorded; the zoom on but with
    /// no blocks and the automatic one off; the camera as the take recorded it, each `cameraStyle` event a change in
    /// time order with the ID `k-` and its number from 1 in 8 hex (plan decision 17); every audio track at gain 1,
    /// without the limiter. It is never written until the first edit, so its IDs are fixed, not random.
    public static func legacy(take: TakeRecord, events: [InputEvent]) -> EditDocument {
        let bounds = TakeTimeline.bounds(take: take, events: events)
        var zoomAuto = DefaultStyle.toma.zoomAuto
        zoomAuto.enabled = false
        let cameraStyles = events.sortedByTime().compactMap { event -> (t: HostTime, style: CameraStyle)? in
            guard case let .cameraStyle(style) = event.kind else { return nil }
            return (event.t, style)
        }
        let audioTracks = take.tracks.filter { !$0.kind.isVideo }.map { track in
            (AudioPlan.key(take: take.id, track: track.id), TrackGain(gain: 1, muted: false))
        }
        return EditDocument(
            documentVersion: currentVersion,
            logSequence: 0,
            aspect: .landscape,
            frameRate: 60,
            sequence: [Clip(id: "c-00000001", take: take.id, start: bounds.start, end: bounds.end, speed: 1)],
            screens: ScreenPlan(initial: bounds.screen.map { [take.id: $0.id] } ?? [:], changes: []),
            style: StageStyle(
                background: .tomaClassic, backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0, frame: .none,
                screenSampling: .bilinear, geometryTransition: .none),
            cursor: CursorStyle(
                show: true, style: .toma, scale: 1, smoothing: .off, hideWhenIdle: false, idleDelay: 2, clickEffect: "none",
                clickSound: "none", clickSoundGain: 0.5, motionBlur: 0),
            zoom: ZoomPlan(
                show: true, auto: zoomAuto, spring: SpringSpec(damping: 1.0, response: 0.70), motionBlur: 0, regions: [], suppressed: []),
            camera: CameraPlan(
                show: true,
                initial: [take.id: take.cameraStyle ?? .default],
                changes: cameraStyles.enumerated().map { index, change in
                    CameraChange(id: legacyID("k-", index + 1), take: take.id, t: change.t, style: change.style, origin: .recorded)
                }),
            audio: AudioPlan(limiter: false, tracks: Dictionary(audioTracks) { first, _ in first }))
    }

    /// `legacy(take:events:)` of the project's take and events.
    public static func legacy(for project: LoadedProject) -> EditDocument {
        legacy(take: project.take, events: project.events)
    }

    /// `prefix` and `number` in 8 lowercase hex digits.
    private static func legacyID(_ prefix: String, _ number: Int) -> String {
        let hex = String(number, radix: 16)
        return prefix + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}
