// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import RecorderKitTestSupport
import Testing

/// «Install Command Line Tool» (plan 4b decision 20), always in temporary folders: never `/usr/local/bin` nor
/// `~/.local/bin`.
@Suite struct CommandLineToolInstallerTests {
    /// An app at `dir/<name>.app` with its `Contents/Helpers/toma`.
    static func app(_ name: String, in dir: URL) throws -> URL {
        let tool = CommandLineToolInstaller.tool(in: dir.appending(path: "\(name).app", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        return tool
    }

    static func destination(of link: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    @Test func installsInTheSystemFolderWhenWritable() throws {
        try withTemporaryDirectory { dir in
            let tool = try Self.app("Toma", in: dir)
            let system = dir.appending(path: "system", directoryHint: .isDirectory)
            let user = dir.appending(path: "user/.local/bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
            let installer = CommandLineToolInstaller(tool: tool, systemFolder: system, userFolder: user, path: "/usr/bin:\(system.path)")
            #expect(installer.installed() == nil)
            let link = system.appending(path: "toma")
            #expect(try installer.install() == .installed(at: link, inPath: true))
            #expect(try Self.destination(of: link) == tool.path)
            #expect(installer.installed() == link)
            // The user's folder was never made.
            #expect(!FileManager.default.fileExists(atPath: user.path))
            #expect(try installer.install() == .alreadyInstalled(at: link))
        }
    }

    @Test func fallsBackToTheUserFolder() throws {
        try withTemporaryDirectory { dir in
            let tool = try Self.app("Toma", in: dir)
            let system = dir.appending(path: "system", directoryHint: .isDirectory)
            let user = dir.appending(path: "home/.local/bin", directoryHint: .isDirectory)
            // A system folder that is not there.
            let missing = CommandLineToolInstaller(tool: tool, systemFolder: system, userFolder: user, path: "/usr/bin")
            #expect(try missing.install() == .installed(at: user.appending(path: "toma"), inPath: false))
            #expect(try Self.destination(of: user.appending(path: "toma")) == tool.path)
            // One this user cannot write.
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: system.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path) }
            let readOnly = CommandLineToolInstaller(tool: tool, systemFolder: system, userFolder: user, path: "/usr/bin")
            #expect(try readOnly.install() == .alreadyInstalled(at: user.appending(path: "toma")))
            #expect(readOnly.installed() == user.appending(path: "toma"))
            #expect(!FileManager.default.fileExists(atPath: system.appending(path: "toma").path))
        }
    }

    @Test func replacesOnlyItsOwnLink() throws {
        try withTemporaryDirectory { dir in
            let tool = try Self.app("Toma", in: dir)
            // Toma moved: the link points to where it was, an app that is not there any more, or to another copy.
            let moved = dir.appending(path: "Old/Toma.app/Contents/Helpers/toma")
            let other = try Self.app("Toma Beta", in: dir.appending(path: "Other", directoryHint: .isDirectory))
            let user = dir.appending(path: "bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let link = user.appending(path: "toma")
            let installer = CommandLineToolInstaller(
                tool: tool, systemFolder: dir.appending(path: "none"), userFolder: user, path: user.path)
            for old in [moved, other] {
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: old.path)
                #expect(installer.installed() == nil)
                #expect(try installer.install() == .installed(at: link, inPath: true))
                #expect(try Self.destination(of: link) == tool.path)
            }
            // No other file was left in the folder.
            #expect(try FileManager.default.contentsOfDirectory(atPath: user.path) == ["toma"])
        }
    }

    @Test func neverOverwritesAFileOrAForeignLink() throws {
        try withTemporaryDirectory { dir in
            let tool = try Self.app("Toma", in: dir)
            let user = dir.appending(path: "bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let link = user.appending(path: "toma")
            let installer = CommandLineToolInstaller(tool: tool, systemFolder: dir.appending(path: "none"), userFolder: user)
            // A file of someone else's.
            try Data("another toma".utf8).write(to: link)
            #expect(try installer.install() == .blocked(by: link))
            #expect(try Data(contentsOf: link) == Data("another toma".utf8))
            // A link to another tool, and one to a toma that is not in an app.
            for foreign in ["/usr/bin/true", dir.appending(path: "Tools/toma").path, dir.appending(path: "Toma.app/toma").path] {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: foreign)
                #expect(try installer.install() == .blocked(by: link))
                #expect(try Self.destination(of: link) == foreign)
                #expect(installer.installed() == nil)
            }
            // A folder named toma.
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            #expect(try installer.install() == .blocked(by: link))
        }
    }

    @Test func saysWhetherTheFolderIsInPath() throws {
        try withTemporaryDirectory { dir in
            let tool = try Self.app("Toma", in: dir)
            let user = dir.appending(path: "home/.local/bin", directoryHint: .isDirectory)
            func installer(_ path: String) -> CommandLineToolInstaller {
                CommandLineToolInstaller(tool: tool, systemFolder: dir.appending(path: "none"), userFolder: user, path: path)
            }
            #expect(installer("/usr/bin:/bin:\(user.path)").isInPath(user))
            #expect(installer("\(user.path)/").isInPath(user))
            #expect(!installer("/usr/bin:/bin").isInPath(user))
            #expect(!installer("").isInPath(user))
            // Through a link: /var is /private/var.
            #expect(installer(user.resolvingSymlinksInPath().path).isInPath(user))
            #expect(try installer("/usr/bin").install() == .installed(at: user.appending(path: "toma"), inPath: false))
            // The login shell's folders include /etc/paths'.
            #expect(CommandLineToolInstaller.loginPath.split(separator: ":").contains("/usr/bin"))
        }
    }
}
