// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Editing
import Foundation
import ProjectFormat
import Synchronization

/// What a `LibraryScanner` tells the library (design §6.8, §10).
public enum LibraryUpdate: Equatable, Sendable {
    /// What the library knows of a project now: one it had not seen, one that changed, moved or was renamed, one of
    /// Other places that a look did not find (`.unavailable`), or one whose size was summed. It replaces the summary of
    /// the same identity.
    case summary(ProjectSummary)
    /// A project of the projects folder or its trash that is no longer there (plan decision 25). Never one of Other
    /// places: those never leave the list by themselves.
    case removed(PackageIdentity)
    /// How many projects the walk of `reconcile` found so far: "Buscando proyectos… 340".
    case progress(found: Int)
    /// An access to the disk of that name took longer than `LibraryScanner.slowAccess`: "Esperando al disco «X»…".
    /// Its cards keep what the index had until it answers.
    case waiting(volume: String)
    /// That disk answered an access in less than `slowAccess`, or has nothing left to do.
    case waitingEnded(volume: String)
    /// A `reconcile` walked the whole projects folder, or found it is not one to look at by itself. Sizes come later.
    case finished
}

/// Keeps what the library knows of the projects in step with the disk (design §6.5, §6.8), off the caller's thread:
/// every method returns at once, and every access to a disk happens on a serial queue of that disk's own, so a slow disk
/// holds up only its own cards. Updates come through `onUpdate`, from those queues (several at once).
///
/// - `reconcile(from:)` walks the projects folder, by itself, only if it is on a local internal volume: up to
///   `maxDepth` folders down, never into `Trash/` (listed apart), a hidden folder or a package, never following a link
///   (a package that is a link is not listed). Of each package it takes the `stat` of the package, `manifest.json`,
///   `edit.json` and `edit-log.jsonl`, and reads it again (`ProjectReader`) only if one changed in size or date, or
///   the package moved. A project of the projects folder that a complete walk does not find is `.removed`.
/// - `look(at:)` looks at what an action of the user, the app or the watcher names, wherever it is.
/// - Sizes come after every read, from the same queue, and wait while anything is being recorded (`isRecording`): they
///   are the heavy part. Reads go on while recording.
///
/// It never writes, never cancels an access half way, and never probes a lock: `isLockHeld` is never called (design
/// §6.6). Inside a package it touches only those three files, what `readDocument` reads (the manifest, the documents
/// and the take's `events.jsonl`, never a video) and, for its size, the space its items take.
public final class LibraryScanner: Sendable {
    /// How many folders below the projects folder a project may be: `a/b/c/d/X.toma` is listed, `a/b/c/d/e/X.toma` not.
    public static let maxDepth = 4
    /// An access that takes longer says `.waiting(volume:)`.
    public static let slowAccess: Duration = .seconds(2)
    /// How often sizes held back by a recording ask again whether it ended.
    static let recordingRecheck: Duration = .seconds(1)
    /// The least time between two `.progress` updates.
    static let progressInterval: Duration = .milliseconds(100)

    private let projectsFolder: URL
    /// The projects folder's path components, standardized, to tell what is in it.
    private let projectsComponents: [String]
    private let fileSystem: any LibraryFileSystem
    private let readDocument: @Sendable (URL) throws -> (LoadedProject, EditDocument, Int)
    /// Kept so the app hands the scanner the same probe as every other part of the library, and a test can count that it
    /// is never called: locks are probed only right before a destructive action (design §6.6), never by the scanner.
    private let isLockHeld: @Sendable (URL) -> Bool
    private let context: EditContext
    private let isRecording: @Sendable () -> Bool
    private let onUpdate: @Sendable (LibraryUpdate) -> Void
    private let state = Mutex(State())
    /// Where slow accesses are noticed while they last.
    private let watchdog = DispatchQueue(label: "dev.toma.Toma.LibraryScanner.watchdog", qos: .utility)
    /// Where `.waiting` and `.waitingEnded` are told, in the order they happened.
    private let notices = DispatchQueue(label: "dev.toma.Toma.LibraryScanner.notices", qos: .utility)

    private struct State {
        /// What the library knows, by identity, as the scanner last told it (or the index said).
        var known: [PackageIdentity: ProjectSummary] = [:]
        var byPath: [String: PackageIdentity] = [:]
        var queues: [String: VolumeQueue] = [:]
        /// The projects folder's volume, as last found.
        var projectsVolume: VolumeInfo?
        /// The disks, by name, that said `.waiting` and not `.waitingEnded` yet.
        var waiting: Set<String> = []
    }

