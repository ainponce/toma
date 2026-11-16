// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

@testable import Recovery

// A package can come from anywhere: recovery must never follow a path out of it.

private let victimBytes = Data("the user's file, which must stay as it is\n{\"t\":1".utf8)

/// A file outside the package, with `victimBytes`.
private func makeVictim(in dir: URL) throws -> URL {
    let victim = dir.appendingPathComponent("victim.txt")
    try victimBytes.write(to: victim)
    return victim
}

/// A `recording` take with one open mic segment, its folders created like the recorder's.
private func addOpenTake(to package: ProjectPackage) throws {
    try addTake(makeTake(tracks: [micTrack([try segmentRecord(package, track: "mic", start: base)])]), to: package)
}

private func expectNeedsRepair(_ results: [ScanResult], _ package: ProjectPackage, sourceLocation: SourceLocation = #_sourceLocation) {
    guard results.count == 1, case let .needsRepair(found, reason) = results[0] else {
        Issue.record("expected needsRepair, got \(results)", sourceLocation: sourceLocation)
        return
    }
    #expect(found == package && !reason.isEmpty, sourceLocation: sourceLocation)
}

@Test func symlinkedLockIsNeverFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let victim = try makeVictim(in: dir)
        let package = try makePackage(in: dir)
        try addOpenTake(to: package)
        try FileManager.default.createSymbolicLink(at: package.lockURL(take: "take-001"), withDestinationURL: victim)
        let manifest = try Data(contentsOf: package.manifestURL)

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.unexpectedEntry("takes/take-001/recording.lock"))) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }
        #expect(throws: POSIXError(.ELOOP)) {
            try RecordingLock.acquire(at: package.lockURL(take: "take-001"), info: .current(now: Date()))
        }
        #expect(!RecordingLock.isHeld(at: package.lockURL(take: "take-001")))

        #expect(try Data(contentsOf: victim) == victimBytes)
        #expect(try Data(contentsOf: package.manifestURL) == manifest)
    }
}

@Test func symlinkedEventLogIsNeverTruncated() async throws {
    try await withTemporaryDirectory { dir in
        let victim = try makeVictim(in: dir)
        let package = try makePackage(in: dir)
        try addOpenTake(to: package)
        try FileManager.default.createSymbolicLink(at: package.eventsURL(take: "take-001"), withDestinationURL: victim)

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.unexpectedEntry("takes/take-001/events.jsonl"))) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }
        #expect(throws: POSIXError(.ELOOP)) { try EventLogReader.truncateIncompleteTail(package.eventsURL(take: "take-001")) }
        #expect(throws: POSIXError(.ELOOP)) { try EventLogWriter(url: package.eventsURL(take: "take-001")) }

        #expect(try Data(contentsOf: victim) == victimBytes)
        #expect(try takeOnDisk(package, "take-001").status == .recording)
        #expect(!FileManager.default.fileExists(atPath: package.lockURL(take: "take-001").path))
    }
}

@Test func symlinkedWallpapersFolderIsNeverFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let package = try makePackage(in: dir)
        try addOpenTake(to: package)
        try FileManager.default.createSymbolicLink(at: package.wallpapersDirectory(take: "take-001"), withDestinationURL: outside)

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.unexpectedEntry("takes/take-001/wallpapers"))) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try takeOnDisk(package, "take-001").status == .recording)
    }
}

@Test func recoveryLeavesTheWallpapersAsTheyAre() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addOpenTake(to: package)
        let wallpapers = package.wallpapersDirectory(take: "take-001")
        try FileManager.default.createDirectory(at: wallpapers, withIntermediateDirectories: false)
        let snapshot = wallpapers.appendingPathComponent("display-1.png")
        try victimBytes.write(to: snapshot)

        #expect(RecoveryScanner.scan(directory: dir) == [.recoverable(package: package, takeID: "take-001")])
        #expect(try await TakeRecovery.recover(package: package, takeID: "take-001").status == .recovered)

        #expect(try FileManager.default.contentsOfDirectory(atPath: wallpapers.path) == ["display-1.png"])
        #expect(try Data(contentsOf: snapshot) == victimBytes)
    }
}

