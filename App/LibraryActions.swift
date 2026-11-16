// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Foundation
import Library
import ProjectFormat
import SwiftUI
import Synchronization
import os

/// What the user asks the library to do with projects (design §6.3–§6.5), from the menus, the keys, a card's buttons and
/// VoiceOver: always through `LibraryModel.perform(_:on:)`.
enum LibraryCommand: Hashable {
    case open
    /// Edits the card's name: with its field, `rename` follows.
    case startRenaming
    case rename(String)
    case duplicate
    /// "Duplicar como": a copy whose first edit is this format (decision 35).
    case duplicateAs(Aspect)
    case showInFinder
    /// "." and the star: out of the favorites if they all are, otherwise into them.
    case toggleFavorite
    case setFavorite(Bool)
    case moveToTrash
    /// Only Other places: the file stays where it is.
    case removeFromLibrary
    case restore
    /// A take that did not finish saving: 1b's recovery on its package.
    case recover
    /// The trash's projects asked for, after an alert.
    case deleteNow
    /// Every project of the trash, after an alert.
    case emptyTrash
    /// Other places: looked at again ("Actualizar", design §6.5).
    case refresh
    /// Packages dropped on the window: those of the projects folder are shown, the others go to Other places.
    case addProjects([URL])
    case undo
    case redo
}

extension LibraryModel {
    /// Every action of the library goes through here (design §6.3), on the cards `ids`: none once a quit began
    /// (`LibraryWork`), and none again on a card whose action is under way.
    func perform(_ command: LibraryCommand, on ids: Set<Library.PackageIdentity> = []) {
        guard !LibraryWork.isStopped else { return }
        actions.perform(command, on: ids)
    }
}

/// The library's work that a quit waits for, in the whole app (design §6.8, `QuitSequencer`): the copies, counted from
/// the command to their end ("Duplicar como" until its first edit is written, a copy paused by a take included), and
/// the gate a quit closes, after which no new action of the library starts.
@MainActor
enum LibraryWork {
    /// A quit is going ahead: nothing new starts.
    private(set) static var isStopped = false
    private static var copies = 0
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    /// A copy is being made: a quit waits for it (`TerminationDecision.decide(…isCopying:)`).
    static var isCopying: Bool { copies > 0 }

    static func stopNewOperations() {
        isStopped = true
    }

    static func beginCopy() {
        copies += 1
    }

