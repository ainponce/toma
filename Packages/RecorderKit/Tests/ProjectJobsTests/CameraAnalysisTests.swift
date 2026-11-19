// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Darwin
import Editing
import Foundation
import ImageAnalysis
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable only for `ProjectJobs.isRunning`, which tells when a cancelled work has returned.
@testable import ProjectJobs

// Every test here runs in `make tsan`.

private let patience = Duration.seconds(60)
private let projectID = String(repeating: "cd", count: 16)
private let base = HostTime(nanoseconds: 9_000_000_000_000)

@Suite struct CameraAnalysisTests {
    @Test func neededJobsFollowTheDocument() throws {
        try withTemporaryDirectory { dir in
            let fixture = try HandmadeTake(in: dir)
            var document = EditDocument.legacy(take: fixture.take, events: [])
            func needed() -> [AnalysisJobKind] {
                CameraAnalysis.neededJobs(document: document, take: fixture.take, package: fixture.package)
            }
            // Original and centred: nothing.
            #expect(needed() == [])

            // Segments 3 (empty), 4 (unreadable) and 5 (missing) are never asked for.
            document.camera.background = .blurred
            #expect(needed() == [mask(1), mask(2)])
            document.camera.background = .removed
            #expect(needed() == [mask(1), mask(2)])

            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
            #expect(needed() == [face(1), face(2), mask(1), mask(2)])
            document.camera.background = .original
            #expect(needed() == [face(1), face(2)])
            document.camera.framing.mode = .manual
            #expect(needed() == [])

            // A hidden camera, or a take without one, needs nothing.
            document.camera.background = .blurred
            document.camera.framing.mode = .face
            document.camera.show = false
            #expect(needed() == [])
            document.camera.show = true
            var withoutCamera = fixture.take
            withoutCamera.tracks = []
            #expect(CameraAnalysis.neededJobs(document: document, take: withoutCamera, package: fixture.package) == [])
        }
    }

    @Test func fillReadsOnlyWholeCaches() throws {
        try withTemporaryDirectory { dir in
            let fixture = try HandmadeTake(in: dir)
            var document = EditDocument.legacy(take: fixture.take, events: [])
            document.camera.background = .blurred
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)

            // Segment 1: a mask still in its temporary, and a face track that does not decode.
            let temporary = try ProjectCaches.temporaryFile(for: try fixture.cacheFile(.masks, segment: 1))
            try Data("part of a movie".utf8).write(to: temporary)
            #expect(ProjectCaches.writeAnalysis(Data("{\"algorithm\":".utf8), to: try fixture.cacheFile(.faces, segment: 1)))
            // Segment 2: both whole.
            let mask2 = try fixture.cacheFile(.masks, segment: 2)
            #expect(ProjectCaches.writeAnalysis(Data("a movie".utf8), to: mask2))
            let face2 = CameraFaceTrack(
                algorithm: "faceTrack-1", frameSize: [640, 360],
                samples: [CameraFaceSample(t: base, face: NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3))])
            #expect(ProjectCaches.writeAnalysis(try ProjectJSON.encoder().encode(face2), to: try fixture.cacheFile(.faces, segment: 2)))

            var inputs = AnalysisInputs()
            inputs.cleanVoice = ["take-001/mic": CleanVoice(files: ["seg-0001": dir.appending(path: "clean.caf")])]
            let before = inputs.cleanVoice
            CameraAnalysis.fill(&inputs, document: document, take: fixture.take, package: fixture.package, caches: fixture.caches)
            #expect(inputs.personMasks == [segment(2): mask2])
            #expect(inputs.faceTracks == [segment(2): face2])
            #expect(inputs.cleanVoice == before)

