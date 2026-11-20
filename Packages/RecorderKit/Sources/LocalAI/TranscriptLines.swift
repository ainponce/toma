// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation

/// A line of the transcript as the model reads it: whole words that are seen, in output order.
public struct TranscriptLine: Equatable, Sendable {
    /// Indices in `keptWords`; `words.lowerBound` is its number.
    public var words: Range<Int>
    public var text: String
    /// From its first word's start to the latest end of its words, in ns of the output.
    public var output: Range<Int64>

    public init(words: Range<Int>, text: String, output: Range<Int64>) {
        self.words = words
        self.text = text
        self.output = output
    }
}

/// The transcript in numbered lines, and the lines in parts that fit the model (plan 5b, decisions 1 and 2).
public enum TranscriptLines {
    /// A pause at least this long between two words ends a line.
    public static let pauseBreak: Int64 = 700_000_000
    /// A line never has more words.
    public static let maximumWords = 30

    /// What ends a sentence, and what may close after it (`listo.»`, `listo.)`).
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}"]

    /// `words` (`TranscriptTiming.keptWords`, in output order) in lines: one ends after a word that ends a sentence, before
    /// a pause of `pauseBreak` or more, or at `maximumWords`.
    public static func make(_ words: [KeptWord]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var start = 0
        for index in words.indices {
            let isLast = index == words.count - 1
            let ends =
                isLast || endsSentence(words[index].text) || index - start + 1 >= maximumWords
                || words[index + 1].output.lowerBound - words[index].output.upperBound >= pauseBreak
            guard ends else { continue }
            let range = start..<(index + 1)
            let text = words[range].map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let first = words[start].output.lowerBound
            let last = words[range].map(\.output.upperBound).max() ?? first
            lines.append(TranscriptLine(words: range, text: text, output: first..<max(first, last)))
            start = index + 1
        }
        return lines
    }

    /// `line` as the model reads it: `[<number> @<m:ss>] <text>`, at the second its first word starts.
    public static func render(_ line: TranscriptLine) -> String {
        let seconds = max(line.output.lowerBound, 0) / 1_000_000_000
        let (minutes, rest) = (seconds / 60, seconds % 60)
        return "[\(line.words.lowerBound) @\(minutes):\(rest < 10 ? "0" : "")\(rest)] \(line.text)"
    }

    /// `lines` rendered, one per row: what a part says to the model and what its tokens are counted on.
    public static func text(_ lines: [TranscriptLine]) -> String {
        lines.map(render).joined(separator: "\n")
    }

    /// `lines` in parts, in order: each takes the most lines that follow whose `text` the model counts in `tokenBudget`
    /// tokens or fewer and that have `maximumWords` words or fewer. A line over the budget alone is a part of its own.
    ///
    /// Each part is counted whole, not line by line (the system model takes some 25 ms a count and adds its own tokens to
    /// each): its end is found by doubling and then halving, a dozen counts a part.
    public static func parts(
        _ lines: [TranscriptLine], tokenBudget: Int, maximumWords: Int, model: any TextModel
    ) async -> [[TranscriptLine]] {
        var wordsBefore = [0]
        for line in lines { wordsBefore.append(wordsBefore[wordsBefore.count - 1] + line.words.count) }

        func fits(_ range: Range<Int>) async -> Bool {
            guard wordsBefore[range.upperBound] - wordsBefore[range.lowerBound] <= maximumWords else { return false }
            return await model.tokenCount(text(Array(lines[range]))) <= tokenBudget
        }

        var parts: [[TranscriptLine]] = []
        var start = 0
        while start < lines.count {
            let left = lines.count - start
            // `good` lines fit (or are the one line a part always has); `bad` do not.
            var good = 1
            var bad: Int?
            var probe = 2
            while good < left {
                let count = min(probe, left)
                if await fits(start..<(start + count)) {
                    good = count
                    probe = count * 2
                } else {
                    bad = count
                    break
                }
            }
            if var bad {
                while bad - good > 1 {
                    let middle = (good + bad) / 2
                    if await fits(start..<(start + middle)) { good = middle } else { bad = middle }
                }
            }
            parts.append(Array(lines[start..<(start + good)]))
            start += good
        }
        return parts
    }

    private static func endsSentence(_ word: String) -> Bool {
        var text = Substring(word.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = text.last, closers.contains(last) { text = text.dropLast() }
        return text.last.map(sentenceEnds.contains) ?? false
    }
}
