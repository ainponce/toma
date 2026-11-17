// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// A project in the trash opens read-only (1c decision 36): `EditContext.forcedReadOnly` opens it with that reason,
/// without taking `edit.lock` (not even for a moment) and without writing anything into the package, whatever it holds;
/// `ProjectTrash.contains` is how the app knows a package is in the trash.
@MainActor @Suite struct TrashReadOnlyTests {
    private nonisolated static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// A take of 1 s of one display in a new package `<name>.toma` of `formatVersion`, in `dir`.
    @concurrent private static func package(in dir: URL, name: String, formatVersion: Int = 3) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    private static func context(_ dir: URL, forcedReadOnly: ReadOnlyReason? = nil) -> EditContext {
        EditContext(
            app: AppInfo(name: "Toma", version: "0.3.0"), cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory),
            defaultStyle: .toma, now: { Date(timeIntervalSince1970: 1_794_800_000) }, makeID: { $0 + "00000001" },
            forcedReadOnly: forcedReadOnly)
    }

    private static func padding(_ document: EditDocument, _ value: Double) throws -> EditStep {
        EditStep(label: .padding, target: "/style/padding", changes: [try #require(document.setChange("/style/padding", value))])
    }

    /// Whatever the package holds (a new v3 project, whose normal opening writes its first document; one edited, whose log
    /// ends in a line cut short, which a normal opening truncates; a v2 one), it opens read-only `.inTrash`, refuses every
    /// edit, writes nothing and leaves `edit.lock` free all along.
    @Test func forcedReadOnlyNeverTakesTheLockNorWrites() async throws {
        try await withTemporaryDirectory { dir in
            let fresh = try await Self.package(in: dir, name: "Fresh")
            let edited = try await Self.package(in: dir, name: "Edited")
            let editable = try await EditSession.open(edited.package.url, take: nil, context: Self.context(dir))
            #expect(editable.perform(try Self.padding(editable.document, 0.1)) == .applied)
            await editable.close()
            let cut = try FileHandle(forWritingTo: edited.package.editLogURL)
            try cut.seekToEnd()
            try cut.write(contentsOf: Data(#"{"seq":3,"#.utf8))
            try cut.close()
            let legacy = try await Self.package(in: dir, name: "Legacy", formatVersion: 2)

            for project in [fresh, edited, legacy] {
                let url = project.package.url
                let before = try treeHash(url)
                let session = try await EditSession.open(url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
                #expect(session.access == .readOnly(.inTrash), "\(url.lastPathComponent)")
                #expect(session.perform(try Self.padding(session.document, 0.2)) == .refused)
                #expect(session.undo() == .refused && session.redo() == .refused)
                #expect(await session.importAsset(url.appending(path: "manifest.json")) == .notEditable)
                #expect(!session.hasUnsavedChanges)
                #expect(try treeHash(url) == before, "nothing written while it is open: \(url.lastPathComponent)")
                // The lock is free while the session is open: another opener takes it at once (and its release removes
                // the lock file it made).
                let other = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
                other.release()
                await session.close()
                #expect(try treeHash(url) == before, "nothing written as it closed: \(url.lastPathComponent)")
            }
            // What it shows is what a normal opening would: the edit, up to its last whole line.
            let shown = try await EditSession.open(edited.package.url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
            #expect(shown.document.style.padding == 0.1)
            await shown.close()
        }
    }

    /// Another app holding the lock does not change the reason (the lock is never asked about), and a document of a newer
    /// version still says so: there is nothing to show.
    @Test func theForcedReasonWinsButANewerDocumentStillSaysSo() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir, name: "Held")
            await (try await EditSession.open(project.package.url, take: nil, context: Self.context(dir))).close()
            let lock = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
            defer { lock.release() }
            let held = try await EditSession.open(project.package.url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
            #expect(held.access == .readOnly(.inTrash))
            await held.close()

            let newer = try await Self.package(in: dir, name: "Newer")
            await (try await EditSession.open(newer.package.url, take: nil, context: Self.context(dir))).close()
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: newer.package.editURL)) as? [String: Any])
            json["documentVersion"] = EditDocument.currentVersion + 1
            try JSONSerialization.data(withJSONObject: json).write(to: newer.package.editURL)
            let session = try await EditSession.open(newer.package.url, take: nil, context: Self.context(dir, forcedReadOnly: .inTrash))
            #expect(session.access == .readOnly(.newerDocument(EditDocument.currentVersion + 1)))
            await session.close()
        }
    }

    /// A package is in the trash when it is anywhere inside `<projects folder>/Trash/`, by real paths: also reached
    /// through a link to the projects folder; never the trash itself, the projects folder or another folder.
    @Test func aPackageInTheTrashIsFoundByItsRealPath() throws {
        try withTemporaryDirectory { dir in
            let projects = dir.appending(path: "Projects", directoryHint: .isDirectory)
            let trash = ProjectTrash.folder(in: projects)
            let inTrash = trash.appending(path: "Demo.toma", directoryHint: .isDirectory)
            let deeper = trash.appending(path: "Old/Demo.toma", directoryHint: .isDirectory)
            let here = projects.appending(path: "Demo.toma", directoryHint: .isDirectory)
            let elsewhere = dir.appending(path: "Desktop/Demo.toma", directoryHint: .isDirectory)
            for folder in [inTrash, deeper, here, elsewhere] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let link = dir.appending(path: "Link", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: projects)

            #expect(ProjectTrash.contains(inTrash, projectsFolder: projects))
            #expect(ProjectTrash.contains(deeper, projectsFolder: projects))
            #expect(ProjectTrash.contains(link.appending(path: "Trash/Demo.toma"), projectsFolder: projects))
            #expect(ProjectTrash.contains(inTrash, projectsFolder: link))
            #expect(ProjectTrash.contains(projects.appending(path: "trash/Demo.toma"), projectsFolder: projects), "any case")
            #expect(!ProjectTrash.contains(trash, projectsFolder: projects))
            #expect(!ProjectTrash.contains(here, projectsFolder: projects))
            #expect(!ProjectTrash.contains(elsewhere, projectsFolder: projects))
            #expect(!ProjectTrash.contains(projects.appending(path: "Trash/Gone.toma"), projectsFolder: projects), "nothing there")
        }
    }
}