            // Only what the document asks for.
            document.camera.background = .original
            document.camera.framing.mode = .center
            CameraAnalysis.fill(&inputs, document: document, take: fixture.take, package: fixture.package, caches: fixture.caches)
            #expect(inputs.personMasks.isEmpty)
            #expect(inputs.faceTracks.isEmpty)
        }
    }

    @Test func progressWeighsSegments() {
        let take = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "camera", kind: .camera, source: TrackSource(name: "Camera"),
                    segments: [record(1, seconds: 1), record(2, from: 1, seconds: 3), record(3, from: 4, seconds: nil)])
            ])
        let kinds = [mask(1), mask(2)]
        #expect(CameraAnalysis.progress([mask(1): .done, mask(2): .running(progress: 0.5)], of: kinds, take: take) == 0.625)
        #expect(CameraAnalysis.progress([:], of: kinds, take: take) == 0)
        #expect(CameraAnalysis.progress([mask(1): .failed(.noSpace), mask(2): .done], of: kinds, take: take) == 1)
        #expect(CameraAnalysis.progress([:], of: [], take: take) == nil)
        // An open segment has no length: alone, the jobs weigh the same.
        #expect(CameraAnalysis.progress([mask(3): .running(progress: 0.25), face(3): .done], of: [mask(3), face(3)], take: take) == 0.625)
    }

    @Test func cachedWorkDoesNotRunAgain() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir)
            let segmenter = LeftHalf()
            let detector = OneFace()
            let jobs = ProjectJobs()
            var made: [AnalysisJobKind: URL] = [:]
            for kind in [mask(1), face(1)] {
                let work = try unwrap(
                    CameraAnalysis.work(
                        for: kind, project: fixture.project, caches: fixture.caches, segmenter: segmenter, detector: detector),
                    "the work of \(kind)")
                let first = try await jobs.result(of: kind, work: work)
                let second = try await jobs.result(of: kind, work: work)
                #expect(first == second)
                guard case .cached(let url) = first else {
                    Issue.record("\(kind) made \(first)")
                    continue
                }
                #expect(FileManager.default.fileExists(atPath: url.path))
                made[kind] = url
            }
            #expect(segmenter.calls.count == 30)
            #expect(detector.calls.count == 10)

            let identity = try unwrap(SegmentIdentity.of(fixture.segment(1), in: fixture.project.package), "segment 1")
            #expect(made[mask(1)] == fixture.caches.folder(.masks).appending(path: "take-001/camera/\(identity.name)-personMask-1.mov"))
            #expect(made[face(1)] == fixture.caches.folder(.faces).appending(path: "take-001/camera/\(identity.name)-faceTrack-1.json"))
        }
    }

    @Test func workSaysWhyItMadeNothing() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir, withAThirdThatIsNotAMovie: true)
            let jobs = ProjectJobs()

            let unavailable = try unwrap(
                CameraAnalysis.work(
                    for: mask(1), project: fixture.project, caches: fixture.caches, segmenter: LeftHalf(available: false)),
                "the mask's work")
            await #expect(throws: JobError(.notOnThisMac, unavailable: true)) {
                try await jobs.result(of: mask(1), work: unavailable)
            }
            #expect(await jobs.state(of: mask(1)) == .unavailable(.notOnThisMac))
            let noDetector = try unwrap(
                CameraAnalysis.work(
                    for: face(1), project: fixture.project, caches: fixture.caches, detector: OneFace(available: false)),
                "the face's work")
            await #expect(throws: JobError(.notOnThisMac, unavailable: true)) {
                try await jobs.result(of: face(1), work: noDetector)
            }

            for kind in [mask(3), face(3)] {
                let work = try unwrap(
                    CameraAnalysis.work(
                        for: kind, project: fixture.project, caches: fixture.caches, segmenter: LeftHalf(), detector: OneFace()),
                    "the work of \(kind)")
                await #expect(throws: JobError(.sourceUnreadable(file: "takes/take-001/camera/seg-0003.mov"))) {
                    try await jobs.result(of: kind, work: work)
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.caches.folder(.masks).appending(path: "take-001/camera").path) == [])

            // Not the camera's, or not one of its segments.
            #expect(CameraAnalysis.work(for: .transcription(take: "take-001", track: "camera"), project: fixture.project, caches: fixture.caches) == nil)
            #expect(CameraAnalysis.work(for: mask(9), project: fixture.project, caches: fixture.caches) == nil)
            #expect(CameraAnalysis.work(for: .personMask(take: "take-002", track: "camera", segment: 1), project: fixture.project, caches: fixture.caches) == nil)
        }
    }

    @Test func exportWaitsForEveryNeededJob() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir)
            var document = EditDocument.legacy(take: fixture.project.take, events: [])
            document.camera.background = .blurred
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
            let segmenter = LeftHalf()
            let detector = OneFace()
            let jobs = ProjectJobs()
            // The face of segment 1 is done already: two masks and a face are left.
            let earlier = try unwrap(
                CameraAnalysis.work(for: face(1), project: fixture.project, caches: fixture.caches, detector: detector), "a work")
            _ = try await jobs.result(of: face(1), work: earlier)
            #expect(detector.calls.count == 10)

            var inputs = AnalysisInputs()
            try await CameraAnalysis.prepareForExport(
                &inputs, document: document, project: fixture.project, caches: fixture.caches, jobs: jobs,
                segmenter: segmenter, detector: detector)

            #expect(Set(inputs.personMasks.keys) == [segment(1), segment(2)])
            #expect(inputs.personMasks.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            #expect(Set(inputs.faceTracks.keys) == [segment(1), segment(2)])
            #expect(inputs.faceTracks.values.allSatisfy { $0.samples.count == 10 })
            #expect(segmenter.calls.count == 60)
            #expect(detector.calls.count == 20)
            for kind in [mask(1), mask(2), face(1), face(2)] { #expect(await jobs.state(of: kind) == .done) }

            // What it filled is what `fill` reads.
            var filled = AnalysisInputs()
            CameraAnalysis.fill(
                &filled, document: document, take: fixture.project.take, package: fixture.project.package, caches: fixture.caches)
            #expect(filled == inputs)
        }
    }

    @Test func exportGoesOnWithoutWhatThisMacCannotMake() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir, withAThirdThatIsNotAMovie: true)
            var document = EditDocument.legacy(take: fixture.project.take, events: [])
            document.camera.background = .removed
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
            let jobs = ProjectJobs()

            var inputs = AnalysisInputs()
            try await CameraAnalysis.prepareForExport(
                &inputs, document: document, project: fixture.project, caches: fixture.caches, jobs: jobs,
                segmenter: LeftHalf(available: false), detector: OneFace())
            // Without Vision's masks, and without the segment that cannot be read: the faces of the two others.
            #expect(inputs.personMasks.isEmpty)
            #expect(Set(inputs.faceTracks.keys) == [segment(1), segment(2)])
        }
    }

    @Test func exportStopsAtAFailure() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir)
            var document = EditDocument.legacy(take: fixture.project.take, events: [])
            document.camera.background = .blurred
            var inputs = AnalysisInputs()
            await #expect(throws: JobError.self) {
                try await CameraAnalysis.prepareForExport(
                    &inputs, document: document, project: fixture.project, caches: fixture.caches, jobs: ProjectJobs(),
                    segmenter: LeftHalf(failing: true))
            }
            #expect(inputs.personMasks.isEmpty)
        }
    }

    @Test func aCancelledMaskJobLeavesNothingInTheCaches() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir)
            let reached = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let segmenter = LeftHalf { call in
                guard call == 5 else { return }
                reached.signal()
                release.wait()
            }
            let jobs = ProjectJobs()
            let work = try unwrap(
                CameraAnalysis.work(for: mask(1), project: fixture.project, caches: fixture.caches, segmenter: segmenter),
                "the mask's work")
            await jobs.enqueue(mask(1), work: work)
            let arrived = try await offThePool { reached.wait(timeout: .now() + 120) == .success }
            try #require(arrived)
            await jobs.cancel(mask(1))
            release.signal()
            #expect(await eventually(timeout: patience) { await !jobs.isRunning })

            #expect(segmenter.calls.count <= 6)
            #expect(await jobs.state(of: mask(1)) == nil)
            let folder = fixture.caches.folder(.masks).appending(path: "take-001/camera")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
            var inputs = AnalysisInputs()
            var document = EditDocument.legacy(take: fixture.project.take, events: [])
            document.camera.background = .blurred
            CameraAnalysis.fill(
                &inputs, document: document, take: fixture.project.take, package: fixture.project.package, caches: fixture.caches)
            #expect(inputs.personMasks.isEmpty)
        }
    }

    @Test func cachesNeverWriteInThePackage() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await RecordedTake(in: dir)
            var document = EditDocument.legacy(take: fixture.project.take, events: [])
            document.camera.background = .blurred
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
            let before = try treeHash(fixture.project.package.url)
            var inputs = AnalysisInputs()
            try await CameraAnalysis.prepareForExport(
                &inputs, document: document, project: fixture.project, caches: fixture.caches, jobs: ProjectJobs(),
                segmenter: LeftHalf(), detector: OneFace())
            #expect(inputs.personMasks.count == 2)
            #expect(try treeHash(fixture.project.package.url) == before)
        }
    }
}

