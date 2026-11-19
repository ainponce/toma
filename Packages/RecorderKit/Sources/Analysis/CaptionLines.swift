// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// A word of a caption as it is drawn, over the output time it is highlighted: from its own start to the start of the next
/// word of the caption (the last, to the end of the caption), so the highlight never flickers between words (plan decision 11).
public struct CaptionWord: Equatable, Sendable {
    public var ref: TranscriptWordRef
    /// As drawn: in capitals if the style asks for them.
    public var text: String
    public var output: Range<Int64>

    public init(ref: TranscriptWordRef, text: String, output: Range<Int64>) {
        self.ref = ref
        self.text = text
        self.output = output
    }
}

/// A caption: one or two lines of words, shown over `output`.
public struct Caption: Equatable, Sendable {
    public var output: Range<Int64>
    public var lines: [[CaptionWord]]
    /// The lines joined by `\n`, their words by a space.
    public var text: String

    public init(output: Range<Int64>, lines: [[CaptionWord]], text: String) {
        self.output = output
        self.lines = lines
        self.text = text
    }
}

/// The captions drawn from the transcript, `captionLines-1` (phase 2 design §5.2): a pure function of the document over
/// output time. Frozen: a change of rule is a new id.
public enum CaptionLines {
    public static let id = "captionLines-1"
    /// A gap between two words of at least this many ns starts a caption.
    public static let gapBreak: Int64 = 700_000_000
    /// A caption stays this long after its last word.
    public static let tail: Int64 = 300_000_000
    /// A caption lasts at least this long, if there is room.
    public static let minimumDuration: Int64 = 800_000_000

    /// The lines and the characters in each, by the ratio `width / height` of the output.
    public static func capacity(outputSize: SIMD2<Int>) -> (lines: Int, characters: Int) {
        let ratio = Double(outputSize.x) / Double(max(outputSize.y, 1))
        if ratio >= 1.2 { return (2, 42) }
        if ratio >= 0.9 { return (2, 32) }
        return (1, 24)
    }

