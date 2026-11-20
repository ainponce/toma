// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The editor's window: each key goes to `EditorKeyboard` before anything else of the window sees it, and on as usual if
/// it does nothing with it.
final class EditorKeyWindow: NSWindow {
    var keyboard: EditorKeyboard?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyboard?.handle(event, in: self) == true { return }
        super.sendEvent(event)
    }
}

/// The editor's keys (design §5.7): which command a key is comes from `KeyboardCommands` (AppSupport), given what has the
/// focus; this class reads the event and the focus, and does the command with the model, the timeline and the window. A
/// key whose command cannot be done now (nothing to split, no selection) goes on as if it had none, and the system beeps.
/// Held down, only the commands that step (`EditorCommand.repeats`) repeat.
@MainActor
final class EditorKeyboard {
    private var commands = KeyboardCommands()
    private weak var model: EditorModel?
    private weak var timeline: EditorTimelineView?
    /// ⌥⌘I: the window's.
    var togglePanel: () -> Void = {}
    /// ⌘O: the app's File ▸ Open….
    var open: () -> Void = {}

    init(model: EditorModel, timeline: EditorTimelineView) {
        self.model = model
        self.timeline = timeline
    }

    /// Does the command of `event`, a key pressed in `window`; whether it did (the event then goes no further). ⌫ and ⌦
    /// delete the marked range, or else what is selected; the last clip is never deleted, and the timeline says so.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let model, let timeline else { return false }
        let modifiers = Self.modifiers(event.modifierFlags)
        guard let characters = event.charactersIgnoringModifiers,
            let key = EditorKey(
                characters: characters, unmodified: event.characters(byApplyingModifiers: []), modifiers: modifiers,
                keyCode: event.keyCode)
        else { return false }
        commands.shuttle = model.playbackSpeed
        let focus = Self.focus(of: window.firstResponder, in: window)
        guard let command = commands.command(for: key, focus: focus) else { return false }
        // Held down: once, unless it steps.
        if event.isARepeat, !command.repeats { return true }
        if focus == .preview, let moved = nudgeAnnotations(command, model) { return moved }
        return perform(command, model, timeline)
    }

    /// ← → ↑ ↓ (⇧: 10 points) and ⇧↑ ⇧↓ with the focus on the preview and annotations selected (3a, decision 16): they
    /// move those the frame at the playhead shows, and the playhead stays (nothing moves during a drag). `nil` when the
    /// key does what it did in 1b: no annotation selected, or none of them shown there.
    private func nudgeAnnotations(_ command: EditorCommand, _ model: EditorModel) -> Bool? {
        guard case .annotations? = model.selection, let points = AnnotationKeys.nudge(for: command) else { return nil }
        if model.isGesturing { return true }
        return model.nudgeSelectedAnnotations(points: points) ? true : nil
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        let pairs: [(NSEvent.ModifierFlags, KeyModifiers)] = [(.command, .command), (.shift, .shift), (.option, .option), (.control, .control)]
        return pairs.reduce(into: []) { if flags.contains($1.0) { $0.insert($1.1) } }
    }

    /// What has the focus when `responder` is the window's first responder: a field being typed in; the timeline; the
    /// preview, or nothing in particular (the window itself, a split view); a control of the panel (the inspector's
    /// view); a control of the timeline's track bar or of a track's header, or of the window's bar (outside the content).
    static func focus(of responder: NSResponder?, in window: NSWindow) -> EditorFocus {
        if let text = responder as? NSTextView, text.isEditable { return .textField }
        if responder is EditorTimelineView { return .timeline }
        guard let view = responder as? NSView else { return .preview }
        guard let content = window.contentView, view.isDescendant(of: content) else { return .toolbar }
        var part: NSView? = view
        while let current = part {
            switch current.identifier?.rawValue {
            case "inspector"?: return .panel
            case "timeline"?: return .toolbar
            case "preview"?: return .preview
            default: part = current.superview
            }
        }
        return .preview
    }

    // MARK: - The commands

    private func perform(_ command: EditorCommand, _ model: EditorModel, _ timeline: EditorTimelineView) -> Bool {
        // A drag's end is an edit made from the document as the drag found it: nothing else edits meanwhile.
        if command.edits, model.isGesturing { return false }
        switch command {
        case .playPause:
            guard model.canPlay else { return false }
            model.togglePlay()
            return true
        case let .shuttle(speed):
            return model.shuttle(speed)
        case .stop:
            guard model.isPlaying else { return false }
            model.pause()
            return true
        case let .step(frames):
            return model.step(frames: frames)
        case let .stepSeconds(seconds):
            return model.step(seconds: seconds)
        case .previousEditPoint:
            return model.goToEditPoint(forward: false)
        case .nextEditPoint:
            return model.goToEditPoint(forward: true)
        case .start:
            guard model.canPlay else { return false }
            model.seekToStart()
            return true
        case .end:
            guard model.canPlay else { return false }
            model.seekToEnd()
            return true
        case .split:
            return model.splitAtPlayhead()
        case .delete:
            switch model.deleteMarkedRangeOrSelection() {
            case .done: return true
            case .nothing: return false
            case .lastClip:
                timeline.interaction.showNotice(String(localized: "There has to be at least one clip."))
                return true
            }
        case .markIn:
            return model.mark(in: true)
        case .markOut:
            return model.mark(in: false)
        case .clearMarks:
            guard model.timelineMarks != TimelineMarks() else { return false }
            model.timelineMarks = TimelineMarks()
            return true
        case .trimStartToPlayhead:
            return model.trimToPlayhead(.start)
        case .trimEndToPlayhead:
            return model.trimToPlayhead(.end)
        case let .nudge(frames):
            return model.nudgeSelection(frames: frames)
        case .addZoom:
            guard model.canEdit else { return false }
            model.addZoom()
            return true
        case .toggleSnapping:
            timeline.snapping.toggle()
            return true
        case .zoomIn, .zoomOut, .fitTimeline:
            guard timeline.content != nil else { return false }
            switch command {
            case .zoomIn: timeline.zoomIn()
            case .zoomOut: timeline.zoomOut()
            default: timeline.fitToWindow()
            }
            return true
        case .deselect:
            // Esc during a drag on the timeline gives it up; otherwise it deselects.
            if timeline.interaction.cancelDrag() { return true }
            guard model.selection != nil else { return false }
            model.selection = nil
            return true
        case let .tab(n):
            return showTab(n, model)
        case .togglePanel:
            togglePanel()
            return true
        case .export:
            // The export sheet (Task 43), whatever the bar shows — also during the "Exportación terminada" label;
            // the model refuses a second export while one runs.
            guard model.canExport else { return false }
            model.openExportSheet()
            return true
        case .open:
            open()
            return true
        case let .layout(kind):
            // The selected block's layout, or a block at the playhead or over the marked range.
            return model.applyLayoutShortcut(kind)
        case .selectAll:
            return model.selectAllOfTrack()
        case .nudgeVertically:
            // ⇧↑ ⇧↓ move the annotations selected over the preview (`nudgeAnnotations`); nothing otherwise.
            return false
        }
    }

    /// ⌘1 … ⌘8: the panel's tab (Camera only with a camera), the panel shown if it was hidden.
    private func showTab(_ n: Int, _ model: EditorModel) -> Bool {
        guard let tab = EditorPanelTab(rawValue: n - 1), tab != .camera || model.hasCamera else { return false }
        if !model.panelVisible { togglePanel() }
        withAnimation(.panel(Motion.selector, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            model.panelTab = tab
        }
        return true
    }
}

