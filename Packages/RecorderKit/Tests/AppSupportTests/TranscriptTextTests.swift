// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

/// Documents with a take of 30 s and a transcript over it.
private enum Fixture {
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)
    static let takeID = "take-001"

    static func source(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

    static func clip(_ number: Int, from: Double, to: Double, take: String = takeID, speed: Double = 1) -> Clip {
        Clip(id: "c-0000000\(number)", take: take, start: source(from), end: source(to), speed: speed)
    }

    static func word(_ text: String, at start: Double, length: Double = 0.3, breakBefore: Bool = false) -> TranscriptWord {
        TranscriptWord(start: source(start), end: source(start + length), text: text, breakBefore: breakBefore)
    }

    /// Words of 0.3 s every 0.4 s from `from`.
    static func words(_ texts: [String], from: Double = 0) -> [TranscriptWord] {
        texts.enumerated().map { word($1, at: from + Double($0) * 0.4) }
    }

    static func document(sequence: [Clip]? = nil, words: [TranscriptWord], takes more: [TranscriptTake] = []) -> EditDocument {
        let toma = DefaultStyle.toma
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60,
            sequence: sequence ?? [clip(1, from: 0, to: 30)],
            screens: ScreenPlan(initial: [takeID: "display-1"], changes: []), style: toma.style, cursor: toma.cursor,
            zoom: ZoomPlan(show: true, auto: toma.zoomAuto, spring: toma.zoomSpring, motionBlur: 0.5, regions: [], suppressed: []),
            camera: CameraPlan(show: false, initial: [takeID: .default], changes: [], layout: .bubble, layouts: [], spring: CameraLayoutRules.spring),
            audio: AudioPlan(limiter: true, tracks: [:]),
            transcript: Transcript(
                language: "es-MX", engine: "speechTranscriber-1",
                takes: [TranscriptTake(take: takeID, track: "microphone-1", words: words)] + more),
            captions: CaptionPlan(show: true, style: .default))
    }

    static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }
}

private typealias F = Fixture

@Suite struct TranscriptTextTests {
    /// A source gap of 1.5 s or more from the word before starts a paragraph; one shorter, a space.
    @Test func paragraphsAtPausesOfOneAndAHalfSeconds() {
        // "uno" ends at 0.3; "dos" 1.5 s later; "tres" 1.49 s after "dos" ends.
        let words = [F.word("uno", at: 0), F.word("dos", at: 1.8), F.word("tres", at: 3.59)]
        let text = TranscriptText(document: F.document(words: words))
        #expect(text.string == "uno\n\ndos tres")
        #expect(text.words.map(\.characters) == [0..<3, 5..<8, 9..<13])
        #expect(text.words.map(\.ref) == (0..<3).map { TranscriptWordRef(take: 0, word: $0) })
        #expect(TranscriptText.paragraphPause == 1_500_000_000)
    }

    /// A range inside two words is those two, whole; one only of spaces is none; a click inside a word is that word.
    @Test func selectionSnapsToWholeWords() {
        let text = TranscriptText(document: F.document(words: F.words(["uno", "dos", "tres"])))
        #expect(text.string == "uno dos tres")
        #expect(text.words(inCharacters: 1..<5) == 0...1)
        #expect(text.words(inCharacters: 2..<11) == 0...2)
        #expect(text.words(inCharacters: 3..<4) == nil)
        #expect(text.words(inCharacters: 9..<9) == 2...2)
        #expect(text.words(inCharacters: 3..<3) == nil)
        #expect(text.words(inCharacters: 0..<0) == 0...0)
        #expect(text.words(inCharacters: 12..<12) == nil)
        #expect(text.words(inCharacters: 40..<50) == nil)
        #expect(text.word(atCharacter: 4) == TranscriptWordRef(take: 0, word: 1))
        #expect(text.word(atCharacter: 7) == nil)
        #expect(text.word(atCharacter: -1) == nil)
    }

