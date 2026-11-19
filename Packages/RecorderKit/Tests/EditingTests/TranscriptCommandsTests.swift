// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

// The words `w0`…`w9` of `BySource.transcribed()`, each `w_i` over [i s, i + 0.5 s), over one clip of the take at 1×.

/// `document` with the words `words` of the first take cut, as the text's ⌫ does.
private func cutting(_ words: ClosedRange<Int>, in document: EditDocument) throws -> EditDocument {
    let step = try #require(TranscriptCommands.cut(document, take: 0, words: words, makeID: BySource.newIDs)).get()
    #expect(step.label == .transcriptCut)
    return try BySource.applying(step, to: document)
}

// MARK: - Cut

@Test func cutRangeKeepsThePauseBefore() throws {
    let document = BySource.transcribed()
    #expect(TranscriptCommands.cutRange(document, take: 0, words: 3...4) == BySource.at(2.96)..<BySource.at(4.96))
    let edited = try cutting(3...4, in: document)
    #expect(BySource.cutWords(edited) == [3, 4])
    #expect(BySource.duration(edited) == 28_000_000_000)
    // The start never goes before host time 0.
    let early = BySource.document(
        words: [TranscriptWord(start: HostTime(nanoseconds: 10_000_000), end: HostTime(nanoseconds: 300_000_000), text: "Hola")])
    #expect(
        TranscriptCommands.cutRange(early, take: 0, words: 0...0)
            == HostTime(nanoseconds: 0)..<HostTime(nanoseconds: 500_000_000))
    // Out of the transcript, or without one: nothing.
    #expect(TranscriptCommands.cutRange(document, take: 1, words: 0...0) == nil)
    #expect(TranscriptCommands.cutRange(document, take: 0, words: 9...10) == nil)
    #expect(TranscriptCommands.cutRange(BySource.document(), take: 0, words: 0...0) == nil)
}

@Test func cutExtendsToTheNextKeptWord() throws {
    let document = try cutting(5...6, in: BySource.transcribed())
    #expect(TranscriptCommands.cutRange(document, take: 0, words: 3...4) == BySource.at(2.96)..<BySource.at(6.96))
    let edited = try cutting(3...4, in: document)
    #expect(BySource.cutWords(edited) == [3, 4, 5, 6])
    #expect(BySource.duration(edited) == 26_000_000_000)
}

@Test func cutOfTheLastWordEndsAfter200ms() throws {
    let document = BySource.transcribed()
    #expect(TranscriptCommands.cutRange(document, take: 0, words: 9...9) == BySource.at(8.96)..<BySource.at(9.7))
    // So it does when every word after the selection is cut.
    let tail = try cutting(8...9, in: document)
    #expect(BySource.cutWords(tail) == [8, 9])
    #expect(TranscriptCommands.cutRange(tail, take: 0, words: 6...7) == BySource.at(5.96)..<BySource.at(7.7))
}

@Test func cutOfCutWordsIsNil() throws {
    let edited = try cutting(3...4, in: BySource.transcribed())
    #expect(TranscriptCommands.cut(edited, take: 0, words: 3...4, makeID: BySource.newIDs) == nil)
    #expect(TranscriptCommands.cut(edited, take: 0, words: 4...4, makeID: BySource.newIDs) == nil)
    #expect(TranscriptCommands.cut(edited, take: 0, words: 3...5, makeID: BySource.newIDs) != nil)
    #expect(TranscriptCommands.cut(edited, take: 0, words: 8...12, makeID: BySource.newIDs) == nil)
    #expect(TranscriptCommands.cut(BySource.document(), take: 0, words: 0...0, makeID: BySource.newIDs) == nil)
}

@Test func cutOfWordsAcrossClipsAtTwoSpeeds() throws {
    // w4 over [4 s, 4.5 s) is half in a clip at 1× and half in one at 2×.
    let document = BySource.document(
        [BySource.clip(1, 0, 4.25), BySource.clip(2, 4.25, 30, speed: 2)], words: BySource.tenWords())
    let edited = try cutting(4...4, in: document)
    #expect(edited.sequence == [BySource.clip(1, 0, 3.96), BySource.clip(2, 4.96, 30, speed: 2)])
    #expect(BySource.cutWords(edited) == [4])
}

