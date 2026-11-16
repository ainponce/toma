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
