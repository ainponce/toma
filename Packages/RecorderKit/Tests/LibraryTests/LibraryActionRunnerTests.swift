// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import Library
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

// MARK: - Doubles

/// Whether a take records, as each test sets it; asked from any thread.
private final class Recording: Sendable {
    private let value = Mutex(false)
    var now: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// How many commands are copying now (`copyBegan`, `copyEnded`).
private final class Copies: Sendable {
    private let value = Mutex(0)
    var now: Int { value.withLock { $0 } }
    func add(_ delta: Int) { value.withLock { $0 += delta } }
}

/// The library's window for the runner: what it shows (`summaries`, kept as an action tells it) and what it was asked.
@MainActor private final class FakeHost: LibraryActionHost {
    var summaries: [PackageIdentity: ProjectSummary] = [:]
    var favorites: Set<PackageIdentity> = []
    var places: [OtherPlace] = []
    var open: Set<String> = []
    var looked: [URL] = []
    var opened: [URL] = []
    var recovered: [URL] = []
    var shownInFinder: [URL] = []
    var forgotten: [PackageIdentity] = []
    var selected: (ids: Set<PackageIdentity>, section: LibrarySection)?
    var questions: [LibraryDeletionQuestion] = []
    /// What the alert answers; it may do something meanwhile (the Finder, another command).
    var answer: () async -> Bool = { true }
    /// What `editContext()` gives, once it is made.
    var context: () async -> EditContext? = { nil }
    /// Told after each `showMoved`.
    var afterMove: () -> Void = {}

    func identity(at url: URL) -> PackageIdentity? {
        let path = url.standardizedFileURL.path
        return summaries.first { $0.value.path == path }?.key
    }

    func locate(_ summary: ProjectSummary) async -> URL { URL(filePath: summary.path, directoryHint: .isDirectory) }
    func isOpenHere(_ url: URL) -> Bool { open.contains(url.standardizedFileURL.path) }
    func hasUnsavedChanges(_ url: URL) -> Bool { false }
    func close(_ url: URL) async { open.remove(url.standardizedFileURL.path) }
    func editContext() async -> EditContext? { await context() }

    func showMoved(_ identity: PackageIdentity, to url: URL, place: Place) {
        summaries[identity]?.path = url.standardizedFileURL.path
        summaries[identity]?.name = url.deletingPathExtension().lastPathComponent
        summaries[identity]?.place = place
        afterMove()
    }

    func forget(_ identities: [PackageIdentity]) {
        forgotten += identities
        for identity in identities { summaries[identity] = nil }
    }

    func takeOut(_ identity: PackageIdentity) -> (summary: ProjectSummary, place: OtherPlace)? {
        guard let summary = summaries.removeValue(forKey: identity) else { return nil }
        let place = places.first { $0.path == summary.path } ?? OtherPlace(added: summary.lastSeen, bookmark: Data(), path: summary.path)
        places.removeAll { $0.path == summary.path }
        return (summary, place)
    }

    func putBack(_ summary: ProjectSummary?, place: OtherPlace) {
        if let summary { summaries[summary.identity] = summary }
        places.append(place)
    }

    func setFavorite(_ identities: [PackageIdentity], _ favorite: Bool) {
        for identity in identities {
            if favorite { favorites.insert(identity) } else { favorites.remove(identity) }
        }
    }

    func addPlaces(_ places: [OtherPlace]) { self.places += places }
    func look(at urls: [URL]) { looked += urls }
    func select(_ identities: Set<PackageIdentity>, in section: LibrarySection) { selected = (identities, section) }
    func open(_ url: URL) { opened.append(url) }
    func recover(_ url: URL) { recovered.append(url) }
    func showInFinder(_ urls: [URL]) { shownInFinder += urls }

    func confirmDeletion(_ question: LibraryDeletionQuestion) async -> Bool {
        questions.append(question)
        return await answer()
    }

    /// Shows the package at `url`, in `place`, with its identity from the disk; `size` bytes.
    @discardableResult
    func show(_ url: URL, place: Place, size: Int64? = nil) throws -> PackageIdentity {
        let identity = try PackageIdentity(of: url, in: SystemFileSystem())
        summaries[identity] = ProjectSummary(
            identity: identity, path: url.standardizedFileURL.path, name: url.deletingPathExtension().lastPathComponent,
            place: place, aspect: .landscape, hasCamera: false,
            state: place == .trash ? .inTrash(since: Date(timeIntervalSince1970: 1_794_000_000)) : .normal, size: size,
            lastSeen: Date(timeIntervalSince1970: 1_794_000_000))
        return identity
    }

