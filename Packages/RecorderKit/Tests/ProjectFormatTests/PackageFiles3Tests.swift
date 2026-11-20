// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

// Phase 3 (base plan, Task B3, decision 13; design §5.4, §7.7, §8.5): the clips and the audio of the user's own in
// `assets/`, and the project's script, `script.txt`.

private let hash = "0123456789abcdef0123456789abcdef"

/// `<dir>/Demo.toma` with `takes/take-001/`, as a recorded package has it.
private func makePackage(in dir: URL) throws -> ProjectPackage {
    let package = ProjectPackage(url: dir.appendingPathComponent("Demo.toma", isDirectory: true))
    try FileManager.default.createDirectory(at: package.takeDirectory("take-001"), withIntermediateDirectories: true)
    return package
}

/// Writes `data` at `relativePath` of `package`, making the folders it needs.
private func put(_ data: Data, at relativePath: String, in package: ProjectPackage) throws {
    let url = package.url.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

@Test func mediaKindsNameTheirFiles() {
    for ext in ["mov", "mp4", "m4v"] { #expect(PackageFileKind.video.isValidName("\(hash).\(ext)"), "\(ext)") }
    for ext in ["m4a", "mp3", "wav", "aiff", "caf"] { #expect(PackageFileKind.audio.isValidName("\(hash).\(ext)"), "\(ext)") }
    // Lowercase only, the extensions of each kind only, and `aif` is named `aiff`.
    for name in ["\(hash).MOV", "\(hash).m4a", "\(hash).png", "\(hash.uppercased()).mov", "\(hash.dropLast()).mov", "x.mov", "\(hash).mov.tmp"] {
        #expect(!PackageFileKind.video.isValidName(name), "\(name)")
    }
    for name in ["\(hash).aif", "\(hash).M4A", "\(hash).ogg", "\(hash).mov", "\(hash)m4a"] {
        #expect(!PackageFileKind.audio.isValidName(name), "\(name)")
    }
    #expect(PackageFileKind.script.isValidName("script.txt"))
    for name in ["Script.txt", "script.txt.tmp", "script", "\(hash).txt"] { #expect(!PackageFileKind.script.isValidName(name)) }
    // Neither is an image: nothing of theirs reaches ImageIO.
    for kind in [PackageFileKind.video, .audio, .script] {
        #expect(kind.imageTypes.isEmpty && kind.maxPixelSide == 0)
        #expect(kind.decodedImage(Data([0x89, 0x50, 0x4E, 0x47])) == nil)
    }
    #expect(PackageFileKind.video.maxBytes == 16 << 30)
    #expect(PackageFileKind.audio.maxBytes == 2 << 30)
    #expect(PackageFileKind.script.maxBytes == 1 << 20)
}

@Test func mediaAssetsAreNamedAndPlacedLikeImages() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let clip = "assets/\(hash).mov", sound = "assets/\(hash).m4a"
        try put(Data("a clip".utf8), at: clip, in: package)
        try put(Data("a sound".utf8), at: sound, in: package)

        #expect(package.mediaAsset(clip, as: .video) == package.url.appending(path: clip))
        #expect(package.mediaAsset(sound, as: .audio) == package.url.appending(path: sound))
        // Each kind its own names, and only in `assets/`.
        #expect(package.mediaAsset(clip, as: .audio) == nil)
        #expect(package.mediaAsset(sound, as: .video) == nil)
        #expect(package.mediaAsset(clip, as: .asset) == nil)
        #expect(package.mediaAsset("assets/\(hash).png", as: .asset) == nil)
        try put(Data("a clip".utf8), at: "takes/take-001/\(hash).mov", in: package)
        try put(Data("a clip".utf8), at: "\(hash).mov", in: package)
        try put(Data("a clip".utf8), at: "assets/\(hash).MOV", in: package)
        for path in ["takes/take-001/\(hash).mov", "\(hash).mov", "assets/\(hash).MOV", "assets/x.mov", "assets/../assets/\(hash).mov",
                     "/assets/\(hash).mov", "assets//\(hash).mov", "assets/\(hash).mov/"]
        {
            #expect(package.mediaAsset(path, as: .video) == nil, "\(path)")
        }
        // Not there.
        #expect(package.mediaAsset("assets/\(String(repeating: "f", count: 32)).mov", as: .video) == nil)

        // A link, to a file inside the package or out of it, is never handed on.
        let outside = dir.appending(path: "outside.mov")
        try Data("elsewhere".utf8).write(to: outside)
        let linked = "assets/\(String(repeating: "a", count: 32)).mp4"
        try FileManager.default.createSymbolicLink(at: package.url.appending(path: linked), withDestinationURL: outside)
        #expect(package.mediaAsset(linked, as: .video) == nil)
        // A FIFO, which AVFoundation would wait on forever.
        let fifo = "assets/\(String(repeating: "b", count: 32)).wav"
        #expect(mkfifo(package.url.appending(path: fifo).path, 0o644) == 0)
        #expect(package.mediaAsset(fifo, as: .audio) == nil)
        // A folder of that name.
        let folder = "assets/\(String(repeating: "c", count: 32)).caf"
        try FileManager.default.createDirectory(at: package.url.appending(path: folder), withIntermediateDirectories: false)
        #expect(package.mediaAsset(folder, as: .audio) == nil)
        // Larger than its kind allows (a sparse file: nothing is written).
        let large = "assets/\(String(repeating: "d", count: 32)).aiff"
        try put(Data(), at: large, in: package)
        #expect(truncate(package.url.appending(path: large).path, off_t(PackageFileKind.audio.maxBytes) + 1) == 0)
        #expect(package.mediaAsset(large, as: .audio) == nil)
        #expect(truncate(package.url.appending(path: large).path, off_t(PackageFileKind.audio.maxBytes)) == 0)
        #expect(package.mediaAsset(large, as: .audio) != nil)
    }
}

@Test func mediaAssetsAreNeverReachedThroughALinkedFolder() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let elsewhere = dir.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try Data("a clip".utf8).write(to: elsewhere.appending(path: "\(hash).mov"))
        try FileManager.default.createSymbolicLink(at: package.assetsURL, withDestinationURL: elsewhere)
        #expect(package.mediaAsset("assets/\(hash).mov", as: .video) == nil)
    }
}

