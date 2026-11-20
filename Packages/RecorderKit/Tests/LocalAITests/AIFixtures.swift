// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// Documents with one take and a transcript over it, for the suggesters (as `Tests/AnalysisTests/TranscriptFixtures`).
enum AIFixtures {
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)
    static let takeID = "take-001"
    static let second: Int64 = 1_000_000_000

    static func source(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

    static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

    static func word(_ text: String, at start: Double, length: Double = 0.3) -> TranscriptWord {
        TranscriptWord(start: source(start), end: source(start + length), text: text)
    }

    /// Sentences of 10 words of 0.3 s each, one every 4 s from 0 (so a pause of 1 s between two): sentence `s` says
    /// "Tema<s> dos tres … diez." and its first word is word `10 s`. As many as fit in `seconds`, or `sentences`.
    static func sentences(seconds: Double, sentences: Int? = nil) -> [TranscriptWord] {
        let count = sentences ?? Int(seconds / 4)
        let rest = ["dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez."]
        return (0..<count).flatMap { s in
            (["Tema\(s)"] + rest).enumerated().map { w, text in word(text, at: Double(s) * 4 + Double(w) * 0.3) }
        }
    }

    /// A take of `seconds` with `sentences(seconds:sentences:)` over it, in `language`.
    static func document(seconds: Double, sentences count: Int? = nil, language: String = "es-MX") -> EditDocument {
        document(seconds: seconds, words: sentences(seconds: seconds, sentences: count), language: language)
    }

    /// A take of `seconds` (or the clips `sequence`) with `words` over it.
    static func document(
        seconds: Double, words: [TranscriptWord], language: String = "es-MX", sequence: [Clip]? = nil
    ) -> EditDocument {
        var document = bare(sequence: sequence ?? [Clip(id: "c-00000001", take: takeID, start: source(0), end: source(seconds), speed: 1)])
        document.transcript = Transcript(
            language: language, engine: "speechTranscriber-1",
            takes: [TranscriptTake(take: takeID, track: "microphone-1", words: words)])
        return document
    }

    /// A document with no transcript.
    static func bare(sequence: [Clip]) -> EditDocument {
        let toma = DefaultStyle.toma
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60,
            sequence: sequence,
            screens: ScreenPlan(initial: [takeID: "display-1"], changes: []), style: toma.style, cursor: toma.cursor,
            zoom: ZoomPlan(show: true, auto: toma.zoomAuto, spring: toma.zoomSpring, motionBlur: 0.5, regions: [], suppressed: []),
            camera: CameraPlan(show: false, initial: [takeID: .default], changes: [], layout: .bubble, layouts: [], spring: CameraLayoutRules.spring),
            audio: AudioPlan(limiter: true, tracks: [:]))
    }

    /// Kept words as `TranscriptTiming` gives them: `texts[i]` from `starts[i]` s for `length` s, in one take.
    static func kept(_ texts: [String], starts: [Double], length: Double = 0.3) -> [KeptWord] {
        zip(texts, starts).enumerated().map { index, pair in
            KeptWord(
                ref: TranscriptWordRef(take: 0, word: index), text: pair.0,
                output: ns(pair.1)..<ns(pair.1 + length))
        }
    }

    /// `texts` one after another, `length` s each, from `from`.
    static func kept(_ texts: [String], from: Double = 0, length: Double = 0.3) -> [KeptWord] {
        kept(texts, starts: texts.indices.map { from + Double($0) * length }, length: length)
    }
}
