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
