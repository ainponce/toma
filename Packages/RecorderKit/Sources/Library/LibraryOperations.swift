// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import ProjectFormat

/// What the library needs to know of the app around it (design §6.6), from the app's own state: never by probing a
/// lock. Asked on the library's own threads, never the main one.
public protocol LibraryAppState: Sendable {
    /// A take is being recorded, any take: the heavy work of the library pauses, and nothing is renamed meanwhile.
    func isRecording() -> Bool
    /// An editor window of this app has the package at `url` open.
    func isOpenHere(_ url: URL) -> Bool
    /// The editor of the package at `url` has changes it could not write (1b §5.9: the disk is full).
    func hasUnsavedChanges(_ url: URL) -> Bool
    /// Closes the editor window of the package at `url`, which writes what is pending and lets go of its `edit.lock`;
    /// returns once it did.
    func close(_ url: URL) async
}

/// Why an action of the library did not happen (design §6.3, §10); the app says it in words. After any of them the
/// project is where it was, whole.
public enum LibraryFailure: Error, Equatable, Sendable {
    /// A take is being recorded: "Se está grabando."
    case recording
    /// Another app holds the project's `edit.lock`, or one of its takes' `recording.lock`, as found just before the
    /// action.
    case openElsewhere
    /// The project's editor has changes it could not write.
    case unsavedChanges
    /// The name cannot be the project's; `.tooLong` also when the disk says so (`ENAMETOOLONG`).
    case name(NameProblem)
    /// The disk has no room for the copy: it takes `needed` bytes.
    case noRoom(needed: Int64)
    /// The package is not where the action applies: out of the projects folder, or already in its trash, for
    /// `moveToTrash`; out of the trash for `restore` and `deleteForever`.
    case outsideProjectsFolder
    /// The copy to undo was opened or changed since it was made.
    case copyOpenedOrChanged
    /// That many projects could not be deleted: they are still in the trash, under their names.
    case someNotDeleted(Int)
    /// The disk refused, with this error.
    case posix(POSIXErrorCode)
}

/// A copy the library made, as it was when it was made: what undoing it checks (design §6.3).
public struct DuplicateRecord: Equatable, Sendable {
    /// The copy's package.
    public var copy: URL
    /// It is in the projects folder: undoing it moves it to the library's trash; otherwise to the Trash of macOS.
    public var insideProjectsFolder: Bool
    /// `edit.json` of the copy when it was made; `nil` if it had none.
    public var editSignature: FileSignature?
    /// `edit-log.jsonl` of the copy when it was made; `nil` if it had none.
    public var logSignature: FileSignature?

    public init(copy: URL, insideProjectsFolder: Bool, editSignature: FileSignature? = nil, logSignature: FileSignature? = nil) {
        self.copy = copy
        self.insideProjectsFolder = insideProjectsFolder
        self.editSignature = editSignature
        self.logSignature = logSignature
    }
}

/// The library's file operations (design §6.3, §6.4): rename, duplicate, move to the trash, restore and delete
/// forever, and undoing a duplicate. A project is never lost: each action is a rename of the whole package on its disk,
/// or a copy that is hidden until it is whole; deleting renames the package out of every list first and only then
/// deletes it; nothing is ever written inside a package, and no link is ever followed. A failure leaves the project
/// where it was.
///
/// Every access to the disk happens on a thread of its own, never the main one. The locks of a project (its
/// `edit.lock` and its takes' `recording.lock`) are asked about with `isLockHeld` only just before an action that
/// changes where it is (renaming, moving to the trash, deleting, undoing a duplicate), never otherwise (design §6.6).
/// While a take is being recorded, a copy without clones and deleting pause, and nothing is renamed.
public final class LibraryOperations: Sendable {
    /// How often a paused copy or deletion looks again whether the take ended.
    static let pausePoll: useconds_t = 50_000
    /// The size of each read and write of a copy: a take that starts stops it within one of these.
    static let copyChunk = 1 << 20
    /// The names a package gets in the trash while it is deleted (decision 33).
    static let deletingPrefix = ".deleting-"

