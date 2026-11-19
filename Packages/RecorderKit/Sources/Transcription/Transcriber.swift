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
    /// The track a take is transcribed from (plan decision 19): its first microphone that recorded a segment; without
    /// one, its first system audio that did; without it, its first device audio that did; `nil` if none did.
    public static func track(for take: TakeRecord) -> TrackRecord? {
        for kind in [TrackKind.microphone, .systemAudio, .deviceAudio] {
            if let track = take.tracks.first(where: { $0.kind == kind && !$0.segments.isEmpty }) { return track }
        }
        return nil
    }

    /// The transcript of `project`'s take, in `language` (BCP 47; `es_MX` is written `es-MX`), heard by `engine`.
    /// `progress` is the engine's, from 0 to 1.
    /// - Throws: `TranscriptionError.noAudio` if the take has no track to transcribe or nothing of it is heard; what
    ///   `TrackAudio.load` throws for its segments; what the engine throws; `CancellationError` if the task is
    ///   cancelled.
    public static func transcribe(
        _ project: LoadedProject, language: String, engine: any SpeechEngine, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        guard let track = track(for: project.take) else { throw TranscriptionError.noAudio }
        let language = SpeechLanguages.bcp47(language)
        let audio = try await TrackAudio.load(project, track: track.id, channels: 1)
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
}
