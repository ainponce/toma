// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// The operations of one go of the command line and the MCP server: each opens, does and closes (plan 4b, Task A4).
@Suite struct ProjectRunnerTests {
    @MainActor @Test func listProjectsFindsPackagesNotLinksNorTrash() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let root = dir.appending(path: "Projects", directoryHint: .isDirectory)
            let deep = root.appending(path: "a/b/c/d", directoryHint: .isDirectory)
            let tooDeep = deep.appending(path: "e", directoryHint: .isDirectory)
            let trash = root.appending(path: "trash", directoryHint: .isDirectory)
            let hidden = root.appending(path: ".hidden", directoryHint: .isDirectory)
            let elsewhere = dir.appending(path: "Elsewhere", directoryHint: .isDirectory)
            for folder in [deep, tooDeep, trash, hidden, elsewhere] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let top = try await APIFixtures.package(in: root, name: "Top").package.url
            let inDeep = try await APIFixtures.package(in: deep, name: "Deep").package.url
            _ = try await APIFixtures.package(in: tooDeep, name: "TooDeep")
            _ = try await APIFixtures.package(in: trash, name: "Trashed")
            _ = try await APIFixtures.package(in: hidden, name: "Hidden")
            let away = try await APIFixtures.package(in: elsewhere, name: "Away").package.url
            // A link to a package, and a link to a folder of packages: neither is followed.
            try FileManager.default.createSymbolicLink(at: root.appending(path: "Link.toma"), withDestinationURL: top)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "Folder"), withDestinationURL: elsewhere)
            // A package that is broken: no manifest.
            let broken = root.appending(path: "Broken.toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            let before = try treeHash(root)

            let listed = try await ProjectRunner.listProjects(in: nil, environment: environment)
            // By path: `Broken.toma`, `Top.toma`, then `a/b/c/d/Deep.toma`.
            #expect(listed.map(\.path) == [broken.path, top.path, inDeep.path].sorted())
            let ok = try #require(listed.first { $0.name == "Top" })
            #expect(ok.problem == nil)
            #expect(abs((ok.duration ?? 0) - APIFixtures.seconds) < 0.2)
            #expect(ok.documentVersion == nil)
            #expect(ok.modified != nil)
            let bad = try #require(listed.first { $0.name == "Broken" })
            #expect(bad.problem?.hasPrefix("notAProject") == true)
            #expect(bad.duration == nil)
            // A folder given: its own packages.
            let given = try await ProjectRunner.listProjects(in: elsewhere, environment: environment)
            #expect(given.map(\.path) == [away.path])
            // Reading never writes.
            #expect(try treeHash(root) == before)
            // A folder that is not there.
            let missing = await APIFixtures.apiError {
                _ = try await ProjectRunner.listProjects(in: dir.appending(path: "Nowhere"), environment: environment)
            }
            #expect(missing?.code == .refused)
        }
    }

    @MainActor @Test func listProjectsOfAMissingLibraryIsEmpty() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let listed = try await ProjectRunner.listProjects(in: nil, environment: environment)
            #expect(listed.isEmpty)
        }
    }

    @MainActor @Test func eachCallOpensAndCloses() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            let report = try await ProjectRunner.report(url, environment: environment)
            #expect(report.mode == .read)
            #expect(try await ProjectRunner.transcript(url, environment: environment)?.words.isEmpty == false)
            #expect(try await ProjectRunner.markers(url, environment: environment).markers.count == 2)

            var told: [Int] = []
            let batch = await ProjectRunner.apply(
                [.setTitle("One"), .setAspect(.portrait), .addMarker(at: 5, name: "Five")], to: url, environment: environment
            ) { index, _ in told.append(index) }
            #expect(batch.error == nil && batch.results.count == 3)
            #expect(told == [0, 1, 2])
            // The lock is let go: the app could open it.
            #expect(!RecordingLock.isHeld(at: ProjectPackage(url: url).editLockURL))

            #expect(try await ProjectRunner.undo(url, environment: environment).label == EditLabel.markerAdd.rawValue)
            #expect(try await ProjectRunner.redo(url, environment: environment).label == EditLabel.markerAdd.rawValue)
            #expect(try await ProjectRunner.report(url, environment: environment).info?.title == "One")

            // Stops at the first that fails; what came before stays.
            let stopped = await ProjectRunner.apply(
                [.setTitle("Two"), .cut(from: 4, to: 3), .setTitle("Three")], to: url, environment: environment)
            #expect(stopped.results.map(\.command) == ["setTitle"])
            #expect(stopped.error?.code == .outOfRange && stopped.failedIndex == 1)
            #expect(try await ProjectRunner.report(url, environment: environment).info?.title == "Two")

            // Locked: nothing ran.
            let app = try await EditSession.open(url, take: nil, context: environment.editContext)
            let locked = await ProjectRunner.apply([.setTitle("Four")], to: url, environment: environment)
            #expect(locked.error?.code == .locked && locked.failedIndex == nil && locked.results.isEmpty)
            #expect(await APIFixtures.apiError { _ = try await ProjectRunner.undo(url, environment: environment) }?.code == .locked)
            await app.close()

            // Not a project.
            let notOne = await APIFixtures.apiError {
                _ = try await ProjectRunner.report(dir.appending(path: "Caches"), environment: environment)
            }
            #expect(notOne?.code == .notAProject)
        }
    }
}
