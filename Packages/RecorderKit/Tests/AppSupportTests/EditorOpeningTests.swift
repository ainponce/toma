// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// How an editor opens a package (Task 39, controller ruling 2): the trash is looked at before the take, so a take that
/// did not finish saving in the trash is offered to be restored first, and is never recovered there.
@Suite struct EditorOpeningTests {
    /// A package `<name>.toma` in `folder` whose one take is still marked as being recorded (`unfinished`) or complete.
    private func package(_ name: String, in folder: URL, unfinished: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let builder = try TakeBuilder(in: folder, name: name)
        return try builder.write(status: unfinished ? .recording : .complete).package.url
    }

    @Test func theTrashIsLookedAtBeforeTheTake() throws {
        try withTemporaryDirectory { dir in
            let projects = dir.appending(path: "Projects", directoryHint: .isDirectory)
            let trash = ProjectTrash.folder(in: projects)
            let trashedUnfinished = try package("A", in: trash, unfinished: true)
            let trashed = try package("B", in: trash, unfinished: false)
            let unfinished = try package("C", in: projects, unfinished: true)
            let plain = try package("D", in: projects, unfinished: false)
            // `TakeBuilder`'s one take.
            let take = "take-001"

            #expect(EditorOpening.of(trashedUnfinished, take: nil, projectsFolder: projects) == .unfinished(takeID: take, inTrash: true))
            #expect(EditorOpening.of(trashed, take: nil, projectsFolder: projects) == .session(forcedReadOnly: .inTrash))
            #expect(EditorOpening.of(unfinished, take: nil, projectsFolder: projects) == .unfinished(takeID: take, inTrash: false))
            #expect(EditorOpening.of(plain, take: nil, projectsFolder: projects) == .session(forcedReadOnly: nil))
            #expect(EditorOpening.of(trashedUnfinished, take: nil, projectsFolder: projects).isInTrash)
            #expect(!EditorOpening.of(unfinished, take: nil, projectsFolder: projects).isInTrash)
        }
    }

    /// Recovery is refused in the trash, also for a package that went there after it was opened; once restored it may be.
    @Test func aTakeInTheTrashIsNeverRecovered() throws {
        try withTemporaryDirectory { dir in
            let projects = dir.appending(path: "Projects", directoryHint: .isDirectory)
            let url = try package("A", in: projects, unfinished: true)
            #expect(EditorOpening.mayRecover(url, projectsFolder: projects))
            let trash = ProjectTrash.folder(in: projects)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let trashed = trash.appending(path: "A.toma", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: url, to: trashed)
            #expect(!EditorOpening.mayRecover(trashed, projectsFolder: projects))
        }
    }
}
