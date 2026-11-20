// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

private typealias F = TranscriptFixtures
private let script = ScriptFixtures.script
private func said(_ range: Range<Int>) -> [String] { ScriptFixtures.said(range) }

private func alignment(at position: Int = 0) -> TeleprompterAlignment {
    TeleprompterAlignment(script: script, at: position)
}

@Suite struct TeleprompterAlignmentTests {
    @Test func idAndConstantsAreFrozen() {
        #expect(TeleprompterAlignment.id == "teleprompterAlign-1")
        #expect(TeleprompterAlignment.minimumSimilarity == 0.75)
        #expect(TeleprompterAlignment.behind == 3)
        #expect(TeleprompterAlignment.ahead == 40)
        #expect(TeleprompterAlignment.bigJump == 5)
    }

    @Test func similarityIsOneMinusLevenshteinOverTheLongerLength() {
        #expect(TeleprompterAlignment.similarity("proyecto", "proyecto") == 1)
        #expect(TeleprompterAlignment.similarity("projecto", "proyecto") == 0.875)
        #expect(TeleprompterAlignment.similarity("casa", "cosa") == 0.75)
        #expect(TeleprompterAlignment.similarity("sol", "mar") == 0)
        #expect(TeleprompterAlignment.similarity("", "") == 1)
        #expect(TeleprompterAlignment.similarity("", "hola") == 0)
        #expect(TeleprompterAlignment.similarity("kitten", "sitting") == 1 - 3.0 / 7.0)
    }

    @Test func exactReadingAdvancesWordByWord() {
        var state = alignment()
        for index in 0..<120 {
            state.hear([script.words[index].text])
            #expect(state.position == index + 1)
        }
        // The end of the script is the end: nothing more to say.
        state.hear(["gracias", "hola"])
        #expect(state.position == 120)
    }

    @Test func readingIsTheSameInAnyChunking() {
        var whole = alignment(), pieces = alignment()
        whole.hear(said(0..<60))
        for chunk in stride(from: 0, to: 60, by: 7) { pieces.hear(said(chunk..<min(chunk + 7, 60))) }
        #expect(whole.position == 60 && pieces == whole)
    }

    @Test func heardWordsAreNormalizedLikeTheScript() {
        var state = alignment()
        state.hear(["Bienvenidos", "A", "ESTE", "Tutorial,", "sobre", "nuestra", "APLICACIÓN", "para", "grabar"])
        #expect(state.position == 9)
        state.hear(["aplicacion", "", "—"])  // empty words are ignored; "aplicacion" is behind
        #expect(state.position == 9)
    }

    @Test func misheardWordsWithinSimilarityAdvance() {
        var state = alignment(at: 0)
        state.hear(["bienvenidos", "a"])
        state.hear(["estes"])  // este: 4/5 = 0.8
        #expect(state.position == 3)
        state.hear(["tutoria"])  // tutorial: 0.875
        #expect(state.position == 4)
        var small = TeleprompterAlignment(script: ScriptWords("la cosa sube el mar"))
        small.hear(["casa"])  // "cosa" at 0.75 advances, "la" (0.25) is not a candidate
        #expect(small.position == 2)
        small.hear(["sol"])  // "sol" vs "sube" 0.25, nothing else close
        #expect(small.position == 2)
        small.hear(["mar"])  // "el mar" is 2 words ahead: within 5, so advances
        #expect(small.position == 5)
    }

    @Test func aWordBelowTheThresholdDoesNotMove() {
        var state = alignment()
        state.hear(["bienvenidas"])  // 10/11... bienvenidos vs bienvenidas: 1 of 11 edits, advances
        #expect(state.position == 1)
        state.hear(["ae"])  // "a" vs "ae": 0.5, no
        #expect(state.position == 1)
    }

    @Test func accentsAndPunctuationDoNotBlockAMatch() {
        var state = alignment(at: 5)  // next: "nuestra aplicación para grabar pantallas"
        state.hear(["Nuestra", "aplicacion"])
        #expect(state.position == 7)
    }

    @Test func adLibsDoNotMove() {
        var state = alignment(at: 20)
        state.hear(["bueno", "eh", "pues", "como", "decia", "ayer", "mi", "amigo", "pedro", "dijo"])
        #expect(state.position == 20)
        state.hear(["despues"])
        #expect(state.position == 21)  // "después" is word 20: reading goes on
    }

    @Test func repeatingAPhraseNeverGoesBack() {
        var state = alignment()
        state.hear(said(0..<30))
        #expect(state.position == 30)
        state.hear(said(27..<30))  // the last three again
        #expect(state.position == 30)
        state.hear(said(30..<33))
        #expect(state.position == 33)
        state.hear(said(28..<33))  // two behind, then the same word
        #expect(state.position == 33)
    }

