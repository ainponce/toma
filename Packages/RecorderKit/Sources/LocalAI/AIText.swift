// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What the model writes, cleaned (plan 5b, decision 5): whatever it answers, a title or a summary that fits.
public enum AIText {
    /// The quotes a model wraps a text in.
    private static let quotes: Set<Character> = ["\"", "“", "”", "„", "«", "»", "'", "‘", "’", "‹", "›"]
    /// What a cut may leave at the end.
    private static let trailing: Set<Character> = [",", ";", ":", "-", "–", "—", "."]
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]"]
    /// A summary keeps at most this many sentences.
    static let summarySentences = 4

    /// `raw` as a title of at most `limit` characters: on one line, without the quotes that wrap it, a numbering at its
    /// start (`1.`, `1)`, `-`, `•`) or a period at its end, its spaces one; cut at its last space within `limit` (at
    /// `limit` if it has none). `nil` if nothing is left.
    public static func title(_ raw: String, limit: Int) -> String? {
        var text = oneLine(raw)
        while true {
            let before = text
            text = unwrapped(text)
            text = withoutNumbering(text)
            while text.last == "." { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces)
            if text == before { break }
        }
        if text.count > limit {
            let head = text.prefix(limit + 1)
            if let space = head.lastIndex(of: " "), space > head.startIndex {
                text = String(head[..<space])
            } else {
                text = String(text.prefix(limit))
            }
            while let last = text.last, trailing.contains(last) || last == " " { text.removeLast() }
        }
        return text.isEmpty ? nil : text
    }

    /// `raw` as a summary: on one line, without the quotes that wrap it, at most `summarySentences` sentences and
    /// `ProjectInfo.summaryLimit` characters, cut after a sentence (or, if the first one is longer, at a word). `nil` if
    /// nothing is left.
    public static func summary(_ raw: String) -> String? {
        var text = oneLine(raw)
        while true {
            let before = text
            text = unwrapped(text).trimmingCharacters(in: .whitespaces)
            if text == before { break }
        }
        let all = sentences(text)
        var kept: [Substring] = []
        var length = 0
        for sentence in all.prefix(summarySentences) {
            let added = (kept.isEmpty ? 0 : 1) + sentence.count
            guard length + added <= ProjectInfo.summaryLimit else { break }
            kept.append(sentence)
            length += added
        }
        if kept.isEmpty, let first = all.first {
            let head = first.prefix(ProjectInfo.summaryLimit + 1)
            if let space = head.lastIndex(of: " "), space > head.startIndex {
                kept = [head[..<space]]
            } else {
                kept = [first.prefix(ProjectInfo.summaryLimit)]
            }
        }
        let summary = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }

    /// Line breaks and runs of spaces as one space, without spaces at the ends.
    private static func oneLine(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `text` without one pair of quotes around it.
    private static func unwrapped(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last, quotes.contains(first), quotes.contains(last)
        else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// `text` without `1.`, `1)`, `-`, `•` and the like at its start (`1.5 segundos` keeps its number).
    private static func withoutNumbering(_ text: String) -> String {
        let pattern = /^(?:\d+[.)](?!\d)|[-•–—*·])\s*/
        guard let match = text.prefixMatch(of: pattern) else { return text }
        return String(text[match.range.upperBound...])
    }

    /// The sentences of `text` (one line): each up to a `.`, `?`, `!` or `…` (and the quotes or parentheses that close
    /// after it) followed by a space or the end.
    private static func sentences(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            var end = text.index(after: index)
            if sentenceEnds.contains(text[index]) {
                while end < text.endIndex, closers.contains(text[end]) || sentenceEnds.contains(text[end]) {
                    end = text.index(after: end)
                }
                if end == text.endIndex || text[end] == " " {
                    let sentence = text[start..<end].drop { $0 == " " }
                    if !sentence.isEmpty { result.append(sentence) }
                    start = end
                }
            }
            index = end
        }
        let rest = text[start...].drop { $0 == " " }
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}
