// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
// @testable for `LibraryThumbnails.drawn(_:document:caches:)`.
import Editing
@testable import Library

/// The library with several takes (phase 3 design §8.1): the thumbnail draws the camera of the take of its frame, the
/// camera of the card is any take's the sequence shows, and the length is the sequence's.
private enum Takes {
    static let app = AppInfo(name: "Toma", version: "0.3.0")
    static let now = Date(timeIntervalSince1970: 1_794_800_000)
    static let frame = Rect(x: 0, y: 0, width: 320, height: 180)
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func context(_ dir: URL) -> EditContext {
        EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: .toma,
            now: { now }, makeID: { $0 + "00000001" })
    }

    /// A package of two takes in `dir`: `take-001` of 2 s and `take-002` of 3 s, recorded 60 s later, each of a display
    /// at 10 fps and, for those in `cameras`, a camera. Loaded focused on the last one.
    static func twoTakes(in dir: URL, name: String, cameras: Set<String>) async throws -> LoadedProject {
        let first = try TakeBuilder(in: dir, name: name)
        try await record(into: first, start: base, seconds: 2, camera: cameras.contains("take-001"))
        _ = try first.write()
        let second = try TakeBuilder(appendingTo: first.package, take: "take-002")
        try await record(into: second, start: base.adding(seconds: 60), seconds: 3, camera: cameras.contains("take-002"))
        _ = try second.write()
        return try LoadedProject.load(first.package.url)
    }

    private static func record(into builder: TakeBuilder, start: HostTime, seconds: Double, camera: Bool) async throws {
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: start, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
        if camera {
            try await builder.addVideoTrack(
                id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
                segments: [VideoSegmentSpec(start: start, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
        }
        try builder.addEvents([
            InputEvent(t: start.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
        ])
    }

    /// `project`'s document of `pieces` (`MultiTakeFixtures.sequence(of:_:)`), saved as its `edit.json`.
    static func save(
        _ project: LoadedProject, _ pieces: [(take: String, from: Double, to: Double)], edit: (inout EditDocument) -> Void = { _ in }
    ) throws -> EditDocument {
        var document = MultiTakeFixtures.sequence(of: project, pieces)
        edit(&document)
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: project.package.editURL)
        return document
    }

    static func summary(_ url: URL, in dir: URL) -> ProjectSummary {
        ProjectReader.summary(
            of: url, place: .projectsFolder(subfolder: ""), fileSystem: SystemFileSystem(), context: context(dir), now: now)
    }

    /// The mask's cache file of the camera's segment of `take`, written.
    static func writeMask(of take: String, in project: LoadedProject, caches: ProjectCaches) throws -> CameraSegment {
        let focused = try #require(project.focused(on: take))
        let segment = try #require(focused.take.track("camera")?.segments.first)
        let identity = try #require(SegmentIdentity.of(segment, in: project.package))
        let url = try #require(CameraAnalysisCaches.maskFile(take: take, track: "camera", identity: identity, caches: caches))
        #expect(ProjectCaches.writeAnalysis(Data("mask".utf8), to: url))
        return CameraSegment(take: take, track: "camera", segment: segment.index)
    }
}

/// The thumbnail's frame (at 10 % of the output) falls in the clip of `take-002`, with the camera Blurred: that take's
/// mask is read, beside the other's, and decides whether the camera is drawn; the other take's missing mask does not.
@Test func thumbnailDrawsTheTakeOfItsFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await Takes.twoTakes(in: dir, name: "Blurred", cameras: ["take-001", "take-002"])
        let caches = ProjectCaches(root: Takes.context(dir).cachesRoot, projectID: project.manifest.resolvedProjectID)
        // 0.2 s of take-001, then 3 s of take-002: the frame at 0.32 s is take-002's.
        _ = try Takes.save(project, [("take-001", 0, 0.2), ("take-002", 0, 3)]) { $0.camera.background = .blurred }
        let (read, shown) = try EditSession.readDocument(project.package.url, take: nil, context: Takes.context(dir))
        #expect(read.take.id == "take-001")
        #expect(shown.camera.show && shown.camera.background == .blurred)

        // No mask yet: the camera is left out.
        var drawn = LibraryThumbnails.drawn(read, document: shown, caches: caches)
        #expect(!drawn.document.camera.show && drawn.analysis.personMasks.isEmpty)
        // take-002's mask: the camera is drawn with it, though take-001's is not there.
        let second = try Takes.writeMask(of: "take-002", in: project, caches: caches)
        drawn = LibraryThumbnails.drawn(read, document: shown, caches: caches)
        #expect(drawn.document == shown)
        #expect(Array(drawn.analysis.personMasks.keys) == [second])
        // Both: each under its own take.
        let first = try Takes.writeMask(of: "take-001", in: project, caches: caches)
        drawn = LibraryThumbnails.drawn(read, document: shown, caches: caches)
        #expect(Set(drawn.analysis.personMasks.keys) == [first, second])

        // The frame in take-001, whose mask is missing: left out.
        let other = try await Takes.twoTakes(in: dir, name: "Blurred first", cameras: ["take-001", "take-002"])
        let otherCaches = ProjectCaches(root: Takes.context(dir).cachesRoot, projectID: other.manifest.resolvedProjectID)
        _ = try Takes.save(other, [("take-001", 0, 2), ("take-002", 0, 3)]) { $0.camera.background = .blurred }
        _ = try Takes.writeMask(of: "take-002", in: other, caches: otherCaches)
        let (otherRead, otherShown) = try EditSession.readDocument(other.package.url, take: nil, context: Takes.context(dir))
        let hidden = LibraryThumbnails.drawn(otherRead, document: otherShown, caches: otherCaches)
        #expect(!hidden.document.camera.show && hidden.analysis.personMasks.count == 1)
    }
}

/// The card's camera is any take's the sequence shows, never one of a take it does not use, whichever the last take of
/// the manifest is.
@Test func hasCameraIsAnyTakeShown() async throws {
    try await withTemporaryDirectory { dir in
        // The camera only in take-001, and take-002, the last, unused: a camera.
        let onlyFirst = try await Takes.twoTakes(in: dir, name: "First", cameras: ["take-001"])
        _ = try Takes.save(onlyFirst, [("take-001", 0, 2)])
        #expect(Takes.summary(onlyFirst.package.url, in: dir).hasCamera)
        // The other way around, take-002 unused: none.
        let onlySecond = try await Takes.twoTakes(in: dir, name: "Second", cameras: ["take-002"])
        _ = try Takes.save(onlySecond, [("take-001", 0, 2)])
        #expect(!Takes.summary(onlySecond.package.url, in: dir).hasCamera)
        // Both shown, the camera in the second: a camera, though the first clip's take has none.
        _ = try Takes.save(onlySecond, [("take-001", 0, 2), ("take-002", 0, 3)])
        #expect(Takes.summary(onlySecond.package.url, in: dir).hasCamera)
    }
}

/// The length on the card is the sequence's, over both takes.
@Test func durationIsTheSequences() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await Takes.twoTakes(in: dir, name: "Both", cameras: [])
        _ = try Takes.save(project, [("take-001", 0, 2), ("take-002", 0, 3)])
        let summary = Takes.summary(project.package.url, in: dir)
        #expect(summary.state == .normal)
        #expect(summary.outputSeconds == 5)
    }
}
