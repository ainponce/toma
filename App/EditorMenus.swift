// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Library
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
    /// The session's edits (`EditorUndoManager`); while the bar's name is being edited, what is typed in it: renaming is
    /// not an edit of the document (design §6.7).
    @objc func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if projectActions.isRenaming, window.firstResponder is NSText { return nameUndoManager }
        return model.undoManager
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

    /// "An export is in progress. Close the window and cancel it?" over the window, brought forward, as closing it asks:
    /// whether the user said Close. Not while another question is up.
    func confirmCancellingTheExport() async -> Bool {
        guard let window, !model.isAskingToClose else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "An export is in progress. Close the window and cancel it?", comment: "Closing an editor's window while its export runs")
        alert.informativeText = String(localized: "The video being exported isn't saved. The project isn't changed.")
        let answers = ExportClosingAnswer.allCases
        for answer in answers {
            alert.addButton(withTitle: Self.title(answer)).hasDestructiveAction = answer.closesTheWindow
        }
        model.isAskingToClose = true
        defer { model.isAskingToClose = false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let response = window.isVisible ? await alert.beginSheetModal(for: window) : alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) && answers[index].closesTheWindow
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
    func showsPackage(_ identity: AppSupport.PackageIdentity) -> Bool {
        AppSupport.PackageIdentity(currentPackageURL) == identity
    }

    /// Where its package is now: the session follows it when it is moved while open; once closed, where it was last seen.
    var currentPackageURL: URL {
        model.currentLocation.standardizedFileURL
    }

    /// Where its package is, and the path it was opened from, for the library (`EditorPlace`).
    var place: EditorPlace {
        EditorPlace(openedFrom: packageURL, firstSeen: model.firstSeen, current: currentPackageURL)
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
        /// The speed of the clips a speed applies to (`EditorModel.speedTargets`); `nil` if they differ.
        var speed: Double?
        /// Whether File ▸ Export Captions… has captions to export (phase 2 design §5.2).
        var canExportCaptions = false
        /// How many annotations are selected (Edit ▸ Duplicate), and the moves of Edit ▸ Arrange that change the one
        /// selected (phase 3 design §5.5).
        var selectedAnnotations = 0
        var layerMoves: Set<AnnotationCommands.LayerMove> = []
        /// Whether a drag of the document is going on (`EditorModel.isGesturing`): a step made meanwhile would clash with
        /// it, so what edits the document by a step is off until it ends (the rule `EditorKeyboard` applies).
        var isGesturing = false
        /// Whether a command that makes a step of its own can run now.
        var canStep: Bool { canEdit && !isGesturing }
    }

    /// What the File menu offers for the key editor's project as a whole (design §6.7).
    struct ProjectFile: Equatable {
        var canRename: Bool
        var canDuplicate: Bool
        /// The formats of Duplicate As: the two the project is not in.
        var otherAspects: [Aspect]
        var canMoveToTrash: Bool
    }

    /// Whether the key editor shows its panel; `nil` while no editor is the key window.
    @Published private(set) var panelVisible: Bool?
    /// The safe-zone guide of the key editor: whether it applies to its format and is shown; `nil` while no editor is key.
    @Published private(set) var safeZones: (applies: Bool, shown: Bool)?
    /// The key editor's project; `nil` while no editor is the key window or its project is not open.
    @Published private(set) var project: Project?
    /// What File offers for the key editor's project; `nil` while no editor is the key window.
    @Published private(set) var file: ProjectFile?
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

    func setSpeed(_ speed: Double) {
        model?.setSpeed(speed)
    }

    func askCustomSpeed() {
        model?.askCustomSpeed()
    }

    /// Edit ▸ Add Blur (phase 2 design §7.1).
    func addBlur() {
        model?.addBlur()
    }

    /// Edit ▸ Speed Up Typing… (phase 2 design §7.5).
    func askTypingSpeed() {
        model?.askTypingSpeed()
    }

    /// File ▸ Export Captions… (phase 2 design §5.2).
    func exportCaptions() {
        model?.exportCaptions()
    }

    /// Edit ▸ Freeze Frame, at the playhead (phase 3 design §5.3).
    func freezeFrame() {
        model?.freezeFrame()
    }

    /// Edit ▸ Add Title Card, at the playhead (phase 3 design §5.2).
    func addTitleCard() {
        guard let model else { return }
        model.addTitleCard(at: .output(model.playheadNanoseconds))
    }

    /// Edit ▸ Duplicate (⌘D): the annotations selected.
    func duplicateAnnotations() {
        model?.duplicateSelectedAnnotations()
    }

    /// Edit ▸ Arrange ▸ … (⌘] ⌘[ ⌥⌘] ⌥⌘[): the one annotation selected.
    func reorderAnnotation(_ move: AnnotationCommands.LayerMove) {
        model?.reorderSelectedAnnotation(move)
    }

    /// View ▸ Show Safe Zones.
    func toggleSafeZones() {
        model?.showsSafeZones.toggle()
    }

    func rename() {
        model?.projectActions?.startRenaming()
    }

    func duplicate(as aspect: Aspect?) {
        model?.projectActions?.duplicate(as: aspect)
    }

    func showInFinder() {
        model?.projectActions?.showInFinder()
    }

    func moveToTrash() {
        model?.projectActions?.moveToTrash()
    }

    private func follow(_ model: EditorModel?) {
        self.model = model
        generation += 1
        track(generation)
    }

    /// Reads the followed model's panel, project and what File offers, and reads them again when what was read changes.
    private func track(_ generation: Int) {
        guard generation == self.generation else { return }
        let (panel, zones, next, nextFile) = withObservationTracking {
            (
                model?.panelVisible,
                model.map { (SafeZones.applies(ratio: $0.previewRatio), $0.showsSafeZones) },
                model.flatMap { model in
                    model.document.map {
                        Project(
                            aspect: $0.aspect, frameRate: $0.frameRate, canEdit: model.canEdit, speed: model.speedOfTargets,
                            canExportCaptions: model.canExportCaptions, selectedAnnotations: model.selectedAnnotationIDs.count,
                            layerMoves: model.possibleLayerMoves, isGesturing: model.isGesturing)
                    }
                },
                model?.projectActions.map { actions in
                    ProjectFile(
                        canRename: actions.canRename && !actions.isRenaming, canDuplicate: actions.canDuplicate,
                        otherAspects: actions.otherAspects, canMoveToTrash: actions.canMoveToTrash)
                }
            )
        } onChange: { [weak self] in
            // Before the change: read once it is made.
            Task { @MainActor in self?.track(generation) }
        }
        if panelVisible != panel { panelVisible = panel }
        if safeZones?.applies != zones?.0 || safeZones?.shown != zones?.1 { safeZones = zones.map { (applies: $0.0, shown: $0.1) } }
        if project != next { project = next }
        if file != nextFile { file = nextFile }
    }
}

