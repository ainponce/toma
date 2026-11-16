// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import CoreGraphics
import Editing
import Foundation
import Library
import Observation
import ProjectFormat
import Synchronization
import os

/// The library's row: SwiftUI's developer tools have a `LibraryItem` of their own.
typealias LibraryItem = Library.LibraryItem

/// Where the library keeps what it knows (design §13.4), and the folder it looks at.
struct LibraryPaths: Sendable {
    var projectsFolder: URL
    /// The cached index.
    var index: URL
    /// `library.json`.
    var records: URL
    /// The thumbnails' cache.
    var thumbnails: URL

    /// The app's: `projectsFolder`, and the index, the records and the thumbnails where design §13.4 puts them.
    static func standard(projectsFolder: URL) -> LibraryPaths {
        LibraryPaths(
            projectsFolder: projectsFolder, index: LibraryIndex.defaultURL, records: LibraryRecords.defaultURL,
            thumbnails: LibraryThumbnails.defaultDirectory)
    }

    #if DEBUG
    /// `-TomaLibraryBench <folder>`'s: the folder, with its index in `index.json` (as `reconcileAndIndexAThousand` leaves
    /// it) and the records and thumbnails in its hidden `.bench`, which the library never lists. Nothing of the user's.
    static func bench(folder: URL) -> LibraryPaths {
        let own = folder.appending(path: ".bench", directoryHint: .isDirectory)
        return LibraryPaths(
            projectsFolder: folder, index: folder.appending(path: "index.json", directoryHint: .notDirectory),
            records: own.appending(path: "library.json", directoryHint: .notDirectory),
            thumbnails: own.appending(path: "thumbnails", directoryHint: .isDirectory))
    }
    #endif
}

/// What the library asks of the app around it, on the main thread. The app tells it what it knows of its own state
/// (`setTake`, `setOpenEditors`, `setOpenElsewhere`, `look(at:)`): the library never probes a lock (design §6.6).
@MainActor
struct LibraryHost {
    /// Opens the editor of the package at the URL, or brings its window forward (1b).
    var open: (URL) -> Void = { _ in }
    /// Opens the island's panel, to record (the empty library's Record).
    var record: () -> Void = {}
    /// The shortcut that opens the island, as the empty library names it: the user's.
    var recordShortcut: () -> String = { HotKeyBindings.defaults.combos[.islandOrStop]?.displayString ?? "" }
}

/// A section of the grid: a date group when it is sorted by date, otherwise all the cards with no heading.
struct LibraryShownGroup: Identifiable, Equatable {
    let id: String
    /// The heading; `nil` for the one section of a grid not sorted by date.
    let title: String?
    let items: [LibraryItem]
}

/// A strip above the library's content (design §10).
enum LibraryBanner: Equatable {
    /// "No se puede leer la carpeta de proyectos.", with Show in Finder and Try Again.
    case projectsFolderUnreadable
    /// "Se está grabando.": the project asked to open is the one being recorded. It goes by itself.
    case recording
}

/// The free space of the projects folder's disk, for the sidebar's footer.
struct LibraryFreeSpace: Equatable {
    var bytes: Int64
    var volumeName: String
}

/// The thumbnail of one card: each card follows its own, so a thumbnail that arrives redraws only its card.
@MainActor @Observable
final class LibraryThumbnail {
    fileprivate(set) var image: CGImage?
    /// Goes up by one each time the image changes, for its fade.
    fileprivate(set) var version = 0
}

/// The library window's model (design §6): it reads the cached index off the main thread and shows it at once, then
/// keeps it in step with the disk through `LibraryScanner` and `LibraryWatcher` (their updates gathered and applied on
/// the main thread at most every `drainDelay`); it draws the thumbnails of the cards on the screen, two at a time and
/// with a low priority; it writes the index and the records with their `DebouncedWriter`s. Nothing here touches the disk
/// on the main thread.
@MainActor @Observable
final class LibraryModel {
    // MARK: What the user chose

    var section: LibrarySection {
        didSet { if section != oldValue { choicesChanged() } }
    }
    var sort: LibrarySort {
        didSet { if sort != oldValue { choicesChanged() } }
    }
    var ascending: Bool {
        didSet { if ascending != oldValue { choicesChanged() } }
    }
    var asList: Bool {
        didSet { if asList != oldValue { choicesChanged() } }
    }
    var search = "" {
        didSet { if search != oldValue { refresh() } }
    }
    private(set) var selection = LibrarySelection<PackageIdentity>()

