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

/// What the tests of this file share.
private enum Reading {
    static let app = AppInfo(name: "Toma", version: "0.3.0")
    /// When the library looks, in whole seconds.
    static let now = Date(timeIntervalSince1970: 1_794_800_000)
    static let projectsFolder = Place.projectsFolder(subfolder: "")

    static func context(_ dir: URL) -> EditContext {
        EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: .toma,
            now: { now }, makeID: { $0 + "00000001" })
    }

    /// The summary of `url` in the projects folder, read from the disk with `EditSession`'s reader.
    static func summary(
        _ url: URL, in dir: URL, place: Place = projectsFolder, fileSystem: any LibraryFileSystem = SystemFileSystem()
    ) -> ProjectSummary {
        ProjectReader.summary(of: url, place: place, fileSystem: fileSystem, context: context(dir), now: now)
    }

    /// Whether `state` is `.needsRepair`, for any reason.
    static func needsRepair(_ state: ProjectState) -> Bool {
        if case .needsRepair = state { return true }
        return false
    }

    /// The media files every take of the package at `url` lists.
    static func media(of url: URL) throws -> [URL] {
        try LoadedProject.load(url).manifest.takes.flatMap(\.tracks).flatMap(\.segments).map { url.appending(path: $0.file) }
    }
}

/// The library's read of a document (`EditSession.readOutline`), which writes down every package it is asked for and
/// how many accesses `fileSystem` had seen by then.
private final class CountingReader: Sendable {
    struct Call: Equatable, Sendable {
        var url: URL
        var accessesBefore: Int
    }

    private let context: EditContext
    private let fileSystem: CountingFileSystem?
    private let log = Mutex<[Call]>([])

    init(context: EditContext, fileSystem: CountingFileSystem? = nil) {
        self.context = context
        self.fileSystem = fileSystem
    }

    var calls: [Call] { log.withLock { $0 } }

    func read(_ url: URL) throws -> (LoadedProject, DocumentOutline) {
        let accesses = fileSystem?.accesses.count ?? 0
        log.withLock { $0.append(Call(url: url, accessesBefore: accesses)) }
        return try EditSession.readOutline(url, take: nil, context: context)
    }
}

/// A file system that answers as the disk does and writes down the limit of every `read`.
private final class LimitRecordingFileSystem: LibraryFileSystem {
    struct Read: Equatable, Sendable {
        var url: URL
        var maxBytes: Int
    }

    private let base = SystemFileSystem()
    private let log = Mutex<[Read]>([])

    var reads: [Read] { log.withLock { $0 } }

    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat { try base.stat(url, withAddedDate: withAddedDate) }
    func volume(of url: URL) throws -> VolumeInfo { try base.volume(of: url) }
    func freeSpace(of url: URL) throws -> Int64 { try base.freeSpace(of: url) }
    func allocatedSize(of package: URL) throws -> Int64 { try base.allocatedSize(of: package) }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        log.withLock { $0.append(Read(url: url, maxBytes: maxBytes)) }
        return try base.read(url, maxBytes: maxBytes)
    }
}

/// The disk, except that `call` on `url` throws `error`. Nothing in it changes once it is made.
private final class FailingFileSystem: LibraryFileSystem, @unchecked Sendable {
    enum Call: Sendable {
        case volume, stat
    }

    let url: URL
    let call: Call
    let error: any Error
    private let base = SystemFileSystem()

    init(url: URL, call: Call, error: any Error) {
        self.url = url
        self.call = call
        self.error = error
    }

    func list(_ directory: URL) throws -> [URL] { try base.list(directory) }
    func freeSpace(of url: URL) throws -> Int64 { try base.freeSpace(of: url) }
    func read(_ url: URL, maxBytes: Int) throws -> Data { try base.read(url, maxBytes: maxBytes) }
    func allocatedSize(of package: URL) throws -> Int64 { try base.allocatedSize(of: package) }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        if call == .stat, url == self.url { throw error }
        return try base.stat(url, withAddedDate: withAddedDate)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        if call == .volume, url == self.url { throw error }
        return try base.volume(of: url)
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
    DispatchQueue.global().asyncAfter(deadline: .now() + delay.seconds, execute: release)
    defer { release.cancel() }
    return try await body()
}

