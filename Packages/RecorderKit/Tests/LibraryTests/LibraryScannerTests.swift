// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import Library
import ProjectFormat
import RecorderKitTestSupport

/// Every update a scanner gave, in order, with when it arrived.
private final class Updates: Sendable {
    struct Arrival: Sendable {
        var update: LibraryUpdate
        var at: ContinuousClock.Instant
    }

    private let log = Mutex<[Arrival]>([])

    func append(_ update: LibraryUpdate) {
        log.withLock { $0.append(Arrival(update: update, at: .now)) }
    }

    var arrivals: [Arrival] { log.withLock { $0 } }
    var all: [LibraryUpdate] { arrivals.map(\.update) }

    /// What the updates so far say of each project: the last summary of each identity, unless removed after it.
    var current: [PackageIdentity: ProjectSummary] {
        var projects: [PackageIdentity: ProjectSummary] = [:]
        for update in all {
            switch update {
            case .summary(let summary): projects[summary.identity] = summary
            case .removed(let identity): projects[identity] = nil
            default: break
            }
        }
        return projects
    }

    /// The current summary of the package at `url`.
    func project(at url: URL) -> ProjectSummary? {
        current.values.first { $0.path == url.path }
    }

    var summaries: [ProjectSummary] {
        all.compactMap { if case .summary(let summary) = $0 { summary } else { nil } }
    }

    var removed: [PackageIdentity] {
        all.compactMap { if case .removed(let identity) = $0 { identity } else { nil } }
    }

    var finishedCount: Int { all.filter { $0 == .finished }.count }

    func reset() {
        log.withLock { $0 = [] }
    }

    /// Waits until `condition` holds of the updates so far, for at most `timeout`.
    func wait(timeout: Duration = .seconds(20), until condition: @escaping ([LibraryUpdate]) -> Bool) async -> Bool {
        await eventually(timeout: timeout) { condition(self.all) }
    }

    /// Waits for `count` `.finished` in all.
    func waitForFinished(_ count: Int = 1, timeout: Duration = .seconds(20)) async -> Bool {
        await wait(timeout: timeout) { updates in updates.filter { $0 == .finished }.count >= count }
    }
}

/// `EditSession`'s `readDocument`, which writes down every package it is asked for.
private final class DocumentReads: Sendable {
    private let context: EditContext
    private let log = Mutex<[URL]>([])

    init(context: EditContext) {
        self.context = context
    }

    var calls: [URL] { log.withLock { $0 } }

    func reset() {
        log.withLock { $0 = [] }
    }

    func read(_ url: URL) throws -> (LoadedProject, EditDocument, Int) {
        log.withLock { $0.append(url) }
        let (project, document, version) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
        return (project, document, version)
    }
}

/// A lock probe that answers "not held" and counts how many times it was asked.
private final class LockProbes: Sendable {
    private let count = Mutex(0)

    var calls: Int { count.withLock { $0 } }

    func isHeld(_ url: URL) -> Bool {
        count.withLock { $0 += 1 }
        return false
    }
}

/// A flag the test sets and the scanner reads.
private final class Flag: Sendable {
    private let value: Mutex<Bool>

    init(_ value: Bool) {
        self.value = Mutex(value)
    }

    var isOn: Bool { value.withLock { $0 } }

    func set(_ on: Bool) {
        value.withLock { $0 = on }
    }
}

/// A file system that answers as the disk does, except that every access at or under one of `failing` throws `EIO`, as a
/// disk that fails for a moment; its volume is still told (the system knows it without reading the disk).
private final class FailingFileSystem: LibraryFileSystem {
    private let base = SystemFileSystem()
    private let failing = Mutex<[String]>([])

    func fail(under paths: [URL]) {
        failing.withLock { $0 = paths.map(\.path) }
    }

    private func check(_ url: URL) throws {
        let path = url.path
        if failing.withLock({ $0.contains { path == $0 || path.hasPrefix($0 + "/") } }) { throw POSIXError(.EIO) }
    }

