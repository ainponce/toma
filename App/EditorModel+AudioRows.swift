// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat

/// The audio rows of the timeline (phase 3 design §7.2 and §7.3): Solo, the stretches at another volume and the cut of
/// the sound J or L, each one step of `AudioRangeCommands` (the timeline's drags make theirs from the document the drag
/// started from, `TimelineAudioDrags`). Solo is the preview's alone: the mix it hears is `soloDocument(of:)`, never the
/// document, the export nor the ducking's voice (plan decision 11).
extension EditorModel {
    // MARK: - Solo

    /// Solo of `row` on or off; the preview's mix is made again with it (what is shown does not change).
    func toggleSolo(_ row: AudioRowID) {
        var solo = audioSolo
        if solo.rows.contains(row) { solo.rows.remove(row) } else { solo.rows.insert(row) }
        audioSolo = solo
        showCurrentDocument()
    }

    /// What the preview's mix hears of `document`: `nil` (the document itself) without a solo, or when no row soloed is
    /// shown any more (a take left the sequence, the music was deleted); otherwise `AudioSolo.applied(to:takes:)` with the
    /// rows soloed that `document` shows.
    func soloDocument(of document: EditDocument) -> EditDocument? {
        guard !audioSolo.isEmpty, let project = overlayProject else { return nil }
        let takes = project.takeRecords(shownBy: document)
        let shown = Set(TimelineLayout(takes: takes, document: document).tracks.compactMap { row -> AudioRowID? in
            switch row.track {
            case let .audio(id): .track(id)
            case .importedAudio: .importedClips
            case .music: .music
            default: nil
            }
        })
        let solo = AudioSolo(rows: audioSolo.rows.intersection(shown))
        return solo.isEmpty ? nil : solo.applied(to: document, takes: takes)
    }

    // MARK: - The stretches

    /// The takes the sequence shows that recorded audio track `track`, in its order.
    private func takes(ofTrack track: String) -> [String] {
        audioTracks.first { $0.track == track }?.takes ?? []
    }

    /// A stretch of `gain` dB over output range `forOutput` of audio track `track` (the capsule's number typed over a
    /// marked stretch): the one selected afterwards.
    func addGainRange(track: String, forOutput: Range<Int64>, gain: Double) {
        guard canEdit, let document else { return }
        let step = AudioRangeCommands.addRange(
            document, track: track, takes: takes(ofTrack: track), forOutput: forOutput, gain: gain,
            timeMap: TimeMap(sequence: document.sequence), makeID: Self.newID)
        guard let step, perform(step) != .refused else { return }
        selection = .gainRange(step.target)
    }

    /// Stretch `id` of `track` at `gain` dB.
    func setGainRange(track: String, id: String, gain: Double) {
        guard canEdit, let document, let step = AudioRangeCommands.setGain(document, track: track, id: id, gain: gain) else { return }
        perform(step)
    }

    /// Edge `edge` of stretch `id` of `track` to output instant `toOutput`.
    func trimGainRange(track: String, id: String, edge: ClipEdge, toOutput: Int64) {
        guard canEdit, let document,
            let step = AudioRangeCommands.trim(
                document, track: track, id: id, edge: edge, toOutput: toOutput, timeMap: TimeMap(sequence: document.sequence))
        else { return }
        perform(step)
    }

    /// Takes stretch `id` of `track` out.
    func deleteGainRange(track: String, id: String) {
        guard canEdit, let document, let step = AudioRangeCommands.delete(document, track: track, id: id) else { return }
        perform(step)
    }

    /// The audio track stretch `id` is of, from its key (`<take>/<track>`): ids are unique in the document.
    func gainRangeTrack(_ id: String) -> String? {
        guard let document else { return nil }
        let key = document.audio.tracks.keys.sorted().first { document.audio.tracks[$0]?.ranges.contains { $0.id == id } == true }
        guard let key, let slash = key.firstIndex(of: "/") else { return nil }
        return String(key[key.index(after: slash)...])
    }

    /// The step that deletes the selected stretch `id` (⌫, "Delete Range" of the selection); `nil` without it.
    func gainRangeDeletion(_ id: String) -> EditStep? {
        guard let document, let track = gainRangeTrack(id) else { return nil }
        return AudioRangeCommands.delete(document, track: track, id: id)
    }

    // MARK: - The cut of the sound

    /// The cut of the sound at the start of clip `clip` to `shift` ns of output (negative a J cut, positive an L cut),
    /// held to what there is of each take ("Reset Audio Cut" and a double click on its notch: 0).
    func setAudioShift(clip: Int, to shift: Int64) {
        guard canEdit, let document,
            let step = AudioRangeCommands.setAudioShift(document, clip: clip, to: shift, takeBounds: audioTakeBounds)
        else { return }
        perform(step)
    }

    /// Each take's source the sound can be read in (`TakeTimeline.editableBounds`), by take id, which the cut of the
    /// sound is held to (`AudioRangeCommands.shiftLimits`, plan decision 10, as the mix holds it): this project's take
    /// from its events in memory, the others as `warmAudioTakeBounds()` read them off the main thread (a take not read
    /// yet is held only to its neighbours).
    var audioTakeBounds: [String: ClosedRange<HostTime>] {
        guard let project = overlayProject else { return audioBoundsCache }
        var bounds = audioBoundsCache
        if bounds[project.take.id] == nil {
            let own = TakeTimeline.editableBounds(take: project.take, events: project.events)
            bounds[project.take.id] = own.start...own.end
            audioBoundsCache[project.take.id] = own.start...own.end
        }
        return bounds
    }

    /// Reads the bounds of the takes the sequence shows that `audioTakeBounds` has not got yet, off the main thread: their
    /// events are read from the package the first time.
    func warmAudioTakeBounds() {
        guard audioBoundsTask == nil, let project = overlayProject, let document else { return }
        let missing = project.takeRecords(shownBy: document).filter { audioBoundsCache[$0.id] == nil && $0.id != project.take.id }
        guard !missing.isEmpty else { return }
        audioBoundsTask = Task {
            let found = await Task.detached(priority: .utility) {
                var found: [String: ClosedRange<HostTime>] = [:]
                for take in missing {
                    let bounds = TakeTimeline.editableBounds(take: take, events: project.events(ofTake: take.id))
                    found[take.id] = bounds.start...bounds.end
                }
                return found
            }.value
            audioBoundsCache.merge(found) { _, new in new }
            audioBoundsTask = nil
        }
    }
}
