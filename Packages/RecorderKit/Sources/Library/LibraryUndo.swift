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

/// The library's undo and redo, in memory while its window is open, as in the Finder (decision 32): at most `limit`
/// actions, the oldest forgotten first. Popping an action moves it to the other stack; recording a new one forgets
/// what was undone.
public struct LibraryUndo: Sendable {
    public static let limit = 100

    private var undoStack: [LibraryAction] = []
    private var redoStack: [LibraryAction] = []

    public init() {}

    /// `action` was just done: it is the next to undo, and nothing can be redone any more.
    public mutating func record(_ action: LibraryAction) {
        undoStack.append(action)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }

    /// The last action done, to undo; it becomes the next to redo. `nil` if there is none.
    public mutating func popUndo() -> LibraryAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    /// The last action undone, to do again; it becomes the next to undo. `nil` if there is none.
    public mutating func popRedo() -> LibraryAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
}