@Test func cutOfAWordStuckToThePrevious() throws {
    // "Hola" ends 20 ms before "mundo" starts: the cut of "mundo" takes 20 ms of its end, and "Hola" is still kept.
    let document = BySource.document(
        [BySource.clip(1, 0, 30)],
        words: [BySource.word("Hola", 0, 0.5), BySource.word("mundo", 0.52, 1), BySource.word("cruel", 1.5, 2)])
    #expect(TranscriptCommands.cutRange(document, take: 0, words: 1...1) == BySource.at(0.48)..<BySource.at(1.46))
    let second = try cutting(1...1, in: document)
    #expect(BySource.cutWords(second) == [1])
    // The cut of "Hola" goes to 40 ms before "mundo": its last 20 ms stay, "mundo" stays whole.
    let first = try cutting(0...0, in: document)
    #expect(BySource.cutWords(first) == [0])
    #expect(first.sequence == [BySource.clip(1, 0.48, 30)])
    // Both, one after the other, leave no piece shorter than a frame: only from "cruel" on.
    let both = try cutting(0...0, in: second)
    #expect(both.sequence.allSatisfy { TimeMap.outputDuration(of: $0) >= TimeMap.frameTime(1, frameRate: 60) })
    #expect(BySource.cutWords(both) == [0, 1])
}

// MARK: - Restore

@Test func restoreOnlyTheMiddleWord() throws {
    let document = BySource.transcribed()
    let edited = try cutting(3...5, in: document)
    #expect(BySource.cutWords(edited) == [3, 4, 5])
    let ids = BySource.CountingIDs()
    let step = try #require(
        TranscriptCommands.restore(edited, take: 0, words: 4...4, bounds: BySource.bounds, makeID: ids.make))
    #expect(step.label == .transcriptRestore)
    let restored = try BySource.applying(step, to: edited)
    #expect(BySource.cutWords(restored) == [3, 5])
    // The cut made `c-00000010` already: the new clip has the next id.
    #expect(restored.sequence == [BySource.clip(1, 0, 2.96), BySource.clip("c-00000011", 3.96, 4.96), edited.sequence[1]])
    // All three back are what the cut took, exactly.
    let all = try #require(TranscriptCommands.restore(edited, take: 0, words: 2...6, bounds: BySource.bounds, makeID: ids.make))
    let whole = try BySource.applying(all, to: edited)
    #expect(BySource.cutWords(whole) == [])
    #expect(BySource.spans(whole) == BySource.spans(document))
    // Words that are kept give nothing back.
    #expect(TranscriptCommands.restore(edited, take: 0, words: 6...8, bounds: BySource.bounds, makeID: ids.make) == nil)
}

@Test func restoreOfSeparateCutWordsIsOneStep() throws {
    let edited = try cutting(7...7, in: try cutting(2...2, in: BySource.transcribed()))
    #expect(BySource.cutWords(edited) == [2, 7])
    let step = try #require(
        TranscriptCommands.restore(edited, take: 0, words: 1...9, bounds: BySource.bounds, makeID: BySource.newIDs))
    let restored = try BySource.applying(step, to: edited)
    #expect(BySource.cutWords(restored) == [])
    #expect(BySource.spans(restored) == BySource.spans(BySource.transcribed()))
    // The last word goes back to 200 ms after its end, as its cut did.
    let last = try cutting(9...9, in: BySource.transcribed())
    let back = try #require(
        TranscriptCommands.restore(last, take: 0, words: 9...9, bounds: BySource.bounds, makeID: BySource.newIDs))
    #expect(BySource.spans(try BySource.applying(back, to: last)) == BySource.spans(BySource.transcribed()))
}

@Test func restoreAfterTheTakesStartWasTrimmed() throws {
    // The take's start trimmed to 40 ms before w3, at 2×: w1 goes back before it, at its speed, and w2 joins it.
    let document = BySource.document([BySource.clip(1, 2.96, 30, speed: 2)], words: BySource.tenWords())
    #expect(BySource.cutWords(document) == [0, 1, 2])
    let ids = BySource.CountingIDs()
    let one = try #require(TranscriptCommands.restore(document, take: 0, words: 1...1, bounds: BySource.bounds, makeID: ids.make))
    #expect(
        try BySource.applying(one, to: document).sequence == [
            BySource.clip("c-00000010", 0.96, 1.96, speed: 2), BySource.clip(1, 2.96, 30, speed: 2),
        ])
    let two = try #require(TranscriptCommands.restore(document, take: 0, words: 2...2, bounds: BySource.bounds, makeID: ids.make))
    #expect(try BySource.applying(two, to: document).sequence == [BySource.clip(1, 1.96, 30, speed: 2)])
    // Before the take's editable start, nothing comes back.
    let late = BySource.at(1)...BySource.at(30)
    let first = try #require(TranscriptCommands.restore(document, take: 0, words: 0...2, bounds: late, makeID: ids.make))
    #expect(try BySource.applying(first, to: document).sequence == [BySource.clip(1, 1, 30, speed: 2)])
}

