// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Export
import Foundation
import ImageAnalysis
import ProjectFormat

/// What an export has of sound (fases 4 y 5 design §6.2): a video has it, a GIF has none, and then nothing of the voice
/// nor of the music is prepared.
public struct ExportNeeds: Equatable, Sendable {
    /// Whether what is exported has sound: the voice and the music are prepared only then.
    public var sound: Bool

    public init(sound: Bool) {
        self.sound = sound
    }

    /// An MP4 or a movie: with sound.
    public static let video = ExportNeeds(sound: true)
    /// A GIF: no sound.
    public static let gif = ExportNeeds(sound: false)
}

/// What prepares an export: the project's analysis queue (`ProjectJobs`), its voice jobs, its music and the camera's
/// analyses. The app hands its editor's own (the queue the preview's jobs share); the API makes its own with
/// `standalone`.
public struct ExportWorkers: Sendable {
    public var jobs: ProjectJobs
    public var voice: SequenceVoiceJobs
    public var music: MusicAnalysis
    /// What finds the person in the camera's frames: Vision's, unless a test gives another.
    public var segmenter: any PersonSegmenter
    /// What finds the face in the camera's frames: Vision's, unless a test gives another.
    public var detector: any FaceDetector

    public init(
        jobs: ProjectJobs, voice: SequenceVoiceJobs, music: MusicAnalysis,
        segmenter: any PersonSegmenter = VisionPersonSegmenter(), detector: any FaceDetector = VisionFaceDetector()
    ) {
        self.jobs = jobs
        self.voice = voice
        self.music = music
        self.segmenter = segmenter
        self.detector = detector
    }

    /// Workers of their own for an export without the editor (the API's, the command line's): a new queue, the voice
    /// jobs without a speech engine (an export never transcribes), cleaned by `isolator`, and the music of `library`.
    public static func standalone(
        project: LoadedProject, caches: ProjectCaches, isolator: any VoiceIsolating = SystemVoiceIsolation(),
        library: MusicLibrary = .shared
    ) -> ExportWorkers {
        ExportWorkers(
            jobs: ProjectJobs(), voice: SequenceVoiceJobs(project: project, caches: caches, engine: nil, isolator: isolator),
            music: MusicAnalysis(project: project, caches: caches, library: library))
    }
}

/// What a prepared export hands its exporter: what the frames and the mix read of the caches, whether a cleanup was
/// skipped (this Mac has no voice isolation: those tracks go dry), and what makes again a music file macOS removes before
/// the exporter opens it (`MP4Exporter.remakeMusic`; `nil` without music or sound).
public struct PreparedExport: Sendable {
    public var analysis: AnalysisInputs
    public var cleanupSkipped: Bool
    public var remakeMusic: MP4Exporter.MusicRemaking?

    public init(analysis: AnalysisInputs, cleanupSkipped: Bool, remakeMusic: MP4Exporter.MusicRemaking?) {
        self.analysis = analysis
        self.cleanupSkipped = cleanupSkipped
        self.remakeMusic = remakeMusic
    }
}

/// The stages of an export's preparation, in their order.
public enum ExportPreparationStage: String, Sendable, CaseIterable {
    /// The person's masks and the faces (`personMask-1`, `faceTrack-1`).
    case camera
    /// The clean voice and the loudness (`soundIsolation-2`, `loudness-1`).
    case voice
    /// The music's files and the voice it ducks under (`music-1`, `ducking-1`).
    case music
}

/// A stage of the preparation failed: which, and why (its `JobError`, most of the time).
public struct ExportPreparationError: Error, CustomStringConvertible {
    public let stage: ExportPreparationStage
    public let underlying: any Error

    public init(stage: ExportPreparationStage, underlying: any Error) {
        self.stage = stage
        self.underlying = underlying
    }

    public var description: String { "the \(stage.rawValue) could not be prepared: \(underlying)" }
}

