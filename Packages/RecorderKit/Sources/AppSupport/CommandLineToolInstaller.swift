// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Settings ▸ General ▸ «Install Command Line Tool» (fases 4 y 5 design §6.2, plan 4b decision 20): a link `toma` to the
/// app's own `Contents/Helpers/toma`, in `/usr/local/bin` if that folder is there and this user can write it without
/// asking for a password, otherwise in `~/.local/bin` (made if it is not there), which the user may have to add to their
/// `PATH`. Never asks for a password. It replaces only a link that points to a `toma` inside an app
/// (`<name>.app/Contents/Helpers/toma`, another copy of Toma, moved or older); a file, or a link to anything else, is left
/// as it is and said (`blocked`).
public struct CommandLineToolInstaller: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The link is in place at `at`; `inPath` tells whether its folder is in the `PATH`.
        case installed(at: URL, inPath: Bool)
        /// The link at `at` already pointed to this app's tool.
        case alreadyInstalled(at: URL)
        /// Something that is not Toma's link is at that place: nothing was done.
        case blocked(by: URL)
    }

    /// The app's `toma`, `Contents/Helpers/toma`.
    public let tool: URL
    public let systemFolder: URL
    public let userFolder: URL
    /// The folders a shell looks in, `:` between them.
    public let path: String

    public init(
        tool: URL, systemFolder: URL = URL(fileURLWithPath: "/usr/local/bin"),
        userFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin"),
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.tool = tool
        self.systemFolder = systemFolder
        self.userFolder = userFolder
        self.path = path
    }

    /// The `toma` of the app at `appBundle`.
    public static func tool(in appBundle: URL) -> URL {
        appBundle.appending(path: "Contents/Helpers/toma", directoryHint: .notDirectory)
    }

    /// The folders a login shell starts with: `PATH` as the app has it, then those of `/etc/paths` and of the files
    /// of `/etc/paths.d`, as `path_helper` reads them. An app opened from the Finder has a short `PATH`; a folder the
    /// user adds in their shell's files is not known.
    public static var loginPath: String {
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var files = ["/etc/paths"]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            files += names.sorted().map { "/etc/paths.d/\($0)" }
        }
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            folders += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Puts the link in place: in `systemFolder` if it is a folder this user can write, otherwise in `userFolder`.
    /// - Throws: what making `userFolder` or the link threw (a `CocoaError` or a `POSIXError`, whose description says
    ///   it in the user's words).
    public func install() throws -> Outcome {
        let folder = isWritableFolder(systemFolder) ? systemFolder : userFolder
        if folder == userFolder {
            try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        }
        let link = folder.appending(path: "toma", directoryHint: .notDirectory)
        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK, let destination = destination(of: link) else { return .blocked(by: link) }
            if destination == tool.standardizedFileURL.path { return .alreadyInstalled(at: link) }
            guard Self.isAppTool(destination) else { return .blocked(by: link) }
        }
        try placeLink(at: link)
        return .installed(at: link, inPath: isInPath(folder))
    }

    /// The link of the system's or the user's folder that points to this app's tool; `nil` if neither does.
    public func installed() -> URL? {
        for folder in [systemFolder, userFolder] {
            let link = folder.appending(path: "toma", directoryHint: .notDirectory)
            if destination(of: link) == tool.standardizedFileURL.path { return link }
        }
        return nil
    }

    /// Whether `folder` is one of `path`'s, as it is written there or with its links resolved.
    public func isInPath(_ folder: URL) -> Bool {
        let wanted = Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
        return path.split(separator: ":").contains { entry in
            let expanded = URL(fileURLWithPath: (String(entry) as NSString).expandingTildeInPath)
            return wanted.contains(expanded.standardizedFileURL.path) || wanted.contains(expanded.resolvingSymlinksInPath().path)
        }
    }

    // MARK: - Private

    /// Where the link at `url` points, as an absolute standardized path; `nil` if it is not a link.
    private func destination(of url: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let absolute = target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appending(path: target)
        return absolute.standardizedFileURL.path
    }

    /// A `toma` inside an app: `<name>.app/Contents/Helpers/toma`.
    private static func isAppTool(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count >= 4 else { return false }
        let tail = parts.suffix(4)
        return tail.first.map { ($0 as NSString).pathExtension.lowercased() == "app" } == true
            && Array(tail.dropFirst()) == ["Contents", "Helpers", "toma"]
    }

    /// A folder (or a link to one) this user can write.
    private func isWritableFolder(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && access(url.path, W_OK) == 0
    }

    /// The link to `tool` at `link`, put in place in one step (a link of another name, renamed over it).
    private func placeLink(at link: URL) throws {
        let temporary = link.deletingLastPathComponent().appending(path: ".toma-\(UUID().uuidString)")
        guard symlink(tool.path, temporary.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary.path, link.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temporary.path)
            throw POSIXError(code)
        }
    }
}
