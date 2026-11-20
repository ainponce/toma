// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// What a save of the Replay is asked for.
public struct ReplaySaveRequest: Sendable {
    /// N: the last seconds to keep, at least 1.
    public var seconds: Int
    /// The library's folder, where the project goes (created if it is not there).
    public var projectsFolder: URL
    /// The project's name without `.toma`: «Repetición 2026-11-20 14.03.22». One name, not hidden: not empty, without
    /// `/` and not starting with `.`.
    public var name: String
    /// The app the manifest and the `create` line name, the clock, the ids and the style of the new projects.
    public var context: EditContext

    public init(seconds: Int, projectsFolder: URL, name: String, context: EditContext) {
        self.seconds = seconds
        self.projectsFolder = projectsFolder
        self.name = name
        self.context = context
    }
}

/// A saved Replay.
public struct ReplaySaveResult: Equatable, Sendable {
    /// The new project, `<projects>/<name>.toma` (or « 2», « 3»…).
    public var projectURL: URL
    /// What its document lasts: the end of the screen less the cut, less than N when less was recorded.
    public var duration: Duration
    /// The kinds of the tracks it saved, in the take's order.
    public var trackKinds: [TrackKind]

    public init(projectURL: URL, duration: Duration, trackKinds: [TrackKind]) {
        self.projectURL = projectURL
        self.duration = duration
        self.trackKinds = trackKinds
    }
}

/// How a save puts a file of the working package into the saved one.
public struct ReplayFileOps: Sendable {
    /// Makes the new file `to` with the bytes of `from`: `cloneOrCopy(_:to:)` in the app.
    public var clone: @Sendable (_ from: URL, _ to: URL) throws -> Void

    /// An APFS clone, or a copy where the disk makes none.
    public static let system = ReplayFileOps(clone: { from, to in try cloneOrCopy(from, to: to) })

    public init(clone: @escaping @Sendable (URL, URL) throws -> Void) {
        self.clone = clone
    }

    /// `cloneOrCopy(_:to:cloning:)` cloning with `fclonefileat`.
    public static func cloneOrCopy(_ from: URL, to: URL) throws {
        try cloneOrCopy(from, to: to) { source, to in
            guard fclonefileat(source, AT_FDCWD, to.path, 0) == 0 else { throw POSIXError.fromErrno() }
        }
    }

    /// The regular file `from` as the new file `to`, never over anything (`EEXIST`). `from` is opened with
    /// `O_NOFOLLOW | O_NONBLOCK` and checked with `fstat`: a link throws `ELOOP` and anything that is not a regular file
    /// `EFTYPE`, never followed nor waited on. Then `cloning` makes `to` from that descriptor (an APFS clone); where it
    /// throws `EXDEV` or `ENOTSUP` (a disk that makes no clones), the bytes are copied to a new file (`O_EXCL |
    /// O_NOFOLLOW`) that is full-synced (`F_FULLFSYNC`) and removed if that fails. Any other error is thrown.
    public static func cloneOrCopy(_ from: URL, to: URL, cloning: (_ source: Int32, _ to: URL) throws -> Void) throws {
        let source = open(from.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw POSIXError.fromErrno() }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw POSIXError.fromErrno() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        do {
            try cloning(source, to)
            return
        } catch let error as POSIXError where error.code == .EXDEV || error.code == .ENOTSUP {
            try copy(source, to: to)
        }
    }

    /// The bytes of `source` from its start into the new file `to`, full-synced; nothing is left at `to` if it fails.
    private static func copy(_ source: Int32, to: URL) throws {
        let target = open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard target >= 0 else { throw POSIXError.fromErrno() }
        do {
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var offset: off_t = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress, $0.count, offset) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.fromErrno()
                }
                if count == 0 { break }
                try buffer.withUnsafeBytes { bytes in
                    var written = 0
                    while written < count {
                        let result = write(target, bytes.baseAddress! + written, count - written)
                        if result < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError.fromErrno()
                        }
                        written += result
                    }
                }
                offset += off_t(count)
            }
            try DurableFile.fullSync(target)
        } catch {
            close(target)
            unlink(to.path)
            throw error
        }
        guard close(target) == 0 else {
            let error = POSIXError.fromErrno()
            unlink(to.path)
            throw error
        }
    }
}

