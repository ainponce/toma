// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// The rules of the paths the API is given (fases 4 y 5 design §6.3), the same for the command line, the MCP server and
/// the control socket: a package is a folder named `.toma` that holds a `manifest.json`, neither of them a link; a path
/// with a `..` component is refused; the folders above the package may be links (`/var` is `/private/var`), as the
/// system's are. A relative path is taken from the working directory `cwd`.
public enum ProjectPaths {
    /// The package at `path`: `notAProject` for a path with `..`, one that is not there, a link, a file, a folder whose
    /// name does not end in `.toma`, or one without a `manifest.json` that is a regular file.
    public static func package(_ path: String, relativeTo cwd: URL) throws(APIError) -> URL {
        guard !path.isEmpty else { throw APIError(.notAProject, "no path was given") }
        let url = try absolute(path, relativeTo: cwd, refusing: .notAProject)
        try checkPackage(url)
        return url
    }

    /// Where an export goes: `refused` for a path with `..`, one inside a package (by its name or by where its folder
    /// is, links resolved), a package itself, or one with no name.
    public static func output(_ path: String, relativeTo cwd: URL) throws(APIError) -> URL {
        guard !path.isEmpty else { throw APIError(.refused, "no output path was given") }
        let url = try absolute(path, relativeTo: cwd, refusing: .refused)
        guard !url.lastPathComponent.isEmpty, url.path != "/" else { throw APIError(.refused, "the output path names no file") }
        if let package = packageAround(url) {
            throw APIError(.refused, "the output \(url.path) is inside the package \(package): an export never writes into a project")
        }
        // A folder above that is a link into a package.
        let parent = url.deletingLastPathComponent()
        let resolved = parent.resolvingSymlinksInPath().appending(path: url.lastPathComponent)
        if let package = packageAround(resolved) {
            throw APIError(.refused, "the output \(url.path) is inside the package \(package): an export never writes into a project")
        }
        return url
    }

    /// Checks that `url` is a package the API opens, as `package(_:relativeTo:)` says.
    static func checkPackage(_ url: URL) throws(APIError) {
        if url.pathComponents.contains("..") { throw APIError(.notAProject, "\(url.path): a path with “..” is refused") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw APIError(.notAProject, "\(url.path) is not there") }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw APIError(.notAProject, "\(url.path) is a link: open the package itself")
        case S_IFDIR: break
        default: throw APIError(.notAProject, "\(url.path) is not a folder")
        }
        guard url.pathExtension.lowercased() == "toma" else {
            throw APIError(.notAProject, "\(url.path) is not a Toma project: its name does not end in .toma")
        }
        // The Replay's working package, which it prunes and deletes: never a project (fases 4 y 5 design §10.2).
        if ReplayScratch.isScratch(ProjectPackage(url: url)) {
            throw APIError(.notAProject, "\(url.path) is the Replay's working package, which Toma deletes: save the Replay to edit it")
        }
        let manifest = url.appending(path: "manifest.json", directoryHint: .notDirectory)
        guard lstat(manifest.path, &info) == 0 else { throw APIError(.notAProject, "\(url.path) has no manifest.json") }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw APIError(.notAProject, "the manifest.json of \(url.path) is a link or not a regular file")
        }
    }

    /// `path` from `cwd`, without `.` components and with a trailing `/` dropped; links are not resolved. Throws `code`
    /// for a `..` component.
    private static func absolute(_ path: String, relativeTo cwd: URL, refusing code: APIErrorCode) throws(APIError) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") { throw APIError(code, "\(path): a path with “..” is refused") }
        let base = expanded.hasPrefix("/") ? [] : cwd.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let parts = base + components.map(String.init).filter { $0 != "." }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }

    /// The first folder of `url` (itself included) whose name ends in `.toma`, if any.
    private static func packageAround(_ url: URL) -> String? {
        var path = ""
        for component in url.pathComponents where component != "/" {
            path += "/" + component
            if (component as NSString).pathExtension.lowercased() == "toma" { return path }
        }
        return nil
    }
}