    func list(_ directory: URL) throws -> [URL] {
        try check(directory)
        return try base.list(directory)
    }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        try check(url)
        return try base.stat(url, withAddedDate: withAddedDate)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }

    func freeSpace(of url: URL) throws -> Int64 {
        try check(url)
        return try base.freeSpace(of: url)
    }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        try check(url)
        return try base.read(url, maxBytes: maxBytes)
    }

    func allocatedSize(of package: URL) throws -> Int64 {
        try check(package)
        return try base.allocatedSize(of: package)
    }
}

/// What the tests of this file share.
private enum Scan {
    static let app = AppInfo(name: "Toma", version: "0.3.0")
    static let now = Date(timeIntervalSince1970: 1_794_800_000)

    static func context(_ dir: URL) -> EditContext {
        EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: .toma,
            now: { now }, makeID: { $0 + "00000001" })
    }

    /// `<dir>/<name>/`, made.
    static func folder(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func scanner(
        projects: URL, in dir: URL, fileSystem: any LibraryFileSystem = SystemFileSystem(), reads: DocumentReads? = nil,
        locks: LockProbes = LockProbes(), isRecording: Flag = Flag(false), updates: Updates
    ) -> LibraryScanner {
        let reads = reads ?? DocumentReads(context: context(dir))
        return LibraryScanner(
            projectsFolder: projects, fileSystem: fileSystem, readDocument: reads.read, isLockHeld: locks.isHeld,
            context: context(dir), isRecording: { isRecording.isOn }, onUpdate: updates.append)
    }

    /// Whether `state` is `.needsRepair`, for any reason.
    static func needsRepair(_ state: ProjectState) -> Bool {
        if case .needsRepair = state { return true }
        return false
    }

    /// The URL `url` is, as a folder.
    static func folderURL(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The index the updates so far make.
    static func index(of updates: Updates) -> LibraryIndex {
        LibraryIndex(projects: updates.current.values.sorted { $0.path < $1.path })
    }
}

/// Runs `body`, and if it is still running after `delay`, opens each FIFO of `fifos` for writing once and closes it: a
/// read blocked on one gets its end, so a regression fails the test instead of hanging the run.
private func unblocking<T>(
    _ fifos: [URL], after delay: Duration = .seconds(5), _ body: () async throws -> T
) async rethrows -> T {
    let release = DispatchWorkItem {
        for fifo in fifos {
            let fd = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 { close(fd) }
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delay.components.seconds * 1000)), execute: release)
    defer { release.cancel() }
    return try await body()
}

