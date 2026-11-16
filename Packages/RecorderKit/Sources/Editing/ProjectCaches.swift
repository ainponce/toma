// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import ProjectFormat

/// The cache folder of a project, outside its package (design §6.1): `<root>/<projectID>/` with `thumbnails/`,
/// `waveforms/`, `suggestions/` and `editor-state.json`. Everything in it can be made again, nothing needs it to open or
/// export, and macOS may empty it; the same folder serves every version of the format, since a version 1 or 2 package
/// uses its derived id (`Manifest.resolvedProjectID`), the one it keeps once upgraded.
public struct ProjectCaches: Sendable {
    /// `~/Library/Caches/dev.toma.Toma/Projects`. Computed: a stored `static var` is not concurrency-safe.
    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    /// `<root>/<projectID>/`.
    public var directory: URL

    /// The folder of project `projectID` in `root`. The folder is always one name inside `root`: an id that is not 32
    /// lowercase hex digits (never one a loaded manifest has: `Manifest.validatePaths()` refuses it) is replaced by the
    /// first 16 bytes of the SHA-256 of its UTF-8, in hex, so no id can name a folder elsewhere.
    public init(root: URL, projectID: String) {
        let name = ProjectID.isValid(projectID)
            ? projectID : SHA256.hash(data: Data(projectID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        directory = root.appending(path: name, directoryHint: .isDirectory)
    }

    public var thumbnails: URL { directory.appending(path: "thumbnails", directoryHint: .isDirectory) }
    public var waveforms: URL { directory.appending(path: "waveforms", directoryHint: .isDirectory) }
    /// The planners' output, with their version and a fingerprint of their inputs.
    public var suggestions: URL { directory.appending(path: "suggestions", directoryHint: .isDirectory) }
    /// The state of the editor's window (design §5.1).
    public var editorState: URL { directory.appending(path: "editor-state.json", directoryHint: .notDirectory) }
}

// MARK: - Removing unused folders

extension ProjectCaches {
    /// Removes the cache folder of every project in `root` not used for more than `age` before `now` (plan decision 27;
    /// the app does it as it starts, when no project is open). A folder was last used when it or its
    /// `editor-state.json`, which the window saves, was last modified, whichever is later. Nothing depends on the folders:
    /// a project whose folder is removed makes it again.
    ///
    /// Only the entries of `root` named like a project's id (32 lowercase hex digits) that are folders count; anything
    /// else, a symlink among them, is left alone and never followed. What cannot be read or removed is skipped. Reads
    /// and removes files: never on the main thread.
    public static func removeUnused(olderThan age: TimeInterval = 30 * 86_400, root: URL, now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where ProjectID.isValid(name) {
            let caches = ProjectCaches(root: root, projectID: name)
            guard let used = caches.lastUse, now.timeIntervalSince(used) > age else { continue }
            try? FileManager.default.removeItem(at: caches.directory)
        }
    }

    /// The later of the modification dates of `directory` and `editorState`, by `lstat`; `nil` unless `directory` is a
    /// folder.
    private var lastUse: Date? {
        func modified(_ url: URL, type: mode_t) -> Date? {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        }
        guard let folder = modified(directory, type: S_IFDIR) else { return nil }
        return max(folder, modified(editorState, type: S_IFREG) ?? folder)
    }
}

// MARK: - What the caches share

extension ProjectCaches {
    /// The bytes of the cache file `url`, or `nil` if it is not there, is not a regular file (a symlink is not followed,
    /// a FIFO is not waited on) or cannot be read.
    static func read(_ url: URL) -> Data? {
        try? SafeRead.regularFile(at: url)
    }

    /// Writes `data` to the cache file `url`, making its folder if macOS emptied it: through a temporary file in the same
    /// folder renamed over it, so a reader sees the old file or the new one, never part of one. Not synced to the drive:
    /// a cache can be made again. A write that fails leaves nothing; whether it was written.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .withoutOverwriting)
            guard rename(temporary.path, url.path) == 0 else {
                unlink(temporary.path)
                return false
            }
            return true
        } catch {
            unlink(temporary.path)
            return false
        }
    }
}

/// Work that every caller asking for the same key while it runs shares, for the caches' actors: the first caller starts
/// it, the others wait for the same result, and it is cancelled once every caller waiting for it was cancelled. Kept by
/// the actor, which calls it only from its own isolation.
struct SharedWork<Value: Sendable> {
    private var running: [String: (task: Task<Value, Never>, waiters: Int)] = [:]

    /// The work for `key`: the one running, now with one more waiter, or the one `start` makes.
    mutating func join(_ key: String, start: () -> Task<Value, Never>) -> Task<Value, Never> {
        if var entry = running[key] {
            entry.waiters += 1
            running[key] = entry
            return entry.task
        }
        let task = start()
        running[key] = (task, 1)
        return task
    }

    /// A waiter of `task` was cancelled: once none waits for it, the work is cancelled and the next caller starts anew.
    mutating func leave(_ key: String, _ task: Task<Value, Never>) {
        guard var entry = running[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters > 0 {
            running[key] = entry
        } else {
            running[key] = nil
            task.cancel()
        }
    }

    /// `task` returned to a waiter: the next caller for `key` starts anew (and finds what it left on disk).
    mutating func finish(_ key: String, _ task: Task<Value, Never>) {
        if running[key]?.task == task { running[key] = nil }
    }
}