    /// A word less than half of which stays in the sequence is marked cut, over the range of its text, which stays in the
    /// string; a word with `breakBefore` is marked too.
    @Test func cutWordsAreMarked() {
        let words = [F.word("uno", at: 0), F.word("dos", at: 0.4, breakBefore: true), F.word("tres", at: 0.8)]
        // [0.35, 0.75) is cut: "dos" keeps 0.05 of its 0.3 s.
        let document = F.document(sequence: [F.clip(1, from: 0, to: 0.35), F.clip(2, from: 0.75, to: 30)], words: words)
        let text = TranscriptText(document: document)
        #expect(text.string == "uno dos tres")
        #expect(text.words.map(\.isCut) == [false, true, false])
        #expect(text.words[1].characters == 4..<7)
        #expect(text.words.map(\.breakBefore) == [false, true, false])
        #expect(text.hasCut(0...2))
        #expect(!text.hasCut(2...2))
        #expect(text.hasKept(0...1))
        #expect(!text.hasKept(1...1))
    }

    /// The words a range snaps to, as characters, cover the range wherever it falls in a word.
    @Test func charactersRoundTrip() {
        let text = TranscriptText(document: F.document(words: F.words(["uno", "dos", "tres", "cuatro"])))
        for range in [1..<9, 0..<3, 4..<5, 2..<18, 8..<12, 13..<14] {
            guard let words = text.words(inCharacters: range) else {
                Issue.record("\(range) snapped to nothing")
                continue
            }
            let characters = text.characters(of: words)
            #expect(characters.lowerBound <= range.lowerBound)
            #expect(characters.upperBound >= range.upperBound)
            // Snapping what it snapped to gives the same words.
            #expect(text.words(inCharacters: characters) == words)
            #expect(text.string.utf16.count >= characters.upperBound)
        }
        #expect(text.characters(of: 1...2) == 4..<12)
    }

    /// Ranges are UTF-16 code units, as `NSString` counts them: an emoji is two.
    @Test func surrogatesCountAsUTF16() {
        let text = TranscriptText(document: F.document(words: F.words(["😀", "hola"])))
        #expect(text.string == "😀 hola")
        #expect(text.words[0].characters == 0..<2)
        #expect(text.words[1].characters.lowerBound == 3)
        #expect(text.word(atCharacter: 1) == TranscriptWordRef(take: 0, word: 0))
        #expect(text.word(atCharacter: 3) == TranscriptWordRef(take: 0, word: 1))
    }

    /// A line break inside a word's text shows as a space, so no paragraph comes from a correction.
    @Test func lineBreaksInAWordShowAsSpaces() {
        let text = TranscriptText(document: F.document(words: [F.word("uno\ndos", at: 0), F.word("tres", at: 0.4)]))
        #expect(text.string == "uno dos tres")
        #expect(text.words.map(\.characters) == [0..<7, 8..<12])
    }