    private let projectsFolder: URL
    private let fileSystem: any LibraryFileSystem
    private let records: LibraryRecordsStore
    private let app: any LibraryAppState
    private let isLockHeld: @Sendable (URL) -> Bool
    private let trash: @Sendable (URL) throws -> Void

    /// `isLockHeld` answers whether another open file holds a lock (by default `RecordingLock.isHeld`, which takes it
    /// for a moment: why it is asked only just before an action); `trash` moves an item to the Trash of macOS, used only
    /// to undo a copy made out of the projects folder.
    public init(
        projectsFolder: URL, fileSystem: any LibraryFileSystem, records: LibraryRecordsStore, app: any LibraryAppState,
        isLockHeld: @escaping @Sendable (URL) -> Bool = { RecordingLock.isHeld(at: $0) },
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.projectsFolder = projectsFolder
        self.fileSystem = fileSystem
        self.records = records
        self.app = app
        self.isLockHeld = isLockHeld
        self.trash = trash
    }

    // MARK: - Rename

    /// Renames the package at `url` in its own folder to `name` (without `.toma`, as `ProjectNames.validate` takes it),
    /// with `renameatx_np` and `RENAME_EXCL`: never over another item. Returns the package's new URL; a name that differs
    /// only in how it is written (case, normalization) renames it too, and its own name does nothing.
    ///
    /// Refused while a take is being recorded, for a name that is not valid or is taken in that folder (`.name`), and if
    /// another app holds a lock of the project, found just before (an editor of this app holds its own `edit.lock`,
    /// which is not asked about: that editor keeps writing into the renamed package).
    public func rename(_ url: URL, to name: String) async -> Result<URL, LibraryFailure> {
        if app.isRecording() { return .failure(.recording) }
        let ownEditor = app.isOpenHere(url)
        return await onDisk { [self] in
            let folder = url.deletingLastPathComponent()
            let valid: String
            do {
                switch ProjectNames.validate(name, existing: try projectNames(in: folder, excluding: url.lastPathComponent)) {
                case .success(let name): valid = name
                case .failure(let problem): return .failure(.name(problem))
                }
            } catch {
                return .failure(Self.failure(error))
            }
            let fileName = "\(valid).\(ProjectPackage.fileExtension)"
            if fileName == url.lastPathComponent { return .success(url) }
            if let refusal = lockRefusal(of: url, editLock: !ownEditor) { return .failure(refusal) }
            let destination = folder.appending(path: fileName, directoryHint: .isDirectory)
            do {
                try ProjectTrash.renameExclusively(from: AT_FDCWD, url.path, to: AT_FDCWD, destination.path)
            } catch {
                return .failure(Self.nameFailure(error))
            }
            return .success(destination)
        }
    }

    // MARK: - Duplicate

    /// Makes a copy of the package at `url` next to it, named `name` (without `.toma`; the app makes it with
    /// `ProjectNames.copyName`), and returns what undoing it needs.
    ///
    /// The copy is made under a hidden name in the same folder (`.<UUID>.duplicating`) and renamed to `name` with
    /// `RENAME_EXCL` once it is whole: a clone (`clonefile(2)`) where the disk has them, byte for byte the original;
    /// otherwise, once the disk is known to have room for it (`.noRoom`), a copy through descriptors, paused while a take
    /// is being recorded, with `progress` (from 0 towards 1) after each step. `progress(1)` once it is done. The original
    /// is read through a descriptor of its own folder: the Finder can rename it or its folder meanwhile, and the copy is
    /// still made, next to it. A failure removes the hidden copy: nothing is left half done.
    ///
    /// Refused while a take is being recorded, if the project's editor has changes it could not write, for a name that is
    /// not valid or is taken in that folder, and, as `.name(.tooLong)`, for one the disk finds too long (`ENAMETOOLONG`:
    /// a name the Finder gave the original can be longer than the library's own limit, and its copy's need not fit).
    public func duplicate(
        _ url: URL, named name: String, progress: @escaping @Sendable (Double) -> Void
    ) async -> Result<DuplicateRecord, LibraryFailure> {
        if app.isRecording() { return .failure(.recording) }
        if app.hasUnsavedChanges(url) { return .failure(.unsavedChanges) }
        return await onDisk(.utility) { [self] in duplicateOnDisk(url, named: name, progress: progress) }
    }

