// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import Transcription

/// Which takes of a document's sequence are transcribed, and where its silences come from (phase 3 design §8.1, plan 3d
/// decisions 16 and 17): the editor's voice asks these, so the rules are here and not in the app. Pure: it reads nothing.
///
/// `shown` is the records of the takes the sequence shows, in the order it first shows each
/// (`SequenceAnalyses.takes(shownBy:in:)`). A take is transcribed from the track `Transcriber.track(for:)` picks; one
/// without any has nothing to hear and is left out of every list. With one take, each rule is the phase 2's.
public enum SequenceTranscription {
    /// The takes of `shown` with a track to transcribe, in its order.
    public static func transcribable(_ shown: [TakeRecord]) -> [String] {
        shown.filter { Transcriber.track(for: $0) != nil }.map(\.id)
    }

    /// What "Transcribe" (and "Transcribe Again") hears in `language` (BCP 47): each take of `transcribable(shown)` whose
    /// words the document's transcript does not have in `language` (every one without a transcript, or with one in
    /// another language), so what the user corrected in the others stays; when each has its own already, every one of
    /// them again. In `shown`'s order; none when nothing can be heard.
    public static func takes(toTranscribe document: EditDocument, shown: [TakeRecord], language: String) -> [String] {
        let all = transcribable(shown)
        let missing = all.filter { !has(document, take: $0, in: language) }
        return missing.isEmpty ? all : missing
    }

    /// What the transcription transcribes by itself as takes come into a transcribed sequence ("Transcribe
    /// Automatically"): each take of `transcribable(shown)` the transcript does not have, in its language. None without a
    /// transcript: a document of phase 2 is transcribed by itself only as it opens (`AutomaticTranscription`).
    public static func newTakes(_ document: EditDocument, shown: [TakeRecord]) -> [String] {
        guard let transcript = document.transcript else { return [] }
        return transcribable(shown).filter { !has(document, take: $0, in: transcript.language) }
    }

    /// Whether "Hide During Silences" finds the silences between the words that stay (`VoiceSilences.fromWords`): the
    /// transcript has the words of every take of `transcribable(shown)`. Otherwise they are where each take's first
    /// microphone is quiet (`VoiceSilences.fromQuiet(ofTakes:timeMap:)`), so a take not transcribed yet is never one long
    /// silence.
    public static func silencesFromWords(_ document: EditDocument, shown: [TakeRecord]) -> Bool {
        guard let transcript = document.transcript else { return false }
        let heard = Set(transcript.takes.map(\.take))
        return transcribable(shown).allSatisfy(heard.contains)
    }

    /// Whether the transcript of `document` is in `language` and has words of `take`.
    private static func has(_ document: EditDocument, take: String, in language: String) -> Bool {
        guard let transcript = document.transcript, bcp47(transcript.language) == bcp47(language) else { return false }
        return transcript.takes.contains { $0.take == take }
    }

    /// `identifier` as BCP 47: `es_MX` and `es-MX` are `es-MX`.
    private static func bcp47(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }
}