/// «Guardar los últimos N s» (fases 4 y 5 design §10.3, plan 5c decision 9): the last N seconds of the Replay's working
/// package as a new project of the library, one take `complete` that the app of phase 3 opens and edits like any.
///
/// Everything is made in a hidden folder of the projects folder, `.<UUID>.replay-saving` (no `.toma`: neither the
/// library nor `RecoveryScanner` sees it), synced, and only then renamed whole to its name with `RENAME_EXCL`: a project
/// is either there whole or not at all, and nothing is ever written over a project that is there. What a crash leaves
/// hidden is removed by `removeAbandonedSaves(in:)` when the app opens. The working package is only read (its files are
/// cloned, never moved), and its marker (`replay-scratch`) never goes into the project, which would hide it from
/// `RecoveryScanner`.
public enum ReplaySaver {
    public static let stagingSuffix = ".replay-saving"

    /// The hidden folders of the saves running in this process, which `removeAbandonedSaves` leaves alone.
    private static let inProgress = Mutex<Set<String>>([])

    /// Saves the last `request.seconds` of what `source` records as a new project of `request.projectsFolder`. Off the
    /// caller's actor (never the main thread).
    ///
    /// `source.freeze()`; its event files read (`EventLogReader`: lines it cannot read are skipped); `ReplayCut.make`
    /// and `ReplayEvents.saved`; in `<projects>/.<UUID>.replay-saving`: `takes/take-001/<track>/` and `cache/`, the
    /// segments kept cloned with `files.clone` (renumbered from 1), the cursor's images the saved events name and the
    /// wallpapers the take has, cloned too, `events.jsonl` (an `EventLogWriter`) and `manifest.json`
    /// (`ReplayManifest.make`, a new `projectID`); `source.thaw()`; the take loaded (`LoadedProject.load`), its document
    /// (`ReplayDocument.make`, the default style's image background copied into `assets/` as an editable opening of a
    /// new project copies it) written as the `create` line (seq 1) of `edit-log.jsonl` in the oldest version that holds
    /// it, never below 2 (`DocumentMigration.oldestVersion(holding:from:)`), with no `edit.json`, which the first
    /// session writes at its close (1b decision 20); every folder synced; renamed to `<name>.toma`, or `<name> 2.toma`,
    /// `<name> 3.toma`… while the name is taken; the projects folder synced (if that last sync fails, the project is
    /// there all the same and is returned).
    ///
    /// `thaw()` is called exactly once after `freeze()`, whatever happens, also when `freeze()` throws (it may stop
    /// pruning before it finds there is nothing to save). On any failure the hidden folder is removed and the error
    /// thrown: what `freeze()` throws (`ReplayError.nothingToSave`, `.notRunning`), `ReplayError.noScreen`, the error of
    /// a file, and `EINVAL`, before `freeze()`, for a name that is not one plain name or `seconds` below 1.
    @concurrent
    public static func save(
        from source: any ReplaySource, _ request: ReplaySaveRequest, files: ReplayFileOps = .system
    ) async throws -> ReplaySaveResult {
        let name = request.name
        guard request.seconds > 0, !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            throw POSIXError(.EINVAL)
        }
        let folder = request.projectsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let snapshot: ReplaySnapshot
        do {
            snapshot = try await source.freeze()
        } catch {
            await source.thaw()
            throw error
        }

