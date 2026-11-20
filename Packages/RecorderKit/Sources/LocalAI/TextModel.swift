// SPDX-License-Identifier: GPL-3.0-or-later

/// Why the model cannot write (plan 5b, decision 9). The app says each one in words.
public enum AIUnavailableReason: Equatable, Sendable {
    /// Before macOS 26 there is no Foundation Models.
    case needsMacOS26
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is still downloading or preparing its model.
    case modelNotReady
    /// A reason this version of Toma does not know.
    case unknown
    /// The model does not write this language (BCP 47).
    case unsupportedLanguage(String)
}

/// Whether the model can write now, in a language.
public enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: AIUnavailableReason)
}

/// What a suggestion can fail with (decision 8). A `TextModel` throws only `.unavailable`, `.contextTooLong`,
/// `.refused`, `.busy` and `.failed`; the suggesters add the rest. Cancelling throws `CancellationError`.
public enum AIError: Error, Equatable, Sendable {
    case unavailable(AIUnavailableReason)
    /// The project has no transcript.
    case noTranscript
    /// Every word of the transcript is cut.
    case noWords
    /// The output lasts less than `ChapterSuggester.shortestVideo`.
    case tooShort
    /// The request does not fit in the model's context.
    case contextTooLong
    /// The model's guardrails or the model itself declined.
    case refused
    /// The model is answering someone else, or too many requests were made; still so after one retry.
    case busy
    /// Anything else, described by the system.
    case failed(String)
}

/// A text the model writes from a transcript.
public enum InfoKind: String, Sendable {
    /// The video's title, up to `InfoSuggester.titleLength` characters.
    case title
    /// Its summary, 2 to 4 sentences.
    case summary
    /// The summary of one part of a long transcript, 2 sentences, which the title and the summary are written from
    /// (decision 7).
    case partSummary
}

/// A chapter as the model proposes it: a title and the number of the line it starts at (`TranscriptLines.render`),
/// which is the index in `keptWords` of the line's first word, unchecked.
public struct ProposedChapter: Equatable, Sendable {
    public var title: String
    public var firstWordIndex: Int

    public init(title: String, firstWordIndex: Int) {
        self.title = title
        self.firstWordIndex = firstWordIndex
    }
}

/// Which part of the transcript is being read: `part` of `parts`, from 1. A part too long for the model is read in two
/// halves, so `parts` can grow while reading.
public struct AIProgress: Equatable, Sendable {
    public var part: Int
    public var parts: Int

    public init(part: Int, parts: Int) {
        self.part = part
        self.parts = parts
    }
}

/// A language model that writes on this Mac: the system's (`SystemTextModel`) or, in tests and screenshots, a fake.
/// What it is asked is never written to disk or to the log.
public protocol TextModel: Sendable {
    /// Whether it can write now in `language` (BCP 47).
    func availability(language: String) -> AIAvailability
    /// Tokens of one request, instructions and answer included.
    var contextSize: Int { get }
    /// The tokens of `text` as a prompt.
    func tokenCount(_ text: String) async -> Int
    /// The chapters `prompt` (numbered lines) has, as `instructions` ask. Throws `AIError` only (or
    /// `CancellationError`).
    func chapters(instructions: String, prompt: String) async throws -> [ProposedChapter]
    /// The text of `kind` for `prompt`. `variation` 0 is the most likely answer; another number, another answer, the same
    /// for the same number. Throws `AIError` only (or `CancellationError`).
    func text(_ kind: InfoKind, instructions: String, prompt: String, variation: Int) async throws -> String
}

/// What both suggesters do with every request (decision 8): one retry after `delay` when the model is busy, and the
/// transcript's language named in `.unsupportedLanguage`, which the system model cannot know.
enum AIRequest {
    static func send<Answer: Sendable>(
        retryingAfter delay: Duration, language: String, _ request: () async throws -> Answer
    ) async throws -> Answer {
        do {
            return try await named(language, request)
        } catch AIError.busy {
            try await Task.sleep(for: delay)
            return try await named(language, request)
        }
    }

    private static func named<Answer: Sendable>(_ language: String, _ request: () async throws -> Answer) async throws -> Answer {
        do {
            return try await request()
        } catch AIError.unavailable(.unsupportedLanguage) {
            throw AIError.unavailable(.unsupportedLanguage(language))
        }
    }
}