    func items(_ ids: [PackageIdentity]) -> [LibraryItem] {
        ids.compactMap { id in summaries[id].map { LibraryItem(summary: $0, favorite: favorites.contains(id)) } }
    }
}

/// A projects folder at `<dir>/Projects`, a window and the runner over them.
@MainActor private struct ActionRig {
    let projects: URL
    let records: LibraryRecordsStore
    let host = FakeHost()
    let recording = Recording()
    let runner: LibraryActionRunner
    let copies = Copies()

    var trash: URL { ProjectTrash.folder(in: projects) }

    init(in dir: URL, firstEdit: (@MainActor (URL, Aspect, EditContext) async -> LibraryReason?)? = nil) throws {
        projects = dir.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        records = LibraryRecordsStore(url: dir.appending(path: "library.json", directoryHint: .notDirectory))
        let recording = recording
        let copies = copies
        let words = LibraryActionRunner.Words(copy: "copia", numbered: { "copia \($0)" }) { aspect in
            switch aspect {
            case .landscape: "horizontal"
            case .portrait: "vertical"
            case .square: "cuadrado"
            }
        }
        let macTrash = dir.appending(path: "MacTrash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macTrash, withIntermediateDirectories: true)
        if let firstEdit {
            runner = LibraryActionRunner(
                projectsFolder: projects, fileSystem: SystemFileSystem(), records: records, host: host, words: words,
                isRecording: { recording.now }, copyBegan: { copies.add(1) },
                copyEnded: { copies.add(-1) }, isLockHeld: { _ in false },
                trash: { try FileManager.default.moveItem(at: $0, to: macTrash.appending(path: $0.lastPathComponent)) },
                firstEdit: firstEdit)
        } else {
            runner = LibraryActionRunner(
                projectsFolder: projects, fileSystem: SystemFileSystem(), records: records, host: host, words: words,
                isRecording: { recording.now }, copyBegan: { copies.add(1) },
                copyEnded: { copies.add(-1) }, isLockHeld: { _ in false },
                trash: { try FileManager.default.moveItem(at: $0, to: macTrash.appending(path: $0.lastPathComponent)) })
        }
        runner.noticeDuration = .seconds(60)
    }

    /// A package named `name` in `folder` (by default the projects folder), shown.
    @discardableResult
    func project(_ name: String, in folder: URL? = nil, place: Place = .projectsFolder(subfolder: ""), size: Int64? = nil) throws
        -> PackageIdentity
    {
        let folder = folder ?? projects
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = try ProjectPackage.create(in: folder, name: name, app: AppInfo(name: "Tests", version: "0"), now: Date())
        return try host.show(package.url, place: place, size: size)
    }

    func run(_ command: LibraryCommand, on ids: [PackageIdentity] = []) async {
        await runner.perform(command, on: host.items(ids))?.value
    }

    func path(_ id: PackageIdentity) -> String? { host.summaries[id]?.path }

    func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
}

private func context(_ dir: URL) -> EditContext {
    EditContext(
        app: AppInfo(name: "Toma", version: "0.3.0"), cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory),
        defaultStyle: .toma, now: { Date(timeIntervalSince1970: 1_794_800_000) }, makeID: { $0 + "00000001" })
}

// MARK: - Tests

@MainActor @Suite struct LibraryActionRunnerTests {
    /// A command on several projects is one step, its cards busy while it lasts; the trash notice undoes it whole, and
    /// so does ⌘Z; ⇧⌘Z does it again.
    @Test func trashingSeveralIsOneStepUndoneWhole() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A"), b = try library.project("B")
            let task = library.runner.perform(.moveToTrash, on: library.host.items([a, b]))
            #expect(library.runner.busy[a] != nil && library.runner.busy[b] != nil, "busy as soon as it is asked")
            #expect(library.runner.perform(.moveToTrash, on: library.host.items([a])) == nil, "it does not start again")
            await task?.value
            #expect(library.names(in: library.trash) == ["A.toma", "B.toma"])
            #expect(library.host.summaries[a]?.place == .trash && library.runner.busy.isEmpty)
            #expect(library.runner.trashNotice?.names == ["A", "B"])
            #expect(library.runner.canUndo)