// MARK: - What the keys do to the model

extension EditorModel {
    /// ← and → (and VoiceOver's playhead): `frames` frames from the playhead, paused.
    @discardableResult
    func step(frames: Int) -> Bool {
        guard canPlay else { return false }
        if isPlaying { pause() }
        seek(frame: playheadFrame + frames)
        return true
    }

    /// ⇧← and ⇧→: `seconds` seconds of frames from the playhead, paused.
    @discardableResult
    func step(seconds: Int) -> Bool {
        guard let document else { return false }
        return step(frames: seconds * document.frameRate)
    }

    /// ↑ and ↓: the edit point before or after the playhead (the edges of the clips and of the zoom blocks, the camera's
    /// and the screens' changes, the take's markers, the start and the end), paused.
    func goToEditPoint(forward: Bool) -> Bool {
        guard canPlay, let document else { return false }
        if isPlaying { pause() }
        let map = TimeMap(sequence: document.sequence)
        let points = EditPoints(document: document, timeMap: map, markers: markerTimes).all
        guard let frame = KeyboardCommands.editPointFrame(
            from: playheadFrame, forward: forward, points: points, frameRate: document.frameRate,
            frameCount: map.frameCount(frameRate: document.frameRate))
        else { return false }
        seek(frame: frame)
        return true
    }

    /// ⌘A on the timeline (design §5.5): every item of the track with the focus, the selection's: every zoom block the
    /// timeline shows when blocks are selected, every clip otherwise. A camera change, a layout block or a change of
    /// screen is selected one at a time: nothing then.
    func selectAllOfTrack() -> Bool {
        guard state == .ready, let document else { return false }
        let map = TimeMap(sequence: document.sequence)
        switch selection {
        case .zooms?:
            let shown = document.zoom.regions.filter { region in
                region.start < region.end && !(map.outputRange(ofSource: region.start..<region.end, take: region.take)?.isEmpty ?? true)
            }
            guard !shown.isEmpty else { return false }
            selection = .zooms(Set(shown.map(\.id)))
        case .clips?, nil:
            let clips = document.sequence.filter { TimeMap.outputDuration(of: $0) > 0 }
            guard !clips.isEmpty else { return false }
            selection = .clips(Set(clips.map(\.id)))
        case .privacyBlocks?:
            let shown = PrivacyTrackRules.items(document)
            guard !shown.isEmpty else { return false }
            selection = .privacyBlocks(Set(shown.map(\.id)))
        case .annotations?:
            let shown = AnnotationTrackRules.items(document)
            guard !shown.isEmpty else { return false }
            selection = .annotations(Set(shown.map(\.item.id)))
        case .cameraChange?, .layoutBlock?, .screenChange?:
            return false
        case .gainRange?:
            return false
        }
        return true
    }

