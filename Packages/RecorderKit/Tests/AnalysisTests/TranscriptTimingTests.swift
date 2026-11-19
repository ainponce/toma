// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

private typealias F = TranscriptFixtures

@Suite struct TranscriptTimingTests {
    @Test func keptFractionAcrossClips() {
        let word = F.word("hola", at: 10, length: 0.4)
        let sequence = [F.clip(1, from: 0, to: 10.2), F.clip(2, from: 10.3, to: 30)]
        // 0.2 s of the first clip and 0.1 s of the second.
        #expect(abs(TranscriptTiming.keptFraction(of: word, take: F.takeID, in: sequence) - 0.75) < 1e-9)
        #expect(!TranscriptTiming.isCut(word, take: F.takeID, in: sequence))
        let cut = [F.clip(1, from: 0, to: 10.05), F.clip(2, from: 10.3, to: 30)]
        #expect(abs(TranscriptTiming.keptFraction(of: word, take: F.takeID, in: cut) - 0.375) < 1e-9)
        #expect(TranscriptTiming.isCut(word, take: F.takeID, in: cut))
        #expect(TranscriptTiming.isCut(word, take: "other", in: sequence))
    }

    @Test func zeroLengthWordIsCutWhenItsInstantIs() {
        let instant = F.word("eh", at: 5, length: 0)
        #expect(!TranscriptTiming.isCut(instant, take: F.takeID, in: [F.clip(1, from: 0, to: 10)]))
        #expect(TranscriptTiming.isCut(instant, take: F.takeID, in: [F.clip(1, from: 6, to: 10)]))
    }

    @Test func keptWordsAreInOutputOrderWithClosedCuts() {
        let words = F.words(["uno", "dos", "tres", "cuatro"])  // 0.0, 0.4, 0.8, 1.2
        // Cuts [0.3, 0.8): "dos" is gone and "tres" starts where "uno" ends plus 0.3 s.
        let document = F.document(sequence: [F.clip(1, from: 0, to: 0.3), F.clip(2, from: 0.8, to: 30)], words: words)
        let kept = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
        #expect(kept.map(\.text) == ["uno", "tres", "cuatro"])
        #expect(kept[0].output == 0..<300_000_000)
        #expect(kept[1].output == 300_000_000..<600_000_000)
        #expect(kept[2].ref == TranscriptWordRef(take: 0, word: 3))
        #expect(kept[2].output.lowerBound == 700_000_000)
    }

    @Test func noTranscriptHasNoKeptWords() {
        var document = F.document(words: [])
        document.transcript = nil
        #expect(TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence)).isEmpty)
    }

    @Test func refsAreOrderedByTakeThenWord() {
        #expect(TranscriptWordRef(take: 0, word: 9) < TranscriptWordRef(take: 1, word: 0))
        #expect(TranscriptWordRef(take: 1, word: 1) < TranscriptWordRef(take: 1, word: 2))
    }
}
