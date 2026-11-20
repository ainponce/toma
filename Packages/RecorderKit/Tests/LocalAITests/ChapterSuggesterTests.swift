// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Testing

@testable import LocalAI

@Suite struct ChapterSuggesterTests {
    private func ns(_ seconds: Double) -> Int64 { AIFixtures.ns(seconds) }

    /// Proposes `chapters` (word index, title) to every request.
    private func proposing(_ chapters: [(Int, String)]) -> FakeTextModel.ChapterAnswer {
        { _ in .success(chapters.map { ProposedChapter(title: $0.1, firstWordIndex: $0.0) }) }
    }

    private func suggester(_ model: FakeTextModel) -> ChapterSuggester { ChapterSuggester(model: model, busyDelay: .zero) }

    @Test func chaptersStartAtTheirLineAndTheFirstAtZero() async throws {
        // 4 min of sentences every 4 s; line `s` starts at word 10 s, at 4 s s, after a pause of 1 s.
        let document = AIFixtures.document(seconds: 240)
        let model = FakeTextModel(chapters: [proposing([(50, "«1. Instalación.»"), (100, "Configurar"), (300, "Probar")])])
        let result = try await suggester(model).suggest(document: document)
        // Word 50 starts at 20 s: under 30 s, so at 0. Words 100 and 300 at 40 s and 120 s, each moved to the middle of
        // its pause of 1 s.
        #expect(result.chapters.map(\.output) == [0, ns(39.5), ns(119.5)])
        #expect(result.chapters.map(\.title) == ["Instalación", "Configurar", "Probar"])
        #expect(result.chapters.map(\.word) == [50, 100, 300].map { TranscriptWordRef(take: 0, word: $0) })
        #expect(result.parts == 1)
        #expect(result.skippedParts == 0)
        #expect(result.language == "es-MX")
        #expect(result.asChapters == [Chapter(start: 0, title: "Instalación"), Chapter(start: ns(39.5), title: "Configurar"),
                                       Chapter(start: ns(119.5), title: "Probar")])
        // The prompt carries every line with its number and time.
        let prompt = try #require(model.requests.first?.prompt)
        #expect(prompt.contains("[0 @0:00] Tema0 dos tres cuatro cinco seis siete ocho nueve diez."))
        #expect(prompt.contains("[590 @3:56] Tema59 dos"))
    }

    @Test func startMovesBackToTheSilenceAtMostOneAndAHalfSeconds() async throws {
        let spec: [(String, Double)] = [
            ("Hola", 0), ("todos.", 0.3),
            ("Primero", 38.4), ("esto.", 38.7),  // ends at 39.0
            ("Ahora", 40), ("aquello.", 40.3),  // 2 words: a pause of 1 s before
            ("Antes", 74.4), ("final.", 74.7),  // ends at 75.0
            ("Luego", 80), ("otro.", 80.3),  // a pause of 5 s before
            ("Seguimos", 118.2), ("con", 118.5), ("esto", 118.8), ("muy", 119.1), ("bien", 119.4), ("aquí.", 119.7),
            ("Después", 120), ("más.", 120.3),  // no pause within 1.5 s before
        ]
        let words = spec.map { AIFixtures.word($0.0, at: $0.1) }
        let document = AIFixtures.document(seconds: 180, words: words)
        let model = FakeTextModel(chapters: [proposing([(4, "Uno"), (8, "Dos"), (16, "Tres")])])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.chapters.map(\.output) == [ns(39.5), ns(78.5), ns(120)])
    }

    @Test func aPauseInsideTheReachMovesTheStartBackToIt() async throws {
        // The pause before the line is short, but one that ends 0.6 s before it is long: the start goes to its middle,
        // never more than 1.5 s before the word.
        let spec: [(String, Double)] = [
            ("Hola", 0), ("todos.", 0.3),
            ("Seguimos", 59.4), ("bien.", 59.7),  // a pause of 58.8 s before, ending 0.6 s before the line
            ("Después", 60), ("más.", 60.3),
        ]
        let document = AIFixtures.document(seconds: 180, words: spec.map { AIFixtures.word($0.0, at: $0.1) })
        let model = FakeTextModel(chapters: [proposing([(4, "Uno")])])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.chapters.map(\.output) == [ns(58.5)])
    }

    @Test func indicesSnapToTheirLineAndOutsidersGo() async throws {
        // Two parts (budget 400 tokens: 16 lines each). The first part proposes an index in the middle of line 10, one
        // past every word, a negative one and one of line 30 (outside it: in the second part); the second, its line 20
        // twice, one of the first part and one with no title.
        let document = AIFixtures.document(seconds: 128)
        let model = FakeTextModel(
            contextSize: 1600,
            chapters: [
                proposing([(105, "Uno"), (9999, "Fuera"), (-3, "Negativo"), (300, "Ajeno")]),
                proposing([(205, "Dos"), (209, "Repetido"), (100, "Del otro"), (250, "  ")]),
            ])
        let result = try await suggester(model).suggest(document: document)
        #expect(model.requests.count == 2)
        #expect(result.parts == 2)
        #expect(result.chapters.map(\.title) == ["Uno", "Dos"])
        #expect(result.chapters.map(\.word) == [TranscriptWordRef(take: 0, word: 100), TranscriptWordRef(take: 0, word: 200)])
        #expect(result.chapters.map(\.output) == [ns(39.5), ns(79.5)])
    }

    @Test func chaptersAreThirtySecondsApart() async throws {
        let document = AIFixtures.document(seconds: 240)
        // Lines at 0, 12 and 44 s.
        let model = FakeTextModel(chapters: [proposing([(0, "Cero"), (30, "Doce"), (110, "Cuarenta y cuatro")])])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.chapters.map(\.output) == [0, ns(43.5)])
        #expect(result.chapters.map(\.title) == ["Cero", "Cuarenta y cuatro"])
    }

    @Test func aTitleRepeatedIsOneChapter() async throws {
        let document = AIFixtures.document(seconds: 240)
        // Lines at 0, 40, 80 and 120 s: the second and the third titled as the one before them.
        let model = FakeTextModel(chapters: [
            proposing([(0, "Instalar"), (100, "Primera función"), (200, "primera funcion."), (300, "Pruebas")])
        ])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.chapters.map(\.title) == ["Instalar", "Primera función", "Pruebas"])
        #expect(result.chapters.map(\.output) == [0, ns(39.5), ns(119.5)])
    }

    @Test func nothingInTheLastThirtySeconds() async throws {
        let document = AIFixtures.document(seconds: 120)
        // Lines at 0, 88 s (87.5 s: 32.5 s from the end) and 100 s (99.5 s: 20.5 s from the end).
        let model = FakeTextModel(chapters: [proposing([(0, "Inicio"), (220, "Casi"), (250, "Tarde")])])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.chapters.map(\.output) == [0, ns(87.5)])
    }

    @Test func existingNamedMarkersWin() async throws {
        let document = AIFixtures.document(seconds: 240)
        // Lines at 0, 72 s (71.5 s: 11.5 s from the marker at 60 s) and 100 s.
        let model = FakeTextModel(chapters: [proposing([(0, "Inicio"), (180, "Cerca"), (250, "Lejos")])])
        let result = try await suggester(model).suggest(document: document, existing: [ns(60)])
        #expect(result.chapters.map(\.title) == ["Inicio", "Lejos"])
        // A marker under 30 s takes the place of the first one too ("Lejos", 28 s after "Cerca", goes).
        let near = try await suggester(model).suggest(document: document, existing: [ns(20)])
        #expect(near.chapters.map(\.title) == ["Cerca"])
    }

    @Test func longTranscriptIsAskedInParts() async throws {
        // contextSize 1600: a budget of 400 tokens, 16 lines of 12 words (2 × 192 + 2 = 386 tokens). 60 lines: 16, 16, 16
        // and 12.
        let document = AIFixtures.document(seconds: 240)
        let model = FakeTextModel(contextSize: 1600, chapters: [FakeTextModel.firstLine()])
        let progress = Collected<AIProgress>()
        let result = try await suggester(model).suggest(document: document) { progress.append($0) }
        #expect(progress.all == (1...4).map { AIProgress(part: $0, parts: 4) })
        #expect(model.requests.count == 4)
        let numbers = model.requests.map { FakeTextModel.lineNumbers(in: $0.prompt) }
        #expect(numbers.map(\.count) == [16, 16, 16, 12])
        #expect(numbers.map(\.first) == [0, 160, 320, 480])
        #expect(numbers.flatMap { $0 } == (0..<60).map { $0 * 10 })
        #expect(model.requests.allSatisfy { FakeTextModel.tokens($0.prompt) <= 1600 - ChapterSuggester.reservedTokens })
        #expect(result.parts == 4)
        #expect(result.chapters.map(\.output) == [0, ns(63.5), ns(127.5), ns(191.5)])
        #expect(result.chapters.map(\.title) == ["Parte 0", "Parte 160", "Parte 320", "Parte 480"])
    }

    @Test func contextTooLongSplitsThePartInHalf() async throws {
        // One part of 45 lines (1082 tokens); the model takes at most 700.
        let document = AIFixtures.document(seconds: 180)
        let model = FakeTextModel(chapters: [
            { prompt in
                FakeTextModel.tokens(prompt) > 700
                    ? .failure(.contextTooLong) : FakeTextModel.firstLine()(prompt)
            }
        ])
        let progress = Collected<AIProgress>()
        let result = try await suggester(model).suggest(document: document) { progress.append($0) }
        #expect(model.requests.count == 3)
        #expect(model.requests.map { FakeTextModel.lineNumbers(in: $0.prompt).count } == [45, 22, 23])
        #expect(progress.all == [AIProgress(part: 1, parts: 1), AIProgress(part: 1, parts: 2), AIProgress(part: 2, parts: 2)])
        #expect(result.parts == 2)
        #expect(result.skippedParts == 0)
        #expect(result.chapters.map(\.output) == [0, ns(87.5)])
    }

    @Test func aSingleLineTooLongIsASkippedPart() async throws {
        // Always too long: halved down to single lines, each one skipped.
        let document = AIFixtures.document(seconds: 64)
        let always = FakeTextModel(chapters: [{ _ in .failure(.contextTooLong) }])
        let none = try await suggester(always).suggest(document: document)
        #expect(none.chapters == [])
        #expect(none.parts == 16)
        #expect(none.skippedParts == none.parts)
        #expect(always.requests.count == 31)

        // Only the line of "Tema7" is too long: the rest is read.
        let one = FakeTextModel(chapters: [
            { prompt in prompt.contains("Tema7 ") ? .failure(.contextTooLong) : FakeTextModel.firstLine()(prompt) }
        ])
        let some = try await suggester(one).suggest(document: AIFixtures.document(seconds: 240))
        #expect(some.skippedParts == 1)
        #expect(!some.chapters.isEmpty)
        #expect(one.requests.last { $0.prompt.contains("Tema7 ") }.map { FakeTextModel.lineNumbers(in: $0.prompt) } == [70])
    }

    @Test func aRefusedPartIsSkippedAndCounted() async throws {
        // 45 lines with a budget of 400: 16, 16 and 13.
        let document = AIFixtures.document(seconds: 180)
        let model = FakeTextModel(
            contextSize: 1600,
            chapters: [FakeTextModel.firstLine("Uno"), { _ in .failure(.refused) }, FakeTextModel.firstLine("Tres")])
        let result = try await suggester(model).suggest(document: document)
        #expect(result.parts == 3)
        #expect(result.skippedParts == 1)
        #expect(result.chapters.map(\.title) == ["Uno", "Tres"])
        #expect(result.chapters.map(\.output) == [0, ns(127.5)])
    }

    @Test func busyIsRetriedOnce() async throws {
        let document = AIFixtures.document(seconds: 64)
        let once = FakeTextModel(chapters: [{ _ in .failure(.busy) }, FakeTextModel.firstLine()])
        let result = try await suggester(once).suggest(document: document)
        #expect(once.requests.count == 2)
        #expect(result.chapters.map(\.output) == [0])

        let twice = FakeTextModel(chapters: [{ _ in .failure(.busy) }])
        await #expect(throws: AIError.busy) { try await suggester(twice).suggest(document: document) }
        #expect(twice.requests.count == 2)
        #expect(ChapterSuggester(model: twice).busyDelay == .seconds(2))
    }

    @Test func unavailableModelIsNeverAsked() async {
        let model = FakeTextModel(availability: { _ in .unavailable(reason: .appleIntelligenceNotEnabled) })
        await #expect(throws: AIError.unavailable(.appleIntelligenceNotEnabled)) {
            try await suggester(model).suggest(document: AIFixtures.document(seconds: 240))
        }
        #expect(model.requests.isEmpty)
    }

    @Test func unsupportedLanguageIsAReason() async {
        let model = FakeTextModel(availability: { language in
            language == "es-MX" ? .unavailable(reason: .unsupportedLanguage(language)) : .available
        })
        await #expect(throws: AIError.unavailable(.unsupportedLanguage("es-MX"))) {
            try await suggester(model).suggest(document: AIFixtures.document(seconds: 240))
        }
        #expect(model.requests.isEmpty)

        // The system model finds out only when asked, and does not know the transcript's language: it is named here.
        let late = FakeTextModel(chapters: [{ _ in .failure(.unavailable(.unsupportedLanguage(""))) }])
        await #expect(throws: AIError.unavailable(.unsupportedLanguage("pt-BR"))) {
            try await suggester(late).suggest(document: AIFixtures.document(seconds: 240, language: "pt-BR"))
        }
        // The availability is asked in the transcript's language.
        let asked = Collected<String>()
        let spy = FakeTextModel(availability: { asked.append($0); return .available })
        _ = try? await suggester(spy).suggest(document: AIFixtures.document(seconds: 240, language: "en-US"))
        #expect(asked.all == ["en-US"])
    }

    @Test func noTranscriptNoWordsAndTooShort() async {
        let model = FakeTextModel()
        let clip = Clip(id: "c-00000001", take: AIFixtures.takeID, start: AIFixtures.source(0), end: AIFixtures.source(240), speed: 1)
        await #expect(throws: AIError.noTranscript) {
            try await suggester(model).suggest(document: AIFixtures.bare(sequence: [clip]))
        }
        // The words are over 0 to 240 s of the source; the clip keeps 300 to 400 s.
        let cut = AIFixtures.document(
            seconds: 240, words: AIFixtures.sentences(seconds: 240),
            sequence: [Clip(id: "c-00000001", take: AIFixtures.takeID, start: AIFixtures.source(300), end: AIFixtures.source(400), speed: 1)])
        await #expect(throws: AIError.noWords) { try await suggester(model).suggest(document: cut) }
        await #expect(throws: AIError.tooShort) {
            try await suggester(model).suggest(document: AIFixtures.document(seconds: 50))
        }
        #expect(model.requests.isEmpty)
        // 60 s is enough.
        _ = try? await suggester(model).suggest(document: AIFixtures.document(seconds: 60))
        #expect(model.requests.count == 1)
    }

    @Test func cancellingStopsBetweenParts() async {
        let model = FakeTextModel(contextSize: 1600, chapters: [FakeTextModel.firstLine()])
        let document = AIFixtures.document(seconds: 240)
        let suggester = suggester(model)
        let task = Task {
            try await suggester.suggest(document: document) { progress in
                if progress.part == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.requests.count == 1)
    }

    @Test func instructionsNameTheLanguage() async throws {
        let model = FakeTextModel(chapters: [FakeTextModel.firstLine()])
        _ = try await suggester(model).suggest(document: AIFixtures.document(seconds: 240))
        let instructions = try #require(model.requests.first?.instructions)
        #expect(instructions.contains("Spanish (Mexico)"))
        #expect(instructions.contains("30 seconds"))
        #expect(instructions.contains("5 minutes"))
        #expect(instructions.contains("40 characters"))
        #expect(AIPrompts.languageName("en-US") == "English (United States)")
        #expect(AIPrompts.languageName("zz-QQ") == "zz-QQ")
    }
}
