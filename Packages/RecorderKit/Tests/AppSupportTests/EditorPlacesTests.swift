// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

/// Where an editor's package is, for the library (1c Task 39, I2): the path it was opened from counts only while the
/// package is still there; a project that takes that path afterwards is another one.
@Suite struct EditorPlacesTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Renamed A → A2 in the editor, then another project takes «A»: the library's actions on «A» find no editor, and the
    /// editor is open at «A2» only.
    @Test func anotherProjectThatTakesTheOldPathIsNotOpenHere() {
        let renamed = EditorPlace(openedFrom: url("/P/A.toma"), firstSeen: url("/P/A.toma"), current: url("/P/A2.toma"))
        #expect(!renamed.isWhereOpened)
        #expect(renamed.paths == [url("/P/A2.toma")])
        #expect(EditorPlace.index(at: url("/P/A.toma"), in: [renamed]) == nil)
        #expect(EditorPlace.index(at: url("/P/A2.toma"), in: [renamed]) == 0)

        // Named «A» again: the path it was opened from names it once more.
        let back = EditorPlace(openedFrom: url("/P/A.toma"), firstSeen: url("/P/A.toma"), current: url("/P/A.toma"))
        #expect(back.isWhereOpened && EditorPlace.index(at: url("/P/A.toma"), in: [back]) == 0)
    }

    /// Restored from the trash, and another «A» trashed and opened since: the trash's «A» is the second editor's, never the
    /// first one's, whose package is in the projects folder now.
    @Test func aRestoredProjectLeavesItsTrashPathToTheNextOne() {
        let restored = EditorPlace(openedFrom: url("/P/Trash/A.toma"), firstSeen: url("/P/Trash/A.toma"), current: url("/P/A.toma"))
        let next = EditorPlace(openedFrom: url("/P/Trash/A.toma"), firstSeen: url("/P/Trash/A.toma"), current: url("/P/Trash/A.toma"))
        #expect(EditorPlace.index(at: url("/P/Trash/A.toma"), in: [restored, next]) == 1)
        #expect(EditorPlace.index(at: url("/P/A.toma"), in: [restored, next]) == 0)
        #expect(EditorPlace.index(at: url("/P/Trash/A.toma"), in: [restored]) == nil)
        #expect(restored.paths.union(next.paths) == [url("/P/A.toma"), url("/P/Trash/A.toma")])
    }

    /// The projects folder reached through a link: the session names the package by its real path; until it moves, the
    /// library's path (the link's) still finds its editor, and is still open here.
    @Test func thePathOpenedThroughALinkCountsUntilThePackageMoves() {
        let linked = EditorPlace(openedFrom: url("/Link/A.toma"), firstSeen: url("/Real/A.toma"), current: url("/Real/A.toma"))
        #expect(linked.isWhereOpened)
        #expect(linked.paths == [url("/Link/A.toma"), url("/Real/A.toma")])
        #expect(EditorPlace.index(at: url("/Link/A.toma"), in: [linked]) == 0)

        let moved = EditorPlace(openedFrom: url("/Link/A.toma"), firstSeen: url("/Real/A.toma"), current: url("/Real/B.toma"))
        #expect(EditorPlace.index(at: url("/Link/A.toma"), in: [moved]) == nil)
        #expect(moved.paths == [url("/Real/B.toma")])

        // Before its session opened, where it was opened from is where it is.
        let opening = EditorPlace(openedFrom: url("/Link/A.toma"), firstSeen: nil, current: url("/Link/A.toma"))
        #expect(opening.isWhereOpened && EditorPlace.index(at: url("/Link/A.toma"), in: [opening]) == 0)
    }
}