// MARK: - Fixtures

private func mask(_ segment: Int) -> AnalysisJobKind { .personMask(take: "take-001", track: "camera", segment: segment) }
private func face(_ segment: Int) -> AnalysisJobKind { .faceTrack(take: "take-001", track: "camera", segment: segment) }
private func segment(_ index: Int) -> CameraSegment { CameraSegment(take: "take-001", track: "camera", segment: index) }

/// Segment `index` of the camera, from `from` seconds after `base`, `seconds` long (open when `nil`).
private func record(
    _ index: Int, from: Double = 0, seconds: Double?, endReason: SegmentEndReason? = .stopped
) -> SegmentRecord {
    let start = base.adding(seconds: from)
    return SegmentRecord(
        index: index, file: "takes/take-001/camera/seg-000\(index).mov", startHostTime: start,
        endHostTime: seconds.map { start.adding(seconds: $0) }, endReason: seconds == nil ? nil : endReason,
        droppedFrames: 0, heartbeatFrames: 0)
}

/// A take whose camera's segments are files of bytes, not movies: what the jobs need is decided by names and `lstat`.
/// Segments 1 and 2 have bytes, 3 has none (`empty`), 4 is marked unreadable and 5 has no file.
private struct HandmadeTake {
    let package: ProjectPackage
    let caches: ProjectCaches
    let take: TakeRecord

