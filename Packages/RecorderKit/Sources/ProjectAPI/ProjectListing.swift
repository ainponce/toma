// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat

/// A package `list_projects` finds (plan 4b decision 14): where it is and what the library would show of it, read as
/// the library reads it (`EditSession.readOutline`), never written. Its JSON is part of the API: keys are only ever
/// added.
public struct ProjectListing: Codable, Equatable, Sendable {
    public var path: String
    /// Its name, without `.toma`.
    public var name: String
    /// The output's length in seconds; `nil` for a package that cannot be read.
    public var duration: Double?
    /// The `documentVersion` its edit document is written in on disk; `nil` without one.
    public var documentVersion: Int?
    /// When its manifest or its edit files last changed.
    public var modified: Date?
    /// Why it cannot be read, or edited and exported (an `APIError`'s description: a take still being recorded is
    /// `locked`); `nil` for one that reads.
    public var problem: String?

    public init(path: String, name: String, duration: Double?, documentVersion: Int?, modified: Date?, problem: String?) {
        self.path = path
        self.name = name
        self.duration = duration
        self.documentVersion = documentVersion
        self.modified = modified
        self.problem = problem
    }

    /// How many folders below the folder listed a package may be: `a/b/c/d/X.toma` is listed, `a/b/c/d/e/X.toma` not,
    /// as in the library (`LibraryScanner.maxDepth`, which the API does not depend on).
    static let maxDepth = 4

    /// The packages of `folder` (or of `environment.projectsFolder` with `nil`), up to `maxDepth` folders down, by path:
    /// never through a link (a package or a folder that is a link is not listed), into a package, a hidden folder or
    /// the library's `Trash/` (a folder `Trash` of the folder listed, in any case). The library's folder that is not
    /// there has no projects; another that is not is `refused`, as a path with `..` is.
    static func list(in folder: URL?, environment: APIEnvironment) async throws -> [ProjectListing] {
        let root = folder ?? environment.projectsFolder
        if root.pathComponents.contains("..") { throw APIError(.refused, "\(root.path): a path with “..” is refused") }
        var info = stat()
        guard stat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            if folder == nil { return [] }
            throw APIError(.refused, "there is no folder at \(root.path)")
        }
        let context = environment.editContext
        return await Task.detached {
            var packages: [URL] = []
            Self.walk(root, depth: 0, into: &packages)
            return packages.sorted { $0.path < $1.path }.map { Self.listing(of: $0, context: context) }
        }.value
    }

    /// The packages of `folder`, `depth` folders below the one listed, and those of its folders.
    private nonisolated static func walk(_ folder: URL, depth: Int, into packages: inout [URL]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appending(path: name, directoryHint: .isDirectory)
            var info = stat()
            // `lstat`: a link is neither a package nor a folder to go into.
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let ext = (name as NSString).pathExtension
            if ext.caseInsensitiveCompare(ProjectPackage.fileExtension) == .orderedSame, name.count > ext.count + 1 {
                // The Replay's working package is never a project.
                if !ReplayScratch.isScratch(ProjectPackage(url: url)) { packages.append(url) }
            } else if depth == 0, name.caseInsensitiveCompare("Trash") == .orderedSame {
                continue
            } else if depth < maxDepth {
                walk(url, depth: depth + 1, into: &packages)
            }
        }
    }

    private nonisolated static func listing(of url: URL, context: EditContext) -> ProjectListing {
        let name = url.deletingPathExtension().lastPathComponent
        let package = ProjectPackage(url: url)
        let modified = [url.appending(path: "manifest.json"), package.editURL, package.editLogURL]
            .compactMap(modificationDate).max()
        do {
            try ProjectPaths.checkPackage(url)
            let (project, outline) = try EditSession.readOutline(url, take: nil, context: context)
            // A take being recorded: what it lasts so far, and why it cannot be edited nor exported yet.
            let recording = project.takes.filter { $0.status == .recording }.map(\.id)
            return ProjectListing(
                path: url.path, name: name, duration: outline.outputSeconds,
                documentVersion: hasEditFiles(project) ? outline.diskVersion : nil, modified: modified,
                problem: recording.isEmpty ? nil : TomaProject.beingRecorded(recording).description)
        } catch {
            return ProjectListing(
                path: url.path, name: name, duration: nil, documentVersion: nil, modified: modified,
                problem: TomaProject.apiError(error).description)
        }
    }

    /// Whether a version 3 package has an edit document on disk, as `TomaProject` tells it.
    private nonisolated static func hasEditFiles(_ project: LoadedProject) -> Bool {
        guard project.manifest.formatVersion >= 3 else { return false }
        var info = stat()
        return lstat(project.package.editURL.path, &info) == 0 || lstat(project.package.editLogURL.path, &info) == 0
    }

    /// When the item at `url` last changed, not followed if it is a link; `nil` if it is not there.
    private nonisolated static func modificationDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }
}