@Test func summariesOfEveryKind() async throws {
    try await withTemporaryDirectory { dir in
        let urls = try await LibraryFixtures.folder(
            in: dir, kinds: [.v1, .v2, .v3, .from1b, .unfinished, .needsRepair, .synthetic(count: 2)])
        let system = SystemFileSystem()

        let v1 = Reading.summary(urls[0], in: dir)
        #expect(v1.identity == (try PackageIdentity(of: urls[0], in: system)))
        #expect(v1.path == urls[0].path)
        #expect(v1.name == "v1")
        #expect(v1.place == Reading.projectsFolder)
        #expect(v1.recordedAt == (try LoadedProject.load(urls[0]).manifest.createdAt))
        #expect(v1.state == .normal)
        #expect(v1.formatVersion == 1)
        // A legacy document is the current version's.
        #expect(v1.documentVersion == EditDocument.currentVersion)
        #expect(abs(try #require(v1.outputSeconds) - 1) < 0.01)
        #expect(v1.aspect == .landscape)
        #expect(!v1.hasCamera)
        let manifestStat = try system.stat(ProjectPackage(url: urls[0]).manifestURL)
        #expect(v1.manifest == FileSignature(size: manifestStat.size, modified: manifestStat.modified))
        #expect(v1.edit == nil && v1.log == nil)
        // The size is summed later, the thumbnail drawn later.
        #expect(v1.size == nil && v1.thumbnailKey == nil)
        #expect(v1.lastSeen == Reading.now)

        let v2 = Reading.summary(urls[1], in: dir)
        #expect(v2.state == .normal)
        #expect(v2.formatVersion == 2)
        #expect(abs(try #require(v2.outputSeconds) - 1) < 0.01)
        #expect(v2.aspect == .landscape)
        #expect(v2.hasCamera)

        // Its edit keeps half a second in 9:16: the summary is the document's, not the take's.
        let v3 = Reading.summary(urls[2], in: dir)
        #expect(v3.state == .normal)
        #expect(v3.formatVersion == 3)
        #expect(v3.documentVersion == EditDocument.currentVersion)
        #expect(abs(try #require(v3.outputSeconds) - 0.5) < 0.01)
        #expect(v3.aspect == .portrait)
        let logStat = try system.stat(ProjectPackage(url: urls[2]).editLogURL)
        #expect(v3.log == FileSignature(size: logStat.size, modified: logStat.modified))
        #expect(v3.edit == nil)

        let from1b = Reading.summary(urls[3], in: dir)
        #expect(from1b.state == .normal)
        #expect(from1b.formatVersion == 3)
        #expect(from1b.documentVersion == 1)
        #expect(abs(try #require(from1b.outputSeconds) - 1) < 0.01)

        let unfinished = Reading.summary(urls[4], in: dir)
        #expect(unfinished.state == .unfinished)
        #expect(unfinished.formatVersion == 3)

        let unreadable = Reading.summary(urls[5], in: dir)
        #expect(unreadable.state == .needsRepair(RepairReason(part: .manifest, problem: .unreadable)))
        #expect(unreadable.manifest != nil)
        #expect(unreadable.outputSeconds == nil && unreadable.formatVersion == nil && unreadable.documentVersion == nil)

        // The first synthetic package lasts 1 s, and has the event log of a second of recording.
        let synthetic = Reading.summary(urls[6], in: dir)
        #expect(synthetic.state == .normal)
        #expect(synthetic.outputSeconds == 1)
        #expect(Reading.summary(urls[7], in: dir).outputSeconds == 2)
        #expect(try LoadedProject.load(urls[6]).events.count == 65)

        // A document of a newer version, in a package this version reads.
        let newerDocument = urls[7]
        try Data(#"{"documentVersion": 4}"#.utf8).write(to: ProjectPackage(url: newerDocument).editURL)
        let newer = Reading.summary(newerDocument, in: dir)
        #expect(newer.state == .newerVersion)
        #expect(newer.documentVersion == 4)
        #expect(newer.formatVersion == 3)

        // A package of a newer format.
        let newerFormat = dir.appending(path: "Newer format.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newerFormat, withIntermediateDirectories: false)
        try Data(#"{"formatVersion": 4, "whatever": true}"#.utf8).write(to: ProjectPackage(url: newerFormat).manifestURL)
        let newerFormatSummary = Reading.summary(newerFormat, in: dir)
        #expect(newerFormatSummary.state == .newerVersion)
        #expect(newerFormatSummary.formatVersion == 4)

        // On a volume that cannot be written to; in the trash, since it got there.
        let readOnly = DelayingFileSystem(volumes: [
            .init(root: dir, info: DelayingFileSystem.volumeInfo(uuid: "READ-ONLY", isReadOnly: true))
        ])
        let locked = Reading.summary(urls[1], in: dir, fileSystem: readOnly)
        #expect(locked.state == .readOnlyVolume)
        #expect(locked.identity.volume == "READ-ONLY")
        #expect(locked.hasCamera && locked.outputSeconds == v2.outputSeconds)
        let added = try #require(try system.stat(urls[1]).addedToDirectory)
        let trashed = Reading.summary(urls[1], in: dir, place: .trash)
        #expect(trashed.state == .inTrash(since: added.roundedToWholeSeconds))
        #expect(trashed.place == .trash)
        #expect(trashed.outputSeconds == v2.outputSeconds)

        // A package that is not there.
        let gone = Reading.summary(dir.appending(path: "Gone.toma", directoryHint: .isDirectory), in: dir)
        #expect(gone.state == .unavailable(.notFound))
        #expect(gone.name == "Gone")
    }
}

@Test func readingNeverOpensVideosNorWrites() async throws {
    try await withTemporaryDirectory { dir in
        let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v1, .v2, .v3, .from1b])
        let media = try urls.flatMap(Reading.media)
        #expect(media.count == 5)
        let before = try urls.map(treeHash)

        // Every media file of the takes cannot be opened while the library reads: one that opened it would fail.
        for file in media { #expect(chmod(file.path, 0) == 0) }
        let counting = CountingFileSystem()
        let reader = CountingReader(context: Reading.context(dir), fileSystem: counting)
        let summaries = urls.map { url in
            ProjectReader.summary(
                of: url, place: Reading.projectsFolder, fileSystem: counting, readDocument: reader.read,
                context: Reading.context(dir), now: Reading.now)
        }
        for file in media { #expect(chmod(file.path, 0o644) == 0) }

        #expect(summaries.map(\.state) == Array(repeating: .normal, count: urls.count))
        #expect(summaries.allSatisfy { $0.outputSeconds != nil })
        // The disk: each package itself, its three files, and of them only the manifest is read.
        let packages = urls.map(ProjectPackage.init)
        let allowed = Set(packages.flatMap { [$0.url, $0.manifestURL, $0.editURL, $0.editLogURL] })
        #expect(counting.accesses.filter { !allowed.contains($0.url) } == [])
        #expect(counting.urls(of: .read) == packages.map(\.manifestURL))
        #expect(counting.urls(of: .list).isEmpty && counting.urls(of: .allocatedSize).isEmpty)
        // The document: once per package, after its manifest was read.
        #expect(reader.calls.map(\.url) == urls)
        for (call, package) in zip(reader.calls, packages) {
            let earlier = counting.accesses.prefix(call.accessesBefore)
            #expect(earlier.contains(.init(operation: .read, url: package.manifestURL)), "\(package.url.lastPathComponent)")
        }
        #expect(try urls.map(treeHash) == before)
    }
}

@Test func eventsThatAreAFifoOrALinkAreRepairNotFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let urls = try await LibraryFixtures.folder(
            in: dir, kinds: [.fifoEvents, .symlinkedEvents, .fifoManifest, .symlinkedPackage])
        let take = LibraryFixtures.take
        let events = ProjectPackage(url: urls[1]).eventsURL(take: take)
        // The link points at a whole event log: followed, the project would read as normal.
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: events.path)
        #expect(try EventLogReader.read(URL(fileURLWithPath: target)).events.isEmpty == false)
        let fifos = [ProjectPackage(url: urls[0]).eventsURL(take: take), ProjectPackage(url: urls[2]).manifestURL]
        let linkedPackage = urls[3]
        let linkTarget = URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: linkedPackage.path))
        #expect(try LoadedProject.load(linkTarget).events.isEmpty == false)
        let before = try (urls.dropLast() + [linkTarget]).map(treeHash)
        let counting = CountingFileSystem()
        // Why each cannot be opened: the events or the manifest are not regular files or are links, the package is a link.
        let reasons = [
            RepairReason(part: .edit, problem: .system(EFTYPE)), RepairReason(part: .edit, problem: .system(ELOOP)),
            RepairReason(part: .manifest, problem: .system(EFTYPE)), RepairReason(part: .package, problem: .isALink),
        ]
        let expected = Dictionary(uniqueKeysWithValues: zip(urls.map(\.lastPathComponent), reasons))

        try await unblocking(fifos) {
            let clock = ContinuousClock()
            for url in urls {
                // A FIFO that blocked the read would block it for good: the best of three tells that apart from the
                // other tests' load.
                var times: [Duration] = []
                var summary: ProjectSummary?
                for _ in 0..<3 {
                    let start = clock.now
                    summary = Reading.summary(url, in: dir, fileSystem: counting)
                    times.append(start.duration(to: clock.now))
                }
                let best = try #require(times.min())
                let state = try #require(summary).state
                #expect(best < .milliseconds(100), "\(url.lastPathComponent): \(times)")
                #expect(state == expected[url.lastPathComponent].map(ProjectState.needsRepair), "\(url.lastPathComponent)")
            }
            // What the editor reads them with refuses them too, at once.
            let context = Reading.context(dir)
            #expect(throws: POSIXError(.EFTYPE)) {
                try EditSession.readDocumentWithDiskVersion(urls[0], take: nil, context: context)
            }
            #expect(throws: POSIXError(.ELOOP)) {
                try EditSession.readDocumentWithDiskVersion(urls[1], take: nil, context: context)
            }
            #expect(throws: POSIXError(.EFTYPE)) {
                try EditSession.readDocumentWithDiskVersion(urls[2], take: nil, context: context)
            }
        }
        // A package that is a link: the link itself is looked at, nothing through it.
        let throughLink = counting.accesses.filter { $0.url.path.hasPrefix(linkedPackage.path + "/") }
        #expect(throughLink == [])
        #expect(Set(counting.accesses.filter { $0.url == linkedPackage }.map(\.operation)) == [.volume, .stat])
        #expect(try (urls.dropLast() + [linkTarget]).map(treeHash) == before)
    }
}