@Suite struct LibraryScannerTests {
    @Test func everyKindOfFolderIsListed() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(
                in: projects,
                kinds: [
                    .v1, .v2, .v3, .from1b, .unfinished, .needsRepair, .symlinkedPackage, .fifoManifest, .hugeManifest,
                    .fifoEvents, .symlinkedEvents, .synthetic(count: 2),
                ])
            let fifos = [
                ProjectPackage(url: urls[7]).manifestURL, ProjectPackage(url: urls[9]).eventsURL(take: LibraryFixtures.take),
            ]
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, updates: updates)

            try await unblocking(fifos) {
                scanner.reconcile(from: LibraryIndex())
                #expect(await updates.waitForFinished())

                // One summary per package, the link left out (and what it points to, in a hidden folder).
                let listed = urls.filter { $0.lastPathComponent != "linked.toma" }
                #expect(Set(updates.current.values.map(\.path)) == Set(listed.map(\.path)))
                #expect(updates.removed.isEmpty)
                #expect(updates.all.last { if case .progress = $0 { true } else { false } } == .progress(found: listed.count))
                func state(_ name: String) throws -> ProjectState {
                    try #require(updates.current.values.first { $0.name == name }, "\(name)").state
                }
                for name in ["v1", "v2", "v3", "from1b", "Synthetic 0001", "Synthetic 0002"] {
                    #expect(try state(name) == .normal, "\(name)")
                }
                #expect(try state("unfinished") == .unfinished)
                for name in ["needs-repair", "fifo-manifest", "huge-manifest", "fifo-events", "linked-events"] {
                    #expect(Scan.needsRepair(try state(name)), "\(name)")
                }
                for summary in updates.current.values {
                    #expect(summary.place == .projectsFolder(subfolder: ""), "\(summary.name)")
                }

                // The FIFO never holds the look up: best of three, as the other tests load the Mac.
                let clock = ContinuousClock()
                var times: [Duration] = []
                for _ in 0..<3 {
                    updates.reset()
                    let start = clock.now
                    scanner.look(at: [urls[7]])
                    #expect(await updates.wait { $0.contains { if case .summary = $0 { true } else { false } } })
                    times.append(start.duration(to: try #require(updates.arrivals.first).at))
                }
                #expect(try #require(times.min()) < .milliseconds(100), "\(times)")
                #expect(Scan.needsRepair(try #require(updates.project(at: urls[7])).state))
            }
        }
    }

    @Test func symlinkedPackageIsNotListed() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.symlinkedPackage, .v3])
            let link = urls[0]
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            let counting = CountingFileSystem()
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, updates: updates)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())
            // Asked again, by name.
            scanner.look(at: [link, urls[1]])
            #expect(await updates.wait { $0.filter { if case .summary = $0 { true } else { false } }.count >= 2 })

            #expect(updates.current.values.map(\.path) == [urls[1].path])
            #expect(updates.summaries.allSatisfy { $0.path == urls[1].path })
            // Nothing in it nor where it points was touched: only the link itself.
            let touched = counting.accesses.map(\.url.path)
            #expect(!touched.contains { $0.hasPrefix(link.path + "/") || $0.hasPrefix(target) })
            #expect(!touched.contains { $0.contains("/.targets") })
        }
    }

    @Test func fifthLevelIsNotListed() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let fourth = try Scan.folder("a/b/c/d", in: projects)
            let fifth = try Scan.folder("a/b/c/d/e", in: projects)
            let four = try #require(try await LibraryFixtures.folder(in: fourth, kinds: [.synthetic(count: 1)]).first)
            let five = try #require(try await LibraryFixtures.folder(in: fifth, kinds: [.synthetic(count: 1)]).first)
            let counting = CountingFileSystem()
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, updates: updates)
            #expect(LibraryScanner.maxDepth == 4)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())
            #expect(updates.current.values.map(\.path) == [four.path])
            #expect(updates.project(at: four)?.place == .projectsFolder(subfolder: "a/b/c/d"))
            // The fifth level is not even listed.
            #expect(!counting.urls(of: .list).contains { $0.path == fifth.path })
            #expect(!counting.accesses.contains { $0.url.path.hasPrefix(fifth.path) })

            // Nor shown when asked about it (a change the watcher saw, say).
            scanner.look(at: [five, fifth, four])
            #expect(await updates.wait { $0.filter { if case .summary = $0 { true } else { false } }.count >= 2 })
            try await Task.sleep(for: .milliseconds(200))
            #expect(updates.current.values.map(\.path) == [four.path])
            #expect(!counting.accesses.contains { $0.url.path.hasPrefix(fifth.path) })
        }
    }

    @Test func trashAndHiddenAreApart() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let trash = try Scan.folder("Trash", in: projects)
            let trashed = try #require(try await LibraryFixtures.folder(in: trash, kinds: [.v3]).first)
            let hidden = try Scan.folder(".oculta", in: projects)
            let inHidden = try #require(try await LibraryFixtures.folder(in: hidden, kinds: [.v3]).first)
            // A folder in the trash is not walked, and a hidden package in it (a deletion under way) is not listed.
            let inTrashFolder = try Scan.folder("Trash/sub", in: projects)
            let deeper = try #require(try await LibraryFixtures.folder(in: inTrashFolder, kinds: [.synthetic(count: 1)]).first)
            let deleting = trash.appending(path: ".deleting-1234.toma", directoryHint: .isDirectory)
            try FileManager.default.moveItem(
                at: try #require(try await LibraryFixtures.folder(in: dir, kinds: [.synthetic(count: 1)]).first), to: deleting)
            let normal = try #require(try await LibraryFixtures.folder(in: projects, kinds: [.v1]).first)
            let counting = CountingFileSystem()
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, updates: updates)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())

            #expect(Set(updates.current.values.map(\.path)) == [trashed.path, normal.path])
            let inTrash = try #require(updates.project(at: trashed))
            #expect(inTrash.place == .trash)
            let added = try #require(try SystemFileSystem().stat(trashed).addedToDirectory)
            #expect(inTrash.state == .inTrash(since: added.roundedToWholeSeconds))
            #expect(updates.project(at: normal)?.place == .projectsFolder(subfolder: ""))
            for skipped in [hidden, inTrashFolder, deeper, deleting, inHidden] {
                #expect(!counting.accesses.contains { $0.url.path.hasPrefix(skipped.path) }, "\(skipped.lastPathComponent)")
            }
        }
    }

    @Test func reconcilingRereadsOnlyWhatChanged() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.synthetic(count: 1000)])
            let first = Updates()
            let firstReads = DocumentReads(context: Scan.context(dir))
            Scan.scanner(projects: projects, in: dir, reads: firstReads, updates: first).reconcile(from: LibraryIndex())
            #expect(await first.waitForFinished(timeout: .seconds(60)))
            #expect(firstReads.calls.count == 1000)
            let index = Scan.index(of: first)
            #expect(index.projects.count == 1000)

            // A snapshot of its own document, written as the editor writes one.
            let changed = urls[417]
            let (_, document, _) = try EditSession.readDocumentWithDiskVersion(changed, take: nil, context: Scan.context(dir))
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: ProjectPackage(url: changed).editURL)

            let second = Updates()
            let reads = DocumentReads(context: Scan.context(dir))
            Scan.scanner(projects: projects, in: dir, reads: reads, updates: second).reconcile(from: index)
            #expect(await second.waitForFinished(timeout: .seconds(60)))
            #expect(reads.calls == [changed])
            let reread = second.summaries.filter { $0.size == nil || $0.path == changed.path }
            #expect(Set(reread.map(\.path)) == [changed.path])
            #expect(second.removed.isEmpty)
            #expect(second.summaries.first { $0.path == changed.path }?.edit != nil)
        }
    }

    @Test func reconcilingNeverProbesALock() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.v3, .from1b, .unfinished])
            // Locks held as an editor and a recorder hold them.
            let info = RecordingLockInfo(pid: getpid(), bootSessionUUID: "test", startedAt: Scan.now)
            var held: [HeldRecordingLock] = []
            for url in urls {
                let package = ProjectPackage(url: url)
                held.append(try RecordingLock.acquire(at: package.editLockURL, info: info))
                held.append(try RecordingLock.acquire(at: package.lockURL(take: LibraryFixtures.take), info: info))
            }
            defer { held.forEach { $0.release() } }
            let counting = CountingFileSystem()
            let locks = LockProbes()
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, locks: locks, updates: updates)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())
            scanner.look(at: urls)
            scanner.accountSizes(of: Array(updates.current.keys))
            #expect(await updates.wait { _ in updates.current.values.filter { $0.size != nil }.count == urls.count })
            try await Task.sleep(for: .milliseconds(200))

            #expect(updates.current.count == urls.count)
            #expect(locks.calls == 0)
            let packages = urls.map(ProjectPackage.init)
            let lockFiles = Set(packages.flatMap { [$0.editLockURL.path, $0.lockURL(take: LibraryFixtures.take).path] })
            #expect(!counting.accesses.contains { lockFiles.contains($0.url.path) })
            // Only the projects folder, the packages themselves and their three files; never inside `takes/`.
            let allowed = Set(
                [projects.path] + packages.flatMap { [$0.url.path, $0.manifestURL.path, $0.editURL.path, $0.editLogURL.path] })
            #expect(counting.accesses.filter { !allowed.contains($0.url.path) }.map(\.url.path) == [])
        }
    }

    @Test func removableProjectsFolderIsNotLookedAtAlone() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.v3, .synthetic(count: 2)])
            let kinds: [(String, VolumeInfo)] = [
                ("removable", DelayingFileSystem.volumeInfo(uuid: "USB", name: "USB", isInternal: false, isRemovable: true)),
                ("network", DelayingFileSystem.volumeInfo(uuid: "NAS", name: "NAS", isInternal: false, isNetwork: true)),
                ("synced", DelayingFileSystem.volumeInfo(uuid: "CLOUD", name: "Cloud", isSynced: true)),
                ("external", DelayingFileSystem.volumeInfo(uuid: "EXT", name: "External", isInternal: false)),
            ]
            for (kind, info) in kinds {
                let volume = DelayingFileSystem(volumes: [.init(root: projects, info: info)])
                // What a scan saw on that disk before.
                let index = LibraryIndex(
                    projects: urls.map { url in
                        ProjectReader.summary(
                            of: url, place: .projectsFolder(subfolder: ""), fileSystem: volume, context: Scan.context(dir),
                            now: Scan.now)
                    })
                let counting = CountingFileSystem(base: volume)
                let updates = Updates()
                let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, updates: updates)
                scanner.reconcile(from: index)
                #expect(await updates.waitForFinished(), "\(kind)")
                scanner.accountSizes(of: index.projects.map(\.identity))
                try await Task.sleep(for: .milliseconds(200))
                // Only where the folder is; no package, not even a listing.
                #expect(counting.accesses.allSatisfy { $0.operation == .volume && $0.url.path == projects.path }, "\(kind)")
                #expect(updates.all == [.finished], "\(kind)")

                // An action of the user on one project looks at that one.
                let asked = urls[1]
                scanner.look(at: [asked])
                #expect(await updates.wait { $0.contains { if case .summary = $0 { true } else { false } } }, "\(kind)")
                try await Task.sleep(for: .milliseconds(200))
                let package = ProjectPackage(url: asked)
                let allowed = Set(
                    [projects.path, asked.path, package.manifestURL.path, package.editURL.path, package.editLogURL.path])
                #expect(counting.accesses.filter { !allowed.contains($0.url.path) }.map(\.url.path) == [], "\(kind)")
                #expect(updates.project(at: asked)?.identity.volume == info.uuid, "\(kind)")
                #expect(updates.removed.isEmpty, "\(kind)")
            }
        }
    }

    @Test func syncedLocationsNeverReadMedia() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            for (kind, info) in [
                ("synced", DelayingFileSystem.volumeInfo(uuid: "CLOUD", name: "iCloud Drive", isSynced: true)),
                ("network", DelayingFileSystem.volumeInfo(uuid: "NAS", name: "NAS", isInternal: false, isNetwork: true)),
            ] {
                let place = try Scan.folder(kind, in: dir)
                let urls = try await LibraryFixtures.folder(in: place, kinds: [.v1, .v2, .v3, .from1b])
                let packages = urls.map(ProjectPackage.init)
                var allowed = Set(packages.flatMap { [$0.url, $0.manifestURL, $0.editURL, $0.editLogURL].map(\.path) })
                // Everything else in the takes cannot be opened, nor looked at in its folder: a read would fail.
                var locked: [URL] = []
                for package in packages {
                    let takes = try FileManager.default.contentsOfDirectory(at: package.takesURL, includingPropertiesForKeys: nil)
                    for take in takes {
                        allowed.insert(package.eventsURL(take: take.lastPathComponent).path)
                        for item in try FileManager.default.contentsOfDirectory(at: take, includingPropertiesForKeys: nil)
                        where item.lastPathComponent != "events.jsonl" {
                            locked.append(item)
                        }
                    }
                }
                for item in locked { #expect(chmod(item.path, 0) == 0) }
                defer { for item in locked { chmod(item.path, 0o755) } }

                let counting = CountingFileSystem(base: DelayingFileSystem(volumes: [.init(root: place, info: info)]))
                let reads = DocumentReads(context: Scan.context(dir))
                let updates = Updates()
                let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: counting, reads: reads, updates: updates)
                scanner.look(at: urls)
                #expect(await updates.wait { _ in updates.current.count == urls.count }, "\(kind)")
                try await Task.sleep(for: .milliseconds(300))

                for url in urls {
                    let summary = try #require(updates.project(at: url), "\(kind) \(url.lastPathComponent)")
                    #expect(summary.state == .normal, "\(kind) \(url.lastPathComponent): \(summary.state)")
                    #expect(summary.place == .elsewhere)
                    #expect(summary.outputSeconds != nil && summary.size == nil)
                }
                #expect(counting.urls(of: .allocatedSize).isEmpty, "\(kind)")
                #expect(counting.urls(of: .read).map(\.path).sorted() == packages.map(\.manifestURL.path).sorted(), "\(kind)")
                #expect(counting.accesses.filter { !allowed.contains($0.url.path) }.map(\.url.path) == [], "\(kind)")
                #expect(reads.calls.map(\.path).sorted() == urls.map(\.path).sorted(), "\(kind)")
            }
        }
    }

    @MainActor @Test func slowVolumeDelaysOnlyItsCards() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Fast", in: dir)
            let fast = try await LibraryFixtures.folder(in: projects, kinds: [.synthetic(count: 2)])
            let slowFolder = try Scan.folder("Slow", in: dir)
            let slow = try await LibraryFixtures.folder(in: slowFolder, kinds: [.synthetic(count: 1)])
            let fileSystem = DelayingFileSystem(volumes: [
                .init(root: projects, info: DelayingFileSystem.volumeInfo(uuid: "FAST", name: "Fast")),
                .init(
                    root: slowFolder,
                    info: DelayingFileSystem.volumeInfo(uuid: "SLOW", name: "Slow", isInternal: false, isNetwork: true),
                    delay: .seconds(2)),
            ])
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: fileSystem, updates: updates)
            let clock = ContinuousClock()

            // The slow disk first, then the fast one; neither call waits for a disk.
            let start = clock.now
            scanner.look(at: slow)
            scanner.reconcile(from: LibraryIndex())
            #expect(start.duration(to: clock.now) < .milliseconds(50))

            // The main thread keeps running while the disks answer.
            var longestGap = Duration.zero
            var last = clock.now
            var fastArrived: ContinuousClock.Instant?
            while !updates.all.contains(.waitingEnded(volume: "Slow")), start.duration(to: clock.now) < .seconds(40) {
                try await Task.sleep(for: .milliseconds(5))
                longestGap = max(longestGap, last.duration(to: clock.now))
                last = clock.now
                if fastArrived == nil, fast.allSatisfy({ updates.project(at: $0) != nil }) {
                    fastArrived = updates.arrivals.last { if case .summary = $0.update { true } else { false } }?.at
                }
            }
            #expect(longestGap < .milliseconds(500), "\(longestGap)")
            let fastTime = start.duration(to: try #require(fastArrived))
            #expect(fastTime < .milliseconds(200), "\(fastTime)")
            #expect(updates.all.contains(.waiting(volume: "Slow")))
            #expect(!updates.all.contains(.waiting(volume: "Fast")))
            #expect(updates.all.contains(.waitingEnded(volume: "Slow")))
            let waiting = try #require(updates.all.firstIndex(of: .waiting(volume: "Slow")))
            let ended = try #require(updates.all.lastIndex(of: .waitingEnded(volume: "Slow")))
            #expect(waiting < ended)
            // The slow card came, after the wait.
            let slowCard = try #require(updates.project(at: slow[0]))
            #expect(slowCard.state == .normal && slowCard.identity.volume == "SLOW")
        }
    }

    @Test func readsKeepGoingWhileRecording() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.v3, .from1b, .synthetic(count: 3)])
            let recording = Flag(true)
            let counting = CountingFileSystem()
            let updates = Updates()
            let scanner = Scan.scanner(
                projects: projects, in: dir, fileSystem: counting, isRecording: recording, updates: updates)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())
            #expect(updates.current.count == urls.count)
            #expect(updates.current.values.allSatisfy { $0.state == .normal && $0.outputSeconds != nil })
            scanner.look(at: [urls[0]])
            scanner.accountSizes(of: Array(updates.current.keys))
            #expect(await updates.wait { $0.filter { if case .summary = $0 { true } else { false } }.count > urls.count })
            // Sizes are heavy work: they wait for the take to end.
            try await Task.sleep(for: .seconds(1.5))
            #expect(counting.urls(of: .allocatedSize).isEmpty)
            #expect(updates.current.values.allSatisfy { $0.size == nil })

            recording.set(false)
            #expect(await updates.wait { _ in updates.current.values.allSatisfy { ($0.size ?? 0) > 0 } })
            let size = try #require(updates.project(at: urls[0])?.size)
            #expect(size == (try SystemFileSystem().allocatedSize(of: urls[0])))
        }
    }

    @Test func lookFollowsRenamesAndRemovals() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let a = try #require(try await LibraryFixtures.folder(in: projects, kinds: [.v3]).first)
            let clients = try Scan.folder("Clientes", in: projects)
            let b = try #require(try await LibraryFixtures.folder(in: clients, kinds: [.synthetic(count: 1)]).first)
            let elsewhere = try Scan.folder("Elsewhere", in: dir)
            let c = try #require(try await LibraryFixtures.folder(in: elsewhere, kinds: [.v1]).first)
            let updates = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, updates: updates)

            scanner.reconcile(from: LibraryIndex())
            #expect(await updates.waitForFinished())
            scanner.look(at: [c])
            #expect(await updates.wait { _ in updates.project(at: c) != nil })
            let idA = try #require(updates.project(at: a)).identity
            let idB = try #require(updates.project(at: b)).identity
            let idC = try #require(updates.project(at: c)).identity
            #expect(updates.project(at: c)?.place == .elsewhere)

            // Renamed in Finder: the old and the new path come together.
            let a2 = projects.appending(path: "Renamed.toma", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: a, to: a2)
            scanner.look(at: [a, a2])
            #expect(await updates.wait { _ in updates.project(at: a2) != nil })
            #expect(updates.project(at: a2)?.identity == idA)
            #expect(updates.project(at: a2)?.name == "Renamed")

            // A folder renamed: its projects follow it.
            let renamedClients = projects.appending(path: "Clients", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: clients, to: renamedClients)
            scanner.look(at: [clients, renamedClients])
            let b2 = renamedClients.appending(path: b.lastPathComponent, directoryHint: .isDirectory)
            #expect(await updates.wait { _ in updates.project(at: b2) != nil })
            #expect(updates.project(at: b2)?.identity == idB)
            #expect(updates.project(at: b2)?.place == .projectsFolder(subfolder: "Clients"))
            #expect(updates.removed.isEmpty)

            // Deleted: it goes.
            try FileManager.default.removeItem(at: a2)
            scanner.look(at: [a2])
            #expect(await updates.wait { $0.contains(.removed(idA)) })

            // One of Other places that is gone stays, unavailable.
            try FileManager.default.removeItem(at: c)
            scanner.look(at: [c])
            #expect(await updates.wait { _ in updates.current[idC]?.state == .unavailable(.notFound) })
            #expect(!updates.removed.contains(idC))
            #expect(Set(updates.current.keys) == [idB, idC])
        }
    }

    @Test func aFailingDiskNeverMakesAProjectGone() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try Scan.folder("Projects", in: dir)
            let loose = try #require(try await LibraryFixtures.folder(in: projects, kinds: [.v3]).first)
            let folder = try Scan.folder("Clientes", in: projects)
            let inFolder = try #require(try await LibraryFixtures.folder(in: folder, kinds: [.synthetic(count: 1)]).first)
            let other = try Scan.folder("Elsewhere", in: dir)
            let elsewhere = try #require(try await LibraryFixtures.folder(in: other, kinds: [.v1]).first)
            let fileSystem = FailingFileSystem()
            let first = Updates()
            let scanner = Scan.scanner(projects: projects, in: dir, fileSystem: fileSystem, updates: first)
            scanner.reconcile(from: LibraryIndex())
            scanner.look(at: [elsewhere])
            #expect(await first.waitForFinished())
            #expect(await first.wait { _ in first.current.count == 3 })
            let index = Scan.index(of: first)

            // The folder cannot be listed, nor the packages looked at, for a while.
            fileSystem.fail(under: [folder, loose, elsewhere])
            let updates = Updates()
            let again = Scan.scanner(projects: projects, in: dir, fileSystem: fileSystem, updates: updates)
            again.reconcile(from: index)
            #expect(await updates.waitForFinished())
            again.look(at: [loose, inFolder, folder, elsewhere])
            try await Task.sleep(for: .milliseconds(500))
            #expect(updates.removed.isEmpty)
            #expect(updates.summaries.isEmpty)

            // Once it answers, they are as they were; gone for good, they go.
            fileSystem.fail(under: [])
            try FileManager.default.removeItem(at: inFolder)
            again.look(at: [loose, folder])
            let gone = try #require(first.project(at: inFolder)).identity
            #expect(await updates.wait { $0.contains(.removed(gone)) })
            #expect(updates.project(at: loose)?.identity == first.project(at: loose)?.identity)
            #expect(updates.removed == [gone])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func reconcileAndIndexAThousand() async throws {
        let benchDir = ProcessInfo.processInfo.environment["TOMA_BENCH_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        try await withTemporaryDirectory { dir in
            // With TOMA_BENCH_DIR, that folder is the projects folder, and its index is `index.json` in it (for Task 36).
            let projects = try benchDir ?? Scan.folder("Projects", in: dir)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let existing = try FileManager.default.contentsOfDirectory(atPath: projects.path)
            try #require(existing.isEmpty, "\(projects.path) must be empty or missing")
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.synthetic(count: 1000)])
            let clock = ContinuousClock()

            let first = Updates()
            let start = clock.now
            Scan.scanner(projects: projects, in: dir, updates: first).reconcile(from: LibraryIndex())
            #expect(await first.waitForFinished(timeout: .seconds(60)))
            let indexing = start.duration(to: try #require(first.arrivals.last { $0.update == .finished }).at)
            #expect(await first.wait(timeout: .seconds(60)) { _ in first.current.values.allSatisfy { $0.size != nil } })
            let sizes = start.duration(to: try #require(first.arrivals.last).at)
            let index = Scan.index(of: first)
            #expect(index.projects.count == 1000)

            let second = Updates()
            let again = clock.now
            Scan.scanner(projects: projects, in: dir, updates: second).reconcile(from: index)
            #expect(await second.waitForFinished(timeout: .seconds(60)))
            let reconciling = again.duration(to: try #require(second.arrivals.last { $0.update == .finished }).at)
            #expect(second.summaries.isEmpty && second.removed.isEmpty)

            // What reading them costs by itself, one after the other on one thread: the floor of indexing.
            let direct = clock.measure {
                for url in urls {
                    _ = ProjectReader.summary(
                        of: url, place: .projectsFolder(subfolder: ""), fileSystem: SystemFileSystem(),
                        context: Scan.context(dir), now: Scan.now)
                }
            }

            print(
                "reconcileAndIndexAThousand: index \(indexing) (sizes summed by \(sizes)), reconcile unchanged \(reconciling), "
                    + "the same reads alone \(direct)")
            #expect(indexing <= .seconds(2))
            #expect(reconciling <= .milliseconds(400))
            if benchDir != nil {
                try DurableFile.writeAtomically(try index.encoded(), to: projects.appending(path: "index.json"))
            }
        }
    }
}
