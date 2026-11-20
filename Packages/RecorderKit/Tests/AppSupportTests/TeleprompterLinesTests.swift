// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Foundation
import Testing

@Suite struct TeleprompterLinesTests {
    /// The reader's width: the teleprompter's, less 28 pt on each side.
    static let width = 584.0

    /// `count` words of a Spanish script, with its signs, in sentences.
    static func script(words count: Int) -> String {
        let vocabulary = ["Hoy", "vamos", "a", "ver", "cómo", "se", "graba", "la", "pantalla", "con", "Toma,", "paso", "a", "paso."]
        return (0..<count).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
    }

    @Test func linesCoverEveryWordInOrder() {
        let script = Self.script(words: 120)
        let words = ScriptWords(script)
        #expect(words.words.count == 120)
        let lines = TeleprompterLines(script: script, words: words, fontSize: 22, width: Self.width)
        // About eight words a line at 22 pt.
        #expect((8...30).contains(lines.lines.count))
        var next = 0
        var previous: TeleprompterLines.Line?
        for line in lines.lines {
            #expect(line.words.lowerBound == next)
            #expect(!line.words.isEmpty)
            next = line.words.upperBound
            #expect(line.height > 0)
            if let previous {
                #expect(line.top > previous.top)
                // The line spacing of today: 22 % of the size between two lines.
                #expect(abs(line.top - (previous.top + previous.height + 0.22 * 22)) < 1e-9)
                #expect(line.characters.lowerBound >= previous.characters.upperBound)
            } else {
                #expect(line.top == 0)
            }
            // Its words are in what it draws, which neither starts nor ends with a space.
            for index in line.words {
                #expect(line.characters.contains(words.words[index].characters.lowerBound))
                #expect(words.words[index].characters.upperBound <= line.characters.upperBound)
            }
            let drawn = Self.text(of: line, in: script)
            #expect(drawn.first?.isWhitespace == false && drawn.last?.isWhitespace == false)
            previous = line
        }
        #expect(next == 120)
        let last = lines.lines[lines.lines.count - 1]
        #expect(lines.height == last.top + last.height)
        for index in 0..<120 {
            let line = lines.line(ofWord: index)
            #expect(line.map { lines.lines[$0].words.contains(index) } == true)
        }
        #expect(lines.line(ofWord: 120) == nil && lines.line(ofWord: -1) == nil)
        // The same words, larger: more lines; smaller: fewer.
        #expect(TeleprompterLines(script: script, words: words, fontSize: 40, width: Self.width).lines.count > lines.lines.count)
        #expect(TeleprompterLines(script: script, words: words, fontSize: 14, width: Self.width).lines.count < lines.lines.count)
        // Nothing to read, nothing to lay out.
        let empty = TeleprompterLines(script: "", words: ScriptWords(""), fontSize: 22, width: Self.width)
        #expect(empty.lines.isEmpty && empty.height == 0)
    }

    @Test func longerWordsWrapAndNewlinesBreak() {
        // A line break starts a line, the words after it on the next one.
        let broken = "Uno dos\nTres"
        let lines = TeleprompterLines(script: broken, words: ScriptWords(broken), fontSize: 22, width: Self.width)
        #expect(lines.lines.map(\.words) == [0..<2, 2..<3])
        #expect(lines.lines.map { Self.text(of: $0, in: broken) } == ["Uno dos", "Tres"])
        // A blank line is a line of its own, with nothing to say.
        let blank = "Uno\n\nDos"
        let blankLines = TeleprompterLines(script: blank, words: ScriptWords(blank), fontSize: 22, width: Self.width)
        #expect(blankLines.lines.map(\.words) == [0..<1, 1..<1, 1..<2])
        #expect(blankLines.lines[1].characters.isEmpty && blankLines.lines[1].height == blankLines.lines[0].height)
        #expect(blankLines.line(ofWord: 1) == 2)
        // A word wider than the line goes alone, whole: never cut in two.
        let long = "a " + String(repeating: "m", count: 80) + " b"
        let longLines = TeleprompterLines(script: long, words: ScriptWords(long), fontSize: 22, width: Self.width)
        #expect(longLines.lines.map(\.words) == [0..<1, 1..<2, 2..<3])
        #expect(longLines.lines.map { Self.text(of: $0, in: long) } == ["a", String(repeating: "m", count: 80), "b"])
        // Words that do not fit together wrap at a space, as the text did.
        let wrapped = String(repeating: "palabra ", count: 30)
        let wrappedLines = TeleprompterLines(script: wrapped, words: ScriptWords(wrapped), fontSize: 22, width: Self.width)
        #expect(wrappedLines.lines.count > 1)
        #expect(wrappedLines.lines.allSatisfy { Self.text(of: $0, in: wrapped).split(separator: " ").allSatisfy { $0 == "palabra" } })
    }

