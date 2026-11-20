// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat

/// What the panel does to the document (design §5.4): each control is one of `StyleCommands`' steps. A drag of a bar is
/// a gesture (Task 36): the preview follows it, and its end is one edit; the arrow keys and a click are steps of their own,
/// which the session's rule for bursts joins into one undo.
extension EditorModel {
    /// Sets the style value at `pointer` (`/style/padding`…): inside a gesture it is the gesture's step, otherwise an edit.
    func setStyle(_ pointer: String, _ value: some Encodable, label: EditLabel) {
        guard let document, let step = StyleCommands.set(document, pointer, value, label: label) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// The background, and with it the blur when the new one needs another (the Desktop starts at 50): one edit.
    func setBackground(_ background: Background, blur: Double? = nil) {
        guard let document else { return }
        var changes: [EditChange] = []
        var target = "/style/background"
        if let step = StyleCommands.set(document, "/style/background", background, label: .background) {
            changes += step.changes
            target = step.target
        }
        if let blur, let step = StyleCommands.set(document, "/style/backgroundBlur", blur, label: .background) { changes += step.changes }
        guard !changes.isEmpty else { return }
        let step = EditStep(label: .background, target: target, changes: changes)
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    // MARK: - Camera

    /// The document's time map, for what the panel places at the playhead.
    var panelTimeMap: TimeMap? { document.map { TimeMap(sequence: $0.sequence) } }

    /// "Show Camera".
    func setCameraShow(_ show: Bool) {
        guard let document, let step = TrackCommands.setCameraShow(document, show) else { return }
        perform(step)
    }

    /// Edits the camera style that rules at the playhead (`TrackCommands.setCameraStyle`): the take's initial one, or the
    /// change there, which is the user's then. A drag of the size bar is a gesture.
    func setCameraStyle(_ style: CameraStyle) {
        guard let document, let map = panelTimeMap,
            let step = TrackCommands.setCameraStyle(document, atOutput: playheadNanoseconds, timeMap: map, style)
        else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// "Add Change at Playhead": a change of the user's with the style that rules there, which is then selected.
    func addCameraChange() {
        guard let document, let map = panelTimeMap else { return }
        var made: String?
        let step = TrackCommands.addCameraChange(document, atOutput: playheadNanoseconds, timeMap: map) { prefix in
            let id = Self.newID(prefix)
            made = id
            return id
        }
        guard let step, perform(step) != .refused, let made else { return }
        selection = .cameraChange(made)
    }

    /// "Delete Change": the one before it, or the initial style, rules from then on.
    func deleteCameraChange(_ id: String) {
        guard let document, let step = TrackCommands.deleteCameraChange(document, id: id) else { return }
        perform(step)
    }

    /// Selects change `id` of the list and puts the playhead on it, so what the panel edits is that change.
    func selectCameraChange(_ id: String, output: Int64) {
        selection = .cameraChange(id)
        guard let rate = document?.frameRate else { return }
        // The first frame of the grid at or after the change: the frame before it would show the style before.
        var frame = Int((Double(output) * Double(rate) / 1e9).rounded(.up))
        while Int64(TimeMap.frameTime(frame, frameRate: rate)) < output { frame += 1 }
        seek(frame: frame)
    }

    static func newID(_ prefix: String) -> String {
        prefix + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    // MARK: - Zoom

    /// "Show Zooms".
    func setZoomShow(_ show: Bool) {
        guard let document, let step = ZoomCommands.setShow(document, show) else { return }
        perform(step)
    }

    /// The zoom's motion blur, from the bar's integer: a drag is a gesture.
    func setZoomMotionBlur(slider: Int) {
        guard let document, let step = ZoomCommands.setMotionBlur(document, PanelValues.motionBlur(slider: slider)) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// The zoom camera's speed.
    func setZoomSpeed(_ speed: ZoomSpeed) {
        setStyle("/zoom/spring", speed.spring, label: .zoomChange)
    }

    /// The automatic zoom's settings as the panel shows them: those being planned, else the document's.
    var autoZoomSettings: AutoZoomSettings? { autoZoomPending ?? document?.zoom.auto }

    /// Changes a setting of the automatic zoom: the planner runs again, off the main thread, and the automatic zooms that
    /// were not touched are replaced, with the setting, in one step (`ZoomCommands.regenerate`). Changes that come while it
    /// plans are joined: only the last is planned next.
    func changeAutoZoom(_ edit: (inout AutoZoomSettings) -> Void) {
        guard canEdit, var settings = autoZoomSettings else { return }
        edit(&settings)
        guard settings != autoZoomSettings else { return }
        planAutoZoom(settings)
    }

    /// "Regenerate Automatic Zooms": plans again with the settings as they are.
    func regenerateAutoZoom() {
        guard canEdit, let settings = autoZoomSettings else { return }
        planAutoZoom(settings)
    }

    private func planAutoZoom(_ settings: AutoZoomSettings) {
        autoZoomPending = settings
        guard autoZoomTask == nil else { return }
        autoZoomTask = Task {
            defer { autoZoomTask = nil }
            while let wanted = autoZoomPending, let document, let project = overlayProject {
                let take = project.take, events = project.events
                let step = await Task.detached { ZoomCommands.regenerate(document, take: take, events: events, settings: wanted) }.value
                // Asked again, or the document changed, while it planned: plan again from what is there now.
                guard autoZoomPending == wanted, self.document == document else { continue }
                perform(step)
                break
            }
            autoZoomPending = nil
        }
    }

    /// What the card of the selected zoom changes (`ZoomCommands.change`): `nil` leaves a field alone.
    func changeZoom(_ id: String, depth: Double?? = nil, focus: ZoomFocus? = nil, instant: Bool? = nil) {
        guard let document, let step = ZoomCommands.change(document, id: id, depth: depth, focus: focus, instant: instant) else { return }
        perform(step)
    }

    /// "Delete Zoom".
    func deleteZoom(_ id: String) {
        guard let document, let step = ZoomCommands.delete(document, ids: [id]) else { return }
        perform(step)
    }

    // MARK: - Audio

    /// A track's volume (0 to 200 %): a drag is a gesture. A track the document has no entry for yet gets one with its
    /// parent's `set` (a `set` cannot add a key).
    func setTrackVolume(_ track: AudioTrackRow, percent: Int) {
        setTrackGain(track) { $0.gain = PanelValues.trackGain(percent: percent) }
    }

    /// "Mute".
    func setTrackMuted(_ track: AudioTrackRow, _ muted: Bool) {
        setTrackGain(track) { $0.muted = muted }
    }

    private func setTrackGain(_ track: AudioTrackRow, _ edit: (inout TrackGain) -> Void) {
        guard let document else { return }
        var gain = document.audio.tracks[track.id] ?? TrackGain(gain: 1, muted: false)
        edit(&gain)
        if document.audio.tracks[track.id] != nil {
            setStyle(JSONPointer(components: ["audio", "tracks", track.id]).string, gain, label: .volume)
        } else {
            var tracks = document.audio.tracks
            tracks[track.id] = gain
            setStyle("/audio/tracks", tracks, label: .volume)
        }
    }

    /// "Avoid Clipping".
    func setLimiter(_ on: Bool) {
        setStyle("/audio/limiter", on, label: .volume)
    }

    // MARK: - Image

    /// "Choose Image…": the file is copied into the project (`importAsset`), then it is the background.
    func chooseImage(_ url: URL) {
        guard canEdit, importTask == nil, let session = panelSession else { return }
        imageImport = .importing
        importTask = Task {
            let outcome = await session.importAsset(url)
            let cancelled = Task.isCancelled
            importTask = nil
            switch outcome {
            case let .imported(path):
                imageImport = .idle
                setBackground(.image(file: path))
            case .notAnImage, .notALUT, .notPlayable:
                // `.notALUT` is only a `.cube`'s and `.notPlayable` a clip's or a sound's, never an image's.
                imageImport = .notAnImage
            case .saveFailed:
                // Cancelled by the user while it waited for room on a full disk: nothing to say.
                imageImport = cancelled ? .idle : .saveFailed
            case .notEditable:
                imageImport = .idle
            }
        }
    }

    /// Stops an import that waits for room on a full disk.
    func cancelImageImport() {
        importTask?.cancel()
    }

    /// "Remove Image": the background goes back to Toma's wallpaper.
    func removeImage() {
        setBackground(DefaultStyle.toma.style.background)
    }
}
