// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ImageAnalysis
import ProjectFormat

/// The analysis jobs of the camera (phase 2 design §6.1, §6.2 and §10): the person's mask (`personMask-1`) and the face
/// (`faceTrack-1`) of each segment of the camera the document draws, their cache files, and what the render reads of them
/// (`AnalysisInputs.personMasks`, `.faceTracks`).
///
/// - **Which segments.** Those of the camera track `CameraBubble` draws (the take's first camera track with a segment,
///   none while the document hides the camera), each `SegmentAvailability.present` and with a `SegmentIdentity` (not a
///   link), which names its cache: `masks/<take>/<track>/<segment>-personMask-1.mov` and
///   `faces/<take>/<track>/<segment>-faceTrack-1.json` (`ProjectCaches.analysisFile`). Masks while `camera.background` is
///   not `original`, faces while `camera.framing.mode` is `face`.
/// - **Once.** A job whose cache file is there returns it without reading a frame; otherwise it writes the file whole
///   (a temporary of the caches and `ProjectCaches.commit`, or `writeAnalysis`) and returns it. Cancelled, it leaves
///   nothing.
/// - **What it says.** Vision that cannot do it on this Mac, `JobError(.notOnThisMac, unavailable: true)`; a segment that
///   is not there or cannot be decoded, `.sourceUnreadable(file:)` with its path in the package; a full drive, `.noSpace`;
///   anything else, `.failed` with why.
/// - **By take** (phase 3 design §8.1 and §9). Each take the sequence shows has the jobs of its own camera, take by take in
///   the order the sequence first shows them (`SequenceAnalyses.takes(shownBy:in:)`): `neededJobs(document:takes:package:)`,
///   `fill(_:document:takes:package:caches:)` and `prepareForExport`. With one take, what it is for that take alone.
public enum CameraAnalysis {
    /// The jobs `document` needs for `take` (in `package`): the faces of each segment first (they are quick, and Follow
    /// the Face waits for them), then the masks, each in the segments' order. Reads each segment's `lstat`, never a file.
    public static func neededJobs(document: EditDocument, take: TakeRecord, package: ProjectPackage) -> [AnalysisJobKind] {
        guard let track = CameraAnalysisCaches.cameraTrack(document: document, take: take) else { return [] }
        let segments = CameraAnalysisCaches.analysable(track, in: package).map(\.index)
        var kinds: [AnalysisJobKind] = []
        if document.camera.framing.mode == .face {
            kinds += segments.map { .faceTrack(take: take.id, track: track.id, segment: $0) }
        }
        if document.camera.background != .original {
            kinds += segments.map { .personMask(take: take.id, track: track.id, segment: $0) }
        }
        return kinds
    }

    /// The jobs `document` needs for each of `takes` (in `package`), take by take in their order: `neededJobs(document:
    /// take:package:)` of each.
    public static func neededJobs(document: EditDocument, takes: [TakeRecord], package: ProjectPackage) -> [AnalysisJobKind] {
        takes.flatMap { neededJobs(document: document, take: $0, package: package) }
    }

    /// The work of `kind` for `project`'s take, with `caches`: `nil` unless `kind` is a mask or a face of a segment of a
    /// camera track of that take (the project focused on another take, `LoadedProject.focused(on:)`, works that one's).
    /// `segmenter` and `detector` are Vision's unless a test hands in others.
    public static func work(
        for kind: AnalysisJobKind, project: LoadedProject, caches: ProjectCaches,
        segmenter: any PersonSegmenter = VisionPersonSegmenter(), detector: any FaceDetector = VisionFaceDetector()
    ) -> JobWork? {
        switch kind {
        case let .personMask(take, track, index):
            guard let segment = segment(index, of: track, take: take, in: project) else { return nil }
            return maskWork(segment: segment, take: take, track: track, package: project.package, caches: caches, segmenter: segmenter)
        case let .faceTrack(take, track, index):
            guard let segment = segment(index, of: track, take: take, in: project) else { return nil }
            return faceWork(segment: segment, take: take, track: track, package: project.package, caches: caches, detector: detector)
        case .transcription, .soundIsolation, .loudness, .sensitiveScan:
            return nil
        }
    }

