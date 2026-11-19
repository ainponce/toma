// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

private typealias F = TranscriptFixtures
private func ns(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

@Suite struct CaptionLinesTests {
    @Test func capacityFollowsTheShape() {
        #expect(CaptionLines.capacity(outputSize: SIMD2(1920, 1080)) == (2, 42))
        #expect(CaptionLines.capacity(outputSize: SIMD2(1296, 1080)) == (2, 42))
        #expect(CaptionLines.capacity(outputSize: SIMD2(1080, 1080)) == (2, 32))
        #expect(CaptionLines.capacity(outputSize: SIMD2(972, 1080)) == (2, 32))
        #expect(CaptionLines.capacity(outputSize: SIMD2(1080, 1350)) == (1, 24))
        #expect(CaptionLines.capacity(outputSize: SIMD2(1080, 1920)) == (1, 24))
        #expect(CaptionLines.capacity(outputSize: SIMD2(1440, 1080)) == (2, 42))
    }

    @Test func newCaptionOnBreakGapPunctuationOrOverflow() {
        // A break the user asked for.
        let asked = F.document(words: [F.word("a", at: 0), F.word("b", at: 0.4), F.word("c", at: 0.8, breakBefore: true)])
        #expect(F.captions(asked).map(\.text) == ["a b", "c"])
        // A gap of 0.7 s breaks; one of 0.69 s does not.
        let gap = F.document(words: [F.word("a", at: 0), F.word("b", at: 1.0), F.word("c", at: 1.99)])
        #expect(F.captions(gap).map(\.text) == ["a", "b c"])
        // Closing punctuation.
        let closing = F.document(words: F.words(["listo.", "dos", "¿sí?", "tres", "¡ya!", "cuatro", "bueno…", "cinco"]))
        #expect(F.captions(closing).map(\.text) == ["listo.", "dos ¿sí?", "tres ¡ya!", "cuatro bueno…", "cinco"])
        // A word that does not fit: 12 words of 9 letters need 2 lines of 42 at most.
        let long = Array(repeating: "palabrota", count: 12)
        let overflow = F.captions(F.document(words: F.words(long)))
        #expect(overflow.map { $0.lines.flatMap { $0 }.count } == [8, 4])
        #expect(overflow[0].lines.map { $0.count } == [4, 4])
    }

    @Test func linesAreBalanced() {
        // 60 characters: "aaaaaaaaa" ×6 plus spaces is 59; they go in two balanced lines.
        let nine = F.captions(F.document(words: F.words(Array(repeating: "aaaaaaaaa", count: 6))))
        #expect(nine.count == 1)
        #expect(nine[0].lines.map(\.count) == [3, 3])
        #expect(nine[0].text == "aaaaaaaaa aaaaaaaaa aaaaaaaaa\naaaaaaaaa aaaaaaaaa aaaaaaaaa")
        // A tie goes to the shorter first line: "aa bb cc dd" has lines 2+... 5 words of 20 chars total.
        let tie = F.captions(F.document(words: F.words(["aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb", "cc"]), style: .default))
        #expect(tie[0].lines.map(\.count) == [1, 2])
        // Short text goes on one line.
        let short = F.captions(F.document(words: F.words(["hola", "mundo"])))
        #expect(short[0].lines.count == 1)
    }

    @Test func timingTailMinimumAndNoOverlap() {
        let document = F.document(words: [
            F.word("a", at: 1, length: 0.2), F.word("b", at: 1.9, length: 0.2), F.word("c", at: 2.2, length: 0.2),
        ])
        let captions = F.captions(document)
        // "a" alone: 0.2 s + 0.3 s tail is 0.5 s, so the 0.8 s minimum rules, but "b c" starts at 1.9 s (0.9 s later).
        #expect(captions[0].output == ns(1)..<ns(1.8))
        // "b c": ends at 2.4 s + 0.3 s.
        #expect(captions[1].output == ns(1.9)..<ns(2.7))
        // The tail never passes the next caption.
        let close = F.document(words: [F.word("a", at: 1, length: 0.2), F.word("b", at: 1.5, length: 0.2, breakBefore: true)])
        #expect(F.captions(close)[0].output == ns(1)..<ns(1.5))
    }

    @Test func lastCaptionEndsWithTheOutput() {
        let document = F.document(sequence: [F.clip(1, from: 0, to: 2)], words: [F.word("fin", at: 1.8, length: 0.2)])
        #expect(F.captions(document)[0].output == ns(1.8)..<ns(2))
    }

    @Test func cutWordsAreLeftOutAndHalfCutTrimmed() {
        let words = [F.word("uno", at: 0, length: 1), F.word("dos", at: 1, length: 1), F.word("tres", at: 2, length: 1)]
        // "uno" keeps 40% (out), "dos" keeps 30% (out), "tres" keeps 70% (in, from where its kept part starts).
        let document = F.document(
            sequence: [F.clip(1, from: 0, to: 0.4), F.clip(2, from: 1.0, to: 1.3), F.clip(3, from: 2.3, to: 30)], words: words)
        let captions = F.captions(document)
        #expect(captions.map(\.text) == ["tres"])
        // 0.4 + 0.3 s of the first two clips, then the kept 0.7 s of "tres".
        #expect(captions[0].lines[0][0].output.lowerBound == ns(0.7))
        // A word 60% kept stays, trimmed to its kept part.
        let half = F.document(
            sequence: [F.clip(1, from: 0, to: 0.6), F.clip(2, from: 1.0, to: 30)],
            words: [F.word("uno", at: 0, length: 1), F.word("dos", at: 1.0, length: 1)])
        let trimmed = F.captions(half)
        #expect(trimmed.map(\.text) == ["uno dos"])
        #expect(trimmed[0].lines[0][0].output.lowerBound == 0)
        #expect(trimmed[0].lines[0][1].output.lowerBound == ns(0.6))
    }

    @Test func wordLongerThanALineIsAloneOnIt() {
        let giant = String(repeating: "x", count: 50)
        let captions = F.captions(F.document(words: F.words(["antes", giant, "despues"])))
        #expect(captions.map(\.text) == ["antes", giant, "despues"])
    }

    @Test func uppercaseCountsForTheCapacity() {
        var style = CaptionStyle.default
        style.uppercase = true
        // "straße" is "STRASSE" (7) in German; 6 of them fill 6 × 7 + 5 = 47 > 42 as one line but fit as two.
        let words = F.words(Array(repeating: "straße", count: 6))
        let upper = F.captions(F.document(words: words, language: "de-DE", style: style))
        #expect(upper[0].text.hasPrefix("STRASSE STRASSE STRASSE\nSTRASSE"))
        // As written, 6 × 6 + 5 = 41 fits one line.
        let plain = F.captions(F.document(words: words, language: "de-DE"))
        #expect(plain[0].lines.count == 1)
    }

    @Test func verticalOutputHasOneLineOf24() {
        let words = F.words(["uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho"])  // 8 words, 38 characters
        let captions = F.captions(F.document(words: words), size: SIMD2(1080, 1920))
        #expect(captions.allSatisfy { $0.lines.count == 1 && $0.text.count <= 24 })
        #expect(captions.count == 2)
    }

    @Test func speedsCompressTheTimes() {
        let words = [F.word("uno", at: 0, length: 0.4), F.word("dos", at: 1.0, length: 0.4)]
        let document = F.document(sequence: [F.clip(1, from: 0, to: 30, speed: 2)], words: words)
        let captions = F.captions(document)
        // At 2× the gap is 0.3 s in the output, below 0.7 s: one caption.
        #expect(captions.map(\.text) == ["uno dos"])
        #expect(captions[0].output.lowerBound == 0)
        #expect(captions[0].lines[0][1].output.lowerBound == ns(0.5))
        // The same gap, 1.0 s − 0.4 s = 0.6 s at 1×, joins too; at 0.5× it is 1.2 s and breaks.
        let slow = F.document(sequence: [F.clip(1, from: 0, to: 30, speed: 0.5)], words: words)
        #expect(F.captions(slow).count == 2)
    }

    @Test func highlightGoesFromWordToWord() {
        let captions = F.captions(F.document(words: F.words(["uno", "dos", "tres"])))
        let words = captions[0].lines.flatMap { $0 }
        #expect(words[0].output == 0..<ns(0.4))
        #expect(words[1].output == ns(0.4)..<ns(0.8))
        #expect(words[2].output == ns(0.8)..<captions[0].output.upperBound)
    }

    @Test func noTranscriptOrNoWordsIsNoCaption() {
        var document = F.document(words: [])
        #expect(F.captions(document).isEmpty)
        document.transcript = nil
        #expect(F.captions(document).isEmpty)
        let allCut = F.document(sequence: [F.clip(1, from: 20, to: 30)], words: F.words(["a", "b"]))
        #expect(F.captions(allCut).isEmpty)
    }

    @Test func indexFindsTheCaptionAtATime() {
        let captions = F.captions(F.document(words: [F.word("a", at: 1), F.word("b", at: 5)]))
        #expect(CaptionLines.index(atOutput: ns(1.1), in: captions) == 0)
        #expect(CaptionLines.index(atOutput: ns(3), in: captions) == nil)
        #expect(CaptionLines.index(atOutput: ns(5), in: captions) == 1)
        #expect(CaptionLines.index(atOutput: 0, in: captions) == nil)
    }

    @Test func reservedHeightCoversTwoNominalLines() {
        let size = SIMD2(1920, 1080)
        let em = 0.06 * 1080
        let expected = 0.08 * 1080 + 2 * 1.2 * em + 2 * 0.35 * em
        #expect(abs(CaptionMetrics.reservedHeight(.default, outputSize: size) - expected) < 1e-9)
        #expect(CaptionMetrics.fontSize(.small, outputSize: size) == 0.045 * 1080)
        #expect(CaptionMetrics.fontSize(.large, outputSize: SIMD2(1080, 1920)) == 0.08 * 1080)
    }
}