/// The library whose window is key, for File ▸ Rename (design §11): whether it renames a card now, followed through the
/// model's observation, as `KeyEditor` follows an editor. Its window's delegate says when it becomes key and stops being
/// key.
@MainActor
final class KeyLibrary: ObservableObject {
    static let shared = KeyLibrary()

    /// Whether Rename edits the name of the one card selected; `nil` while the library is not the key window.
    @Published private(set) var canRename: Bool?
    private weak var model: LibraryModel?
    /// Grows with each library followed: an observation of the one before is not renewed.
    private var generation = 0

    private init() {}

    func follow(_ model: LibraryModel) {
        follow(Optional(model))
    }

    func stopFollowing(_ model: LibraryModel) {
        guard self.model === model else { return }
        follow(nil)
    }

    /// File ▸ Rename: the name of the card selected is edited.
    func rename() {
        guard let model else { return }
        model.perform(.startRenaming, on: model.selection.selected)
    }

    private func follow(_ model: LibraryModel?) {
        self.model = model
        generation += 1
        track(generation)
    }

    private func track(_ generation: Int) {
        guard generation == self.generation else { return }
        let next = withObservationTracking {
            model.map { model -> Bool in
                guard model.actions.renaming == nil, model.selection.selected.count == 1, let id = model.selection.selected.first,
                    let item = model.shown.first(where: { $0.summary.identity == id })
                else { return false }
                return LibraryActionRules.reaches(.startRenaming, item, busy: model.actions.busy[id] != nil)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.track(generation) }
        }
        if canRename != next { canRename = next }
    }
}