    @Test func followOffsetPutsTheLineAtAThird() {
        #expect(TeleprompterFollow.readingLineShare == 1.0 / 3)
        let script = Self.script(words: 120)
        let lines = TeleprompterLines(script: script, words: ScriptWords(script), fontSize: 22, width: Self.width)
        let line = lines.lines[5]
        let offset = TeleprompterFollow.offset(showing: line, readingHeight: 122, leadIn: 40, maximum: 1000)
        #expect(abs(offset - (line.top - 122.0 / 3 + 40)) < 1e-9)
        // Never past the end, nor before the top.
        #expect(TeleprompterFollow.offset(showing: line, readingHeight: 122, leadIn: 40, maximum: 100) == 100)
        #expect(TeleprompterFollow.offset(showing: lines.lines[0], readingHeight: 122, leadIn: 40, maximum: 1000) == 0)
        #expect(TeleprompterFollow.offset(showing: line, readingHeight: 122, leadIn: 40, maximum: -30) == 0)
        // And back: the line at the reading line, and its first word.
        #expect(TeleprompterFollow.word(atOffset: offset, lines: lines, readingHeight: 122, leadIn: 40) == line.words.lowerBound)
        #expect(TeleprompterFollow.word(atOffset: 0, lines: lines, readingHeight: 122, leadIn: 40) == 0)
        #expect(TeleprompterFollow.word(atOffset: 0, lines: TeleprompterLines(script: "", words: ScriptWords(""), fontSize: 22, width: Self.width), readingHeight: 122, leadIn: 40) == 0)
    }

    @Test func spokenWordsNeverGoBack() {
        let script = ScriptWords("Hoy vamos a ver cómo se graba la pantalla con Toma, paso a paso.")
        var place = TeleprompterFollow.Place(script: script, from: 0)
        #expect(place.word == 0)
        // Volatile words move it ahead on trial.
        place.hear("Hoy vamos a ver", isFinal: false)
        #expect(place.word == 4)
        // The next volatile result replaces it: it says less, and nothing goes back.
        place.hear("Hoy vamos", isFinal: false)
        #expect(place.word == 4)
        // The final one says less than the volatile did: still where it was shown.
        place.hear("Hoy vamos a", isFinal: true)
        #expect(place.word == 4 && place.alignment.position == 3)
        // What comes next is aligned on what was confirmed.
        place.hear("ver cómo se graba", isFinal: true)
        #expect(place.word == 7 && place.alignment.position == 7)
        // Ad libs and a repetition move nothing.
        place.hear("eh bueno se graba", isFinal: true)
        #expect(place.word == 7)
        // From a word of a re-record, the words before it are said.
        let rerecord = TeleprompterFollow.Place(script: script, from: 11)
        #expect(rerecord.word == 11)
        #expect(TeleprompterFollow.Place(script: script, from: 99).word == script.words.count)
    }
}

extension TeleprompterLinesTests {
    /// What `line` draws of `script`.
    static func text(of line: TeleprompterLines.Line, in script: String) -> String {
        let utf16 = script.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: line.characters.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: line.characters.upperBound)
        return String(script[start..<end])
    }
}
