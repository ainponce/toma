// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Observation
import ProjectFormat
import SwiftUI

// MARK: - Edit ▸ Undo and Redo

/// The undo manager of an editor's window (`windowWillReturnUndoManager`): the window validates Edit ▸ Undo and Redo (⌘Z,
/// ⇧⌘Z) with it and sends them through it, so they undo and redo the session's edits by their names (design §5.2), those
/// of the project's log included, after it is opened again. An item is enabled only when the session would do it
/// (`UndoMenuItem`). Nothing is registered in it: what is typed in a field of the panel is an edit of the document, and is
/// undone as one.
final class EditorUndoManager: UndoManager {
    private weak var model: EditorModel?

    init(model: EditorModel) {
        self.model = model
        super.init()
        disableUndoRegistration()
    }

    override var canUndo: Bool { undoItem.isEnabled }
    override var canRedo: Bool { redoItem.isEnabled }
    override var undoActionName: String { undoItem.label.map(localizedTitle) ?? "" }
    override var redoActionName: String { redoItem.label.map(localizedTitle) ?? "" }
    override var undoMenuItemTitle: String { editMenuUndoTitle(undoItem) }
    override var redoMenuItemTitle: String { editMenuRedoTitle(redoItem) }

    private var undoItem: UndoMenuItem { model?.undoMenuItem ?? .unavailable }
    private var redoItem: UndoMenuItem { model?.redoMenuItem ?? .unavailable }

    override func undo() {
        model?.undo()
    }

    override func redo() {
        model?.redo()
    }
}

extension EditorModel {
    /// What Edit ▸ Undo offers now: nothing until the session opens, or while a drag is under way.
    var undoMenuItem: UndoMenuItem {
        guard let session = panelSession else { return .unavailable }
        return UndoMenuItem(label: session.undoLabel, sessionWouldDoIt: session.canUndo, isGesturing: isGesturing)
    }

    /// What Edit ▸ Redo offers now.
    var redoMenuItem: UndoMenuItem {
        guard let session = panelSession else { return .unavailable }
        return UndoMenuItem(label: session.redoLabel, sessionWouldDoIt: session.canRedo, isGesturing: isGesturing)
    }

    /// Some change is not on disk yet: closing the window now loses it (design §5.9).
    var hasUnsavedChanges: Bool { panelSession?.hasUnsavedChanges ?? false }

    /// Project ▸ Frames per Second: an edit, undone like any other.
    func setFrameRate(_ fps: Int) {
        guard let document, let step = StyleCommands.setFrameRate(document, fps) else { return }
        perform(step)
    }
}

// MARK: - The window

extension EditorWindowController {
    @objc func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    /// Closing with changes that couldn't be saved asks first (design §5.9): "Keep Open", the default, or "Close Anyway".
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch EditorClosing.decide(hasUnsavedChanges: model.hasUnsavedChanges, isAsking: model.isAskingToClose) {
        case .close:
            return true
        case .keepOpen:
            return false
        case .ask:
            askBeforeClosing(sender)
            return false
        }
    }

    private func askBeforeClosing(_ window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Some changes couldn't be saved", comment: "Closing an editor whose last changes are not on the disk")
        alert.informativeText = String(
            localized: "If the window is closed now, they're lost.", comment: "Closing an editor whose last changes are not on the disk")
        let answers = UnsavedChangesAnswer.allCases
        for answer in answers {
            let button = alert.addButton(withTitle: Self.title(answer))
            button.hasDestructiveAction = answer.closesTheWindow
        }
        model.isAskingToClose = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isAskingToClose = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard answers.indices.contains(index), answers[index].closesTheWindow else { return }
                // `close()` does not ask again (`windowShouldClose` is for the window's button and ⌘W).
                self.window?.close()
            }
        }
    }

    private static func title(_ answer: UnsavedChangesAnswer) -> String {
        switch answer {
        case .keepOpen: String(localized: "Keep Open", comment: "Closing with unsaved changes: the window stays open (the default)")
        case .closeAnyway: String(localized: "Close Anyway", comment: "Closing with unsaved changes: the window closes, losing them")
        }
    }

    /// Whether this editor has the package `identity` open: its package where it is now (it may have been moved while
    /// open), or the path it was opened from until its session opens.
    func showsPackage(_ identity: PackageIdentity) -> Bool {
        PackageIdentity(model.panelSession?.packageURL ?? packageURL) == identity
    }
}

// MARK: - The app's menus

/// The editor whose window is key, for the app's menus (SwiftUI's commands do not see an AppKit window's responder chain):
/// its project as the Project menu shows it, followed through the model's observation. An `ObservableObject`, which
/// commands follow (`@ObservedObject`).
@MainActor
final class KeyEditor: ObservableObject {
    static let shared = KeyEditor()

    /// What the Project menu shows of a project.
    struct Project: Equatable {
        var aspect: Aspect
        var frameRate: Int
        var canEdit: Bool
    }

    /// The key editor's project; `nil` while no editor is the key window or its project is not open.
    @Published private(set) var project: Project?
    private weak var model: EditorModel?
    /// Grows with each editor followed: an observation of the one before is not renewed.
    private var generation = 0
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.follow((NSApp.keyWindow?.windowController as? EditorWindowController)?.model)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The editor followed is not key any more (it closed, or a sheet or another window is key now).
                guard let self, let model = self.model, model.window?.isKeyWindow != true else { return }
                self.follow(nil)
            }
        })
    }

    func setAspect(_ aspect: Aspect) {
        model?.setAspect(aspect)
    }

    func setFrameRate(_ fps: Int) {
        model?.setFrameRate(fps)
    }

    private func follow(_ model: EditorModel?) {
        self.model = model
        generation += 1
        track(generation)
    }

    /// Reads the followed model's project, and reads it again when what was read changes.
    private func track(_ generation: Int) {
        guard generation == self.generation else { return }
        let next = withObservationTracking {
            model.flatMap { model in
                model.document.map { Project(aspect: $0.aspect, frameRate: $0.frameRate, canEdit: model.canEdit) }
            }
        } onChange: { [weak self] in
            // Before the change: read once it is made.
            Task { @MainActor in self?.track(generation) }
        }
        if project != next { project = next }
    }
}

/// File ▸ Open… (⌘O, design §5.1), and the editor's Project menu: Format (16:9 · 9:16 · 1:1, as the bar's selector) and
/// Frames per Second (24 · 25 · 30 · 50 · 60) of the key editor's project, each an edit that is undone like any other.
/// The project's frames per second change only here.
struct ProjectCommands: Commands {
    let app: AppDelegate
    @ObservedObject var editor = KeyEditor.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") { app.openProject() }
                .keyboardShortcut("o")
        }
        CommandMenu("Project") {
            let project = editor.project
            Picker("Format", selection: Binding(get: { project?.aspect }, set: { $0.map(editor.setAspect) })) {
                ForEach(FormatMenu.aspects, id: \.self) { aspect in
                    Label(FormatMenu.title(aspect), systemImage: FormatMenu.symbol(aspect)).tag(Optional(aspect))
                }
            }
            .disabled(project?.canEdit != true)
            Picker("Frames per Second", selection: Binding(get: { project?.frameRate }, set: { $0.map(editor.setFrameRate) })) {
                ForEach(StyleCommands.frameRates, id: \.self) { fps in
                    Text(fps, format: .number).tag(Optional(fps))
                }
            }
            .disabled(project?.canEdit != true)
        }
    }
}
