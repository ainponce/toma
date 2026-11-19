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
public enum CameraAnalysis {
    /// The jobs `document` needs for `take` (in `package`): the faces of each segment first (they are quick, and Follow
    /// the Face waits for them), then the masks, each in the segments' order. Reads each segment's `lstat`, never a file.
    public static func neededJobs(document: EditDocument, take: TakeRecord, package: ProjectPackage) -> [AnalysisJobKind] {
        guard let track = cameraTrack(document: document, take: take) else { return [] }
        let segments = analysable(track, in: package).map(\.index)
        var kinds: [AnalysisJobKind] = []
        if document.camera.framing.mode == .face {
            kinds += segments.map { .faceTrack(take: take.id, track: track.id, segment: $0) }
        }
        if document.camera.background != .original {
            kinds += segments.map { .personMask(take: take.id, track: track.id, segment: $0) }
        }
        return kinds
    }

    /// The work of `kind` for `project`'s take, with `caches`: `nil` unless `kind` is a mask or a face of a segment of a
    /// camera track of that take. `segmenter` and `detector` are Vision's unless a test hands in others.
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

    /// `inputs` with its masks and faces replaced by what the caches hold whole for what `document` asks of `take`: the
    /// committed mask movie of each segment (a regular file of some bytes at its name) while the background is not
    /// `original`, and the face track that decodes as `faceTrack-1` while the framing follows the face; nothing else.
    /// A temporary not committed is never at the name, and a JSON that does not decode is not there. Reads the disk:
    /// never on the main thread.
    public static func fill(
        _ inputs: inout AnalysisInputs, document: EditDocument, take: TakeRecord, package: ProjectPackage, caches: ProjectCaches
    ) {
        var masks: [CameraSegment: URL] = [:]
        var faces: [CameraSegment: CameraFaceTrack] = [:]
        if let track = cameraTrack(document: document, take: take) {
            for segment in analysable(track, in: package) {
                guard let identity = SegmentIdentity.of(segment, in: package) else { continue }
                let key = CameraSegment(take: take.id, track: track.id, segment: segment.index)
                if document.camera.background != .original,
                   let url = maskFile(take: take.id, track: track.id, identity: identity, caches: caches), isWholeFile(url) {
                    masks[key] = url
                }
                if document.camera.framing.mode == .face,
                   let url = faceFile(take: take.id, track: track.id, identity: identity, caches: caches),
                   let face = readFaceTrack(url) {
                    faces[key] = face
                }
            }
        }
        inputs.personMasks = masks
        inputs.faceTracks = faces
    }

    /// What an export does before it starts: every job `document` needs (`neededJobs`), asked of `jobs` first in its
    /// queue (`ProjectJobs.result(of:work:)`, one after another), then `fill`. It returns only once each job has ended.
    /// A job Vision cannot do on this Mac (`unavailable`) or whose segment cannot be read (`.sourceUnreadable`) is left
    /// out, as the preview leaves it out: that segment draws its camera Original, or centred. Any other failure is thrown
    /// (`JobError`), as is `CancellationError`.
    public static func prepareForExport(
        _ inputs: inout AnalysisInputs, document: EditDocument, project: LoadedProject, caches: ProjectCaches,
        jobs: ProjectJobs, segmenter: any PersonSegmenter = VisionPersonSegmenter(),
        detector: any FaceDetector = VisionFaceDetector()
    ) async throws {
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
        try Task.checkCancellation()
        fill(&inputs, document: document, take: project.take, package: project.package, caches: caches)
    }

    /// How far the camera's jobs `kinds` of `take` are, 0 to 1, each weighed by the length of its segment (equally, when
    /// none has a length): one done, failed or unavailable counts whole, one running by its progress, one waiting or
    /// never asked for as nothing. `nil` when there is no job.
    public static func progress(_ states: [AnalysisJobKind: JobState], of kinds: [AnalysisJobKind], take: TakeRecord) -> Double? {
        guard !kinds.isEmpty else { return nil }
        let weights = kinds.map { segmentSeconds(of: $0, take: take) }
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
            guard let url = maskFile(take: take, track: track, identity: identity, caches: caches) else {
                throw JobError(.failed("The camera segment's names cannot name a cache file"))
            }
            if isWholeFile(url) {
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
            guard let url = faceFile(take: take, track: track, identity: identity, caches: caches) else {
                throw JobError(.failed("The camera segment's names cannot name a cache file"))
            }
            if readFaceTrack(url) != nil {
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

    /// The camera track `CameraBubble` draws: the take's first camera track with a segment, unless the document hides
    /// the camera.
    private static func cameraTrack(document: EditDocument, take: TakeRecord) -> TrackRecord? {
        guard document.camera.show else { return nil }
        return take.tracks.first { $0.kind == .camera && !$0.segments.isEmpty }
    }

    /// The segments of `track` that can be analysed, in the order of their index: present, and not a link.
    private static func analysable(_ track: TrackRecord, in package: ProjectPackage) -> [SegmentRecord] {
        track.segments.sorted { $0.index < $1.index }.filter { segment in
            SegmentAvailability.classify(segment, in: package) == .present && SegmentIdentity.of(segment, in: package) != nil
        }
    }

    /// Segment `index` of camera track `track` of `project`'s take, if `take` is it.
    private static func segment(_ index: Int, of track: String, take: String, in project: LoadedProject) -> SegmentRecord? {
        guard take == project.take.id, let record = project.take.track(track), record.kind == .camera else { return nil }
        return record.segments.first { $0.index == index }
    }

    private static func maskFile(take: String, track: String, identity: SegmentIdentity, caches: ProjectCaches) -> URL? {
        caches.analysisFile(.masks, take: take, track: track, segment: identity, algorithm: PersonMaskEngine.algorithm, extension: "mov")
    }

    private static func faceFile(take: String, track: String, identity: SegmentIdentity, caches: ProjectCaches) -> URL? {
        caches.analysisFile(.faces, take: take, track: track, segment: identity, algorithm: FaceTrackEngine.algorithm, extension: "json")
    }

    /// Whether a regular file of some bytes is at `url`, by `lstat` (a link is not followed).
    private static func isWholeFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0
    }

    /// The face track at `url`, if it is there and decodes as `faceTrack-1`.
    private static func readFaceTrack(_ url: URL) -> CameraFaceTrack? {
        guard let data = ProjectCaches.readAnalysis(url),
              let face = try? ProjectJSON.decoder().decode(CameraFaceTrack.self, from: data),
              face.algorithm == FaceTrackEngine.algorithm
        else { return nil }
        return face
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
