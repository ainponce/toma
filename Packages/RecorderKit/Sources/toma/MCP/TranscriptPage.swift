// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI

/// What `get_transcript` gives: a part of the transcript small enough for an agent's tool result (Claude Code warns at
/// 10,000 tokens and cuts at 25,000, `MAX_MCP_OUTPUT_TOKENS`), and enough to ask for the next. By default the words the
/// output says come as segments, a sentence each (or the words between two pauses), with their start and end in seconds
/// of the output; with `words`, each word with its own. A part covers `[from, to)` of the output; when the size runs
/// out before `to`, `nextFrom` says where the next part starts.
struct TranscriptPage: Encodable, Equatable, Sendable {
    /// A sentence, or the words between two pauses.
    struct Segment: Encodable, Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    struct Word: Encodable, Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    var language: String
    /// What the whole output lasts, in seconds.
    var duration: Double
    var from: Double
    /// Where this part ends: the `to` asked for (the end of the output without one), or `nextFrom`.
    var to: Double
    /// Where the next part starts, when this one ran out of room before `to`.
    var nextFrom: Double?
    var segments: [Segment]?
    var words: [Word]?

    /// About how many characters of JSON a part holds: some 7,000 tokens, twice that with the copy a result carries as
    /// text.
    static let budget = 24_000
    /// A silence this long between two words ends a segment.
    static let pause = 1.0
    /// A segment has at most this many words.
    static let longest = 40

    /// The part `[from, to)` of `report` (the whole output without them). `outOfRange` for a `from` below 0 or not
    /// before the end of the output, or a `to` not after `from`.
    static func make(
        _ report: TranscriptReport, from: Double?, to: Double?, words: Bool, budget: Int = budget
    ) throws(APIError) -> TranscriptPage {
        let kept = keptWords(report)
        let duration = report.duration ?? kept.last?.end ?? 0
        let start = from ?? 0
        let end = to ?? duration
        guard start >= 0, start < max(duration, 0.001) else {
            throw APIError(.outOfRange, "get_transcript: from is between 0 and the output's end, \(rounded(duration)) s")
        }
        guard end > start else { throw APIError(.outOfRange, "get_transcript: to has to be after from") }

        let items = words ? kept : segments(of: kept)
        var page = TranscriptPage(
            language: report.language, duration: rounded(duration), from: rounded(start), to: rounded(end), nextFrom: nil)
        var included: [Item] = []
        var size = 0
        for item in items where (item.end > start || item.start >= start) && item.start < end {
            let itemSize = item.text.utf8.count + 48
            if size + itemSize > budget, !included.isEmpty {
                let next = (item.start * 1000).rounded(.down) / 1000
                page.nextFrom = next
                page.to = next
                break
            }
            size += itemSize
            included.append(item)
        }
        if words {
            page.words = included.map { Word(start: rounded($0.start), end: rounded($0.end), text: $0.text) }
        } else {
            page.segments = included.map { Segment(start: rounded($0.start), end: rounded($0.end), text: $0.text) }
        }
        return page
    }

    // MARK: - Private

    private struct Item {
        var start: Double
        var end: Double
        var text: String
    }

    /// The words the output says, in its order.
    private static func keptWords(_ report: TranscriptReport) -> [Item] {
        report.words.enumerated()
            .compactMap { index, word -> (Int, Item)? in
                guard !word.cut, let start = word.start, let end = word.end else { return nil }
                return (index, Item(start: start, end: max(end, start), text: word.text))
            }
            .sorted { $0.1.start != $1.1.start ? $0.1.start < $1.1.start : $0.0 < $1.0 }
            .map(\.1)
    }

    /// The words as sentences: a segment ends after a word that ends a sentence, before a pause, or at `longest` words.
    private static func segments(of words: [Item]) -> [Item] {
        var segments: [Item] = []
        var current: [Item] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(Item(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for word in words {
            if let last = current.last,
                endsSentence(last.text) || word.start - last.end > pause || current.count >= longest
            {
                close()
            }
            current.append(word)
        }
        close()
        return segments
    }

    /// Whether `text` ends a sentence: `.`, `?`, `!`, `…` or their CJK forms, before any closing quotes or brackets.
    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]
        guard let last = text.reversed().first(where: { !closers.contains($0) }) else { return false }
        return [".", "?", "!", "…", "。", "？", "！"].contains(last)
    }

    /// In milliseconds.
    private static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}