    /// I (`in`) and O: a mark at the playhead.
    func mark(in isIn: Bool) -> Bool {
        guard state == .ready, document != nil else { return false }
        var marks = timelineMarks
        if isIn { marks.markIn(at: playheadNanoseconds) } else { marks.markOut(at: playheadNanoseconds) }
        timelineMarks = marks
        return true
    }

    /// ⌫ with a range marked: the range, in one step, and the marks go; without one, what is selected.
    func deleteMarkedRangeOrSelection() -> TimelineEditResult {
        guard let range = timelineMarks.range else { return deleteSelection() }
        guard canEdit, let document else { return .nothing }
        switch SequenceCommands.deleteRange(document, output: range, takeBounds: takeBounds, makeID: Self.newID) {
        case .failure(.lastClip):
            return .lastClip
        case let .success(step):
            guard !step.changes.isEmpty, perform(step) != .refused else { return .nothing }
            timelineMarks = TimelineMarks()
            return .done
        }
    }

    /// ⌥[ and ⌥]: the start or the end of the clip under the playhead, up to it, within the bounds of that clip's take.
    @discardableResult
    func trimToPlayhead(_ edge: ClipEdge) -> Bool {
        guard canEdit, let document, let project = playheadProject,
            let step = SequenceCommands.trimToPlayhead(
                document, edge: edge, atOutput: playheadNanoseconds, take: project.take, events: project.events)
        else { return false }
        return perform(step) != .refused
    }

    /// , and . (⇧ for 10): what is selected, `frames` frames later or earlier: a zoom block, a camera change, a change of
    /// screen or a layout block. Clips do not move (the sequence is magnetic), nor several blocks at once.
    func nudgeSelection(frames: Int) -> Bool {
        guard canEdit, let document, frames != 0 else { return false }
        let map = TimeMap(sequence: document.sequence)
        let delta = TimeMap.frameTime(abs(frames), frameRate: document.frameRate) * (frames < 0 ? -1 : 1)
        let step: EditStep?
        switch selection {
        case let .zooms(ids)? where ids.count == 1:
            guard let id = ids.first, let region = document.zoom.regions.first(where: { $0.id == id }),
                let range = map.outputRange(ofSource: region.start..<region.end, take: region.take)
            else { return false }
            step = ZoomCommands.move(document, id: id, toOutputStart: range.lowerBound + delta, makeID: Self.newID)
        case let .cameraChange(id)?:
            guard let change = document.camera.changes.first(where: { $0.id == id }),
                let output = map.output(atSource: change.t, take: change.take)
            else { return false }
            step = TrackCommands.moveCameraChange(document, id: id, toOutput: output + delta, timeMap: map)
        case let .screenChange(id)?:
            guard let change = document.screens.changes.first(where: { $0.id == id }),
                let output = map.output(ofChangeAt: change.t, take: change.take)
            else { return false }
            step = TrackCommands.moveScreenBoundary(document, changeID: id, toOutput: output + delta, timeMap: map)
        case let .layoutBlock(id)?:
            guard let k = document.camera.layouts.firstIndex(where: { $0.id == id }),
                let output = LayoutTimeline.blockOutputs(of: document, timeMap: map)[k]
            else { return false }
            step = LayoutCommands.move(document, id: id, toOutputStart: output.lowerBound + delta, timeMap: map)
        case let .privacyBlocks(ids)? where ids.count == 1:
            guard let id = ids.first, let range = TimelinePrivacyItems.range(of: id, in: document) else { return false }
            step = PrivacyCommands.move(document, id: id, toOutputStart: range.lowerBound + delta)
        case .privacyBlocks?:
            step = nil
        case let .annotations(ids)? where ids.count == 1:
            guard let id = ids.first, let range = TimelineAnnotationItems.range(of: id, in: document) else { return false }
            step = AnnotationCommands.move(document, id: id, toOutputStart: range.lowerBound + delta)
        case .annotations?, .gainRange?:
            step = nil
        case .zooms?, .clips?, nil:
            step = nil
        }
        guard let step, perform(step) != .refused else { return false }
        // A moved automatic block is another one, with a new id.
        if case .zooms? = selection { selection = .zooms([step.target]) }
        return true
    }
}