@Test func takeFolderSymlinkedOutsideThePackageIsNotTouched() async throws {
    try await withTemporaryDirectory { dir in
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("mic"), withIntermediateDirectories: true)
        let reserve = outside.appendingPathComponent(".reserve")
        try victimBytes.write(to: reserve)
        let package = try makePackage(in: dir)
        try FileManager.default.createSymbolicLink(at: package.takeDirectory("take-001"), withDestinationURL: outside)
        try ManifestStore(package: package).update {
            $0.takes.append(makeTake(tracks: [micTrack([try segmentRecord(package, track: "mic", start: base)])]))
        }

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.unexpectedEntry("takes/take-001"))) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }

        #expect(try Data(contentsOf: reserve) == victimBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == [".reserve", "mic"])
    }
}

@Test func takeIDThatLeavesThePackageIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try ManifestStore(package: package).update {
            $0.takes.append(makeTake("../../escape", tracks: [micTrack([])]))
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.invalidTakeID("../../escape"))) {
            try await TakeRecovery.recover(package: package, takeID: "../../escape")
        }
        #expect(throws: LoadedProjectError.invalidPath(.invalidTakeID("../../escape"))) {
            try LoadedProject.load(package.url)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape").path))
    }
}

@Test func manifestPathsAreValidated() throws {
    let file = "takes/take-001/mic/seg-0001.mov"
    func take(_ id: String = "take-001", track: String = "mic", file: String = file, index: Int = 1) -> TakeRecord {
        makeTake(id, tracks: [TrackRecord(id: track, kind: .microphone, source: micSource, segments: [
            SegmentRecord(index: index, file: file, startHostTime: base, droppedFrames: 0, heartbeatFrames: 0),
        ])])
    }
    #expect(throws: Never.self) { try take().validatePaths() }
    #expect(throws: Never.self) { try take("take-1234", file: "takes/take-1234/mic/seg-0001.mov").validatePaths() }
    #expect(throws: PackagePathError.invalidTakeID("take-01")) { try take("take-01").validatePaths() }
    #expect(throws: PackagePathError.invalidTakeID("take-00a")) { try take("take-00a").validatePaths() }
    #expect(throws: PackagePathError.invalidTrackID(take: "take-001", track: "..")) { try take(track: "..").validatePaths() }
    #expect(throws: PackagePathError.invalidTrackID(take: "take-001", track: "a/b")) { try take(track: "a/b").validatePaths() }
    for bad in ["takes/take-001/mic/../../../x.mov", "takes/take-001/mic/seg-0002.mov", "/tmp/seg-0001.mov", "takes/take-001/mic/seg-1.mov"] {
        #expect(throws: PackagePathError.invalidSegmentFile(take: "take-001", track: "mic", file: bad)) {
            try take(file: bad).validatePaths()
        }
    }
    #expect(throws: PackagePathError.invalidSegmentFile(take: "take-001", track: "mic", file: "takes/take-001/mic/seg-0000.mov")) {
        try take(file: "takes/take-001/mic/seg-0000.mov", index: 0).validatePaths()
    }
}