            await library.runner.undoTrashNotice()?.value
            #expect(library.names(in: library.projects) == ["A.toma", "B.toma", "Trash"])
            #expect(library.runner.trashNotice == nil && library.runner.canRedo)
            #expect(library.host.summaries[a]?.place == .projectsFolder(subfolder: ""))

            await library.run(.redo)
            #expect(library.names(in: library.trash) == ["A.toma", "B.toma"])
            await library.run(.undo)
            #expect(library.names(in: library.trash).isEmpty)
            #expect(library.runner.messages.isEmpty)
            await library.records.flush()
        }
    }

    /// In the trash a project may have had to take «nombre 2»: undoing gives it back its own name where it was.
    @Test func undoingATrashGivesTheNameBack() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            try library.project("Demo", in: library.trash, place: .trash)
            let demo = try library.project("Demo")
            await library.run(.moveToTrash, on: [demo])
            #expect(library.names(in: library.trash) == ["Demo 2.toma", "Demo.toma"])
            await library.run(.undo)
            #expect(library.names(in: library.projects).contains("Demo.toma"))
            #expect(library.path(demo)?.hasSuffix("/Projects/Demo.toma") == true)
            await library.records.flush()
        }
    }

    /// ⌘Z during "Vaciar la papelera…" (I2): undo waits while a deletion is asked or under way, and never runs over a busy
    /// card; only the projects actually deleted leave the library, so one restored meanwhile (in the Finder, while the
    /// alert asked) is never forgotten.
    @Test func undoDuringEmptyingNeverForgetsARestoredProject() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A", size: 1_000), b = try library.project("B", size: 2_000)
            await library.run(.moveToTrash, on: [a, b])
            let host = library.host, runner = library.runner, projects = library.projects
            var undoWhileAsked: Task<Void, Never>?
            host.answer = {
                undoWhileAsked = runner.perform(.undo, on: [])
                // The Finder takes A out of the trash while the alert is up.
                try? FileManager.default.moveItem(
                    at: ProjectTrash.folder(in: projects).appending(path: "A.toma"), to: projects.appending(path: "A.toma"))
                return true
            }
            let emptying = runner.perform(.emptyTrash, on: host.items([a, b]))
            #expect(!runner.canUndo, "no undo while a deletion is asked")
            #expect(runner.perform(.undo, on: []) == nil)
            #expect(runner.perform(.restore, on: host.items([a])) == nil, "a busy card")
            await emptying?.value
            #expect(undoWhileAsked == nil)
            #expect(host.questions == [LibraryDeletionQuestion(count: 2, bytes: 3_000)])
            #expect(host.forgotten == [b], "A was restored meanwhile: its card stays")
            #expect(host.summaries[a] != nil)
            #expect(library.names(in: library.trash).isEmpty && library.names(in: projects) == ["A.toma", "Trash"])
            #expect(runner.canUndo && runner.busy.isEmpty)
            await library.records.flush()
        }
    }

    /// Undo and redo mark their cards busy, and an action asked on one of them meanwhile does not start; nor does an
    /// undo whose card is busy with another action.
    @Test func undoAndRedoMarkTheirCards() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A"), b = try library.project("B")
            await library.run(.rename("A2"), on: [a])
            let undo = library.runner.perform(.undo, on: [])
            #expect(library.runner.busy[a] != nil)
            #expect(library.runner.perform(.moveToTrash, on: library.host.items([a])) == nil)
            #expect(library.runner.perform(.showInFinder, on: library.host.items([a])) != nil, "what does not move it still works")
            await undo?.value
            #expect(library.path(a)?.hasSuffix("/A.toma") == true && library.runner.busy.isEmpty)

            // B busy with a rename of its own: redoing A's step is not refused, B's own step waits.
            await library.run(.rename("B2"), on: [b])
            await library.run(.undo)
            let renaming = library.runner.perform(.rename("B3"), on: library.host.items([b]))
            #expect(library.runner.perform(.redo, on: []) == nil, "its card is busy")
            await renaming?.value
            #expect(library.runner.canUndo)
            await library.records.flush()
        }
    }

    /// A take that starts in the middle of an undo stops it: what it reached is undone, the rest stays in the history
    /// as it was, to undo once the take ends (M8).
    @Test func aTakeStartingMidUndoKeepsTheRest() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A"), b = try library.project("B")
            await library.run(.moveToTrash, on: [a, b])
            let recording = library.recording
            library.host.afterMove = { recording.now = true }  // after the first project is back
            await library.run(.undo)
            #expect(library.runner.messages == [.recording])
            #expect(library.host.summaries[b]?.place == .projectsFolder(subfolder: ""), "the last done, undone first")
            #expect(library.host.summaries[a]?.place == .trash)

            library.host.afterMove = {}
            await library.run(.undo)
            #expect(library.host.summaries[a]?.place == .trash, "not while recording")
            recording.now = false
            await library.run(.undo)
            #expect(library.host.summaries[a]?.place == .projectsFolder(subfolder: ""))
            // Done again, in the order they were done.
            await library.run(.redo)
            #expect(library.host.summaries[a]?.place == .trash && library.host.summaries[b]?.place == .projectsFolder(subfolder: ""))
            await library.run(.redo)
            #expect(library.host.summaries[b]?.place == .trash)
            await library.records.flush()
        }
    }

    /// ⌘D on several projects is one step (M7), counted as copying while it lasts.
    @Test func duplicatingSeveralIsOneStep() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A"), b = try library.project("B")
            let task = library.runner.perform(.duplicate, on: library.host.items([a, b]))
            #expect(library.copies.now == 1)
            await task?.value
            #expect(library.copies.now == 0)
            #expect(library.names(in: library.projects) == ["A copia.toma", "A.toma", "B copia.toma", "B.toma"])
            // The copies are shown by the scanner: the window shows them as it would.
            for name in ["A copia", "B copia"] { try library.host.show(library.projects.appending(path: "\(name).toma"), place: .projectsFolder(subfolder: "")) }
            await library.run(.undo)
            #expect(library.names(in: library.trash) == ["A copia.toma", "B copia.toma"])
            await library.records.flush()
        }
    }

    /// "Duplicar como" (I3, M9): it waits for the edit context, writes the format as the copy's first edit, then opens
    /// the copy; the original does not change, and undoing it works on the copy untouched since.
    @Test func duplicateAsWritesTheFormatThenOpens() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let original = try #require(try await LibraryFixtures.folder(in: library.projects, kinds: [.v2]).first)
            let id = try library.host.show(original, place: .projectsFolder(subfolder: ""))
            let made = context(dir)
            var given = false
            library.host.context = {
                // Made a moment later.
                try? await Task.sleep(for: .milliseconds(50))
                given = true
                return made
            }
            await library.run(.duplicateAs(.portrait), on: [id])
            #expect(given)
            let copy = library.projects.appending(path: "v2 vertical.toma", directoryHint: .isDirectory)
            #expect(library.host.opened.map(\.lastPathComponent) == ["v2 vertical.toma"])
            #expect(library.runner.messages.isEmpty)
            #expect(try EditSession.readDocument(copy, take: nil, context: made).1.aspect == .portrait)
            #expect(try EditSession.readDocument(original, take: nil, context: made).1.aspect == .landscape)

            try library.host.show(copy, place: .projectsFolder(subfolder: ""))
            await library.run(.undo)
            #expect(library.runner.messages.isEmpty, "the copy is as its first edit left it")
            #expect(library.names(in: library.trash) == ["v2 vertical.toma"])
            await library.records.flush()
        }
    }

    /// "Duplicar como" that cannot change the format says so; the copy stays, under its name, and does not open as if it
    /// were in the new format (I3).
    @Test func duplicateAsThatCannotChangeTheFormatSaysSo() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir) { _, _, _ in .copyCannotBeEdited }
            let original = try #require(try await LibraryFixtures.folder(in: library.projects, kinds: [.v2]).first)
            let id = try library.host.show(original, place: .projectsFolder(subfolder: ""))
            let made = context(dir)
            library.host.context = { made }
            await library.run(.duplicateAs(.square), on: [id])
            #expect(library.runner.messages == [.couldNot(.changeFormat, name: "v2 cuadrado", .copyCannotBeEdited)])
            #expect(library.host.opened.isEmpty)
            #expect(library.names(in: library.projects).contains("v2 cuadrado.toma"))

            // Without an edit context (the window closed): said too.
            let other = try ActionRig(in: dir.appending(path: "Other", directoryHint: .isDirectory))
            let second = try #require(try await LibraryFixtures.folder(in: other.projects, kinds: [.v2]).first)
            let secondID = try other.host.show(second, place: .projectsFolder(subfolder: ""))
            await other.run(.duplicateAs(.portrait), on: [secondID])
            #expect(other.runner.messages == [.couldNot(.changeFormat, name: "v2 vertical", .copyCannotBeOpened)])
            #expect(other.host.opened.isEmpty)
            await library.records.flush()
            await other.records.flush()
        }
    }

    /// Every failure of a command is told, each once (M6); the text of Other places only for one of them (M5).
    @Test func everyFailureOfACommandIsTold() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let outside = dir.appending(path: "Desktop", directoryHint: .isDirectory)
            let x = try library.project("X", in: outside, place: .elsewhere)
            let y = try library.project("Y", in: outside, place: .elsewhere)
            // Shown in the projects folder, but already in its trash on disk (the Finder put it there).
            let z = try library.project("Z", in: library.trash, place: .projectsFolder(subfolder: ""))
            await library.run(.moveToTrash, on: [x, y, z])
            #expect(
                library.runner.messages == [
                    .outsideTomasFolder(name: "X"), .outsideTomasFolder(name: "Y"), .couldNot(.moveToTrash, name: "Z", .notThere),
                ])
            #expect(library.runner.trashNotice == nil && !library.runner.canUndo)

            library.recording.now = true
            let a = try library.project("A"), b = try library.project("B")
            await library.run(.rename("C"), on: [a])
            await library.run(.moveToTrash, on: [a, b])
            #expect(library.runner.messages == [.recording], "the same failure, once")
            await library.records.flush()
        }
    }

    /// Dropped packages (M3): those the walk lists are shown in their own section, the trash's in the trash; those it
    /// never lists say why; only folders named `.toma` count, never a file or a link; the others go to Other places.
    @Test func droppedPackagesGoWhereTheyBelong() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let inTrash = try library.project("T", in: library.trash, place: .trash)
            await library.run(.addProjects([library.trash.appending(path: "T.toma", directoryHint: .isDirectory)]))
            #expect(library.host.selected?.ids == [inTrash] && library.host.selected?.section == .trash)
            let here = try library.project("H")
            await library.run(.addProjects([library.projects.appending(path: "H.toma", directoryHint: .isDirectory)]))
            #expect(library.host.selected?.ids == [here] && library.host.selected?.section == .all)

            let deep = library.projects.appending(path: "a/b/c/d/e", directoryHint: .isDirectory)
            try library.project("Deep", in: deep)
            let outside = dir.appending(path: "Desktop", directoryHint: .isDirectory)
            try library.project("Out", in: outside, place: .elsewhere)
            let file = outside.appending(path: "File.toma", directoryHint: .notDirectory)
            try Data("x".utf8).write(to: file)
            let link = outside.appending(path: "Link.toma", directoryHint: .notDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appending(path: "Out.toma"))
            library.host.places = []
            await library.run(
                .addProjects([
                    deep.appending(path: "Deep.toma", directoryHint: .isDirectory), outside.appending(path: "Out.toma", directoryHint: .isDirectory),
                    file, link, outside.appending(path: "notes.txt"),
                ]))
            #expect(library.runner.messages == [.notListed(name: "Deep", .tooDeep)])
            #expect(library.host.places.map { URL(filePath: $0.path).lastPathComponent } == ["Out.toma"])
            #expect(library.host.places.allSatisfy { !$0.bookmark.isEmpty })
            await library.records.flush()
        }
    }

    /// Favorites, Other places taken out of the library and put back, and the Finder: no file is touched.
    @Test func favoritesAndOtherPlacesUndo() async throws {
        try await withTemporaryDirectory { dir in
            let library = try ActionRig(in: dir)
            let a = try library.project("A"), b = try library.project("B")
            await library.run(.toggleFavorite, on: [a, b])
            #expect(library.host.favorites == [a, b])
            await library.run(.toggleFavorite, on: [a, b])
            #expect(library.host.favorites.isEmpty)
            await library.run(.undo)
            #expect(library.host.favorites == [a, b])

            let outside = dir.appending(path: "Desktop", directoryHint: .isDirectory)
            let x = try library.project("X", in: outside, place: .elsewhere)
            library.host.places = [OtherPlace(added: Date(), bookmark: Data([1]), path: try #require(library.path(x)))]
            await library.run(.removeFromLibrary, on: [x, a])
            #expect(library.host.summaries[x] == nil && library.host.places.isEmpty && library.host.summaries[a] != nil)
            await library.run(.undo)
            #expect(library.host.summaries[x] != nil && library.host.places.count == 1)
            await library.run(.showInFinder, on: [x, a])
            #expect(library.host.shownInFinder.count == 2)
            #expect(library.host.looked.contains { $0.lastPathComponent == "X.toma" }, "one of Other places is looked at again")
            await library.records.flush()
        }
    }
}
