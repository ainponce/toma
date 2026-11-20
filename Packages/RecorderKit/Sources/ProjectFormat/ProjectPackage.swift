// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

/// A project on disk: a `.toma` folder that Finder shows as a single document.
///
/// ```
/// Name.toma/
///   manifest.json
///   edit.json
///   edit-log.jsonl
///   edit.lock
///   script.txt
///   assets/<sha>.<ext>
///   takes/<take>/<track>/seg-0001.mov
///   takes/<take>/events.jsonl
///   takes/<take>/recording.lock
///   takes/<take>/wallpapers/display-<id>.png
///   takes/<take>/cursors/<hash>.png
///   cache/
/// ```
public struct ProjectPackage: Sendable, Hashable {
    public static let fileExtension = "toma"

    /// Where the package was when this value was made: its identity (two packages are the same if their `url`s are).
    public let url: URL
    /// With one, the files a reader opens later are found where the package is now (`currentURL`): an editor's preview
    /// and export go on reading a package renamed or moved on its disk while they read it (1c Task 39).
    public let handle: PackageHandle?

    public init(url: URL) {
        self.init(url: url, handle: nil)
    }

    public init(url: URL, handle: PackageHandle?) {
        self.url = url
        self.handle = handle
    }

    /// Where the package is now: where its `handle` finds it, or `url` without one.
    public var currentURL: URL { handle?.url ?? url }