/// The project id names the project's cache folder outside the package: one that is not 32 lowercase hex digits
/// (`..` in it, empty, `.`) could put that folder anywhere, so the manifest is refused like one with a bad take ID.
@Test func projectIDThatIsNotThirtyTwoHexDigitsIsRefused() async throws {
    let empty = Manifest(formatVersion: 3, app: AppInfo(name: "Tests", version: "0"), createdAt: Date(timeIntervalSince1970: 0), takes: [])
    for bad in ["../../x", "", ".", "..", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcde", "a/0123456789abcdef0123456789abcd"] {
        var manifest = empty
        manifest.projectID = bad
        #expect(throws: PackagePathError.invalidProjectID(bad)) { try manifest.validatePaths() }
    }
    var valid = empty
    valid.projectID = "0123456789abcdef0123456789abcdef"
    #expect(throws: Never.self) { try valid.validatePaths() }
    // Version 1 and 2 have none: their id is the derived one.
    for version in [1, 2] {
        var legacy = empty
        legacy.formatVersion = version
        #expect(throws: Never.self) { try legacy.validatePaths() }
    }

    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake(tracks: [micTrack([])]), to: package)
        try ManifestStore(package: package).update { $0.projectID = "../../escape" }
        let before = try Data(contentsOf: package.manifestURL)

        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)
        await #expect(throws: RecoveryError.invalidPath(.invalidProjectID("../../escape"))) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }
        #expect(throws: LoadedProjectError.invalidPath(.invalidProjectID("../../escape"))) {
            try LoadedProject.load(package.url)
        }
        #expect(try Data(contentsOf: package.manifestURL) == before)

        // A package of version 1 or 2 opens without one, and a version 3 one with the id it was created with.
        for version in [1, 2, 3] {
            let builder = try TakeBuilder(in: dir, name: "v\(version)", formatVersion: version)
            try await builder.addAudioTrack(id: "mic", source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 0.1)])
            let project = try builder.write()
            #expect(project.manifest.formatVersion == version)
            #expect((project.manifest.projectID == nil) == (version < 3))
            #expect(ProjectID.isValid(project.manifest.resolvedProjectID))
        }
    }
}

@Test func takeFolderTheManifestDoesNotListIsReported() async throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake("take-001", status: .complete, tracks: [micTrack([])]), to: package)
        // A take whose first manifest write never landed: its segment is on disk, the manifest knows nothing.
        let orphan = package.segmentURL(take: "take-002", track: "display-1", index: 1)
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: orphan)
        // An empty folder left by a start that failed before recording is not.
        try FileManager.default.createDirectory(at: package.takeDirectory("take-003"), withIntermediateDirectories: false)
        let manifest = try Data(contentsOf: package.manifestURL)

        let results = RecoveryScanner.scan(directory: dir)
        guard results.count == 1, case let .needsRepair(found, reason) = results[0] else {
            Issue.record("expected needsRepair, got \(results)")
            return
        }
        #expect(found == package)
        #expect(reason.contains("takes/take-002") && !reason.contains("take-003"), "\(reason)")
        #expect(try Data(contentsOf: package.manifestURL) == manifest)  // read-only
    }
}

@Test func scannerNamesALeftoverLockAsSuch() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake("take-001", status: .complete, tracks: [micTrack([])]), to: package)
        // A recorder that died after taking the lock and before the take's first manifest write.
        try FileManager.default.createDirectory(at: package.takeDirectory("take-002"), withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: package.lockURL(take: "take-002"))

        let lockOnly = "takes/take-002 holds only a leftover recording.lock and manifest.json does not list it"
        #expect(RecoveryScanner.scan(directory: dir) == [.needsRepair(package: package, reason: lockOnly)])

        // Next to a folder with recorded files, each is named for what it holds.
        let orphan = package.segmentURL(take: "take-003", track: "camera", index: 1)
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: orphan)
        let recorded = "takes/take-003 holds recorded files that manifest.json does not list"
        #expect(RecoveryScanner.scan(directory: dir) == [.needsRepair(package: package, reason: "\(recorded); \(lockOnly)")])
    }
}

@Test func takeFolderWithAFreeLockTheManifestDoesNotListIsReported() async throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try FileManager.default.createDirectory(at: package.takeDirectory("take-001"), withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: package.lockURL(take: "take-001"))
        expectNeedsRepair(RecoveryScanner.scan(directory: dir), package)

        // The same folder while its recorder holds the lock is a take starting right now.
        try FileManager.default.removeItem(at: package.lockURL(take: "take-001"))
        let held = try RecordingLock.acquire(at: package.lockURL(take: "take-001"), info: .current(now: Date()))
        defer { held.release() }
        Swift.withExtendedLifetime(held) {
            #expect(RecoveryScanner.scan(directory: dir).isEmpty)
        }
    }
}