@Test func scriptIsWrittenAndReadWhole() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        #expect(package.scriptURL == package.url.appending(path: "script.txt"))
        #expect(package.readScript() == nil)

        let text = "Hola, esto es Toma.\nUna línea con ñ y 😀.\n"
        try package.writeScript(text)
        #expect(package.readScript() == text)
        #expect(try Data(contentsOf: package.scriptURL) == Data(text.utf8))
        #expect(!FileManager.default.fileExists(atPath: package.scriptURL.path + ".tmp"))
        try package.writeScript("")
        #expect(package.readScript() == "")
        let whole = String(repeating: "x", count: PackageFileKind.script.maxBytes)
        try package.writeScript(whole)
        #expect(package.readScript() == whole)

        // Larger than 1 MiB: never written, and one put there is not read.
        #expect(throws: POSIXError(.EFBIG)) { try package.writeScript(whole + "y") }
        #expect(package.readScript() == whole)
        try Data((whole + "y").utf8).write(to: package.scriptURL)
        #expect(package.readScript() == nil)
        // Bytes that are not UTF-8.
        try Data([0x48, 0x6F, 0xFF, 0x6C, 0x61]).write(to: package.scriptURL)
        #expect(package.readScript() == nil)

        // A link in its place: not read, and replaced by the write, never followed.
        let outside = dir.appending(path: "outside.txt")
        try Data("not the script".utf8).write(to: outside)
        try FileManager.default.removeItem(at: package.scriptURL)
        try FileManager.default.createSymbolicLink(at: package.scriptURL, withDestinationURL: outside)
        #expect(package.readScript() == nil)
        try package.writeScript("the script")
        #expect(package.readScript() == "the script")
        #expect(try Data(contentsOf: outside) == Data("not the script".utf8))
        var info = stat()
        #expect(lstat(package.scriptURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)

        // A FIFO in its place is not waited on.
        try FileManager.default.removeItem(at: package.scriptURL)
        #expect(mkfifo(package.scriptURL.path, 0o644) == 0)
        #expect(package.readScript() == nil)
        try package.writeScript("again")
        #expect(package.readScript() == "again")
    }
}

@Test func theScriptIsWrittenWhereThePackageIsNow() throws {
    try withTemporaryDirectory { dir in
        let first = dir.appending(path: "First.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        let handle = try #require(PackageHandle(url: first))
        let package = ProjectPackage(url: first, handle: handle)
        let moved = dir.appending(path: "Moved.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: first, to: moved)

        try package.writeScript("moved along")
        #expect(package.readScript() == "moved along")
        #expect(try String(contentsOf: moved.appending(path: "script.txt"), encoding: .utf8) == "moved along")
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }
}
