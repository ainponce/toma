// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import LocalAI

@Suite struct InfoSuggesterTests {
    private func suggester(_ model: FakeTextModel) -> InfoSuggester { InfoSuggester(model: model, busyDelay: .zero) }

    @Test func shortTranscriptIsOneRequest() async throws {
        let model = FakeTextModel(texts: [
            { _, _ in .success("«Cómo instalar el paquete y configurarlo todo en una Mac nueva desde la terminal, paso a paso.»") }
        ])
        let progress = Collected<AIProgress>()
        let title = try await suggester(model).title(document: AIFixtures.document(seconds: 64)) { progress.append($0) }
        #expect(title == "Cómo instalar el paquete y configurarlo todo en una Mac nueva desde la")
        #expect(title.count <= InfoSuggester.titleLength)
        #expect(model.requests.count == 1)
        let request = try #require(model.requests.first)
        #expect(request.kind == .title)
        #expect(request.variation == 0)
        #expect((0..<16).allSatisfy { request.prompt.contains("Tema\($0) dos") })
        #expect(request.instructions.contains("Spanish (Mexico)"))
        #expect(request.instructions.contains("70 characters"))
        #expect(progress.all == [AIProgress(part: 1, parts: 1)])

        // The summary is cleaned too.
        let summary = try await suggester(FakeTextModel(texts: [{ _, _ in .success(" Uno. Dos.\nTres. Cuatro. Cinco. ") }]))
            .summary(document: AIFixtures.document(seconds: 64))
        #expect(summary == "Uno. Dos. Tres. Cuatro.")
    }

    @Test func longTranscriptSummarizesPartsFirst() async throws {
        // contextSize 1200: a budget of 400 tokens, 16 lines. 45 lines: 16, 16 and 13.
        let model = FakeTextModel(contextSize: 1200, texts: [
            { kind, _ in .success(kind == .partSummary ? "Resumen uno." : "Final.") },
            { kind, _ in .success(kind == .partSummary ? "Resumen dos." : "Final.") },
            { kind, _ in .success(kind == .partSummary ? "Resumen tres." : "Final.") },
            { _, _ in .success("El video muestra todo. Termina bien.") },
        ])
        let progress = Collected<AIProgress>()
        let summary = try await suggester(model).summary(document: AIFixtures.document(seconds: 180), variation: 1) {
            progress.append($0)
        }
        #expect(summary == "El video muestra todo. Termina bien.")
        #expect(model.requests.map(\.kind) == [.partSummary, .partSummary, .partSummary, .summary])
        #expect(model.requests.map(\.variation) == [0, 0, 0, 1])
        #expect(model.requests[0].prompt.contains("Tema0 dos"))
        #expect(model.requests[1].prompt.contains("Tema16 dos"))
        #expect(!model.requests[1].prompt.contains("Tema15 dos"))
        let last = model.requests[3].prompt
        let places = ["Resumen uno.", "Resumen dos.", "Resumen tres."].map { last.range(of: $0)?.lowerBound }
        #expect(places.allSatisfy { $0 != nil })
        #expect(places.compactMap { $0 } == places.compactMap { $0 }.sorted())
        #expect(!last.contains("Tema"))
        #expect(progress.all == (1...4).map { AIProgress(part: $0, parts: 4) })
    }

    @Test func aRefusedPartIsLeftOutOfTheSummary() async throws {
        let model = FakeTextModel(contextSize: 1200, texts: [
            { _, _ in .success("Resumen uno.") }, { _, _ in .failure(.refused) }, { _, _ in .success("Resumen tres.") },
            { _, prompt in .success(prompt.contains("Resumen dos") ? "Mal." : "Bien.") },
        ])
        let title = try await suggester(model).title(document: AIFixtures.document(seconds: 180))
        #expect(title == "Bien")
        #expect(model.requests.map(\.kind) == [.partSummary, .partSummary, .partSummary, .title])

        // Every part refused: the title is refused.
        let none = FakeTextModel(contextSize: 1200, texts: [{ _, _ in .failure(.refused) }])
        await #expect(throws: AIError.refused) { try await suggester(none).title(document: AIFixtures.document(seconds: 180)) }
    }

    @Test func aSinglePartTooLongIsSummarizedInHalves() async throws {
        // One part by the count, too long for the model: summarized in two halves, then titled from them.
        let model = FakeTextModel(texts: [
            { kind, prompt in
                kind != .partSummary && prompt.contains("Tema") ? .failure(.contextTooLong) : .success("Una mitad.")
            }
        ])
        let title = try await suggester(model).title(document: AIFixtures.document(seconds: 180))
        #expect(title == "Una mitad")
        #expect(model.requests.map(\.kind) == [.title, .partSummary, .partSummary, .title])
    }

    @Test func variationReachesTheModel() async throws {
        let model = FakeTextModel(texts: [{ _, _ in .success("Título") }])
        _ = try await suggester(model).title(document: AIFixtures.document(seconds: 64), variation: 2)
        #expect(model.requests.map(\.variation) == [2])
    }

    @Test func refusedTitleIsAnError() async {
        let model = FakeTextModel(texts: [{ _, _ in .failure(.refused) }])
        await #expect(throws: AIError.refused) { try await suggester(model).title(document: AIFixtures.document(seconds: 64)) }
        // An answer with nothing left once cleaned is refused too.
        let empty = FakeTextModel(texts: [{ _, _ in .success(" «» ") }])
        await #expect(throws: AIError.refused) { try await suggester(empty).title(document: AIFixtures.document(seconds: 64)) }
        // Busy twice: busy.
        let busy = FakeTextModel(texts: [{ _, _ in .failure(.busy) }])
        await #expect(throws: AIError.busy) { try await suggester(busy).summary(document: AIFixtures.document(seconds: 64)) }
        #expect(busy.requests.count == 2)
    }

    @Test func unavailableOrNoWordsIsNeverAsked() async throws {
        let off = FakeTextModel(availability: { _ in .unavailable(reason: .modelNotReady) })
        await #expect(throws: AIError.unavailable(.modelNotReady)) {
            try await suggester(off).title(document: AIFixtures.document(seconds: 64))
        }
        let clip = Clip(id: "c-00000001", take: AIFixtures.takeID, start: AIFixtures.source(0), end: AIFixtures.source(64), speed: 1)
        await #expect(throws: AIError.noTranscript) { try await suggester(off).summary(document: AIFixtures.bare(sequence: [clip])) }
        #expect(off.requests.isEmpty)
        // A short video still has a title.
        let model = FakeTextModel(texts: [{ _, _ in .success("Corto") }])
        #expect(try await suggester(model).title(document: AIFixtures.document(seconds: 8)) == "Corto")
    }
}
