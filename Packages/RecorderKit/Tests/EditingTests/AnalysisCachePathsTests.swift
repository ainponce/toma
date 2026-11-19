// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// A package folder with the camera's first segment of `take-001` written as `bytes`, modified at `modified` ns since
/// 1970, and the project's cache folder next to it.
private struct AnalysisFixture {
    static let projectID = String(repeating: "ab", count: 16)
    static let segment = SegmentRecord(
        index: 1, file: "takes/take-001/camera/seg-0001.mov", startHostTime: HostTime(nanoseconds: 1_000_000_000),
        endHostTime: HostTime(nanoseconds: 2_000_000_000), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)

    let package: ProjectPackage
    let caches: ProjectCaches

    init(in dir: URL) throws {
        package = ProjectPackage(url: dir.appending(path: "Demo.toma", directoryHint: .isDirectory))
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: Self.projectID)
        try FileManager.default.createDirectory(
            at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    var segmentURL: URL { package.fileURL(Self.segment.file) }

    func writeSegment(_ bytes: Int, modified: Int64) throws {
        unlink(segmentURL.path)
        try Data(repeating: 7, count: bytes).write(to: segmentURL)
        try setModified(modified)
    }

    func setModified(_ modified: Int64) throws {
        let time = timespec(tv_sec: Int(modified / 1_000_000_000), tv_nsec: Int(modified % 1_000_000_000))
        let times = [time, time]
        guard utimensat(AT_FDCWD, segmentURL.path, times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

@Test func analysisFilesAreNamedBySegmentIdentity() throws {
    try withTemporaryDirectory { dir in
        let fixture = try AnalysisFixture(in: dir)
        try fixture.writeSegment(1_234, modified: 1_700_000_000_123_456_789)

        let identity = try #require(SegmentIdentity.of(AnalysisFixture.segment, in: fixture.package))
        #expect(identity == SegmentIdentity(stem: "seg-0001", bytes: 1_234, modified: 1_700_000_000_123_456_789))
        #expect(identity.name == "seg-0001-1234-1700000000123456789")

        #expect(fixture.caches.folder(.masks) == fixture.caches.directory.appending(path: "masks", directoryHint: .isDirectory))
        for folder in AnalysisCacheFolder.allCases {
            #expect(fixture.caches.folder(folder).lastPathComponent == folder.rawValue)
            #expect(fixture.caches.folder(folder).deletingLastPathComponent().path == fixture.caches.directory.path)
        }

        let file = fixture.caches.analysisFile(
            .masks, take: "take-001", track: "camera", segment: identity, algorithm: "personMask-1", extension: "mov")
        #expect(file?.path == fixture.caches.directory.path + "/masks/take-001/camera/seg-0001-1234-1700000000123456789-personMask-1.mov")
        let clean = fixture.caches.analysisFile(
            .clean, take: "take-001", track: "mic-1", segment: identity, algorithm: "soundIsolation-2", extension: "caf")
        #expect(clean?.path == fixture.caches.directory.path + "/clean/take-001/mic-1/seg-0001-1234-1700000000123456789-soundIsolation-2.caf")
    }
}

@Test func identityChangesWithSizeOrDate() throws {
    try withTemporaryDirectory { dir in
        let fixture = try AnalysisFixture(in: dir)
        func name() throws -> String {
            let identity = try #require(SegmentIdentity.of(AnalysisFixture.segment, in: fixture.package))
            return try #require(fixture.caches.analysisFile(
                .faces, take: "take-001", track: "camera", segment: identity, algorithm: "faceTrack-1", extension: "json")
            ).lastPathComponent
        }

        try fixture.writeSegment(100, modified: 1_700_000_000_000_000_000)
        let first = try name()
        #expect(try name() == first)

        // Other bytes, the same date.
        try fixture.writeSegment(101, modified: 1_700_000_000_000_000_000)
        let resized = try name()
        #expect(resized != first)

        // The same bytes, a date 1 ns later.
        try fixture.setModified(1_700_000_000_000_000_001)
        let touched = try name()
        #expect(touched != resized)
        #expect(touched == "seg-0001-101-1700000000000000001-faceTrack-1.json")
    }
}

@Test func aSymlinkedSegmentHasNoIdentity() throws {
    try withTemporaryDirectory { dir in
        let fixture = try AnalysisFixture(in: dir)
        // Missing.
        #expect(SegmentIdentity.of(AnalysisFixture.segment, in: fixture.package) == nil)

        // A symlink to a real file is not followed.
        let elsewhere = dir.appending(path: "elsewhere.mov")
        try Data(repeating: 1, count: 64).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: fixture.segmentURL, withDestinationURL: elsewhere)
        #expect(SegmentIdentity.of(AnalysisFixture.segment, in: fixture.package) == nil)

        // Nor is a folder a segment.
        unlink(fixture.segmentURL.path)
        try FileManager.default.createDirectory(at: fixture.segmentURL, withIntermediateDirectories: false)
        #expect(SegmentIdentity.of(AnalysisFixture.segment, in: fixture.package) == nil)
    }
}

@Test func idsThatAreNotOneNameHaveNoFile() {
    let caches = ProjectCaches(root: URL(filePath: "/tmp/caches", directoryHint: .isDirectory), projectID: AnalysisFixture.projectID)
    let identity = SegmentIdentity(stem: "seg-0001", bytes: 10, modified: 20)
    func file(take: String = "take-001", track: String = "camera", segment: SegmentIdentity = identity,
              algorithm: String = "personMask-1", extension ext: String = "mov") -> URL? {
        caches.analysisFile(.masks, take: take, track: track, segment: segment, algorithm: algorithm, extension: ext)
    }

    #expect(file() != nil)
    for bad in ["a/b", "..", ".", "", "a\u{0}b"] {
        #expect(file(take: bad) == nil, "take \(bad.debugDescription)")
        #expect(file(track: bad) == nil, "track \(bad.debugDescription)")
        #expect(caches.scanFile(take: bad, algorithm: "sensitiveScan-1") == nil, "scan take \(bad.debugDescription)")
    }
    #expect(file(segment: SegmentIdentity(stem: "../seg", bytes: 10, modified: 20)) == nil)
    #expect(file(algorithm: "personMask-1/../../x") == nil)
    #expect(file(extension: "mov/x") == nil)
    #expect(caches.scanFile(take: "take-001", algorithm: "a/b") == nil)
}

@Test func scanFileIsPerTake() {
    let caches = ProjectCaches(root: URL(filePath: "/tmp/caches", directoryHint: .isDirectory), projectID: AnalysisFixture.projectID)
    #expect(caches.scanFile(take: "take-001", algorithm: "sensitiveScan-1")?.path
        == caches.directory.path + "/scan/take-001-sensitiveScan-1.json")
    #expect(caches.scanFile(take: "take-002", algorithm: "sensitiveScan-1")?.lastPathComponent == "take-002-sensitiveScan-1.json")
}

