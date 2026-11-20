// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import FoundationModels
import ProjectFormat
import Testing

@testable import LocalAI

@Suite struct SystemTextModelTests {
    @Test func systemReasonsMapOneToOne() {
        guard #available(macOS 26, *) else {
            #expect(SystemTextModel.availability(language: "en-US") == .unavailable(reason: .needsMacOS26))
            return
        }
        #expect(SystemTextModel.reason(.deviceNotEligible) == .deviceNotEligible)
        #expect(SystemTextModel.reason(.appleIntelligenceNotEnabled) == .appleIntelligenceNotEnabled)
        #expect(SystemTextModel.reason(.modelNotReady) == .modelNotReady)
        #expect(SystemTextModel.availability(.unavailable(.modelNotReady), language: "es-MX", supported: true)
            == .unavailable(reason: .modelNotReady))
        #expect(SystemTextModel.availability(.available, language: "es-MX", supported: true) == .available)
        #expect(SystemTextModel.availability(.available, language: "eu-ES", supported: false)
            == .unavailable(reason: .unsupportedLanguage("eu-ES")))
        // This Mac's answer is one of ours, and the instance answers the same.
        #expect(SystemTextModel().availability(language: "en-US") == SystemTextModel.availability(language: "en-US"))
        #expect(SystemTextModel().contextSize >= 4096)
    }

    @Test func generationErrorsMapToAIError() {
        guard #available(macOS 26, *) else { return }
        typealias GenerationError = LanguageModelSession.GenerationError
        let context = GenerationError.Context(debugDescription: "")
        let cases: [(GenerationError, AIError)] = [
            (.exceededContextWindowSize(context), .contextTooLong),
            (.guardrailViolation(context), .refused),
            (.refusal(GenerationError.Refusal(transcriptEntries: []), context), .refused),
            (.unsupportedLanguageOrLocale(context), .unavailable(.unsupportedLanguage("es-MX"))),
            (.assetsUnavailable(context), .unavailable(.modelNotReady)),
            (.rateLimited(context), .busy),
            (.concurrentRequests(context), .busy),
        ]
        for (error, expected) in cases {
            #expect(SystemTextModel.aiError(error, language: "es-MX") == expected, "\(error)")
        }
        guard case .failed = SystemTextModel.aiError(GenerationError.decodingFailure(context), language: "es-MX") else {
            Issue.record("decodingFailure is not .failed")
            return
        }
        guard case .failed = SystemTextModel.aiError(CocoaError(.fileNoSuchFile), language: "es-MX") else {
            Issue.record("another error is not .failed")
            return
        }
        // An AIError passes through.
        #expect(SystemTextModel.aiError(AIError.busy, language: "es-MX") == .busy)
    }

    @Test func tokensAreCountedOrEstimated() async {
        let model = SystemTextModel()
        let count = await model.tokenCount("[0] Hola a todos, hoy vamos a ver cómo instalar el paquete.")
        #expect(count > 5)
        #expect(count < 60)
        #expect(SystemTextModel.estimatedTokens("abcd") == 2)
        #expect(SystemTextModel.estimatedTokens("abc") == 2)
    }

    /// The system model, when this Mac has it: three topics in English, about 180 words over 3 min.
    @Test(.enabled(if: SystemTextModel.availability(language: "en-US") == .available), .timeLimit(.minutes(3)))
    func theRealModelProposesChaptersTitleAndSummary() async throws {
        let topics = [
            "First we install the package manager on the Mac. Open the terminal and paste the command from the website. "
                + "The installer asks for your password and downloads everything it needs. When it finishes, check the version. "
                + "If you see a number, the package manager is ready to use.",
            "Now we create a new project with the command line tool. Choose a folder for it and give it a short name. "
                + "The tool writes the files and a configuration you can edit later. Open the folder in your editor and look "
                + "at the main file to see where the program starts.",
            "Finally we run the tests and publish the first version. The tests check that every function still works. "
                + "When all of them pass, tag the release and push it. Other people can then install your package with one "
                + "command, the same way we installed the manager at the start.",
        ]
        var words: [TranscriptWord] = []
        for (index, topic) in topics.enumerated() {
            let texts = topic.split(separator: " ").map(String.init)
            let start = Double(index) * 60
            let step = 55.0 / Double(texts.count)
            words += texts.enumerated().map { AIFixtures.word($1, at: start + Double($0) * step, length: step * 0.8) }
        }
        let document = AIFixtures.document(seconds: 180, words: words, language: "en-US")
        let model = SystemTextModel()

        let chapters = try await ChapterSuggester(model: model).suggest(document: document)
        #expect(!chapters.chapters.isEmpty)
        #expect(chapters.chapters.first?.output == 0)
        #expect(chapters.chapters.allSatisfy { (1...ChapterSuggester.titleLength).contains($0.title.count) })
        let outputs = chapters.chapters.map(\.output)
        #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $1 - $0 >= ChapterSuggester.minimumLength })
        #expect(chapters.skippedParts == 0)

        let info = InfoSuggester(model: model)
        let title = try await info.title(document: document)
        #expect((1...InfoSuggester.titleLength).contains(title.count))
        let summary = try await info.summary(document: document)
        #expect(!summary.isEmpty)
        #expect(summary.count <= ProjectInfo.summaryLimit)
    }
}
