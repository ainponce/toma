// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation

/// What Edit ▸ Undo or Edit ▸ Redo offers in an editor (design §5.2): the action, by its name, when the session would do
/// it; a plain, disabled item when it would refuse it (a `migrate` that cut the history, a log being started again), and
/// while a drag is under way, whose end is an edit of its own. An action this app has no name for (a newer app's) is
/// offered without one.
public struct UndoMenuItem: Equatable, Sendable {
    public var isEnabled: Bool
    /// What it undoes or redoes; `nil` when it is not offered or has no name.
    public var label: EditLabel?

    public static let unavailable = UndoMenuItem(isEnabled: false, label: nil)

    public init(isEnabled: Bool, label: EditLabel?) {
        self.isEnabled = isEnabled
        self.label = label
    }

    /// From the session's label (`EditSession.undoLabel` or `redoLabel`) and whether it would do it now (`canUndo` or
    /// `canRedo`).
    public init(label: EditLabel?, sessionWouldDoIt: Bool, isGesturing: Bool) {
        let enabled = sessionWouldDoIt && !isGesturing
        self.init(isEnabled: enabled, label: enabled ? label : nil)
    }
}

/// What closing an editor's window does (design §5.9): when a change couldn't be saved and still isn't (the amber
/// banner's `EditNotice.saveFailed`), it asks first ("Some changes couldn't be saved"), one question at a time. A change
/// merely on its way to the disk (a line being synced, the move to version 3, a new log being started: unsaved, but
/// nothing failed) is not asked about: the session saves it as it closes.
public enum EditorClosing: Equatable, Sendable {
    case close
    /// Asks, with `UnsavedChangesAnswer`.
    case ask
    /// Stays open: the question is up already.
    case keepOpen

    /// From the session's `hasUnsavedChanges` and `notices`.
    public static func decide(hasUnsavedChanges: Bool, notices: [EditNotice], isAsking: Bool) -> EditorClosing {
        if isAsking { return .keepOpen }
        let saveFailed = notices.contains { if case .saveFailed = $0 { true } else { false } }
        return hasUnsavedChanges && saveFailed ? .ask : .close
    }
}

/// The answers to "Some changes couldn't be saved", in the alert's order: the first, "Keep Open", is the default.
public enum UnsavedChangesAnswer: CaseIterable, Sendable {
    case keepOpen
    case closeAnyway

    public var closesTheWindow: Bool { self == .closeAnyway }
}

/// A project package as a folder on its volume (its device and inode): the same through a symlink and after it is renamed
/// or moved on its volume, as an open one may be. Opening a project an editor has open already brings that editor forward
/// instead of opening a second session on the package.
public struct PackageIdentity: Hashable, Sendable {
    private let device: Int32
    private let inode: UInt64

    /// The package at `url`, following symlinks; `nil` if nothing is there or it is not a folder.
    public init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}