@Test func commitOfACancelledTaskWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try AnalysisFixture(in: dir)
        let url = try #require(fixture.caches.analysisFile(
            .loudness, take: "take-001", track: "mic-1", segment: SegmentIdentity(stem: "seg-0001", bytes: 1, modified: 2),
            algorithm: "loudness-1", extension: "json"))
        let temporary = try ProjectCaches.temporaryFile(for: url)
        try Data("x".utf8).write(to: temporary)
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try ProjectCaches.commit(temporary, to: url)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(ProjectCaches.readAnalysis(url) == nil)
    }
}

@Test func staleTemporariesAreRemovedOnceAndNamesStayShort() throws {
    try withTemporaryDirectory { dir in
        let folder = dir.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appending(path: ".a.\(UUID().uuidString).tmp.json")
        let fresh = folder.appending(path: ".b.\(UUID().uuidString).tmp.json")
        let real = folder.appending(path: "a.json")
        for file in [stale, fresh, real] { try Data("x".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: real.path)

        // The first use of the folder removes the old temporary, not a recent one nor a final file.
        _ = try ProjectCaches.temporaryFile(for: real)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: real.path))

        // A name that would not fit gets a shorter temporary, with the extension last; the final name is as it was.
        let long = String(repeating: "é", count: 200)
        let url = folder.appending(path: "\(long).json")
        let temporary = try ProjectCaches.temporaryFile(for: url)
        #expect(temporary.lastPathComponent.utf8.count <= 255)
        #expect(temporary.pathExtension == "json")
        #expect(url.lastPathComponent == "\(long).json")
        try Data("y".utf8).write(to: temporary)
        #expect(try ProjectCaches.commit(temporary, to: url.deletingLastPathComponent().appending(path: "c.json")))
    }
}

