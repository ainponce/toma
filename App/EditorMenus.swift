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
    /// What each item was found to offer, for the session's state it was found in: validating an item asks for its title
    /// and whether it is enabled, and finding out applies the document again (`EditSession.canUndo`).
    private var found = Found()

    /// What the items' offers depend on: the session, its document and history (its revision and labels: a new log
    /// clears the labels without a new revision), whether it can be changed, and a drag under way.
    private struct SessionState: Equatable {
        var session: ObjectIdentifier
        var revision: Int
        var access: EditAccess
        var undoLabel: EditLabel?
        var redoLabel: EditLabel?
        var isGesturing: Bool
    }

    private struct Found {
        var state: SessionState?
        var undo: UndoMenuItem?
        var redo: UndoMenuItem?
    }

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

    override func undo() {
        model?.undo()
    }

    override func redo() {
        model?.redo()
    }

    /// What Edit ▸ Undo offers now: nothing until the session opens, or while a drag is under way.
    private var undoItem: UndoMenuItem {
        guard let (session, state) = sessionState() else { return .unavailable }
        if let undo = found.undo { return undo }
        let undo = UndoMenuItem(label: state.undoLabel, sessionWouldDoIt: session.canUndo, isGesturing: state.isGesturing)
        found.undo = undo
        return undo
    }

    /// What Edit ▸ Redo offers now.
    private var redoItem: UndoMenuItem {
        guard let (session, state) = sessionState() else { return .unavailable }
        if let redo = found.redo { return redo }
        let redo = UndoMenuItem(label: state.redoLabel, sessionWouldDoIt: session.canRedo, isGesturing: state.isGesturing)
        found.redo = redo
        return redo
    }

    /// The session and its state now; what was found for another state is forgotten.
    private func sessionState() -> (EditSession, SessionState)? {
        guard let model, let session = model.panelSession else { return nil }
        let state = SessionState(
            session: ObjectIdentifier(session), revision: session.revision, access: session.access,
            undoLabel: session.undoLabel, redoLabel: session.redoLabel, isGesturing: model.isGesturing)
        if found.state != state { found = Found(state: state) }
        return (session, state)
    }
}

extension EditorModel {
    /// Closing the window now: whether it asks first (`EditorClosing`, design §5.9): about changes that couldn't be
    /// saved, and about its export in progress.
    var closingRule: EditorClosing {
        EditorClosing.decide(
            hasUnsavedChanges: panelSession?.hasUnsavedChanges ?? false, notices: panelSession?.notices ?? [],
            isExporting: isExporting, isAsking: isAskingToClose)
    }

    /// What closing the window asks now, in order.
    var closingQuestions: [EditorClosing.Question] {
        EditorClosing.questions(
            hasUnsavedChanges: panelSession?.hasUnsavedChanges ?? false, notices: panelSession?.notices ?? [],
            isExporting: isExporting)
    }

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

