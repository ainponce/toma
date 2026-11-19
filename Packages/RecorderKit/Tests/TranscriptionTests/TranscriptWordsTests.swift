// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing
@testable import Transcription

private let origin = HostTime(nanoseconds: 7_000_000_000_000)

private func at(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

private func words(_ runs: [SpeechRun]) -> [TranscriptWord] {
    TranscriptWords.words(from: runs, origin: origin)
}

/// A run's pieces between spaces are its words, and the punctuation stays on the word it touches.
@Test func wordsSplitBySpacesKeepPunctuation() {
    let made = words([
        SpeechRun(text: "Hola,", start: 0, end: 0.5),
        SpeechRun(text: " ¿cómo", start: 0.5, end: 0.9),
        SpeechRun(text: " estás?", start: 0.9, end: 1.4),
    ])
    #expect(made == [
        TranscriptWord(start: at(0), end: at(0.5), text: "Hola,"),
        TranscriptWord(start: at(0.5), end: at(0.9), text: "¿cómo"),
        TranscriptWord(start: at(0.9), end: at(1.4), text: "estás?"),
    ])
    // Spaces of any kind split, and a run of only spaces is nothing.
    #expect(words([SpeechRun(text: "\tuno\n", start: 2, end: 3), SpeechRun(text: "  ", start: 3, end: 4)])
        == [TranscriptWord(start: at(2), end: at(3), text: "uno")])
}

/// A run of only punctuation joins the word before it, with that word's time; `¿` and `¡` join the next one, and so
/// does punctuation with no word before it.
@Test func punctuationOnlyRunsJoinTheWordBefore() {
    #expect(words([SpeechRun(text: "Listo", start: 1, end: 1.5), SpeechRun(text: ".", start: 1.5, end: 1.7)])
        == [TranscriptWord(start: at(1), end: at(1.5), text: "Listo.")])
    #expect(words([
        SpeechRun(text: "¿", start: 0.9, end: 1), SpeechRun(text: "Sí", start: 1, end: 1.4), SpeechRun(text: "?", start: 1.4, end: 1.5),
    ]) == [TranscriptWord(start: at(1), end: at(1.4), text: "¿Sí?")])
    #expect(words([SpeechRun(text: "Bueno ¡ya!", start: 0, end: 1)]).map(\.text) == ["Bueno", "¡ya!"])
    #expect(words([SpeechRun(text: "…", start: 0, end: 0.2), SpeechRun(text: "dale", start: 0.2, end: 0.6)])
        == [TranscriptWord(start: at(0.2), end: at(0.6), text: "…dale")])
    // Punctuation and nothing else gives no word.
    #expect(words([SpeechRun(text: "¿?", start: 0, end: 1)]).isEmpty)
}

/// A run with several words shares its time out by their letters and digits; punctuation weighs nothing.
@Test func multiWordRunSplitsItsTimeByLetters() {
    #expect(words([SpeechRun(text: "a bcd", start: 1, end: 2)]) == [
        TranscriptWord(start: at(1), end: at(1.25), text: "a"),
        TranscriptWord(start: at(1.25), end: at(2), text: "bcd"),
    ])
    let made = words([SpeechRun(text: "son 125, ¿no?", start: 0, end: 7)])
    #expect(made.map(\.text) == ["son", "125,", "¿no?"])
    #expect(made.map(\.start) == [at(0), at(3 * 7 / 8.0), at(6 * 7 / 8.0)])
    #expect(made.map(\.end) == [at(3 * 7 / 8.0), at(6 * 7 / 8.0), at(7)])
}

/// The pieces of a run without a time join the word before them after a space, or the next one when there is none.
@Test func untimedRunJoinsTheWordBefore() {
    #expect(words([SpeechRun(text: "uno", start: 0, end: 0.5), SpeechRun(text: "dos", start: nil, end: nil)])
        == [TranscriptWord(start: at(0), end: at(0.5), text: "uno dos")])
    #expect(words([SpeechRun(text: "uno", start: 0, end: 0.5), SpeechRun(text: "dos,", start: 1, end: nil)])
        == [TranscriptWord(start: at(0), end: at(0.5), text: "uno dos,")])
    #expect(words([
        SpeechRun(text: "cero uno", start: nil, end: nil), SpeechRun(text: ",", start: nil, end: nil),
        SpeechRun(text: "dos", start: 1, end: 2),
    ]) == [TranscriptWord(start: at(1), end: at(2), text: "cero uno, dos")])
    // What waits for the next word keeps its order: an opening `¿`, then a word without a time.
    #expect(words([
        SpeechRun(text: "uno", start: 0, end: 1), SpeechRun(text: "¿", start: 1, end: 1.1),
        SpeechRun(text: "qué", start: nil, end: nil), SpeechRun(text: "tal?", start: 1.5, end: 2),
    ]).map(\.text) == ["uno", "¿qué tal?"])
    // Nothing with a time: no word.
    #expect(words([SpeechRun(text: "nada", start: nil, end: nil)]).isEmpty)
}

/// The words are in the order of their times and never overlap; a second of a run is `origin` plus a second.
@Test func wordsAreOrderedAndNeverOverlap() {
    let made = words([
        SpeechRun(text: "uno", start: 0, end: 1),
        SpeechRun(text: "dos", start: 0.8, end: 1.5),
        SpeechRun(text: "tres", start: 1.6, end: 1.55),
        SpeechRun(text: "cero", start: -0.5, end: -0.1),
    ])
    #expect(made.map(\.text) == ["cero", "uno", "dos", "tres"])
    #expect(made.map(\.start) == [at(-0.5), at(0), at(1), at(1.6)])
    #expect(made.map(\.end) == [at(-0.1), at(1), at(1.5), at(1.6)])
    #expect(zip(made, made.dropFirst()).allSatisfy { $0.end <= $1.start && $0.start <= $0.end })
    #expect(at(1.25) == HostTime(nanoseconds: origin.nanoseconds + 1_250_000_000))
}

/// A word that starts or ends in a quiet span of the track leaves that quiet out, if something of it is left.
@Test func quietAtTheEdgesOfAWordIsLeftOut() {
    func word(_ start: Double, _ end: Double) -> TranscriptWord { TranscriptWord(start: at(start), end: at(end), text: "x") }
    let quiet = [at(0)..<at(1.5), at(3.75)..<at(7.25), at(9)..<at(9.5)]
    let trimmed = TranscriptWords.trimmed(
        [word(1, 2), word(2, 3.5), word(3.5, 4), word(6.5, 7.5), word(7.5, 9.5), word(9.1, 9.3), word(8.9, 9.6)], quiet: quiet)
    #expect(trimmed == [
        // Starts in the quiet before it.
        word(1.5, 2),
        // Nothing quiet at its edges.
        word(2, 3.5),
        // Ends in the pause after it.
        word(3.5, 3.75),
        // Starts in the pause before it.
        word(7.25, 7.5),
        // Ends in a quiet span, and to its end: up to where it starts.
        word(7.5, 9),
        // All quiet: as it was.
        word(9.1, 9.3),
        // A quiet span inside it is not an edge.
        word(8.9, 9.6),
    ])
    // A word that ends where a quiet span starts, or starts where one ends, is not in it.
    #expect(TranscriptWords.trimmed([word(1.5, 3.75)], quiet: quiet) == [word(1.5, 3.75)])
    #expect(TranscriptWords.trimmed([word(1, 2)], quiet: []) == [word(1, 2)])
}
