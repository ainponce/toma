// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Foundation
import Library
import ProjectFormat
import SwiftUI

extension LibraryModel {
    /// Every action of the library goes through here (design §6.3), on the cards `ids`: none once a quit began
    /// (`LibraryWork`). Which cards each reaches, and in which order its steps go, is `LibraryActionRunner`'s.
    func perform(_ command: LibraryCommand, on ids: Set<Library.PackageIdentity> = []) {
        guard !LibraryWork.shared.isStopped else { return }
        actions.perform(command, on: ids)
    }
}

/// The library's actions in the window (design §6.3–§6.5): the name being edited, the alerts, and what only the app does
/// for `LibraryActionRunner` (Library), which carries out each command, its undo and its messages; and the words of all
/// of it (design §12).
@MainActor @Observable
final class LibraryActions: LibraryActionHost {
    /// The card whose name is being edited.
    private(set) var renaming: Library.PackageIdentity?
    /// Made once the records are read.
    private(set) var runner: LibraryActionRunner?

    @ObservationIgnored weak var model: LibraryModel?
    /// The library's window, for the alerts.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var pendingRename: Task<Void, Never>?

    /// The cards an action works on.
    var busy: [Library.PackageIdentity: LibraryActionRunner.Work] { runner?.busy ?? [:] }
    /// Deleting for good: "Vaciando… 3 de 12".
    var emptying: LibraryActionRunner.Emptying? { runner?.emptying }
    var canUndo: Bool { runner?.canUndo ?? false }
    var canRedo: Bool { runner?.canRedo ?? false }

    /// The strip: what the last command that failed could not do, the first failure and how many more.
    var failure: String? {
        guard let messages = runner?.messages, let first = messages.first else { return nil }
        let text = Self.text(first)
        guard messages.count > 1 else { return text }
        let more = messages.count - 1
        return String(localized: "\(text) (and \(more) more)", comment: "The library's strip: the first failure, and how many more")
    }

    /// "«Demo» se movió a la papelera. · Deshacer".
    var trashNotice: String? {
        guard let notice = runner?.trashNotice, let first = notice.names.first else { return nil }
        let count = notice.names.count
        return count == 1
            ? String(localized: "“\(first)” moved to the trash.", comment: "The library: the notice after a project went to the trash")
            : String(localized: "\(count) projects moved to the trash.", comment: "The library: the notice after several projects went to the trash")
    }

    /// Whether the trash notice's Deshacer still undoes it.
    var trashNoticeUndoes: Bool { runner?.trashNotice?.undoes != nil }

    /// What the disk said of the name asked for the card `id`.
    func renameProblem(for id: Library.PackageIdentity) -> NameProblem? {
        guard let refusal = runner?.nameRefusal, refusal.identity == id else { return nil }
        return refusal.problem
    }

    /// Once the records are read: the runner, and what a crash left half deleted is finished (decision 33).
    func start(records: LibraryRecordsStore) {
        guard runner == nil, let model else { return }
        let runner = LibraryActionRunner(
            projectsFolder: model.paths.projectsFolder, fileSystem: SystemFileSystem(), records: records, host: self,
            words: Self.words, isRecording: model.recordingProbe, copyBegan: { LibraryWork.shared.beginCopy() },
            copyEnded: { LibraryWork.shared.endCopy() })
        self.runner = runner
        Task { await runner.finishPendingDeletions() }
    }

    /// `LibraryModel.perform(_:on:)`: Abrir and Renombrar are the window's; the rest the runner's, on the cards shown
    /// (Vaciar la papelera…, every project of the trash).
    fileprivate func perform(_ command: LibraryCommand, on ids: Set<Library.PackageIdentity>) {
        guard let model else { return }
        let items = model.shown.filter { ids.contains($0.summary.identity) }
        switch command {
        case .open:
            model.open(Set(items.map(\.summary.identity)))
        case .startRenaming:
            guard items.count == 1, let item = items.first,
                LibraryActionRules.reaches(.startRenaming, item, busy: busy[item.summary.identity] != nil)
            else { return }
            pendingRename?.cancel()
            runner?.forgetNameRefusal()
            renaming = item.summary.identity
        case .rename:
            guard let runner, let id = items.first?.summary.identity, let task = runner.perform(command, on: items) else { return }
            Task {
                await task.value
                // The field stays while the disk refused the name: the problem is beside it.
                if renaming == id, runner.nameRefusal?.identity != id { endRenaming() }
            }
        case .emptyTrash:
            runner?.perform(command, on: model.trashedItems)
        default:
            runner?.perform(command, on: items)
        }
    }

