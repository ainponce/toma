// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// A chapter the model proposes, placed: where the output shows it, its title cleaned, and the word it starts at.
public struct ChapterSuggestion: Equatable, Sendable {
    /// In ns of the output.
    public var output: Int64
    public var title: String
    public var word: TranscriptWordRef

    public init(output: Int64, title: String, word: TranscriptWordRef) {
        self.output = output
        self.title = title
        self.word = word
    }
}

/// What `ChapterSuggester` proposes, for the sheet that reviews it: never written to the document by itself
/// (design decision 11).
public struct ChapterSuggestions: Equatable, Sendable {
    /// By output, each at least `ChapterSuggester.minimumLength` from the one before, from existing named markers and
    /// from the end.
    public var chapters: [ChapterSuggestion]
    /// How many parts the transcript was read in.
    public var parts: Int
    /// How many of them the model did not read: refused, or a single line still too long.
    public var skippedParts: Int
    /// The transcript's language (BCP 47).
    public var language: String

    public init(chapters: [ChapterSuggestion], parts: Int, skippedParts: Int, language: String) {
        self.chapters = chapters
        self.parts = parts
        self.skippedParts = skippedParts
        self.language = language
    }

    /// The chapters as `ChapterReviewRules` and `ChapterCommands` take them.
    public var asChapters: [Chapter] { chapters.map { Chapter(start: $0.output, title: $0.title) } }
}

/// Chapters for a video from its transcript (design §9, plan 5b decisions 1 to 4 and 8): the numbered lines, in parts
/// that fit the model, each part asked on its own, the answers placed on their lines and cleaned.
public struct ChapterSuggester: Sendable {
    /// No chapter starts closer than this to another, to an existing named marker or to the end.
    public static let minimumLength: Int64 = 30_000_000_000
    /// A shorter output has no chapters.
    public static let shortestVideo: Int64 = 60_000_000_000
    public static let titleLength = 40
    /// A part never has more words (the design's ~2500, which counts with larger contexts).
    public static let wordsPerPart = 2500
    /// The tokens of a request that are not the transcript: instructions, the schema and the answer.
    public static let reservedTokens = 1200
    /// A chapter starts at most this much before its first word.
    public static let silenceReach: Int64 = 1_500_000_000
    /// A pause at least this long between two words is a silence a chapter can start in.
    public static let silenceMinimum: Int64 = 250_000_000
    /// What the schema asks of each part, at most.
    public static let chaptersPerPart = 12

    let model: any TextModel
    let busyDelay: Duration

    public init(model: any TextModel, busyDelay: Duration = .seconds(2)) {
        self.model = model
        self.busyDelay = busyDelay
    }

    /// The chapters of `document`'s output. `existing`: the output of each marker that has a name, which a chapter keeps
    /// its distance from. `progress` is told before each part; cancelling stops between parts.
    ///
    /// Throws `.noTranscript`, `.noWords`, `.tooShort` or `.unavailable` before asking anything; `.busy`, `.failed` or
    /// `.unavailable` from the model; `CancellationError`.
    public func suggest(
        document: EditDocument, existing: [Int64] = [], progress: @Sendable (AIProgress) -> Void = { _ in }
    ) async throws -> ChapterSuggestions {
        guard let transcript = document.transcript else { throw AIError.noTranscript }
        let timeMap = TimeMap(sequence: document.sequence)
        let words = TranscriptTiming.keptWords(of: document, timeMap: timeMap)
        guard !words.isEmpty else { throw AIError.noWords }
        guard timeMap.duration >= Self.shortestVideo else { throw AIError.tooShort }
        let language = transcript.language
        if case .unavailable(let reason) = model.availability(language: language) { throw AIError.unavailable(reason) }

        let lines = TranscriptLines.make(words)
        var queue = await TranscriptLines.parts(
            lines, tokenBudget: max(model.contextSize - Self.reservedTokens, 1), maximumWords: Self.wordsPerPart,
            model: model)
        let instructions = AIPrompts.chapterInstructions(language: language)
        var starts: [(word: Int, title: String)] = []
        var skipped = 0
        var index = 0
        while index < queue.count {
            try Task.checkCancellation()
            progress(AIProgress(part: index + 1, parts: queue.count))
            let part = queue[index]
            do {
                let proposed = try await AIRequest.send(retryingAfter: busyDelay, language: language) {
                    try await model.chapters(instructions: instructions, prompt: AIPrompts.chapterPrompt(part))
                }
                starts += Self.placed(proposed, in: part)
                index += 1
            } catch AIError.contextTooLong where part.count > 1 {
                let half = part.count / 2
                queue.replaceSubrange(index...index, with: [Array(part[..<half]), Array(part[half...])])
            } catch AIError.contextTooLong, AIError.refused {
                skipped += 1
                index += 1
            }
        }
        try Task.checkCancellation()

        let chapters = Self.chapters(starts, words: words, duration: timeMap.duration, existing: existing)
        return ChapterSuggestions(chapters: chapters, parts: queue.count, skippedParts: skipped, language: language)
    }

