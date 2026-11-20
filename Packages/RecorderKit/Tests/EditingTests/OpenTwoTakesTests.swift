// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
import Editing
import ProjectFormat

// Phase 3 base, Task B4 (design §9): in a package of more than one take, the editor and the read-only reads show the
// project focused on the take of the document's first clip, never on a take the sequence does not use.

@MainActor @Suite struct OpenTwoTakesTests {
    private static let app = AppInfo(name: "Toma", version: "0.3.0")

    private final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    private static func context(_ dir: URL, forcedReadOnly: ReadOnlyReason? = nil) -> EditContext {
        let ids = IDs()
        return EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
            now: { Date(timeIntervalSince1970: 1_794_773_523) }, makeID: { ids.make($0) }, forcedReadOnly: forcedReadOnly)
    }

    /// `twoTakes` with `edit.json` holding the legacy document with `pieces`, and no log: what the editor opens from.
    private static func package(
        in dir: URL, _ pieces: [(take: String, from: Double, to: Double)]
    ) async throws -> LoadedProject {
        let project = try await MultiTakeFixtures.twoTakes(in: dir)
        let document = MultiTakeFixtures.sequence(of: project, pieces)
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: project.package.editURL)
        return project
    }

    @Test func editorOpensOnTheTakeOfTheFirstClip() async throws {
        try await withTemporaryDirectory { dir in
            // take-002, the last one, never used: the document shows take-001 alone.
            let project = try await Self.package(in: dir, [("take-001", 0, 2), ("take-001", 2.5, 3.5)])
            let url = project.package.url
            let first = project.events(ofTake: "take-001")
            #expect(!first.isEmpty)

            let session = try await EditSession.open(url, take: nil, context: Self.context(dir))
            #expect(session.access == .editable)
            #expect(session.project.take.id == "take-001")
            #expect(session.project.take == project.takes[0])
            #expect(session.project.events == first)
            #expect(session.document.sequence.map(\.take) == ["take-001", "take-001"])
            await session.close()

            // Read-only, the same.
            let readOnly = try await EditSession.open(url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
            #expect(readOnly.access == .readOnly(.inTrash))
            #expect(readOnly.project.take.id == "take-001")
            #expect(readOnly.project.events == first)
            await readOnly.close()

            // So do the reads without the lock.
            let (read, document) = try EditSession.readDocument(url, take: nil, context: Self.context(dir))
            #expect(read.take.id == "take-001")
            #expect(read.events == first)
            #expect(document.sequence.map(\.take) == ["take-001", "take-001"])
            let (withDiskVersion, _, _) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: Self.context(dir))
            #expect(withDiskVersion.take.id == "take-001")
            let (outlined, _) = try EditSession.readOutline(url, take: nil, context: Self.context(dir))
            #expect(outlined.take.id == "take-001")

            // A take asked for stays the one shown.
            let asked = try await EditSession.open(url, take: "take-002", context: Self.context(dir))
            #expect(asked.project.take.id == "take-002")
            await asked.close()
            #expect(try EditSession.readDocument(url, take: "take-002", context: Self.context(dir)).0.take.id == "take-002")
        }
    }

    @Test func theFirstClipDecidesAndAnUnknownTakeIsPassedOver() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir, [("take-002", 0, 1), ("take-001", 0, 2)])
            let url = project.package.url
            let (read, _) = try EditSession.readDocument(url, take: nil, context: Self.context(dir))
            #expect(read.take.id == "take-002")

            let document = MultiTakeFixtures.sequence(of: project, [("take-009", 0, 1), ("take-001", 0, 2)])
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: project.package.editURL)
            let session = try await EditSession.open(url, take: nil, context: Self.context(dir))
            #expect(session.project.take.id == "take-001")
            #expect(session.project.events == project.events(ofTake: "take-001"))
            await session.close()
        }
    }

    @Test func anUnreadableShownTakeIsThrownAndLeavesNoLock() async throws {
        try await withTemporaryDirectory { dir in
            // The take shown is refused as the take loaded would be (`LoadedProject.load`); the one not shown never is.
            let project = try await Self.package(in: dir, [("take-001", 0, 2)])
            let url = project.package.url
            let events = project.package.eventsURL(take: "take-001")
            try FileManager.default.removeItem(at: events)
            try FileManager.default.createSymbolicLink(at: events, withDestinationURL: project.package.eventsURL(take: "take-002"))
            await #expect(throws: POSIXError(.ELOOP)) { _ = try await EditSession.open(url, take: nil, context: Self.context(dir)) }
            #expect(!RecordingLock.isHeld(at: project.package.editLockURL))
            await #expect(throws: POSIXError(.ELOOP)) {
                _ = try await EditSession.open(url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
            }
            #expect(throws: POSIXError(.ELOOP)) { _ = try EditSession.readDocument(url, take: nil, context: Self.context(dir)) }
            // Nothing was written: the package opens once the log is back.
            #expect(!FileManager.default.fileExists(atPath: project.package.editLogURL.path))
            try FileManager.default.removeItem(at: events)
            try Data().write(to: events)
            let session = try await EditSession.open(url, take: nil, context: Self.context(dir))
            #expect(session.access == .editable)
            #expect(session.project.take.id == "take-001")
            #expect(session.project.events == [])
            await session.close()
        }
    }

    @Test func anUnreadableUnusedTakeNeverStopsTheProject() async throws {
        try await withTemporaryDirectory { dir in
            // take-002, the last one, an unused take whose log cannot be read: unreadable, a FIFO, a link. The project
            // opens and reads on take-001 all the same, and take-002's log is never opened.
            let project = try await Self.package(in: dir, [("take-001", 0, 2), ("take-001", 2.5, 3.5)])
            let url = project.package.url
            let first = project.events(ofTake: "take-001")
            let events = project.package.eventsURL(take: "take-002")
            let saved = dir.appending(path: "take-002-events.jsonl")
            try FileManager.default.copyItem(at: events, to: saved)
            let unreadable: [(String, () throws -> Void)] = [
                ("unreadable", { #expect(chmod(events.path, 0) == 0) }),
                ("FIFO", {
                    try FileManager.default.removeItem(at: events)
                    #expect(mkfifo(events.path, 0o644) == 0)
                }),
                ("link", {
                    try FileManager.default.removeItem(at: events)
                    try FileManager.default.createSymbolicLink(at: events, withDestinationURL: saved)
                }),
            ]
            for (kind, spoil) in unreadable {
                try spoil()
                let session = try await EditSession.open(url, take: nil, context: Self.context(dir))
                #expect(session.access == .editable, "\(kind)")
                #expect(session.project.take.id == "take-001", "\(kind)")
                #expect(session.project.events == first, "\(kind)")
                #expect(session.project.events(ofTake: "take-002") == [], "\(kind)")
                await session.close()

                let readOnly = try await EditSession.open(url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
                #expect(readOnly.project.take.id == "take-001" && readOnly.project.events == first, "\(kind)")
                await readOnly.close()

                let (read, document) = try EditSession.readDocument(url, take: nil, context: Self.context(dir))
                #expect(read.take.id == "take-001" && read.events == first, "\(kind)")
                #expect(document.sequence.map(\.take) == ["take-001", "take-001"], "\(kind)")
                let (outlined, outline) = try EditSession.readOutline(url, take: nil, context: Self.context(dir))
                #expect(outlined.take.id == "take-001", "\(kind)")
                #expect(outline.outputSeconds == 3, "\(kind)")

                // Asked for, take-002 is refused, as it would be alone.
                await #expect(throws: (any Error).self, "\(kind)") {
                    _ = try await EditSession.open(url, take: "take-002", context: Self.context(dir))
                }
                #expect(throws: (any Error).self, "\(kind)") {
                    _ = try EditSession.readDocument(url, take: "take-002", context: Self.context(dir))
                }

                if kind == "unreadable" { #expect(chmod(events.path, 0o644) == 0) }
                try FileManager.default.removeItem(at: events)
                try FileManager.default.copyItem(at: saved, to: events)
            }
        }
    }

    @Test func aNewProjectOfTwoTakesShowsTheLastOne() async throws {
        try await withTemporaryDirectory { dir in
            // No edit files: a `NewDocument` of the last take, as with one take.
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let session = try await EditSession.open(project.package.url, take: nil, context: Self.context(dir))
            #expect(session.project.take.id == "take-002")
            #expect(session.document.sequence.map(\.take) == ["take-002"])
            #expect(session.project.events == project.events)
            await session.close()
        }
    }
}
