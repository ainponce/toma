// SPDX-License-Identifier: GPL-3.0-or-later

/// Transcription (design of phase 2, §5.1 and §10): the words of an audio track of a take, with their source times,
/// from Speech on the Mac (`SpeechTranscriber` from macOS 26), decoded with `Export`'s `AudioTrackTimeline`.
///
/// An engine of the analysis queue: it is handed the files it reads and reports its progress, and knows nothing of the
/// project's caches or the queue (`ProjectJobs` runs it). What it makes is not a cache: it goes into the document
/// (`EditDocument.transcript`). Never called from the render or the mix. `Transcriber` transcribes a take with a
/// `SpeechEngine` (`SpeechTranscriberEngine`); `SpeechLanguages` lists the languages and gets their models;
/// `TranscriptWords` makes the words of what an engine heard.
enum TranscriptionModule {}