    public static func captions(of document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) -> [Caption] {
        guard let transcript = document.transcript else { return [] }
        let capacity = capacity(outputSize: outputSize)
        let locale = Locale(identifier: transcript.language)
        let uppercase = document.captions.style.uppercase
        let duration = timeMap.duration

        var groups: [[Item]] = []
        var previous: KeptWord?
        for kept in TranscriptTiming.keptWords(of: document, timeMap: timeMap) {
            let trimmed = kept.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let drawn = uppercase ? trimmed.uppercased(with: locale) : trimmed
            let item = Item(ref: kept.ref, text: drawn, output: kept.output)
            let breaks = transcript.takes[kept.ref.take].words[kept.ref.word].breakBefore
            var startsNew = groups.isEmpty || breaks
            if let previous, !startsNew {
                startsNew = kept.output.lowerBound - previous.output.upperBound >= gapBreak || endsSentence(previous.text)
            }
            if !startsNew, var current = groups.last {
                current.append(item)
                if Self.split(current.map(\.text), capacity: capacity) != nil {
                    groups[groups.count - 1] = current
                } else {
                    startsNew = true
                }
            }
            if startsNew { groups.append([item]) }
            previous = kept
        }

        var captions: [Caption] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let start = first.output.lowerBound
            let nextStart = index + 1 < groups.count ? groups[index + 1][0].output.lowerBound : Int64.max
            var end = Self.added(last.output.upperBound, tail)
            end = max(end, Self.added(start, minimumDuration))
            end = min(end, nextStart, duration)
            guard end > start else { continue }
            let texts = group.map(\.text)
            let breakAt = split(texts, capacity: capacity) ?? texts.count
            var lines: [[CaptionWord]] = []
            for (lineIndex, range) in [0..<breakAt, breakAt..<group.count].enumerated() where !range.isEmpty || lineIndex == 0 {
                lines.append(
                    range.map { position in
                        let wordEnd = position + 1 < group.count ? group[position + 1].output.lowerBound : end
                        let wordStart = group[position].output.lowerBound
                        return CaptionWord(
                            ref: group[position].ref, text: group[position].text, output: wordStart..<max(wordEnd, wordStart))
                    })
            }
            let text = lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
            captions.append(Caption(output: start..<end, lines: lines, text: text))
        }
        return captions
    }

    /// The index of the caption shown at output time `output`; `nil` between captions. `captions` is in order.
    public static func index(atOutput output: Int64, in captions: [Caption]) -> Int? {
        var (low, high) = (0, captions.count)
        while low < high {
            let middle = low + (high - low) / 2
            if captions[middle].output.upperBound <= output { low = middle + 1 } else { high = middle }
        }
        guard low < captions.count, captions[low].output.contains(output) else { return nil }
        return low
    }

    // MARK: - Private

    private struct Item {
        var ref: TranscriptWordRef
        var text: String
        var output: Range<Int64>
    }

    /// Where the words are broken into lines, balanced by characters: the number of words in the first line (all of them
    /// when they fit in one). `nil` if they do not fit the capacity. A lone word always fits, however long.
    static func split(_ words: [String], capacity: (lines: Int, characters: Int)) -> Int? {
        let lengths = words.map(\.count)
        let total = lengths.reduce(0, +) + max(words.count - 1, 0)
        if words.count == 1 || total <= capacity.characters { return words.count }
        guard capacity.lines >= 2, words.count >= 2 else { return nil }
        var best: (breakAt: Int, difference: Int, first: Int)?
        var first = 0
        for breakAt in 1..<words.count {
            first += lengths[breakAt - 1] + (breakAt > 1 ? 1 : 0)
            let second = total - first - 1
            let difference = abs(first - second)
            // Ties go to the first line being the shorter one, which is the earlier break.
            if best == nil || difference < best!.difference { best = (breakAt, difference, first) }
        }
        guard let best else { return nil }
        let second = total - best.first - 1
        return max(best.first, second) <= capacity.characters ? best.breakAt : nil
    }

    /// Whether the word ends a sentence: `.`, `?`, `!` or `…`, ignoring closing quotes and brackets after it.
    private static func endsSentence(_ text: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"'”’»)]}")
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, closers.contains(last) { scalars.removeLast() }
        guard let last = scalars.last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }

    private static func added(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}

/// The measures of the captions' look, `captionStyle-1` (plan decision 10). The render and the editor share them; the
/// font and the text are the render's.
public enum CaptionMetrics {
    public static let id = "captionStyle-1"
    /// The distance of the text box from the bottom or top edge, as a fraction of the output's height.
    public static let edgeMargin = 0.08
    /// The widest line, as a fraction of the output's width.
    public static let maxWidthFraction = 0.9
    public static let boxOpacity = 0.6
    public static let boxCornerEm = 0.3
    /// Horizontal and vertical padding of Classic's box, in em.
    public static let boxPaddingEm = SIMD2(0.6, 0.35)
    public static let outlineEm = 0.08
    public static let shadowOffsetEm = 0.04
    public static let shadowBlurEm = 0.12
    public static let shadowOpacity = 0.5

    /// The nominal font size in output pixels: 0.045, 0.06 or 0.08 of the shorter side.
    public static func fontSize(_ size: OverlaySize, outputSize: SIMD2<Int>) -> Double {
        let fraction: Double
        switch size {
        case .small: fraction = 0.045
        case .medium: fraction = 0.06
        case .large: fraction = 0.08
        }
        return fraction * Double(min(outputSize.x, outputSize.y))
    }

    /// What the captions can take from the edge, in output pixels: the margin, two lines of 1.2 em at the nominal size and
    /// Classic's padding. What the keys (2c) leave free under them when the captions are at the same edge.
    public static func reservedHeight(_ style: CaptionStyle, outputSize: SIMD2<Int>) -> Double {
        let em = fontSize(style.size, outputSize: outputSize)
        return edgeMargin * Double(outputSize.y) + 2 * 1.2 * em + 2 * boxPaddingEm.y * em
    }
}
