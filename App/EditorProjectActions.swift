// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Library
import ProjectFormat

/// What an editor needs of the app to act on its project as a whole (design §6.7); made by the app delegate.
struct EditorProjectHost {
    /// The projects folder: a project in its trash opens read-only (1c decision 36), and only one inside it goes to the
    /// trash.
    var projectsFolder: URL
    /// The library's records (`library.json`), the app's one store of them: where a project in the trash came from.
    var records: () async -> LibraryRecordsStore
    /// Whether a take is being recorded, asked from any thread.
    var isRecording: @Sendable () -> Bool
    /// The library, if it is open, looks at these packages now.
    var look: ([URL]) -> Void = { _ in }
    /// Opens the package in an editor: a copy just made.
    var open: (URL) -> Void = { _ in }
    /// The editor's package is somewhere else now: the app tells the library again where its editors' packages are.
    var moved: () -> Void = {}
    /// Whether a take of this launch recorded into the package at this URL (`RecordingController.recordedThisSession`):
    /// its editor may transcribe it by itself (`AutomaticTranscription`).
    var recordedHere: (URL) -> Bool = { _ in false }
    /// "Re-record from Here" (phase 3 design §8.2): the app hides the request's editor and records a take into its package
    /// through the island, and the editor hears how it ended (`EditorModel.rerecordEnded`); `false`, with nothing hidden
    /// nor recorded, if the app can't now.
    var rerecord: (EditorRerecordRequest) -> Bool = { _ in false }
}

/// What an editor does with its project as a whole (design §6.7), with the library's operations (`LibraryOperations`),
/// none once a quit began (`LibraryWork`): renaming it from the bar's name (↩ renames, Esc leaves it as it was; not an
/// edit of the document, so the editor's undo never sees it, and the session goes on writing into the renamed package);
/// Duplicate and Duplicate As, whose copy opens (the format of Duplicate As is the copy's first edit, as in the library);
/// Show in Finder; Move to Trash, which closes the window first; and Restore, for a project that opened from the trash.
/// One at a time. What could not be done is said in an alert, with the library's words.
@MainActor @Observable
final class EditorProjectActions {
    /// The name in the bar is being edited.
    private(set) var isRenaming = false
    /// What the disk said of the name asked for, said beside the field until the name is edited again.
    private(set) var nameRefusal: NameProblem?
    /// The names of the other projects in the package's folder, read when the name starts being edited: a name taken is
    /// said as it is typed.
    private(set) var namesNearby: [String] = []
    /// An action on the project is under way.
    private(set) var isBusy = false

    /// Closes the editor's window, asking first while its export runs, and returns once its session closed; `false` if the
    /// user kept it open. Set by the window.
    @ObservationIgnored var closeWindow: @MainActor @Sendable () async -> Bool = { true }
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private let host: EditorProjectHost

    init(model: EditorModel, host: EditorProjectHost) {
        self.model = model
        self.host = host
    }

    // MARK: - What can be done

    /// Nothing starts while another action runs, nor once a quit began; and only on a project that opened.
    private var isFree: Bool {
        !isBusy && !LibraryWork.shared.isStopped && model?.state == .ready
    }

    /// A project in the trash is restored first: it only opens for viewing there (1c decision 36).
    var canRename: Bool { isFree && model?.isInTrash == false }
    var canDuplicate: Bool { isFree && model?.isInTrash == false }
    /// Only a project of the projects folder goes to the trash (design §4.5): where it is now, or where it was opened
    /// from (the session names it by its real path, which differs when the projects folder is reached through a link).
    /// The operation itself looks at where it really is.
    var canMoveToTrash: Bool {
        guard isFree, let model, !model.isInTrash else { return false }
        return [model.location, model.packageURL].contains { !isElsewhere($0) }
    }

    /// Restore, in the trash: from the banner of a project opened for viewing, or in place of Recover for a take that did
    /// not finish saving (Task 39, ruling 2).
    var canRestore: Bool {
        guard !isBusy, !LibraryWork.shared.isStopped, let model, model.isInTrash else { return false }
        switch model.state {
        case .ready, .unfinished: return true
        case .opening, .recovering, .failed, .newerDocument: return false
        }
    }

    /// The formats Duplicate As offers: the two the project is not in.
    var otherAspects: [Aspect] {
        guard let aspect = model?.document?.aspect else { return [] }
        return FormatMenu.aspects.filter { $0 != aspect }
    }

