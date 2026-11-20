// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// The rules of the paths the API is given (fases 4 y 5 design §6.3).
private func makePackage(in dir: URL, name: String = "Paths") throws -> URL {
    try ProjectPackage.create(in: dir, name: name, app: APIFixtures.app, now: Date()).url
}

private func code(_ body: () throws -> URL) -> APIErrorCode? {
    do {
        _ = try body()
        return nil
    } catch {
        return (error as? APIError)?.code
    }
}

@Test func dotDotIsRefused() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        #expect(code { try ProjectPaths.package("Other/../\(package.lastPathComponent)", relativeTo: dir) } == .notAProject)
        #expect(code { try ProjectPaths.package(package.path + "/..", relativeTo: dir) } == .notAProject)
        #expect(code { try ProjectPaths.output("Exports/../out.mp4", relativeTo: dir) } == .refused)
        // The same package without the `..` opens.
        #expect(code { try ProjectPaths.package(package.lastPathComponent, relativeTo: dir) } == nil)
    }
}

@Test func symlinkedPackageIsNotAProject() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let link = dir.appending(path: "Link.toma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        #expect(code { try ProjectPaths.package(link.path, relativeTo: dir) } == .notAProject)
        // A manifest that is a link is refused too.
        let other = try makePackage(in: dir, name: "Other")
        let manifest = other.appending(path: "manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: package.appending(path: "manifest.json"))
        #expect(code { try ProjectPaths.package(other.path, relativeTo: dir) } == .notAProject)
    }
}

@Test func folderWithoutManifestIsNotAProject() throws {
    try withTemporaryDirectory { dir in
        let folder = dir.appending(path: "Empty.toma")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(code { try ProjectPaths.package(folder.path, relativeTo: dir) } == .notAProject)
        // Not there, a file, a folder of another name.
        #expect(code { try ProjectPaths.package("Missing.toma", relativeTo: dir) } == .notAProject)
        let file = dir.appending(path: "File.toma")
        try Data("{}".utf8).write(to: file)
        #expect(code { try ProjectPaths.package(file.path, relativeTo: dir) } == .notAProject)
        let package = try makePackage(in: dir)
        let renamed = dir.appending(path: "Renamed")
        try FileManager.default.moveItem(at: package, to: renamed)
        #expect(code { try ProjectPaths.package(renamed.path, relativeTo: dir) } == .notAProject)
        #expect(code { try ProjectPaths.package("", relativeTo: dir) } == .notAProject)
    }
}

@Test func outputInsideAPackageIsRefused() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        #expect(code { try ProjectPaths.output(package.appending(path: "out.mp4").path, relativeTo: dir) } == .refused)
        #expect(code { try ProjectPaths.output(package.appending(path: "takes/out.mp4").path, relativeTo: dir) } == .refused)
        #expect(code { try ProjectPaths.output(package.path, relativeTo: dir) } == .refused)
        // Through a link to the package's folder.
        let link = dir.appending(path: "Into")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        #expect(code { try ProjectPaths.output(link.appending(path: "out.mp4").path, relativeTo: dir) } == .refused)
        // Next to it is fine.
        #expect(try ProjectPaths.output("out.mp4", relativeTo: dir) == dir.appending(path: "out.mp4"))
    }
}

@Test func relativePathsResolveAgainstTheWorkingDirectory() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        #expect(try ProjectPaths.package("Paths.toma", relativeTo: dir).path == package.path)
        #expect(try ProjectPaths.package("./Paths.toma/", relativeTo: dir).path == package.path)
        let exports = dir.appending(path: "Exports")
        #expect(try ProjectPaths.output("Exports/out.mp4", relativeTo: dir).path == exports.appending(path: "out.mp4").path)
        #expect(try ProjectPaths.output("/tmp/out.mp4", relativeTo: dir).path == "/tmp/out.mp4")
    }
}

@MainActor @Test func systemLinksAboveArePassed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await APIFixtures.package(in: dir)
        let path = project.package.url.path
        // `/var` is a link of the system's to `/private/var`: both name the package.
        let other = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : "/private" + path
        try #require(path.hasPrefix("/var/") || path.hasPrefix("/private/var/"))
        let environment = APIFixtures.environment(in: dir)
        for form in [path, other] {
            let url = try ProjectPaths.package(form, relativeTo: dir)
            #expect(url.path == form)
            let opened = try await TomaProject.open(url, mode: .read, environment: environment)
            #expect(opened.document.sequence.count == 1)
            await opened.close()
        }
    }
}