// MARK: - Create, correct, break

@Test func createTurnsCaptionsOnTheFirstTime() throws {
    let document = BySource.document()
    #expect(document.transcript == nil && !document.captions.show)
    let transcript = try #require(BySource.transcribed().transcript)
    let step = try #require(TranscriptCommands.create(document, transcript))
    #expect(step.label == .transcriptCreate)
    #expect(step.target == "/transcript")
    #expect(
        step.changes == [
            .set(path: JSONPointer(components: ["transcript"]), before: .null, after: try JSONValue(encoding: transcript)),
            .set(path: JSONPointer(components: ["captions", "show"]), before: .bool(false), after: .bool(true)),
        ])
    let created = try BySource.applying(step, to: document)
    #expect(created.transcript == transcript)
    #expect(created.captions.show)
    // Again, with captions turned off since: only the transcript is replaced.
    var hidden = created
    hidden.captions.show = false
    var again = transcript
    again.takes[0].words[0].text = "Hola"
    let replace = try #require(TranscriptCommands.create(hidden, again))
    #expect(replace.changes.count == 1)
    let replaced = try BySource.applying(replace, to: hidden)
    #expect(replaced.transcript == again)
    #expect(!replaced.captions.show)
    // The same transcript: nothing.
    #expect(TranscriptCommands.create(created, transcript) == nil)
}

@Test func lostCorrectionsCountsTextAndBreaks() throws {
    let new = try #require(BySource.transcribed().transcript)
    #expect(TranscriptCommands.lostCorrections(new, new) == 0)
    var old = new
    old.takes[0].words[2].text = "Hola"
    old.takes[0].words[5].breakBefore = true
    #expect(TranscriptCommands.lostCorrections(old, new) == 2)
    // A word corrected and broken is one; a break on a word the new transcript does not have is one more.
    old.takes[0].words[2].breakBefore = true
    old.takes[0].words.append(BySource.word("extra", 20, 20.5, breakBefore: true))
    old.takes[0].words.append(BySource.word("otra", 21, 21.5))
    #expect(TranscriptCommands.lostCorrections(old, new) == 3)
}

@Test func correctSetsTheTextTrimmed() throws {
    let document = BySource.transcribed()
    let ref = TranscriptWordRef(take: 0, word: 2)
    let step = try #require(TranscriptCommands.correct(document, ref, text: "  Hola \n"))
    #expect(step.label == .transcriptWord)
    #expect(step.target == "/transcript/takes/0/words/2/text")
    #expect(
        step.changes == [
            .set(
                path: JSONPointer(components: ["transcript", "takes", "0", "words", "2", "text"]), before: .string("w2"),
                after: .string("Hola"))
        ])
    #expect(try BySource.applying(step, to: document).transcript?.takes[0].words[2].text == "Hola")
    for text in ["", " \n\t", "w2", " w2 "] {
        #expect(TranscriptCommands.correct(document, ref, text: text) == nil)
    }
    #expect(TranscriptCommands.correct(document, TranscriptWordRef(take: 0, word: 10), text: "Hola") == nil)
    #expect(TranscriptCommands.correct(BySource.document(), ref, text: "Hola") == nil)
}

@Test func toggleBreakAddsAndRemovesTheMember() throws {
    let document = BySource.transcribed()
    let ref = TranscriptWordRef(take: 0, word: 3)
    let path = JSONPointer(components: ["transcript", "takes", "0", "words", "3", "breakBefore"])
    let on = try #require(TranscriptCommands.toggleBreak(document, ref))
    #expect(on.label == .transcriptBreak)
    #expect(on.target == "/transcript/takes/0/words/3/breakBefore")
    #expect(on.changes == [.set(path: path, before: .null, after: .bool(true))])
    let broken = try BySource.applying(on, to: document)
    #expect(broken.transcript?.takes[0].words[3].breakBefore == true)
    let off = try #require(TranscriptCommands.toggleBreak(broken, ref))
    #expect(off.changes == [.set(path: path, before: .bool(true), after: .null)])
    let back = try BySource.applying(off, to: broken)
    #expect(back == document)
    let json = try #require(String(data: try ProjectJSON.encoder().encode(back), encoding: .utf8))
    #expect(!json.contains("breakBefore"))
    #expect(TranscriptCommands.toggleBreak(document, TranscriptWordRef(take: 1, word: 0)) == nil)
}

