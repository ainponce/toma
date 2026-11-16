// SPDX-License-Identifier: GPL-3.0-or-later
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

@Test func moveIntoAFolderKeepsBothNames() throws {
    try withTemporaryDirectory { projects in
        let clientes = projects.appendingPathComponent("Clientes", isDirectory: true)
        try FileManager.default.createDirectory(at: clientes, withIntermediateDirectories: false)
        _ = try ProjectPackage.create(in: clientes, name: "X", app: app, now: Date())
        let other = try ProjectPackage.create(in: projects, name: "x", app: app, now: Date())
        try Data("other".utf8).write(to: other.cacheURL.appendingPathComponent("content"))

        // The name is taken there, as the volume compares names: «x 2».
        let moved = try ProjectTrash.move(other.url, into: clientes)
        #expect(moved.lastPathComponent == "x 2.toma")
        #expect(try FileManager.default.contentsOfDirectory(atPath: clientes.path).sorted() == ["X.toma", "x 2.toma"])
        #expect(try Data(contentsOf: ProjectPackage(url: moved).cacheURL.appendingPathComponent("content")) == Data("other".utf8))

        // Under another name.
        let named = try ProjectTrash.move(moved, into: projects, as: "Demo")
        #expect(named.lastPathComponent == "Demo.toma")
        #expect(try ProjectTrash.move(named, into: clientes, as: "X").lastPathComponent == "X 2.toma")

        // Not into a link to a folder, nor into what is not a folder: nothing moves.
        let link = projects.appendingPathComponent("Link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: clientes)
        let package = try ProjectPackage.create(in: projects, name: "Y", app: app, now: Date())
        #expect(throws: POSIXError(.ENOTDIR)) { try ProjectTrash.move(package.url, into: link) }
        #expect(FileManager.default.fileExists(atPath: package.manifestURL.path))
    }
}

@Test func trashWorksOnAVolumeWithoutRenameExcl() throws {
    try withTemporaryDirectory { folder in
        // exFAT: renamex_np(RENAME_EXCL) gives ENOTSUP.
        let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .exFAT, in: folder)
        defer { try? disk.detach(force: true) }
        let projects = disk.mountPoint.appendingPathComponent("Projects", isDirectory: true)
        let clientes = projects.appendingPathComponent("Clientes", isDirectory: true)
        try FileManager.default.createDirectory(at: clientes, withIntermediateDirectories: true)
        var trashed: [URL] = []
        for (index, folder) in [projects, clientes].enumerated() {
            let package = try ProjectPackage.create(in: folder, name: "X", app: app, now: Date())
            try Data("\(index)".utf8).write(to: package.cacheURL.appendingPathComponent("content"))
            try FileManager.default.createDirectory(at: package.takeDirectory("take-001"), withIntermediateDirectories: false)
            trashed.append(try ProjectTrash.move(package, projectsFolder: projects))
        }
        #expect(trashed.map(\.lastPathComponent) == ["X.toma", "X 2.toma"])
        for (index, url) in trashed.enumerated() {
            #expect(try Data(contentsOf: ProjectPackage(url: url).cacheURL.appendingPathComponent("content")) == Data("\(index)".utf8))
        }
        // Only its case.
        let recased = ProjectTrash.folder(in: projects).appendingPathComponent("x.toma", isDirectory: true)
        try ProjectTrash.renameExclusively(from: AT_FDCWD, trashed[0].path, to: AT_FDCWD, recased.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ProjectTrash.folder(in: projects).path).sorted().filter { !$0.hasPrefix(".") } == ["X 2.toma", "x.toma"])
        // Never over another.
        #expect(throws: POSIXError(.EEXIST)) {
            try ProjectTrash.renameExclusively(from: AT_FDCWD, recased.path, to: AT_FDCWD, trashed[1].path)
        }
    }
}