    init(in dir: URL) throws {
        package = ProjectPackage(url: dir.appending(path: "Demo.toma", directoryHint: .isDirectory))
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: projectID)
        let segments = [
            record(1, seconds: 1), record(2, from: 1, seconds: 1), record(3, from: 2, seconds: 1, endReason: .empty),
            record(4, from: 3, seconds: 1, endReason: .unreadable(bytes: 4096)), record(5, from: 4, seconds: 1),
        ]
        let folder = package.fileURL("takes/take-001/camera")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: package.fileURL(segments[0].file))
        try Data(repeating: 2, count: 2000).write(to: package.fileURL(segments[1].file))
        try Data().write(to: package.fileURL(segments[2].file))
        try Data(repeating: 0x5A, count: 4096).write(to: package.fileURL(segments[3].file))
        take = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [TrackRecord(id: "camera", kind: .camera, source: TrackSource(name: "Camera"), segments: segments)])
    }

    /// The cache file of `folder` for camera segment `index`.
    func cacheFile(_ folder: AnalysisCacheFolder, segment index: Int) throws -> URL {
        let record = try unwrap(take.tracks[0].segments.first { $0.index == index }, "segment \(index)")
        let identity = try unwrap(SegmentIdentity.of(record, in: package), "the identity of segment \(index)")
        let (algorithm, ext) = folder == .masks ? ("personMask-1", "mov") : ("faceTrack-1", "json")
        return try unwrap(
            caches.analysisFile(folder, take: "take-001", track: "camera", segment: identity, algorithm: algorithm, extension: ext),
            "the cache file")
    }
}

/// A take recorded with a camera of two segments of 1 s at 30 fps (`TakeBuilder`), and optionally a third whose file
/// is not a movie; its caches next to it.
private struct RecordedTake {
    let project: LoadedProject
    let caches: ProjectCaches

    init(in dir: URL, withAThirdThatIsNotAMovie third: Bool = false) async throws {
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Camera"),
            segments: [
                VideoSegmentSpec(start: base, seconds: 1, width: 320, height: 180),
                VideoSegmentSpec(start: base.adding(seconds: 2), seconds: 1, width: 320, height: 180),
            ])
        if third {
            try builder.addEmptySegment(
                track: "camera", index: 3, start: base.adding(seconds: 4), end: base.adding(seconds: 5), endReason: .stopped,
                file: .garbage())
        }
        project = try builder.write()
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: projectID)
    }

    func segment(_ index: Int) throws -> SegmentRecord {
        try unwrap(project.take.track("camera")?.segments.first { $0.index == index }, "segment \(index)")
    }
}

/// How many times something was called.
private final class Calls: Sendable {
    private let value = Mutex(0)

    /// One more; its number, from 1.
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
}

/// A segmenter that finds the person in the left half: 64 × 36, 255 on the left. `onCall` is told each call's number,
/// from 1.
private struct LeftHalf: PersonSegmenter {
    let calls = Calls()
    var available = true
    var failing = false
    var onCall: (@Sendable (Int) -> Void)?

    init(available: Bool = true, failing: Bool = false, onCall: (@Sendable (Int) -> Void)? = nil) {
        self.available = available
        self.failing = failing
        self.onCall = onCall
    }

    var isAvailable: Bool { available }

    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let call = calls.next()
        onCall?(call)
        if failing { throw ImageAnalysisError.visionFailed("no mask") }
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_OneComponent8, nil, &made) == kCVReturnSuccess,
              let buffer = made
        else { throw TestSupportError.failed("no mask buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<36 {
            for x in 0..<64 { base[y * row + x] = x < 32 ? 255 : 0 }
        }
        return buffer
    }
}

/// A detector that finds one face in the middle of every frame.
private struct OneFace: FaceDetector {
    let calls = Calls()
    var available = true

    init(available: Bool = true) {
        self.available = available
    }

    var isAvailable: Bool { available }

    func faces(in frame: CVPixelBuffer) throws -> [NormalizedRect] {
        _ = calls.next()
        return [NormalizedRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5)]
    }
}
