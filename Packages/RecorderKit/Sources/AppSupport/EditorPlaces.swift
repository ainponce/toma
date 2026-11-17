// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where an editor's package is, as the app tells the library which packages its editors have open and finds the editor
/// of a package the library acts on (1c design §6.6): by where the package is now, and by the path it was opened from only
/// while that path still names it. A session names its package by its real path (`F_GETPATH`), which differs from the
/// path it was opened from when the projects folder is reached through a link; once the package moved (renamed, restored
/// from the trash), the path it was opened from may name another project.
public struct EditorPlace: Equatable, Sendable {
    /// The path the editor was opened from.
    public var openedFrom: URL
    /// Where its session first found the package, once a session opened; `nil` before.
    public var firstSeen: URL?
    /// Where the package is now.
    public var current: URL

    public init(openedFrom: URL, firstSeen: URL?, current: URL) {
        self.openedFrom = openedFrom
        self.firstSeen = firstSeen
        self.current = current
    }

    /// The package is where it was when the editor opened it: the path it was opened from still names it.
    public var isWhereOpened: Bool {
        Self.path(firstSeen ?? openedFrom) == Self.path(current)
    }

    /// The paths that name the package now: where it is, and the path it was opened from while that still names it.
    public var paths: Set<URL> {
        var paths: Set<URL> = [current.standardizedFileURL]
        if isWhereOpened { paths.insert(openedFrom.standardizedFileURL) }
        return paths
    }

    /// Which of `places` has the package that `url` names now: one whose package is there first, otherwise one opened from
    /// `url` whose package has not moved since. `nil` if none: a project that took the path of one that moved is another.
    public static func index(at url: URL, in places: [EditorPlace]) -> Int? {
        let path = path(url)
        if let now = places.firstIndex(where: { Self.path($0.current) == path }) { return now }
        return places.firstIndex { $0.isWhereOpened && Self.path($0.openedFrom) == path }
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
