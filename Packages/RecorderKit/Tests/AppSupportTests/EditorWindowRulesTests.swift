// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Dispatch
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
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

@Test func closingAsksOnlyWhenASaveFailed() {
    let failed: [EditNotice] = [.legacyLook, .saveFailed(.ENOSPC)]
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: [], isAsking: false) == .close)
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: failed, isAsking: false) == .ask)
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: [.saveFailed(.EIO)], isAsking: false) == .ask)
    // On its way to the disk (a line being synced, the move to version 3, a new log): the session saves it as it closes.
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: [], isAsking: false) == .close)
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: [.legacyLook, .recovered(upTo: Date(timeIntervalSince1970: 0))], isAsking: false) == .close)
    // Saved since: the banner goes with it.
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: failed, isAsking: false) == .close)
    // The question is up already: one at a time.
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: failed, isAsking: true) == .keepOpen)
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: [], isAsking: true) == .keepOpen)
}

/// The system's calls, with the full syncs waiting while `holdsSyncs` and the writes failing with `failingWrites`.
private final class HeldIO: Sendable {
    private let state = Mutex<(holdsSyncs: Bool, failingWrites: POSIXErrorCode?)>((false, nil))
    private let released = DispatchSemaphore(value: 0)

    func holdSyncs() { state.withLock { $0.holdsSyncs = true } }

    func releaseSyncs() {
        state.withLock { $0.holdsSyncs = false }
        released.signal()
    }

    func failWrites(with code: POSIXErrorCode?) { state.withLock { $0.failingWrites = code } }

    var io: EditJournalIO {
        EditJournalIO(
            open: { try EditJournalIO.system.open($0, $1, $2) },
            write: { [self] descriptor, bytes in
                if let code = state.withLock({ $0.failingWrites }) { throw POSIXError(code) }
                return try EditJournalIO.system.write(descriptor, bytes)
            },
            fullSync: { [self] descriptor in
                if state.withLock({ $0.holdsSyncs }) { released.wait() }
                try EditJournalIO.system.fullSync(descriptor)
            },
            fsync: { try EditJournalIO.system.fsync($0) },
            syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
    }
}

/// A take of 1 s of one display in a new version 3 package.
@concurrent private func package(in dir: URL) async throws -> LoadedProject {
    let base = HostTime(nanoseconds: 5_000_000_000_000)
    let builder = try TakeBuilder(in: dir, name: "Closing")
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    try await builder.addVideoTrack(
        id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
        segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
    try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
    return try builder.write()
}

@MainActor @Test func aSessionAsksOnlyOnceASaveFailed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await package(in: dir)
        let held = HeldIO()
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0"), cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
            now: { Date() }, makeID: { $0 + "00000001" }, journalIO: held.io)
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        @MainActor func closing() -> EditorClosing {
            EditorClosing.decide(hasUnsavedChanges: session.hasUnsavedChanges, notices: session.notices, isAsking: false)
        }
        #expect(await session.flushed() > 0)
        #expect(closing() == .close)
        // A change whose line is being synced: unsaved, but nothing failed.
        held.holdSyncs()
        let padding = try #require(StyleCommands.set(session.document, "/style/padding", 0.12, label: .padding))
        #expect(session.perform(padding) == .applied)
        #expect(session.hasUnsavedChanges)
        #expect(closing() == .close)
        held.releaseSyncs()
        _ = await session.flushed()
        // A disk that is full: the amber banner, and the question.
        held.failWrites(with: .ENOSPC)
        let shadow = try #require(StyleCommands.set(session.document, "/style/shadow", 0.3, label: .shadow))
        #expect(session.perform(shadow) == .applied)
        #expect(await eventually { session.notices.contains(.saveFailed(.ENOSPC)) })
        #expect(closing() == .ask)
        // Room again: saved, and closing does not ask.
        held.failWrites(with: nil)
        #expect(await eventually(timeout: .seconds(10)) { !session.hasUnsavedChanges })
        #expect(closing() == .close)
        await session.close()
    }
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