    public static func == (a: ProjectPackage, b: ProjectPackage) -> Bool {
        a.url == b.url
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    /// Creates `<directory>/<name>.toma` with `takes/`, `cache/` and an empty manifest of the current format
    /// version (`Manifest.currentFormatVersion`) with a random `projectID`.
    ///
    /// `directory` must already exist. Throws `CocoaError(.fileWriteFileExists)` if the
    /// package already exists, leaving it untouched.
    public static func create(in directory: URL, name: String, app: AppInfo, now: Date) throws -> ProjectPackage {
        let package = ProjectPackage(url: directory.appendingPathComponent("\(name).\(fileExtension)", isDirectory: true))
        guard mkdir(package.url.path, 0o755) == 0 else {
            let error = POSIXError.current()
            if error.code == .EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: package.url.path, NSUnderlyingErrorKey: error])
            }
            throw error
        }
        do {
            for subdirectory in [package.takesURL, package.cacheURL] {
                guard mkdir(subdirectory.path, 0o755) == 0 else { throw POSIXError.current() }
            }
            let manifest = Manifest(
                formatVersion: Manifest.currentFormatVersion,
                app: app,
                createdAt: now.roundedToWholeSeconds,
                takes: [],
                projectID: ProjectID.random()
            )
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
            try DurableFile.syncDirectory(directory)
        } catch {
            // The package was created by this call and holds no recording yet.
            try? FileManager.default.removeItem(at: package.url)
            throw error
        }
        return package
    }

    public var manifestURL: URL { url.appendingPathComponent("manifest.json", isDirectory: false) }
    public var editURL: URL { url.appendingPathComponent("edit.json", isDirectory: false) }
    /// `edit-log.jsonl`: the editor's log of changes (version 3).
    public var editLogURL: URL { url.appendingPathComponent("edit-log.jsonl", isDirectory: false) }
    /// `edit.lock`: held with `flock` by the editor that writes the package (version 3).
    public var editLockURL: URL { url.appendingPathComponent("edit.lock", isDirectory: false) }
    /// `assets/`: the images of the user's own backgrounds, copied into the package (version 3), and the `.cube`s, the
    /// clips and the sounds of the user's own (`PackageFileKind`).
    public var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    /// `script.txt`: the project's script for the teleprompter (phase 3 design §8.5), read and written with
    /// `readScript()` and `writeScript(_:)`, never through this URL.
    public var scriptURL: URL { url.appendingPathComponent(PackageFileKind.scriptFileName, isDirectory: false) }
    public var cacheURL: URL { url.appendingPathComponent("cache", isDirectory: true) }
    /// `takes/`, which holds one folder per take.
    public var takesURL: URL { url.appendingPathComponent("takes", isDirectory: true) }

    public func takeDirectory(_ take: String) -> URL {
        takesURL.appendingPathComponent(take, isDirectory: true)
    }

    public func trackDirectory(take: String, track: String) -> URL {
        takeDirectory(take).appendingPathComponent(track, isDirectory: true)
    }

    /// `takes/<take>/<track>/seg-0001.mov`
    public func segmentURL(take: String, track: String, index: Int) -> URL {
        trackDirectory(take: take, track: track).appendingPathComponent(Self.segmentFileName(index: index), isDirectory: false)
    }

    public func eventsURL(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("events.jsonl", isDirectory: false)
    }

    public func lockURL(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("recording.lock", isDirectory: false)
    }

    /// `takes/<take>/wallpapers/`: optional, a picture of the wallpaper of each display the take records, as it
    /// was when the take started.
    public func wallpapersDirectory(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("wallpapers", isDirectory: true)
    }

    /// `takes/<take>/cursors/`: the images of the cursor the take recorded (version 3).
    public func cursorsDirectory(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("cursors", isDirectory: true)
    }

    /// `takes/<take>/cursors/<hash>.png`: the image a `cursorImage` event with this `hash` names. `hash` is used as
    /// given: whoever reads through it checks the name first.
    public func cursorImageURL(take: String, hash: String) -> URL {
        cursorsDirectory(take: take).appendingPathComponent("\(hash).png", isDirectory: false)
    }

    /// `takes/<take>/.reserve`: space the recorder holds while recording a take and frees to close it
    /// when the disk fills. Never take data: recovery removes it.
    public func reserveURL(take: String) -> URL {
        takeDirectory(take).appendingPathComponent(".reserve", isDirectory: false)
    }

    /// The path of a file inside the package relative to its root, as stored in the manifest.
    ///
    /// Symlinks in both URLs are resolved, so a file reached through another path to the same
    /// folder (for example `/var` and `/private/var`) still resolves. The file does not need to
    /// exist yet. Throws `ProjectPackageError.notInsidePackage` for any other URL.
    public func relativePath(of fileURL: URL) throws -> String {
        if let path = Self.relativePath(of: fileURL.standardizedFileURL.pathComponents, under: url.standardizedFileURL.pathComponents) {
            return path
        }
        if let path = Self.relativePath(of: Self.resolvingSymlinks(fileURL), under: Self.resolvingSymlinks(url)) {
            return path
        }
        throw ProjectPackageError.notInsidePackage(fileURL)
    }

    private static func relativePath(of file: [String], under root: [String]) -> String? {
        guard file.count > root.count, file.starts(with: root) else { return nil }
        return file.dropFirst(root.count).joined(separator: "/")
    }

    /// The path components of `url` with every symlink resolved.
    ///
    /// `URL.resolvingSymlinksInPath()` leaves a path untouched when its last component does not
    /// exist (a segment about to be written), so this resolves the deepest existing ancestor
    /// with `realpath(3)` and appends the components that do not exist yet.
    private static func resolvingSymlinks(_ url: URL) -> [String] {
        var existing = url.standardizedFileURL.pathComponents
        var missing: [String] = []
        while !existing.isEmpty {
            if let resolved = realpath(NSString.path(withComponents: existing), nil) {
                defer { free(resolved) }
                return URL(fileURLWithPath: String(cString: resolved)).pathComponents + missing.reversed()
            }
            missing.append(existing.removeLast())
        }
        return url.standardizedFileURL.pathComponents
    }

    /// The first `take-NNN` after the highest one in `existing` whose folder does not exist yet.
    ///
    /// Numbers are never reused, so a removed take cannot be confused with a newer one.
    public func nextTakeID(existing: [TakeRecord]) -> String {
        var number = (existing.compactMap { Self.takeNumber(of: $0.id) }.max() ?? 0) + 1
        while true {
            let id = "take-" + String(format: "%03d", number)
            if !FileManager.default.fileExists(atPath: takeDirectory(id).path) {
                return id
            }
            number += 1
        }
    }

    private static func takeNumber(of id: String) -> Int? {
        guard id.hasPrefix("take-") else { return nil }
        return Int(id.dropFirst("take-".count))
    }
}

public enum ProjectPackageError: Error, Equatable {
    /// The URL is not a file inside the package.
    case notInsidePackage(URL)
}

/// A package's folder, open, so that where it is now can be asked at any time (`F_GETPATH`, which follows a rename or a
/// move on its disk), for readers that open its files after it moved (`ProjectPackage.handle`). Holds a descriptor of
/// the folder for as long as it lives, and nothing else: no lock, no write.
public final class PackageHandle: Sendable {
    private let descriptor: Int32
    private let lastSeen: Mutex<URL>

    /// The folder at `url` (a link to it is followed, as the Finder opens a package); `nil` if it cannot be opened. Reads
    /// the disk: never on the main thread.
    public init?(url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
        lastSeen = Mutex(url)
        _ = self.url
    }

    deinit {
        close(descriptor)
    }

    /// Where the folder is now; where it was last seen if that cannot be told (it was deleted).
    public var url: URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let path = buffer.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, fcntl(descriptor, F_GETPATH, base) != -1 else { return nil }
            return String(cString: base)
        }
        guard let path else { return lastSeen.withLock { $0 } }
        let found = URL(fileURLWithPath: path, isDirectory: true)
        lastSeen.withLock { $0 = found }
        return found
    }
}