// MARK: - Fillers

@Test func fillersAreWholeWordsLowercasedWithoutPunctuation() {
    for text in ["Eh,", "ehh", "Mmm.", "eh", "ehm", "em", "emm", "mm", "mhm", "ah", "ahh", "¿Eh?", "¡Ah!"] {
        #expect(TranscriptCommands.isFiller(text, language: "es-MX"), "\(text)")
    }
    for text in ["eho", "hemos", "um", "a", "", "…"] {
        #expect(!TranscriptCommands.isFiller(text, language: "es-MX"), "\(text)")
    }
    for text in ["Um…", "uhh", "Hmm", "umm", "uh", "er", "erm", "mm", "mmm", "ah"] {
        #expect(TranscriptCommands.isFiller(text, language: "en-US"), "\(text)")
    }
    for text in ["umbrella", "eh", "hmmm"] {
        #expect(!TranscriptCommands.isFiller(text, language: "en-US"), "\(text)")
    }
    for text in ["eh", "um", "ah", "mm"] {
        #expect(!TranscriptCommands.isFiller(text, language: "pt-BR"), "\(text)")
    }
    #expect(TranscriptCommands.isFiller("eh", language: "es"))
    #expect(TranscriptCommands.isFiller("um", language: "en_GB"))
    #expect(TranscriptCommands.fillersID == "fillers-1")
}

@Test func removeFillersIsOneStepAndSkipsCutOnes() throws {
    let texts = ["Bueno,", "eh", "esto", "mmm", "es", "Eh,", "una", "prueba.", "Sí", "ah"]
    let document = try cutting(9...9, in: BySource.transcribed(texts))
    #expect(
        TranscriptCommands.fillers(in: document) == [
            TranscriptWordRef(take: 0, word: 1), TranscriptWordRef(take: 0, word: 3), TranscriptWordRef(take: 0, word: 5),
        ])
    let step = try #require(TranscriptCommands.removeFillers(document, makeID: BySource.newIDs)).get()
    #expect(step.label == .transcriptFillers)
    let edited = try BySource.applying(step, to: document)
    #expect(BySource.cutWords(edited) == [1, 3, 5, 9])
    // Each from 40 ms before it to 40 ms before the next word: a second each.
    #expect(BySource.duration(edited) == BySource.duration(document) - 3_000_000_000)
    #expect(TranscriptCommands.fillers(in: edited) == [])
    #expect(TranscriptCommands.removeFillers(edited, makeID: BySource.newIDs) == nil)
    // Two fillers one after the other are one cut.
    let two = BySource.transcribed(["Bueno,", "eh", "mmm", "esto", "es", "una", "prueba", "de", "voz", "fin"])
    let both = try BySource.applying(try #require(TranscriptCommands.removeFillers(two, makeID: BySource.newIDs)).get(), to: two)
    #expect(both.sequence == [BySource.clip(1, 0, 0.96), BySource.clip("c-00000010", 2.96, 30)])
    // In a language without fillers, none.
    #expect(TranscriptCommands.fillers(in: BySource.transcribed(texts, language: "pt-BR")) == [])
}

// MARK: - Pauses

