// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Editing
import Foundation
import Observation
import ProjectFormat
import Synchronization
import os

/// What the library's actions need of the window around them, on the main thread: what it knows of the projects, what an
/// action changed (shown at once, before the scanner looks again) and what only the app can do. The library never probes
/// a lock to know what the app has open (design §6.6).
@MainActor
public protocol LibraryActionHost: AnyObject, Sendable {
    /// The project known at `url`, if any.
    func identity(at url: URL) -> PackageIdentity?
    /// Where the package of `summary` is now: one of Other places found again by its bookmark, off the main thread.
    func locate(_ summary: ProjectSummary) async -> URL
    /// An editor of this app has the package at `url` open.
    func isOpenHere(_ url: URL) -> Bool
    /// That editor has changes it could not write.
    func hasUnsavedChanges(_ url: URL) -> Bool
    /// Closes the editor of the package at `url`, which writes what is pending and lets go of its lock; returns once it did.
    func close(_ url: URL) async
    /// The context documents are edited with, once it is made; `nil` only if it never will be (the window closed).
    func editContext() async -> EditContext?

    /// The project `identity` is now at `url`, in `place`.
    func showMoved(_ identity: PackageIdentity, to url: URL, place: Place)
    /// These projects were deleted for good.
    func forget(_ identities: [PackageIdentity])
    /// Takes the project `identity`, one of Other places, out of the library: its summary and its place, to put back.
    func takeOut(_ identity: PackageIdentity) -> (summary: ProjectSummary, place: OtherPlace)?
    func putBack(_ summary: ProjectSummary?, place: OtherPlace)
    func setFavorite(_ identities: [PackageIdentity], _ favorite: Bool)
    /// Adds these to Other places (`library.json`).
    func addPlaces(_ places: [OtherPlace])
    /// Something an action did changed these packages: they are looked at now.
    func look(at urls: [URL])
    /// Shows these projects, selected, in `section`.
    func select(_ identities: Set<PackageIdentity>, in section: LibrarySection)

    func open(_ url: URL)
    /// 1b's recovery on the package at `url`.
    func recover(_ url: URL)
    func showInFinder(_ urls: [URL])
    /// Asks whether to delete for good (an alert with Cancelar by default, design §6.4): whether the user said so.
    func confirmDeletion(_ question: LibraryDeletionQuestion) async -> Bool
}

/// What the alert before deleting for good asks (design §6.4): "¿Eliminar «Demo» para siempre?" or "¿Eliminar para
/// siempre 12 proyectos (8,4 GB)?".
public struct LibraryDeletionQuestion: Equatable, Sendable {
    public var count: Int
    /// The project's name when there is only one.
    public var name: String?
    /// What they take, as far as their sizes are summed.
    public var bytes: Int64

    public init(count: Int, name: String? = nil, bytes: Int64) {
        self.count = count
        self.name = name
        self.bytes = bytes
    }
}

/// The library's actions (design §6.3–§6.5, §9, §10): each command on the cards it reaches (`LibraryActionRules`), off the
/// main thread through `LibraryOperations`; meanwhile those cards are `busy` and no action that moves a package starts on
/// them again. What an action moved is shown at once and looked at again; what failed is told in `messages`, every failure
/// of the command, and the project stays as it was. Each command is one step of the history (`LibraryUndo`), undone and
/// done again whole by `undo` and `redo`, which mark their cards busy as well and never run over a busy one, nor while a
/// deletion is asked or under way. A take that starts during an undo or a redo stops it: what it did not reach stays as it
/// was in the history.
@MainActor @Observable
public final class LibraryActionRunner {
    /// A card an action is working on; how far its copy went, when a copy without clones says.
    public struct Work: Equatable, Sendable {
        public var progress: Double?

        public init(progress: Double? = nil) {
            self.progress = progress
        }
    }

    /// "«Demo» se movió a la papelera. · Deshacer".
    public struct TrashNotice: Equatable, Sendable {
        public var names: [String]
        /// Whether its Deshacer still undoes its step: it is the last one done.
        public var undoes: Int?
    }

