// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

private let app = AppInfo(name: "Tests", version: "0")

@Test func trashNeverOverwrites() throws {
    try withTemporaryDirectory { projects in
        var trashed: [URL] = []
        for content in ["first", "second"] {
            let package = try ProjectPackage.create(in: projects, name: "X", app: app, now: Date())
            try Data(content.utf8).write(to: package.cacheURL.appendingPathComponent("content"))
            trashed.append(try ProjectTrash.move(package, projectsFolder: projects))
            #expect(!FileManager.default.fileExists(atPath: package.url.path))
        }

        let trash = ProjectTrash.folder(in: projects)
        #expect(trash.lastPathComponent == ProjectTrash.folderName)
        #expect(trashed.map(\.lastPathComponent) == ["X.toma", "X 2.toma"])
        #expect(trashed.map { $0.deletingLastPathComponent().standardizedFileURL } == [trash, trash].map(\.standardizedFileURL))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted() == ["X 2.toma", "X.toma"])
        // Each is whole: it still opens as a project, with what it had.
        for (url, content) in zip(trashed, ["first", "second"]) {
            let package = ProjectPackage(url: url)
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            #expect(manifest.takes.isEmpty)
            #expect(try Data(contentsOf: package.cacheURL.appendingPathComponent("content")) == Data(content.utf8))
        }
    }
}

@Test func trashRefusesATakeStillRecording() throws {
    try withTemporaryDirectory { projects in
        let package = try ProjectPackage.create(in: projects, name: "Recording", app: app, now: Date())
        try FileManager.default.createDirectory(at: package.takeDirectory("take-001"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package.takeDirectory("take-002"), withIntermediateDirectories: false)
        let lock = try RecordingLock.acquire(at: package.lockURL(take: "take-002"), info: .current(now: Date()))
        defer { lock.release() }

        #expect(throws: ProjectTrashError.takeStillRecording) {
            try ProjectTrash.move(package, projectsFolder: projects)
        }
        #expect(FileManager.default.fileExists(atPath: package.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: projects).path))

        lock.release()
        let moved = try ProjectTrash.move(package, projectsFolder: projects)
        #expect(moved.lastPathComponent == "Recording.toma")
        #expect(!FileManager.default.fileExists(atPath: package.url.path))
    }
}