    // MARK: What it shows

    /// The items of the section that match the search, in order.
    private(set) var shown: [LibraryItem] = []
    /// `shown` in the grid's sections.
    private(set) var groups: [LibraryShownGroup] = []
    private(set) var counts: [LibrarySection: Int] = [:]
    /// The cached index was read and is shown: until then the window shows nothing rather than an empty library.
    private(set) var hasLoaded = false
    /// There was no index, and the first walk is still finding projects: "Buscando proyectos… N".
    private(set) var isLookingForProjects = false
    private(set) var projectsFound = 0
    /// The disks that are slow to answer, by name, in the order they started to be.
    private(set) var waitingFor: [String] = []
    /// The strip shown now: a notice while it lasts, otherwise the projects folder that cannot be read.
    var banner: LibraryBanner? {
        notice ?? (isFolderUnreadable ? .projectsFolderUnreadable : nil)
    }
    /// The projects folder cannot be read, as the last walk or look found.
    private(set) var isFolderUnreadable = false
    /// A notice that goes by itself ("Se está grabando.").
    private(set) var notice: LibraryBanner?
    private(set) var freeSpace: LibraryFreeSpace?
    /// What the projects of the trash take, as far as their sizes are summed.
    private(set) var trashBytes: Int64 = 0
    /// The projects folder is on the network or in a synced location: no thumbnails there.
    private(set) var thumbnailsAreOffHere = false

    // MARK: -

    let paths: LibraryPaths
    @ObservationIgnored let host: LibraryHost
    @ObservationIgnored private let savePreferences: (LibraryPreferences) -> Void
    /// How many columns the grid has now, for the arrows; the grid sets it.
    @ObservationIgnored var columns = 1

    /// What is known of each project, by identity.
    @ObservationIgnored private var summaries: [PackageIdentity: ProjectSummary] = [:]
    @ObservationIgnored private var records = LibraryRecords()
    @ObservationIgnored private var recordsStore: LibraryRecordsStore?
    @ObservationIgnored private var scanner: LibraryScanner?
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var thumbnails: LibraryThumbnails?
    @ObservationIgnored private var context: EditContext?
    /// The projects folder's volume, once found; `nil` while it is not there.
    @ObservationIgnored private var projectsVolume: VolumeInfo?
    /// The projects folder's volume was looked for: until then no thumbnail is looked for, since where it may come from
    /// depends on it.
    @ObservationIgnored private var volumeWasLookedFor = false
    @ObservationIgnored private let fileSystem = SystemFileSystem()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    /// A `.projectsFolderUnreadable` came since the last `reconcile` began.
    @ObservationIgnored private var unreadableThisWalk = false
    /// The walk of `reconcile` ended.
    @ObservationIgnored private(set) var walkFinished = false

    /// What the app said of its own state (design §6.6), by package path.
    @ObservationIgnored private var recordingPath: String?
    @ObservationIgnored private var openHerePaths: Set<String> = []
    @ObservationIgnored private var openElsewherePaths: Set<String> = []
    /// What the scanner, the watcher and the thumbnails share with the model from their own threads.
    @ObservationIgnored private let shared = Shared()

    private final class Shared: Sendable {
        /// Whether a take records, and into which package.
        let take = Mutex<(isRecording: Bool, package: URL?)>((false, nil))
        /// The scanner's updates, until the main thread takes them.
        let inbox = Mutex<(updates: [LibraryUpdate], isScheduled: Bool)>(([], false))

        var isRecording: Bool { take.withLock { $0.isRecording } }
    }
    /// How long updates are gathered before they are applied: a walk tells hundreds a second.
    nonisolated private static let drainDelay: DispatchTimeInterval = .milliseconds(50)

    /// The index is written at most this often (and its writer waits as long again).
    private static let indexSaveDelay: Duration = .seconds(2)
    @ObservationIgnored private let indexWriter: DebouncedWriter
    /// Encodes the index off the main thread, in order.
    @ObservationIgnored private let indexQueue = DispatchQueue(label: "dev.toma.Toma.LibraryIndexSave", qos: .utility)
    @ObservationIgnored private var indexIsDirty = false
    @ObservationIgnored private var indexSaveScheduled = false

