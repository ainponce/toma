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
    /// It is on the network or in a synced location: it has none, and says so (design §6.5).
    fileprivate(set) var isOffHere = false
}

/// The library window's model (design §6): the main-actor shell around the library's values. It reads the cached index
/// and the records off the main thread and shows them at once; it keeps `LibraryCatalog` in step with `LibraryScanner`
/// and `LibraryWatcher` (their updates gathered and applied on the main thread at most every `drainDelay`); it carries
/// out what `LibraryThumbnailQueue` decides for the thumbnails of the cards on the screen; it writes the index and the
/// records with their `DebouncedWriter`s. Nothing here touches the disk on the main thread.
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
    private(set) var selection = LibrarySelection<Library.PackageIdentity>()

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

    // MARK: -

    let paths: LibraryPaths
    @ObservationIgnored let host: LibraryHost
    @ObservationIgnored private let savePreferences: (LibraryPreferences) -> Void
    /// How many columns the grid has now, for the arrows; the grid sets it.
    @ObservationIgnored var columns = 1
    /// The window's frame, as the window controller last saved it.
    @ObservationIgnored var frame: Rect? {
        didSet { if frame != oldValue { savePreferences(preferences) } }
    }
    /// `sort` and `ascending` are being set together (`setOrder`): one refresh and one save, after both.
    @ObservationIgnored private var isSettingTheOrder = false

    /// What is known of the projects and of the walk.
    @ObservationIgnored private var catalog = LibraryCatalog(index: LibraryIndex())
    /// What the app said of its own state (design §6.6).
    @ObservationIgnored private var live = LibraryLive()
    @ObservationIgnored private var records = LibraryRecords()
    @ObservationIgnored private var recordsStore: LibraryRecordsStore?
    @ObservationIgnored private var scanner: LibraryScanner?
    /// What the app said to look at before the scanner was there.
    @ObservationIgnored private var pendingLooks: [URL] = []
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var thumbnails: LibraryThumbnails?
    @ObservationIgnored private var context: EditContext?
    /// The projects folder's volume, once found; `nil` while it is not there.
    @ObservationIgnored private var projectsVolume: VolumeInfo?
    /// The projects folder's volume was looked for once.
    @ObservationIgnored private var volumeWasLookedFor = false
    /// The thumbnails' queue was told it can start: the context, the cache and the projects folder's volume are known.
    @ObservationIgnored private var queueIsReady = false
    @ObservationIgnored private let fileSystem = SystemFileSystem()
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var closed = false

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

    // Thumbnails (design §6.8): `LibraryThumbnailQueue` decides, the model looks.
    @ObservationIgnored private var queue = LibraryThumbnailQueue()
    @ObservationIgnored private var slots: [Library.PackageIdentity: LibraryThumbnail] = [:]
    /// The looks under way, by card: a cancelled one still reports when it ends.
    @ObservationIgnored private var looks: [Library.PackageIdentity: Task<Void, Never>] = [:]

    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
    /// How long a notice stays.
    private static let noticeDuration: Duration = .seconds(4)
    /// Who waits for the cached index to be shown (`whenLoaded(within:)`), each with its own time limit.
    @ObservationIgnored private var loadedWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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
            catalog = LibraryCatalog(index: index)
            hasLoaded = true
            showStatus()
            refresh()
            resumeLoadedWaiters()

            let made = await context.value
            guard !closed else { return }
            self.context = made
            startScanning(from: index, context: made)
            adopt(volume: await volume.value)
        }
    }

    /// Stops the scanner and the watcher, and writes what is pending of the index and the records; the window closed.
    /// Returns once the scanner touches no disk any more (a window opened again does not walk the same disk at the same
    /// time). Updates that come later are dropped.
    func close() async {
        guard !closed else { return }
        closed = true
        resumeLoadedWaiters()
        for look in looks.values { look.cancel() }
        looks = [:]
        scanner?.stop()
        if let watcher { await Task.detached { watcher.stop() }.value }
        saveIndexNow()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in indexQueue.async { done.resume() } }
        await indexWriter.flush()
        await recordsStore?.flush()
        await scanner?.whenStopped()
    }

    /// Returns once the cached index is shown, or `limit` has passed, or the window closed.
    func whenLoaded(within limit: Duration) async {
        guard !hasLoaded, !closed else { return }
        let id = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            loadedWaiters[id] = waiter
            Task {
                try? await Task.sleep(for: limit)
                // Only this waiter: another may have a later limit.
                loadedWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func resumeLoadedWaiters() {
        let waiters = loadedWaiters.values
        loadedWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - What the app tells

    /// Whether a take is being recorded (any) and the package it records into, if it has one yet (design §6.6): that
    /// card says "Grabando", the thumbnails stop being drawn and the watcher looks at that package at most every 2 s.
    /// Once the take ends, what it kept from being drawn, its own card included, is looked for again.
    func setTake(isRecording: Bool, package: URL?) {
        let changed = shared.take.withLock { take -> Bool in
            defer { take = (isRecording, package) }
            return take.isRecording != isRecording || take.package != package
        }
        guard changed else { return }
        live.recordingPath = package?.standardizedFileURL.path
        refresh()
        // After the recording path changed: what is decided from now on sees it.
        perform(queue.takeChanged(isRecording: isRecording))
    }

    /// The packages this app's editors have open.
    func setOpenEditors(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        guard paths != live.openHere else { return }
        live.openHere = paths
        refresh()
    }

    /// The packages found open in another app (by an editor that opened read-only, or just before an action).
    func setOpenElsewhere(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        guard paths != live.openElsewhere else { return }
        live.openElsewhere = paths
        refresh()
    }

    /// Something the app did, or an action of the user, changed these packages: they are looked at now.
    func look(at urls: [URL]) {
        guard let scanner else {
            // The window is still being made: looked at once the scanner is there.
            if !closed { pendingLooks += urls }
            return
        }
        scanner.look(at: urls)
    }

    // MARK: - What the user does

    /// The banner's "Volver a intentar": the projects folder is walked again; the strip stays until that walk says.
    func retry() {
        guard let scanner else { return }
        catalog.walkStarted()
        scanner.reconcile(from: LibraryIndex(projects: Array(catalog.summaries.values)))
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

    /// The order and its direction at once (a heading of the list): one refresh and one save.
    func setOrder(_ sort: LibrarySort, ascending: Bool) {
        guard sort != self.sort || ascending != self.ascending else { return }
        isSettingTheOrder = true
        self.sort = sort
        self.ascending = ascending
        isSettingTheOrder = false
        choicesChanged()
    }

    /// Opens the selected projects (↩, ⌘O, ⌘↓).
    func openSelection() {
        open(selection.selected)
    }

    /// Opens these projects, in the order they are shown (a double click, ↩, ⌘O, ⌘↓): each in its editor, or its window
    /// brought forward. The one being recorded does not open ("Se está grabando."); one of Other places is found again
    /// by its bookmark first, and looked at again (an action of the user, design §6.5); one that was not available is
    /// only looked at again.
    func open(_ ids: Set<Library.PackageIdentity>) {
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

    func click(_ id: Library.PackageIdentity, extending: Bool, toggling: Bool) {
        selection.click(id, order: shownIDs, extending: extending, toggling: toggling)
    }

    func selectAll() {
        selection.selectAll(shownIDs)
    }

    func clearSelection() {
        selection.clear()
    }

    /// The list's table chose these.
    func select(_ ids: Set<Library.PackageIdentity>) {
        selection.set(ids)
    }

    /// An arrow in the grid; returns the card moved to, to bring into view.
    func move(_ move: LibraryMove, extending: Bool) -> Library.PackageIdentity? {
        selection.move(move, extending: extending, order: shownIDs, columns: columns, groupSizes: groups.map(\.items.count))
    }

    // MARK: - What a card shows

    /// The thumbnail of the card `id`, which follows it.
    func thumbnail(for id: Library.PackageIdentity) -> LibraryThumbnail {
        if let slot = slots[id] { return slot }
        let slot = LibraryThumbnail()
        slots[id] = slot
        return slot
    }

    /// A view of the card `id` is on the screen.
    func cardAppeared(_ id: Library.PackageIdentity) {
        perform(queue.appeared(id))
    }

    /// A view of the card `id` left the screen.
    func cardDisappeared(_ id: Library.PackageIdentity) {
        perform(queue.disappeared(id))
    }

    /// Asked again when the window comes forward: a take may have filled the disk meanwhile.
    func windowBecameKey() {
        guard hasLoaded else { return }
        refreshVolume()
    }

    #if DEBUG
    /// Nothing is being looked for and the walk ended (`-TomaLibraryBench`).
    var isSettled: Bool { catalog.walkFinished && volumeWasLookedFor && queue.isIdle }

    /// How many cards are on the screen (`-TomaLibraryBench`).
    var cardsOnScreen: Int { queue.cardsOnScreen }
    #endif

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
        scanner.reconcile(from: index)
        watcher.start()
        if !pendingLooks.isEmpty {
            scanner.look(at: pendingLooks)
            pendingLooks = []
        }
        makeTheQueueReady()
    }

    /// Tells the thumbnails' queue it can start, once what it needs to decide is known.
    private func makeTheQueueReady() {
        guard !queueIsReady, volumeWasLookedFor, context != nil, thumbnails != nil else { return }
        queueIsReady = true
        perform(queue.ready())
    }

    /// Applies what the scanner told since the last time (`LibraryCatalog.apply`), and carries out what follows.
    private func drain() {
        let updates = shared.inbox.withLock { inbox -> [LibraryUpdate] in
            defer { inbox = ([], false) }
            return inbox.updates
        }
        guard !closed else { return }
        let changes = catalog.apply(updates)
        if changes.status { showStatus() }
        if changes.projects {
            refresh()
            scheduleIndexSave()
        }
        // In a stable order: the queue starts them in the order it is told.
        for id in changes.thumbnails.sorted(by: { $0.string < $1.string }) { perform(queue.changed(id)) }
        // A walk ended, or a projects folder that was not there is now: its disk is looked at again.
        if changes.walkFinished || (changes.projects && projectsVolume == nil) { refreshVolume() }
    }

    /// The walk's state, as the catalog has it, for the sidebar's foot and the strip.
    private func showStatus() {
        if isLookingForProjects != catalog.isLookingForProjects { isLookingForProjects = catalog.isLookingForProjects }
        if projectsFound != catalog.projectsFound { projectsFound = catalog.projectsFound }
        if waitingFor != catalog.waitingFor { waitingFor = catalog.waitingFor }
        if isFolderUnreadable != catalog.isFolderUnreadable { isFolderUnreadable = catalog.isFolderUnreadable }
    }

    /// Everything shown again from what is known (`LibraryCatalog.sections`); each value set only when it changed, since
    /// setting one redraws what reads it; and what is no longer shown is no longer selected.
    private func refresh() {
        let calendar = Calendar.current
        let sections = catalog.sections(
            section: section, search: search, sort: sort, ascending: ascending, records: records, live: live, now: Date(),
            calendar: calendar)
        if sections.counts != counts { counts = sections.counts }
        if sections.shown != shown { shown = sections.shown }
        let groups = sections.groups.map { group in
            LibraryShownGroup(
                id: group.date.map(Self.key(of:)) ?? "all", title: group.date.map { Self.title(of: $0, calendar: calendar) },
                items: group.items)
        }
        if groups != self.groups { self.groups = groups }
        if sections.trashBytes != trashBytes { trashBytes = sections.trashBytes }
        var selection = self.selection
        selection.keep(only: Set(shownIDs))
        if selection != self.selection { self.selection = selection }
    }

    private var shownIDs: [Library.PackageIdentity] {
        shown.map(\.summary.identity)
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

    // MARK: - Preferences and notices

    /// What the library remembers (design §6.1).
    private var preferences: LibraryPreferences {
        LibraryPreferences(frame: frame, asList: asList, sort: sort.rawValue, ascending: ascending, section: section.rawValue)
    }

    private func choicesChanged() {
        guard !isSettingTheOrder else { return }
        refresh()
        savePreferences(preferences)
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

    // MARK: - Records and the index

    /// The project was opened now: "Abierto por última vez" (written in whole seconds).
    private func noteOpened(_ identity: Library.PackageIdentity) {
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
        let projects = Array(catalog.summaries.values), writer = indexWriter
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

    /// The projects folder's volume as just found: the free space; the thumbnails start once it was looked for; when the
    /// folder appears after a look found it missing (the first take made it), it is watched and the cards without an
    /// image are looked for again.
    private func adopt(volume found: (volume: VolumeInfo, free: Int64?)?) {
        guard !closed else { return }
        let appeared = volumeWasLookedFor && projectsVolume == nil && found != nil
        volumeWasLookedFor = true
        projectsVolume = found?.volume
        freeSpace = found.flatMap { found in found.free.map { LibraryFreeSpace(bytes: $0, volumeName: found.volume.name) } }
        makeTheQueueReady()
        if appeared {
            watcher?.start()
            perform(queue.lookAgainWithoutImage())
        }
    }

    // MARK: - Thumbnails

    /// Carries out what the queue decided: a look started as `LibraryThumbnailQueue.decide` says (one with nothing to
    /// look for reports at once), a look cancelled (it still reports when it ends), an image shown or let go.
    private func perform(_ actions: [LibraryThumbnailQueue.Action]) {
        var pending = actions[...]
        while let action = pending.popFirst() {
            switch action {
            case .start(let id):
                pending.append(contentsOf: start(id))
            case .cancel(let id):
                looks[id]?.cancel()
            case .show:
                break  // shown by `lookEnded`, which has the image
            case .release(let id):
                slots[id]?.image = nil
            }
        }
    }

    /// Starts the look for the card `id`; what the queue says at once when there is nothing to look for.
    private func start(_ id: Library.PackageIdentity) -> [LibraryThumbnailQueue.Action] {
        guard !closed, let thumbnails, let context, let summary = catalog.summaries[id] else {
            return queue.returned(id, .nothing)
        }
        let decision = LibraryThumbnailQueue.decide(summary, projectsVolume: projectsVolume, recordingPath: live.recordingPath)
        thumbnail(for: id).isOffHere = decision == .notHere
        switch decision {
        case .draw(let url):
            looks[id] = Task(priority: .low) {
                let image = await thumbnails.render(url, summary: summary, context: context)
                lookEnded(id, image, cancelled: Task.isCancelled)
            }
        case .cached(let key):
            looks[id] = Task(priority: .low) {
                let image = await thumbnails.cached(key)
                lookEnded(id, image, cancelled: Task.isCancelled)
            }
        case .afterTheTake:
            return queue.returned(id, .afterTheTake)
        case .notHere, .none:
            return queue.returned(id, .nothing)
        }
        return []
    }

    /// A look ended (or was cancelled: what it found is dropped).
    private func lookEnded(_ id: Library.PackageIdentity, _ image: CGImage?, cancelled: Bool) {
        looks[id] = nil
        guard !closed else { return }
        let outcome: LibraryThumbnailQueue.Outcome = image == nil ? .noImage : .image
        let actions = queue.returned(id, cancelled ? .noImage : outcome)
        if let image, actions.contains(.show(id)) { show(image, on: id) }
        perform(actions)
    }

    private func show(_ image: CGImage, on id: Library.PackageIdentity) {
        let slot = thumbnail(for: id)
        slot.image = image
        slot.isOffHere = false
        slot.version += 1
    }

    /// Whether the library draws the thumbnail of `summary` by itself, in the background.
    private func drawsByItself(_ summary: ProjectSummary) -> Bool {
        if case .draw = LibraryThumbnailQueue.decide(summary, projectsVolume: projectsVolume, recordingPath: live.recordingPath) {
            return true
        }
        return false
    }

    /// The thumbnail of a project the library does not look at by itself (Other places, a removable disk), which the
    /// user just opened (design §6.5): its key is read and kept in the index, and it is drawn unless its disk is on the
    /// network or synced (`LibraryThumbnails.mayDraw(…, opened: true)`); what it gives is kept as the queue keeps any.
    private func drawOpened(_ summary: ProjectSummary, at url: URL) {
        guard let thumbnails, let context, summary.path != live.recordingPath else { return }
        switch summary.state {
        case .normal, .readOnlyVolume, .inTrash: break
        case .unfinished, .needsRepair, .newerVersion, .unavailable: return
        }
        let fileSystem = self.fileSystem, id = summary.identity
        Task(priority: .low) {
            let looked = await Task.detached(priority: .utility) { () -> (key: String, mayDraw: Bool, offHere: Bool)? in
                guard let key = try? LibraryThumbnails.key(of: url), let volume = try? fileSystem.volume(of: url) else {
                    return nil
                }
                return (key, LibraryThumbnails.mayDraw(place: summary.place, volume: volume, opened: true),
                    volume.isNetwork || volume.isSynced)
            }.value
            guard let looked, !closed else { return }
            if catalog.setThumbnailKey(looked.key, for: id) { scheduleIndexSave() }
            guard let known = catalog.summaries[id] else { return }
            if looked.offHere {
                thumbnail(for: id).isOffHere = true
                perform(queue.lookedForByTheUser(id, .nothing))
                return
            }
            let image = looked.mayDraw
                ? await thumbnails.render(url, summary: known, context: context) : await thumbnails.cached(looked.key)
            guard !closed else { return }
            let actions = queue.lookedForByTheUser(id, image == nil ? .noImage : .image)
            if let image, actions.contains(.show(id)) { show(image, on: id) }
            perform(actions)
        }
    }

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
