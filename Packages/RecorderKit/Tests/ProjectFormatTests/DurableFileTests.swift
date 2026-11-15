// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: these are the APIs other modules use, so they must be public.
import ProjectFormat

private func fileSystemType(at url: URL) throws -> String {
    var info = statfs()
    guard statfs(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

@Suite struct DurableFileTests {
    @Test func barrierAndFullSyncWorkOnHFSPlus() async throws {
        try withTemporaryDirectory { dir in
            let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .hfsPlus, in: dir)
            let mount = disk.mountPoint
            defer {
                do {
                    try disk.detach()
                } catch {
                    Issue.record(error)
                    try? disk.detach(force: true)
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
        try withTemporaryDirectory { dir in
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

    @Test func writeNewNeverReplaces() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("display-1.png")
            try DurableFile.writeNew(Data("first".utf8), to: url)
            #expect(try Data(contentsOf: url) == Data("first".utf8))
            #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))

            let error = #expect(throws: POSIXError.self) { try DurableFile.writeNew(Data("second".utf8), to: url) }
            #expect(error?.code == .EEXIST)
            #expect(try Data(contentsOf: url) == Data("first".utf8))
            #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))

            // A symlink at the destination is there too: it is neither replaced nor followed.
            let victim = dir.appendingPathComponent("victim.txt")
            try Data("not a snapshot".utf8).write(to: victim)
            let link = dir.appendingPathComponent("display-2.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
            let linked = #expect(throws: POSIXError.self) { try DurableFile.writeNew(Data("third".utf8), to: link) }
            #expect(linked?.code == .EEXIST)
            #expect(try Data(contentsOf: victim) == Data("not a snapshot".utf8))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == victim.path)
            #expect(!FileManager.default.fileExists(atPath: link.path + ".tmp"))
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
}
