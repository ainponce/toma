// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import ProjectFormat

/// Transcribes a take (phase 2 design §5.1): the words of one of its audio tracks, decoded on the take's timeline as
/// the mix places it (`TrackAudio`, in mono), given to an engine span by span, in source host time. A word never starts
/// or ends in a quiet span of the track (`SilenceFinder`, `TranscriptWords.trimmed`): the pauses stay pauses.
///
/// What it makes goes into the document whole (`Transcript`), or nothing does: a cancelled or failed transcription
/// gives nothing back.
public enum Transcriber {
    /// The track a take's transcription is named by (`AnalysisJobKind.transcription`, plan decision 19): the first of
    /// `candidates(for:)`; `nil` if the take has none. When the candidates are several tracks of system audio,
    /// `transcribe` hears the one with the most speech, which the transcript names (`TranscriptTake.track`).
    public static func track(for take: TakeRecord) -> TrackRecord? {
        candidates(for: take).first
    }

    /// The tracks a take may be transcribed from (plan decision 19), in the manifest's order: its first microphone that
    /// recorded a segment; without one, every track of system audio that did (one for each app chosen By App, phase 3
    /// design §7.1); without any, its first device audio that did; none if none did.
    public static func candidates(for take: TakeRecord) -> [TrackRecord] {
        let recorded = take.tracks.filter { !$0.segments.isEmpty }
        if let microphone = recorded.first(where: { $0.kind == .microphone }) { return [microphone] }
        let system = recorded.filter { $0.kind == .systemAudio }
        if !system.isEmpty { return system }
        return recorded.first(where: { $0.kind == .deviceAudio }).map { [$0] } ?? []
    }

    /// The transcript of `project`'s take, in `language` (BCP 47; `es_MX` is written `es-MX`), heard by `engine`, of
    /// the one of `candidates(for:)` with the most speech (`heardTrack`). `progress` is the engine's, from 0 to 1.
    /// - Throws: `TranscriptionError.noAudio` if the take has no track to transcribe or nothing of it is heard; what
    ///   `TrackAudio.load` throws for its segments; what the engine throws; `CancellationError` if the task is
    ///   cancelled.
    public static func transcribe(
        _ project: LoadedProject, language: String, engine: any SpeechEngine, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        guard let (track, audio) = try await heardTrack(project) else { throw TranscriptionError.noAudio }
        let language = SpeechLanguages.bcp47(language)
        guard !audio.spans.isEmpty else { throw TranscriptionError.noAudio }
        // Found while the engine hears, with a reader of its own; cancelled with the engine if it throws.
        async let quiet = SilenceFinder.quietSpans(audio)
        let runs = try await engine.transcribe(audio, language: language, progress: progress)
        try Task.checkCancellation()
        let words = TranscriptWords.trimmed(TranscriptWords.words(from: runs, origin: audio.origin), quiet: try await quiet)
        return Transcript(
            language: language, engine: SpeechLanguages.engineID,
            takes: [TranscriptTake(take: project.take.id, track: track.id, words: words)])
    }

    /// The track `transcribe` hears, with its audio in mono: the only one of `candidates(for:)`, or, of several (the
    /// take's system audio, one track for each app, without a microphone), the one with the most seconds that sound
    /// like speech (`SpeechAmount.seconds`), the first of them in the manifest when two have as many; `nil` without any.
    /// A take of phase 2 has one system audio track, and that one is heard, as then. The transcript keeps the words of
    /// one track of each take, so the others' are not heard (phase 3 design §7.1 and §8.1).
    /// - Throws: what `TrackAudio.load` and `SpeechAmount.seconds` throw.
    static func heardTrack(_ project: LoadedProject) async throws -> (TrackRecord, TrackAudio)? {
        let candidates = candidates(for: project.take)
        var best: (track: TrackRecord, audio: TrackAudio, seconds: Int)?
        for track in candidates {
            let audio = try await TrackAudio.load(project, track: track.id, channels: 1)
            guard candidates.count > 1 else { return (track, audio) }
            let seconds = try await SpeechAmount.seconds(audio)
            if best.map({ seconds > $0.seconds }) ?? true { best = (track, audio, seconds) }
        }
        return best.map { ($0.track, $0.audio) }
    }
}
