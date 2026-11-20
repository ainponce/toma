// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The Replay's working package (fases 4 y 5 design §10.2): `<cachés>/dev.toma.Toma/Replay/current.toma`, outside the
/// library, where the Replay records its rolling take.
///
/// ```
/// Replay/
///   current.toma/
///     replay-scratch             the marker: written before any take, it says the package is never a project
///     manifest.json              take-001, `recording` while the Replay runs, its segments `rotated` every 10 s
///     takes/take-001/
///       <track>/seg-NNNN.mov     the segments not pruned yet
///       events-NNNN.jsonl        the events, one file every 10 s of time (`EventLogWriter.rotate(to:)`)
///       recording.lock           held while the Replay records
///       cursors/<hash>.png
/// ```
///
/// It is never recovered nor shown (decision 13): `RecoveryScanner` skips a package with the marker before it reads its
/// manifest, and whatever a forced quit leaves here is deleted, without asking, when Toma opens (`discardLeftovers`).
/// Nothing here follows a link: a link in the root, or the root itself if it is one, is never followed.
public enum ReplayScratch {
    public static let packageName = "current.toma"
    public static let markerName = "replay-scratch"
    /// The one take of the working package, and of a saved Replay.
    public static let takeID = "take-001"

    /// What a folder being deleted is renamed to first, so a deletion cut short leaves no package nor half of one
    /// under a name anything reads: only the next `discardLeftovers` sees it, and deletes it.
    static let discardingPrefix = ".discarding-"

    private static let markerContents = Data(
        "Toma's Replay working package. It is never a project: Toma deletes it whenever it opens.\n".utf8)

    /// `<cachés>/<bundleID>/Replay`.
    public static func defaultRoot(cachesDirectory: URL, bundleID: String) -> URL {
        cachesDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Replay", isDirectory: true)
    }

    /// `<root>/current.toma`, whether or not it is there.
    public static func package(in root: URL) -> ProjectPackage {
        ProjectPackage(url: root.appendingPathComponent(packageName, isDirectory: true))
    }

    /// Whether `package` has the marker: a regular file named `replay-scratch` in its root, looked at with `lstat`, so a
    /// link there is never followed nor taken for one.
    public static func isScratch(_ package: ProjectPackage) -> Bool {
        fileType(markerURL(of: package)) == S_IFREG
    }

    /// `takes/take-001/events-0001.jsonl` for index 1: the event files of the working take, one every segment of time.
    public static func shardURL(of package: ProjectPackage, index: Int) -> URL {
        package.takeDirectory(takeID).appendingPathComponent("events-" + String(format: "%04d", index) + ".jsonl", isDirectory: false)
    }

    /// Creates `root` if needed and `current.toma` with the marker (synced) and no take. One that is there already is
    /// deleted first when nobody records into it (its `recording.lock` is not held); with its lock held, throws
    /// `ReplayError.scratchInUse` and leaves it as it is.
    ///
    /// Throws `ELOOP` if `root` is a link and `ENOTDIR` if it is not a folder, without touching what it names.
    public static func create(in root: URL, app: AppInfo, now: Date) throws -> ProjectPackage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try requireFolder(root)
        let scratch = package(in: root)
        if fileType(scratch.url) != nil {
            if isLive(scratch) { throw ReplayError.scratchInUse }
            try remove(scratch.url, in: root)
        }
        let created = try ProjectPackage.create(
            in: root, name: (packageName as NSString).deletingPathExtension, app: app, now: now)
        do {
            // `writeNew`: full-synced, and the package's folder too, before any take can be added.
            try DurableFile.writeNew(markerContents, to: markerURL(of: created))
        } catch {
            try? remove(created.url, in: root)
            throw error
        }
        return created
    }

    /// Deletes everything in `root` but a `current.toma` whose `recording.lock` is held, and returns what it deleted (what
    /// it could not delete is left for the next time). A link in `root` is deleted, never what it names; a `root` that
    /// is a link, or not there, is left alone.
    @discardableResult public static func discardLeftovers(in root: URL) -> [URL] {
        guard fileType(root) == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var removed: [URL] = []
        for name in names.sorted() {
            if name == packageName, isLive(package(in: root)) { continue }
            let url = root.appendingPathComponent(name, isDirectory: false)
            do {
                try remove(url, in: root)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }

    /// Deletes the working package `package`, whole; with nothing there, it is done already. Throws `POSIXError(.EPERM)`,
    /// touching nothing, for anything but a folder with the marker: it never deletes a project.
    public static func discard(_ package: ProjectPackage) throws {
        guard let type = fileType(package.url) else { return }
        guard type == S_IFDIR, isScratch(package) else { throw POSIXError(.EPERM) }
        try remove(package.url, in: package.url.deletingLastPathComponent())
    }

    private static func markerURL(of package: ProjectPackage) -> URL {
        package.url.appendingPathComponent(markerName, isDirectory: false)
    }

    /// Whether `package` is the folder of a Replay that records right now: its `takes/take-001/recording.lock` is held,
    /// reached through folders that are not links.
    private static func isLive(_ package: ProjectPackage) -> Bool {
        guard [package.url, package.takesURL, package.takeDirectory(takeID)].allSatisfy({ fileType($0) == S_IFDIR }) else {
            return false
        }
        return RecordingLock.isHeld(at: package.lockURL(take: takeID))
    }

    /// Deletes the entry at `url`, a child of `root`: a folder is first renamed to a hidden name in `root`, so a deletion
    /// cut short never leaves part of a package under its own name. A link is deleted, never followed.
    private static func remove(_ url: URL, in root: URL) throws {
        guard let type = fileType(url) else { return }
        guard type == S_IFDIR, !url.lastPathComponent.hasPrefix(discardingPrefix) else {
            if type == S_IFDIR {
                try FileManager.default.removeItem(at: url)
            } else if unlink(url.path) != 0, errno != ENOENT {
                throw POSIXError.current()
            }
            return
        }
        let doomed = root.appendingPathComponent(discardingPrefix + UUID().uuidString, isDirectory: true)
        guard renamex_np(url.path, doomed.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError.current()
        }
        try FileManager.default.removeItem(at: doomed)
    }

    private static func requireFolder(_ url: URL) throws {
        switch fileType(url) {
        case S_IFDIR: return
        case S_IFLNK: throw POSIXError(.ELOOP)
        case nil: throw POSIXError(.ENOENT)
        default: throw POSIXError(.ENOTDIR)
        }
    }

    /// The type of what is at `url` (`S_IFDIR`, `S_IFREG`, `S_IFLNK`…), by `lstat`; `nil` if nothing is there.
    private static func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}
