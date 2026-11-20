// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// How an editor's window was left (design §5.1), in `editor-state.json` of its project's caches: read once, off the main
/// thread, before the window shows; written off the main thread every `EditorStateAutosave.interval` if it changed, and
/// when the window closes (or the app quits with it open).
@MainActor
final class EditorWindowMemory {
    /// The state as last read or written: the defaults until it is read.
    var state = EditorState()
    /// Where it is; `nil` until it is read, or if the project's manifest could not be read.
    private(set) var caches: ProjectCaches?
    /// When it is written; `nil` while there is nowhere to write it.
    var autosave: EditorStateAutosave?
    var autosaveTask: Task<Void, Never>?
    /// The window's frame and panel are where the state says: the window can show.
    var isWindowPlaced = false
    private var reading: Task<Void, Never>?

    /// Reads the state of the project at `url` once; a second call waits for the same reading. If its manifest cannot be
    /// read, the state is read from `fallback` (the session's caches, once it is open) when there is one.
    func restore(packageAt url: URL, fallback: ProjectCaches? = nil) async {
        if reading == nil {
            reading = Task {
                let root = ProjectCaches.defaultRoot
                let found = await Task.detached { EditorStateFile.caches(ofPackageAt: url, root: root) }.value
                if let found { await read(found) }
            }
        }
        await reading?.value
        if caches == nil, let fallback { await read(fallback) }
    }

    private func read(_ caches: ProjectCaches) async {
        let state = await Task.detached { EditorState.load(caches) }.value
        self.caches = caches
        self.state = state
        autosave = EditorStateAutosave(restored: state)
    }
}

/// Writes the editors' states off the main thread, one after another: a later state never lands before an earlier one.
enum EditorStateWriter {
    private static let queue = DispatchQueue(label: "dev.toma.Editor.state", qos: .utility)

    static func write(_ state: EditorState, to caches: ProjectCaches) {
        queue.async { state.save(caches) }
    }

    /// Waits for the writes asked for so far: only as the app quits, which would otherwise end before them.
    static func flush() {
        queue.sync {}
    }
}

extension EditorModel {
    /// Reads the state the window was left in, once (the window, before it shows, and the opening, before it places the
    /// playhead, wait for the same reading), then writes it every `EditorStateAutosave.interval` if it changed.
    /// `sessionCaches`: where to read it if the manifest could not be read before the session opened.
    func restoreWindowState(sessionCaches: ProjectCaches? = nil) async {
        await windowMemory.restore(packageAt: packageURL, fallback: sessionCaches)
        startAutosave()
    }

    /// Once the project is open: the playhead, the panel's tab (Camera only if the take has a camera) and the timeline's
    /// scale and scroll where they were left. The timeline starts from `timelineScale` and `timelineOffset` and writes them
    /// back as it changes.
    func restoreProjectView() {
        let remembered = EditorProjectView(remembered: windowMemory.state)
        let tab = EditorPanelTab(stateName: remembered.tab) ?? .background
        panelTab = tab == .camera && !hasCamera ? .background : tab
        timelineScale = remembered.timelineScale
        timelineOffset = remembered.timelineOffset
        seek(frame: remembered.playheadFrame)
    }

    /// Writes the state as it is now, changed or not: when the window closes, when the app quits with it open, and when a
    /// banner remembered with it is closed.
    func writeWindowState() {
        guard let caches = windowMemory.caches, let state = windowMemory.autosave?.closing(currentWindowState()) else { return }
        windowMemory.state = state
        EditorStateWriter.write(state, to: caches)
    }

    /// Stops writing the state every few seconds: the window closed.
    func stopAutosave() {
        windowMemory.autosaveTask?.cancel()
        windowMemory.autosaveTask = nil
    }

    private func startAutosave() {
        guard windowMemory.autosave != nil, windowMemory.autosaveTask == nil, !closed else { return }
        windowMemory.autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: EditorStateAutosave.interval)
                guard !Task.isCancelled, let self else { return }
                writeWindowStateIfChanged()
            }
        }
    }

    private func writeWindowStateIfChanged() {
        guard let caches = windowMemory.caches, let state = windowMemory.autosave?.due(currentWindowState()) else { return }
        windowMemory.state = state
        EditorStateWriter.write(state, to: caches)
    }

    /// The state as it is now (`EditorState.remembering`): what the project shows (the playhead, the tab, the timeline)
    /// only once it is open, and the frame unless the window is in full screen.
    private func currentWindowState() -> EditorState {
        let frame = window.flatMap { window -> Rect? in
            guard !window.styleMask.contains(.fullScreen) else { return nil }
            return Rect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height)
        }
        let project = state == .ready
            ? EditorProjectView(
                playheadFrame: playheadFrame, tab: panelTab.stateName, timelineScale: timelineScale, timelineOffset: timelineOffset)
            : nil
        return windowMemory.state.remembering(windowFrame: frame, panelVisible: panelVisible, project: project)
    }
}

extension EditorWindowController {
    /// The state the window was left in is read and its frame and panel applied: the window can show.
    var isRestored: Bool { model.windowMemory.isWindowPlaced }

    /// Reads the state the window was left in, and applies what shows before the project opens: the window's frame, if its
    /// title bar can still be reached on a screen (`EditorWindowPlacement`; otherwise it stays centered at its initial
    /// size), and the panel shown or hidden.
    func restoreWindowState() async {
        await model.restoreWindowState()
        // Only now can a second opening show it: before, it would show where it was made, and stay there.
        defer { model.windowMemory.isWindowPlaced = true }
        guard let window, !window.isVisible else { return }
        let remembered = model.windowMemory.state
        if let frame = EditorWindowPlacement.frame(
            restoring: remembered.windowFrame, screens: NSScreen.screens.map(\.visibleFrame), minimumSize: EditorLayout.minimumSize)
        {
            window.setFrame(frame, display: false)
        }
        if remembered.panelVisible != model.panelVisible { togglePanel(nil) }
    }

    /// The app quits with the window open: its state is written as if it closed.
    func writeStateBeforeQuit() {
        model.writeWindowState()
    }
}

extension EditorPanelTab {
    /// Its name in the remembered state (`EditorState.tab`).
    var stateName: String {
        switch self {
        case .background: "background"
        case .frame: "frame"
        case .camera: "camera"
        case .cursor: "cursor"
        case .zoom: "zoom"
        case .audio: "audio"
        case .captions: "captions"
        case .privacy: "privacy"
        case .annotations: "annotations"
        case .info: "info"
        }
    }

    init?(stateName: String) {
        guard let tab = Self.allCases.first(where: { $0.stateName == stateName }) else { return nil }
        self = tab
    }
}