    func dismissFailure() {
        runner?.dismissMessages()
    }

    func undoTrashNotice() {
        guard !LibraryWork.shared.isStopped else { return }
        runner?.undoTrashNotice()
    }

    func dismissTrashNotice() {
        runner?.dismissTrashNotice()
    }

    // MARK: - Renaming

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
        runner?.forgetNameRefusal()
    }

    /// The name in the field changed: what the disk said of the last one no longer holds.
    func nameEdited() {
        runner?.forgetNameRefusal()
    }

    // MARK: - LibraryActionHost

    func identity(at url: URL) -> Library.PackageIdentity? { model?.identity(at: url) }

    func locate(_ summary: ProjectSummary) async -> URL {
        await model?.locate(summary) ?? URL(filePath: summary.path, directoryHint: .isDirectory)
    }

    /// An editor of this app holds the package's `edit.lock`: one open read-only because another app has it does not, so
    /// the lock is asked about before a rename (design §6.6).
    func isOpenHere(_ url: URL) -> Bool {
        guard let model else { return false }
        return model.isOpenHere(url) && !model.isOpenElsewhere(url)
    }

    func isRenaming(_ identity: Library.PackageIdentity) -> Bool { renaming == identity }
    func hasUnsavedChanges(_ url: URL) -> Bool { model?.host.hasUnsavedChanges(url) ?? false }
    func close(_ url: URL) async { await model?.host.close(url) }
    func editContext() async -> EditContext? { await model?.madeContext() }

    /// The cards settle with `Motion.trackItem`; one that leaves the section shrinks to 90 % and fades (design §9). The app
    /// is told: an editor may have it open.
    func showMoved(_ identity: Library.PackageIdentity, to url: URL, place: Place) {
        withAnimation(Self.settling) { model?.showMoved(identity, to: url, place: place) }
        model?.host.moved()
    }

    func forget(_ identities: [Library.PackageIdentity]) {
        withAnimation(Self.settling) { model?.forget(identities) }
    }

    func takeOut(_ identity: Library.PackageIdentity) -> (summary: ProjectSummary, place: OtherPlace)? {
        withAnimation(Self.settling) { model?.takeOut(identity) }
    }

    func putBack(_ summary: ProjectSummary?, place: OtherPlace) {
        withAnimation(Self.settling) { model?.putBack(summary, place: place) }
    }

    func setFavorite(_ identities: [Library.PackageIdentity], _ favorite: Bool) {
        let keys = identities.map(\.string)
        withAnimation(Self.settling) {
            model?.changeRecords { records in
                for key in keys {
                    if favorite { records.favorites.insert(key) } else { records.favorites.remove(key) }
                }
            }
        }
    }

    func addPlaces(_ places: [OtherPlace]) {
        model?.changeRecords { records in
            for place in places where !records.places.contains(where: { $0.path == place.path }) { records.places.append(place) }
        }
    }

    func look(at urls: [URL]) { model?.look(at: urls) }

    /// The section changes only if the one shown does not show them all (N3: a package dropped while it is in Favorites
    /// stays there).
    func select(_ identities: Set<Library.PackageIdentity>, in section: LibrarySection) {
        guard let model else { return }
        let shown = Set(model.shown.map(\.summary.identity))
        if model.section != section, !identities.isSubset(of: shown) { model.section = section }
        model.select(identities)
    }

    func open(_ url: URL) { model?.host.open(url) }
    func recover(_ url: URL) { model?.host.recover(url) }
    func showInFinder(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    /// "¿Eliminar «Demo» para siempre?" or "¿Eliminar para siempre 12 proyectos (8,4 GB)?", "No se puede deshacer.",
    /// with Cancelar first: the default, with ↩ (design §6.4).
    func confirmDeletion(_ question: LibraryDeletionQuestion) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let name = question.name {
            alert.messageText = String(localized: "Delete “\(name)” forever?", comment: "The library: the alert before deleting a project of the trash")
        } else {
            let size = question.bytes.formatted(.byteCount(style: .file))
            alert.messageText = String(
                localized: "Delete \(question.count) projects forever (\(size))?",
                comment: "The library: the alert before deleting projects of the trash")
        }
        alert.informativeText = String(localized: "This can't be undone.", comment: "The library: deleting for good")
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        let delete = alert.addButton(withTitle: Self.deleteTitle)
        cancel.keyEquivalent = "\r"
        delete.keyEquivalent = ""
        delete.hasDestructiveAction = true
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    /// The cards settling (design §9), or a fade with Reduce motion.
    private static var settling: Animation {
        .panel(Motion.trackItem, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

// MARK: - Words

extension LibraryActions {
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
        case .restore: String(localized: "Restore", comment: "The library: a project of the trash goes back")
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

    static var undoTitle: String {
        String(localized: "Undo", comment: "The library: undo the last action, and the trash notice's button")
    }

    static var deleteTitle: String {
        String(localized: "Delete Permanently", comment: "The library: the alert's button that deletes for good")
    }

    /// The words of the names of copies (design §12): «Demo copia», «Demo copia 2», «Demo vertical».
    static var words: LibraryActionRunner.Words {
        LibraryActionRunner.Words(
            copy: String(localized: "copy", comment: "The library: what follows a project's name in its copy's name («Demo copia»)"),
            numbered: { number in
                String(
                    localized: "copy \(number)",
                    comment: "The library: what follows a project's name in its copy's name, when that is taken («Demo copia 2»)")
            },
            suffix: { aspect in
                switch aspect {
                case .landscape:
                    String(localized: "landscape", comment: "The library: what follows a project's name in a 16:9 copy's name («Demo horizontal»)")
                case .portrait:
                    String(localized: "portrait", comment: "The library: what follows a project's name in a 9:16 copy's name («Demo vertical»)")
                case .square:
                    String(localized: "square", comment: "The library: what follows a project's name in a 1:1 copy's name («Demo cuadrado»)")
                }
            })
    }

    /// What `message` says (design §10, §12).
    static func text(_ message: LibraryMessage) -> String {
        switch message {
        case .recording:
            return String(localized: "It's recording.", comment: "The library: a project being recorded does not open")
        case .openElsewhere:
            return String(localized: "Can't: it's open in another app.", comment: "The library: an action on a project another app has open")
        case .copyOpenedOrChanged:
            return String(localized: "Can't undo: the copy was opened or changed since it was made.", comment: "The library: undoing a duplicate")
        case .noRoom(let needed):
            let size = needed.formatted(.byteCount(style: .file))
            return String(localized: "There's no room to duplicate it: \(size) are needed.", comment: "The library: a duplicate on a full disk")
        case .notDeleted(let count):
            return String(localized: "\(count) projects couldn't be deleted: they're still in the trash.", comment: "The library: deleting for good failed")
        case .outsideTomasFolder(let name):
            return String(
                localized: "“\(name)” is outside Toma's folder: removing it from the library leaves the file where it is.",
                comment: "The library: a project of Other places is not moved to the trash")
        case .couldNot(let doing, let name, let reason):
            return couldNot(doing, name, reasonText(reason))
        case .notListed(let name, let why):
            return notListed(name, why)
        }
    }

    private static func couldNot(_ doing: LibraryDoing, _ name: String, _ reason: String) -> String {
        switch doing {
        case .rename: String(localized: "Couldn't rename “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .duplicate: String(localized: "Couldn't duplicate “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .moveToTrash:
            String(localized: "Couldn't move “\(name)” to the trash: \(reason)", comment: "The library: the strip; the project's name and why")
        case .restore: String(localized: "Couldn't restore “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .delete: String(localized: "Couldn't delete “\(name)”: \(reason)", comment: "The library: the strip; the project's name and why")
        case .changeFormat:
            String(
                localized: "Couldn't change the format of “\(name)”: \(reason)",
                comment: "The library: the strip after Duplicate As; the copy's name and why its format stayed")
        }
    }

    private static func notListed(_ name: String, _ why: NotListed) -> String {
        switch why {
        case .tooDeep:
            String(
                localized: "“\(name)” is more than four folders inside the projects folder: the library doesn't show it.",
                comment: "The library: a package dropped on it that it does not list")
        case .hidden:
            String(localized: "“\(name)” is in a hidden folder: the library doesn't show it.", comment: "The library: a package dropped on it that it does not list")
        case .inTrashFolder:
            String(
                localized: "“\(name)” is in a folder inside the trash: the library doesn't show it.",
                comment: "The library: a package dropped on it that it does not list")
        case .insidePackage:
            String(
                localized: "“\(name)” is inside another project: the library doesn't show it.", comment: "The library: a package dropped on it that it does not list")
        }
    }

    /// Why, after "No se pudo …:".
    private static func reasonText(_ reason: LibraryReason) -> String {
        switch reason {
        case .noLongerInTrash: String(localized: "it's no longer in the trash", comment: "The library: why an action failed")
        case .notThere: String(localized: "it isn't there", comment: "The library: why a part of a project can't be read")
        case .unsavedChanges: String(localized: "its editor has changes that couldn't be saved", comment: "The library: why an action failed")
        case .nameTaken: String(localized: "a project with that name already exists", comment: "The library: why an action failed")
        case .nameTooLong: String(localized: "the name is too long", comment: "The library: why an action failed")
        case .nameUnusable: String(localized: "the name can't be used", comment: "The library: why an action failed")
        case .noPermission: String(localized: "there's no permission", comment: "The library: why a part of a project can't be read")
        case .diskFull: String(localized: "the disk is full", comment: "The library: why an action failed")
        case .readOnly: String(localized: "the disk is read-only", comment: "The library: why an action failed")
        case .diskFailed: String(localized: "the disk failed", comment: "The library: why a part of a project can't be read")
        case .diskDidNotAnswer: String(localized: "the disk didn't answer", comment: "The library: why a part of a project can't be read")
        case .link: String(localized: "it's a link", comment: "The library: why a part of a project can't be read")
        case .copyCannotBeOpened: String(localized: "the copy can't be opened", comment: "The library: why Duplicate As kept the format")
        case .copyCannotBeEdited: String(localized: "the copy can't be edited", comment: "The library: why Duplicate As kept the format")
        case .editNotSaved: String(localized: "the change couldn't be saved", comment: "The library: why Duplicate As kept the format")
        case .other: String(localized: "the disk didn't allow it", comment: "The library: why an action failed")
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

    /// The URLs dropped on the window, read from `providers`, then `then`.
    static func loadDropped(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
        let loads = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loads.isEmpty else { return }
        let found = DroppedURLs()
        let group = DispatchGroup()
        for provider in loads {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = found.urls
            MainActor.assumeIsolated { then(urls) }
        }
    }
}

/// The URLs a drop's providers gave, from their own threads.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [URL] = []

    func add(_ url: URL) {
        lock.withLock { found.append(url) }
    }

    var urls: [URL] { lock.withLock { found } }
}

// MARK: - Views

/// The menu of `ids` (design §6.3): the context menu of a card or of the list's rows.
struct LibraryMenu: View {
    let model: LibraryModel
    let ids: Set<Library.PackageIdentity>

    var body: some View {
        let items = model.shown.filter { ids.contains($0.summary.identity) }
        ForEach(Array(LibraryActionRules.entries(for: items).enumerated()), id: \.offset) { _, entry in
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
        if let problem = model.actions.renameProblem(for: item.summary.identity) { return problem }
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