    // Thumbnails (design §6.8): only the cards on the screen, two at a time, with a low priority.
    private static let concurrentThumbnails = 2
    /// How many cards off the screen keep their image in memory (each is about 600 KB).
    private static let keptOffScreen = 120
    @ObservationIgnored private var slots: [PackageIdentity: LibraryThumbnail] = [:]
    /// How many views show each card now (the grid's card or the list's row).
    @ObservationIgnored private var onScreen: [PackageIdentity: Int] = [:]
    /// The cards whose thumbnail is to be looked for, in the order they appeared.
    @ObservationIgnored private var wanted: [PackageIdentity] = []
    @ObservationIgnored private var loading: [PackageIdentity: Task<Void, Never>] = [:]
    /// The cards whose thumbnail is as current as it can be.
    @ObservationIgnored private var thumbnailIsCurrent: Set<PackageIdentity> = []
    /// Cards that got none while a take was being recorded: looked for again once it ends.
    @ObservationIgnored private var missedWhileRecording: Set<PackageIdentity> = []
    /// Cards off the screen with an image, oldest first: the first to let it go.
    @ObservationIgnored private var offScreenOrder: [PackageIdentity] = []

    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
    /// Who waits for the cached index to be shown (`whenLoaded(within:)`).
    @ObservationIgnored private var loadedWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Library")

    init(
        paths: LibraryPaths, host: LibraryHost, preferences: LibraryPreferences,
        savePreferences: @escaping (LibraryPreferences) -> Void
    ) {
        self.paths = paths
        self.host = host
        self.savePreferences = savePreferences
        section = LibrarySection(rawValue: preferences.section) ?? .all
        sort = LibrarySort(rawValue: preferences.sort) ?? .dateRecorded
        ascending = preferences.ascending
        asList = preferences.asList
        frame = preferences.frame
        indexWriter = DebouncedWriter(url: paths.index)
    }

    // MARK: - Life

    /// Reads the cached index and the records off the main thread, at once, while the window is being made, and shows
    /// them; then, with the context to read documents with and the projects folder's volume (also read off the main
    /// thread meanwhile), starts the walk, the watcher and the thumbnails.
    func start() {
        guard !started else { return }
        started = true
        let paths = self.paths, fileSystem = self.fileSystem
        let index = Task.detached(priority: .userInitiated) { LibraryIndex.load(from: paths.index) }
        // `LibraryRecordsStore` reads its file as it is made: never on the main thread.
        let store = Task.detached(priority: .userInitiated) { LibraryRecordsStore(url: paths.records) }
        let context = Task.detached(priority: .utility) { Self.makeContext() }
        let volume = Task.detached(priority: .utility) { Self.lookAtVolume(of: paths.projectsFolder, fileSystem) }
        Task {
            let index = await index.value
            let store = await store.value
            let records = await store.records
            guard !closed else { return }
            recordsStore = store
            self.records = records
            for summary in index.projects where summary.identity.file != 0 { summaries[summary.identity] = summary }
            isLookingForProjects = index.projects.isEmpty
            hasLoaded = true
            refresh()
            resumeLoadedWaiters()

            let made = await context.value
            guard !closed else { return }
            self.context = made
            startScanning(from: index, context: made)
            adopt(volume: await volume.value)
        }
    }

