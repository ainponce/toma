// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Editing
import Export
import Foundation
import ProjectFormat
import Synchronization
import Transcription

/// What takes the noise out of a segment of a microphone (`soundIsolation-2`, phase 2 design §5.6): the system's
/// `AUSoundIsolation` (`SystemVoiceIsolation`), or a test's.
public protocol VoiceIsolating: Sendable {
    /// Whether this Mac can clean.
    var isAvailable: Bool { get }
    /// Writes the clean voice of `span` of `audio` to a new file at `url` as `SoundIsolation.clean` does (CAF, Float32
    /// LPCM, mono, 48 kHz, exactly the span's frames), reporting the fraction done to `progress`.
    /// - Throws: `CancellationError` if the task is cancelled, leaving whatever it wrote at `url` for the caller to delete.
    func clean(_ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The system's voice isolation: `SoundIsolation`, `AUSoundIsolation` rendered offline.
public struct SystemVoiceIsolation: VoiceIsolating {
    public init() {}

    public var isAvailable: Bool { SoundIsolation.isAvailable }

    public func clean(
        _ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await SoundIsolation.clean(audio, span: span, to: url, progress: progress)
    }
}

/// The voice jobs of a project open in the editor (phase 2 design §5.1, §5.6, §5.7 and §10; plan decisions 14, 15 and
/// 17): which of them a document needs, their work on the project's `ProjectJobs`, what their caches give the mix
/// (`AnalysisInputs`), and what an export waits for.
///
/// - **The caches.** The clean voice of a segment of a microphone is `clean/<take>/<track>/<segment>-soundIsolation-2.caf`
///   (exactly the timeline frames the segment is heard over, `TrackAudio.spans`), its loudness
///   `loudness/<take>/<track>/<segment>-loudness-1.json` (`SegmentLoudness`), each named by the segment's identity
///   (`SegmentIdentity`): a segment written again is another file. A clean file of another length than its span, or a
///   measure of another length, of other channels or of a clean file that is not the one there now, is stale: it is
///   never used, and is made again.
/// - **Where the tracks are heard.** The spans of a track come from decoding it (`TrackAudio.load`), which the jobs of
///   a track and the export's preparation do once, for every job of the project (only where each segment is heard is
///   kept in memory, never its samples), as long as its segments are the same files. Until then, `needed` and `applied`
///   go by the segments that are there (`SegmentAvailability.present`) and by the names of their caches; a clean file
///   is checked against its span's length once the track was loaded. The export always loads them first.
/// - **Nothing at half.** A cache is written whole (`ProjectCaches.temporaryFile`, `commit`, `writeAnalysis`) or not at
///   all: a work that is cancelled or fails leaves no file, not even its temporary. Nothing is written in the package.
///
/// `needed` and `applied` read the caches' folders (`lstat`), the header of a clean file and a loudness file once for
/// each version of it, never the audio: call them off the main thread.
public final class VoiceJobs: Sendable {
    private let project: LoadedProject
    private let caches: ProjectCaches
    private let engine: (any SpeechEngine)?
    private let isolator: any VoiceIsolating
    private let audios: SharedTrackAudio
    private let reads = CacheReads()

    /// The jobs of `project`'s take, writing to `caches`; `engine` hears the words (`nil` before macOS 26), `isolator`
    /// cleans the voice.
    public init(project: LoadedProject, caches: ProjectCaches, engine: (any SpeechEngine)?, isolator: any VoiceIsolating) {
        self.project = project
        self.caches = caches
        self.engine = engine
        self.isolator = isolator
        audios = SharedTrackAudio(project: project)
    }

    /// Where the tracks' audio comes from, shared by every job: for the tests.
    var trackAudio: SharedTrackAudio { audios }

    // MARK: - The jobs

    /// The transcription of the take in `language` (BCP 47), of the track `Transcriber.track` picks, and its work,
    /// which makes `.transcript`; `nil` if the take has no track to transcribe. Without an engine (macOS 15) the job is
    /// unavailable, `.needsMacOS26`.
    public func transcription(language: String) -> (AnalysisJobKind, JobWork)? {
        guard let track = Transcriber.track(for: project.take) else { return nil }
        let project = project, engine = engine
        let work: JobWork = { progress in
            guard let engine else { throw JobError(.needsMacOS26, unavailable: true) }
            do {
                let transcript = try await Transcriber.transcribe(project, language: language, engine: engine) { progress.report($0) }
                return .transcript(transcript)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw Self.jobError(error)
            }
        }
        return (.transcription(take: project.take.id, track: track.id), work)
    }

    /// The jobs `document` waits for, in the order they are to run: the cleaning of each segment heard of each
    /// microphone with a cleanup above 0 whose clean voice is not in the caches (none when this Mac cannot clean), then,
    /// with Normalize, the loudness of each audio track with a segment whose measure is missing or stale (with a cleanup,
    /// stale also when it is not of the clean file there now). Once those have run, none of them again: a measure made
    /// before its segment was cleaned is asked for once the clean file is there.
    public func needed(for document: EditDocument) -> [AnalysisJobKind] {
        let take = project.take.id
        var kinds: [AnalysisJobKind] = []
        if isolator.isAvailable {
            for track in cleanedTracks(document) {
                for heard in heard(track) where cleanFile(heard, of: track) == nil {
                    kinds.append(.soundIsolation(take: take, track: track.id, segment: heard.record.index))
                }
            }
        }
        if document.audio.normalize {
            for track in audioTracks where !isMeasured(track, withClean: cleanup(of: track, in: document) > 0) {
                kinds.append(.loudness(take: take, track: track.id))
            }
        }
        return kinds
    }

    /// The work of a cleanup or a loudness job of this take; `nil` for any other kind (the transcription's comes with
    /// `transcription(language:)`), another take, or a track or segment the take does not have.
    ///
    /// - A cleanup writes the clean voice of its segment (`isolator`) to its cache and makes `.cached` of it; one already
    ///   there is found, not made again. Without the isolation it is unavailable, `.notOnThisMac`.
    /// - A loudness job measures each segment heard of its track whose measure is missing or stale (`Loudness.measure`,
    ///   with the segment's clean voice when it is there), writes it, and makes `.cached` of the track's folder.
    ///
    /// A segment that is not heard is `.sourceUnreadable`, a full drive `.noSpace`.
    public func work(for kind: AnalysisJobKind) -> JobWork? {
        switch kind {
        case let .soundIsolation(take, trackID, index):
            guard take == project.take.id, let track = project.take.track(trackID), track.kind == .microphone,
                  let segment = track.segments.first(where: { $0.index == index })
            else { return nil }
            return { [self] progress in
                try await Self.reporting { try await self.clean(segment, of: track, progress: progress) }
            }
        case let .loudness(take, trackID):
            guard take == project.take.id, let track = project.take.track(trackID), !track.kind.isVideo else { return nil }
            return { [self] progress in
                try await Self.reporting { try await self.measure(track, progress: progress) }
            }
        case .transcription, .personMask, .faceTrack, .sensitiveScan:
            return nil
        }
    }

    // MARK: - What the mix reads

    /// `inputs` with its clean voice and loudness those of the caches for `document` (the other fields as they are):
    /// the clean voice of each microphone with a cleanup above 0 whose every segment heard has its clean file, and, with
    /// Normalize, the loudness of each audio track whose every segment heard is measured, with the clean voice's blocks
    /// only when the track is mixed clean and every measure is of the clean file mixed (otherwise the dry sound's
    /// alone: such a track is not normalized while it plays clean, `EditedMix`). Synchronous, from the disk: call it off
    /// the main thread.
    public func applied(to inputs: AnalysisInputs, document: EditDocument) -> AnalysisInputs {
        var result = inputs
        result.cleanVoice = [:]
        result.loudness = [:]
        for track in cleanedTracks(document) {
            let heard = heard(track)
            let files = heard.compactMap { heard in cleanFile(heard, of: track).map { (heard.record.file, $0.url) } }
            guard !heard.isEmpty, files.count == heard.count else { continue }
            result.cleanVoice[key(track)] = CleanVoice(files: Dictionary(files) { first, _ in first })
        }
        if document.audio.normalize {
            for track in audioTracks {
                guard let loudness = trackLoudness(track, mixedClean: result.cleanVoice[key(track)] != nil) else { continue }
                result.loudness[key(track)] = loudness
            }
        }
        return result
    }

    // MARK: - The export

    /// Waits for every job `document` needs (`needed`, and the loudness measured again after the cleaning it waits
    /// for) through `jobs`, each first in the queue, in order, reporting their progress as one, from 0 to 1 and never
    /// down; then `applied(to:document:)` of `inputs`. Without the voice isolation on this Mac (a project cleaned on
    /// another), the cleanups are skipped and `cleanupSkipped` says so: the export goes dry for those tracks.
    /// - Throws: the `JobError` of a job that failed; `CancellationError` if the task is cancelled (the jobs go on).
    public func prepareExport(
        _ document: EditDocument, onto inputs: AnalysisInputs, jobs: ProjectJobs, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (inputs: AnalysisInputs, cleanupSkipped: Bool) {
        let report = RisingProgress(progress)
        // Where each track it needs is heard, so `needed` finds a clean file of another length too.
        for track in tracksToLoad(document) {
            do {
                _ = try await audios.audio(of: track)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw Self.jobError(error)
            }
        }
        var skipped = !isolator.isAvailable
        var kinds = await offThePool { self.needed(for: document) }
        // A measure made before the cleaning is stale once it is done.
        if document.audio.normalize {
            for case let .soundIsolation(take, track, _) in kinds where !kinds.contains(.loudness(take: take, track: track)) {
                kinds.append(.loudness(take: take, track: track))
            }
        }
        var total = kinds.count, done = 0, passes = 0
        // Once more if a cache went missing meanwhile; never on and on.
        while !kinds.isEmpty, passes < 3 {
            passes += 1
            for kind in kinds {
                if let work = work(for: kind) {
                    let before = done, of = total
                    do {
                        try await Self.wait(for: kind, work: work, on: jobs) { report((Double(before) + $0) / Double(of)) }
                    } catch let error as JobError where error.unavailable && kind.isSoundIsolation {
                        skipped = true
                    }
                }
                done += 1
                report(Double(done) / Double(total))
            }
            kinds = await offThePool { self.needed(for: document) }.filter { !(skipped && $0.isSoundIsolation) }
            total += kinds.count
        }
        report(1)
        let skippedAny = skipped
        return await offThePool {
            let result = self.applied(to: inputs, document: document)
            // A track left dry that had something to clean.
            let dry = self.cleanedTracks(document).contains { result.cleanVoice[self.key($0)] == nil && !self.heard($0).isEmpty }
            return (result, skippedAny && dry)
        }
    }

    /// The `JobError` a job keeps for `error`: the transcription's and the isolation's reasons, a full drive (also
    /// under the errors it wraps), or what it says.
    public static func jobError(_ error: any Error) -> JobError {
        switch error {
        case let error as JobError:
            return error
        case let error as TranscriptionError:
            switch error {
            case .needsMacOS26: return JobError(.needsMacOS26, unavailable: true)
            case .notOnThisMac: return JobError(.notOnThisMac, unavailable: true)
            case .modelNotInstalled(let locale): return JobError(.modelNotInstalled(locale: locale), unavailable: true)
            case .noAudio: return JobError(.failed("nothing of the take is heard"))
            case .engine(let message): return JobError(.failed(message))
            }
        case let error as SoundIsolationError:
            switch error {
            case .unavailable: return JobError(.notOnThisMac, unavailable: true)
            case .renderingFailed(let message): return JobError(.failed(message))
            }
        default:
            return isOutOfSpace(error) ? JobError(.noSpace) : JobError(.failed(String(describing: error)))
        }
    }

    // MARK: - The works

    /// The work of a cleanup: the clean voice of `segment` of `track` in its cache.
    private func clean(_ segment: SegmentRecord, of track: TrackRecord, progress: JobProgress) async throws -> JobOutput {
        guard isolator.isAvailable else { throw JobError(.notOnThisMac, unavailable: true) }
        let loaded = try await audios.audio(of: track)
        guard let heard = Self.heard(track, loaded).first(where: { $0.record.file == segment.file }), let span = heard.span else {
            throw JobError(.sourceUnreadable(file: segment.file))
        }
        guard let url = cleanURL(heard, of: track) else { throw JobError(.failed("no cache file for \(segment.file)")) }
        if cleanFile(heard, of: track) == nil {
            let temporary = try ProjectCaches.temporaryFile(for: url)
            do {
                try await isolator.clean(loaded.audio, span: span, to: temporary) { progress.report($0) }
                guard try ProjectCaches.commit(temporary, to: url) else {
                    throw JobError(.failed("the clean voice of \(segment.file) could not be written"))
                }
            } catch {
                unlink(temporary.path)
                if !(error is CancellationError), !Self.hasRoom(for: Int64(span.frames.count) * 4, at: url) { throw JobError(.noSpace) }
                throw error
            }
        }
        progress.report(1)
        return .cached(url)
    }

    /// The work of a loudness job: the measure of each segment heard of `track` in its cache.
    private func measure(_ track: TrackRecord, progress: JobProgress) async throws -> JobOutput {
        let loaded = try await audios.audio(of: track)
        let heard = Self.heard(track, loaded)
        let total = max(1, heard.reduce(Int64(0)) { $0 + Int64($1.span?.frames.count ?? 0) })
        var done: Int64 = 0
        for heard in heard {
            try Task.checkCancellation()
            guard let span = heard.span, let url = loudnessURL(heard, of: track) else { continue }
            let clean = cleanFile(heard, of: track)
            if let measure = reads.measure(url), Self.isCurrent(measure, of: heard, clean: clean, channels: loaded.audio.channels) {
                done += Int64(span.frames.count)
                continue
            }
            let measure = try await Loudness.measure(loaded.audio, span: span, clean: clean?.url)
            let data = try ProjectJSON.encoder().encode(measure)
            guard ProjectCaches.writeAnalysis(data, to: url) else {
                try Task.checkCancellation()
                throw JobError(Self.hasRoom(for: Int64(data.count), at: url) ? .failed("the loudness of \(span.segment) could not be written") : .noSpace)
            }
            done += Int64(span.frames.count)
            progress.report(Double(done) / Double(total))
        }
        progress.report(1)
        return .cached(caches.folder(.loudness).appending(path: project.take.id, directoryHint: .isDirectory)
            .appending(path: track.id, directoryHint: .isDirectory))
    }

    /// What `body` makes, with any error but a cancellation as the queue keeps it (`jobError`).
    private static func reporting(_ body: () async throws -> JobOutput) async throws -> JobOutput {
        do {
            return try await body()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw jobError(error)
        }
    }

    /// Waits for the job of `kind` (first in the queue, `work` if it is not there yet), with its progress to `progress`.
    private static func wait(
        for kind: AnalysisJobKind, work: @escaping JobWork, on jobs: ProjectJobs, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let updates = await jobs.updates()
        let watcher = Task {
            for await states in updates {
                if case .running(let fraction)? = states[kind] { progress(fraction) }
            }
        }
        defer { watcher.cancel() }
        _ = try await jobs.result(of: kind, work: work)
    }

    // MARK: - The tracks and their caches

    /// A segment of a track that is heard, as far as is known: by its span once its track's audio is loaded, by its
    /// file being there before.
    private struct Heard {
        var record: SegmentRecord
        var identity: SegmentIdentity
        /// Where it is heard, once the track's audio is loaded.
        var span: TrackAudioSpan?
    }

    /// A clean file there, and its identity as a loudness measure names it.
    private struct Clean {
        var url: URL
        var identity: String
    }

    /// The take's audio tracks with segments: its microphones, system audio and device audio.
    private var audioTracks: [TrackRecord] {
        project.take.tracks.filter { !$0.kind.isVideo && !$0.segments.isEmpty }
    }

    /// The take's microphones with segments that `document` cleans (a cleanup above 0).
    private func cleanedTracks(_ document: EditDocument) -> [TrackRecord] {
        audioTracks.filter { $0.kind == .microphone && cleanup(of: $0, in: document) > 0 }
    }

    /// The tracks whose audio the export loads before asking what it needs.
    private func tracksToLoad(_ document: EditDocument) -> [TrackRecord] {
        let cleaned = isolator.isAvailable ? cleanedTracks(document) : []
        guard document.audio.normalize else { return cleaned }
        return audioTracks
    }

    private func key(_ track: TrackRecord) -> String {
        AudioPlan.key(take: project.take.id, track: track.id)
    }

    /// `TrackGain.cleanup` of `track` in `document`, 0 to 1 (not a number, 0).
    private func cleanup(of track: TrackRecord, in document: EditDocument) -> Double {
        guard let cleanup = document.audio.tracks[key(track)]?.cleanup, !cleanup.isNaN else { return 0 }
        return min(max(cleanup, 0), 1)
    }

    /// The segments of `track` that are heard, in order: those of its loaded audio if its segments are still the files
    /// it was loaded from; otherwise those whose file is there.
    private func heard(_ track: TrackRecord) -> [Heard] {
        let identities = audios.identities(of: track)
        if let loaded = audios.loaded(track, identities: identities) { return Self.heard(track, loaded) }
        return track.segments.indices
            .filter { SegmentAvailability.classify(track.segments[$0], in: project.package) == .present }
            .sorted { track.segments[$0].startHostTime < track.segments[$1].startHostTime }
            .compactMap { k in identities[k].map { Heard(record: track.segments[k], identity: $0, span: nil) } }
    }

    /// The segments heard in `loaded`, the audio of `track`.
    private static func heard(_ track: TrackRecord, _ loaded: SharedTrackAudio.Loaded) -> [Heard] {
        loaded.audio.spans.compactMap { span in
            guard let k = track.segments.firstIndex(where: { $0.file == span.segment }), let identity = loaded.identities[k] else {
                return nil
            }
            return Heard(record: track.segments[k], identity: identity, span: span)
        }
    }

    private func cleanURL(_ heard: Heard, of track: TrackRecord) -> URL? {
        caches.analysisFile(
            .clean, take: project.take.id, track: track.id, segment: heard.identity, algorithm: SoundIsolation.algorithm,
            extension: "caf")
    }

    private func loudnessURL(_ heard: Heard, of track: TrackRecord) -> URL? {
        caches.analysisFile(
            .loudness, take: project.take.id, track: track.id, segment: heard.identity, algorithm: Loudness.algorithm,
            extension: "json")
    }

    /// The clean voice of `heard` in the caches, if it is there whole: a regular file of mono Float32 LPCM at 48 kHz,
    /// as long as its span once that is known (the check `EditedMix` makes).
    private func cleanFile(_ heard: Heard, of track: TrackRecord) -> Clean? {
        guard let url = cleanURL(heard, of: track), let found = reads.cleanFrames(url) else { return nil }
        if let span = heard.span, found.frames != Int64(span.frames.count) { return nil }
        return Clean(url: url, identity: found.identity)
    }

    /// Whether every segment heard of `track` has its measure, current (`isCurrent`), all of the same channels: with
    /// the blocks of its clean voice when `withClean` and its clean file is there.
    private func isMeasured(_ track: TrackRecord, withClean: Bool) -> Bool {
        var channels = audios.loaded(track, identities: audios.identities(of: track))?.audio.channels
        for heard in heard(track) {
            guard let url = loudnessURL(heard, of: track), let measure = reads.measure(url),
                  Self.isCurrent(measure, of: heard, clean: withClean ? cleanFile(heard, of: track) : nil, channels: channels)
            else { return false }
            channels = measure.channels
        }
        return true
    }

    /// The loudness of `track` if every segment heard is measured: with the clean voice's blocks when `mixedClean` and
    /// each measure is of the clean file there now.
    private func trackLoudness(_ track: TrackRecord, mixedClean: Bool) -> TrackLoudness? {
        let heard = heard(track)
        guard !heard.isEmpty else { return nil }
        var channels = audios.loaded(track, identities: audios.identities(of: track))?.audio.channels
        var measures: [SegmentLoudness] = []
        var withClean = mixedClean
        for heard in heard {
            guard let url = loudnessURL(heard, of: track), let measure = reads.measure(url),
                  Self.isCurrent(measure, of: heard, clean: nil, channels: channels)
            else { return nil }
            channels = measure.channels
            if withClean {
                let clean = cleanFile(heard, of: track)
                withClean = clean != nil && Self.isCurrent(measure, of: heard, clean: clean, channels: nil)
            }
            measures.append(measure)
        }
        return TrackLoudness(
            channels: measures[0].channels, dry: measures.flatMap(\.dry),
            wet: withClean ? measures.flatMap { $0.wet ?? [] } : nil, cross: withClean ? measures.flatMap { $0.cross ?? [] } : nil)
    }

    /// Whether `measure` is what measuring `heard` now gives: of `loudness-1`, of `channels` when given, one block for
    /// each of its span once that is known, and with the clean voice's blocks, of the file `clean`, when given.
    private static func isCurrent(_ measure: SegmentLoudness, of heard: Heard, clean: Clean?, channels: Int?) -> Bool {
        guard measure.algorithm == Loudness.algorithm, measure.channels == 1 || measure.channels == 2 else { return false }
        if let channels, measure.channels != channels { return false }
        if let span = heard.span, measure.dry.count != blocks(inFrames: Int64(span.frames.count)) { return false }
        guard let clean else { return true }
        return measure.clean == clean.identity && measure.wet?.count == measure.dry.count && measure.cross?.count == measure.dry.count
    }

    /// The whole blocks of 400 ms, one every 100 ms, in `frames` frames.
    private static func blocks(inFrames frames: Int64) -> Int {
        let hopsInABlock = Int64(Loudness.blockFrames / Loudness.hopFrames)
        return Int(max(0, frames / Int64(Loudness.hopFrames) - (hopsInABlock - 1)))
    }

    /// Whether the volume of `url` has room for `bytes` more, and some to spare; true when it cannot tell.
    private static func hasRoom(for bytes: Int64, at url: URL) -> Bool {
        var folder = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        guard let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return true
        }
        return Int64(available) > bytes + 1_048_576
    }
}

extension AnalysisJobKind {
    fileprivate var isSoundIsolation: Bool {
        if case .soundIsolation = self { true } else { false }
    }
}

// MARK: - Shared audio of the tracks

/// The audio of each track of a take (`TrackAudio`: where its segments are heard, never their samples), loaded once and
/// shared by every job and export of the project while its segments are the files it was loaded from (by
/// `SegmentIdentity`).
///
/// Callers that ask while it loads wait for the same load. One whose task is cancelled stops waiting at once if it is
/// the last one waiting, and the load is cancelled with it; otherwise it waits on until the load is done, and the
/// others get it. A load that fails or is cancelled is forgotten: the next caller loads again.
final class SharedTrackAudio: Sendable {
    typealias Load = @Sendable (LoadedProject, TrackRecord) async throws -> TrackAudio

    struct Loaded: Sendable {
        /// Of the track's segments, in the manifest's order, when the audio was loaded.
        var identities: [SegmentIdentity?]
        var audio: TrackAudio
    }

    private struct Loading {
        var id: Int
        var identities: [SegmentIdentity?]
        var task: Task<TrackAudio, any Error>
        var waiters: Set<Int>
    }

    private struct State {
        var loaded: [String: Loaded] = [:]
        var loading: [String: Loading] = [:]
        var lastID = 0
        var loads = 0
    }

    private enum Step {
        case loaded(Loaded)
        case waiting(Task<TrackAudio, any Error>, load: Int, waiter: Int)
    }

    private let project: LoadedProject
    private let load: Load
    private let state = Mutex(State())

    /// Loading with `load`: `TrackAudio.load` of the track with the channels it needs, unless a test loads otherwise.
    init(project: LoadedProject, load: @escaping Load = { try await TrackAudio.load($0, track: $1.id) }) {
        self.project = project
        self.load = load
    }

    /// The loads started so far, for the tests.
    var loads: Int { state.withLock { $0.loads } }

    /// The callers waiting for the load of `track` under way, for the tests.
    func waiters(of track: TrackRecord) -> Int {
        state.withLock { $0.loading[track.id]?.waiters.count ?? 0 }
    }

    /// The identity of each segment of `track`, in its order (`nil` for one that is not a regular file there).
    func identities(of track: TrackRecord) -> [SegmentIdentity?] {
        track.segments.map { SegmentIdentity.of($0, in: project.package) }
    }

    /// The audio of `track`, if it was loaded from the files whose identities are `identities`.
    func loaded(_ track: TrackRecord, identities: [SegmentIdentity?]) -> Loaded? {
        state.withLock { state in
            guard let loaded = state.loaded[track.id], loaded.identities == identities else { return nil }
            return loaded
        }
    }

    /// The audio of `track` from its files as they are now: loaded already, or once the load under way or a new one
    /// (on a task of its own, at utility priority) is done.
    /// - Throws: what `TrackAudio.load` throws; `CancellationError` if the task is cancelled while it is the last one
    ///   waiting.
    func audio(of track: TrackRecord) async throws -> Loaded {
        let identities = identities(of: track)
        let project = project, load = load
        let step = state.withLock { state -> Step in
            if let loaded = state.loaded[track.id], loaded.identities == identities { return .loaded(loaded) }
            state.lastID += 1
            let waiter = state.lastID
            if var loading = state.loading[track.id], loading.identities == identities {
                loading.waiters.insert(waiter)
                state.loading[track.id] = loading
                return .waiting(loading.task, load: loading.id, waiter: waiter)
            }
            // A load of other files, if one is under way, is left to whoever waits for it.
            state.lastID += 1
            let id = state.lastID
            state.loads += 1
            let task = Task.detached(priority: .utility) { try await load(project, track) }
            state.loading[track.id] = Loading(id: id, identities: identities, task: task, waiters: [waiter])
            return .waiting(task, load: id, waiter: waiter)
        }
        guard case let .waiting(task, load, waiter) = step else {
            guard case .loaded(let loaded) = step else { preconditionFailure("SharedTrackAudio: a step of no kind") }
            return loaded
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            self.leave(track.id, load: load, waiter: waiter)
        }
        return try state.withLock { state in
            if state.loading[track.id]?.id == load { state.loading[track.id] = nil }
            let loaded = Loaded(identities: identities, audio: try result.get())
            state.loaded[track.id] = loaded
            return loaded
        }
    }

    /// `waiter` no longer waits for load `load` of `track`: the load is cancelled (and forgotten) if no one does.
    private func leave(_ track: String, load: Int, waiter: Int) {
        let abandoned = state.withLock { state -> Task<TrackAudio, any Error>? in
            guard var loading = state.loading[track], loading.id == load else { return nil }
            loading.waiters.remove(waiter)
            guard loading.waiters.isEmpty else {
                state.loading[track] = loading
                return nil
            }
            state.loading[track] = nil
            return loading.task
        }
        abandoned?.cancel()
    }
}

// MARK: - Reading the caches

/// What the caches' files hold, read once for each version of each: by its path, and its size, date and inode by
/// `lstat` (never following a link).
private final class CacheReads: Sendable {
    private struct Stamp: Equatable, Sendable {
        var bytes: Int64
        var modified: Int64
        var inode: UInt64

        /// `"<bytes>-<modification ns>"`, what a loudness measure names its clean file by.
        var identity: String { "\(bytes)-\(modified)" }
    }

    private struct Entry<Value: Sendable>: Sendable {
        var stamp: Stamp
        var value: Value?
    }

    private let cleanFiles = Mutex<[String: Entry<Int64>]>([:])
    private let measures = Mutex<[String: Entry<SegmentLoudness>]>([:])

    /// The identity and frames of the clean file at `url` if it is a regular file of mono Float32 LPCM at 48 kHz:
    /// its header, never its audio.
    func cleanFrames(_ url: URL) -> (identity: String, frames: Int64)? {
        guard let stamp = Self.stamp(url) else { return nil }
        if let entry = cleanFiles.withLock({ $0[url.path] }), entry.stamp == stamp {
            return entry.value.map { (stamp.identity, $0) }
        }
        let frames = Self.frames(ofCleanFile: url)
        cleanFiles.withLock { $0[url.path] = Entry(stamp: stamp, value: frames) }
        return frames.map { (stamp.identity, $0) }
    }

    /// The loudness measure in the file at `url`, of `loudness-1`; `nil` if there is none or it cannot be read.
    func measure(_ url: URL) -> SegmentLoudness? {
        guard let stamp = Self.stamp(url) else { return nil }
        if let entry = measures.withLock({ $0[url.path] }), entry.stamp == stamp { return entry.value }
        let measure = ProjectCaches.readAnalysis(url).flatMap { try? ProjectJSON.decoder().decode(SegmentLoudness.self, from: $0) }
            .flatMap { $0.algorithm == Loudness.algorithm ? $0 : nil }
        measures.withLock { $0[url.path] = Entry(stamp: stamp, value: measure) }
        return measure
    }

    /// The `lstat` of a regular file at `url`; `nil` for anything else.
    private static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(
            bytes: Int64(info.st_size), modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }

    private static func frames(ofCleanFile url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let format = file.fileFormat
        guard format.commonFormat == .pcmFormatFloat32, format.sampleRate == TrackAudio.sampleRate, format.channelCount == 1 else {
            return nil
        }
        return file.length
    }
}

// MARK: - Helpers

/// Reports a fraction that only goes up, clamped to 0…1, to `report`, in order (under a lock).
private final class RisingProgress: Sendable {
    private let last = Mutex(-1.0)
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func callAsFunction(_ fraction: Double) {
        guard !fraction.isNaN else { return }
        let value = min(max(fraction, 0), 1)
        last.withLock { last in
            guard value > last else { return }
            last = value
            report(value)
        }
    }
}

/// `body`, run on a queue of its own and waited for without holding a thread of Swift's cooperative pool: it reads
/// the caches' files.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: body()) }
    }
}

/// Whether `error` means the drive is full, looking through the errors it wraps (as the recording does).
private func isOutOfSpace(_ error: any Error, depth: Int = 0) -> Bool {
    let error = error as NSError
    switch (error.domain, error.code) {
    case (NSPOSIXErrorDomain, Int(ENOSPC)),
         (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
         (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
         (NSOSStatusErrorDomain, -34):  // dskFulErr
        return true
    default:
        break
    }
    guard depth < 8 else { return false }
    var underlying: [NSError] = []
    if let error = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(error) }
    if let errors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { underlying += errors }
    return underlying.contains { isOutOfSpace($0, depth: depth + 1) }
}