    /// Each take of the transcript starts a paragraph; a word is found by its place, and a selection over two takes
    /// is one run of words for each.
    @Test func takesAreParagraphsAndRuns() {
        let second = TranscriptTake(
            take: "take-002", track: "microphone-1", words: [F.word("cinco", at: 0), F.word("seis", at: 0.4)])
        let text = TranscriptText(
            document: F.document(
                sequence: [F.clip(1, from: 0, to: 30), F.clip(2, from: 0, to: 30, take: "take-002")],
                words: F.words(["uno", "dos", "tres"]), takes: [second]))
        #expect(text.string == "uno dos tres\n\ncinco seis")
        #expect(text.takes == [0, 1])
        #expect(text.takeStarts == [0, 3])
        #expect(text.index(of: TranscriptWordRef(take: 1, word: 1)) == 4)
        #expect(text.index(of: TranscriptWordRef(take: 0, word: 3)) == nil)
        #expect(text.index(of: TranscriptWordRef(take: 2, word: 0)) == nil)
        #expect(
            text.takeRuns(1...4)
                == [TranscriptText.TakeRun(take: 0, words: 1...2), TranscriptText.TakeRun(take: 1, words: 0...1)])
        #expect(text.takeRuns(3...3) == [TranscriptText.TakeRun(take: 1, words: 0...0)])
    }

    /// The takes go in the order the sequence first shows each, whatever the order of the transcript: a word is still
    /// found by its place in the transcript, and a selection is still a run of each take.
    @Test func textFollowsTheSequenceOrder() {
        let second = TranscriptTake(
            take: "take-002", track: "microphone-1", words: [F.word("cinco", at: 0), F.word("seis", at: 2)])
        // take-002, then take-001, then take-002 again.
        let sequence = [
            F.clip(1, from: 0, to: 1, take: "take-002"), F.clip(2, from: 0, to: 30), F.clip(3, from: 1, to: 30, take: "take-002"),
        ]
        let document = F.document(sequence: sequence, words: F.words(["uno", "dos", "tres"]), takes: [second])
        let text = TranscriptText(document: document)
        #expect(text.string == "cinco\n\nseis\n\nuno dos tres")
        #expect(text.takes == [1, 0])
        #expect(text.takeStarts == [0, 2])
        #expect(text.words.map(\.ref) == [
            TranscriptWordRef(take: 1, word: 0), TranscriptWordRef(take: 1, word: 1), TranscriptWordRef(take: 0, word: 0),
            TranscriptWordRef(take: 0, word: 1), TranscriptWordRef(take: 0, word: 2),
        ])
        #expect(text.index(of: TranscriptWordRef(take: 0, word: 0)) == 2)
        #expect(text.index(of: TranscriptWordRef(take: 1, word: 1)) == 1)
        #expect(text.index(of: TranscriptWordRef(take: 1, word: 2)) == nil)
        #expect(
            text.takeRuns(1...3)
                == [TranscriptText.TakeRun(take: 1, words: 1...1), TranscriptText.TakeRun(take: 0, words: 0...1)])
        // A pause of take-001 after "dos" is marked after it, where the text has it now.
        let pause = SourceRange(take: "take-001", start: F.source(0.5), end: F.source(0.6))
        #expect(text.wordsBefore(pauses: [pause], in: document) == [3])
    }

    /// A take the sequence does not show is not in the text, though the transcript has it.
    @Test func unusedTakesAreLeftOut() {
        let second = TranscriptTake(
            take: "take-002", track: "microphone-1", words: [F.word("cinco", at: 0), F.word("seis", at: 0.4)])
        let document = F.document(words: F.words(["uno", "dos", "tres"]), takes: [second])
        let text = TranscriptText(document: document)
        #expect(text.string == "uno dos tres")
        #expect(text.takes == [0])
        #expect(text.takeStarts == [0])
        #expect(text.words.map(\.ref.take) == [0, 0, 0])
        #expect(text.index(of: TranscriptWordRef(take: 1, word: 0)) == nil)
        #expect(text.wordsBefore(pauses: [SourceRange(take: "take-002", start: F.source(0.3), end: F.source(0.4))], in: document) == [])
        // Shown again later, it is back, after the take that is first.
        var shown = document
        shown.sequence.append(F.clip(2, from: 0, to: 1, take: "take-002"))
        #expect(TranscriptText(document: shown).string == "uno dos tres\n\ncinco seis")
    }

    /// The documents of the phase 2, of one take: the text of then, character for character.
    @Test func oneTakeIsTheTextOfToday() {
        let words = [
            F.word("uno", at: 0), F.word("dos", at: 0.4, breakBefore: true), F.word("tres\ncuatro", at: 0.8), F.word("cinco", at: 3),
        ]
        // [0.35, 0.75) is cut: "dos" keeps 0.05 of its 0.3 s.
        let document = F.document(sequence: [F.clip(1, from: 0, to: 0.35), F.clip(2, from: 0.75, to: 30)], words: words)
        let text = TranscriptText(document: document)
        #expect(text.string == "uno dos tres cuatro\n\ncinco")
        #expect(
            text.words == [
                TranscriptText.Word(ref: TranscriptWordRef(take: 0, word: 0), characters: 0..<3, isCut: false),
                TranscriptText.Word(ref: TranscriptWordRef(take: 0, word: 1), characters: 4..<7, isCut: true, breakBefore: true),
                TranscriptText.Word(ref: TranscriptWordRef(take: 0, word: 2), characters: 8..<19, isCut: false),
                TranscriptText.Word(ref: TranscriptWordRef(take: 0, word: 3), characters: 21..<26, isCut: false),
            ])
        #expect(text.takes == [0])
        #expect(text.takeStarts == [0])
        #expect(text.index(of: TranscriptWordRef(take: 0, word: 3)) == 3)
        #expect(text.takeRuns(0...3) == [TranscriptText.TakeRun(take: 0, words: 0...3)])
    }

    /// No transcript, no text.
    @Test func noTranscriptIsEmpty() {
        var document = F.document(words: [])
        document.transcript = nil
        let text = TranscriptText(document: document)
        #expect(text.string.isEmpty)
        #expect(text.words.isEmpty)
        #expect(text.words(inCharacters: 0..<0) == nil)
    }

    /// The word being said goes from its start until the next one starts, but no longer than a second after its end;
    /// before the first, none.
    @Test func playingWordFollowsTheOutput() {
        let words = [F.word("uno", at: 1), F.word("dos", at: 1.5), F.word("tres", at: 5)]
        let document = F.document(words: words)
        let kept = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
        func playing(_ seconds: Double) -> Int? { TranscriptText.playingWord(atOutput: F.ns(seconds), in: kept)?.word }
        #expect(playing(0.5) == nil)
        #expect(playing(1) == 0)
        #expect(playing(1.4) == 0)
        #expect(playing(1.5) == 1)
        #expect(playing(2.7) == 1)
        #expect(playing(2.8) == nil)
        #expect(playing(5.1) == 2)
        #expect(TranscriptText.playingWord(atOutput: 0, in: []) == nil)
    }

    /// A click on a word puts the playhead where it is seen; on a cut one, at the first instant kept after it.
    @Test func seekingGoesToTheWordOrAfterItsCut() {
        let words = [F.word("uno", at: 0), F.word("dos", at: 0.4), F.word("tres", at: 0.8)]
        // [0.35, 0.75) is cut.
        let document = F.document(sequence: [F.clip(1, from: 0, to: 0.35), F.clip(2, from: 0.75, to: 30)], words: words)
        let map = TimeMap(sequence: document.sequence)
        #expect(TranscriptText.seekOutput(of: TranscriptWordRef(take: 0, word: 0), in: document, timeMap: map) == 0)
        // "dos" ends at 0.7, inside the cut: the clip after it, at output 0.35.
        #expect(TranscriptText.seekOutput(of: TranscriptWordRef(take: 0, word: 1), in: document, timeMap: map) == F.ns(0.35))
        #expect(TranscriptText.seekOutput(of: TranscriptWordRef(take: 0, word: 2), in: document, timeMap: map) == F.ns(0.4))
        #expect(TranscriptText.seekOutput(of: TranscriptWordRef(take: 0, word: 3), in: document, timeMap: map) == nil)
        // The first frame of the grid at or after an instant, within the frames.
        #expect(TranscriptText.firstFrame(atOrAfter: F.ns(0.35), frameRate: 60, frameCount: 100) == 21)
        #expect(TranscriptText.firstFrame(atOrAfter: 0, frameRate: 60, frameCount: 100) == 0)
        #expect(TranscriptText.firstFrame(atOrAfter: F.ns(10), frameRate: 60, frameCount: 100) == 99)
    }

    /// Each pause "Shorten Pauses" would cut is marked after the word kept before it, past the cut words inside it.
    @Test func pausesAreMarkedAfterTheWordBefore() {
        let words = [
            F.word("uno", at: 0), F.word("dos", at: 2), F.word("tres", at: 2.4), F.word("cuatro", at: 5), F.word("cinco", at: 5.4),
        ]
        // "tres" keeps 0.1 of its 0.3 s, so it is cut: the pause after "dos" goes on to "cuatro" and starts after "tres" starts.
        let document = F.document(sequence: [F.clip(1, from: 0, to: 2.5), F.clip(2, from: 3, to: 30)], words: words)
        let text = TranscriptText(document: document)
        let pauses = TranscriptCommands.pauses(in: document, threshold: 1_000_000_000)
        #expect(pauses.count == 2)
        #expect(text.wordsBefore(pauses: pauses, in: document) == [0, 1])
        #expect(text.wordsBefore(pauses: [SourceRange(take: "other", start: F.source(1), end: F.source(2))], in: document) == [])
    }
}