    /// Deleting for good: "Vaciando… 3 de 12", or paused while a take records.
    public struct Emptying: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var paused: Bool
    }

    /// The disk refused the name asked for a project (taken meanwhile, too long for it): what the field beside it says.
    public struct NameRefusal: Equatable, Sendable {
        public var identity: PackageIdentity
        public var problem: NameProblem
    }

    /// The app's words in the names of copies (design §12): «copia», «copia 2», «vertical»…
    public struct Words: Sendable {
        public var copy: String
        public var numbered: @Sendable (Int) -> String
        public var suffix: @Sendable (Aspect) -> String

        public init(copy: String, numbered: @escaping @Sendable (Int) -> String, suffix: @escaping @Sendable (Aspect) -> String) {
            self.copy = copy
            self.numbered = numbered
            self.suffix = suffix
        }
    }

    public private(set) var busy: [PackageIdentity: Work] = [:]
    /// What the last command that failed could not do, each failure once; until it is dismissed or another fails.
    public private(set) var messages: [LibraryMessage] = []
    public private(set) var nameRefusal: NameRefusal?
    public private(set) var trashNotice: TrashNotice?
    public private(set) var emptying: Emptying?
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    /// How long the trash notice stays (design §6.3).
    @ObservationIgnored public var noticeDuration: Duration = .seconds(8)
    @ObservationIgnored public private(set) weak var host: (any LibraryActionHost)?

    @ObservationIgnored private let operations: LibraryOperations
    @ObservationIgnored private let appState: NotedAppState
    @ObservationIgnored private let projectsFolder: URL
    @ObservationIgnored private let words: Words
    @ObservationIgnored private let isRecording: @Sendable () -> Bool
    @ObservationIgnored private let copyBegan: @MainActor () -> Void
    @ObservationIgnored private let copyEnded: @MainActor () -> Void
    @ObservationIgnored private let firstEdit: @MainActor (URL, Aspect, EditContext) async -> LibraryReason?
    @ObservationIgnored private var history = LibraryUndo()
    /// An undo or a redo is under way: the steps other commands record meanwhile wait for it, which amends the one it
    /// moved.
    @ObservationIgnored private var isUndoing = false
    @ObservationIgnored private var heldSteps: [[LibraryAction]] = []
    /// A deletion waits for its alert.
    @ObservationIgnored private var deletionPending = false
    /// Goes up with every change of the history: a notice's Deshacer undoes its step only while it is the last done.
    @ObservationIgnored private var historySerial = 0
    /// What "Quitar de la biblioteca" took out, by path, to put back on undo.
    @ObservationIgnored private var takenOut: [String: ProjectSummary] = [:]
    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
    /// The deletion under way, so progress that arrives after it ended is dropped.
    @ObservationIgnored private var deletion = 0

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Library")

    /// The actions on the projects of `projectsFolder` (`LibraryOperations` with `fileSystem`, `records`, `isLockHeld` and
    /// `trash`), for `host`. `isRecording` is asked from any thread; `copyBegan` and `copyEnded` bracket every command
    /// that copies, so a quit waits for it (AppSupport's `LibraryWork`); `firstEdit` is "Duplicar como"'s
    /// (`setAspectAsFirstEdit`): `nil` once written, otherwise why not.
    public init(
        projectsFolder: URL, fileSystem: any LibraryFileSystem, records: LibraryRecordsStore, host: any LibraryActionHost,
        words: Words, isRecording: @escaping @Sendable () -> Bool, copyBegan: @escaping @MainActor () -> Void = {},
        copyEnded: @escaping @MainActor () -> Void = {},
        isLockHeld: @escaping @Sendable (URL) -> Bool = { RecordingLock.isHeld(at: $0) },
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        firstEdit: @escaping @MainActor (URL, Aspect, EditContext) async -> LibraryReason? = {
            await LibraryActionRunner.setAspectAsFirstEdit(of: $0, aspect: $1, context: $2)
        }
    ) {
        self.projectsFolder = projectsFolder
        self.host = host
        self.words = words
        self.isRecording = isRecording
        self.copyBegan = copyBegan
        self.copyEnded = copyEnded
        self.firstEdit = firstEdit
        let appState = NotedAppState(isRecording: isRecording) { [weak host] url in await host?.close(url) }
        self.appState = appState
        operations = LibraryOperations(
            projectsFolder: projectsFolder, fileSystem: fileSystem, records: records, app: appState, isLockHeld: isLockHeld,
            trash: trash)
    }

    /// What a crash left half deleted is finished (decision 33): when the library opens.
    public func finishPendingDeletions() async {
        await operations.finishPendingDeletions()
    }

    /// Carries out `command` on those of `items` it reaches (`LibraryActionRules.reaches`; for `emptyTrash`, every
    /// project of the trash): what starts at once (the cards marked busy, a copy counted) is done when this returns,
    /// and the rest runs in the task returned, which ends once the action did. `nil` when nothing runs: nothing was
    /// reached, `open` and `startRenaming` (the window's), or an undo or a redo that cannot be done now.
    @discardableResult
    public func perform(_ command: LibraryCommand, on items: [LibraryItem]) -> Task<Void, Never>? {
        let reached = items.filter { LibraryActionRules.reaches(command, $0, busy: busy[$0.summary.identity] != nil) }
        let one = reached.count == 1 ? reached.first : nil
        switch command {
        case .open, .startRenaming: return nil
        case .rename(let name): return one.flatMap { rename($0, to: name) }
        case .duplicate: return duplicate(reached, as: nil)
        case .duplicateAs(let aspect): return one.flatMap { duplicate([$0], as: aspect) }
        case .showInFinder: return showInFinder(reached)
        case .toggleFavorite: return setFavorite(!reached.allSatisfy(\.favorite), reached)
        case .setFavorite(let favorite): return setFavorite(favorite, reached)
        case .moveToTrash: return moveToTrash(reached)
        case .removeFromLibrary: return removeFromLibrary(reached)
        case .restore: return restore(reached)
        case .recover: return one.flatMap(recover)
        case .deleteNow, .emptyTrash: return delete(reached)
        case .refresh: return refresh(reached)
        case .addProjects(let urls): return add(urls)
        case .undo: return undoLast()
        case .redo: return redoLast()
        }
    }

    public func dismissMessages() {
        messages = []
    }

    /// The field that showed `nameRefusal` was edited or closed.
    public func forgetNameRefusal() {
        nameRefusal = nil
    }

    public func dismissTrashNotice() {
        noticeDismissal?.cancel()
        trashNotice = nil
    }

    /// The trash notice's Deshacer: its step, if it is still the last one done.
    @discardableResult
    public func undoTrashNotice() -> Task<Void, Never>? {
        let undoes = trashNotice?.undoes
        dismissTrashNotice()
        guard let undoes, undoes == historySerial else { return nil }
        return undoLast()
    }

    // MARK: - Renaming and duplicating

    private func rename(_ item: LibraryItem, to name: String) -> Task<Void, Never>? {
        let summary = item.summary, id = summary.identity
        busy[id] = Work()
        nameRefusal = nil
        return Task {
            defer { busy[id] = nil }
            let url = await locate(summary)
            note([url])
            switch await operations.rename(url, to: name) {
            case .success(let renamed):
                guard renamed != url else { return }
                record([.renamed(from: url, to: renamed)])
                moved(id, from: url, to: renamed)
            case .failure(.name(let problem)):
                nameRefusal = NameRefusal(identity: id, problem: problem)
            case .failure(let failure):
                report([.of(failure, doing: .rename, name: summary.name, isElsewhere: summary.place == .elsewhere)])
                lookAgain(summary, at: url)
            }
        }
    }

    /// A copy of each of `items` next to it, «Demo copia» (or, with `aspect`, «Demo vertical», design §6.3), one step of
    /// the history, counted while it lasts (`copyBegan`). With `aspect`, the format is the copy's first edit, after the
    /// edit context is made, and then the copy opens (decision 35); if the edit cannot be written, the copy stays, under
    /// its name, and the messages say so. A copy is signed again after its first edit, so undoing it finds it unchanged.
    private func duplicate(_ items: [LibraryItem], as aspect: Aspect?) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        for item in items { busy[item.summary.identity] = Work() }
        copyBegan()
        return Task {
            var done: [LibraryAction] = []
            var failures: [LibraryMessage] = []
            for item in items {
                let (made, failure) = await duplicate(item.summary, as: aspect)
                if let made { done.append(.duplicated(made)) }
                if let failure { failures.append(failure) }
                busy[item.summary.identity] = nil
            }
            record(done)
            report(failures)
            copyEnded()
        }
    }

    private func duplicate(_ summary: ProjectSummary, as aspect: Aspect?) async -> (DuplicateRecord?, LibraryMessage?) {
        let id = summary.identity
        let url = await locate(summary)
        let base = Self.name(of: url)
        let existing = await operations.namesOfProjects(in: url.deletingLastPathComponent())
        let name =
            aspect.map { ProjectNames.formatName(base, suffix: words.suffix($0), existing: existing) }
            ?? ProjectNames.copyName(base, existing: existing, copy: words.copy, numbered: words.numbered)
        note([url])
        let result = await operations.duplicate(url, named: name) { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.copied(id, progress) } }
        }
        guard case .success(var made) = result else {
            lookAgain(summary, at: url)
            guard case .failure(let failure) = result else { return (nil, nil) }
            return (nil, .of(failure, doing: .duplicate, name: summary.name, isElsewhere: summary.place == .elsewhere))
        }
        if location(of: made.copy) == .elsewhere {
            // Next to one of Other places: one too.
            await addOtherPlaces([made.copy])
        } else {
            host?.look(at: [made.copy])
        }
        guard let aspect else { return (made, nil) }
        var reason: LibraryReason? = .copyCannotBeOpened
        if let context = await host?.editContext() { reason = await firstEdit(made.copy, aspect, context) }
        made = await operations.signed(made)
        host?.look(at: [made.copy])
        if let reason {
            Self.logger.error("The format of a copy could not be changed: \(String(describing: reason), privacy: .public)")
            return (made, .couldNot(.changeFormat, name: name, reason))
        }
        host?.open(made.copy)
        return (made, nil)
    }

    private func copied(_ id: PackageIdentity, _ progress: Double) {
        let shown = busy[id]?.progress ?? 0
        guard busy[id] != nil, (shown..<1).contains(progress), progress != shown else { return }
        busy[id] = Work(progress: progress)
    }

    /// "Duplicar como"'s first edit (decision 35): `StyleCommands.setAspect` on the copy at `copy`, through an
    /// `EditSession` (a v1 or v2 project moves to v3 in the copy, never in the original), written before the session
    /// closes. `nil` once it is on disk (or the copy has that format already), otherwise why not.
    public static func setAspectAsFirstEdit(of copy: URL, aspect: Aspect, context: EditContext) async -> LibraryReason? {
        let session: EditSession
        do {
            session = try await EditSession.open(copy, take: nil, context: context)
        } catch {
            return .copyCannotBeOpened
        }
        var reason: LibraryReason?
        if let step = StyleCommands.setAspect(session.document, aspect) {
            if session.perform(step) == .refused {
                reason = .copyCannotBeEdited
            } else {
                _ = await session.flushed()
            }
        }
        await session.close()
        if reason == nil, session.hasUnsavedChanges { reason = .editNotSaved }
        return reason
    }

    // MARK: - Finder, favorites, Other places, recovery

    private func showInFinder(_ items: [LibraryItem]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        return Task {
            var urls: [URL] = []
            for item in items { urls.append(await locate(item.summary)) }
            // One of Other places is looked at again: an action of the user on it (design §6.5).
            let elsewhere = zip(items, urls).filter { $0.0.summary.place == .elsewhere }.map(\.1)
            if !elsewhere.isEmpty { host?.look(at: elsewhere) }
            host?.showInFinder(urls)
        }
    }

    private func setFavorite(_ favorite: Bool, _ items: [LibraryItem]) -> Task<Void, Never>? {
        let changed = items.filter { $0.favorite != favorite }.map(\.summary.identity)
        guard !changed.isEmpty else { return nil }
        host?.setFavorite(changed, favorite)
        record(changed.map { .favorite($0, favorite) })
        return nil
    }

    private func removeFromLibrary(_ items: [LibraryItem]) -> Task<Void, Never>? {
        var done: [LibraryAction] = []
        for item in items {
            guard let taken = host?.takeOut(item.summary.identity) else { continue }
            takenOut[taken.place.path] = taken.summary
            done.append(.removedFromLibrary(taken.place))
        }
        record(done)
        return nil
    }

    /// "Actualizar": each of Other places is found by its bookmark and looked at again; one that is not there shows
    /// "No disponible" (design §6.5).
    private func refresh(_ items: [LibraryItem]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        return Task {
            var urls: [URL] = []
            for item in items { urls.append(await locate(item.summary)) }
            host?.look(at: urls)
        }
    }

    private func recover(_ item: LibraryItem) -> Task<Void, Never>? {
        Task { host?.recover(await locate(item.summary)) }
    }

    /// Dropped packages (design §6.2), only folders named `<name>.toma`, never a file or a link: those the walk lists are
    /// looked at and shown, selected, in their section (the trash's in the trash); those it never lists (too deep,
    /// hidden, in a folder of the trash or in another package) say why; the others go to Other places.
    private func add(_ urls: [URL]) -> Task<Void, Never>? {
        let candidates = urls.filter { PackageNames.isPackage($0.lastPathComponent) }
        guard !candidates.isEmpty else { return nil }
        return Task {
            let packages = await operations.packageFolders(candidates)
            var listed: [(url: URL, place: Place)] = []
            var outside: [URL] = []
            var failures: [LibraryMessage] = []
            for url in packages {
                switch location(of: url) {
                case .listed(let place): listed.append((url, place))
                case .elsewhere: outside.append(url)
                case .notListed(let why): failures.append(.notListed(name: Self.name(of: url), why))
                }
            }
            if let first = listed.first {
                host?.look(at: listed.map(\.url))
                let section: LibrarySection = first.place == .trash ? .trash : .all
                let ids = listed.filter { ($0.place == .trash) == (section == .trash) }.compactMap { host?.identity(at: $0.url) }
                if !ids.isEmpty { host?.select(Set(ids), in: section) }
            }
            await addOtherPlaces(outside)
            report(failures)
        }
    }

    /// Adds packages out of the projects folder to Other places, with their bookmarks (made off the main thread), and
    /// looks at them: an action of the user (design §6.5).
    private func addOtherPlaces(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let places = await Task.detached(priority: .userInitiated) {
            urls.compactMap { url -> OtherPlace? in
                guard let bookmark = try? url.bookmarkData() else { return nil }
                return OtherPlace(added: Date().roundedToWholeSeconds, bookmark: bookmark, path: url.standardizedFileURL.path)
            }
        }.value
        host?.addPlaces(places)
        host?.look(at: urls)
    }

    // MARK: - The trash

    private func moveToTrash(_ items: [LibraryItem]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        for item in items { busy[item.summary.identity] = Work() }
        return Task {
            var done: [LibraryAction] = []
            var names: [String] = []
            var failures: [LibraryMessage] = []
            for item in items {
                let summary = item.summary
                let url = await locate(summary)
                note([url])
                let result = await operations.moveToTrash(url)
                busy[summary.identity] = nil
                switch result {
                case .success(let trashed):
                    done.append(.trashed(from: url, to: trashed))
                    names.append(summary.name)
                    moved(summary.identity, from: url, to: trashed)
                case .failure(let failure):
                    failures.append(.of(failure, doing: .moveToTrash, name: summary.name, isElsewhere: summary.place == .elsewhere))
                }
            }
            showTrashNotice(names, undoes: record(done))
            report(failures)
        }
    }

    private func restore(_ items: [LibraryItem]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        for item in items { busy[item.summary.identity] = Work() }
        return Task {
            var done: [LibraryAction] = []
            var failures: [LibraryMessage] = []
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
                    failures.append(.of(failure, doing: .restore, name: summary.name, isElsewhere: false))
                    host?.look(at: [url])
                }
            }
            record(done)
            report(failures)
        }
    }

    /// "Eliminar ahora…" and "Vaciar la papelera…" (design §6.4): their cards are busy from now on, the alert asks
    /// (the size of those to delete, busy ones left out), then each is deleted for good; one deletion at a time, and
    /// no undo or redo meanwhile. Only the projects deleted leave the library.
    private func delete(_ items: [LibraryItem]) -> Task<Void, Never>? {
        guard !items.isEmpty, emptying == nil, !deletionPending else { return nil }
        let summaries = items.map(\.summary)
        let ids = summaries.map(\.identity)
        deletionPending = true
        for id in ids { busy[id] = Work() }
        updateAvailability()
        let question = LibraryDeletionQuestion(
            count: summaries.count, name: summaries.count == 1 ? summaries[0].name : nil,
            bytes: summaries.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        return Task {
            let confirmed = await host?.confirmDeletion(question) ?? false
            deletionPending = false
            guard confirmed else {
                for id in ids { busy[id] = nil }
                updateAvailability()
                return
            }
            let urls = summaries.map { URL(filePath: $0.path, directoryHint: .isDirectory) }
            deletion += 1
            let current = deletion
            emptying = Emptying(done: 0, total: urls.count, paused: false)
            updateAvailability()
            note(urls)
            let result = await operations.deletion(of: urls) { done, total, paused in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.deletion == current, self.emptying != nil else { return }
                        self.emptying = Emptying(done: done, total: total, paused: paused)
                    }
                }
            }
            emptying = nil
            for id in ids { busy[id] = nil }
            updateAvailability()
            if !result.deleted.isEmpty { host?.forget(result.deleted) }
            if let failure = result.failure { report([.ofDeletion(failure, names: summaries.map(\.name))]) }
            host?.look(at: [ProjectTrash.folder(in: projectsFolder)])
        }
    }

    private func showTrashNotice(_ names: [String], undoes: Int?) {
        guard !names.isEmpty else { return }
        trashNotice = TrashNotice(names: names, undoes: undoes)
        noticeDismissal?.cancel()
        let duration = noticeDuration
        noticeDismissal = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            trashNotice = nil
        }
    }

    // MARK: - Undo and redo

    /// What undoing or doing one action again came to.
    private enum Outcome {
        /// Done: the action as it is now, to be done the other way next; `nil` if it cannot be.
        case done(LibraryAction?)
        /// It could not be; it is forgotten.
        case failed(LibraryMessage)
        /// A take started: neither it nor what comes after in the step is touched.
        case stopped
    }

    /// `actions`, one command's, become the next step to undo; while an undo or a redo is under way they wait for it.
    /// Returns the step's number while it is the last one done (`historySerial`); `nil` for none, or if it waits.
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
        let free = !isUndoing && !deletionPending && emptying == nil
        if canUndo != (free && history.canUndo) { canUndo = free && history.canUndo }
        if canRedo != (free && history.canRedo) { canRedo = free && history.canRedo }
    }

    /// Whether undoing or doing `action` again touches a package: not while a take records.
    private static func touchesDisk(_ action: LibraryAction) -> Bool {
        switch action {
        case .favorite, .removedFromLibrary: false
        case .renamed, .trashed, .restored, .duplicated: true
        }
    }

    /// The card a package `action` moves when it is undone (`undoing`) or done again: the one at the URL it starts from.
    private func card(of action: LibraryAction, undoing: Bool) -> PackageIdentity? {
        switch action {
        case .renamed(let from, let to), .trashed(let from, let to), .restored(let from, let to):
            return host?.identity(at: undoing ? to : from)
        case .duplicated(let record):
            return host?.identity(at: record.copy)
        case .favorite, .removedFromLibrary:
            return nil
        }
    }

    /// Whether `step` can be undone (`undoing`) or done again now: not while a take records (it says so) nor while one
    /// of its cards is busy. If not, it stays where it was.
    private func mayRun(_ step: [LibraryAction], undoing: Bool) -> Set<PackageIdentity>? {
        let moving = step.filter(Self.touchesDisk)
        let cards = Set(moving.compactMap { card(of: $0, undoing: undoing) })
        if cards.contains(where: { busy[$0] != nil }) { return nil }
        if !moving.isEmpty, isRecording() {
            report([.recording])
            return nil
        }
        return cards
    }

    /// ⌘Z: the last step, all its actions, the last first.
    private func undoLast() -> Task<Void, Never>? {
        guard !isUndoing, !deletionPending, emptying == nil, history.canUndo else { return nil }
        let step = history.popUndoStep()
        historySerial += 1
        dismissTrashNotice()
        guard let cards = mayRun(step, undoing: true) else {
            _ = history.popRedoStep()
            historySerial += 1
            updateAvailability()
            return nil
        }
        isUndoing = true
        for id in cards { busy[id] = Work() }
        updateAvailability()
        return Task {
            var undone: [LibraryAction] = []
            var stillToUndo: [LibraryAction] = []
            var failures: [LibraryMessage] = []
            let order = Array(step.reversed())
            actions: for (index, action) in order.enumerated() {
                let outcome: Outcome
                if Self.touchesDisk(action), isRecording() {
                    outcome = .stopped
                } else {
                    outcome = await undo(action)
                }
                switch outcome {
                case .done(let amended):
                    if let amended { undone.insert(amended, at: 0) }
                case .failed(let message):
                    failures.append(message)
                case .stopped:
                    stillToUndo = order[index...].reversed()
                    failures.append(.recording)
                    break actions
                }
            }
            history.amendNextRedo(undone, stillToUndo: stillToUndo)
            for id in cards { busy[id] = nil }
            finishUndoing()
            report(failures)
        }
    }

    /// ⇧⌘Z: the last step undone, all its actions, in the order they were done.
    private func redoLast() -> Task<Void, Never>? {
        guard !isUndoing, !deletionPending, emptying == nil, history.canRedo else { return nil }
        let step = history.popRedoStep()
        historySerial += 1
        guard let cards = mayRun(step, undoing: false) else {
            _ = history.popUndoStep()
            historySerial += 1
            updateAvailability()
            return nil
        }
        isUndoing = true
        for id in cards { busy[id] = Work() }
        updateAvailability()
        return Task {
            var redone: [LibraryAction] = []
            var stillToRedo: [LibraryAction] = []
            var failures: [LibraryMessage] = []
            actions: for (index, action) in step.enumerated() {
                let outcome: Outcome
                if Self.touchesDisk(action), isRecording() {
                    outcome = .stopped
                } else {
                    outcome = await redo(action)
                }
                switch outcome {
                case .done(let amended):
                    if let amended { redone.append(amended) }
                case .failed(let message):
                    failures.append(message)
                case .stopped:
                    stillToRedo = Array(step[index...])
                    failures.append(.recording)
                    break actions
                }
            }
            history.amendNextUndo(redone, stillToRedo: stillToRedo)
            for id in cards { busy[id] = nil }
            finishUndoing()
            report(failures)
        }
    }

    private func finishUndoing() {
        isUndoing = false
        for step in heldSteps { commit(step) }
        heldSteps = []
        updateAvailability()
    }

    private func undo(_ action: LibraryAction) async -> Outcome {
        switch action {
        case .renamed(let from, let to):
            let id = host?.identity(at: to)
            note([to])
            switch await operations.rename(to, to: Self.name(of: from)) {
            case .success(let back):
                moved(id, from: to, to: back)
                return .done(.renamed(from: back, to: to))
            case .failure(let failure):
                return failed(failure, doing: .rename, at: to)
            }
        case .trashed(let from, let to):
            let id = host?.identity(at: to)
            switch await operations.restore(to) {
            case .success(var back):
                // In the trash it may have had to take «nombre 2»: back where it was, it gets its name again if it can.
                if Self.name(of: back) != Self.name(of: from) {
                    note([back])
                    if case .success(let renamed) = await operations.rename(back, to: Self.name(of: from)) { back = renamed }
                }
                moved(id, from: to, to: back)
                return .done(.trashed(from: back, to: to))
            case .failure(let failure):
                return failed(failure, doing: .restore, at: to)
            }
        case .restored(_, let to):
            let id = host?.identity(at: to)
            note([to])
            switch await operations.moveToTrash(to) {
            case .success(let trashed):
                moved(id, from: to, to: trashed)
                return .done(.restored(from: trashed, to: to))
            case .failure(let failure):
                return failed(failure, doing: .moveToTrash, at: to)
            }
        case .favorite(let identity, let favorite):
            host?.setFavorite([identity], !favorite)
            return .done(action)
        case .removedFromLibrary(let place):
            host?.putBack(takenOut.removeValue(forKey: place.path), place: place)
            return .done(action)
        case .duplicated(let record):
            let id = host?.identity(at: record.copy)
            note([record.copy])
            switch await operations.undoDuplicate(record) {
            case .success(let trashed) where location(of: trashed) == .listed(.trash):
                moved(id, from: record.copy, to: trashed)
                var record = record
                record.copy = trashed
                return .done(.duplicated(record))
            case .success:
                // A copy of Other places goes to the Trash of macOS: out of the library, and it cannot be done again.
                if let id { _ = host?.takeOut(id) }
                return .done(nil)
            case .failure(let failure):
                return failed(failure, doing: .moveToTrash, at: record.copy)
            }
        }
    }

    private func redo(_ action: LibraryAction) async -> Outcome {
        switch action {
        case .renamed(let from, let to):
            let id = host?.identity(at: from)
            note([from])
            switch await operations.rename(from, to: Self.name(of: to)) {
            case .success(let renamed):
                moved(id, from: from, to: renamed)
                return .done(.renamed(from: from, to: renamed))
            case .failure(let failure):
                return failed(failure, doing: .rename, at: from)
            }
        case .trashed(let from, _):
            let id = host?.identity(at: from)
            note([from])
            switch await operations.moveToTrash(from) {
            case .success(let trashed):
                moved(id, from: from, to: trashed)
                return .done(.trashed(from: from, to: trashed))
            case .failure(let failure):
                return failed(failure, doing: .moveToTrash, at: from)
            }
        case .restored(let from, _):
            switch await restoreAgain(from) {
            case .success(let restored): return .done(.restored(from: from, to: restored))
            case .failure(let failure): return failed(failure, doing: .restore, at: from)
            }
        case .duplicated(var record):
            // Its undo put it in the library's trash: it comes back from there.
            switch await restoreAgain(record.copy) {
            case .success(let restored):
                record.copy = restored
                return .done(.duplicated(record))
            case .failure(let failure):
                return failed(failure, doing: .restore, at: record.copy)
            }
        case .favorite(let identity, let favorite):
            host?.setFavorite([identity], favorite)
            return .done(action)
        case .removedFromLibrary(let place):
            if let identity = host?.identity(at: URL(filePath: place.path, directoryHint: .isDirectory)),
                let taken = host?.takeOut(identity)
            {
                takenOut[place.path] = taken.summary
            }
            return .done(action)
        }
    }

    private func restoreAgain(_ url: URL) async -> Result<URL, LibraryFailure> {
        let id = host?.identity(at: url)
        let result = await operations.restore(url)
        if case .success(let restored) = result { moved(id, from: url, to: restored) }
        return result
    }

    /// What a failure of undoing or doing again tells: a take that started stops the rest.
    private func failed(_ failure: LibraryFailure, doing: LibraryDoing, at url: URL) -> Outcome {
        if failure == .recording { return .stopped }
        return .failed(.of(failure, doing: doing, name: Self.name(of: url), isElsewhere: location(of: url) == .elsewhere))
    }

    // MARK: - Where things are

    private func report(_ failures: [LibraryMessage]) {
        guard !failures.isEmpty else { return }
        var once: [LibraryMessage] = []
        for message in failures where !once.contains(message) { once.append(message) }
        messages = once
    }

    private func locate(_ summary: ProjectSummary) async -> URL {
        await host?.locate(summary) ?? URL(filePath: summary.path, directoryHint: .isDirectory)
    }

    /// What `LibraryOperations` will ask of the app about `urls`, from what the app says now (design §6.6).
    private func note(_ urls: [URL]) {
        for url in urls {
            appState.note(url, openHere: host?.isOpenHere(url) ?? false, unsaved: host?.hasUnsavedChanges(url) ?? false)
        }
    }

    /// The project `id` (if known) went from `from` to `to`: shown there at once, and both are looked at.
    private func moved(_ id: PackageIdentity?, from: URL, to: URL) {
        if let id {
            switch location(of: to) {
            case .listed(let place): host?.showMoved(id, to: to, place: place)
            case .elsewhere: host?.showMoved(id, to: to, place: .elsewhere)
            case .notListed: break
            }
        }
        host?.look(at: [from, to])
    }

    /// One of Other places whose action failed is looked at again: it may not be there (design §6.5: "No disponible").
    private func lookAgain(_ summary: ProjectSummary, at url: URL) {
        if summary.place == .elsewhere { host?.look(at: [url]) }
    }

    private func location(of url: URL) -> PackageLocation {
        LibraryScanner.location(of: url, projectsFolder: projectsFolder)
    }

    private static func name(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// What `LibraryOperations` asks of the app from its own threads (design §6.6): from the app's own state, as the runner
/// noted it for each package just before acting on it; never by probing a lock.
final class NotedAppState: LibraryAppState {
    private let isRecordingNow: @Sendable () -> Bool
    private let closeEditor: @MainActor @Sendable (URL) async -> Void
    /// By package path.
    private let noted = Mutex<[String: (openHere: Bool, unsaved: Bool)]>([:])

    init(isRecording: @escaping @Sendable () -> Bool, close: @escaping @MainActor @Sendable (URL) async -> Void) {
        isRecordingNow = isRecording
        closeEditor = close
    }

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