    /// The proposals of `part` on the first word of their line, with their titles cleaned (decision 2): an index outside
    /// the part, or without a title once cleaned, goes; of two on one line, the first stays.
    static func placed(_ proposed: [ProposedChapter], in part: [TranscriptLine]) -> [(word: Int, title: String)] {
        guard let first = part.first, let last = part.last else { return [] }
        let words = first.words.lowerBound..<last.words.upperBound
        var seen: Set<Int> = []
        var result: [(word: Int, title: String)] = []
        for chapter in proposed where words.contains(chapter.firstWordIndex) {
            guard let line = part.first(where: { $0.words.contains(chapter.firstWordIndex) }),
                let title = AIText.title(chapter.title, limit: titleLength),
                seen.insert(line.words.lowerBound).inserted
            else { continue }
            result.append((line.words.lowerBound, title))
        }
        return result
    }

    /// The chapters at `starts` (decisions 3 and 4): each at its word, moved back into the silence before it; the first
    /// at 0 if it starts under `minimumLength`; by output, without one under `minimumLength` from the one before that
    /// stayed, from the end or from an `existing` marker, nor one titled as the one before that stayed (case and accents
    /// aside: the model splits a topic so, and the two are one chapter).
    static func chapters(
        _ starts: [(word: Int, title: String)], words: [KeptWord], duration: Int64, existing: [Int64]
    ) -> [ChapterSuggestion] {
        var placed = starts.map { start in
            ChapterSuggestion(output: Self.start(ofWord: start.word, in: words), title: start.title, word: words[start.word].ref)
        }
        placed.sort { ($0.output, $0.word) < ($1.output, $1.word) }
        if let first = placed.first, first.output < minimumLength { placed[0].output = 0 }
        var result: [ChapterSuggestion] = []
        for chapter in placed {
            if duration - chapter.output < minimumLength { continue }
            if let previous = result.last, chapter.output - previous.output < minimumLength { continue }
            if let previous = result.last, Self.sameTitle(previous.title, chapter.title) { continue }
            if existing.contains(where: { abs($0 - chapter.output) < minimumLength }) { continue }
            result.append(chapter)
        }
        return result
    }

    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == .orderedSame
    }

    /// Where a chapter at word `index` starts (decision 3): the middle of the nearest pause of `silenceMinimum` or more
    /// between two words before it that ends at most `silenceReach` before the word, never more than `silenceReach`
    /// before it; without one, the word's start.
    static func start(ofWord index: Int, in words: [KeptWord]) -> Int64 {
        let word = words[index].output.lowerBound
        var k = index
        while k > 0 {
            let silenceEnd = words[k].output.lowerBound
            guard word - silenceEnd <= silenceReach else { break }
            let silenceStart = words[k - 1].output.upperBound
            if silenceEnd - silenceStart >= silenceMinimum {
                return max(silenceStart + (silenceEnd - silenceStart) / 2, word - silenceReach, 0)
            }
            k -= 1
        }
        return word
    }
}
