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
    public func relativePath(of fileURL: URL) -> String {
        let root = url.standardizedFileURL.pathComponents
        let file = fileURL.standardizedFileURL.pathComponents
        precondition(
            file.count > root.count && file.starts(with: root),
            "\(fileURL.path) is not inside the package \(url.path)"
        )
        return file.dropFirst(root.count).joined(separator: "/")
    }

    /// The first `take-NNN` after the highest one in `existing` whose folder does not exist yet.
    ///
    /// Numbers are never reused, so a removed take cannot be confused with a newer one.
    public func nextTakeID(existing: [TakeRecord]) -> String {
        let used = Set(existing.map(\.id))
        var number = (existing.compactMap { Self.takeNumber(of: $0.id) }.max() ?? 0) + 1
        while true {
            let id = "take-" + String(format: "%03d", number)
            if !used.contains(id), !FileManager.default.fileExists(atPath: takeDirectory(id).path) {
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
