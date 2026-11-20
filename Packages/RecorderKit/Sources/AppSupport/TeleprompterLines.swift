// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import CoreText

/// The script as the teleprompter reads it, line by line (plan 3d, T13): where each line breaks, which words of the script
/// (`ScriptWords`) it holds, and where it is, so the teleprompter can draw each line where it was measured and bring the
/// line being read to the reading line (`TeleprompterFollow`).
///
/// Laid out with CoreText in the reader's font: the system font, semibold, at the chosen size, its tracking −0.5 % of the
/// size, centered, 22 % of the size between two lines (the reader of phase 2). A line break of the script starts a line
/// (a blank line is a line with no words); a line that is full wraps at the break CoreText suggests, as the text did. A word
/// is never cut in two: one wider than the line goes alone on its own line, whole.
public struct TeleprompterLines: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// The words of the script on it (indices in `ScriptWords.words`); empty, at the index of the next word, for a line
        /// with no words.
        public let words: Range<Int>
        /// UTF-16 offsets in the script of what it draws: without the spaces it ends with, or its line break.
        public let characters: Range<Int>
        /// From the top of the first line, in points.
        public let top: Double
        public let height: Double

        public init(words: Range<Int>, characters: Range<Int>, top: Double, height: Double) {
            self.words = words
            self.characters = characters
            self.top = top
            self.height = height
        }
    }

    public let lines: [Line]
    /// From the top of the first line to the bottom of the last; 0 without lines.
    public let height: Double

    /// The tracking of the reader's text, as a share of its size.
    public static let trackingShare = -0.005
    /// The space between two lines, as a share of the size.
    public static let lineSpacingShare = 0.22

    /// `script`, whose words are `words`, laid out in the reader's font at `fontSize` points in lines `width` points wide.
    public init(script: String, words: ScriptWords, fontSize: Double, width: Double) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
        let lineHeight = Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let pitch = lineHeight + Self.lineSpacingShare * fontSize
        let breaks = Self.breaks(of: script, words: words, font: font, fontSize: fontSize, width: width)
        var lines: [Line] = []
        var word = 0
        for (index, range) in breaks.enumerated() {
            let first = word
            while word < words.words.count, words.words[word].characters.lowerBound < range.next { word += 1 }
            lines.append(Line(words: first..<word, characters: range.drawn, top: Double(index) * pitch, height: lineHeight))
        }
        self.lines = lines
        height = lines.last.map { $0.top + $0.height } ?? 0
    }

    /// The line `index` is on; `nil` for a word the script does not have.
    public func line(ofWord index: Int) -> Int? {
        guard index >= 0 else { return nil }
        // The first line whose words end after it.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].words.upperBound <= index { low = middle + 1 } else { high = middle }
        }
        guard low < lines.count, lines[low].words.contains(index) else { return nil }
        return low
    }

    /// The index of the line at `y` from the top of the first line: the last one starting at or before it (the first, above
    /// it); `nil` without lines.
    public func line(at y: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].top <= y { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }

    /// Where each line of `script` starts the next one (`next`) and what it draws (`drawn`), in UTF-16 offsets.
    private static func breaks(
        of script: String, words: ScriptWords, font: CTFont, fontSize: Double, width: Double
    ) -> [(drawn: Range<Int>, next: Int)] {
        guard !script.isEmpty else { return [] }
        let utf16 = Array(script.utf16)
        let attributes = [kCTFontAttributeName: font, kCTTrackingAttributeName: trackingShare * fontSize] as CFDictionary
        guard let text = CFAttributedStringCreate(nil, script as CFString, attributes) else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let lineWidth = width > 0 ? width : .greatestFiniteMagnitude
        var breaks: [(drawn: Range<Int>, next: Int)] = []
        for paragraph in paragraphs(of: script) {
            var start = paragraph.lowerBound
            guard !paragraph.isEmpty else {
                breaks.append((start..<start, paragraph.upperBound))
                continue
            }
            while start < paragraph.upperBound {
                let suggested = CTTypesetterSuggestLineBreak(typesetter, start, lineWidth)
                var end = min(start + max(suggested, 1), paragraph.upperBound)
                // A word is never cut: the line ends before it, or holds it whole if it is the first.
                if let cut = word(around: end, in: words), cut.lowerBound < end, end < cut.upperBound {
                    end = cut.lowerBound > start ? cut.lowerBound : cut.upperBound
                }
                // The spaces after the line are its own: the next line starts with something to draw.
                while end < paragraph.upperBound, isSpace(utf16[end]) { end += 1 }
                var drawnEnd = end
                while drawnEnd > start, isSpace(utf16[drawnEnd - 1]) { drawnEnd -= 1 }
                breaks.append((start..<drawnEnd, end))
                start = end
            }
        }
        return breaks
    }

    /// The UTF-16 ranges of the paragraphs of `script`, without the line breaks between them (as `Character.isNewline`
    /// says, as `ScriptWords` does): one for each line break, and one after the last.
    private static func paragraphs(of script: String) -> [Range<Int>] {
        var paragraphs: [Range<Int>] = []
        var start = 0
        var offset = 0
        for character in script {
            let width = character.utf16.count
            if character.isNewline {
                paragraphs.append(start..<offset)
                start = offset + width
            }
            offset += width
        }
        paragraphs.append(start..<offset)
        return paragraphs
    }

    /// The characters of the word of `words` that starts before `offset` and ends after it, if one does.
    private static func word(around offset: Int, in words: ScriptWords) -> Range<Int>? {
        // The last word starting before the offset.
        var low = 0
        var high = words.words.count
        while low < high {
            let middle = (low + high) / 2
            if words.words[middle].characters.lowerBound < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let characters = words.words[low - 1].characters
        return characters.upperBound > offset ? characters : nil
    }

    /// A space or a tab, not a line break: what a line ends with and does not draw.
    private static func isSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace && !Character(scalar).isNewline
    }
}