    /// `readDocument` is `ProjectReader`'s, by default `EditSession.readDocumentWithDiskVersion` with `context`;
    /// `isLockHeld`, by default `RecordingLock.isHeld`, is never called.
    public init(
        projectsFolder: URL, fileSystem: any LibraryFileSystem,
        readDocument: (@Sendable (URL) throws -> (LoadedProject, EditDocument, Int))? = nil,
        isLockHeld: @escaping @Sendable (URL) -> Bool = { RecordingLock.isHeld(at: $0) }, context: EditContext,
        isRecording: @escaping @Sendable () -> Bool, onUpdate: @escaping @Sendable (LibraryUpdate) -> Void
    ) {
        self.projectsFolder = URL(filePath: projectsFolder.standardizedFileURL.path, directoryHint: .isDirectory)
        self.projectsComponents = projectsFolder.standardizedFileURL.pathComponents
        self.fileSystem = fileSystem
        self.readDocument =
            readDocument ?? { url in
                let (project, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(
                    url, take: nil, context: context)
                return (project, document, diskVersion)
            }
        self.isLockHeld = isLockHeld
        self.context = context
        self.isRecording = isRecording
        self.onUpdate = onUpdate
    }

    // MARK: - What the library asks

    /// Starts from `index` (what the library showed from its cache) and walks the projects folder, if it is on a local
    /// internal volume, telling what changed, what is new and what is gone, then `.finished`; then the sizes it lacks.
    /// On any other volume, or if the folder cannot be found, only `.finished`: the index stays as it was, and a project
    /// is looked at only with `look(at:)`. An entry of the index with no identity (`.unavailable(.notFound)` of a
    /// package that was not there) is dropped.
    public func reconcile(from index: LibraryIndex) {
        withProjectsVolume(refresh: true) { volume in
            guard let volume, volume.isLookedAtAlone else {
                self.start(from: index)
                self.onUpdate(.finished)
                return
            }
            let queue = self.volumeQueue(for: volume)
            self.enqueue(on: queue) {
                // On the walk's queue: a walk under way ends with what it started from.
                self.start(from: index)
                self.walkEverything(volume: volume, queue: queue)
            }
        }
    }

    /// What the scanner knows becomes `index`'s, without the entries that have no identity.
    private func start(from index: LibraryIndex) {
        state.withLock { state in
            state.known = [:]
            state.byPath = [:]
            for summary in index.projects where summary.identity.file != 0 {
                state.known[summary.identity] = summary
                state.byPath[summary.path] = summary.identity
            }
        }
    }

    /// Looks at each of `urls` now, on an action of the user ("Actualizar", one of Other places), a notice of the app
    /// (a new take, a rename) or a change the watcher saw, wherever it is:
    /// - a package or a folder in the projects folder: what it holds by the rules of the walk (a folder is walked, the
    ///   projects folder itself or its trash too), and what the library knew there and is gone is `.removed`, unless
    ///   one of `urls` shows it moved;
    /// - a package anywhere else, as one of Other places: what it is now, or `.unavailable` (with its disk's name if
    ///   the disk is not connected) if it was known and is not found.
    /// Every package looked at is read again. Its size comes after, except on the network or in a synced location.
    public func look(at urls: [URL]) {
        var inProjectsFolder: [URL] = []
        var outside: [String: URL] = [:]
        for url in urls {
            if url.standardizedFileURL.pathComponents.starts(with: projectsComponents) {
                inProjectsFolder.append(url)
            } else if PackageNames.isPackage(url.lastPathComponent) {
                outside[url.standardizedFileURL.path] = url
            }
        }
        let inside = inProjectsFolder
        if !inside.isEmpty {
            withProjectsVolume(refresh: false) { volume in
                guard let volume else { return }
                let queue = self.volumeQueue(for: volume)
                self.enqueue(on: queue) { self.lookInside(inside, volume: volume, queue: queue) }
            }
        }
        for url in outside.values {
            let resolver = self.resolver(for: url, isProjectsFolder: false)
            enqueue(on: resolver) {
                switch self.findVolume(of: url, on: resolver) {
                case .success(let volume):
                    let queue = self.volumeQueue(for: volume)
                    self.enqueue(on: queue) { self.lookElsewhere(url, volume: volume, queue: queue) }
                case .failure(let error):
                    if Self.isMissing(error) {
                        let fileSystem = TimedFileSystem(base: self.fileSystem, scanner: self, queue: resolver)
                        self.markUnavailable(url, fileSystem: fileSystem)
                    }
                    self.endWaiting(named: resolver.name)
                }
            }
        }
    }

    /// Sums again, after any read waiting on their disk and while nothing is being recorded, the space each of these
    /// projects takes, telling it with their summary. Only those the scanner looks at by itself: of the projects folder
    /// (or its trash) on a local internal volume. The others are left as they are.
    public func accountSizes(of identities: [PackageIdentity]) {
        withProjectsVolume(refresh: false) { volume in
            guard let volume, volume.isLookedAtAlone else { return }
            let mine = self.state.withLock { state in
                identities.filter { identity in
                    guard let summary = state.known[identity] else { return false }
                    if case .elsewhere = summary.place { return false }
                    return true
                }
            }
            self.scheduleSizes(of: mine, on: self.volumeQueue(for: volume), volume: volume)
        }
    }

    // MARK: - Walking

    /// What one job found, on one queue.
    private struct Pass {
        let volume: VolumeInfo
        let fileSystem: TimedFileSystem
        let reportsProgress: Bool
        /// The identities seen, to tell what is gone.
        var found: Set<PackageIdentity> = []
        /// The folders and packages that could not be looked at, for another reason than being gone (`EIO`, `EACCES`):
        /// what the library knew at or under them stays.
        var unreadable: [String] = []
        var sizes: [PackageIdentity] = []
        var count = 0
        var lastProgress: ContinuousClock.Instant?
    }

    /// The walk of `reconcile`, on the queue of the projects folder's volume.
    private func walkEverything(volume: VolumeInfo, queue: VolumeQueue) {
        var pass = Pass(
            volume: volume, fileSystem: TimedFileSystem(base: fileSystem, scanner: self, queue: queue), reportsProgress: true)
        if walk(projectsFolder, depth: 0, subfolder: "", &pass) {
            removeMissing(everywhere: true, under: [], pass)
            reportProgress(&pass, final: true)
        }
        onUpdate(.finished)
        scheduleSizes(of: pass.sizes, on: queue, volume: volume)
    }

    /// Lists `folder`, `depth` folders below the projects folder (whose path from it is `subfolder`): its packages,
    /// then the trash (in the projects folder itself), then its folders while `depth` is less than `maxDepth`. Hidden
    /// items, links and files are skipped. Whether it could be listed; one that could not, for any reason but being
    /// gone, is kept in `unreadable`.
    @discardableResult
    private func walk(_ folder: URL, depth: Int, subfolder: String, _ pass: inout Pass) -> Bool {
        let entries: [URL]
        do {
            entries = try pass.fileSystem.list(folder)
        } catch {
            if !Self.isMissing(error) { pass.unreadable.append(folder.standardizedFileURL.path) }
            return false
        }
        var folders: [(url: URL, subfolder: String)] = []
        var trash: URL?
        for entry in entries {
            let name = entry.lastPathComponent
            if PackageNames.isHidden(name) { continue }
            if PackageNames.isPackage(name) {
                visit(entry, place: .projectsFolder(subfolder: subfolder), reread: false, &pass)
            } else if entry.hasDirectoryPath {
                if depth == 0, PackageNames.isTrash(name) {
                    trash = entry
                } else if depth < Self.maxDepth {
                    folders.append((entry, subfolder.isEmpty ? name : subfolder + "/" + name))
                }
            }
        }
        if let trash { walkTrash(trash, &pass) }
        for (url, subfolder) in folders { walk(url, depth: depth + 1, subfolder: subfolder, &pass) }
        return true
    }

    /// The packages of `<projects folder>/Trash/` itself; nothing in its folders.
    private func walkTrash(_ trash: URL, _ pass: inout Pass) {
        let entries: [URL]
        do {
            entries = try pass.fileSystem.list(trash)
        } catch {
            if !Self.isMissing(error) { pass.unreadable.append(trash.standardizedFileURL.path) }
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if !PackageNames.isHidden(name), PackageNames.isPackage(name) { visit(entry, place: .trash, reread: false, &pass) }
        }
    }

    /// Looks at the package `url` in `place`: nothing if it is not a folder (a link is not listed) or is gone; what the
    /// library knew there stays if it cannot be looked at for another reason. Unless `reread`, a package the library
    /// knows at this path and place, with the same signatures, is not read again.
    private func visit(_ url: URL, place: Place, reread: Bool, _ pass: inout Pass) {
        let fileSystem = pass.fileSystem
        let path = url.standardizedFileURL.path
        let folder: FileStat
        do {
            folder = try fileSystem.stat(url, withAddedDate: false)
        } catch {
            if !Self.isMissing(error) { pass.unreadable.append(path) }
            return
        }
        guard folder.kind == .directory else { return }
        pass.count += 1
        reportProgress(&pass)
        if !reread, let known = state.withLock({ $0.known[PackageIdentity(volume: pass.volume.uuid, file: folder.fileID)] }),
            known.path == path, known.place == place, !known.state.isUnavailable
        {
            let package = ProjectPackage(url: url)
            func signature(_ file: URL) -> FileSignature? {
                (try? fileSystem.stat(file, withAddedDate: false)).map { FileSignature(size: $0.size, modified: $0.modified) }
            }
            if known.manifest == signature(package.manifestURL), known.edit == signature(package.editURL),
                known.log == signature(package.editLogURL)
            {
                pass.found.insert(known.identity)
                if known.size == nil { pass.sizes.append(known.identity) }
                return
            }
        }
        switch read(url, place: place, fileSystem: fileSystem) {
        case .read(let summary):
            pass.found.insert(summary.identity)
            pass.sizes.append(summary.identity)
        case .gone:
            break
        case .unreadable:
            pass.unreadable.append(path)
        }
    }

    private enum Reading {
        case read(ProjectSummary)
        /// The package is not there.
        case gone
        /// It cannot be looked at for now (a disk that fails): what the library knew of it stays.
        case unreadable
    }

    /// Reads the package at `url` and tells it, keeping its size until it is summed again and its thumbnail key if its
    /// files did not change. Telling nothing if it is not there, or cannot be looked at (`ProjectReader` gives those an
    /// identity of file 0, which is never told).
    private func read(_ url: URL, place: Place, fileSystem: any LibraryFileSystem) -> Reading {
        var summary = ProjectReader.summary(
            of: url, place: place, fileSystem: fileSystem, readDocument: readDocument, context: context, now: context.now())
        if summary.identity.file == 0 { return summary.state == .unavailable(.notFound) ? .gone : .unreadable }
        if let previous = state.withLock({ $0.known[summary.identity] }) {
            summary.size = previous.size
            if previous.manifest == summary.manifest, previous.edit == summary.edit, previous.log == summary.log {
                summary.thumbnailKey = previous.thumbnailKey
            }
        }
        publish(summary)
        return .read(summary)
    }

    /// Looks at `urls`, all in the projects folder, as one: what one of them shows moved is not gone from another.
    private func lookInside(_ urls: [URL], volume: VolumeInfo, queue: VolumeQueue) {
        var pass = Pass(
            volume: volume, fileSystem: TimedFileSystem(base: fileSystem, scanner: self, queue: queue), reportsProgress: false)
        var everywhere = false
        var scopes: [String] = []
        for url in urls {
            switch item(at: url) {
            case .projectsFolder:
                if !walk(projectsFolder, depth: 0, subfolder: "", &pass) {
                    pass.unreadable.append(projectsFolder.standardizedFileURL.path)
                }
                everywhere = true
            case .trash(let trash):
                walkTrash(trash, &pass)
                scopes.append(trash.standardizedFileURL.path)
            case .folder(let folder, let depth, let subfolder):
                walk(folder, depth: depth, subfolder: subfolder, &pass)
                scopes.append(folder.standardizedFileURL.path)
            case .package(let package, let place):
                visit(package, place: place, reread: true, &pass)
                scopes.append(package.standardizedFileURL.path)
            case .notListed(let path):
                scopes.append(path)
            }
        }
        removeMissing(everywhere: everywhere, under: scopes, pass)
        scheduleSizes(of: pass.sizes, on: queue, volume: volume)
    }

    /// Looks at `url`, one of Other places, on its volume's queue.
    private func lookElsewhere(_ url: URL, volume: VolumeInfo, queue: VolumeQueue) {
        let fileSystem = TimedFileSystem(
            base: fileSystem, scanner: self, queue: queue, resolved: (url.standardizedFileURL.path, volume))
        switch read(url, place: .elsewhere, fileSystem: fileSystem) {
        case .read(let summary): scheduleSizes(of: [summary.identity], on: queue, volume: volume)
        case .gone: markUnavailable(url, fileSystem: fileSystem)
        case .unreadable: break
        }
    }

    /// Tells the project of Other places known at `url` as `.unavailable`: its disk's name if `url` is on a volume of
    /// `/Volumes` that is not there, `.notFound` otherwise. Nothing for one that was not known, nor for one of the
    /// projects folder (those are `.removed`).
    private func markUnavailable(_ url: URL, fileSystem: any LibraryFileSystem) {
        let path = url.standardizedFileURL.path
        guard var summary = state.withLock({ state in state.byPath[path].flatMap { state.known[$0] } }),
            case .elsewhere = summary.place
        else { return }
        let components = url.standardizedFileURL.pathComponents
        var reason = Unavailable.notFound
        if components.count > 3, components[1] == "Volumes",
            (try? fileSystem.stat(URL(filePath: "/Volumes/" + components[2], directoryHint: .isDirectory), withAddedDate: false))
                == nil
        {
            reason = .diskNotConnected(components[2])
        }
        summary.state = .unavailable(reason)
        publish(summary)
    }

    /// What a URL in the projects folder is for the walk.
    private enum Item {
        case projectsFolder
        case trash(URL)
        case folder(URL, depth: Int, subfolder: String)
        case package(URL, Place)
        /// What the walk never lists (hidden, too deep, in a folder of the trash), by its path: what the library knew
        /// there is gone.
        case notListed(String)
    }

    /// `url`, in the projects folder, as the walk sees it: a URL inside a package is that package.
    private func item(at url: URL) -> Item {
        let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(projectsComponents.count))
        guard let first = relative.first else { return .projectsFolder }
        let packageIndex = relative.firstIndex(where: PackageNames.isPackage)
        let named = Array(relative[...(packageIndex ?? relative.count - 1)])
        let target = named.reduce(projectsFolder) { $0.appending(path: $1, directoryHint: .isDirectory) }
        let path = target.standardizedFileURL.path
        if named.contains(where: PackageNames.isHidden) { return .notListed(path) }
        if PackageNames.isTrash(first) {
            if packageIndex == 1 { return .package(target, .trash) }
            return named.count == 1 && packageIndex == nil ? .trash(target) : .notListed(path)
        }
        if let packageIndex {
            guard packageIndex <= Self.maxDepth else { return .notListed(path) }
            return .package(target, .projectsFolder(subfolder: named.dropLast().joined(separator: "/")))
        }
        guard named.count <= Self.maxDepth else { return .notListed(path) }
        return .folder(target, depth: named.count, subfolder: named.joined(separator: "/"))
    }