    /// `inputs` with its masks and faces replaced by what the caches hold whole for what `document` asks of `take`
    /// (`CameraAnalysisCaches.fill`, which the library's thumbnails read with too). Reads the disk: never on the main
    /// thread.
    public static func fill(
        _ inputs: inout AnalysisInputs, document: EditDocument, take: TakeRecord, package: ProjectPackage, caches: ProjectCaches
    ) {
        CameraAnalysisCaches.fill(&inputs, document: document, take: take, package: package, caches: caches)
    }

    /// `inputs` with its masks and faces replaced by what the caches hold whole for what `document` asks of each of
    /// `takes`: `CameraAnalysisCaches.fill(_:document:takes:package:caches:)`, each take's under its own, none of them
    /// emptying another's (a take listed twice, once). Reads the disk: never on the main thread.
    public static func fill(
        _ inputs: inout AnalysisInputs, document: EditDocument, takes: [TakeRecord], package: ProjectPackage,
        caches: ProjectCaches
    ) {
        CameraAnalysisCaches.fill(&inputs, document: document, takes: takes, package: package, caches: caches)
    }

    /// What an export does before it starts: every job `document` needs of each take its sequence shows (`neededJobs`,
    /// take by take, `project` focused on each), asked of `jobs` first in its queue (`ProjectJobs.result(of:work:)`, one
    /// after another), then `fill` of them all. It returns only once each job has ended.
    /// A job Vision cannot do on this Mac (`unavailable`) or whose segment cannot be read (`.sourceUnreadable`) is left
    /// out, as the preview leaves it out: that segment draws its camera Original, or centred. Any other failure is thrown
    /// (`JobError`), as is `CancellationError`.
    public static func prepareForExport(
        _ inputs: inout AnalysisInputs, document: EditDocument, project: LoadedProject, caches: ProjectCaches,
        jobs: ProjectJobs, segmenter: any PersonSegmenter = VisionPersonSegmenter(),
        detector: any FaceDetector = VisionFaceDetector()
    ) async throws {
        let shown = project.takesShown(by: document)
        for project in shown {
            for kind in neededJobs(document: document, take: project.take, package: project.package) {
                guard let work = work(for: kind, project: project, caches: caches, segmenter: segmenter, detector: detector)
                else { continue }
                do {
                    _ = try await jobs.result(of: kind, work: work)
                } catch let error as JobError where error.unavailable {
                    continue
                } catch let error as JobError {
                    guard case .sourceUnreadable = error.problem else { throw error }
                }
            }
        }
        try Task.checkCancellation()
        fill(&inputs, document: document, takes: shown.map(\.take), package: project.package, caches: caches)
    }

    /// How far the camera's jobs `kinds` of `take` are, 0 to 1, each weighed by the length of its segment (equally, when
    /// none has a length): one done, failed or unavailable counts whole, one running by its progress, one waiting or
    /// never asked for as nothing. `nil` when there is no job.
    public static func progress(_ states: [AnalysisJobKind: JobState], of kinds: [AnalysisJobKind], take: TakeRecord) -> Double? {
        progress(states, of: kinds, takes: [take])
    }

    /// `progress(_:of:take:)` of jobs of any of `takes`, each weighed by the length of its segment in its own take (none
    /// for a job of another take).
    public static func progress(
        _ states: [AnalysisJobKind: JobState], of kinds: [AnalysisJobKind], takes: [TakeRecord]
    ) -> Double? {
        guard !kinds.isEmpty else { return nil }
        let weights = kinds.map { kind in takes.reduce(0) { $0 + segmentSeconds(of: kind, take: $1) } }
        let total = weights.reduce(0, +)
        var done = 0.0
        for (kind, weight) in zip(kinds, weights) {
            let fraction: Double
            switch states[kind] {
            case .done?, .failed?, .unavailable?: fraction = 1
            case .running(let progress)?: fraction = min(max(progress, 0), 1)
            case .waiting?, nil: fraction = 0
            }
            done += (total > 0 ? weight : 1) * fraction
        }
        return done / (total > 0 ? total : Double(kinds.count))
    }

    // MARK: - The works