    static func endCopy() {
        copies -= 1
        guard copies == 0 else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once no copy is being made.
    static func waitForCopies() async {
        guard copies > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// What `LibraryOperations` asks of the app from its own threads (design §6.6): from the app's own state, as the
/// library noted it for each package just before acting on it; never by probing a lock.
final class LibraryAppStateSnapshot: LibraryAppState {
    private let isRecordingNow: @Sendable () -> Bool
    private let closeEditor: @MainActor @Sendable (URL) async -> Void
    /// By package path.
    private let noted = Mutex<[String: (openHere: Bool, unsaved: Bool)]>([:])

    init(isRecording: @escaping @Sendable () -> Bool, close: @escaping @MainActor @Sendable (URL) async -> Void) {
        isRecordingNow = isRecording
        closeEditor = close
    }

    /// What the app says of the package at `url` now.
    func note(_ url: URL, openHere: Bool, unsaved: Bool) {
        noted.withLock { $0[url.standardizedFileURL.path] = (openHere, unsaved) }
    }

    func isRecording() -> Bool { isRecordingNow() }

    func isOpenHere(_ url: URL) -> Bool {
        noted.withLock { $0[url.standardizedFileURL.path]?.openHere ?? false }
    }

    func hasUnsavedChanges(_ url: URL) -> Bool {
        noted.withLock { $0[url.standardizedFileURL.path]?.unsaved ?? false }
    }

    func close(_ url: URL) async {
        await closeEditor(url)
    }
}

/// The library's actions (design §6.3–§6.5, §9, §10): rename, duplicate (also as another format), show in the Finder,
/// favorites, the trash, Other places, deleting for good, and their undo (`LibraryUndo`, ⌘Z and ⇧⌘Z). Each works off the
/// main thread through `LibraryOperations`; meanwhile its cards show an indicator and the action does not start again
/// on them; a failure leaves the project as it was and says what and why in the strip. What an action moved is shown
/// at once, the cards settling with `Motion.trackItem`, and the scanner looks at it again.
@MainActor @Observable
final class LibraryActions {
    /// A card an action is working on; how far its copy went, when a copy without clones says.
    struct Work: Equatable {
        var progress: Double?
    }

    /// "«Demo» se movió a la papelera. · Deshacer".
    struct TrashNotice: Equatable {
        var text: String
        /// The step its Deshacer undoes, while it is the last one done (`historySerial`); `nil` for none.
        var undoes: Int?
    }

    /// Deleting for good: "Vaciando… 3 de 12", or paused while a take records.
    struct Emptying: Equatable {
        var done: Int
        var total: Int
        var paused: Bool
    }

    private(set) var busy: [Library.PackageIdentity: Work] = [:]
    /// The card whose name is being edited.
    private(set) var renaming: Library.PackageIdentity?
    /// What the disk found wrong with the name asked for (taken meanwhile, too long for it), until it is edited.
    private(set) var renameProblem: NameProblem?
    /// The strip: what failed and why, until it is closed or another failure takes its place.
    private(set) var failure: String?
    private(set) var trashNotice: TrashNotice?
    private(set) var emptying: Emptying?
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored weak var model: LibraryModel?
    /// The library's window, for the alerts.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var operations: LibraryOperations?
    @ObservationIgnored private var appState: LibraryAppStateSnapshot?
    @ObservationIgnored private var history = LibraryUndo()
    /// An undo or a redo is under way: what other actions record meanwhile waits for it (it amends the step it moved).
    @ObservationIgnored private var isUndoing = false
    @ObservationIgnored private var heldSteps: [[LibraryAction]] = []
    /// Goes up with every change of the history: a notice's Deshacer undoes its step only while it is the last done.
    @ObservationIgnored private var historySerial = 0
    /// What "Quitar de la biblioteca" took out, by path, to put back on undo.
    @ObservationIgnored private var takenOut: [String: ProjectSummary] = [:]
    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
    @ObservationIgnored private var pendingRename: Task<Void, Never>?
    /// The deletion under way, so progress that arrives after it ended is dropped.
    @ObservationIgnored private var deletion = 0

    /// How long the trash notice stays (design §6.3).
    static let noticeDuration: Duration = .seconds(8)
    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Library")

    /// Once the records are read: the operations, and what a crash left half deleted is finished (decision 33).
    func start(records: LibraryRecordsStore) {
        guard operations == nil, let model else { return }
        let appState = LibraryAppStateSnapshot(isRecording: model.recordingProbe) { [weak model] url in
            await model?.host.close(url)
        }
        let operations = LibraryOperations(
            projectsFolder: model.paths.projectsFolder, fileSystem: SystemFileSystem(), records: records, app: appState)
        self.appState = appState
        self.operations = operations
        Task { await operations.finishPendingDeletions() }
    }

    /// `LibraryModel.perform(_:on:)`.
    fileprivate func perform(_ command: LibraryCommand, on ids: Set<Library.PackageIdentity>) {
        guard let model else { return }
        let items = model.shown.filter { ids.contains($0.summary.identity) && busy[$0.summary.identity] == nil }
        let one = items.count == 1 ? items.first : nil
        switch command {
        case .open: model.open(Set(items.map(\.summary.identity)))
        case .startRenaming: if let one { startRenaming(one.summary.identity) }
        case .rename(let name): if let one { rename(one, to: name) }
        case .duplicate: for item in items { duplicate(item, as: nil) }
        case .duplicateAs(let aspect): if let one { duplicate(one, as: aspect) }
        case .showInFinder: showInFinder(items)
        case .toggleFavorite: setFavorite(!items.allSatisfy(\.favorite), items)
        case .setFavorite(let favorite): setFavorite(favorite, items)
        case .moveToTrash: moveToTrash(items)
        case .removeFromLibrary: removeFromLibrary(items)
        case .restore: restore(items.filter { $0.summary.place == .trash })
        case .recover: if let one { recover(one) }
        case .deleteNow: confirmDeletion(of: items.map(\.summary).filter { $0.place == .trash }, wholeTrash: false)
        case .emptyTrash: confirmDeletion(of: model.trashedSummaries.filter { busy[$0.identity] == nil }, wholeTrash: true)
        case .refresh: refresh(items)
        case .addProjects(let urls): add(urls)
        case .undo: undoLast()
        case .redo: redoLast()
        }
    }

    // MARK: - The strip and the notice

    func dismissFailure() {
        failure = nil
    }

    private func fail(_ text: String) {
        failure = text
    }

    private func showTrashNotice(_ names: [String], undoes: Int?) {
        guard let first = names.first else { return }
        let text =
            names.count == 1
            ? String(localized: "“\(first)” moved to the trash.", comment: "The library: the notice after a project went to the trash")
            : String(localized: "\(names.count) projects moved to the trash.", comment: "The library: the notice after several projects went to the trash")
        trashNotice = TrashNotice(text: text, undoes: undoes)
        noticeDismissal?.cancel()
        noticeDismissal = Task {
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            trashNotice = nil
        }
    }

    /// The notice's Deshacer: its step, if it is still the last one done.
    func undoTrashNotice() {
        let undoes = trashNotice?.undoes
        dismissTrashNotice()
        if let undoes, undoes == historySerial { model?.perform(.undo) }
    }

    func dismissTrashNotice() {
        noticeDismissal?.cancel()
        trashNotice = nil
    }

    // MARK: - Renaming

    private func startRenaming(_ id: Library.PackageIdentity) {
        pendingRename?.cancel()
        renameProblem = nil
        renaming = id
    }

    /// A click on the name of the only card selected: its name is edited once a double click (which opens) can no
    /// longer be under way.
    func renameAfterClick(_ id: Library.PackageIdentity) {
        pendingRename?.cancel()
        pendingRename = Task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            model?.perform(.startRenaming, on: [id])
        }
    }

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }

    func endRenaming() {
        renaming = nil
        renameProblem = nil
    }

    /// The name in the field changed: what the disk said of the last one no longer holds.
    func nameEdited() {
        renameProblem = nil
    }

    private func rename(_ item: LibraryItem, to name: String) {
        guard let model, let operations else { return }
        let summary = item.summary, id = summary.identity
        busy[id] = Work()
        Task {
            let url = await model.locate(summary)
            note([url])
            let result = await operations.rename(url, to: name)
            busy[id] = nil
            switch result {
            case .success(let renamed):
                if renaming == id { endRenaming() }
                guard renamed != url else { return }
                record([.renamed(from: url, to: renamed)])
                moved(id, from: url, to: renamed)
            case .failure(.name(let problem)) where renaming == id:
                // The field stays, with the problem beside it.
                renameProblem = problem
            case .failure(let failure):
                if renaming == id { endRenaming() }
                fail(Self.text(failure, doing: .rename, name: summary.name))
                lookAgain(summary, at: url)
            }
        }
    }

    // MARK: - Duplicating

    /// A copy next to the project, «Demo copia» (or, with `aspect`, «Demo vertical», design §6.3), counted while it is made
    /// (`LibraryWork`). With `aspect`, the format is the copy's first edit and then the copy opens (decision 35).
    private func duplicate(_ item: LibraryItem, as aspect: Aspect?) {
        guard let model, let operations else { return }
        let summary = item.summary, id = summary.identity
        busy[id] = Work()
        LibraryWork.beginCopy()
        Task {
            defer {
                busy[id] = nil
                LibraryWork.endCopy()
            }
            let url = await model.locate(summary)
            let base = url.deletingPathExtension().lastPathComponent
            let existing = await Self.projectNames(in: url.deletingLastPathComponent())
            let name =
                aspect.map { ProjectNames.formatName(base, suffix: Self.nameSuffix($0), existing: existing) }
                ?? ProjectNames.copyName(base, existing: existing, copy: Self.copyWord, numbered: Self.numberedCopyWord)
            note([url])
            let result = await operations.duplicate(url, named: name) { progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.copied(id, progress) } }
            }
            switch result {
            case .success(let made):
                record([.duplicated(made)])
                if place(of: made.copy) == .elsewhere {
                    // Next to one of Other places: one too.
                    await addOtherPlaces([made.copy])
                } else {
                    model.look(at: [made.copy])
                }
                if let aspect {
                    await firstEdit(of: made.copy, aspect: aspect)
                    model.host.open(made.copy)
                }
            case .failure(let failure):
                fail(Self.text(failure, doing: .duplicate, name: summary.name))
                lookAgain(summary, at: url)
            }
        }
    }

    private func copied(_ id: Library.PackageIdentity, _ progress: Double) {
        let shown = busy[id]?.progress ?? 0
        guard busy[id] != nil, (shown..<1).contains(progress), progress != shown else { return }
        busy[id] = Work(progress: progress)
    }

    /// "Duplicar como" (decision 35): the format is the copy's first edit, written before its editor opens; a v1 or v2
    /// project moves to v3 in the copy, never in the original.
    private func firstEdit(of copy: URL, aspect: Aspect) async {
        guard let context = model?.editContext else { return }
        do {
            let session = try await EditSession.open(copy, take: nil, context: context)
            if let step = StyleCommands.setAspect(session.document, aspect), session.perform(step) != .refused {
                _ = await session.flushed()
            }
            if session.hasUnsavedChanges {
                Self.logger.error("The format of a copy could not be written: it opens as the original")
            }
            await session.close()
        } catch {
            Self.logger.error("Cannot open a copy to change its format: \(String(describing: error), privacy: .public)")
        }
    }

    /// The names of the projects in `folder`, without `.toma`, read off the main thread.
    private nonisolated static func projectNames(in folder: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { ($0 as NSString).pathExtension.lowercased() == ProjectPackage.fileExtension }
                .map { ($0 as NSString).deletingPathExtension }
        }.value
    }

    // MARK: - Finder, favorites, Other places, recovery

    private func showInFinder(_ items: [LibraryItem]) {
        guard let model, !items.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for item in items { urls.append(await model.locate(item.summary)) }
            // One of Other places is looked at again: an action of the user on it (design §6.5).
            let elsewhere = zip(items, urls).filter { $0.0.summary.place == .elsewhere }.map(\.1)
            if !elsewhere.isEmpty { model.look(at: elsewhere) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func setFavorite(_ favorite: Bool, _ items: [LibraryItem]) {
        let changed = items.filter { $0.favorite != favorite }.map(\.summary.identity)
        guard !changed.isEmpty else { return }
        setFavorites(changed, favorite)
        record(changed.map { .favorite($0, favorite) })
    }

    private func setFavorites(_ ids: [Library.PackageIdentity], _ favorite: Bool) {
        let keys = ids.map(\.string)
        withAnimation(Self.settling) {
            model?.changeRecords { records in
                for key in keys {
                    if favorite { records.favorites.insert(key) } else { records.favorites.remove(key) }
                }
            }
        }
    }

    private func removeFromLibrary(_ items: [LibraryItem]) {
        guard let model else { return }
        var done: [LibraryAction] = []
        withAnimation(Self.settling) {
            for item in items where item.summary.place == .elsewhere {
                guard let taken = model.takeOut(item.summary.identity) else { continue }
                takenOut[taken.place.path] = taken.summary
                done.append(.removedFromLibrary(taken.place))
            }
        }
        record(done)
    }

    /// "Actualizar": each of Other places is found by its bookmark and looked at again; one that is not there shows
    /// "No disponible" (design §6.5).
    private func refresh(_ items: [LibraryItem]) {
        guard let model, !items.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for item in items { urls.append(await model.locate(item.summary)) }
            model.look(at: urls)
        }
    }

    private func recover(_ item: LibraryItem) {
        guard let model else { return }
        Task { model.host.recover(await model.locate(item.summary)) }
    }

    /// Dropped packages (design §6.2): those of the projects folder are looked at and selected; the others are added to
    /// Other places.
    private func add(_ urls: [URL]) {
        guard let model else { return }
        let packages = urls.filter { $0.pathExtension.lowercased() == ProjectPackage.fileExtension }
        let inside = packages.filter { place(of: $0) != .elsewhere }
        let outside = packages.filter { place(of: $0) == .elsewhere }
        if !inside.isEmpty {
            model.look(at: inside)
            let ids = inside.compactMap(model.identity(at:))
            if !ids.isEmpty {
                if model.shown.contains(where: { ids.contains($0.summary.identity) }) == false { model.section = .all }
                model.select(Set(ids))
            }
        }
        if !outside.isEmpty { Task { await addOtherPlaces(outside) } }
    }

    /// Adds packages out of the projects folder to Other places, with their bookmarks (made off the main thread), and
    /// looks at them: an action of the user (design §6.5).
    private func addOtherPlaces(_ urls: [URL]) async {
        guard let model, !urls.isEmpty else { return }
        let places = await Task.detached(priority: .userInitiated) {
            urls.compactMap { url -> OtherPlace? in
                guard let bookmark = try? url.bookmarkData() else { return nil }
                return OtherPlace(added: Date().roundedToWholeSeconds, bookmark: bookmark, path: url.standardizedFileURL.path)
            }
        }.value
        model.changeRecords { records in
            for place in places where !records.places.contains(where: { $0.path == place.path }) {
                records.places.append(place)
            }
        }
        model.look(at: urls)
    }

    // MARK: - The trash

    private func moveToTrash(_ items: [LibraryItem]) {
        guard let model, let operations, !items.isEmpty else { return }
        for item in items { busy[item.summary.identity] = Work() }
        Task {
            var done: [LibraryAction] = []
            var names: [String] = []
            for item in items {
                let summary = item.summary
                let url = await model.locate(summary)
                note([url])
                let result = await operations.moveToTrash(url)
                busy[summary.identity] = nil
                switch result {
                case .success(let trashed):
                    done.append(.trashed(from: url, to: trashed))
                    names.append(summary.name)
                    moved(summary.identity, from: url, to: trashed)
                case .failure(let failure):
                    fail(Self.text(failure, doing: .moveToTrash, name: summary.name))
                }
            }
            showTrashNotice(names, undoes: record(done))
        }
    }

    private func restore(_ items: [LibraryItem]) {
        guard let operations, !items.isEmpty else { return }
        for item in items { busy[item.summary.identity] = Work() }
        Task {
            var done: [LibraryAction] = []
            for item in items {
                let summary = item.summary
                let url = URL(filePath: summary.path, directoryHint: .isDirectory)
                let result = await operations.restore(url)
                busy[summary.identity] = nil
                switch result {
                case .success(let restored):
                    done.append(.restored(from: url, to: restored))
                    moved(summary.identity, from: url, to: restored)
                case .failure(let failure):
                    fail(Self.text(failure, doing: .restore, name: summary.name))
                    model?.look(at: [url])
                }
            }
            record(done)
        }
    }

    /// "Eliminar ahora…" and "Vaciar la papelera…": an alert with Cancelar by default (design §6.4), then deleting for
    /// good. One deletion at a time.
    private func confirmDeletion(of summaries: [ProjectSummary], wholeTrash: Bool) {
        guard let model, !summaries.isEmpty, emptying == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if summaries.count == 1, let name = summaries.first?.name {
            alert.messageText = String(localized: "Delete “\(name)” forever?", comment: "The library: the alert before deleting a project of the trash")
        } else {
            let bytes = wholeTrash ? model.trashBytes : summaries.reduce(0) { $0 + ($1.size ?? 0) }
            let size = bytes.formatted(.byteCount(style: .file))
            alert.messageText = String(
                localized: "Delete \(summaries.count) projects forever (\(size))?", comment: "The library: the alert before deleting projects of the trash")
        }
        alert.informativeText = String(localized: "This can't be undone.", comment: "The library: deleting for good")
        // Cancelar first: it is the default, with ↩ (and Esc).
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        let delete = alert.addButton(withTitle: Self.deleteTitle)
        cancel.keyEquivalent = "\r"
        delete.keyEquivalent = ""
        delete.hasDestructiveAction = true
        Task {
            let response: NSApplication.ModalResponse
            if let window, window.isVisible {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            if response == .alertSecondButtonReturn { deleteForever(summaries) }
        }
    }

    private func deleteForever(_ summaries: [ProjectSummary]) {
        guard let model, let operations, emptying == nil else { return }
        let ids = summaries.map(\.identity)
        let urls = summaries.map { URL(filePath: $0.path, directoryHint: .isDirectory) }
        for id in ids { busy[id] = Work() }
        deletion += 1
        let current = deletion
        emptying = Emptying(done: 0, total: urls.count, paused: false)
        note(urls)
        Task {
            let result = await operations.deleteForever(urls) { done, total, paused in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.deletion == current, self.emptying != nil else { return }
                        self.emptying = Emptying(done: done, total: total, paused: paused)
                    }
                }
            }
            emptying = nil
            for id in ids { busy[id] = nil }
            switch result {
            case .success:
                withAnimation(Self.settling) { model.forget(ids) }
            case .failure(let failure):
                fail(Self.deletionText(failure, names: summaries.map(\.name)))
            }
            model.look(at: [ProjectTrash.folder(in: model.paths.projectsFolder)])
        }
    }

    // MARK: - Undo and redo

    /// `actions`, one command's, become the next step to undo. While an undo or a redo is under way they wait for it.
    /// Returns the step's number while it is the last one done; `nil` for none, or if it waits.
    @discardableResult
    private func record(_ actions: [LibraryAction]) -> Int? {
        guard !actions.isEmpty else { return nil }
        guard !isUndoing else {
            heldSteps.append(actions)
            return nil
        }
        commit(actions)
        return historySerial
    }

    private func commit(_ actions: [LibraryAction]) {
        history.record(actions)
        historySerial += 1
        updateAvailability()
    }

    private func updateAvailability() {
        canUndo = history.canUndo && !isUndoing
        canRedo = history.canRedo && !isUndoing
    }

    /// Whether undoing or doing `action` again touches a package: not while a take records.
    private static func touchesDisk(_ action: LibraryAction) -> Bool {
        switch action {
        case .favorite, .removedFromLibrary: false
        case .renamed, .trashed, .restored, .duplicated: true
        }
    }

    /// ⌘Z: the last step, all its actions; each that cannot be undone says why and is forgotten.
    private func undoLast() {
        guard let model, let operations, !isUndoing, history.canUndo else { return }
        let step = history.popUndoStep()
        historySerial += 1
        dismissTrashNotice()
        if model.recordingProbe(), step.contains(where: Self.touchesDisk) {
            // Back where it was: it can be undone once the take ends.
            _ = history.popRedoStep()
            fail(Self.recordingText)
            return
        }
        isUndoing = true
        updateAvailability()
        Task {
            var undone: [LibraryAction] = []
            for action in step.reversed() {
                if let amended = await undo(action, operations) { undone.insert(amended, at: 0) }
            }
            history.amendNextRedo(undone)
            finishUndoing()
        }
    }

    /// ⇧⌘Z: the last step undone, all its actions.
    private func redoLast() {
        guard let model, let operations, !isUndoing, history.canRedo else { return }
        let step = history.popRedoStep()
        historySerial += 1
        if model.recordingProbe(), step.contains(where: Self.touchesDisk) {
            _ = history.popUndoStep()
            fail(Self.recordingText)
            return
        }
        isUndoing = true
        updateAvailability()
        Task {
            var redone: [LibraryAction] = []
            for action in step {
                if let amended = await redo(action, operations) { redone.append(amended) }
            }
            history.amendNextUndo(redone)
            finishUndoing()
        }
    }

    private func finishUndoing() {
        isUndoing = false
        for step in heldSteps { commit(step) }
        heldSteps = []
        updateAvailability()
    }

    /// Undoes `action`: it as it is now, to be done again; `nil` if it could not be undone (the strip says why) or cannot
    /// be done again.
    private func undo(_ action: LibraryAction, _ operations: LibraryOperations) async -> LibraryAction? {
        switch action {
        case .renamed(let from, let to):
            let id = model?.identity(at: to)
            note([to])
            switch await operations.rename(to, to: Self.name(of: from)) {
            case .success(let back):
                moved(id, from: to, to: back)
                return .renamed(from: back, to: to)
            case .failure(let failure):
                fail(Self.text(failure, doing: .rename, name: Self.name(of: to)))
                return nil
            }
        case .trashed(let from, let to):
            let id = model?.identity(at: to)
            switch await operations.restore(to) {
            case .success(var back):
                // In the trash it may have had to take «nombre 2»: back where it was, it gets its name again if it can.
                if Self.name(of: back) != Self.name(of: from) {
                    note([back])
                    if case .success(let renamed) = await operations.rename(back, to: Self.name(of: from)) { back = renamed }
                }
                moved(id, from: to, to: back)
                return .trashed(from: back, to: to)
            case .failure(let failure):
                fail(Self.text(failure, doing: .restore, name: Self.name(of: to)))
                return nil
            }
        case .restored(_, let to):
            let id = model?.identity(at: to)
            note([to])
            switch await operations.moveToTrash(to) {
            case .success(let trashed):
                moved(id, from: to, to: trashed)
                return .restored(from: trashed, to: to)
            case .failure(let failure):
                fail(Self.text(failure, doing: .moveToTrash, name: Self.name(of: to)))
                return nil
            }
        case .favorite(let identity, let favorite):
            setFavorites([identity], !favorite)
            return action
        case .removedFromLibrary(let place):
            withAnimation(Self.settling) { model?.putBack(takenOut.removeValue(forKey: place.path), place: place) }
            return action
        case .duplicated(let record):
            let id = model?.identity(at: record.copy)
            note([record.copy])
            switch await operations.undoDuplicate(record) {
            case .success(let trashed) where place(of: trashed) == .trash:
                moved(id, from: record.copy, to: trashed)
                var record = record
                record.copy = trashed
                return .duplicated(record)
            case .success:
                // A copy of Other places goes to the Trash of macOS: out of the library, and it cannot be done again.
                if let id { withAnimation(Self.settling) { _ = model?.takeOut(id) } }
                return nil
            case .failure(let failure):
                fail(Self.text(failure, doing: .moveToTrash, name: Self.name(of: record.copy)))
                return nil
            }
        }
    }

    /// Does `action` again: it as it is now, to be undone; `nil` if it could not be done (the strip says why).
    private func redo(_ action: LibraryAction, _ operations: LibraryOperations) async -> LibraryAction? {
        switch action {
        case .renamed(let from, let to):
            let id = model?.identity(at: from)
            note([from])
            switch await operations.rename(from, to: Self.name(of: to)) {
            case .success(let renamed):
                moved(id, from: from, to: renamed)
                return .renamed(from: from, to: renamed)
            case .failure(let failure):
                fail(Self.text(failure, doing: .rename, name: Self.name(of: from)))
                return nil
            }
        case .trashed(let from, _):
            let id = model?.identity(at: from)
            note([from])
            switch await operations.moveToTrash(from) {
            case .success(let trashed):
                moved(id, from: from, to: trashed)
                return .trashed(from: from, to: trashed)
            case .failure(let failure):
                fail(Self.text(failure, doing: .moveToTrash, name: Self.name(of: from)))
                return nil
            }
        case .restored(let from, _):
            guard let restored = await restoreAgain(from, operations) else { return nil }
            return .restored(from: from, to: restored)
        case .duplicated(var record):
            // Its undo put it in the library's trash: it comes back from there.
            guard let restored = await restoreAgain(record.copy, operations) else { return nil }
            record.copy = restored
            return .duplicated(record)
        case .favorite(let identity, let favorite):
            setFavorites([identity], favorite)
            return action
        case .removedFromLibrary(let place):
            if let model, let identity = model.identity(at: URL(filePath: place.path, directoryHint: .isDirectory)) {
                withAnimation(Self.settling) {
                    if let taken = model.takeOut(identity) { takenOut[place.path] = taken.summary }
                }
            }
            return action
        }
    }

    /// Restores the package at `url`, of the trash, again: where it is now, or `nil` if it could not be (the strip says
    /// why).
    private func restoreAgain(_ url: URL, _ operations: LibraryOperations) async -> URL? {
        let id = model?.identity(at: url)
        switch await operations.restore(url) {
        case .success(let restored):
            moved(id, from: url, to: restored)
            return restored
        case .failure(let failure):
            fail(Self.text(failure, doing: .restore, name: Self.name(of: url)))
            return nil
        }
    }

    // MARK: - Where things are

    /// What `LibraryOperations` will ask of the app about `urls`, from what the app said (design §6.6).
    private func note(_ urls: [URL]) {
        guard let model, let appState else { return }
        for url in urls {
            appState.note(url, openHere: model.isOpenHere(url), unsaved: model.host.hasUnsavedChanges(url))
        }
    }

    /// The project `id` (if known) went from `from` to `to`: shown there at once, the cards settling with
    /// `Motion.trackItem` (one that leaves the section shrinks to 90 % and fades, design §9); its entry of Other places
    /// follows it; the scanner looks at both.
    private func moved(_ id: Library.PackageIdentity?, from: URL, to: URL) {
        guard let model else { return }
        let place = place(of: to)
        if let id { withAnimation(Self.settling) { model.showMoved(id, to: to, place: place) } }
        if place == .elsewhere {
            let (old, new) = (from.standardizedFileURL.path, to.standardizedFileURL.path)
            model.changeRecords { records in
                for index in records.places.indices where records.places[index].path == old { records.places[index].path = new }
            }
        }
        model.look(at: [from, to])
    }

    /// One of Other places whose action failed is looked at again: it may not be there (design §6.5: "No disponible").
    private func lookAgain(_ summary: ProjectSummary, at url: URL) {
        if summary.place == .elsewhere { model?.look(at: [url]) }
    }

    /// Where a package at `url` is for the library, by its path.
    private func place(of url: URL) -> Place {
        guard let model else { return .elsewhere }
        let projects = model.paths.projectsFolder.standardizedFileURL.pathComponents
        let folder = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard folder.starts(with: projects) else { return .elsewhere }
        let relative = Array(folder.dropFirst(projects.count))
        if relative.count == 1, relative[0].caseInsensitiveCompare(ProjectTrash.folderName) == .orderedSame { return .trash }
        return .projectsFolder(subfolder: relative.joined(separator: "/"))
    }

    private static func name(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// The cards settling (design §9), or a fade with Reduce motion.
    private static var settling: Animation {
        .panel(Motion.trackItem, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

// MARK: - Menus

/// One entry of a project's menu (design §6.3); the commands are also its card's VoiceOver actions (design §11).
enum LibraryMenuEntry: Hashable {
    case command(LibraryCommand)
    /// "Duplicar como ▸" with these formats: all but the project's own.
    case duplicateAs([Aspect])
    case divider
}

extension LibraryActions {
    /// What a menu offers for `items` (the selection, or the card under the pointer): in the trash, Abrir, Restaurar,
    /// Mostrar en Finder and Eliminar ahora…; elsewhere Abrir (Recuperar for a take that did not finish saving),
    /// Renombrar and Duplicar como for one project, Duplicar, Mostrar en Finder, Favoritos, Actualizar for Other places,
    /// then Mover a la papelera, or Quitar de la biblioteca for Other places.
    static func entries(for items: [LibraryItem]) -> [LibraryMenuEntry] {
        guard !items.isEmpty else { return [] }
        let one = items.count == 1 ? items.first : nil
        if items.allSatisfy({ $0.summary.place == .trash }) {
            return [.command(.open), .command(.restore), .command(.showInFinder), .divider, .command(.deleteNow)]
        }
        var entries: [LibraryMenuEntry] = []
        entries.append(.command(one?.summary.state == .unfinished && one?.live != .recording ? .recover : .open))
        if one != nil { entries.append(.command(.startRenaming)) }
        entries.append(.command(.duplicate))
        if let one, Self.opens(one.summary.state) {
            entries.append(.duplicateAs([Aspect.landscape, .portrait, .square].filter { $0 != one.summary.aspect }))
        }
        entries.append(.command(.showInFinder))
        entries.append(.command(.toggleFavorite))
        let elsewhere = items.contains { $0.summary.place == .elsewhere }
        if elsewhere { entries.append(.command(.refresh)) }
        entries.append(.divider)
        if items.contains(where: { $0.summary.place != .elsewhere }) { entries.append(.command(.moveToTrash)) }
        if elsewhere { entries.append(.command(.removeFromLibrary)) }
        return entries
    }

    /// The commands of `entries(for:)` for one card, as VoiceOver actions (design §11), "Duplicar como" aside.
    static func accessibilityCommands(for item: LibraryItem) -> [LibraryCommand] {
        entries(for: [item]).compactMap { entry in
            if case .command(let command) = entry { return command }
            return nil
        }
    }

    /// Whether a project in `state` opens in the editor, so it can get another format.
    private static func opens(_ state: ProjectState) -> Bool {
        switch state {
        case .normal, .readOnlyVolume: true
        case .unfinished, .needsRepair, .newerVersion, .inTrash, .unavailable: false
        }
    }

    /// The title of `command` on `items`.
    static func title(_ command: LibraryCommand, items: [LibraryItem]) -> String {
        switch command {
        case .open: String(localized: "Open", comment: "The library: opens the project")
        case .startRenaming, .rename: String(localized: "Rename", comment: "The library: a project's menu")
        case .duplicate: String(localized: "Duplicate", comment: "The library: a project's menu")
        case .duplicateAs(let aspect): title(aspect)
        case .showInFinder: String(localized: "Show in Finder")
        case .toggleFavorite: items.allSatisfy(\.favorite) ? removeFromFavoritesTitle : addToFavoritesTitle
        case .setFavorite(let favorite): favorite ? addToFavoritesTitle : removeFromFavoritesTitle
        case .moveToTrash: String(localized: "Move to Trash", comment: "The library: a project's menu")
        case .removeFromLibrary: String(localized: "Remove from Library", comment: "The library: a project's menu, for Other places")
        case .restore: restoreTitle
        case .recover: String(localized: "Recover")
        case .deleteNow: String(localized: "Delete Now…", comment: "The library: a project's menu, in the trash")
        case .emptyTrash: String(localized: "Empty Trash…", comment: "The library: the trash's button")
        case .refresh: String(localized: "Refresh", comment: "The library: a project's menu, for Other places: look at it again")
        case .addProjects: ""
        case .undo: undoTitle
        case .redo: String(localized: "Redo", comment: "The library: do again what was undone")
        }
    }

    static var duplicateAsTitle: String {
        String(localized: "Duplicate As", comment: "The library: a project's menu, a copy in another format")
    }

    static func title(_ aspect: Aspect) -> String {
        switch aspect {
        case .landscape: String(localized: "Landscape 16:9", comment: "The library: Duplicate As, a format")
        case .portrait: String(localized: "Portrait 9:16", comment: "The library: Duplicate As, a format")
        case .square: String(localized: "Square 1:1", comment: "The library: Duplicate As, a format")
        }
    }

    static var addToFavoritesTitle: String {
        String(localized: "Add to Favorites", comment: "The library: a project's menu, and the star")
    }

    static var removeFromFavoritesTitle: String {
        String(localized: "Remove from Favorites", comment: "The library: a project's menu, and the star")
    }

    static var restoreTitle: String {
        String(localized: "Restore", comment: "The library: a project of the trash goes back")
    }

    static var undoTitle: String {
        String(localized: "Undo", comment: "The library: undo the last action, and the trash notice's button")
    }

    static var deleteTitle: String {
        String(localized: "Delete", comment: "The library: the alert's button that deletes for good")
    }

    // MARK: - Names of copies

    /// «copia»: what follows the name of a copy («Demo copia»).
    fileprivate static var copyWord: String {
        String(localized: "copy", comment: "The library: what follows a project's name in its copy's name («Demo copia»)")
    }

    /// «copia 2», «copia 3»…
    fileprivate static func numberedCopyWord(_ number: Int) -> String {
        String(localized: "copy \(number)", comment: "The library: what follows a project's name in its copy's name, when that is taken («Demo copia 2»)")
    }

    /// «horizontal», «vertical», «cuadrado»: what follows the name of a copy in another format.
    fileprivate static func nameSuffix(_ aspect: Aspect) -> String {
        switch aspect {
        case .landscape: String(localized: "landscape", comment: "The library: what follows a project's name in a 16:9 copy's name («Demo horizontal»)")
        case .portrait: String(localized: "portrait", comment: "The library: what follows a project's name in a 9:16 copy's name («Demo vertical»)")
        case .square: String(localized: "square", comment: "The library: what follows a project's name in a 1:1 copy's name («Demo cuadrado»)")
        }
    }

    // MARK: - What failed, in words (design §10, §12)

    enum Doing {
        case rename, duplicate, moveToTrash, restore
    }

    static var recordingText: String {
        String(localized: "It's recording.", comment: "The library: a project being recorded does not open")
    }

    /// What the strip says when `doing` failed on the project `name` (design §10): never that a project of the trash is
    /// "fuera de la carpeta" (Task 33's `.outsideProjectsFolder` also means it is no longer in the trash).
    static func text(_ failure: LibraryFailure, doing: Doing, name: String) -> String {
        switch failure {
        case .recording:
            return recordingText
        case .openElsewhere:
            return String(localized: "Can't: it's open in another app.", comment: "The library: an action on a project another app has open")
        case .copyOpenedOrChanged:
            return String(
                localized: "Can't undo: the copy was opened or changed since it was made.", comment: "The library: undoing a duplicate")
        case .noRoom(let needed):
            let size = needed.formatted(.byteCount(style: .file))
            return String(localized: "There's no room to duplicate it: \(size) are needed.", comment: "The library: a duplicate on a full disk")
        case .someNotDeleted(let count):
            return notDeletedText(count)
        case .outsideProjectsFolder where doing == .moveToTrash:
            return String(
                localized: "“\(name)” is outside Toma's folder: removing it from the library leaves the file where it is.",
                comment: "The library: a project of Other places is not moved to the trash")
        case .outsideProjectsFolder:
            return couldNot(doing, name, String(localized: "it's no longer in the trash", comment: "The library: why an action failed"))
        case .unsavedChanges:
            return couldNot(
                doing, name, String(localized: "its editor has changes that couldn't be saved", comment: "The library: why an action failed"))
        case .name(let problem):
            return couldNot(doing, name, nameReason(problem))
        case .posix(let code):
            return couldNot(doing, name, reason(code))
        }
    }

    /// What the strip says when deleting `names` for good failed.
    static func deletionText(_ failure: LibraryFailure, names: [String]) -> String {
        switch failure {
        case .recording, .openElsewhere, .someNotDeleted:
            return text(failure, doing: .moveToTrash, name: names.first ?? "")
        case .outsideProjectsFolder where names.count > 1:
            return notDeletedText(names.count)
        case .outsideProjectsFolder:
            return couldNotDelete(names.first ?? "", String(localized: "it's no longer in the trash", comment: "The library: why an action failed"))
        case .posix(let code):
            return names.count == 1 ? couldNotDelete(names[0], reason(code)) : notDeletedText(names.count)
        case .unsavedChanges, .name, .noRoom, .copyOpenedOrChanged:
            return notDeletedText(names.count)
        }
    }

    private static func notDeletedText(_ count: Int) -> String {
        String(localized: "\(count) projects couldn't be deleted: they're still in the trash.", comment: "The library: deleting for good failed")
    }

    private static func couldNotDelete(_ name: String, _ reason: String) -> String {
        String(localized: "Couldn't delete “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
    }

    private static func couldNot(_ doing: Doing, _ name: String, _ reason: String) -> String {
        switch doing {
        case .rename: String(localized: "Couldn't rename “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .duplicate: String(localized: "Couldn't duplicate “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .moveToTrash:
            String(localized: "Couldn't move “\(name)” to the trash: \(reason)", comment: "The library: the strip; the project's name and why")
        case .restore: String(localized: "Couldn't restore “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        }
    }

    /// Why a name the disk refused cannot be used, after "No se pudo …:".
    private static func nameReason(_ problem: NameProblem) -> String {
        switch problem {
        case .taken: String(localized: "a project with that name already exists", comment: "The library: why an action failed")
        case .tooLong: String(localized: "the name is too long", comment: "The library: why an action failed")
        case .empty, .slashOrColon, .leadingDot, .controlCharacter:
            String(localized: "the name can't be used", comment: "The library: why an action failed")
        }
    }

    /// Why the disk refused, after "No se pudo …:".
    private static func reason(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ENOENT, .ENOTDIR: String(localized: "it isn't there", comment: "The library: why a part of a project can't be read")
        case .EACCES, .EPERM: String(localized: "there's no permission", comment: "The library: why a part of a project can't be read")
        case .ENOSPC, .EDQUOT: String(localized: "the disk is full", comment: "The library: why an action failed")
        case .EROFS: String(localized: "the disk is read-only", comment: "The library: why an action failed")
        case .EIO: String(localized: "the disk failed", comment: "The library: why a part of a project can't be read")
        case .ETIMEDOUT: String(localized: "the disk didn't answer", comment: "The library: why a part of a project can't be read")
        case .ELOOP: String(localized: "it's a link", comment: "The library: why a part of a project can't be read")
        case .ENAMETOOLONG: nameReason(.tooLong)
        case .EEXIST: nameReason(.taken)
        default: String(localized: "the disk didn't allow it", comment: "The library: why an action failed")
        }
    }

    /// The help beside the name being edited (design §10).
    static func help(_ problem: NameProblem) -> String {
        switch problem {
        case .taken: String(localized: "A project with that name already exists.", comment: "The library: beside a name being edited")
        case .slashOrColon: String(localized: "The name can't contain “/” or “:”.", comment: "The library: beside a name being edited")
        case .empty: String(localized: "The name can't be empty.", comment: "The library: beside a name being edited")
        case .leadingDot: String(localized: "It can't start with a period.", comment: "The library: beside a name being edited")
        case .controlCharacter:
            String(localized: "The name can't contain control characters.", comment: "The library: beside a name being edited")
        case .tooLong: String(localized: "The name is too long.", comment: "The library: beside a name being edited")
        }
    }

    // MARK: - Keys a text field takes

    /// While a text field is being edited (a name, the search), the keys are its own (⌘Z, ⇧⌘Z, ⌘⌫, ↩, "."): `action`, if
    /// any, is sent to it and the library does nothing. Whether one is.
    static func textFieldTakes(_ action: Selector?) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        if let action { NSApp.sendAction(action, to: nil, from: nil) }
        return true
    }

    /// The package URLs dropped on the window, read from `providers`, then `then`.
    static func loadDropped(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
        let loads = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loads.isEmpty else { return }
        let found = Mutex<[URL]>([])
        let group = DispatchGroup()
        for provider in loads {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.withLock { $0.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = found.withLock { $0 }
            MainActor.assumeIsolated { then(urls) }
        }
    }
}

// MARK: - Views

/// The menu of `ids` (design §6.3): the context menu of a card or of the list's rows.
struct LibraryMenu: View {
    let model: LibraryModel
    let ids: Set<Library.PackageIdentity>

    var body: some View {
        let items = model.shown.filter { ids.contains($0.summary.identity) }
        ForEach(Array(LibraryActions.entries(for: items).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .command(let command):
                button(command, items: items)
            case .duplicateAs(let aspects):
                Menu(LibraryActions.duplicateAsTitle) {
                    ForEach(aspects, id: \.self) { aspect in
                        Button(LibraryActions.title(aspect)) { model.perform(.duplicateAs(aspect), on: ids) }
                    }
                }
            case .divider:
                Divider()
            }
        }
    }

    /// With the key of its shortcut, where it has one.
    @ViewBuilder private func button(_ command: LibraryCommand, items: [LibraryItem]) -> some View {
        let button = Button(LibraryActions.title(command, items: items)) { model.perform(command, on: ids) }
        switch command {
        case .duplicate: button.keyboardShortcut("d", modifiers: .command)
        case .moveToTrash: button.keyboardShortcut(.delete, modifiers: .command)
        case .toggleFavorite: button.keyboardShortcut(".", modifiers: [])
        default: button
        }
    }
}

/// The name of a card or a row being edited (design §6.3): ↩ renames, Esc and leaving it with a name that cannot be
/// used leave it as it was; beside it, what is wrong with the name as it is typed, or what the disk said.
struct LibraryRenameField: View {
    let model: LibraryModel
    let item: LibraryItem
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(model: LibraryModel, item: LibraryItem) {
        self.model = model
        self.item = item
        _text = State(initialValue: item.summary.name)
    }

    private var problem: NameProblem? {
        if let problem = model.actions.renameProblem { return problem }
        if case .failure(let problem) = ProjectNames.validate(text, existing: model.knownNames(besides: item.summary)) {
            return problem
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(text: $text) {
                Text("Name", comment: "The library's list: a column")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { commit(leaving: false) }
            .onExitCommand { model.actions.endRenaming() }
            .onChange(of: text) { model.actions.nameEdited() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit(leaving: true) }
            }
            .onAppear { isFocused = true }
            if let problem {
                Text(verbatim: LibraryActions.help(problem))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ↩, or the field left (`leaving`): renames if the name can be used and changed; otherwise ↩ keeps the field and
    /// leaving it lets it go.
    private func commit(leaving: Bool) {
        let id = item.summary.identity
        guard model.actions.renaming == id, model.actions.busy[id] == nil else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == item.summary.name {
            model.actions.endRenaming()
        } else if problem == nil {
            model.perform(.rename(name), on: [id])
        } else if leaving {
            model.actions.endRenaming()
        }
    }
}
