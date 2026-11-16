// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import RecorderKitTestSupport
import Testing

// MARK: - Edit ▸ Undo and Redo

@Test func undoAndRedoNameTheActionTheyWouldDo() {
    #expect(UndoMenuItem(label: .split, sessionWouldDoIt: true, isGesturing: false) == UndoMenuItem(isEnabled: true, label: .split))
    #expect(UndoMenuItem(label: nil, sessionWouldDoIt: false, isGesturing: false) == .unavailable)
    #expect(UndoMenuItem.unavailable == UndoMenuItem(isEnabled: false, label: nil))
}

@Test func anUndoTheSessionWouldRefuseIsNotOffered() {
    // A label with nothing the session can undo (a `migrate` that cut the history, a log being started again): a plain,
    // disabled item.
    #expect(UndoMenuItem(label: .padding, sessionWouldDoIt: false, isGesturing: false) == .unavailable)
    // A group of an action this app has no name for: offered, without a name.
    #expect(UndoMenuItem(label: nil, sessionWouldDoIt: true, isGesturing: false) == UndoMenuItem(isEnabled: true, label: nil))
}

@Test func nothingIsUndoneWhileADragIsUnderWay() {
    #expect(UndoMenuItem(label: .trim, sessionWouldDoIt: true, isGesturing: true) == .unavailable)
}

// MARK: - Closing with changes that couldn't be saved

@Test func closingAsksOnlyWithUnsavedChanges() {
    #expect(EditorClosing.decide(hasUnsavedChanges: false, isAsking: false) == .close)
    #expect(EditorClosing.decide(hasUnsavedChanges: true, isAsking: false) == .ask)
    // The question is up already: one at a time.
    #expect(EditorClosing.decide(hasUnsavedChanges: true, isAsking: true) == .keepOpen)
    #expect(EditorClosing.decide(hasUnsavedChanges: false, isAsking: true) == .keepOpen)
}

@Test func keepOpenIsTheDefaultAnswer() {
    #expect(UnsavedChangesAnswer.allCases == [.keepOpen, .closeAnyway])
    #expect(!UnsavedChangesAnswer.keepOpen.closesTheWindow)
    #expect(UnsavedChangesAnswer.closeAnyway.closesTheWindow)
}

// MARK: - The same package

@Test func aPackageIsTheSameThroughASymlinkAndAfterItMoves() throws {
    try withTemporaryDirectory { dir in
        let package = dir.appending(path: "Demo.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let identity = try #require(PackageIdentity(package))
        let link = dir.appending(path: "Link.toma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        #expect(PackageIdentity(link) == identity)
        #expect(PackageIdentity(dir.appending(path: "./Demo.toma")) == identity)
        let moved = dir.appending(path: "Renamed.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: package, to: moved)
        #expect(PackageIdentity(moved) == identity)
        #expect(PackageIdentity(package) == nil)

        let other = dir.appending(path: "Other.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(PackageIdentity(other) != identity)
        // A file is not a package.
        let file = dir.appending(path: "File.toma")
        try Data("x".utf8).write(to: file)
        #expect(PackageIdentity(file) == nil)
    }
}
