// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

// While a new log starts (the log was removed under the journal), nothing can be undone: Edit ▸ Undo and Redo have no
// label, and the session says so as it starts (final review A-M1, Task 12a M5). The app's menu reads the labels and
// `onChange`, so it never offers an undo that does nothing.

private let base = HostTime(nanoseconds: 5_000_000_000_000)

/// A take of 1 s of one display with the cursor moving over it, in a new package. Written off the main actor.
@concurrent private func package(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Fixture", formatVersion: 3)
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    try await builder.addVideoTrack(
        id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
        segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
    try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
    try builder.addEvents((0..<20).map { i in
        InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: 100 + Double(i) * 10, y: 100))
    })
    return try builder.write()
}

/// The system's IO, whose opens wait while `held` (a new log being started waits there).
private final class HeldOpens: Sendable {
    private let held = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)
    private let waiting = Mutex(0)

    func hold() { held.withLock { $0 = true } }

    func release() {
        let count = held.withLock { held -> Int in
            held = false
            return waiting.withLock { $0 }
        }
        for _ in 0..<max(count, 1) { gate.signal() }
    }

    var io: EditJournalIO {
        let system = EditJournalIO.system
        return EditJournalIO(
            open: { [self] directory, name, create in
                if held.withLock({ $0 }) {
                    waiting.withLock { $0 += 1 }
                    // Released by the test, or after a minute (a watchdog: the test then fails, it never hangs).
                    _ = gate.wait(timeout: .now() + 60)
                    waiting.withLock { $0 -= 1 }
                }
                return try system.open(directory, name, create)
            },
            write: system.write, fullSync: system.fullSync, fsync: system.fsync, syncDirectory: system.syncDirectory)
    }
}

@MainActor @Test func nothingIsOfferedToUndoWhileANewLogStarts() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await package(in: dir)
        let opens = HeldOpens()
        let ids = Mutex(0)
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0.2.0"), cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
            now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                ids.withLock { ids in
                    ids += 1
                    return prefix + String(format: "%08x", ids)
                }
            }, journalIO: opens.io)
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        let padding = try #require(session.document.setChange("/style/padding", 0.1))
        #expect(session.perform(EditStep(label: .padding, target: "/style/padding", changes: [padding])) == .applied)
        // The `create`, the two `migrate`s of the first edit and its step.
        #expect(await session.flushed() == 4)
        #expect(session.undoLabel == .padding && session.canUndo)

        // What the menu reads each time the session says something changed.
        var seen: [(label: EditLabel?, canUndo: Bool, unsaved: Bool)] = []
        session.onChange = { seen.append((session.undoLabel, session.canUndo, session.hasUnsavedChanges)) }
        opens.hold()
        try FileManager.default.removeItem(at: project.package.editLogURL)
        // The next line finds the log gone: the session starts a new one, which waits in its open.
        let shadow = try #require(session.document.setChange("/style/shadow", 0.2))
        #expect(session.perform(EditStep(label: .shadow, target: "/style/shadow", changes: [shadow])) == .applied)
        #expect(await eventually { seen.contains { $0.unsaved && !$0.canUndo } })
        #expect(session.undoLabel == nil, "nothing can be undone while the log starts again")
        #expect(session.redoLabel == nil)
        #expect(!session.canUndo)
        let last = try #require(seen.last)
        #expect(last.label == nil && !last.canUndo, "the session said so once it started: \(seen)")

        opens.release()
        #expect(await eventually { !session.hasUnsavedChanges })
        await session.close()
    }
}
