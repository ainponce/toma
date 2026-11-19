// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A made-up transcript of a take, for tests and screenshots that need words without Speech (phase 2 plan, Task A10):
/// the numbers in Spanish ("uno", "dos"…, sentences of twelve words, each with a capital and a period), every
/// twentieth word the filler "eh", over the take's segments of the track a transcription hears.
public enum FakeTranscript {
    /// The numbers the words say, in turn.
    static let numbers = [
        "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "once", "doce", "trece",
        "catorce", "quince", "dieciséis", "diecisiete", "dieciocho", "diecinueve", "veinte",
    ]
    /// The words of a sentence, after which a pause of `pause` comes.
    static let sentence = 12
    static let pause = 1.6
    /// Every this many words is the filler "eh".
    static let filler = 20

    /// The transcript of `take` in es-MX, `wordsPerSecond` words a second (each one three quarters of its place long)
    /// inside each segment of the track a transcription would hear (its first microphone with segments; else its first
    /// system audio, device audio, or any track with segments), from 0.3 s into each segment to its end. Empty words
    /// for a take without any segment that ended.
    public static func make(for take: TakeRecord, wordsPerSecond: Double = 2.5) -> Transcript {
        let kinds: [TrackKind] = [.microphone, .systemAudio, .deviceAudio]
        let track = kinds.lazy.compactMap { kind in take.tracks.first { $0.kind == kind && !$0.segments.isEmpty } }.first
            ?? take.tracks.first { !$0.segments.isEmpty }
        let step = 1 / max(wordsPerSecond, 0.1)
        var words: [TranscriptWord] = []
        var count = 0
        for segment in track?.segments ?? [] {
            guard let end = segment.endHostTime else { continue }
            var start = segment.startHostTime.adding(seconds: 0.3)
            while start.adding(seconds: step) <= end {
                let place = count % sentence
                var text = (count + 1) % filler == 0 ? "eh" : numbers[count % numbers.count]
                if place == 0 { text = text.prefix(1).uppercased() + text.dropFirst() }
                let closes = place == sentence - 1
                if closes { text += "." }
                words.append(TranscriptWord(start: start, end: start.adding(seconds: step * 0.75), text: text))
                count += 1
                start = start.adding(seconds: step + (closes ? pause : 0))
            }
        }
        let takes = track.map { [TranscriptTake(take: take.id, track: $0.id, words: words)] } ?? []
        return Transcript(language: "es-MX", engine: "speechTranscriber-1", takes: takes)
    }
}
