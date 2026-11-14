// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which editors to show after recovery: every recovered project is listed to the user, but only a few open at
/// once, and an editor already open on one (still saying it hasn't finished saving) loads it again.
public enum RecoveredProjects {
    /// At most this many new editors open after one recovery.
    public static let maximumOpened = 3

    /// `reload`: the recovered projects that have an editor open, in recovery order. `open`: the first
    /// `maximumOpened` of the others, in recovery order. Projects are compared by their standardized URL.
    public static func editors(recovered: [URL], openEditors: Set<URL>) -> (reload: [URL], open: [URL]) {
        let open = Set(openEditors.map(\.standardizedFileURL))
        var seen: Set<URL> = []
        let unique = recovered.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        return (unique.filter { open.contains($0) }, Array(unique.filter { !open.contains($0) }.prefix(maximumOpened)))
    }
}
