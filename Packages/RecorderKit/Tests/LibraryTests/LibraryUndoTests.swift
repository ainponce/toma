// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Library
import Testing

private func renamed(_ number: Int) -> LibraryAction {
    .renamed(from: URL(fileURLWithPath: "/P/\(number).toma"), to: URL(fileURLWithPath: "/P/\(number) b.toma"))
}

@Test func undoAndRedoPairUp() {
    var undo = LibraryUndo()
    #expect(!undo.canUndo && !undo.canRedo)
    #expect(undo.popUndo() == nil)
    #expect(undo.popRedo() == nil)

    let identity = PackageIdentity(volume: "V", file: 7)
    let actions: [LibraryAction] = [renamed(1), .favorite(identity, true), renamed(3)]
    for action in actions { undo.record(action) }
    #expect(undo.canUndo && !undo.canRedo)

    // The last first; what is undone can be done again, in the other order.
    #expect(undo.popUndo() == renamed(3))
    #expect(undo.popUndo() == .favorite(identity, true))
    #expect(undo.canUndo && undo.canRedo)
    #expect(undo.popRedo() == .favorite(identity, true))
    #expect(undo.popUndo() == .favorite(identity, true))

    // Something new forgets what was undone.
    let record = DuplicateRecord(copy: URL(fileURLWithPath: "/P/x copia.toma"), insideProjectsFolder: true)
    undo.record(.duplicated(record))
    #expect(!undo.canRedo)
    #expect(undo.popRedo() == nil)
    #expect(undo.popUndo() == .duplicated(record))
    #expect(undo.popUndo() == renamed(1))
    #expect(!undo.canUndo)
    #expect(undo.popRedo() == renamed(1))

    // At most `limit`: the oldest goes first.
    var long = LibraryUndo()
    for number in 1...(LibraryUndo.limit + 5) { long.record(renamed(number)) }
    var undone: [LibraryAction] = []
    while let action = long.popUndo() { undone.append(action) }
    #expect(LibraryUndo.limit == 100)
    #expect(undone.count == LibraryUndo.limit)
    #expect(undone.first == renamed(LibraryUndo.limit + 5))
    #expect(undone.last == renamed(6))
    // Every one of them can be done again.
    var redone = 0
    while long.popRedo() != nil { redone += 1 }
    #expect(redone == LibraryUndo.limit)
}

/// One command on several projects (a multiple selection) is one step: undone and done again whole, as in the Finder.
@Test func aStepIsUndoneAndRedoneWhole() {
    var undo = LibraryUndo()
    undo.record([])
    #expect(!undo.canUndo, "a command that did nothing is no step")
    undo.record(renamed(1))
    undo.record([renamed(2), renamed(3), renamed(4)])
    #expect(undo.popUndoStep() == [renamed(2), renamed(3), renamed(4)])
    #expect(undo.popRedoStep() == [renamed(2), renamed(3), renamed(4)])
    #expect(undo.popUndoStep() == [renamed(2), renamed(3), renamed(4)])
    #expect(undo.popUndoStep() == [renamed(1)])
    #expect(undo.popUndoStep().isEmpty)
    #expect(undo.popRedoStep() == [renamed(1)])
    #expect(undo.popRedoStep() == [renamed(2), renamed(3), renamed(4)])
    #expect(undo.popRedoStep().isEmpty)

    // One action at a time: the last of a step, the others stay one step.
    var single = LibraryUndo()
    single.record([renamed(1), renamed(2)])
    #expect(single.popUndo() == renamed(2))
    #expect(single.popUndoStep() == [renamed(1)])
    #expect(single.popRedoStep() == [renamed(1)])
    #expect(single.popRedoStep() == [renamed(2)])
}

/// What was undone or done again replaces the step that moved: its packages may be under other names now, and what
/// could not be undone is forgotten.
@Test func whatWasUndoneOrRedoneIsAmended() {
    let a = URL(fileURLWithPath: "/P/A.toma"), b = URL(fileURLWithPath: "/P/B.toma")
    let trashA = URL(fileURLWithPath: "/P/Trash/A.toma"), trashB = URL(fileURLWithPath: "/P/Trash/B.toma")
    let b2 = URL(fileURLWithPath: "/P/B 2.toma"), trashB2 = URL(fileURLWithPath: "/P/Trash/B 2.toma")
    var undo = LibraryUndo()
    undo.amendNextRedo([.trashed(from: a, to: trashA)])
    undo.amendNextUndo([.trashed(from: a, to: trashA)])
    #expect(!undo.canUndo && !undo.canRedo, "nothing moved: nothing to amend")

    undo.record(renamed(1))
    undo.record([.trashed(from: a, to: trashA), .trashed(from: b, to: trashB)])
    _ = undo.popUndoStep()
    // B came back as «B 2»; A could not be restored, and stays in the trash.
    undo.amendNextRedo([.trashed(from: b2, to: trashB)])
    #expect(undo.popRedoStep() == [.trashed(from: b2, to: trashB)])
    // Done again, it went to the trash under another name.
    undo.amendNextUndo([.trashed(from: b2, to: trashB2)])
    #expect(undo.popUndoStep() == [.trashed(from: b2, to: trashB2)])
    // Undone again, it could not be: forgotten, and the next undo is the one before.
    undo.amendNextRedo([])
    #expect(!undo.canRedo)
    #expect(undo.popUndoStep() == [renamed(1)])
}

/// The limit counts actions; whole steps are forgotten, the oldest first, but never the one just recorded.
@Test func theLimitForgetsWholeStepsButNeverTheNewest() {
    var undo = LibraryUndo()
    undo.record([renamed(1), renamed(2)])
    for number in 3...(LibraryUndo.limit) { undo.record(renamed(number)) }
    undo.record(renamed(1000))
    var steps: [[LibraryAction]] = []
    while case let step = undo.popUndoStep(), !step.isEmpty { steps.append(step) }
    #expect(steps.count == LibraryUndo.limit - 1, "the first step went whole, not one of its actions")
    #expect(steps.last == [renamed(3)])

    var big = LibraryUndo()
    big.record(renamed(1))
    let many = (1...150).map(renamed)
    big.record(many)
    #expect(big.popUndoStep() == many)
    #expect(!big.canUndo)
}
