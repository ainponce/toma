// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
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