    // MARK: - What the library is told

    private func publish(_ summary: ProjectSummary) {
        state.withLock { state in
            if let old = state.known[summary.identity], old.path != summary.path, state.byPath[old.path] == summary.identity {
                state.byPath[old.path] = nil
            }
            state.known[summary.identity] = summary
            state.byPath[summary.path] = summary.identity
        }
        onUpdate(.summary(summary))
    }

    /// Tells `.removed` for each project of the projects folder or its trash the library knew (everywhere, or at or
    /// under one of `paths`) that `pass` did not find, unless it was at or under something that could not be looked at.
    private func removeMissing(everywhere: Bool, under paths: [String], _ pass: Pass) {
        func isUnder(_ path: String, _ folders: [String]) -> Bool {
            folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        let gone = state.withLock { state -> [PackageIdentity] in
            let gone = state.known.values.filter { summary in
                if case .elsewhere = summary.place { return false }
                return (everywhere || isUnder(summary.path, paths)) && !pass.found.contains(summary.identity)
                    && !isUnder(summary.path, pass.unreadable)
            }.map(\.identity)
            for identity in gone {
                if let summary = state.known.removeValue(forKey: identity), state.byPath[summary.path] == identity {
                    state.byPath[summary.path] = nil
                }
            }
            return gone
        }
        for identity in gone { onUpdate(.removed(identity)) }
    }

    private func reportProgress(_ pass: inout Pass, final: Bool = false) {
        guard pass.reportsProgress else { return }
        let now = ContinuousClock.now
        guard final || pass.lastProgress.map({ $0.duration(to: now) >= Self.progressInterval }) ?? true else { return }
        pass.lastProgress = now
        onUpdate(.progress(found: pass.count))
    }

    // MARK: - Sizes

    /// Queues the sum of the size of each of `identities` on `queue`, after its reads, unless `volume` is on the network
    /// or synced (design §6.5: nothing that would download).
    private func scheduleSizes(of identities: [PackageIdentity], on queue: VolumeQueue, volume: VolumeInfo) {
        guard volume.readsSizes else { return }
        for identity in identities {
            enqueueSize(of: identity, on: queue) { self.sumSize(of: identity, queue: queue) }
        }
    }

    private func sumSize(of identity: PackageIdentity, queue: VolumeQueue) {
        guard let path = state.withLock({ $0.known[identity]?.path }) else { return }
        let fileSystem = TimedFileSystem(base: fileSystem, scanner: self, queue: queue)
        guard let size = try? fileSystem.allocatedSize(of: URL(filePath: path, directoryHint: .isDirectory)) else { return }
        let summary = state.withLock { state -> ProjectSummary? in
            guard var summary = state.known[identity], summary.path == path, summary.size != size else { return nil }
            summary.size = size
            state.known[identity] = summary
            return summary
        }
        if let summary { onUpdate(.summary(summary)) }
    }

    // MARK: - Queues

    /// Runs `then` with the projects folder's volume: the one found last unless `refresh`, or found now on the projects
    /// folder's own queue; `nil` if it cannot be found.
    private func withProjectsVolume(refresh: Bool, _ then: @escaping @Sendable (VolumeInfo?) -> Void) {
        if !refresh, let volume = state.withLock({ $0.projectsVolume }) {
            then(volume)
            return
        }
        let resolver = resolver(for: projectsFolder, isProjectsFolder: true)
        enqueue(on: resolver) {
            let volume = try? self.findVolume(of: self.projectsFolder, on: resolver).get()
            if let volume {
                self.state.withLock { $0.projectsVolume = volume }
            } else {
                self.endWaiting(named: resolver.name)
            }
            then(volume)
        }
    }

    /// The volume of `url`, asked on `resolver`. One that took longer than `slowAccess` says `.waiting` with the name it
    /// gave, which its volume's queue ends; a wait `resolver` said under another name (its folder in `/Volumes`) ends.
    private func findVolume(of url: URL, on resolver: VolumeQueue) -> Result<VolumeInfo, any Error> {
        let start = ContinuousClock.now
        let volume = Result { try timed(resolver) { try fileSystem.volume(of: url) } }
        if case .success(let volume) = volume {
            if start.duration(to: .now) >= Self.slowAccess { startWaiting(named: volume.name) }
            if resolver.name != volume.name { endWaiting(named: resolver.name) }
        }
        return volume
    }

    /// The queue where the volume of `url` is found before its work goes to that volume's queue: the projects folder
    /// has its own, each volume of `/Volumes` its own (named as its folder there), and the rest of the paths share one.
    /// So a disk that does not answer holds up only finding itself.
    private func resolver(for url: URL, isProjectsFolder: Bool) -> VolumeQueue {
        let components = url.standardizedFileURL.pathComponents
        let mounted = components.count > 2 && components[1] == "Volumes" ? components[2] : nil
        let key = isProjectsFolder ? "projects" : mounted.map { "/Volumes/" + $0 } ?? "/"
        return queue(key: "find:" + key, name: mounted, endsWaiting: false)
    }

    private func volumeQueue(for volume: VolumeInfo) -> VolumeQueue {
        queue(key: "volume:" + volume.uuid, name: volume.name, endsWaiting: true)
    }

    private func queue(key: String, name: String?, endsWaiting: Bool) -> VolumeQueue {
        state.withLock { state in
            if let queue = state.queues[key] { return queue }
            let queue = VolumeQueue(label: key, name: name, endsWaiting: endsWaiting)
            state.queues[key] = queue
            return queue
        }
    }

    private func enqueue(on queue: VolumeQueue, _ job: @escaping @Sendable () -> Void) {
        queue.pending.withLock { $0.reads.append(job) }
        startDraining(queue)
    }

    /// Queues `job`, the size of `identity`, unless one is waiting already.
    private func enqueueSize(of identity: PackageIdentity, on queue: VolumeQueue, _ job: @escaping @Sendable () -> Void) {
        let added = queue.pending.withLock { pending in
            guard pending.sizeKeys.insert(identity).inserted else { return false }
            pending.sizes.append((identity, job))
            return true
        }
        if added { startDraining(queue) }
    }

    private func startDraining(_ queue: VolumeQueue) {
        let start = queue.pending.withLock { pending in
            guard !pending.isDraining else { return false }
            pending.isDraining = true
            return true
        }
        if start { queue.queue.async { self.drain(queue) } }
    }

    /// Runs the jobs of `queue`, reads first, until none is left or only sizes are and something is being recorded
    /// (then it asks again every `recordingRecheck`).
    private func drain(_ queue: VolumeQueue) {
        enum Next {
            case job(@Sendable () -> Void)
            case sizes
            case idle
        }
        while true {
            let next = queue.pending.withLock { pending -> Next in
                if !pending.reads.isEmpty { return .job(pending.reads.removeFirst()) }
                if pending.sizes.isEmpty {
                    pending.isDraining = false
                    return .idle
                }
                return .sizes
            }
            switch next {
            case .job(let job):
                job()
            case .idle:
                endWaiting(queue)
                return
            case .sizes:
                if isRecording() {
                    let (paused, recheck) = queue.pending.withLock { pending -> (Bool, Bool) in
                        guard pending.reads.isEmpty else { return (false, false) }
                        pending.isDraining = false
                        defer { pending.isRecheckScheduled = true }
                        return (true, !pending.isRecheckScheduled)
                    }
                    guard paused else { continue }
                    if recheck {
                        queue.queue.asyncAfter(deadline: .now() + Self.recordingRecheck.dispatchInterval) {
                            queue.pending.withLock { $0.isRecheckScheduled = false }
                            self.startDraining(queue)
                        }
                    }
                    endWaiting(queue)
                    return
                }
                let job = queue.pending.withLock { pending -> (@Sendable () -> Void)? in
                    guard !pending.sizes.isEmpty else { return nil }
                    let (identity, job) = pending.sizes.removeFirst()
                    pending.sizeKeys.remove(identity)
                    return job
                }
                job?()
            }
        }
    }

    // MARK: - Slow disks

    /// Runs `body`, an access to the disk of `queue`, timing it: past `slowAccess` (while it lasts, if the disk's name
    /// is known, or when it ends) the disk is `.waiting`; one that ends sooner ends the wait.
    fileprivate func timed<T>(_ queue: VolumeQueue, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let arm = queue.pending.withLock { pending -> Bool in
            pending.accesses += 1
            pending.access = (pending.accesses, start)
            guard queue.name != nil, !pending.isCheckArmed else { return false }
            pending.isCheckArmed = true
            return true
        }
        if arm { armCheck(queue, from: start) }
        defer {
            queue.pending.withLock { $0.access = nil }
            if start.duration(to: .now) >= Self.slowAccess {
                startWaiting(named: queue.name)
            } else {
                endWaiting(queue)
            }
        }
        return try body()
    }

    /// Looks, `slowAccess` after `start`, at the access under way on `queue`.
    private func armCheck(_ queue: VolumeQueue, from start: ContinuousClock.Instant) {
        let delay = max(.zero, Self.slowAccess - start.duration(to: .now))
        watchdog.asyncAfter(deadline: .now() + delay.dispatchInterval) {
            enum Verdict {
                case slow
                case later(ContinuousClock.Instant)
                case done
            }
            let verdict = queue.pending.withLock { pending -> Verdict in
                guard let access = pending.access else {
                    pending.isCheckArmed = false
                    return .done
                }
                guard access.start.duration(to: .now) >= Self.slowAccess else { return .later(access.start) }
                pending.isCheckArmed = false
                return .slow
            }
            switch verdict {
            case .slow: self.startWaiting(named: queue.name)
            case .later(let start): self.armCheck(queue, from: start)
            case .done: break
            }
        }
    }

    /// Whether `error` says nothing is there: `ENOENT`, `ENOTDIR` (a folder on the way is not one) or Foundation's "no
    /// such file", itself or as its underlying error (as `ProjectReader` tells a missing package).
    private static func isMissing(_ error: any Error) -> Bool {
        var error: NSError? = error as NSError
        while let current = error {
            if current.domain == NSPOSIXErrorDomain { return current.code == Int(ENOENT) || current.code == Int(ENOTDIR) }
            if current.domain == NSCocoaErrorDomain,
                [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(current.code)
            {
                return true
            }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func startWaiting(named name: String?) {
        guard let name else { return }
        state.withLock { state in
            guard state.waiting.insert(name).inserted else { return }
            notices.async { self.onUpdate(.waiting(volume: name)) }
        }
    }

    /// Ends the wait of `queue`'s disk, if it is a volume's queue (finding a volume never ends it: the volume's queue
    /// goes on with the same disk).
    private func endWaiting(_ queue: VolumeQueue) {
        if queue.endsWaiting { endWaiting(named: queue.name) }
    }

    private func endWaiting(named name: String?) {
        guard let name else { return }
        state.withLock { state in
            guard state.waiting.remove(name) != nil else { return }
            notices.async { self.onUpdate(.waitingEnded(volume: name)) }
        }
    }
}

/// A serial queue for one volume (or for finding volumes before their work goes to theirs): one access to that disk at
/// a time, reads before sizes.
private final class VolumeQueue: Sendable {
    struct Pending {
        var reads: [@Sendable () -> Void] = []
        var sizes: [(PackageIdentity, @Sendable () -> Void)] = []
        var sizeKeys: Set<PackageIdentity> = []
        var isDraining = false
        var isRecheckScheduled = false
        /// The access under way, by number, and when it began.
        var access: (number: Int, start: ContinuousClock.Instant)?
        var accesses = 0
        /// A check of the access under way is due.
        var isCheckArmed = false
    }

    /// The disk's name for `.waiting`, if known.
    let name: String?
    /// A volume's queue ends the wait of its disk; a queue that finds volumes does not.
    let endsWaiting: Bool
    let queue: DispatchQueue
    let pending = Mutex(Pending())

    init(label: String, name: String?, endsWaiting: Bool) {
        self.name = name
        self.endsWaiting = endsWaiting
        queue = DispatchQueue(label: "dev.toma.Toma.LibraryScanner." + label, qos: .utility)
    }
}

/// `base`, with every access timed on `queue`; the volume of the one URL `resolved` names is answered without asking
/// the disk again.
private struct TimedFileSystem: LibraryFileSystem {
    let base: any LibraryFileSystem
    let scanner: LibraryScanner
    let queue: VolumeQueue
    var resolved: (path: String, volume: VolumeInfo)?

    func list(_ directory: URL) throws -> [URL] {
        try scanner.timed(queue) { try base.list(directory) }
    }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        try scanner.timed(queue) { try base.stat(url, withAddedDate: withAddedDate) }
    }

    func volume(of url: URL) throws -> VolumeInfo {
        if let resolved, url.standardizedFileURL.path == resolved.path { return resolved.volume }
        return try scanner.timed(queue) { try base.volume(of: url) }
    }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        try scanner.timed(queue) { try base.read(url, maxBytes: maxBytes) }
    }

    func allocatedSize(of package: URL) throws -> Int64 {
        try scanner.timed(queue) { try base.allocatedSize(of: package) }
    }

    func freeSpace(of url: URL) throws -> Int64 {
        try scanner.timed(queue) { try base.freeSpace(of: url) }
    }
}

/// How the library tells packages, hidden items and the trash by name.
enum PackageNames {
    /// `<name>.toma`, in any case, as Finder takes it.
    static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return name.count > ext.count + 1 && ext.caseInsensitiveCompare(ProjectPackage.fileExtension) == .orderedSame
    }

    /// A name that starts with a dot: a hidden item, never listed (a deletion or a duplicate under way among them).
    static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    /// `Trash` (`ProjectTrash.folderName`), in any case, as the volume takes it.
    static func isTrash(_ name: String) -> Bool {
        name.caseInsensitiveCompare("Trash") == .orderedSame
    }
}

extension VolumeInfo {
    /// A disk inside the Mac, local and not synced: the only kind the library looks at by itself (design §6.5, §6.8).
    var isLookedAtAlone: Bool { isInternal && !isRemovable && !isNetwork && !isSynced }
    /// Neither on the network nor synced: sizes may be summed there (design §6.5: nothing that would download).
    var readsSizes: Bool { !isNetwork && !isSynced }
}

extension ProjectState {
    fileprivate var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