@Test func commitIsWholeOrNothing() throws {
    try withTemporaryDirectory { dir in
        let fixture = try AnalysisFixture(in: dir)
        let identity = SegmentIdentity(stem: "seg-0001", bytes: 10, modified: 20)
        let url = try #require(fixture.caches.analysisFile(
            .loudness, take: "take-001", track: "mic-1", segment: identity, algorithm: "loudness-1", extension: "json"))

        // A temporary file in the same folder, made for it, with nothing there yet and the file's extension last.
        let temporary = try ProjectCaches.temporaryFile(for: url)
        #expect(temporary.deletingLastPathComponent().path == url.deletingLastPathComponent().path)
        #expect(temporary.lastPathComponent.hasPrefix("."))
        #expect(temporary.pathExtension == "json")
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try ProjectCaches.temporaryFile(for: url) != temporary)

        // Written and committed: read whole, and the temporary is gone.
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        try data.write(to: temporary)
        #expect(ProjectCaches.readAnalysis(url) == nil)
        #expect(try ProjectCaches.commit(temporary, to: url))
        #expect(ProjectCaches.readAnalysis(url) == data)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))

        // A commit replaces the older file whole.
        let newer = try ProjectCaches.temporaryFile(for: url)
        try Data("newer".utf8).write(to: newer)
        #expect(try ProjectCaches.commit(newer, to: url))
        #expect(ProjectCaches.readAnalysis(url) == Data("newer".utf8))

        // A temporary that is not there commits nothing: the file stays as it was.
        let absent = try ProjectCaches.temporaryFile(for: url)
        #expect(try !ProjectCaches.commit(absent, to: url))
        #expect(ProjectCaches.readAnalysis(url) == Data("newer".utf8))
        let other = url.deletingLastPathComponent().appending(path: "other.json")
        #expect(try !ProjectCaches.commit(absent, to: other))
        #expect(!FileManager.default.fileExists(atPath: other.path))

        // Nor does a folder, or a symlink, where the temporary should be; neither is followed.
        let folder = try ProjectCaches.temporaryFile(for: other)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(try !ProjectCaches.commit(folder, to: other))
        #expect(!FileManager.default.fileExists(atPath: other.path))
        let link = try ProjectCaches.temporaryFile(for: other)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(try !ProjectCaches.commit(link, to: other))
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(ProjectCaches.readAnalysis(url) == Data("newer".utf8))

        // A cache file that is a symlink is not read.
        let linked = url.deletingLastPathComponent().appending(path: "linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: url)
        #expect(ProjectCaches.readAnalysis(linked) == nil)

        // With the cache folder emptied by macOS, the temporary file's folder is made again, and so is a write's.
        try FileManager.default.removeItem(at: fixture.caches.directory)
        let again = try ProjectCaches.temporaryFile(for: url)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: again.deletingLastPathComponent().path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
        try FileManager.default.removeItem(at: fixture.caches.directory)
        #expect(ProjectCaches.writeAnalysis(data, to: url))
        #expect(ProjectCaches.readAnalysis(url) == data)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == [url.lastPathComponent])
    }
}