@Test func pausesAreShortenedToFourTenths() throws {
    let document = BySource.document(
        [BySource.clip(1, 0, 30)],
        words: [BySource.word("Hola", 0, 0.5), BySource.word("a", 2, 2.5), BySource.word("todos", 3, 3.5)])
    #expect(TranscriptCommands.defaultPauseThreshold == 1_000_000_000)
    #expect(TranscriptCommands.pauseThresholds == [500_000_000, 1_000_000_000, 2_000_000_000])
    let pauses = TranscriptCommands.pauses(in: document, threshold: TranscriptCommands.defaultPauseThreshold)
    #expect(pauses == [SourceRange(take: BySource.takeID, start: BySource.at(0.7), end: BySource.at(1.8))])
    let step = try #require(TranscriptCommands.shortenPauses(document, threshold: 1_000_000_000, makeID: BySource.newIDs)).get()
    #expect(step.label == .transcriptPauses)
    let edited = try BySource.applying(step, to: document)
    let map = TimeMap(sequence: edited.sequence)
    let gap = try #require(map.output(atSource: BySource.at(2), take: BySource.takeID))
        - (try #require(map.output(atSource: BySource.at(0.5), take: BySource.takeID)))
    #expect(gap == 400_000_000)
    #expect(BySource.cutWords(edited) == [])
}

@Test func shortenedPausesAreNotCountedAgain() throws {
    let document = BySource.document(
        [BySource.clip(1, 0, 30)],
        words: [BySource.word("Hola", 0, 0.5), BySource.word("a", 2, 2.5), BySource.word("todos", 3, 3.5)])
    let edited = try BySource.applying(
        try #require(TranscriptCommands.shortenPauses(document, threshold: 1_000_000_000, makeID: BySource.newIDs)).get(),
        to: document)
    #expect(TranscriptCommands.pauses(in: edited, threshold: 1_000_000_000) == [])
    #expect(TranscriptCommands.shortenPauses(edited, threshold: 1_000_000_000, makeID: BySource.newIDs) == nil)
    // At half a second only the other one counts, the pause of 0.4 s left is not one.
    #expect(
        TranscriptCommands.pauses(in: edited, threshold: 500_000_000) == [
            SourceRange(take: BySource.takeID, start: BySource.at(2.7), end: BySource.at(2.8))
        ])
}

@Test func pauseThresholdIsInclusive() {
    let document = BySource.document(
        [BySource.clip(1, 0, 30)],
        words: [BySource.word("Hola", 0, 0.5), BySource.word("a", 1.5, 2), BySource.word("todos", 2.99, 3.5)])
    #expect(
        TranscriptCommands.pauses(in: document, threshold: 1_000_000_000) == [
            SourceRange(take: BySource.takeID, start: BySource.at(0.7), end: BySource.at(1.3))
        ])
    #expect(TranscriptCommands.pauses(in: document, threshold: 1_000_000_001) == [])
}

@Test func pausesCountOnlyWhatIsKept() throws {
    // Between kept words 0.5 s apart with a cut word between them, what is heard is 0.5 s: no pause of 1 s.
    let short = try cutting(5...5, in: BySource.transcribed())
    #expect(TranscriptCommands.pauses(in: short, threshold: 1_000_000_000) == [])
    // A word cut out of a long silence leaves the silence before it: that is a pause, and shortening it leaves 0.24 s.
    let long = try cutting(
        1...1,
        in: BySource.document(
            [BySource.clip(1, 0, 30)],
            words: [BySource.word("Hola", 0, 0.5), BySource.word("eh", 2, 2.5), BySource.word("todos", 4, 4.5)]))
    #expect(
        TranscriptCommands.pauses(in: long, threshold: 1_000_000_000) == [
            SourceRange(take: BySource.takeID, start: BySource.at(0.7), end: BySource.at(3.8))
        ])
    let edited = try BySource.applying(
        try #require(TranscriptCommands.shortenPauses(long, threshold: 1_000_000_000, makeID: BySource.newIDs)).get(), to: long)
    let map = TimeMap(sequence: edited.sequence)
    let gap = try #require(map.output(atSource: BySource.at(4), take: BySource.takeID))
        - (try #require(map.output(atSource: BySource.at(0.5), take: BySource.takeID)))
    #expect(gap == 240_000_000)
    // What is left of a pause that lasts less than a frame of output is not one: 0.25 s at 16× is 15.6 ms.
    func fast(_ speed: Double) -> EditDocument {
        BySource.document(
            [BySource.clip(1, 0, 0.7), BySource.clip(2, 0.7, 0.95, speed: speed), BySource.clip(3, 1.3, 30)],
            words: [BySource.word("Hola", 0, 0.5), BySource.word("a", 1.5, 2)])
    }
    #expect(TranscriptCommands.pauses(in: fast(16), threshold: 500_000_000) == [])
    #expect(
        TranscriptCommands.pauses(in: fast(8), threshold: 500_000_000) == [
            SourceRange(take: BySource.takeID, start: BySource.at(0.7), end: BySource.at(1.3))
        ])
}
