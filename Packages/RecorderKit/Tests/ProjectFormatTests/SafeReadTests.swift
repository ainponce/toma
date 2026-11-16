// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing

@testable import ProjectFormat

/// A file that grew past the limit after `fstat` measured it: the read stops one byte past the limit, the byte that
/// tells it from a file that ends there, and refuses it.
@Test func boundedReadOfAFileThatGrewStopsOneBytePastTheLimit() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "manifest.json")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }

        // As if `fstat` had said 70 000 bytes (more than one buffer) and the file had grown to 300 000 since.
        #expect(throws: POSIXError(.EFBIG)) { try SafeRead.readToEnd(fd, capacity: 70_000, limit: 70_000) }
        #expect(lseek(fd, 0, SEEK_CUR) == 70_001)

        // A file that ends at the limit is read whole.
        #expect(lseek(fd, 0, SEEK_SET) == 0)
        #expect(try SafeRead.readToEnd(fd, capacity: 0, limit: 300_000) == bytes)
        #expect(lseek(fd, 0, SEEK_SET) == 0)
        #expect(try SafeRead.readToEnd(fd, capacity: 0, limit: nil) == bytes)
    }
}

/// A file reached from a folder one component at a time: a link below the folder is refused wherever it is, the folder
/// itself may be reached through one.
@Test func regularFileInAFolderFollowsNoLinkBelowIt() throws {
    try withTemporaryDirectory { dir in
        let root = dir.appending(path: "Demo.toma", directoryHint: .isDirectory)
        let inner = root.appending(path: "takes/take-001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let bytes = Data("{\"t\":1}\n".utf8)
        try bytes.write(to: inner.appending(path: "events.jsonl"))
        #expect(try SafeRead.regularFile("takes/take-001/events.jsonl", in: root) == bytes)
        // Through the user's own link to the folder (and `/var`, which the temporary folder is under).
        let alias = dir.appending(path: "Alias.toma", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(try SafeRead.regularFile("takes/take-001/events.jsonl", in: alias) == bytes)

        // A copy elsewhere, which a link below the folder would lead to.
        let elsewhere = dir.appending(path: "elsewhere/take-001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try bytes.write(to: elsewhere.appending(path: "events.jsonl"))
        let other = dir.appending(path: "Other.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other.appending(path: "takes"), withIntermediateDirectories: true)
        for (path, link, target) in [
            ("takes/take-001/events.jsonl", other.appending(path: "takes/take-001"), elsewhere),
            ("takes/take-001/events.jsonl", other.appending(path: "takes"), elsewhere.deletingLastPathComponent()),
            ("events.jsonl", other.appending(path: "events.jsonl"), elsewhere.appending(path: "events.jsonl")),
        ] {
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: POSIXError(.ELOOP), "\(link.lastPathComponent)") { try SafeRead.regularFile(path, in: other) }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: other.appending(path: "takes"), withIntermediateDirectories: true)
        }

        // A FIFO is refused at once; a file on the way is not a folder; nothing is not there.
        #expect(mkfifo(inner.appending(path: "fifo").path, 0o644) == 0)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: POSIXError(.EFTYPE)) { try SafeRead.regularFile("takes/take-001/fifo", in: root) }
        #expect(clock.now - started < .milliseconds(100))
        #expect(throws: POSIXError(.ENOTDIR)) { try SafeRead.regularFile("takes/take-001/events.jsonl/x", in: root) }
        #expect(throws: POSIXError(.ENOENT)) { try SafeRead.regularFile("takes/take-002/events.jsonl", in: root) }
        // Only names, going down.
        for path in ["", "/takes/take-001/events.jsonl", "takes//take-001/events.jsonl", "takes/../takes/take-001/events.jsonl",
            "./takes/take-001/events.jsonl", "takes/take-001/"]
        {
            #expect(throws: POSIXError(.EINVAL), "\(path)") { try SafeRead.regularFile(path, in: root) }
        }
    }
}