    // MARK: - Renaming

    /// A click on the name in the bar, or File ▸ Rename: the name is edited.
    func startRenaming() {
        guard canRename, let model, !isRenaming else { return }
        nameRefusal = nil
        namesNearby = []
        isRenaming = true
        let url = model.currentLocation
        Task {
            let names = await operations().namesOfProjects(in: url.deletingLastPathComponent())
            let own = url.deletingPathExtension().lastPathComponent
            guard isRenaming else { return }
            namesNearby = names.filter { $0 != own }
        }
    }

    /// Esc, or the field left with the name it had or one that cannot be used: it stays as it was.
    func cancelRenaming() {
        isRenaming = false
        nameRefusal = nil
    }

    /// The name in the field changed: what the disk said of the last one no longer holds.
    func nameEdited() {
        nameRefusal = nil
    }

    /// What is wrong with `text` as a name, as it is typed, or what the disk said of it.
    func problem(with text: String) -> NameProblem? {
        if let nameRefusal { return nameRefusal }
        if case .failure(let problem) = ProjectNames.validate(text, existing: namesNearby) { return problem }
        return nil
    }

    /// ↩, or the field left (`leaving`): the package is renamed if the name can be used and is another; otherwise ↩ keeps
    /// the field and leaving it lets it go. A name the disk refuses is said beside the field while it is open; once it
    /// closed, in an alert.
    func commitRename(_ text: String, leaving: Bool) {
        guard isRenaming, !isBusy, let model else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != model.name else {
            cancelRenaming()
            return
        }
        guard problem(with: name) == nil, !LibraryWork.shared.isStopped else {
            if leaving { cancelRenaming() }
            return
        }
        isBusy = true
        let url = model.currentLocation, before = model.name
        let ownLock = model.access == .editable
        Task {
            defer { isBusy = false }
            // This editor's own `edit.lock` is not asked about: it goes on writing into the renamed package.
            switch await operations(openHere: true, holdsLock: ownLock).rename(url, to: name) {
            case .success(let renamed):
                isRenaming = false
                model.follow(to: renamed)
                host.look([url, renamed])
                host.moved()
            case .failure(.name(let problem)) where isRenaming:
                nameRefusal = problem
            case .failure(let failure):
                isRenaming = false
                tell(.of(failure, doing: .rename, name: before, isElsewhere: isElsewhere(url)))
            }
        }
    }

    // MARK: - Duplicating

    /// Duplicate (⇧⌘S), or with `aspect` Duplicate As (design §6.3): a copy next to the package, «Demo copia» or «Demo
    /// vertical», of what is on the disk once every change shown is there; with `aspect`, the format is the copy's first
    /// edit (`LibraryActionRunner.setAspectAsFirstEdit`, the copy signed again after it, as the library does); then the
    /// copy opens. Counted while it lasts, so a quit waits for it (`LibraryWork`). A copy whose format could not be
    /// changed stays, under its name, and does not open.
    func duplicate(as aspect: Aspect?) {
        guard canDuplicate, let model else { return }
        isBusy = true
        LibraryWork.shared.beginCopy()
        let base = model.name
        Task {
            defer {
                isBusy = false
                LibraryWork.shared.endCopy()
            }
            await model.flushed()
            let url = model.currentLocation
            let operations = await operations(
                openHere: true, holdsLock: model.access == .editable, unsaved: model.hasUnsavedChanges)
            let existing = await operations.namesOfProjects(in: url.deletingLastPathComponent())
            let words = LibraryActions.words
            let name =
                aspect.map { ProjectNames.formatName(base, suffix: words.suffix($0), existing: existing) }
                ?? ProjectNames.copyName(base, existing: existing, copy: words.copy, numbered: words.numbered)
            var made: DuplicateRecord
            switch await operations.duplicate(url, named: name, progress: { _ in }) {
            case .success(let record): made = record
            case .failure(let failure):
                tell(.of(failure, doing: .duplicate, name: base, isElsewhere: isElsewhere(url)))
                return
            }
            host.look([made.copy])
            if let aspect {
                let context = await EditorModel.editContext()
                let reason = await LibraryActionRunner.setAspectAsFirstEdit(of: made.copy, aspect: aspect, context: context)
                made = await operations.signed(made)
                host.look([made.copy])
                if let reason {
                    tell(.couldNot(.changeFormat, name: name, reason))
                    return
                }
            }
            // Once a quit began, no editor opens: the quit closed the editors already.
            guard !LibraryWork.shared.isStopped else { return }
            host.open(made.copy)
        }
    }