    /// Closing while a change couldn't be saved (the amber banner is up) asks first (design §5.9): "Keep Open", the default,
    /// or "Close Anyway"; while its export runs, whether to cancel it, as quitting asks: "Cancel", the default, or "Close".
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch model.closingRule {
        case .close:
            return true
        case .keepOpen:
            return false
        case .ask:
            askBeforeClosing(sender, answered: [])
            return false
        }
    }

    /// Asks the first of the questions closing asks now that was not `answered` yes; closes once none is left. Each
    /// question is read again after an answer: a save may have gone through, or the export ended, meanwhile.
    private func askBeforeClosing(_ window: NSWindow, answered: [EditorClosing.Question]) {
        guard let question = model.closingQuestions.first(where: { !answered.contains($0) }) else {
            // `close()` does not ask again (`windowShouldClose` is for the window's button and ⌘W).
            window.close()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let closes: [Bool]
        switch question {
        case .unsavedChanges:
            alert.messageText = String(
                localized: "Some changes couldn't be saved", comment: "Closing an editor whose last changes are not on the disk")
            alert.informativeText = String(
                localized: "If the window is closed now, they're lost.", comment: "Closing an editor whose last changes are not on the disk")
            let answers = UnsavedChangesAnswer.allCases
            for answer in answers {
                let button = alert.addButton(withTitle: Self.title(answer))
                button.hasDestructiveAction = answer.closesTheWindow
            }
            closes = answers.map(\.closesTheWindow)
        case .cancelExport:
            alert.messageText = String(
                localized: "An export is in progress. Close the window and cancel it?",
                comment: "Closing an editor's window while its export runs")
            alert.informativeText = String(localized: "The video being exported isn't saved. The project isn't changed.")
            let answers = ExportClosingAnswer.allCases
            for answer in answers {
                let button = alert.addButton(withTitle: Self.title(answer))
                button.hasDestructiveAction = answer.closesTheWindow
            }
            closes = answers.map(\.closesTheWindow)
        }
        model.isAskingToClose = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isAskingToClose = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard closes.indices.contains(index), closes[index] else { return }
                self.askBeforeClosing(window, answered: answered + [question])
            }
        }
    }

    private static func title(_ answer: UnsavedChangesAnswer) -> String {
        switch answer {
        case .keepOpen: String(localized: "Keep Open", comment: "Closing with unsaved changes: the window stays open (the default)")
        case .closeAnyway: String(localized: "Close Anyway", comment: "Closing with unsaved changes: the window closes, losing them")
        }
    }

    private static func title(_ answer: ExportClosingAnswer) -> String {
        switch answer {
        case .cancel: String(localized: "Cancel")
        case .close: String(localized: "Close")
        }
    }

    /// Whether this editor has the package `identity` open: its package where it is now (it may have been moved while
    /// open), or the path it was opened from until its session opens.
    func showsPackage(_ identity: PackageIdentity) -> Bool {
        PackageIdentity(currentPackageURL) == identity
    }

    /// Where its package is now: the session follows it when it is moved while open.
    var currentPackageURL: URL {
        (model.panelSession?.packageURL ?? packageURL).standardizedFileURL
    }
}

// MARK: - The app's menus

/// The editor whose window is key, for the app's menus (SwiftUI's commands do not see an AppKit window's responder chain):
/// whether it shows its panel (View ▸ Show Panel / Hide Panel) and its project as the Project menu shows it, followed
/// through the model's observation. Its window's delegate says when it becomes key and stops being key. An
/// `ObservableObject`, which commands follow (`@ObservedObject`).
@MainActor
final class KeyEditor: ObservableObject {
    static let shared = KeyEditor()

    /// What the Project menu shows of a project.
    struct Project: Equatable {
        var aspect: Aspect
        var frameRate: Int
        var canEdit: Bool
    }

    /// Whether the key editor shows its panel; `nil` while no editor is the key window.
    @Published private(set) var panelVisible: Bool?
    /// The key editor's project; `nil` while no editor is the key window or its project is not open.
    @Published private(set) var project: Project?
    private weak var model: EditorModel?
    /// Grows with each editor followed: an observation of the one before is not renewed.
    private var generation = 0

    private init() {}

    /// `model`'s window became key.
    func follow(_ model: EditorModel) {
        follow(Optional(model))
    }

    /// `model`'s window is not key any more (it closed, or a sheet or another window is key now).
    func stopFollowing(_ model: EditorModel) {
        guard self.model === model else { return }
        follow(nil)
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

    /// Reads the followed model's panel and project, and reads them again when what was read changes.
    private func track(_ generation: Int) {
        guard generation == self.generation else { return }
        let (panel, next) = withObservationTracking {
            (model?.panelVisible, model.flatMap { model in
                model.document.map { Project(aspect: $0.aspect, frameRate: $0.frameRate, canEdit: model.canEdit) }
            })
        } onChange: { [weak self] in
            // Before the change: read once it is made.
            Task { @MainActor in self?.track(generation) }
        }
        if panelVisible != panel { panelVisible = panel }
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