    /// Stops the watcher and writes what is pending of the index and the records; the window closed. Updates that come
    /// later are dropped.
    func close() async {
        guard !closed else { return }
        closed = true
        resumeLoadedWaiters()
        for task in loading.values { task.cancel() }
        loading = [:]
        if let watcher { await Task.detached { watcher.stop() }.value }
        saveIndexNow()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in indexQueue.async { done.resume() } }
        await indexWriter.flush()
        await recordsStore?.flush()
    }

    /// Returns once the cached index is shown, or `limit` has passed, or the window closed.
    func whenLoaded(within limit: Duration) async {
        guard !hasLoaded, !closed else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            loadedWaiters.append(waiter)
            Task {
                try? await Task.sleep(for: limit)
                resumeLoadedWaiters()
            }
        }
    }

    private func resumeLoadedWaiters() {
        let waiters = loadedWaiters
        loadedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - What the app tells

    /// Whether a take is being recorded (any) and the package it records into, if it has one yet (design §6.6): that
    /// card says "Grabando", the thumbnails stop being drawn and the watcher looks at that package at most every 2 s.
    func setTake(isRecording: Bool, package: URL?) {
        let wasRecording = shared.take.withLock { take in
            defer { take = (isRecording, package) }
            return take.isRecording
        }
        let path = package?.standardizedFileURL.path
        guard path != recordingPath || wasRecording != isRecording else { return }
        recordingPath = path
        refresh()
        if wasRecording, !isRecording {
            // What a take kept from being drawn.
            for id in missedWhileRecording where onScreen[id, default: 0] > 0 { want(id) }
            missedWhileRecording = []
            pumpThumbnails()
        }
    }

    /// The packages this app's editors have open.
    func setOpenEditors(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        guard paths != openHerePaths else { return }
        openHerePaths = paths
        refresh()
    }

    /// The packages found open in another app (by an editor that opened read-only, or just before an action).
    func setOpenElsewhere(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        guard paths != openElsewherePaths else { return }
        openElsewherePaths = paths
        refresh()
    }

    /// Something the app did, or an action of the user, changed these packages: they are looked at now.
    func look(at urls: [URL]) {
        scanner?.look(at: urls)
    }

    // MARK: - What the user does

    /// The banner's "Volver a intentar": the projects folder is walked again.
    func retry() {
        guard let scanner else { return }
        isFolderUnreadable = false
        unreadableThisWalk = false
        walkFinished = false
        scanner.reconcile(from: LibraryIndex(projects: Array(summaries.values)))
    }

    /// The banner's "Mostrar en Finder".
    func showProjectsFolderInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.projectsFolder])
    }

    /// The notice's close button.
    func dismissNotice() {
        noticeDismissal?.cancel()
        notice = nil
    }

    /// Opens the selected projects (↩, ⌘O, ⌘↓).
    func openSelection() {
        open(selection.selected)
    }

    /// Opens these projects, in the order they are shown (a double click, ↩, ⌘O, ⌘↓): each in its editor, or its window
    /// brought forward. The one being recorded does not open ("Se está grabando."); one of Other places is found again
    /// by its bookmark first, and looked at again (an action of the user, design §6.5); one that was not available is
    /// only looked at again.
    func open(_ ids: Set<PackageIdentity>) {
        for item in shown where ids.contains(item.summary.identity) {
            let summary = item.summary
            let url = URL(filePath: summary.path, directoryHint: .isDirectory)
            if item.live == .recording {
                showNotice(.recording)
                continue
            }
            if case .unavailable = summary.state {
                look(at: [url])
                continue
            }
            noteOpened(summary.identity)
            guard summary.place == .elsewhere else {
                host.open(url)
                if !drawsByItself(summary) { drawOpened(summary, at: url) }
                continue
            }
            let bookmark = records.places.first { $0.path == summary.path }?.bookmark
            Task {
                let found = await Task.detached(priority: .userInitiated) { Self.resolve(bookmark) ?? url }.value
                guard !closed else { return }
                look(at: [found])
                host.open(found)
                drawOpened(summary, at: found)
            }
        }
    }

    /// The thumbnail of a project the library does not look at by itself (Other places, a removable disk), which the
    /// user just opened (design §6.5): its key is read and kept in the index, and it is drawn unless its disk is on the
    /// network or synced (`LibraryThumbnails.mayDraw(…, opened: true)`).
    private func drawOpened(_ summary: ProjectSummary, at url: URL) {
        guard let thumbnails, let context, summary.path != recordingPath, Self.opens(summary.state) else { return }
        let fileSystem = self.fileSystem, id = summary.identity
        Task(priority: .low) {
            let looked = await Task.detached(priority: .utility) { () -> (key: String, mayDraw: Bool)? in
                guard let key = try? LibraryThumbnails.key(of: url), let volume = try? fileSystem.volume(of: url) else {
                    return nil
                }
                return (key, LibraryThumbnails.mayDraw(place: summary.place, volume: volume, opened: true))
            }.value
            guard let looked, !closed, var known = summaries[id] else { return }
            known.thumbnailKey = looked.key
            summaries[id] = known
            scheduleIndexSave()
            let image = looked.mayDraw
                ? await thumbnails.render(url, summary: known, context: context) : await thumbnails.cached(looked.key)
            guard !closed, let image else { return }
            let slot = thumbnail(for: id)
            slot.image = image
            slot.version += 1
            thumbnailIsCurrent.insert(id)
        }
    }

    func click(_ id: PackageIdentity, extending: Bool, toggling: Bool) {
        selection.click(id, order: shownIDs, extending: extending, toggling: toggling)
    }

    func selectAll() {
        selection.selectAll(shownIDs)
    }

    func clearSelection() {
        selection.clear()
    }

    /// The list's table chose these.
    func select(_ ids: Set<PackageIdentity>) {
        selection.set(ids)
    }

    /// An arrow in the grid; returns the card moved to, to bring into view.
    func move(_ move: LibraryMove, extending: Bool) -> PackageIdentity? {
        selection.move(move, extending: extending, order: shownIDs, columns: columns, groupSizes: groups.map(\.items.count))
    }

    // MARK: - What a card shows

    /// The thumbnail of the card `id`, which follows it.
    func thumbnail(for id: PackageIdentity) -> LibraryThumbnail {
        if let slot = slots[id] { return slot }
        let slot = LibraryThumbnail()
        slots[id] = slot
        return slot
    }

    /// A view of the card `id` is on the screen: its thumbnail is looked for if it is not current.
    func cardAppeared(_ id: PackageIdentity) {
        onScreen[id, default: 0] += 1
        guard onScreen[id] == 1 else { return }
        offScreenOrder.removeAll { $0 == id }
        if !thumbnailIsCurrent.contains(id) { want(id) }
        pumpThumbnails()
    }

    /// A view of the card `id` left the screen: once none is left, its thumbnail is no longer looked for, and its image
    /// may be let go.
    func cardDisappeared(_ id: PackageIdentity) {
        guard let count = onScreen[id] else { return }
        guard count <= 1 else {
            onScreen[id] = count - 1
            return
        }
        onScreen[id] = nil
        wanted.removeAll { $0 == id }
        loading.removeValue(forKey: id)?.cancel()
        if slots[id]?.image != nil { offScreenOrder.append(id) }
        while offScreenOrder.count > Self.keptOffScreen {
            let old = offScreenOrder.removeFirst()
            slots[old]?.image = nil
            thumbnailIsCurrent.remove(old)
        }
        pumpThumbnails()
    }

    // MARK: - Updates

    private func startScanning(from index: LibraryIndex, context: EditContext) {
        let paths = self.paths, shared = self.shared, delay = Self.drainDelay
        let onUpdate: @Sendable (LibraryUpdate) -> Void = { [weak self] update in
            let schedule = shared.inbox.withLock { inbox -> Bool in
                inbox.updates.append(update)
                defer { inbox.isScheduled = true }
                return !inbox.isScheduled
            }
            guard schedule else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { self?.drain() }
            }
        }
        let scanner = LibraryScanner(
            projectsFolder: paths.projectsFolder, fileSystem: fileSystem, context: context,
            isRecording: { shared.isRecording }, onUpdate: onUpdate)
        self.scanner = scanner
        thumbnails = LibraryThumbnails(directory: paths.thumbnails, isRecording: { shared.isRecording })
        let watcher = LibraryWatcher(
            folder: paths.projectsFolder, recordingPackage: { shared.take.withLock { $0.package } },
            onPackages: { urls in scanner.look(at: urls) }, fileSystem: fileSystem)
        self.watcher = watcher
        unreadableThisWalk = false
        scanner.reconcile(from: index)
        watcher.start()
    }

    /// Applies what the scanner told since the last time.
    private func drain() {
        let updates = shared.inbox.withLock { inbox -> [LibraryUpdate] in
            defer { inbox = ([], false) }
            return inbox.updates
        }
        guard !closed else { return }
        var indexChanged = false
        var lookAtVolume = false
        for update in updates {
            switch update {
            case .summary(var summary):
                // The scanner keeps the identity it knew; one without any is never kept (design §13.4).
                guard summary.identity.file != 0 else { continue }
                // The scanner does not know the thumbnail's key: one found on an action of the user holds while the
                // files it comes from look the same.
                if summary.thumbnailKey == nil, let known = summaries[summary.identity], known.manifest == summary.manifest,
                    known.edit == summary.edit, known.log == summary.log
                {
                    summary.thumbnailKey = known.thumbnailKey
                }
                let old = summaries.updateValue(summary, forKey: summary.identity)
                indexChanged = true
                if old.map({ Self.looksDifferent($0, summary) }) ?? true { thumbnailChanged(summary.identity) }
            case .removed(let identity):
                // Only the summary: favorites and where a project of the trash came from stay (a `.summary` may follow).
                if summaries.removeValue(forKey: identity) != nil { indexChanged = true }
            case .progress(let found):
                projectsFound = found
            case .waiting(let volume):
                if !waitingFor.contains(volume) { waitingFor.append(volume) }
            case .waitingEnded(let volume):
                waitingFor.removeAll { $0 == volume }
            case .projectsFolderUnreadable:
                unreadableThisWalk = true
                isFolderUnreadable = true
            case .finished:
                walkFinished = true
                isLookingForProjects = false
                if !unreadableThisWalk { isFolderUnreadable = false }
                unreadableThisWalk = false
                lookAtVolume = true
            }
        }
        // Only what changed is set: progress and waits leave the cards alone.
        if indexChanged {
            refresh()
            scheduleIndexSave()
            // A projects folder that was not there is now.
            if projectsVolume == nil { lookAtVolume = true }
        }
        if lookAtVolume { refreshVolume() }
        pumpThumbnails()
    }

    /// Whether a new summary of the same project may show another thumbnail: what it was read from changed.
    private static func looksDifferent(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        a.manifest != b.manifest || a.edit != b.edit || a.log != b.log || a.state != b.state || a.path != b.path
            || a.thumbnailKey != b.thumbnailKey
    }

    /// Everything shown again from what is known: the items with what the records and the app add, the section's in
    /// order, the grid's sections, the counts, what the trash takes; and what is no longer shown is no longer selected.
    private func refresh() {
        let all = summaries.values.map { summary in
            LibraryItem(
                summary: summary, favorite: records.favorites.contains(summary.identity.string),
                lastOpened: records.lastOpened[summary.identity.string], live: live(of: summary))
        }
        // Each is set only when it changed: setting one redraws what reads it.
        let counts = LibraryListing.counts(all)
        if counts != self.counts { self.counts = counts }
        let shown = LibraryListing.items(all, section: section, search: search, sort: sort, ascending: ascending)
        if shown != self.shown { self.shown = shown }
        let groups: [LibraryShownGroup]
        if sort == .dateRecorded {
            let calendar = Calendar.current
            groups = LibraryListing.groups(shown, now: Date(), calendar: calendar).map { group, items in
                LibraryShownGroup(id: Self.key(of: group), title: Self.title(of: group, calendar: calendar), items: items)
            }
        } else {
            groups = shown.isEmpty ? [] : [LibraryShownGroup(id: "all", title: nil, items: shown)]
        }
        if groups != self.groups { self.groups = groups }
        let trashBytes = all.reduce(0) { total, item in item.summary.place == .trash ? total + (item.summary.size ?? 0) : total }
        if trashBytes != self.trashBytes { self.trashBytes = trashBytes }
        var selection = self.selection
        selection.keep(only: Set(shownIDs))
        if selection != self.selection { self.selection = selection }
    }

    private var shownIDs: [PackageIdentity] {
        shown.map(\.summary.identity)
    }

    private func live(of summary: ProjectSummary) -> LiveState {
        if let recordingPath, summary.path == recordingPath { return .recording }
        if openHerePaths.contains(summary.path) { return .openHere }
        if openElsewherePaths.contains(summary.path) { return .openElsewhere }
        return .none
    }

    private static func key(of group: DateGroup) -> String {
        switch group {
        case .today: "today"
        case .yesterday: "yesterday"
        case .weekday(let day): "weekday-\(day)"
        case .month(let year, let month): "month-\(year)-\(month)"
        }
    }

    private static func title(of group: DateGroup, calendar: Calendar) -> String {
        switch group {
        case .today: String(localized: "Today", comment: "The library: the heading of today's projects")
        case .yesterday: String(localized: "Yesterday", comment: "The library: the heading of yesterday's projects")
        case .weekday, .month: group.title(calendar: calendar)
        }
    }

    private func choicesChanged() {
        refresh()
        var preferences = LibraryPreferences(
            asList: asList, sort: sort.rawValue, ascending: ascending, section: section.rawValue)
        preferences.frame = frame
        savePreferences(preferences)
    }

    /// The window's frame, as the window controller last saved it.
    @ObservationIgnored var frame: Rect? {
        didSet {
            guard frame != oldValue else { return }
            savePreferences(
                LibraryPreferences(
                    frame: frame, asList: asList, sort: sort.rawValue, ascending: ascending, section: section.rawValue))
        }
    }

    /// A notice for a few seconds.
    private func showNotice(_ notice: LibraryBanner) {
        noticeDismissal?.cancel()
        self.notice = notice
        noticeDismissal = Task {
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    /// How long a notice stays.
    private static let noticeDuration: Duration = .seconds(4)

    // MARK: - Records and the index

    /// The project was opened now: "Abierto por última vez" (written in whole seconds).
    private func noteOpened(_ identity: PackageIdentity) {
        let now = Date().roundedToWholeSeconds, key = identity.string
        let change: @Sendable (inout LibraryRecords) -> Void = { $0.lastOpened[key] = now }
        change(&records)
        if let recordsStore { Task { await recordsStore.update(change) } }
        refresh()
    }

    /// The index is written `indexSaveDelay` after the first change not written yet, with what is known then.
    private func scheduleIndexSave() {
        indexIsDirty = true
        guard !indexSaveScheduled else { return }
        indexSaveScheduled = true
        Task {
            try? await Task.sleep(for: Self.indexSaveDelay)
            saveIndexNow()
        }
    }

    /// Encodes the index off the main thread and hands it to its writer.
    private func saveIndexNow() {
        indexSaveScheduled = false
        guard indexIsDirty else { return }
        indexIsDirty = false
        let projects = Array(summaries.values), writer = indexWriter
        indexQueue.async {
            let index = LibraryIndex(projects: projects.sorted { $0.path < $1.path })
            do {
                writer.write(try index.encoded())
            } catch {
                Self.logger.error("Cannot encode the library's index: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - The volume

    /// The projects folder's volume and its free space, off the main thread: the free space only on a disk the library
    /// looks at by itself (local, inside the Mac, not synced). `nil` while the folder is not there.
    nonisolated private static func lookAtVolume(
        of folder: URL, _ fileSystem: any LibraryFileSystem
    ) -> (volume: VolumeInfo, free: Int64?)? {
        guard let volume = try? fileSystem.volume(of: folder) else { return nil }
        let isLocal = volume.isInternal && !volume.isRemovable && !volume.isNetwork && !volume.isSynced
        return (volume, isLocal ? try? fileSystem.freeSpace(of: folder) : nil)
    }

    private func refreshVolume() {
        let folder = paths.projectsFolder, fileSystem = self.fileSystem
        Task {
            let found = await Task.detached(priority: .utility) { Self.lookAtVolume(of: folder, fileSystem) }.value
            adopt(volume: found)
        }
    }

    private func adopt(volume found: (volume: VolumeInfo, free: Int64?)?) {
        guard !closed else { return }
        let firstLook = !volumeWasLookedFor
        let appeared = projectsVolume == nil && found != nil
        volumeWasLookedFor = true
        projectsVolume = found?.volume
        freeSpace = found.flatMap { found in found.free.map { LibraryFreeSpace(bytes: $0, volumeName: found.volume.name) } }
        thumbnailsAreOffHere = found.map { $0.volume.isNetwork || $0.volume.isSynced } ?? false
        if appeared {
            // The projects folder was made since (the first take): it is watched now, and what was on the screen is
            // looked for again.
            watcher?.start()
            for id in onScreen.keys where slots[id]?.image == nil {
                thumbnailIsCurrent.remove(id)
                want(id)
            }
        }
        if firstLook || appeared { pumpThumbnails() }
    }

    /// Asked again when the window comes forward: a take may have filled the disk meanwhile.
    func windowBecameKey() {
        guard hasLoaded else { return }
        refreshVolume()
    }

    // MARK: - Thumbnails

    private func want(_ id: PackageIdentity) {
        guard !wanted.contains(id), loading[id] == nil else { return }
        wanted.append(id)
    }

    /// What `summary` changed: its thumbnail is looked for again if its card is on the screen; the old one shows until
    /// the new one arrives.
    private func thumbnailChanged(_ id: PackageIdentity) {
        thumbnailIsCurrent.remove(id)
        loading.removeValue(forKey: id)?.cancel()
        if onScreen[id, default: 0] > 0 { want(id) }
    }

    /// Where the thumbnail of a card comes from (design §6.5, §6.8): drawn (or read from the cache) for a project the
    /// library may look at by itself; only from the cache, by the key its summary has, for any other (Other places, a
    /// removable, network or synced disk); none for the one being recorded or one that cannot be opened.
    private enum ThumbnailSource {
        case render(URL, ProjectSummary)
        case cached(String)
    }

    private func source(of summary: ProjectSummary) -> ThumbnailSource? {
        guard summary.path != recordingPath, Self.opens(summary.state) else { return nil }
        let cached = summary.thumbnailKey.map(ThumbnailSource.cached)
        guard let projectsVolume, LibraryThumbnails.mayDraw(place: summary.place, volume: projectsVolume) else {
            return cached
        }
        return .render(URL(filePath: summary.path, directoryHint: .isDirectory), summary)
    }

    /// Whether the library draws the thumbnail of `summary` by itself, in the background.
    private func drawsByItself(_ summary: ProjectSummary) -> Bool {
        if case .render? = source(of: summary) { return true }
        return false
    }

    /// Whether a project in `state` opens, and so has a thumbnail.
    private static func opens(_ state: ProjectState) -> Bool {
        switch state {
        case .normal, .readOnlyVolume, .inTrash: true
        case .unfinished, .needsRepair, .newerVersion, .unavailable: false
        }
    }

    /// Starts looking for the wanted thumbnails, at most `concurrentThumbnails` at a time, with a low priority; nothing
    /// before the context is made and the projects folder's volume was looked for.
    private func pumpThumbnails() {
        guard !closed, let thumbnails, let context, volumeWasLookedFor else { return }
        while loading.count < Self.concurrentThumbnails, !wanted.isEmpty {
            let id = wanted.removeFirst()
            guard let summary = summaries[id], let source = source(of: summary) else {
                thumbnailIsCurrent.insert(id)
                continue
            }
            loading[id] = Task(priority: .low) {
                let image: CGImage?
                switch source {
                case .render(let url, let summary): image = await thumbnails.render(url, summary: summary, context: context)
                case .cached(let key): image = await thumbnails.cached(key)
                }
                guard !Task.isCancelled else { return }
                thumbnailArrived(id, image)
            }
        }
    }

    private func thumbnailArrived(_ id: PackageIdentity, _ image: CGImage?) {
        loading[id] = nil
        if let image {
            let slot = thumbnail(for: id)
            slot.image = image
            slot.version += 1
            thumbnailIsCurrent.insert(id)
        } else if shared.isRecording {
            missedWhileRecording.insert(id)
        } else {
            thumbnailIsCurrent.insert(id)
        }
        pumpThumbnails()
    }

    #if DEBUG
    /// Nothing is being looked for and the walk ended (`-TomaLibraryBench`).
    var isSettled: Bool {
        walkFinished && volumeWasLookedFor && loading.isEmpty && wanted.isEmpty
    }

    /// How many cards are on the screen (`-TomaLibraryBench`).
    var cardsOnScreen: Int { onScreen.count }
    #endif

    // MARK: - Off the main thread

    /// The context to read documents with, as the editor's (`EditorModel.load`): the default style read from its file.
    nonisolated private static func makeContext() -> EditContext {
        let defaultStyle = DefaultStyleStore(directory: DefaultStyleStore.defaultDirectory).load()
        return EditContext(
            app: AppInfo(name: AppIdentity.name, version: AppIdentity.version), cachesRoot: ProjectCaches.defaultRoot,
            defaultStyle: defaultStyle, now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) },
            styleDirectory: DefaultStyleStore.defaultDirectory)
    }

    /// Where `bookmark` points now, without asking anything nor mounting a disk; `nil` if it does not resolve.
    nonisolated private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &isStale)
    }
}