        let hidden = "." + UUID().uuidString + stagingSuffix
        inProgress.withLock { _ = $0.insert(hidden) }
        defer { inProgress.withLock { _ = $0.remove(hidden) } }
        let staging = ProjectPackage(url: folder.appending(path: hidden, directoryHint: .isDirectory))
        var thawed = false
        do {
            let saved = try Saved(snapshot, seconds: request.seconds)
            try build(staging, from: snapshot, saved, context: request.context, files: files)
            thawed = true
            await source.thaw()
            try writeDocument(of: staging, cut: saved.cut.cut, context: request.context)
            try syncFolders(of: staging)
            let url = try rename(hidden, in: folder, to: name)
            return ReplaySaveResult(
                projectURL: url,
                duration: .nanoseconds(Int64(saved.cut.end.nanoseconds) - Int64(saved.cut.cut.nanoseconds)),
                trackKinds: saved.cut.tracks.map(\.kind))
        } catch {
            if !thawed { await source.thaw() }
            try? FileManager.default.removeItem(at: staging.url)
            throw error
        }
    }

    /// Removes what a save cut short left in the first level of `projectsFolder`: the folders named
    /// `.<UUID>.replay-saving` (by `lstat`: a link of that name is not one of them) that no save of this process is
    /// making. Nothing else: never a `.toma`, another hidden folder or a duplicate's `.duplicating`. Returns what it
    /// removed; what it could not remove is left for the next time.
    @discardableResult public static func removeAbandonedSaves(in projectsFolder: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projectsFolder.path) else { return [] }
        var removed: [URL] = []
        for name in names.sorted() where isStagingName(name) && !inProgress.withLock({ $0.contains(name) }) {
            let url = projectsFolder.appending(path: name, directoryHint: .isDirectory)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            removed.append(url)
        }
        return removed
    }

    // MARK: - Private

    /// What is saved, worked out before anything is written.
    private struct Saved {
        var cut: ReplayCut
        var events: [InputEvent]
        var cameraStyle: CameraStyle?

        init(_ snapshot: ReplaySnapshot, seconds: Int) throws {
            var events: [InputEvent] = []
            for shard in snapshot.shards {
                events += try EventLogReader.read(shard).events
            }
            cut = try ReplayCut.make(take: snapshot.take, seconds: seconds, takeID: ReplayScratch.takeID)
            (self.events, cameraStyle) = ReplayEvents.saved(
                events, carried: snapshot.carried, initialCameraStyle: snapshot.take.cameraStyle, cut: cut)
        }
    }

    /// Whether `name` is that of a save's hidden folder: `.<UUID>.replay-saving`.
    private static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(stagingSuffix) else { return false }
        return UUID(uuidString: String(name.dropFirst().dropLast(stagingSuffix.count))) != nil
    }

    /// The hidden folder `staging` with the take's files, events and manifest: everything read from the working package.
    private static func build(
        _ staging: ProjectPackage, from snapshot: ReplaySnapshot, _ saved: Saved, context: EditContext, files: ReplayFileOps
    ) throws {
        let take = ReplayScratch.takeID
        let scratch = snapshot.package
        try makeFolder(staging.url)
        try makeFolder(staging.takesURL)
        try makeFolder(staging.cacheURL)
        try makeFolder(staging.takeDirectory(take))
        for track in saved.cut.tracks {
            try makeFolder(staging.trackDirectory(take: take, track: track.id))
        }
        for file in saved.cut.files {
            try files.clone(
                scratch.url.appending(path: file.from, directoryHint: .notDirectory),
                staging.url.appending(path: file.to, directoryHint: .notDirectory))
        }

        // The images of the cursor the saved events name (the one re-emitted at the start among them), each once.
        var hashes: [String] = []
        for event in saved.events {
            guard case let .cursorImage(hash, _, _, _) = event.kind, !hashes.contains(hash),
                PackageFileKind.cursorImage.isValidName(hash + ".png")
            else { continue }
            hashes.append(hash)
        }
        for hash in hashes {
            let from = scratch.cursorImageURL(take: take, hash: hash)
            guard isRegularFile(from) else { continue }
            if !isFolder(staging.cursorsDirectory(take: take)) { try makeFolder(staging.cursorsDirectory(take: take)) }
            try files.clone(from, staging.cursorImageURL(take: take, hash: hash))
        }

        // The wallpapers of the take's displays, if it has them.
        let wallpapers = scratch.wallpapersDirectory(take: take)
        if isFolder(wallpapers), let names = try? FileManager.default.contentsOfDirectory(atPath: wallpapers.path) {
            for name in names.sorted() where PackageFileKind.wallpaper.isValidName(name) {
                let from = wallpapers.appending(path: name, directoryHint: .notDirectory)
                guard isRegularFile(from) else { continue }
                if !isFolder(staging.wallpapersDirectory(take: take)) { try makeFolder(staging.wallpapersDirectory(take: take)) }
                try files.clone(from, staging.wallpapersDirectory(take: take).appending(path: name, directoryHint: .notDirectory))
            }
        }

        let log = try EventLogWriter(url: staging.eventsURL(take: take))
        for event in saved.events { log.append(event) }
        try log.close()

        let manifest = ReplayManifest.make(
            cut: saved.cut, events: saved.events, cameraStyle: saved.cameraStyle, takeID: take, app: context.app,
            now: context.now(), projectID: ProjectID.random())
        try DurableFile.writeNew(try ProjectJSON.encoder().encode(manifest), to: staging.manifestURL)
    }

    /// The document of the take saved in `staging`, as the `create` line of `edit-log.jsonl`.
    private static func writeDocument(of staging: ProjectPackage, cut: HostTime, context: EditContext) throws {
        let project = try LoadedProject.load(staging.url, take: ReplayScratch.takeID)
        var document = ReplayDocument.make(
            project: project, cut: cut, defaultStyle: context.defaultStyle, makeID: context.makeID,
            cameraLook: context.cameraLook)
        // Its default style's image goes into the package before the `create` that names it.
        document.style.background = DefaultStyleStore.background(
            document.style.background, from: context.styleDirectory, into: staging)
        document.logSequence = 1
        let version = DocumentMigration.oldestVersion(holding: document, from: 2)
        let line = try EditLogEntry.create(seq: 1, document: document, app: context.app).jsonLine(writingDocumentAt: version)
        try DurableFile.writeNew(Data((line + "\n").utf8), to: staging.editLogURL)
    }

    /// Full-syncs every folder of `staging`, the deepest first, so what they hold is on the drive before the rename.
    private static func syncFolders(of staging: ProjectPackage) throws {
        let take = ReplayScratch.takeID
        var folders: [URL] = []
        if let tracks = try? FileManager.default.contentsOfDirectory(atPath: staging.takeDirectory(take).path) {
            folders += tracks.sorted().map { staging.takeDirectory(take).appending(path: $0, directoryHint: .isDirectory) }
                .filter(isFolder)
        }
        folders += [staging.takeDirectory(take), staging.takesURL, staging.cacheURL, staging.assetsURL, staging.url]
            .filter(isFolder)
        for folder in folders { try DurableFile.syncDirectory(folder) }
    }

    /// Renames the hidden folder `hidden` of `folder` to `<name>.toma`, or `<name> 2.toma`, `<name> 3.toma`… while
    /// that is taken, never over anything (`RENAME_EXCL`); syncs `folder` and returns the project's URL.
    private static func rename(_ hidden: String, in folder: URL, to name: String) throws -> URL {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.fromErrno() }
        defer { close(fd) }
        for attempt in 1...10_000 {
            let fileName = (attempt == 1 ? name : "\(name) \(attempt)") + "." + ProjectPackage.fileExtension
            do {
                try ProjectTrash.renameExclusively(from: fd, hidden, to: fd, fileName)
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
            // The project is there whole: a folder that cannot be synced now does not undo it.
            try? DurableFile.fullSync(fd)
            return folder.appending(path: fileName, directoryHint: .isDirectory)
        }
        throw POSIXError(.EEXIST)
    }

    private static func makeFolder(_ url: URL) throws {
        guard mkdir(url.path, 0o755) == 0 else { throw POSIXError.fromErrno() }
    }

    /// Whether a folder is at `url`, by `lstat` (a link is not one).
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether a regular file is at `url`, by `lstat` (a link is not one).
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}

extension POSIXError {
    /// The error for the current value of `errno`.
    fileprivate static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
