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
    private(set) var isRestored = false
    private var reading: Task<Void, Never>?

    /// Reads the state of the project at `url` once; a second call waits for the same reading. If its manifest cannot be
    /// read, the state is read from `fallback` (the session's caches, once it is open) when there is one.
    func restore(packageAt url: URL, fallback: ProjectCaches? = nil) async {
        if reading == nil {
            reading = Task {
                let root = ProjectCaches.defaultRoot
                let found = await Task.detached { EditorStateFile.caches(ofPackageAt: url, root: root) }.value
                if let found { await read(found) }
                isRestored = true
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

    /// Once the project is open: the playhead and the panel's tab where they were left (the Camera tab only if the take
    /// has a camera).
    func restorePlayheadAndTab() {
        let remembered = windowMemory.state
        let tab = EditorPanelTab(stateName: remembered.tab) ?? .background
        panelTab = tab == .camera && !hasCamera ? .background : tab
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

    /// The state as it is now. What only an open project has (the playhead, the tab) stays as it was remembered until the
    /// project is open; the frame of a window in full screen, too (it would open as large as the screen).
    private func currentWindowState() -> EditorState {
        var current = windowMemory.state
        if let window, !window.styleMask.contains(.fullScreen) {
            let frame = window.frame
            current.windowFrame = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        }
        current.panelVisible = panelVisible
        current.timelineScale = timelineScale
        current.timelineOffset = timelineOffset
        if state == .ready {
            current.playheadFrame = playheadFrame
            current.tab = panelTab.stateName
        }
        return current
    }
}

extension EditorWindowController {
    /// The state the window was left in is read and applied: the window can show.
    var isRestored: Bool { model.windowMemory.isRestored }

    /// Reads the state the window was left in, and applies what shows before the project opens: the window's frame, if its
    /// title bar can still be reached on a screen (`EditorWindowPlacement`; otherwise it stays centered at its initial
    /// size), and the panel shown or hidden.
    func restoreWindowState() async {
        await model.restoreWindowState()
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
        }
    }

    init?(stateName: String) {
        guard let tab = Self.allCases.first(where: { $0.stateName == stateName }) else { return nil }
        self = tab
    }
}
