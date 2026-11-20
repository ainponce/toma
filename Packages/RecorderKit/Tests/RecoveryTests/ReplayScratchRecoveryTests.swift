// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

import Recovery

// Milestone 5c, Task R1 (fases 4 y 5 design §10.2, decision 13): what a forced quit leaves of the Replay is never
// recovered. The scanner skips its working package by the marker, before it reads the manifest.

/// The Replay's working package after a forced quit: `take-001` still `recording`, a segment on disk and a lock file
/// nobody holds.
private func crashedScratch(in root: URL) throws -> ProjectPackage {
    let package = try ReplayScratch.create(in: root, app: AppInfo(name: "Tests", version: "0"), now: Date())
    try addTake(makeTake(ReplayScratch.takeID, tracks: [displayTrack([try segmentRecord(package, track: "display-1", start: base)])]),
                to: package)
    try Data("frames".utf8).write(to: package.segmentURL(take: ReplayScratch.takeID, track: "display-1", index: 1))
    try Data("{}".utf8).write(to: package.lockURL(take: ReplayScratch.takeID))
    try Data().write(to: ReplayScratch.shardURL(of: package, index: 1))
    return package
}

@Suite struct ReplayScratchRecoveryTests {
    @Test func scannerSkipsTheReplayScratch() throws {
        try withTemporaryDirectory { dir in
            let package = try crashedScratch(in: dir)

            #expect(RecoveryScanner.scan(package: package).isEmpty)

            // The same package without the marker is a take to recover: only the marker tells them apart.
            try FileManager.default.removeItem(at: package.url.appendingPathComponent(ReplayScratch.markerName))
            #expect(RecoveryScanner.scan(package: package) == [.recoverable(package: package, takeID: ReplayScratch.takeID)])
        }
    }

    @Test func scratchIsSkippedBeforeItsManifestIsRead() throws {
        try withTemporaryDirectory { dir in
            let package = try crashedScratch(in: dir)
            // Half written or damaged: still nothing to repair, never shown.
            try Data("{".utf8).write(to: package.manifestURL)
            #expect(RecoveryScanner.scan(package: package).isEmpty)
        }
    }

    @Test func scanOfTheReplayFolderFindsNothing() throws {
        try withTemporaryDirectory { dir in
            let root = ReplayScratch.defaultRoot(cachesDirectory: dir, bundleID: "dev.toma.Toma")
            _ = try crashedScratch(in: root)
            #expect(RecoveryScanner.scan(directory: root).isEmpty)
        }
    }
}
