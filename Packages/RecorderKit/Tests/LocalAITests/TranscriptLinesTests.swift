// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Testing

@testable import LocalAI

@Suite struct TranscriptLinesTests {
    @Test func linesBreakAtSentencesPausesAndThirtyWords() {
        // "Hola." ends a line; a pause of 0.8 s ends one; a pause of 0.5 s does not.
        let words = AIFixtures.kept(
            ["Hola.", "Ahora", "vemos", "esto", "y", "aquello"], starts: [0, 0.3, 0.6, 1.7, 2.5, 2.8])
        let lines = TranscriptLines.make(words)
        #expect(lines.map(\.words) == [0..<1, 1..<3, 3..<6])
        #expect(lines.map(\.text) == ["Hola.", "Ahora vemos", "esto y aquello"])
        #expect(lines[1].output == AIFixtures.ns(0.3)..<AIFixtures.ns(0.9))

        // 35 words without a period: 30 and 5.
        let long = TranscriptLines.make(AIFixtures.kept((0..<35).map { "p\($0)" }))
        #expect(long.map(\.words) == [0..<30, 30..<35])
        #expect(TranscriptLines.maximumWords == 30)
        #expect(TranscriptLines.pauseBreak == 700_000_000)

        // A question, an exclamation and an ellipsis end one too; a pause of exactly 0.7 s ends one.
        let marks = TranscriptLines.make(
            AIFixtures.kept(["¿Listo?", "¡Vamos!", "Bueno…", "ya", "está"], starts: [0, 0.3, 0.6, 0.9, 1.9]))
        #expect(marks.map(\.words) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5])
        #expect(TranscriptLines.make([]).isEmpty)
    }

    @Test func aClosingQuoteStillEndsASentence() {
        let lines = TranscriptLines.make(
            AIFixtures.kept(["Dijo", "«listo.»", "Luego", "\"listo.)", "Y", "“fin.”", "Otra", "cosa"]))
        #expect(lines.map(\.words) == [0..<2, 2..<4, 4..<6, 6..<8])
        // A period inside the word, as in a number, does not.
        #expect(TranscriptLines.make(AIFixtures.kept(["Son", "3.5", "segundos"])).count == 1)
    }

    @Test func renderedLineHasItsNumberAndTime() {
        let line = TranscriptLine(
            words: 12..<16, text: "Primero abrimos la terminal", output: AIFixtures.ns(65.4)..<AIFixtures.ns(67))
        #expect(TranscriptLines.render(line) == "[12 @1:05] Primero abrimos la terminal")
        let late = TranscriptLine(words: 900..<901, text: "Fin.", output: AIFixtures.ns(3725)..<AIFixtures.ns(3726))
        #expect(TranscriptLines.render(late) == "[900 @62:05] Fin.")
        let first = TranscriptLine(words: 0..<1, text: "Hola.", output: 0..<AIFixtures.ns(0.3))
        #expect(TranscriptLines.render(first) == "[0 @0:00] Hola.")
    }

    @Test func aPartNeverPassesTheTokenBudget() async {
        // 400 lines of 3 to 12 words.
        var texts: [String] = []
        for line in 0..<400 {
            let count = 3 + line * 7 % 10
            texts += (0..<count).map { $0 == count - 1 ? "fin\(line)." : "w\($0)" }
        }
        let lines = TranscriptLines.make(AIFixtures.kept(texts))
        #expect(lines.count == 400)
        let model = FakeTextModel()
        let parts = await TranscriptLines.parts(lines, tokenBudget: 300, maximumWords: 2500, model: model)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { !$0.isEmpty })
        #expect(parts.flatMap { $0 } == lines)
        for (index, part) in parts.enumerated() {
            #expect(FakeTextModel.tokens(TranscriptLines.text(part)) <= 300)
            // Each part takes every line that fits.
            if index + 1 < parts.count {
                #expect(FakeTextModel.tokens(TranscriptLines.text(part + [parts[index + 1][0]])) > 300)
            }
        }
    }

    @Test func aPartNeverPassesTheWordCap() async {
        let lines = TranscriptLines.make(AIFixtures.kept((0..<4000).map { $0 % 10 == 9 ? "fin." : "w" }))
        #expect(lines.count == 400)
        let parts = await TranscriptLines.parts(lines, tokenBudget: 1_000_000, maximumWords: 2500, model: FakeTextModel())
        #expect(parts.map { $0.reduce(0) { $0 + $1.words.count } } == [2500, 1500])
    }

    @Test func aLineOverTheBudgetIsAPartOfItsOwn() async {
        let lines = TranscriptLines.make(
            AIFixtures.kept(["Corta."] + (0..<29).map { "larga\($0)" } + ["fin.", "Otra."]))
        #expect(lines.map(\.words.count) == [1, 30, 1])
        let parts = await TranscriptLines.parts(lines, tokenBudget: 20, maximumWords: 2500, model: FakeTextModel())
        #expect(parts.map(\.count) == [1, 1, 1])
    }
}
