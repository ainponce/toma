// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
// Not @testable: these are the APIs other modules use, so they must be public.
import ProjectFormat

private struct HdiutilFailed: Error, CustomStringConvertible {
    var arguments: [String]
    var status: Int32
    var output: String
    var description: String { "hdiutil \(arguments.joined(separator: " ")) exited \(status): \(output)" }
}

private func hdiutil(_ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HdiutilFailed(arguments: arguments, status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

private func fileSystemType(at url: URL) throws -> String {
    var info = statfs()
    guard statfs(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

@Test func barrierAndFullSyncWorkOnHFSPlus() async throws {
    try await withTemporaryDirectory { dir in
        let image = dir.appendingPathComponent("TomaTest.dmg")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "TomaTest", image.path)
        try hdiutil("attach", "-nobrowse", "-mountpoint", mount.path, image.path)
        defer {
            do {
                try hdiutil("detach", mount.path)
            } catch {
                Issue.record(error)
                try? hdiutil("detach", "-force", mount.path)
            }
        }
        #expect(try fileSystemType(at: mount) == "hfs")

        let file = mount.appendingPathComponent("seg-0001.mov")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(write(fd, "fragment", 8) == 8)
        try DurableFile.barrierSync(fd)
        try DurableFile.fullSync(fd)
        try DurableFile.syncDirectory(mount)

        let manifest = mount.appendingPathComponent("manifest.json")
        try DurableFile.writeAtomically(Data("{}".utf8), to: manifest)
        #expect(try Data(contentsOf: manifest) == Data("{}".utf8))
        #expect(!FileManager.default.fileExists(atPath: manifest.path + ".tmp"))
    }
}

@Test func writeAtomicallyNeverFollowsASymlinkAtTheTemporaryPath() async throws {
    try await withTemporaryDirectory { dir in
        let victim = dir.appendingPathComponent("victim.txt")
        let victimBytes = Data("not the manifest".utf8)
        try victimBytes.write(to: victim)
        let url = dir.appendingPathComponent("manifest.json")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("manifest.json.tmp"), withDestinationURL: victim)

        try DurableFile.writeAtomically(Data("new".utf8), to: url)

        #expect(try Data(contentsOf: url) == Data("new".utf8))
        #expect(try Data(contentsOf: victim) == victimBytes)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json.tmp").path))
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
    }
}

@Test func syncOfAnInvalidDescriptorThrows() {
    let barrier = #expect(throws: POSIXError.self) { try DurableFile.barrierSync(-1) }
    #expect(barrier?.code == .EBADF)
    let full = #expect(throws: POSIXError.self) { try DurableFile.fullSync(-1) }
    #expect(full?.code == .EBADF)
}

@Test func datesRoundDownToWholeSeconds() {
    #expect(Date(timeIntervalSince1970: 1_700_000_000.999).roundedToWholeSeconds == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(Date(timeIntervalSince1970: 1_700_000_000).roundedToWholeSeconds == Date(timeIntervalSince1970: 1_700_000_000))
}