    private static func maskWork(
        segment: SegmentRecord, take: String, track: String, package: ProjectPackage, caches: ProjectCaches,
        segmenter: any PersonSegmenter
    ) -> JobWork {
        { progress in
            guard let identity = SegmentIdentity.of(segment, in: package) else {
                throw JobError(.sourceUnreadable(file: segment.file))
            }
            guard let url = CameraAnalysisCaches.maskFile(take: take, track: track, identity: identity, caches: caches) else {
                throw JobError(.failed("The camera segment's names cannot name a cache file"))
            }
            if CameraAnalysisCaches.isWholeFile(url) {
                progress.report(1)
                return .cached(url)
            }
            guard await offThePool({ segmenter.isAvailable }) else { throw JobError(.notOnThisMac, unavailable: true) }
            guard SegmentAvailability.classify(segment, in: package) == .present else {
                throw JobError(.sourceUnreadable(file: segment.file))
            }
            let temporary: URL
            do {
                temporary = try ProjectCaches.temporaryFile(for: url)
            } catch {
                throw jobError(error, file: segment.file)
            }
            do {
                try await PersonMaskEngine.write(
                    segment: package.fileURL(segment.file), to: temporary, segmenter: segmenter,
                    progress: { progress.report($0) })
                guard try ProjectCaches.commit(temporary, to: url) else {
                    throw JobError(.failed("The mask could not be put in the caches"))
                }
            } catch {
                unlink(temporary.path)
                throw jobError(error, file: segment.file)
            }
            return .cached(url)
        }
    }

    private static func faceWork(
        segment: SegmentRecord, take: String, track: String, package: ProjectPackage, caches: ProjectCaches,
        detector: any FaceDetector
    ) -> JobWork {
        { progress in
            guard let identity = SegmentIdentity.of(segment, in: package) else {
                throw JobError(.sourceUnreadable(file: segment.file))
            }
            guard let url = CameraAnalysisCaches.faceFile(take: take, track: track, identity: identity, caches: caches) else {
                throw JobError(.failed("The camera segment's names cannot name a cache file"))
            }
            if CameraAnalysisCaches.readFaceTrack(url) != nil {
                progress.report(1)
                return .cached(url)
            }
            guard await offThePool({ detector.isAvailable }) else { throw JobError(.notOnThisMac, unavailable: true) }
            guard SegmentAvailability.classify(segment, in: package) == .present else {
                throw JobError(.sourceUnreadable(file: segment.file))
            }
            let face: CameraFaceTrack
            do {
                face = try await FaceTrackEngine.track(
                    segment: package.fileURL(segment.file), start: segment.startHostTime, detector: detector,
                    progress: { progress.report($0) })
            } catch {
                throw jobError(error, file: segment.file)
            }
            try Task.checkCancellation()
            guard ProjectCaches.writeAnalysis(try ProjectJSON.encoder().encode(face), to: url) else {
                try Task.checkCancellation()
                throw JobError(.failed("The face track could not be written to the caches"))
            }
            return .cached(url)
        }
    }

    // MARK: - Private

    /// Segment `index` of camera track `track` of `project`'s take, if `take` is it.
    private static func segment(_ index: Int, of track: String, take: String, in project: LoadedProject) -> SegmentRecord? {
        guard take == project.take.id, let record = project.take.track(track), record.kind == .camera else { return nil }
        return record.segments.first { $0.index == index }
    }

    /// The length of the segment of a camera job, in seconds; 0 for an open segment, one not in `take` and any other job.
    private static func segmentSeconds(of kind: AnalysisJobKind, take: TakeRecord) -> Double {
        let (trackID, index): (String, Int)
        switch kind {
        case let .personMask(id, track, segment), let .faceTrack(id, track, segment):
            guard id == take.id else { return 0 }
            (trackID, index) = (track, segment)
        case .transcription, .soundIsolation, .loudness, .sensitiveScan:
            return 0
        }
        guard let segment = take.track(trackID)?.segments.first(where: { $0.index == index }),
              let end = segment.endHostTime, end > segment.startHostTime
        else { return 0 }
        return end.seconds(since: segment.startHostTime)
    }

    /// What a camera job throws for `error`, made reading or writing the segment of `file`.
    private static func jobError(_ error: any Error, file: String) -> any Error {
        switch error {
        case is CancellationError, is JobError:
            return error
        case ImageAnalysisError.unreadable:
            return JobError(.sourceUnreadable(file: file))
        case ImageAnalysisError.diskFull:
            return JobError(.noSpace)
        case ImageAnalysisError.visionFailed(let why), ImageAnalysisError.writerFailed(let why):
            return JobError(.failed(why))
        default:
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) || error.code == Int(EDQUOT) {
                return JobError(.noSpace)
            }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return JobError(.noSpace) }
            return JobError(.failed(String(describing: error)))
        }
    }

    /// `body`'s value, made on a utility queue, off Swift's cooperative pool.
    private static func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: body()) }
        }
    }
}
