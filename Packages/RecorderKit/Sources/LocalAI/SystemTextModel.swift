// SPDX-License-Identifier: GPL-3.0-or-later
// The only file of Toma that imports FoundationModels (plan 5b): every use is behind macOS 26, so the framework links
// weakly and Toma opens on macOS 15. It does not import ProjectFormat, whose `Transcript` would clash with the
// framework's.
import Foundation
import FoundationModels

/// Apple Intelligence's model on this Mac (`SystemLanguageModel.default`), from macOS 26. Nothing leaves the Mac, and
/// nothing it is asked or answers is written anywhere. Before macOS 26 it is unavailable (`.needsMacOS26`) and never
/// asked.
public struct SystemTextModel: TextModel {
    /// The context before macOS 27, measured: also what the system says on 26.
    static let legacyContextSize = 4096

    public init() {}

    /// Whether the system model can write `language` (BCP 47) now (decision 9): its own reasons one to one, and a
    /// language it does not write as `.unsupportedLanguage`.
    public static func availability(language: String) -> AIAvailability {
        guard #available(macOS 26, *) else { return .unavailable(reason: .needsMacOS26) }
        let model = SystemLanguageModel.default
        let availability = model.availability
        let supported = availability == .available && model.supportsLocale(Locale(identifier: language))
        return Self.availability(availability, language: language, supported: supported)
    }

    public func availability(language: String) -> AIAvailability { Self.availability(language: language) }

    public var contextSize: Int {
        guard #available(macOS 26, *) else { return Self.legacyContextSize }
        return SystemLanguageModel.default.contextSize
    }

    public func tokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return count
        }
        return Self.estimatedTokens(text)
    }

    public func chapters(instructions: String, prompt: String) async throws -> [ProposedChapter] {
        guard #available(macOS 26, *) else { throw AIError.unavailable(.needsMacOS26) }
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)
        let content = try await respond(instructions: instructions, prompt: prompt, generating: GeneratedChapters.self, options: options)
        return content.chapters.map { ProposedChapter(title: $0.title, firstWordIndex: $0.firstWordIndex) }
    }

    public func text(_ kind: InfoKind, instructions: String, prompt: String, variation: Int) async throws -> String {
        guard #available(macOS 26, *) else { throw AIError.unavailable(.needsMacOS26) }
        let sampling: GenerationOptions.SamplingMode = variation == 0 ? .greedy : .random(top: 40, seed: UInt64(max(variation, 0)))
        let options = GenerationOptions(samplingMode: sampling, maximumResponseTokens: kind == .title ? 120 : 400)
        return try await respond(instructions: instructions, prompt: prompt, generating: GeneratedText.self, options: options).text
    }

    /// One request in a new session, its errors as `AIError`. `includeSchemaInPrompt` is always given, so the overload
    /// of macOS 26 is chosen and not the one of 27 (`contextOptions:`).
    @available(macOS 26, *)
    private func respond<Content: Generable>(
        instructions: String, prompt: String, generating type: Content.Type, options: GenerationOptions
    ) async throws -> Content {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: type, includeSchemaInPrompt: true, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The suggesters name the transcript's language, which a session does not know.
            throw Self.aiError(error, language: "")
        }
    }

    // MARK: - Mapping, internal so the tests reach it

    @available(macOS 26, *)
    static func availability(_ availability: SystemLanguageModel.Availability, language: String, supported: Bool) -> AIAvailability {
        switch availability {
        case .available: supported ? .available : .unavailable(reason: .unsupportedLanguage(language))
        case .unavailable(let reason): .unavailable(reason: Self.reason(reason))
        }
    }

    @available(macOS 26, *)
    static func reason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AIUnavailableReason {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unknown
        }
    }

    /// `error` of a request as `AIError` (decision 8): the context exceeded, a guardrail or a refusal, the model busy,
    /// a language it does not write (`language`), its assets missing; anything else `.failed` with its description. The
    /// errors of macOS 27 (`LanguageModelError`) and of 26 (`GenerationError`, obsolete in 27) both.
    static func aiError(_ error: any Error, language: String) -> AIError {
        if let error = error as? AIError { return error }
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .contextTooLong
                case .guardrailViolation, .refusal: return .refused
                case .rateLimited: return .busy
                case .unsupportedLanguageOrLocale: return .unavailable(.unsupportedLanguage(language))
                default: return .failed(error.localizedDescription)
                }
            }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests { return .busy }
            if let error = error as? SystemLanguageModel.Error, case .assetsUnavailable = error {
                return .unavailable(.modelNotReady)
            }
        }
        if #available(macOS 26, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextTooLong
            case .guardrailViolation, .refusal: return .refused
            case .rateLimited, .concurrentRequests: return .busy
            case .unsupportedLanguageOrLocale: return .unavailable(.unsupportedLanguage(language))
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            case .decodingFailure, .unsupportedGuide: return .failed(error.localizedDescription)
            @unknown default: return .failed(error.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }

    /// Tokens of `text` where the system cannot count them (before macOS 26.4): one per two UTF-16 units, more than
    /// the model's (some 3.5 characters a token in Spanish), so a part never runs over.
    static func estimatedTokens(_ text: String) -> Int { (text.utf16.count + 1) / 2 }
}

// MARK: - What the model fills in

@available(macOS 26, *)
@Generable
struct GeneratedChapters {
    @Guide(description: "The chapters, in order", .maximumCount(ChapterSuggester.chaptersPerPart))
    var chapters: [GeneratedChapter]
}

@available(macOS 26, *)
@Generable
struct GeneratedChapter {
    @Guide(description: "A short title, at most 40 characters")
    var title: String
    @Guide(description: "The number in brackets of the line where the chapter starts", .minimum(0))
    var firstWordIndex: Int
}

@available(macOS 26, *)
@Generable
struct GeneratedText {
    @Guide(description: "Only the text asked for, without quotes or a label")
    var text: String
}