/// What an export does before its exporter starts (fases 4 y 5 design §6.2), the same for the app and the API, so both
/// export the same frames and the same sound: the camera's analyses, then the voice's, then the music's, each waiting
/// for what the exported document lacks (first in the project's queue) and putting it in the `AnalysisInputs` the
/// exporter reads. Each stage replaces only its own fields of the inputs it is given:
///
/// - `camera`: `personMasks` and `faceTracks` (`CameraAnalysis.prepareForExport`, which leaves out what this Mac cannot
///   do and the segments that cannot be read, as the preview does).
/// - `voice`: `cleanVoice` and `loudness` (`SequenceVoiceJobs.prepareExport`), for an export with sound; as they came
///   without.
/// - `music`: `musicFiles` and `voiceActivity` (`MusicAnalysis.prepareExport`), and what makes them again; empty for an
///   export without sound or a document without music.
///
/// The app calls the stages one by one (each feature of the editor keeps its progress on the ring, its notices and its
/// alerts); the API calls `prepared`, which runs them in that order. Nothing here writes into the package: only the
/// project's caches.
public enum ExportPreparation {
    /// The analysis an export of `document` reads, prepared with workers of its own (`ExportWorkers.standalone`), from
    /// nothing: `prepared(…).analysis`. Its jobs are cancelled if it throws.
    @concurrent public static func prepare(
        project: LoadedProject, document: EditDocument, caches: ProjectCaches, needs: ExportNeeds,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AnalysisInputs {
        let workers = ExportWorkers.standalone(project: project, caches: caches)
        do {
            return try await prepared(
                project: project, document: document, caches: caches, needs: needs, workers: workers, progress: progress
            ).analysis
        } catch {
            await workers.jobs.cancelAll()
            throw error
        }
    }

    /// The three stages in order (camera, voice, music) on `inputs`, each a third of `progress`, which goes from 0 to 1
    /// and never down; never called once this returns or throws.
    /// - Throws: `CancellationError` if the task is cancelled (the jobs of `workers.jobs` go on: cancel them if nobody
    ///   else needs them); otherwise `ExportPreparationError`, with the stage that failed.
    @concurrent public static func prepared(
        project: LoadedProject, document: EditDocument, caches: ProjectCaches, needs: ExportNeeds, workers: ExportWorkers,
        onto inputs: AnalysisInputs = .none, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedExport {
        let report = OrderedProgress(progress)
        let third = 1.0 / Double(ExportPreparationStage.allCases.count)
        report(0)
        let camera = try await stage(.camera) {
            try await Self.camera(
                inputs, project: project, document: document, caches: caches, jobs: workers.jobs, segmenter: workers.segmenter,
                detector: workers.detector) { report(third * $0) }
        }
        report(third)
        let voice = try await stage(.voice) {
            try await Self.voice(camera, document: document, needs: needs, voice: workers.voice, jobs: workers.jobs) {
                report(third * (1 + $0))
            }
        }
        report(2 * third)
        let music = try await stage(.music) {
            try await Self.music(voice.analysis, document: document, needs: needs, music: workers.music) {
                report(third * (2 + $0))
            }
        }
        report(1)
        return PreparedExport(analysis: music.analysis, cleanupSkipped: voice.cleanupSkipped, remakeMusic: music.remakeMusic)
    }

    /// `inputs` with the person's masks and the faces `document` needs of each take its sequence shows, once their jobs
    /// are done (`CameraAnalysis.prepareForExport`, first in `jobs`). `progress` says how far the jobs that were not done
    /// yet are (`CameraAnalysis.progress`), 1 last; nothing when every one was done. Never called once this returns.
    /// - Throws: the `JobError` of a job that failed; `CancellationError` if the task is cancelled (the jobs go on).
    @concurrent public static func camera(
        _ inputs: AnalysisInputs, project: LoadedProject, document: EditDocument, caches: ProjectCaches, jobs: ProjectJobs,
        segmenter: any PersonSegmenter = VisionPersonSegmenter(), detector: any FaceDetector = VisionFaceDetector(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AnalysisInputs {
        let takes = SequenceAnalyses.takes(shownBy: document, in: project)
        // The jobs not done yet, whose progress is the stage's.
        var notDone: [AnalysisJobKind] = []
        for kind in CameraAnalysis.neededJobs(document: document, takes: takes, package: project.package) {
            if await jobs.state(of: kind) != .done { notDone.append(kind) }
        }
        let pending = notDone
        let watcher = pending.isEmpty ? nil : Task {
            for await states in await jobs.updates() {
                if let fraction = CameraAnalysis.progress(states, of: pending, takes: takes) { progress(fraction) }
            }
        }
        var result = inputs
        do {
            try await CameraAnalysis.prepareForExport(
                &result, document: document, project: project, caches: caches, jobs: jobs, segmenter: segmenter, detector: detector)
        } catch {
            watcher?.cancel()
            await watcher?.value
            throw error
        }
        guard let watcher else { return result }
        watcher.cancel()
        await watcher.value
        progress(1)
        return result
    }

    /// For an export with sound, `inputs` with the clean voice and the loudness `document` needs of each take its
    /// sequence shows, once their jobs are done (`SequenceVoiceJobs.prepareExport`, first in `jobs`), and whether a
    /// cleanup was skipped (no voice isolation on this Mac). Without sound, `inputs` as they are. `progress` from 0 to 1,
    /// never down.
    /// - Throws: the `JobError` of a job that failed; `CancellationError` if the task is cancelled (the jobs go on).
    @concurrent public static func voice(
        _ inputs: AnalysisInputs, document: EditDocument, needs: ExportNeeds, voice: SequenceVoiceJobs, jobs: ProjectJobs,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (analysis: AnalysisInputs, cleanupSkipped: Bool) {
        guard needs.sound else { return (inputs, false) }
        let (analysis, skipped) = try await voice.prepareExport(document, onto: inputs, jobs: jobs, progress: progress)
        return (analysis, skipped)
    }

    /// For an export with sound of a document with music, `inputs` with the music's files and the voice it ducks under
    /// (`MusicAnalysis.prepareExport`, made where they are missing), and what makes again a file macOS removes before the
    /// exporter opens it (`MusicAnalysis.remaking(for:)`). Otherwise `inputs` without music nor voice, and no remaking.
    /// `progress` from 0 to 1, never down.
    /// - Throws: what `MusicAnalysis.prepare` throws: the `JobError` of a file that could not be written,
    ///   `CancellationError` if the task is cancelled (leaving nothing).
    @concurrent public static func music(
        _ inputs: AnalysisInputs, document: EditDocument, needs: ExportNeeds, music: MusicAnalysis,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (analysis: AnalysisInputs, remakeMusic: MP4Exporter.MusicRemaking?) {
        guard needs.sound, !document.music.items.isEmpty else {
            var analysis = inputs
            analysis.musicFiles = [:]
            analysis.voiceActivity = [:]
            return (analysis, nil)
        }
        let analysis = try await music.prepareExport(document, onto: inputs, progress: progress)
        return (analysis, music.remaking(for: document))
    }

    // MARK: - Private

    /// What `body` gives; what it throws as `ExportPreparationError` of `stage`, but a cancellation as itself.
    private static func stage<T>(_ stage: ExportPreparationStage, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExportPreparationError(stage: stage, underlying: error)
        }
    }
}
