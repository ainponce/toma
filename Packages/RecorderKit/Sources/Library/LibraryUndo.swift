// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Something the user did in the library that can be undone (design §6.3, decision 32). Deleting forever is not one.
public enum LibraryAction: Equatable, Sendable {
    /// The package was renamed in its folder.
    case renamed(from: URL, to: URL)
    /// The package went to the library's trash.
    case trashed(from: URL, to: URL)
    /// The package came back from the trash.
    case restored(from: URL, to: URL)
    /// The project was added to the favorites (`true`) or taken out of them (`false`).
    case favorite(PackageIdentity, Bool)
    /// A project of Other places was taken out of the library; its file stayed where it is.
    case removedFromLibrary(OtherPlace)
    /// A copy was made; undoing it is `LibraryOperations.undoDuplicate`.
    case duplicated(DuplicateRecord)
}

/// The library's undo and redo, in memory while its window is open, as in the Finder (decision 32). What one command
/// did is one step, undone and done again whole: several actions when it acted on several projects at once. At most
/// `limit` actions are kept: the oldest steps are forgotten first, whole, but never the one just recorded. Popping
/// moves to the other stack; recording a new step forgets what was undone.
///
/// Undoing or doing again can leave a package under another name than the one it had («nombre 2» when its name was
/// taken meanwhile) or fail: the caller then amends the step that moved (`amendNextRedo`, `amendNextUndo`), so the next
/// redo or undo finds each package where it is.
public struct LibraryUndo: Sendable {
    public static let limit = 100

    /// Steps, oldest first; each step's actions in the order they were done.
    private var undoStack: [[LibraryAction]] = []
    private var redoStack: [[LibraryAction]] = []

    public init() {}

    /// `action` was just done: it is the next to undo, and nothing can be redone any more.
    public mutating func record(_ action: LibraryAction) {
        record([action])
    }

    /// `actions` were just done by one command, in this order: they are the next step to undo, and nothing can be
    /// redone any more. Nothing happens for none.
    public mutating func record(_ actions: [LibraryAction]) {
        guard !actions.isEmpty else { return }
        undoStack.append(actions)
        var count = undoStack.reduce(0) { $0 + $1.count }
        while count > Self.limit, undoStack.count > 1 {
            count -= undoStack.removeFirst().count
        }
        redoStack.removeAll()
    }

    /// The last action done, to undo; it becomes the next to redo, a step by itself (the others of its step stay one).
    /// `nil` if there is none.
    public mutating func popUndo() -> LibraryAction? {
        Self.popLast(from: &undoStack, to: &redoStack)
    }

    /// The last action undone, to do again; it becomes the next to undo, a step by itself. `nil` if there is none.
    public mutating func popRedo() -> LibraryAction? {
        Self.popLast(from: &redoStack, to: &undoStack)
    }

    /// The last step done, its actions in the order they were done, to undo together; it becomes the next to redo.
    /// Empty if there is none.
    public mutating func popUndoStep() -> [LibraryAction] {
        guard let step = undoStack.popLast() else { return [] }
        redoStack.append(step)
        return step
    }

    /// The last step undone, its actions in the order they were done, to do again together; it becomes the next to
    /// undo. Empty if there is none.
    public mutating func popRedoStep() -> [LibraryAction] {
        guard let step = redoStack.popLast() else { return [] }
        undoStack.append(step)
        return step
    }

    /// The next step to redo (the one `popUndoStep` just moved there) as it was undone: `actions` replace it, in the
    /// order they were done, each as it is now; those that could not be undone are left out. With none left, it is
    /// forgotten. Nothing happens if there is nothing to redo.
    public mutating func amendNextRedo(_ actions: [LibraryAction]) {
        Self.amendLast(of: &redoStack, actions)
    }

    /// The next step to undo (the one `popRedoStep` just moved there) as it was done again: `actions` replace it, as
    /// `amendNextRedo` says.
    public mutating func amendNextUndo(_ actions: [LibraryAction]) {
        Self.amendLast(of: &undoStack, actions)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private static func popLast(from source: inout [[LibraryAction]], to destination: inout [[LibraryAction]]) -> LibraryAction? {
        guard var step = source.popLast(), let action = step.popLast() else { return nil }
        if !step.isEmpty { source.append(step) }
        destination.append([action])
        return action
    }

    private static func amendLast(of stack: inout [[LibraryAction]], _ actions: [LibraryAction]) {
        guard !stack.isEmpty else { return }
        if actions.isEmpty {
            stack.removeLast()
        } else {
            stack[stack.count - 1] = actions
        }
    }
}