@Test func hugeManifestIsRepairNotRead() async throws {
    try await withTemporaryDirectory { dir in
        let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.hugeManifest]).first)
        let manifest = ProjectPackage(url: url).manifestURL
        #expect(try SystemFileSystem().stat(manifest).size == 5 * 1_048_576)
        // Read whole, it is a manifest that loads: only its size makes it one to repair.
        #expect(try LoadedProject.load(url).manifest.formatVersion == 3)

        let fileSystem = LimitRecordingFileSystem()
        let reader = CountingReader(context: Reading.context(dir))
        let summary = ProjectReader.summary(
            of: url, place: Reading.projectsFolder, fileSystem: fileSystem, readDocument: reader.read,
            context: Reading.context(dir), now: Reading.now)
        #expect(summary.state == .needsRepair(RepairReason(part: .manifest, problem: .system(EFBIG))))
        #expect(fileSystem.reads == [.init(url: manifest, maxBytes: ProjectReader.maxManifestBytes)])
        #expect(ProjectReader.maxManifestBytes == 4 * 1_048_576)
        #expect(reader.calls.isEmpty)
    }
}

@Test func a1bProjectWithATrailingMigrateReadsAsV1() async throws {
    try await withTemporaryDirectory { dir in
        let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.from1b]).first)
        let log = ProjectPackage(url: url).editLogURL
        // The first edit of a 1c app cut short right after its `migrate`.
        let read = try EditLogReader.read(log)
        let seq = try #require(read.entries.last?.seq) + 1
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try EditLogEntry.migrate(seq: seq, from: 1, to: 2).jsonLine() + "\n").utf8))
        try handle.close()
        let before = try treeHash(url)

        let summary = Reading.summary(url, in: dir)
        #expect(summary.state == .normal)
        #expect(summary.documentVersion == 1)
        let legacy = EditDocument.legacy(for: try LoadedProject.load(url))
        #expect(summary.outputSeconds == TimeMap(sequence: legacy.sequence).durationSeconds)
        #expect(summary.aspect == .landscape)
        // Nothing was cut from the log: reading is not opening.
        #expect(try treeHash(url) == before)
    }
}

