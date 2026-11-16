// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The folders a sync service keeps in the cloud: iCloud Drive (`~/Library/Mobile Documents`) and the file providers
/// (`~/Library/CloudStorage`). A take is never recorded into them, and the library never reads media there.
public enum SyncedFolders {
    /// Whether `url` is one of them or inside one, whether or not it exists yet.
    public static func contains(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let synced = ["Library/Mobile Documents", "Library/CloudStorage"].map {
            normalizedPath(home.appending(path: $0, directoryHint: .isDirectory))
        }
        let path = normalizedPath(url)
        return synced.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Lowercased on purpose: a conservative choice for default (case-insensitive) APFS.
    /// Standardized, lowercased path with symlinks resolved on the nearest existing ancestor, so
    /// that a location that does not exist yet still compares correctly.
    private static func normalizedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in rest { resolved.append(path: component) }
        return resolved.standardizedFileURL.path.lowercased()
    }
}
