// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// `teleprompterAlign-1`: where in a script the speaker is, from the words heard. Frozen: a change is a new id.
///
/// For each word heard, the nearest word of the script at or after the position that is similar enough (`1 - Levenshtein /
/// longer length >= 0.75`) within the next 40 words moves the position past it. Failing that, a similar word in the 3 before
/// the position is a repetition and moves nothing. A jump of more than 5 words is held until the next word heard matches
/// the word after the candidate. The position never goes back, and what is not in the script (ad libs) moves nothing.
public struct TeleprompterAlignment: Equatable, Sendable {
    public static let id = "teleprompterAlign-1"
    public static let minimumSimilarity = 0.75, behind = 3, ahead = 40, bigJump = 5

    public let script: ScriptWords
    /// The next word of the script to be said (0: none said).
    public private(set) var position: Int
    /// A big jump waiting for its second match: the script index of the first word that matched.
    private var pending: Int?

    public init(script: ScriptWords, at position: Int = 0) {
        self.script = script
        self.position = min(max(position, 0), script.words.count)
        self.pending = nil
    }

    /// Final words: confirms them.
    public mutating func hear(_ words: [String]) {
        for word in words {
            let heard = ScriptWords.normalized(word)
            guard !heard.isEmpty else { continue }
            listen(to: heard)
        }
    }

    /// Volatile words, on trial over what is confirmed: the alignment they would give, without changing this one.
    public func trying(_ words: [String]) -> TeleprompterAlignment {
        var copy = self
        copy.hear(words)
        return copy
    }

    /// `1 - Levenshtein(a, b) / max(length a, length b)`, over the characters as given; two empty strings are 1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let (x, y) = (Array(a.unicodeScalars), Array(b.unicodeScalars))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var row = previous
        for i in 1...x.count {
            row[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                row[j] = min(substitution, previous[j] + 1, row[j - 1] + 1)
            }
            swap(&previous, &row)
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }

    private func matches(_ heard: String, _ index: Int) -> Bool {
        index >= 0 && index < script.words.count
            && Self.similarity(heard, script.words[index].text) >= Self.minimumSimilarity
    }

    private mutating func listen(to heard: String) {
        if let candidate = pending {
            pending = nil
            if matches(heard, candidate + 1) {
                position = max(position, candidate + 2)
                return
            }
        }
        let end = min(position + Self.ahead, script.words.count)
        if position < end, let found = (position..<end).first(where: { matches(heard, $0) }) {
            if found - position > Self.bigJump {
                pending = found
            } else {
                position = found + 1
            }
        }
        // A match in the words just before the position is a repetition: it moves nothing (and so needs no search).
    }
}

/// Where the speaker was at a time of the output, from the transcript and the script.
public enum ScriptPosition {
    /// The words of the transcript that are said before output time `τ` (their kept span ends at or before it), in the
    /// order of the output.
    public static func spokenWords(before τ: Int64, in document: EditDocument, timeMap: TimeMap) -> [String] {
        TranscriptTiming.keptWords(of: document, timeMap: timeMap).filter { $0.output.upperBound <= τ }.map(\.text)
    }

    /// The next word of `script` to say after `spoken`, aligned with `teleprompterAlign-1`; 0 if none matches. Pass it to
    /// `ScriptWords.sentenceStart(of:)` to begin at the start of that sentence.
    public static func word(in script: ScriptWords, spoken: [String]) -> Int {
        var alignment = TeleprompterAlignment(script: script)
        alignment.hear(spoken)
        return alignment.position
    }
}