@Test func linkedFoldersInsideAPackageAreRepairNotFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .v3])
        let elsewhere = dir.appending(path: ".elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        // `takes/` of one, `takes/take-001/` of the other: moved out whole and linked back, so following the link would
        // read the take's whole event log.
        let linked = [
            ProjectPackage(url: urls[0]).takesURL,
            ProjectPackage(url: urls[1]).takeDirectory(LibraryFixtures.take),
        ]
        for (index, folder) in linked.enumerated() {
            let moved = elsewhere.appending(path: "\(index)", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        }
        let context = Reading.context(dir)
        for url in urls {
            let summary = Reading.summary(url, in: dir)
            #expect(summary.state == .needsRepair(RepairReason(part: .edit, problem: .system(ELOOP))), "\(url.lastPathComponent)")
            #expect(throws: POSIXError(.ELOOP), "\(url.lastPathComponent)") {
                try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
            }
        }
    }
}

@Test func onlyAMissingPackageIsNotFound() async throws {
    try await withTemporaryDirectory { dir in
        let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v1]).first)
        // Not there: no such item, or a folder on the way that is a file.
        let plain = dir.appending(path: "plain", directoryHint: .notDirectory)
        try Data().write(to: plain)
        for missing in [dir.appending(path: "Gone.toma", directoryHint: .isDirectory), plain.appending(path: "Demo.toma")] {
            #expect(Reading.summary(missing, in: dir).state == .unavailable(.notFound), "\(missing.path)")
        }
        // A disk that fails, or a folder that cannot be looked at, for a moment: the project is still there.
        let failures: [(any Error, FailingFileSystem.Call)] = [
            (POSIXError(.EIO), .stat), (POSIXError(.EACCES), .stat), (POSIXError(.ETIMEDOUT), .volume),
            (CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)]), .volume),
            (CocoaError(.fileReadUnknown), .volume),
        ]
        // Why, by the system's code; one that has none says it in English.
        let problems: [RepairReason.Problem?] = [.system(EIO), .system(EACCES), .system(ETIMEDOUT), .system(EACCES), nil]
        for ((error, call), problem) in zip(failures, problems) {
            let summary = Reading.summary(url, in: dir, fileSystem: FailingFileSystem(url: url, call: call, error: error))
            guard case .needsRepair(let reason) = summary.state else {
                Issue.record("\(error): \(summary.state)")
                continue
            }
            #expect(reason.part == .package, "\(error)")
            if let problem {
                #expect(reason.problem == problem, "\(error)")
            } else if case .other = reason.problem {
            } else {
                Issue.record("\(error): \(reason.problem)")
            }
            #expect(summary.identity.file == 0)
        }
        // Foundation's own "no such file" is not there.
        let gone = FailingFileSystem(url: url, call: .volume, error: CocoaError(.fileReadNoSuchFile))
        #expect(Reading.summary(url, in: dir, fileSystem: gone).state == .unavailable(.notFound))
    }
}