/// What the Captions tab makes again with each change of the transcript or the clips, for an hour of speech (9 000 words,
/// one every 0.4 s, a pause of 2 s every 20, a filler every 25), cut by 60 clips: the text, the words kept, the fillers,
/// the pauses and the words before them; and what it reads ten times a second while playing (the word being said) and
/// at each click (the word under it). Median of 5 after one to warm up. Run by an agent, with `TOMA_BENCH=1`, in release.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func transcriptTextOfAnHourBench() {
    let texts = ["Hoy", "vamos", "a", "grabar", "la", "pantalla", "con", "subtítulos", "en", "español,"]
    var start = 0.0
    let words = (0..<9000).map { index -> TranscriptWord in
        defer { start += index % 20 == 19 ? 2.4 : 0.4 }
        return F.word(index % 25 == 24 ? "eh" : texts[index % 10], at: start, length: 0.3)
    }
    // 60 clips of an hour with a cut of 0.5 s between each two.
    let clips = (0..<60).map { F.clip($0, from: Double($0) * 70, to: Double($0) * 70 + 69.5) }
    let document = F.document(sequence: clips, words: words)
    var made: [Double] = []
    var lookups: [Double] = []
    var counts = (words: 0, kept: 0, fillers: 0, pauses: 0)
    for run in 0..<6 {
        let begin = DispatchTime.now().uptimeNanoseconds
        let text = TranscriptText(document: document)
        let kept = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
        let fillers = TranscriptCommands.fillers(in: document).compactMap(text.index(of:))
        let pauses = TranscriptCommands.pauses(in: document, threshold: 1_000_000_000)
        let before = text.wordsBefore(pauses: pauses, in: document)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
        // A minute of playing at ten readings a second, and a thousand clicks.
        let lookupBegin = DispatchTime.now().uptimeNanoseconds
        var found = 0
        for tick in 0..<600 where TranscriptText.playingWord(atOutput: Int64(tick) * 100_000_000, in: kept).flatMap(text.index(of:)) != nil {
            found += 1
        }
        for click in 0..<1000 where text.words(inCharacters: (click * 37)..<(click * 37)) != nil { found += 1 }
        let lookup = Double(DispatchTime.now().uptimeNanoseconds - lookupBegin) / 1e6
        if run > 0 {
            made.append(elapsed)
            lookups.append(lookup)
        }
        counts = (text.words.count, kept.count, fillers.count, before.count)
        #expect(found > 0)
    }
    print(
        String(
            format: "transcript text of an hour: median %.1f ms (runs %@); 600 playing words and 1000 clicks %.2f ms; %d words, %d kept, %d fillers, %d pauses",
            made.sorted()[2], made.map { String(format: "%.1f", $0) }.joined(separator: ", "), lookups.sorted()[2], counts.words,
            counts.kept, counts.fillers, counts.pauses))
    #expect(counts.words == 9000)
}