    @Test func aRepetitionFartherThanTheWindowBehindDoesNotMoveEither() {
        var state = alignment()
        state.hear(said(0..<30))
        state.hear(said(10..<15))  // a retake of an earlier sentence: far behind, not ahead
        #expect(state.position == 30)
    }

    @Test func aJumpOfFiveWordsMovesAtOnce() {
        var state = alignment(at: 10)
        state.hear([script.words[15].text])  // skipped 5
        #expect(state.position == 16)
    }

    @Test func aJumpOfMoreThanFiveWordsNeedsTwoMatches() {
        var state = alignment(at: 10)
        state.hear([script.words[22].text])  // skipped 12
        #expect(state.position == 10)
        state.hear([script.words[23].text])  // and the one that follows it
        #expect(state.position == 24)

        var single = alignment(at: 10)
        single.hear([script.words[22].text, "eh"])  // the second heard word is not the next
        #expect(single.position == 10)
        single.hear([script.words[23].text])  // a lone word that is not confirmed by the one after
        #expect(single.position == 10)
    }

    @Test func aSkippedSentenceIsFollowedOnceTheSpeakerReadsOn() {
        var state = alignment()
        state.hear(said(0..<20))
        state.hear(said(30..<34))  // sentences 3 and 4 skipped entirely
        #expect(state.position == 34)
    }

    @Test func aBigJumpIsNotConfirmedByAnythingButTheNextWord() {
        var state = alignment(at: 10)
        state.hear([script.words[30].text, "este", script.words[31].text])
        // The candidate (30) was dropped by the word in between; "31" is itself a big jump waiting for 32.
        #expect(state.position == 10)
        state.hear([script.words[32].text])
        #expect(state.position == 33)
    }

    @Test func aJumpPastFortyWordsIsNotFound() {
        var state = alignment(at: 5)
        state.hear([script.words[50].text, script.words[51].text, script.words[52].text])  // 45 ahead
        #expect(state.position == 5)
        var inside = alignment(at: 5)
        inside.hear([script.words[44].text, script.words[45].text])  // 39 ahead: the last one inside
        #expect(inside.position == 46)
        var edge = alignment(at: 5)
        edge.hear([script.words[45].text, script.words[46].text])  // exactly 40 ahead is outside [p, p + 40)
        #expect(edge.position == 5)
    }

    @Test func theNearestMatchAheadWins() {
        let repeated = ScriptWords("hoy es lunes. hoy es martes. hoy es jueves.")
        var state = TeleprompterAlignment(script: repeated)
        state.hear(["hoy", "es", "martes"])  // "hoy" and "es" take the nearest ones; "martes" is 3 ahead
        #expect(state.position == 6)
        state.hear(["hoy", "es", "jueves"])
        #expect(state.position == 9)
    }

    @Test func volatileWordsMoveAheadAndFinalCommits() {
        var state = alignment(at: 4)
        let tentative = state.trying(said(4..<8))
        #expect(tentative.position == 8)
        #expect(state.position == 4)  // trying changes nothing
        // The final result differs from the volatile one: the confirmed position is the final's.
        state.hear(said(4..<6))
        #expect(state.position == 6)
        #expect(state.trying(said(6..<9)).position == 9)
        #expect(state.trying([]).position == state.position)
    }

    @Test func tryingNeverGoesBehindWhatIsConfirmed() {
        var state = alignment()
        state.hear(said(0..<25))
        for words in [[], ["eh"], said(0..<5), said(22..<24), ["zzz", "qqq"]] {
            #expect(state.trying(words).position >= state.position)
        }
    }

    @Test func aPendingJumpSurvivesTheTrial() {
        var state = alignment(at: 10)
        state.hear([script.words[22].text])
        #expect(state.trying([script.words[23].text]).position == 24)
        state.hear([script.words[23].text])
        #expect(state.position == 24)
    }

    @Test func startingPositionIsClamped() {
        #expect(TeleprompterAlignment(script: script, at: -3).position == 0)
        #expect(TeleprompterAlignment(script: script, at: 999).position == 120)
        var empty = TeleprompterAlignment(script: ScriptWords(""))
        empty.hear(["hola"])
        #expect(empty.position == 0)
    }

    @Test func sameInputSamePosition() {
        let heard = said(0..<12) + ["eh", "bueno"] + said(14..<40) + said(36..<44) + said(60..<64)
        var first = alignment(), second = alignment()
        first.hear(heard)
        second.hear(heard)
        #expect(first == second)
        #expect(first.position == second.position)
    }