    // MARK: - Finder and the trash

    /// Show in Finder: the package where it is now. One of Other places is looked at again (design §6.5).
    func showInFinder() {
        guard let model else { return }
        let url = model.currentLocation
        if isElsewhere(url) { host.look([url]) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Move to Trash (design §6.7): as the library does, refused while a take records or while changes could not be
    /// saved; then the window closes (what is pending is written and the lock let go) and the package goes into the
    /// trash. One another app has open is refused before the window closes.
    func moveToTrash() {
        guard canMoveToTrash, let model else { return }
        guard !model.isOpenElsewhere else {
            tell(.openElsewhere)
            return
        }
        isBusy = true
        let url = model.currentLocation, name = model.name, unsaved = model.losesEditsIfClosed
        let holdsLock = model.access == .editable
        Task {
            defer { isBusy = false }
            switch await operations(openHere: true, holdsLock: holdsLock, unsaved: unsaved).moveToTrash(url) {
            case .success(let trashed):
                // Where it came from is on the disk before anything else: Restore goes back there.
                await host.records().flush()
                host.look([url, trashed])
                host.moved()
            case .failure(let failure):
                tell(.of(failure, doing: .moveToTrash, name: name, isElsewhere: isElsewhere(url)))
            }
        }
    }

    /// The trash banner's Restaurar: the package goes back where it came from, the session for viewing closes, and the
    /// project opens again there, editable.
    func restore() {
        guard canRestore, let model else { return }
        isBusy = true
        let url = model.currentLocation, name = model.name
        Task {
            defer { isBusy = false }
            switch await operations().restore(url) {
            case .success(let restored):
                await host.records().flush()
                model.reopen(at: restored)
                host.look([url, restored])
                host.moved()
            case .failure(let failure):
                tell(.of(failure, doing: .restore, name: name, isElsewhere: false))
            }
        }
    }

    // MARK: - Re-recording

    /// "Re-record from Here", asked by the editor (`EditorModel.rerecordFromHere`): the app takes it from here; `false` if
    /// it can't now.
    func rerecord(_ request: EditorRerecordRequest) -> Bool {
        host.rerecord(request)
    }

    // MARK: -

    /// The library's operations on this editor's package, told what the app knows of it: whether this editor is to be
    /// closed before the package goes to the trash (`openHere`), whether it holds the package's `edit.lock` (`holdsLock`)
    /// and whether it has changes not on the disk (`unsaved`).
    private func operations(openHere: Bool = false, holdsLock: Bool = false, unsaved: Bool = false) async -> LibraryOperations {
        let app = EditorPackageState(
            isRecording: host.isRecording, openHere: openHere, holdsLock: holdsLock, unsaved: unsaved, close: closeWindow)
        return LibraryOperations(
            projectsFolder: host.projectsFolder, fileSystem: SystemFileSystem(), records: await host.records(), app: app)
    }

    private func isElsewhere(_ url: URL) -> Bool {
        LibraryScanner.location(of: url, projectsFolder: host.projectsFolder) == .elsewhere
    }

    /// Says `message` (design §10, §12): over the window while it is open, otherwise on its own.
    private func tell(_ message: LibraryMessage) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = LibraryActions.text(message)
        if let window = model?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }
}

/// What the library's operations are told of an editor's package as the editor acts on it (design §6.6): from the
/// editor's own state, never by probing a lock. Asked about that package only.
private final class EditorPackageState: LibraryAppState {
    private let recording: @Sendable () -> Bool
    private let openHere: Bool
    private let holdsLock: Bool
    private let unsaved: Bool
    private let closeWindow: @MainActor @Sendable () async -> Bool

    init(
        isRecording: @escaping @Sendable () -> Bool, openHere: Bool, holdsLock: Bool, unsaved: Bool,
        close: @escaping @MainActor @Sendable () async -> Bool
    ) {
        recording = isRecording
        self.openHere = openHere
        self.holdsLock = holdsLock
        self.unsaved = unsaved
        closeWindow = close
    }

    func isRecording() -> Bool { recording() }
    func isOpenHere(_ url: URL) -> Bool { openHere }
    func holdsEditLock(_ url: URL) -> Bool { holdsLock }
    func hasUnsavedChanges(_ url: URL) -> Bool { unsaved }
    func close(_ url: URL) async -> Bool { await closeWindow() }
}
