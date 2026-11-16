// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Editing
import Foundation
import ProjectFormat

/// When the editor's window writes its state (design §5.1, `editor-state.json` in the project's caches): every `interval`
/// while it is open, if the state changed since it was last written, and when it closes, always (which also marks the
/// project as used for `ProjectCaches.removeUnused`). It starts from the state read when the window opened: a window
/// whose state was never read writes nothing.
public struct EditorStateAutosave: Equatable, Sendable {
    public static let interval = Duration.seconds(5)

    /// The state last written, or read when the window opened.
    public private(set) var written: EditorState

    public init(restored: EditorState) {
        written = restored
    }

    /// Every `interval`: `current` if it is not the state last written (it is the one written then); `nil` otherwise.
    public mutating func due(_ current: EditorState) -> EditorState? {
        guard current != written else { return nil }
        written = current
        return current
    }

    /// When the window closes: `current`, changed or not.
    public mutating func closing(_ current: EditorState) -> EditorState {
        written = current
        return current
    }
}

/// Where an editor's window opens (design §5.1): where it was when its state was last written, if its title bar can still
/// be reached on a screen; otherwise at its initial size, centered.
public enum EditorWindowPlacement {
    /// The top of a window that has to be on a screen to move it: its title bar.
    public static let titleBarHeight = 28.0
    /// How much of the title bar's width has to be on one screen.
    public static let reachableWidth = 100.0

    /// `saved` (a window's frame as AppKit gives it, from the bottom left) if at least `reachableWidth` of its title bar,
    /// and the title bar's whole height, is on one of `screens` (their visible frames); its size then between
    /// `minimumSize` and the size of the screen with the most of its title bar, its top-left corner where it was. `nil`
    /// without a saved frame, or when no screen shows its title bar: the window opens at its initial size.
    public static func frame(restoring saved: Rect?, screens: [CGRect], minimumSize: CGSize) -> CGRect? {
        guard let saved else { return nil }
        let frame = CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - titleBarHeight, width: frame.width, height: titleBarHeight)
        let reachable = screens.compactMap { screen -> (screen: CGRect, width: Double)? in
            let shown = screen.intersection(titleBar)
            guard !shown.isNull, shown.width >= reachableWidth, shown.height >= titleBarHeight else { return nil }
            return (screen, shown.width)
        }
        guard let screen = reachable.max(by: { $0.width < $1.width })?.screen else { return nil }
        let width = max(min(frame.width, screen.width), minimumSize.width)
        let height = max(min(frame.height, screen.height), minimumSize.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }
}

/// Where an editor's state is before its project opens: the window takes its frame and its panel from it before it shows.
public enum EditorStateFile {
    /// The cache folder in `root` of the project whose package is at `url`, the one its edit session uses
    /// (`EditSession.caches`): named after its manifest's id (`Manifest.resolvedProjectID`, the derived one in a version 1
    /// or 2 package). `nil` if the manifest is not a regular file (a symlink is not followed) or does not decode. Reads a
    /// file: never on the main thread.
    public static func caches(ofPackageAt url: URL, root: URL) -> ProjectCaches? {
        guard let data = try? SafeRead.regularFile(at: ProjectPackage(url: url).manifestURL),
            let manifest = try? ProjectJSON.decoder().decode(Manifest.self, from: data)
        else { return nil }
        return ProjectCaches(root: root, projectID: manifest.resolvedProjectID)
    }
}