    private func duplicateOnDisk(
        _ url: URL, named raw: String, progress: @escaping (Double) -> Void
    ) -> Result<DuplicateRecord, LibraryFailure> {
        let folder = url.deletingLastPathComponent()
        let name: String
        do {
            switch ProjectNames.validate(raw, existing: try projectNames(in: folder)) {
            case .success(let valid): name = valid
            // The disk says whether it fits.
            case .failure(.tooLong): name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            case .failure(let problem): return .failure(.name(problem))
            }
        } catch {
            return .failure(Self.failure(error))
        }
        let parent = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return .failure(.posix(Self.errnoCode())) }
        defer { close(parent) }
        let source = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return .failure(.posix(Self.errnoCode())) }
        defer { close(source) }

        let hidden = ".\(UUID().uuidString).duplicating"
        if fclonefileat(source, parent, hidden, UInt32(CLONE_NOFOLLOW)) != 0 {
            let code = Self.errnoCode()
            guard code == .ENOTSUP else {
                Self.removeQuietly(hidden, in: parent)
                return .failure(.posix(code))
            }
            // No clones on this disk: a copy, once there is room for it.
            let needed: Int64
            do {
                needed = try fileSystem.allocatedSize(of: url)
                if needed > (try fileSystem.freeSpace(of: folder)) { return .failure(.noRoom(needed: needed)) }
            } catch {
                return .failure(Self.failure(error))
            }
            do {
                let copy = try FolderCopy(source, progress: progress, beforeEachStep: { [self] in waitWhileRecording() })
                try copy.copy(into: parent, named: hidden)
            } catch {
                Self.removeQuietly(hidden, in: parent)
                let failure = Self.failure(error)
                if failure == .posix(.ENOSPC) || failure == .posix(.EDQUOT) { return .failure(.noRoom(needed: needed)) }
                return .failure(failure)
            }
        }
        let fileName = "\(name).\(ProjectPackage.fileExtension)"
        do {
            try ProjectTrash.renameExclusively(from: parent, hidden, to: parent, fileName)
        } catch {
            Self.removeQuietly(hidden, in: parent)
            return .failure(Self.nameFailure(error))
        }
        let copyFolder = Self.folder(open: parent, given: folder)
        let copy = ProjectPackage(url: copyFolder.appending(path: fileName, directoryHint: .isDirectory))
        progress(1)
        return .success(
            DuplicateRecord(
                copy: copy.url, insideProjectsFolder: place(ofFolder: copyFolder) != .elsewhere,
                editSignature: signature(of: copy.editURL), logSignature: signature(of: copy.editLogURL)))
    }

    // MARK: - Trash and restore

    /// Moves the package at `url`, which is in the projects folder, into its trash (`<projects folder>/Trash/`) under its
    /// own name, «nombre 2»… while that is taken there (`ProjectTrash.move(_:into:as:)`): a rename on the same disk.
    /// Writes down where it came from in `trashOrigins`, by its identity, for `restore`. Returns where it is now.
    ///
    /// Refused while a take is being recorded, for a package out of the projects folder or already in its trash
    /// (`.outsideProjectsFolder`: the library does not trash what it does not keep, design §4.5), if its editor has
    /// changes it could not write, and if another app holds a lock of it. If an editor of this app has it open, its
    /// window is closed first, which writes what is pending and lets go of its lock; then the locks are asked about.
    public func moveToTrash(_ url: URL) async -> Result<URL, LibraryFailure> {
        if app.isRecording() { return .failure(.recording) }
        let place = await onDisk { [self] in place(ofFolder: url.deletingLastPathComponent()) }
        guard place == .projects else { return .failure(.outsideProjectsFolder) }
        if app.hasUnsavedChanges(url) { return .failure(.unsavedChanges) }
        if app.isOpenHere(url) { await app.close(url) }
        let moved = await onDisk { [self] () -> Result<Trashed, LibraryFailure> in
            if let refusal = lockRefusal(of: url, editLock: true) { return .failure(refusal) }
            return moveIntoTrash(url)
        }
        return await noting(moved)
    }

    /// Moves the package at `url`, which is in the trash, back to the folder it came from: the one `trashOrigins` has
    /// for it, found by its bookmark (which follows the folder if it was moved or renamed) or its path, if that is still
    /// a folder of the projects folder; otherwise the projects folder itself. Under its own name, «nombre 2»… while that
    /// is taken there. Returns where it is now. Asks about no lock: the project only leaves the trash.
    public func restore(_ url: URL) async -> Result<URL, LibraryFailure> {
        let found = await onDisk { [self] () -> (Bool, PackageIdentity?) in
            (isInTrash(url), try? PackageIdentity(of: url, in: fileSystem))
        }
        guard found.0 else { return .failure(.outsideProjectsFolder) }
        let identity = found.1
        var known: TrashOrigin?
        if let identity { known = await records.records.trashOrigins[identity.string] }
        let origin = known
        let restored = await onDisk { [self] () -> Result<URL, LibraryFailure> in
            do {
                return .success(try ProjectTrash.move(url, into: restoreFolder(for: origin)))
            } catch {
                return .failure(Self.failure(error))
            }
        }
        if case .success = restored, let identity {
            await records.update { $0.trashOrigins[identity.string] = nil }
        }
        return restored
    }

    // MARK: - Delete

    /// Deletes forever the packages at `urls`, which are all in the trash (otherwise nothing happens:
    /// `.outsideProjectsFolder`). Those this app has open (to look at) are closed first. Then each, once its locks are
    /// found free, is renamed to `Trash/.deleting-<UUID>`: from that moment it is in no list, and a crash leaves it for
    /// `finishPendingDeletions`. Then they are deleted one by one, never following a link, paused while a take is being
    /// recorded. `progress(done, total, paused)` is told the projects deleted out of `urls.count` once they are all
    /// renamed, after each one, and when a pause begins and ends. Returns once all are deleted.
    ///
    /// A package that could not be deleted goes back to its name in the trash (with « 2»… if it is taken), with what
    /// was left of it. `.openElsewhere` if the only one asked for has a lock taken; otherwise those with a lock taken and
    /// those that could not be deleted are `.someNotDeleted`. Deleting forever cannot be undone.
    public func deleteForever(
        _ urls: [URL], progress: @escaping @Sendable (Int, Int, Bool) -> Void
    ) async -> Result<Void, LibraryFailure> {
        let inTrash = await onDisk { [self] in urls.allSatisfy(isInTrash) }
        guard inTrash else { return .failure(.outsideProjectsFolder) }
        for url in urls where app.isOpenHere(url) { await app.close(url) }
        let total = urls.count
        let marked = await onDisk { [self] in markForDeletion(urls) }
        let deleted = await onDisk(.utility) { [self] in
            deleteMarked(marked.pending, alreadyGone: marked.gone, total: total, progress: progress)
        }
        let identities = deleted.identities.map(\.string)
        if !identities.isEmpty {
            await records.update { records in
                for identity in identities { records.trashOrigins[identity] = nil }
            }
        }
        let notDeleted = marked.locked + marked.failed + deleted.failed
        if notDeleted == 0 { return .success(()) }
        if total == 1, marked.locked == 1 { return .failure(.openElsewhere) }
        return .failure(.someNotDeleted(notDeleted))
    }

    /// Deletes what deletions a crash left in the trash (`Trash/.deleting-*`, decision 33), paused while a take is being
    /// recorded, and touches nothing else: a link among them is removed itself. Whatever cannot be deleted stays as it
    /// is, for the next time.
    public func finishPendingDeletions() async {
        await onDisk(.utility) { [self] in
            let trash = ProjectTrash.folder(in: projectsFolder)
            guard let entries = try? fileSystem.list(trash) else { return }
            let pending = entries.map(\.lastPathComponent).filter { $0.hasPrefix(Self.deletingPrefix) }
            guard !pending.isEmpty else { return }
            let folder = open(trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { return }
            defer { close(folder) }
            for name in pending {
                try? Self.removeTree(named: name, in: folder) { waitWhileRecording() }
            }
        }
    }

    // MARK: - Undo a duplicate

    /// Undoes `record`, a copy this library made, without ever deleting it (design §6.3): a copy in the projects folder
    /// goes to its trash (as `moveToTrash`, and can be restored), one elsewhere to the Trash of macOS (`trash`). Returns
    /// where it is now: in the trash, or the URL it had when it went to the Trash of macOS, which does not say.
    ///
    /// Refused, and the copy stays, if it was opened or changed since it was made (`.copyOpenedOrChanged`): this app has
    /// it open, its `edit.lock` is taken (asked just before), or its `edit.json` or `edit-log.jsonl` is not as it was
    /// (size and modification date). Also refused while a take is being recorded, and if a take's `recording.lock` is
    /// taken.
    public func undoDuplicate(_ record: DuplicateRecord) async -> Result<URL, LibraryFailure> {
        if app.isRecording() { return .failure(.recording) }
        if app.isOpenHere(record.copy) { return .failure(.copyOpenedOrChanged) }
        let moved = await onDisk { [self] () -> Result<Trashed, LibraryFailure> in
            let package = ProjectPackage(url: record.copy)
            do {
                guard try fileSystem.stat(record.copy, withAddedDate: false).kind == .directory else {
                    return .failure(.posix(.ENOTDIR))
                }
            } catch {
                return .failure(Self.failure(error))
            }
            if isLockHeld(package.editLockURL) { return .failure(.copyOpenedOrChanged) }
            guard signature(of: package.editURL) == record.editSignature, signature(of: package.editLogURL) == record.logSignature
            else { return .failure(.copyOpenedOrChanged) }
            if let refusal = lockRefusal(of: record.copy, editLock: false) { return .failure(refusal) }
            if record.insideProjectsFolder { return moveIntoTrash(record.copy) }
            do {
                try trash(record.copy)
            } catch {
                return .failure(Self.failure(error))
            }
            return .success(Trashed(url: record.copy))
        }
        return await noting(moved)
    }

    // MARK: - Private: the trash

    /// A package moved to a trash, and what `trashOrigins` gets for it.
    private struct Trashed: Sendable {
        var url: URL
        var identity: PackageIdentity?
        var origin: TrashOrigin?
    }

    /// Moves the package at `url` into the trash of the projects folder, which is made if it is not there; with its
    /// identity and where it came from. On the disk's thread.
    private func moveIntoTrash(_ url: URL) -> Result<Trashed, LibraryFailure> {
        let from = url.deletingLastPathComponent()
        let identity = try? PackageIdentity(of: url, in: fileSystem)
        let origin = TrashOrigin(bookmark: try? from.bookmarkData(), path: from.path)
        let trash = ProjectTrash.folder(in: projectsFolder)
        do {
            if mkdir(trash.path, 0o755) != 0, errno != EEXIST { throw POSIXError(Self.errnoCode()) }
            return .success(Trashed(url: try ProjectTrash.move(url, into: trash), identity: identity, origin: origin))
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// Writes down in `trashOrigins` where a package moved to the library's trash came from; `moved` as it is.
    private func noting(_ moved: Result<Trashed, LibraryFailure>) async -> Result<URL, LibraryFailure> {
        switch moved {
        case .success(let trashed):
            if let identity = trashed.identity, let origin = trashed.origin {
                await records.update { $0.trashOrigins[identity.string] = origin }
            }
            return .success(trashed.url)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// The folder a package of the trash goes back to: where it came from, found by the bookmark (as it was given, by
    /// its path, while that is still the same folder) or else the path, if it is a folder of the projects folder (out of
    /// the trash, not a link); otherwise the projects folder.
    private func restoreFolder(for origin: TrashOrigin?) -> URL {
        guard let origin else { return projectsFolder }
        let byPath = URL(fileURLWithPath: origin.path, isDirectory: true)
        var candidates: [URL] = []
        if let bookmark = origin.bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            {
                let path = Self.realPath(byPath)
                candidates.append(path != nil && path == Self.realPath(resolved) ? byPath : resolved)
            }
        }
        candidates.append(byPath)
        return candidates.first { folder in
            var info = stat()
            return lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && place(ofFolder: folder) == .projects
        } ?? projectsFolder
    }

    // MARK: - Private: deleting

    /// The packages of a `deleteForever` renamed out of every list.
    private struct Marked: Sendable {
        /// Their hidden names in the trash, the names they had and their identities.
        var pending: [(hidden: String, name: String, identity: PackageIdentity?)]
        /// Those that were no longer there: someone else deleted them.
        var gone = 0
        /// Those with a lock taken, left as they are.
        var locked = 0
        /// Those whose locks or name could not be looked at or changed, left as they are.
        var failed = 0
    }

    /// Renames each of `urls` whose locks are free to `.deleting-<UUID>` in the trash. On the disk's thread.
    private func markForDeletion(_ urls: [URL]) -> Marked {
        var marked = Marked(pending: [])
        let trash = ProjectTrash.folder(in: projectsFolder)
        for url in urls {
            switch lockRefusal(of: url, editLock: true) {
            case nil: break
            case .openElsewhere?:
                marked.locked += 1
                continue
            case _?:
                marked.failed += 1
                continue
            }
            let identity = try? PackageIdentity(of: url, in: fileSystem)
            let hidden = Self.deletingPrefix + UUID().uuidString
            do {
                try ProjectTrash.renameExclusively(
                    from: AT_FDCWD, url.path, to: AT_FDCWD, trash.appending(path: hidden, directoryHint: .isDirectory).path)
                marked.pending.append((hidden, url.deletingPathExtension().lastPathComponent, identity))
            } catch let error as POSIXError where error.code == .ENOENT {
                marked.gone += 1
            } catch {
                marked.failed += 1
            }
        }
        return marked
    }

    /// Deletes the packages `marked` hid in the trash, one by one, paused while a take is being recorded; one that cannot
    /// be deleted goes back to its name. Their identities, and how many could not be deleted. On the disk's thread.
    private func deleteMarked(
        _ pending: [(hidden: String, name: String, identity: PackageIdentity?)], alreadyGone: Int, total: Int,
        progress: (Int, Int, Bool) -> Void
    ) -> (identities: [PackageIdentity], failed: Int) {
        var done = alreadyGone
        progress(done, total, false)
        guard !pending.isEmpty else { return ([], 0) }
        let trash = ProjectTrash.folder(in: projectsFolder)
        let folder = open(trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if folder >= 0 { close(folder) } }
        var identities: [PackageIdentity] = []
        var failed = 0
        for package in pending {
            do {
                guard folder >= 0 else { throw POSIXError(Self.errnoCode()) }
                try Self.removeTree(named: package.hidden, in: folder) {
                    waitWhileRecording { paused in progress(done, total, paused) }
                }
                done += 1
                if let identity = package.identity { identities.append(identity) }
                progress(done, total, false)
            } catch {
                failed += 1
                let hidden = trash.appending(path: package.hidden, directoryHint: .isDirectory)
                _ = try? ProjectTrash.move(hidden, into: trash, as: package.name)
            }
        }
        return (identities, failed)
    }

    /// Removes the item `name` of the folder open at `folder` and, if it is a folder, everything in it, depth first;
    /// `beforeEach` before each item is removed. A link is removed itself, never followed, and what is already gone
    /// counts as removed. Stops at the first item that cannot be removed and throws its error.
    static func removeTree(named name: String, in folder: Int32, beforeEach: () -> Void) throws {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(errnoCode())
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let inner = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard inner >= 0 else {
                if errno == ENOENT { return }
                throw POSIXError(errnoCode())
            }
            defer { close(inner) }
            for entry in try names(in: inner) {
                try removeTree(named: entry, in: inner, beforeEach: beforeEach)
            }
        }
        beforeEach()
        let flags = info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
        guard unlinkat(folder, name, flags) == 0 || errno == ENOENT else { throw POSIXError(errnoCode()) }
    }

    /// `removeTree` without pauses, of something this library made, whatever comes of it.
    private static func removeQuietly(_ name: String, in folder: Int32) {
        try? removeTree(named: name, in: folder) {}
    }

    // MARK: - Private: the disk

    /// Where a folder is, for the library.
    private enum Place {
        /// The projects folder, or a folder in it out of its trash.
        case projects
        /// The trash of the projects folder, or a folder in it.
        case trash
        case elsewhere
    }

    /// Where `folder` is, by real paths (so that `/var` and `/private/var`, or a link on the way, are the same place).
    private func place(ofFolder folder: URL) -> Place {
        guard let projects = Self.realPath(projectsFolder), let path = Self.realPath(folder) else { return .elsewhere }
        let trash = projects + "/" + ProjectTrash.folderName
        if path == trash || path.hasPrefix(trash + "/") { return .trash }
        if path == projects || path.hasPrefix(projects + "/") { return .projects }
        return .elsewhere
    }

    /// Whether the package at `url` is directly in the trash of the projects folder.
    private func isInTrash(_ url: URL) -> Bool {
        guard let projects = Self.realPath(projectsFolder), let folder = Self.realPath(url.deletingLastPathComponent()) else {
            return false
        }
        return folder == projects + "/" + ProjectTrash.folderName
    }

    /// `.openElsewhere` if another open file holds a lock of the package at `url`: its `edit.lock` (only with
    /// `editLock`: without, this app's own editor holds it) or one of its takes' `recording.lock`. Asked just before an
    /// action that changes where the project is, and only then. A `takes/` that is not there or not a folder (a file, or
    /// a link, which is never followed) has no takes; a failure if it cannot be read.
    private func lockRefusal(of url: URL, editLock: Bool) -> LibraryFailure? {
        let package = ProjectPackage(url: url)
        let takes: [String]
        do {
            takes = try fileSystem.list(package.takesURL).map(\.lastPathComponent)
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
            takes = []
        } catch {
            return Self.failure(error)
        }
        let locks = (editLock ? [package.editLockURL] : []) + takes.sorted().map { package.lockURL(take: $0) }
        return locks.contains(where: isLockHeld) ? .openElsewhere : nil
    }

    /// The names of the projects in `folder` (without `.toma`), but the item named `excluded`.
    private func projectNames(in folder: URL, excluding excluded: String? = nil) throws -> [String] {
        try fileSystem.list(folder)
            .filter { $0.pathExtension.lowercased() == ProjectPackage.fileExtension && $0.lastPathComponent != excluded }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The size and date of the file at `url`; `nil` if it cannot be looked at.
    private func signature(of url: URL) -> FileSignature? {
        (try? fileSystem.stat(url, withAddedDate: false)).map { FileSignature(size: $0.size, modified: $0.modified) }
    }

    /// Blocks this thread while a take is being recorded; `paused` is told when the wait begins and when it ends.
    private func waitWhileRecording(_ paused: (Bool) -> Void = { _ in }) {
        guard app.isRecording() else { return }
        paused(true)
        while app.isRecording() { usleep(Self.pausePoll) }
        paused(false)
    }

    /// `work` on a thread of its own: the disk can take its time, never on the main thread nor on Swift's.
    private func onDisk<T: Sendable>(
        _ qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }

    /// The folder open at `fd` as `given` while it is still there; where it is now if it was moved or renamed.
    private static func folder(open fd: Int32, given: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return given }
        let now = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return realPath(given) == now ? given : URL(fileURLWithPath: now, isDirectory: true)
    }

    static func realPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    /// The names in the folder open at `fd`, but `.` and `..`.
    static func names(in fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw POSIXError(errnoCode()) }
        guard let stream = fdopendir(copy) else {
            let error = POSIXError(errnoCode())
            close(copy)
            throw error
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(errnoCode()) }
                return names
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    static func errnoCode() -> POSIXErrorCode { POSIXErrorCode(rawValue: errno) ?? .EIO }

    /// `error` as a failure of the library: the code of a `POSIXError`, itself or under Foundation's; `EIO` otherwise.
    static func failure(_ error: any Error) -> LibraryFailure {
        if let failure = error as? LibraryFailure { return failure }
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain { return .posix(POSIXErrorCode(rawValue: Int32(error.code)) ?? .EIO) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .posix(.EIO)
    }

    /// A rename's error: a name that is taken or too long for the disk is the name's.
    private static func nameFailure(_ error: any Error) -> LibraryFailure {
        switch failure(error) {
        case .posix(.EEXIST): .name(.taken)
        case .posix(.ENAMETOOLONG): .name(.tooLong)
        case let other: other
        }
    }
}

/// A copy of a folder, through descriptors: the original or its folder can be renamed meanwhile. Never follows a link
/// (a link is copied as one); a FIFO is made again; anything else that is not a file or a folder is left out. Files are
/// copied in steps of `LibraryOperations.copyChunk`, with `beforeEachStep` before each (it pauses) and `progress` after
/// (the bytes copied over those of the original, below 1); each file and folder gets the original's permissions and
/// dates.
private final class FolderCopy {
    private let source: Int32
    private let total: Int64
    private var copied: Int64 = 0
    private let progress: (Double) -> Void
    private let beforeEachStep: () -> Void
    private var buffer = [UInt8](repeating: 0, count: LibraryOperations.copyChunk)

    init(_ source: Int32, progress: @escaping (Double) -> Void, beforeEachStep: @escaping () -> Void) throws {
        self.source = source
        self.progress = progress
        self.beforeEachStep = beforeEachStep
        total = try Self.bytes(in: source)
    }

    /// Makes the folder `name` in the folder open at `parent` a copy of the source.
    func copy(into parent: Int32, named name: String) throws {
        var info = stat()
        guard fstat(source, &info) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        try copyFolder(source, info: info, into: parent, named: name)
    }

    private func copyFolder(_ folder: Int32, info: stat, into parent: Int32, named name: String) throws {
        guard mkdirat(parent, name, 0o700) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        defer { close(target) }
        for entry in try LibraryOperations.names(in: folder) {
            var item = stat()
            guard fstatat(folder, entry, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
                // Gone meanwhile: the editor replaces its files by renames.
                if errno == ENOENT { continue }
                throw POSIXError(LibraryOperations.errnoCode())
            }
            switch item.st_mode & S_IFMT {
            case S_IFDIR:
                let inner = openat(folder, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard inner >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
                defer { close(inner) }
                try copyFolder(inner, info: item, into: target, named: entry)
            case S_IFREG:
                try copyFile(entry, in: folder, into: target)
            case S_IFLNK:
                var destination = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
                let length = readlinkat(folder, entry, &destination, Int(MAXPATHLEN))
                guard length >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
                destination[length] = 0
                guard symlinkat(destination, target, entry) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
            case S_IFIFO:
                guard mkfifoat(target, entry, item.st_mode & 0o7777) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
            default:
                continue
            }
        }
        try Self.setModeAndDates(of: target, as: info)
    }

    private func copyFile(_ name: String, in folder: Int32, into target: Int32) throws {
        let input = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        let output = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        defer { close(output) }
        while true {
            beforeEachStep()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(LibraryOperations.errnoCode())
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = write(output, bytes.baseAddress! + offset, count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(LibraryOperations.errnoCode())
                    }
                    offset += written
                }
            }
            copied += Int64(count)
            progress(min(Double(copied) / Double(max(total, 1)), 1.0.nextDown))
        }
        try Self.setModeAndDates(of: output, as: info)
    }

    /// The permissions and the access and modification dates of `info`, on the item open at `fd`.
    private static func setModeAndDates(of fd: Int32, as info: stat) throws {
        guard fchmod(fd, info.st_mode & 0o7777) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
        let times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(fd, times) == 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
    }

    /// The bytes of every regular file in the folder open at `folder`, links not followed.
    private static func bytes(in folder: Int32) throws -> Int64 {
        var total: Int64 = 0
        for entry in try LibraryOperations.names(in: folder) {
            var item = stat()
            guard fstatat(folder, entry, &item, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch item.st_mode & S_IFMT {
            case S_IFREG:
                total += Int64(item.st_size)
            case S_IFDIR:
                let inner = openat(folder, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard inner >= 0 else { throw POSIXError(LibraryOperations.errnoCode()) }
                defer { close(inner) }
                total += try bytes(in: inner)
            default:
                break
            }
        }
        return total
    }
}