/// File ▸ Open… (⌘O, design §5.1); then, of the key editor's project as a whole (1c design §6.7): Rename (also of the
/// key library's card, §11), Duplicate (⇧⌘S), Duplicate As ▸ (the two other formats), Show in Finder and Move to Trash
/// (which closes the window); none of them takes a key the library's window has (⌘D, ⌘⌫). And the editor's Project menu:
/// Format (16:9 · 9:16 · 1:1, as the bar's selector), Frames per Second (24 · 25 · 30 · 50 · 60) and the Speed of the
/// selected clips, or of the one under the playhead (the track bar's presets and "Custom Speed…", for the keyboard: design
/// §5.10), of the key editor's project, each an edit that is undone like any other. The project's frames per second
/// change only here.
struct ProjectCommands: Commands {
    let app: AppDelegate
    @ObservedObject var editor = KeyEditor.shared
    @ObservedObject var library = KeyLibrary.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") { app.openProject() }
                .keyboardShortcut("o")
            Divider()
            let file = editor.file
            Button(LibraryActions.title(.startRenaming, items: [])) {
                if file != nil { editor.rename() } else { library.rename() }
            }
            .disabled(!(file?.canRename ?? library.canRename ?? false))
            Button(LibraryActions.title(.duplicate, items: [])) { editor.duplicate(as: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(file?.canDuplicate != true)
            Menu(LibraryActions.duplicateAsTitle) {
                ForEach(file?.otherAspects ?? [], id: \.self) { aspect in
                    Button(LibraryActions.title(aspect)) { editor.duplicate(as: aspect) }
                }
            }
            .disabled(file?.canDuplicate != true || file?.otherAspects.isEmpty != false)
            Button(String(localized: "Show in Finder")) { editor.showInFinder() }
                .disabled(file == nil)
            Button(LibraryActions.title(.moveToTrash, items: [])) { editor.moveToTrash() }
                .disabled(file?.canMoveToTrash != true)
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
            Picker("Speed", selection: Binding(get: { project?.speed }, set: { $0.map(editor.setSpeed) })) {
                ForEach(SequenceCommands.speedPresets, id: \.self) { speed in
                    Text(verbatim: TimelineFormat.multiplier(speed)).tag(Optional(speed))
                }
            }
            .disabled(project?.canEdit != true)
            Button("Custom Speed…") { editor.askCustomSpeed() }
                .disabled(project?.canEdit != true)
        }
        // File ▸ Export Captions… (phase 2 design §5.2): the captions as an .srt or .vtt file; only with a transcript.
        CommandGroup(after: .importExport) {
            Button("Export Captions…") { editor.exportCaptions() }
                .disabled(editor.project?.canExportCaptions != true)
        }
        // Edit ▸ Add Blur (phase 2 design §7.1): a privacy block of 3 s from the playhead, as the timeline's bar makes one.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Add Blur") { editor.addBlur() }
                .disabled(editor.project?.canEdit != true)
            Button("Speed Up Typing…") { editor.askTypingSpeed() }
                .disabled(editor.project?.canEdit != true)
        }
        // Edit ▸ Freeze Frame and Add Title Card at the playhead (phase 3 design §5.2, §5.3); Duplicate (⌘D) and Arrange
        // (⌘] ⌘[ ⌥⌘] ⌥⌘[) of the annotations selected (§5.1, §5.5). Shortcuts of the menu: macOS places them on other
        // keyboard layouts. ⌘D is the library's Duplicate while the library is the key window (its own key, first).
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Freeze Frame") { editor.freezeFrame() }
                .disabled(editor.project?.canStep != true)
            Button("Add Title Card") { editor.addTitleCard() }
                .disabled(editor.project?.canStep != true)
            Divider()
            Button("Duplicate") { editor.duplicateAnnotations() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(editor.project?.canStep != true || (editor.project?.selectedAnnotations ?? 0) == 0)
            Menu("Arrange") {
                let moves = editor.project?.canStep == true ? (editor.project?.layerMoves ?? []) : []
                Button("Bring Forward") { editor.reorderAnnotation(.forward) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!moves.contains(.forward))
                Button("Send Backward") { editor.reorderAnnotation(.backward) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!moves.contains(.backward))
                Button("Bring to Front") { editor.reorderAnnotation(.front) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!moves.contains(.front))
                Button("Send to Back") { editor.reorderAnnotation(.back) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!moves.contains(.back))
            }
        }
    }
}
