// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Export
import Foundation
import ProjectFormat
import Synchronization
import Transcription

/// The takes a document's sequence shows, for the analyses of phase 2, which are by take (phase 3 design §8.1 and §9):
/// each take's jobs are asked for while the sequence shows it, so a take new in it puts its own in the queue.
public enum SequenceAnalyses {
    /// The record of each take `document`'s sequence shows, each once, in the order it first shows them, as
    /// `LoadedProject.takesShown(by:)` gives them (a take the manifest does not have is left out; `project`'s own take
    /// alone for an empty sequence), without focusing on any: it reads nothing, so the main thread may ask.
    public static func takes(shownBy document: EditDocument, in project: LoadedProject) -> [TakeRecord] {
        guard !document.sequence.isEmpty else { return [project.take] }
        var seen: Set<String> = []
        return document.sequence.compactMap { clip in
            guard seen.insert(clip.take).inserted else { return nil }
            if clip.take == project.take.id { return project.take }
            return project.takes.first { $0.id == clip.take }
        }
    }
}

/// The voice jobs of every take a document's sequence shows (phase 3 design §8.1 and §9): a `VoiceJobs` of each take,
/// made the first time it is asked for and kept, and every list of them take by take, in the order the sequence first
/// shows each (`LoadedProject.takesShown(by:)`). With one take, exactly what `VoiceJobs` of the project's take asks,
/// works and reads.
///
/// Each take's jobs read `document` with the gain of each of its tracks by its id (`AudioPlan.trackGain(take:track:takes:)`,
/// the gain the mix plays it with): a track without a gain of its own is cleaned with the cleanup of the same track in the
/// first take of the sequence that has one. Its caches are its own (by `<take>/<track>`), so what one take makes never
/// stands for another's.
///
/// `needed`, `applied` and `transcriptions` read what `VoiceJobs` reads (the caches' folders, the headers of their
/// files): call them off the main thread.
public final class SequenceVoiceJobs: Sendable {
    private let project: LoadedProject
    private let caches: ProjectCaches
    private let engine: (any SpeechEngine)?
    private let isolator: any VoiceIsolating
    /// The jobs of each take asked for so far, by its id.
    private let made = Mutex<[String: VoiceJobs]>([:])

    /// The jobs of every take of `project`'s package that a sequence shows, writing to `caches`; `engine` hears the
    /// words (`nil` before macOS 26), `isolator` cleans the voice.
    public init(project: LoadedProject, caches: ProjectCaches, engine: (any SpeechEngine)?, isolator: any VoiceIsolating) {
        self.project = project
        self.caches = caches
        self.engine = engine
        self.isolator = isolator
    }

    /// The voice jobs of the take `take` (the project focused on it, `LoadedProject.focused(on:)`), made the first time
    /// they are asked for and the same ones after; `nil` for a take the manifest does not have.
    public func jobs(ofTake take: String) -> VoiceJobs? {
        made.withLock { made -> VoiceJobs? in
            if let jobs = made[take] { return jobs }
            guard let focused = project.focused(on: take) else { return nil }
            let jobs = VoiceJobs(project: focused, caches: caches, engine: engine, isolator: isolator)
            made[take] = jobs
            return jobs
        }
    }

    /// The jobs `document` waits for (`VoiceJobs.needed(for:)`), take by take.
    public func needed(for document: EditDocument) -> [AnalysisJobKind] {
        shown(document).flatMap { $0.jobs.needed(for: $0.document) }
    }

    /// The work of a cleanup or a loudness job, by the jobs of its take (`VoiceJobs.work(for:)`); `nil` for any other
    /// kind and for a take the manifest does not have.
    public func work(for kind: AnalysisJobKind) -> JobWork? {
        switch kind {
        case let .soundIsolation(take, _, _), let .loudness(take, _):
            return jobs(ofTake: take)?.work(for: kind)
        case .transcription, .personMask, .faceTrack, .sensitiveScan:
            return nil
        }
    }

    /// The transcription in `language` of each take `document`'s sequence shows that has a track to transcribe
    /// (`VoiceJobs.transcription(language:)`), take by take.
    public func transcriptions(language: String, document: EditDocument) -> [(AnalysisJobKind, JobWork)] {
        shown(document).compactMap { $0.jobs.transcription(language: language) }
    }

    /// `inputs` with its clean voice and loudness those the caches hold for every take `document`'s sequence shows
    /// (`VoiceJobs.applied(to:document:)` of each, which never share a key), the other fields as they are. Synchronous,
    /// from the disk: call it off the main thread.
    public func applied(to inputs: AnalysisInputs, document: EditDocument) -> AnalysisInputs {
        var result = Self.emptied(inputs)
        for take in shown(document) {
            Self.add(take.jobs.applied(to: inputs, document: take.document), to: &result)
        }
        return result
    }

    /// Waits for every job `document` needs, take by take (`VoiceJobs.prepareExport` of each, its progress one equal
    /// share of the whole, from 0 to 1 and never down), then `applied(to:document:)` of `inputs`; `cleanupSkipped` when
    /// any take's cleanup was skipped (no voice isolation on this Mac).
    /// - Throws: the `JobError` of a job that failed; `CancellationError` if the task is cancelled (the jobs go on).
    public func prepareExport(
        _ document: EditDocument, onto inputs: AnalysisInputs, jobs: ProjectJobs, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (inputs: AnalysisInputs, cleanupSkipped: Bool) {
        let shown = shown(document)
        guard !shown.isEmpty else {
            progress(1)
            return (Self.emptied(inputs), false)
        }
        var result = Self.emptied(inputs)
        var skipped = false
        let count = Double(shown.count)
        for (index, take) in shown.enumerated() {
            let done = Double(index)
            let (prepared, cleanupSkipped) = try await take.jobs.prepareExport(take.document, onto: inputs, jobs: jobs) {
                progress((done + $0) / count)
            }
            Self.add(prepared, to: &result)
            skipped = skipped || cleanupSkipped
        }
        return (result, skipped)
    }

    // MARK: - Private

    /// The jobs of each take `document`'s sequence shows, in its order, with `document` as they read it: the gain of
    /// each track of the take that has none of its own, that of the same track in the first take of the sequence that
    /// has one. With one take, `document` itself.
    private func shown(_ document: EditDocument) -> [(jobs: VoiceJobs, document: EditDocument)] {
        let takes = SequenceAnalyses.takes(shownBy: document, in: project)
        let ids = takes.map(\.id)
        return takes.compactMap { take in
            guard let jobs = jobs(ofTake: take.id) else { return nil }
            var read = document
            for track in take.tracks where !track.kind.isVideo {
                let key = AudioPlan.key(take: take.id, track: track.id)
                guard read.audio.tracks[key] == nil,
                      let gain = document.audio.trackGain(take: take.id, track: track.id, takes: ids)
                else { continue }
                read.audio.tracks[key] = gain
            }
            return (jobs, read)
        }
    }

    /// `inputs` without clean voice nor loudness.
    private static func emptied(_ inputs: AnalysisInputs) -> AnalysisInputs {
        var inputs = inputs
        inputs.cleanVoice = [:]
        inputs.loudness = [:]
        return inputs
    }

    /// Adds the clean voice and the loudness of one take, `part`, to `result`.
    private static func add(_ part: AnalysisInputs, to result: inout AnalysisInputs) {
        result.cleanVoice.merge(part.cleanVoice) { first, _ in first }
        result.loudness.merge(part.loudness) { first, _ in first }
    }
}
