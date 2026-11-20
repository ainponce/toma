// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat

/// Which take each feature of phases 1 and 2 reads with more than one in the sequence (phase 3 design §8.1, 3d plan
/// decision 17): the take of the clip it works on (a trim of its edges), the take of the clip at the playhead (trimming
/// up to it, the bubble and the stage's points of the preview, the camera's picture, the panel's line of layouts), or
/// every take the sequence shows (the automatic zoom, Follow the Cursor, the panel's flags, the export's recorded size,
/// the timeline's thumbnails and waveforms). With one take, each is that take: what phase 2 read.
///
/// The events of every take of the package are read once, off the main thread, when the project opens (`adopt`, for
/// `screensByTake`), and shared by every value focused from the session's project: reading them here afterwards is a
/// look at memory, never the disk.
extension EditorModel {
    /// What the panel offers by what the takes recorded (`takeFlags(of:)`): each is the session's own take's with one.
    struct TakeFlags: Equatable {
        /// Some take has a camera with something recorded: the panel's Camera tab exists.
        var hasCamera = false
        /// Some take saved the shapes of the cursor (`cursorImage` events): macOS's cursor can be drawn.
        var hasCursorImages = false
        /// Some take recorded key presses: the keys on screen have something to show.
        var hasKeyPresses = false
        /// Every take's screen is an iPhone or an iPad (a `device` track): there is no cursor anywhere.
        var screenIsDevice = false
        /// Some take has clicks to make zooms from.
        var hasClicks = false
        /// Some take noted when keys were typed: "Hold While Typing" has something to hold.
        var canHoldWhileTyping = false
        /// Every take recorded an iPhone or iPad: no cursor, clicks or keys in any of them.
        var isDeviceTake = false
        /// Some take recorded the keyboard focus (`focus` events): "Follow the Focus" has something to follow.
        var hasFocusEvents = false
    }

    /// The flags of `projects`, the takes the sequence shows (`LoadedProject.takesShown(by:)`) with their events: what
    /// any of them has, and a device only when all of them are one. With one take, that take's. Goes over every event
    /// of each (and reads it from the disk the first time): never on the main thread.
    nonisolated static func takeFlags(of projects: [LoadedProject]) -> TakeFlags {
        var flags = TakeFlags()
        var devices = 0
        for project in projects {
            let tracks = project.take.tracks, events = project.events
            if tracks.contains(where: { $0.kind == .camera && !$0.segments.isEmpty }) { flags.hasCamera = true }
            if !flags.hasCursorImages, events.contains(where: { if case .cursorImage = $0.kind { true } else { false } }) {
                flags.hasCursorImages = true
            }
            if !flags.hasKeyPresses, events.contains(where: { if case .keyPress = $0.kind { true } else { false } }) {
                flags.hasKeyPresses = true
            }
            if tracks.contains(where: { $0.kind == .device }) { devices += 1 }
            if !flags.hasClicks, ZoomPanelRules.hasClicks(events: events) { flags.hasClicks = true }
            if !flags.canHoldWhileTyping, ZoomPanelRules.canHoldWhileTyping(events: events) { flags.canHoldWhileTyping = true }
            if !flags.hasFocusEvents, ZoomPanelRules.hasFocus(events: events) { flags.hasFocusEvents = true }
        }
        flags.screenIsDevice = !projects.isEmpty && devices == projects.count
        flags.isDeviceTake = flags.screenIsDevice
        return flags
    }

    /// The session's project focused on take `id` (`LoadedProject.focused(on:)`), from where the package is now; `nil`
    /// without a session or for a take the package does not have.
    func project(ofTake id: String) -> LoadedProject? {
        overlayProject?.focused(on: id)
    }

    /// The project focused on the take of the clip at the playhead (`TimeMap.source(atOutput:)`, a clip with content's
    /// own take); the session's own take without a document or a clip.
    var playheadProject: LoadedProject? {
        guard let project = overlayProject, let document,
            let shown = TimeMap(sequence: document.sequence).source(atOutput: playheadNanoseconds),
            document.sequence.indices.contains(shown.clip)
        else { return overlayProject }
        return project.focused(on: document.sequence[shown.clip].take) ?? project
    }

    /// The project focused on each take the sequence shows, in the order it first shows it (`takesShown(by:)`); the
    /// session's own take alone for an empty sequence, none without a session.
    var sequenceProjects: [LoadedProject] {
        guard let project = overlayProject else { return [] }
        guard let document else { return [project] }
        return project.takesShown(by: document)
    }

    /// The ids of the takes `document`'s sequence shows, each once, in the order it first shows them: what changes
    /// the panel's flags and the mix's sources when it changes.
    nonisolated static func takeIDs(shownBy document: EditDocument) -> [String] {
        var seen: Set<String> = []
        return document.sequence.compactMap { seen.insert($0.take).inserted ? $0.take : nil }
    }

    /// Whether `document` shows a take of `project` that a mix with sources for `mixed` (`EditedMix.takeIDs`) has none
    /// for: such a clip is silent in it, so the mix is made again. A take the package does not have never counts.
    nonisolated static func mixLacksATake(_ mixed: [String], project: LoadedProject, document: EditDocument) -> Bool {
        let has = Set(mixed)
        return project.takesShown(by: document).contains { !has.contains($0.take.id) }
    }

    /// The flags of the takes `document` shows, worked out off the main thread, then shown if the editor's document
    /// still shows those takes; one that came to show others asks again for its own.
    func refreshTakeFlags(of document: EditDocument) {
        guard let project = overlayProject else { return }
        let shown = project.takesShown(by: document), ids = Self.takeIDs(shownBy: document)
        Task {
            let flags = await Task.detached(priority: .userInitiated) { Self.takeFlags(of: shown) }.value
            guard let now = self.document, Self.takeIDs(shownBy: now) == ids else { return }
            show(flags)
        }
    }
}