    @Test func aLongReadingWithRecognitionNoiseFollowsTheSpeaker() {
        // Words the engine gets a little wrong, an ad lib, a repeated phrase and a skipped sentence.
        var heard = said(0..<18)
        heard[3] = "tutoria"
        heard[8] = "grabal"
        heard += ["bueno", "perdon"]
        heard += said(15..<18)  // repeated
        heard += said(18..<30)
        heard += said(40..<55)  // skips 10 words
        var state = alignment()
        state.hear(heard)
        #expect(state.position == 55)
    }
}

@Suite struct ScriptPositionTests {
    /// A transcript that reads the first `count` script words, 0.4 s apart, in a 30 s clip.
    private func document(reading count: Int, sequence: [Clip]? = nil) -> EditDocument {
        F.document(sequence: sequence, words: F.words(ScriptFixtures.said(0..<count)))
    }

    private func spoken(before seconds: Double, in document: EditDocument) -> [String] {
        ScriptPosition.spokenWords(
            before: Int64(seconds * 1e9), in: document, timeMap: TimeMap(sequence: document.sequence))
    }

    @Test func spokenWordsAreTheOnesThatEndBeforeTheCursor() {
        let doc = document(reading: 60)
        // Word k spans [0.4k, 0.4k + 0.3]; at 1.5 s words 0..<3 are over (word 3 ends at 1.5 s).
        #expect(spoken(before: 1.5, in: doc) == ScriptFixtures.said(0..<4))
        #expect(spoken(before: 1.49, in: doc) == ScriptFixtures.said(0..<3))
        #expect(spoken(before: 0, in: doc).isEmpty)
    }

    @Test func scriptPositionFromTheTranscriptBeforeThePlayhead() {
        let doc = document(reading: 60)
        let words = spoken(before: 14.8, in: doc)  // 37 words said
        #expect(words.count == 37)
        #expect(ScriptPosition.word(in: script, spoken: words) == 37)
        #expect(script.sentenceStart(of: 37) == 30)
    }

    @Test func noTranscriptStartsAtTheBeginning() {
        var doc = document(reading: 10)
        doc.transcript = nil
        let words = spoken(before: 20, in: doc)
        #expect(words.isEmpty)
        #expect(ScriptPosition.word(in: script, spoken: words) == 0)
        #expect(ScriptPosition.word(in: ScriptWords(""), spoken: ["hola"]) == 0)
    }

    @Test func cutWordsAreNotSpokenAndASkippedSentenceStillAligns() {
        // Cut the seconds [4, 8): words 10..<20 (a whole sentence) are gone from the output.
        let sequence = [F.clip(1, from: 0, to: 4), F.clip(2, from: 8, to: 30)]
        let doc = document(reading: 60, sequence: sequence)
        let all = ScriptPosition.spokenWords(
            before: .max, in: doc, timeMap: TimeMap(sequence: doc.sequence))
        #expect(all == ScriptFixtures.said(0..<10) + ScriptFixtures.said(20..<60))
        #expect(ScriptPosition.word(in: script, spoken: all) == 60)
        // At output 8.0 s (source 12 s): words 0..<10 and 20..<30 are over in the sequence.
        let before = spoken(before: 4.0 + (14.8 - 8.0), in: doc)
        #expect(ScriptPosition.word(in: script, spoken: before) == 37)
    }

    @Test func aWordRepeatedInTheTranscriptDoesNotGoBack() {
        let texts = ScriptFixtures.said(0..<20) + ScriptFixtures.said(15..<20) + ScriptFixtures.said(20..<30)
        let doc = F.document(words: F.words(texts))
        let all = spoken(before: 29, in: doc)
        #expect(ScriptPosition.word(in: script, spoken: all) == 30)
    }

    @Test func misrecognizedTranscriptWordsStillAlign() {
        var texts = ScriptFixtures.said(0..<40)
        texts[5] = "nuestro"  // nuestra
        texts[12] = "ventanas"  // ventana
        texts[25] = "xyz"  // nothing like it
        let doc = F.document(words: F.words(texts))
        #expect(ScriptPosition.word(in: script, spoken: spoken(before: 29, in: doc)) == 40)
    }

    @Test func theSentenceOfTheCursorIsWhereARerecordStarts() {
        let doc = document(reading: 60)
        func start(before seconds: Double) -> Int {
            script.sentenceStart(of: ScriptPosition.word(in: script, spoken: spoken(before: seconds, in: doc)))
        }
        #expect(start(before: 0) == 0)
        #expect(start(before: 14.8) == 30)  // in the middle of sentence 4 (words 30..<40)
        #expect(start(before: 16.0) == 40)  // words 0..<40 said: the sentence is over, the next begins
    }
}