@Test func aThousandSummariesNeverAskForFreeSpace() async throws {
    try await withTemporaryDirectory { dir in
        let urls = try await LibraryFixtures.folder(in: dir, kinds: [.synthetic(count: 1_000)])
        let counting = CountingFileSystem()
        // The document is not what is counted here: one read of it stands for all.
        let read = try EditSession.readOutline(urls[0], take: nil, context: Reading.context(dir))
        let summaries = urls.map { url in
            ProjectReader.summary(
                of: url, place: Reading.projectsFolder, fileSystem: counting, readDocument: { _ in read },
                context: Reading.context(dir), now: Reading.now)
        }
        #expect(summaries.allSatisfy { $0.state == .normal })
        #expect(counting.urls(of: .freeSpace).isEmpty)
        #expect(counting.urls(of: .volume).count == 1_000)
    }
}

@Test func repairReasonsSayWhatAndWhy() {
    // In English, for logs: the app says them in words of its own.
    #expect(RepairReason(part: .manifest, problem: .system(EFBIG)).description == "manifest.json: File too large.")
    #expect(RepairReason(part: .package, problem: .isALink).description == "The package is a link.")
    #expect(RepairReason(part: .manifest, problem: .unknownFormat(0)).description == "manifest.json: there is no format version 0.")
    #expect(RepairReason(part: .edit, problem: .unreadable).description == "It is not one this version reads.")
    #expect(
        RepairReason(part: .package, problem: .system(EIO)).description == "The package cannot be looked at: Input/output error.")
}
