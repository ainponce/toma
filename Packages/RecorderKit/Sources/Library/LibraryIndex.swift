// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The cached index of the library (design §13.4, plan decision 25): what it knew of every project the last time it
/// looked, so the window draws at once. `{ "projects": [ProjectSummary…], "version": 2 }`, written whole with
/// `DurableFile.writeAtomically` (through a `DebouncedWriter`). A cache: if it is lost, the scan builds it again.
public struct LibraryIndex: Codable, Equatable, Sendable {
    /// The version this app writes and reads. 2: the phase 2 app (manifest version 4) and the phase 1 app share the
    /// cache file, and a cached summary keeps its `state` while the signatures do not change, so each must discard the
    /// other's index and scan again (a v4 package that phase 1 indexed as `.newerVersion` must not stay so).
    public static let currentVersion = 2

    public var version: Int
    public var projects: [ProjectSummary]

    public init(version: Int = LibraryIndex.currentVersion, projects: [ProjectSummary] = []) {
        self.version = version
        self.projects = projects
    }

    /// `~/Library/Caches/dev.toma.Toma/Library/index.json`.
    public static var defaultURL: URL {
        URL.cachesDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "index.json", directoryHint: .notDirectory)
    }

    /// The index at `url`; an empty one if it is missing, cannot be read (a link or a FIFO is not followed nor waited
    /// on), is damaged or is of another version.
    public static func load(from url: URL) -> LibraryIndex {
        guard let data = try? SafeRead.regularFile(at: url),
            let index = try? ProjectJSON.decoder().decode(LibraryIndex.self, from: data),
            index.version == currentVersion
        else { return LibraryIndex() }
        return index
    }

    /// The JSON with `ProjectJSON.encoder()`'s rules.
    public func encoded() throws -> Data {
        try ProjectJSON.encoder().encode(self)
    }
}
