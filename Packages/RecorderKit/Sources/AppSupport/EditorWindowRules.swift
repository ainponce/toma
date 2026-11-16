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

/// What closing an editor's window does (design §5.9): it asks first, one question at a time, in the order of
/// `questions`, and the first "no" keeps it open:
/// - when a change couldn't be saved and still isn't (the amber banner's `EditNotice.saveFailed`): "Some changes couldn't
///   be saved" (`UnsavedChangesAnswer`). A change merely on its way to the disk (a line being synced, the move to version
///   3, a new log being started: unsaved, but nothing failed) is not asked about: the session saves it as it closes. Quitting
///   asks the same (`losesEdits`, `TerminationQuestion.unsavedEdits`);
/// - while its export runs: whether to close and cancel it, as quitting asks. An export is never cancelled silently.
public enum EditorClosing: Equatable, Sendable {
    case close
    /// Asks `questions`.
    case ask
    /// Stays open: a question is up already.
    case keepOpen

    /// What closing asks.
    public enum Question: Equatable, Sendable {
        case unsavedChanges
        case cancelExport
    }

    /// From the session's `hasUnsavedChanges` and `notices`, and whether the editor's export runs.
    public static func decide(
        hasUnsavedChanges: Bool, notices: [EditNotice], isExporting: Bool = false, isAsking: Bool
    ) -> EditorClosing {
        if isAsking { return .keepOpen }
        return questions(hasUnsavedChanges: hasUnsavedChanges, notices: notices, isExporting: isExporting).isEmpty ? .close : .ask
    }

    /// What closing asks now, in order.
    public static func questions(hasUnsavedChanges: Bool, notices: [EditNotice], isExporting: Bool) -> [Question] {
        var questions: [Question] = []
        if losesEdits(hasUnsavedChanges: hasUnsavedChanges, notices: notices) { questions.append(.unsavedChanges) }
        if isExporting { questions.append(.cancelExport) }
        return questions
    }

    /// Whether closing the session now loses edits: a change couldn't be saved and still isn't.
    public static func losesEdits(hasUnsavedChanges: Bool, notices: [EditNotice]) -> Bool {
        hasUnsavedChanges && notices.contains { if case .saveFailed = $0 { true } else { false } }
    }
}

/// The answers to "Some changes couldn't be saved", in the alert's order: the first, "Keep Open", is the default.
public enum UnsavedChangesAnswer: CaseIterable, Sendable {
    case keepOpen
    case closeAnyway

    public var closesTheWindow: Bool { self == .closeAnyway }
}

/// The answers to "An export is in progress. Close the window and cancel it?", in the alert's order: the first,
/// "Cancel", is the default; "Close" cancels the export (its partial file removed) and closes the window.
public enum ExportClosingAnswer: CaseIterable, Sendable {
    case cancel
    case close

    public var closesTheWindow: Bool { self == .close }
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
