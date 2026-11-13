// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// A project on disk: a `.toma` folder that Finder shows as a single document.
///
/// ```
/// Name.toma/
///   manifest.json
///   edit.json
///   takes/<take>/<track>/seg-0001.mov
///   takes/<take>/events.jsonl
///   takes/<take>/recording.lock
///   cache/
/// ```
public struct ProjectPackage: Sendable, Hashable {
    public static let fileExtension = "toma"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Creates `<directory>/<name>.toma` with `takes/`, `cache/` and an empty manifest.
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
                takes: []
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
    public var cacheURL: URL { url.appendingPathComponent("cache", isDirectory: true) }
    var takesURL: URL { url.appendingPathComponent("takes", isDirectory: true) }

    public func takeDirectory(_ take: String) -> URL {
        takesURL.appendingPathComponent(take, isDirectory: true)
    }

    public func trackDirectory(take: String, track: String) -> URL {
        takeDirectory(take).appendingPathComponent(track, isDirectory: true)
    }

    /// `takes/<take>/<track>/seg-0001.mov`
    public func segmentURL(take: String, track: String, index: Int) -> URL {
        let name = "seg-" + String(format: "%04d", index) + ".mov"
        return trackDirectory(take: take, track: track).appendingPathComponent(name, isDirectory: false)
    }

    public func eventsURL(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("events.jsonl", isDirectory: false)
    }

    public func lockURL(take: String) -> URL {
        takeDirectory(take).appendingPathComponent("recording.lock", isDirectory: false)
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
