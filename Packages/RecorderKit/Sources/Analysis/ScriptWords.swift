// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The words of a project script, for aligning what is heard with what is written (`teleprompterAlign-1`).
///
/// A word is a run of letters and digits; any other character (spaces, signs, hyphens, dashes) separates words, except an
/// apostrophe between two letters ("don't" is one word). Each word keeps its normalized text and the UTF-16 range it
/// occupies in the script, so the teleprompter can find it in the text it shows.
public struct ScriptWords: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        /// Lower case, without accents, signs or spaces.
        public let text: String
        /// UTF-16 offsets of the word in the script, as written.
        public let characters: Range<Int>

        public init(text: String, characters: Range<Int>) {
            self.text = text
            self.characters = characters
        }
    }

    public let words: [Word]
    /// `breaksAfter[i]`: a sentence ends after word `i` (`.`, `?`, `!` or `…` before a space, or a line break).
    private let breaksAfter: [Bool]

    public init(_ script: String) {
        var words: [Word] = []
        var breaks: [Bool] = []
        var offset = 0
        var current: (text: String, start: Int)?
        var gap: [Character] = []
        let characters = Array(script)

        func finishWord(at end: Int) {
            guard let word = current else { return }
            current = nil
            let text = ScriptWords.normalized(word.text)
            guard !text.isEmpty else { return }
            words.append(Word(text: text, characters: word.start..<end))
            breaks.append(false)
            gap = []
        }

        for (index, character) in characters.enumerated() {
            let width = character.utf16.count
            let isWordCharacter =
                character.isLetter || character.isNumber
                || (ScriptWords.isApostrophe(character) && current != nil && index + 1 < characters.count
                    && (characters[index + 1].isLetter || characters[index + 1].isNumber))
            if isWordCharacter {
                if current == nil {
                    if !words.isEmpty, ScriptWords.endsSentence(gap) { breaks[breaks.count - 1] = true }
                    gap = []
                    current = ("", offset)
                }
                current?.text.append(character)
            } else {
                finishWord(at: offset)
                gap.append(character)
            }
            offset += width
        }
        finishWord(at: offset)
        self.words = words
        self.breaksAfter = breaks
    }

    /// `text` in lower case, without accents or any character that is not a letter or a digit ("¿Qué?" is "que").
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    /// The first word of the sentence that word `index` is in. Out-of-range indices are clamped; an empty script is 0.
    public func sentenceStart(of index: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        var start = min(max(index, 0), words.count - 1)
        while start > 0, !breaksAfter[start - 1] { start -= 1 }
        return start
    }

    private static func isApostrophe(_ character: Character) -> Bool { character == "'" || character == "\u{2019}" }

    /// The characters between two words end a sentence: a line break, or `.`/`?`/`!`/`…` followed by a space ("3.5" and
    /// "a.b" do not).
    private static func endsSentence(_ gap: [Character]) -> Bool {
        if gap.contains(where: { $0.isNewline }) { return true }
        let terminated = gap.contains { $0 == "." || $0 == "?" || $0 == "!" || $0 == "\u{2026}" }
        return terminated && gap.contains { $0.isWhitespace }
    }
}
