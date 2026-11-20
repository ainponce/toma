// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// A title and a summary for a video from its transcript (design §9, plan 5b decisions 6 to 8). A transcript that fits
/// the model is one request; a longer one is summarized part by part, and the title or the summary written from those
/// summaries, in order.
public struct InfoSuggester: Sendable {
    public static let titleLength = 70
    /// The tokens of a request that are not the transcript: instructions, the schema and the answer.
    public static let reservedTokens = 800

    let model: any TextModel
    let busyDelay: Duration

    public init(model: any TextModel, busyDelay: Duration = .seconds(2)) {
        self.model = model
        self.busyDelay = busyDelay
    }

    /// A title of at most `titleLength` characters. `variation` 0 is the most likely; asking again with 1, 2… gives
    /// another (decision 6). Throws as `summary` does.
    public func title(
        document: EditDocument, variation: Int = 0, progress: @Sendable (AIProgress) -> Void = { _ in }
    ) async throws -> String {
        let raw = try await write(.title, document: document, variation: variation, progress: progress)
        guard let title = AIText.title(raw, limit: Self.titleLength) else { throw AIError.refused }
        return title
    }

    /// A summary of 2 to 4 sentences, at most `ProjectInfo.summaryLimit` characters.
    ///
    /// Throws `.noTranscript`, `.noWords` or `.unavailable` before asking anything; `.refused` when the model declines
    /// (or every part of a long transcript is declined, or nothing is left of the answer once cleaned); `.busy`,
    /// `.contextTooLong`, `.failed` or `.unavailable` from the model; `CancellationError`.
    public func summary(
        document: EditDocument, variation: Int = 0, progress: @Sendable (AIProgress) -> Void = { _ in }
    ) async throws -> String {
        let raw = try await write(.summary, document: document, variation: variation, progress: progress)
        guard let summary = AIText.summary(raw) else { throw AIError.refused }
        return summary
    }

    private func write(
        _ kind: InfoKind, document: EditDocument, variation: Int, progress: @Sendable (AIProgress) -> Void
    ) async throws -> String {
        guard let transcript = document.transcript else { throw AIError.noTranscript }
        let words = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
        guard !words.isEmpty else { throw AIError.noWords }
        let language = transcript.language
        if case .unavailable(let reason) = model.availability(language: language) { throw AIError.unavailable(reason) }

        var queue = await TranscriptLines.parts(
            TranscriptLines.make(words), tokenBudget: max(model.contextSize - Self.reservedTokens, 1),
            maximumWords: ChapterSuggester.wordsPerPart, model: model)
        let instructions = AIPrompts.infoInstructions(kind, language: language)
        if queue.count == 1 {
            let part = queue[0]
            progress(AIProgress(part: 1, parts: 1))
            do {
                return try await ask(kind, instructions, AIPrompts.infoPrompt(part), variation, language)
            } catch AIError.contextTooLong where part.count > 1 {
                let half = part.count / 2
                queue = [Array(part[..<half]), Array(part[half...])]
            }
        }

        // Decision 7: each part in 2 sentences, then the text from them. A refused part is left out.
        let partInstructions = AIPrompts.infoInstructions(.partSummary, language: language)
        var summaries: [String] = []
        var refused = false
        var index = 0
        while index < queue.count {
            try Task.checkCancellation()
            progress(AIProgress(part: index + 1, parts: queue.count + 1))
            let part = queue[index]
            do {
                let raw = try await ask(.partSummary, partInstructions, AIPrompts.infoPrompt(part), 0, language)
                if let summary = AIText.summary(raw) { summaries.append(summary) }
                index += 1
            } catch AIError.contextTooLong where part.count > 1 {
                let half = part.count / 2
                queue.replaceSubrange(index...index, with: [Array(part[..<half]), Array(part[half...])])
            } catch AIError.refused {
                refused = true
                index += 1
            } catch AIError.contextTooLong {
                index += 1
            }
        }
        guard !summaries.isEmpty else { throw refused ? AIError.refused : AIError.contextTooLong }
        try Task.checkCancellation()
        progress(AIProgress(part: queue.count + 1, parts: queue.count + 1))
        return try await ask(kind, instructions, AIPrompts.infoPrompt(summaries: summaries), variation, language)
    }

    private func ask(
        _ kind: InfoKind, _ instructions: String, _ prompt: String, _ variation: Int, _ language: String
    ) async throws -> String {
        try await AIRequest.send(retryingAfter: busyDelay, language: language) {
            try await model.text(kind, instructions: instructions, prompt: prompt, variation: variation)
        }
    }
}
