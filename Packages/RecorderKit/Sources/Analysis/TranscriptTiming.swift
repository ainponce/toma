// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A word of the transcript by its place: the index of its take in `transcript.takes` and its own in that take's `words`.
/// Ordered by take, then word.
public struct TranscriptWordRef: Hashable, Comparable, Codable, Sendable {
    public var take: Int
    public var word: Int

    public init(take: Int, word: Int) {
        self.take = take
        self.word = word
    }

    public static func < (lhs: TranscriptWordRef, rhs: TranscriptWordRef) -> Bool {
        (lhs.take, lhs.word) < (rhs.take, rhs.word)
    }
}

/// A word that is not cut, with the output time it is seen in.
public struct KeptWord: Equatable, Sendable {
    public var ref: TranscriptWordRef
    public var text: String
    public var output: Range<Int64>

    public init(ref: TranscriptWordRef, text: String, output: Range<Int64>) {
        self.ref = ref
        self.text = text
        self.output = output
    }
}

/// Which words of the transcript survive the cuts (phase 2 plan decision 5): one rule for what the text strikes through,
/// what the captions leave out and what "kept" means when words are deleted.
public enum TranscriptTiming {
    /// The part of the word's source span `[start, end)` that the clips of `take` keep, from 0 to 1. A word of no length
    /// is 1 if its instant is kept and 0 if not.
    public static func keptFraction(of word: TranscriptWord, take: String, in sequence: [Clip]) -> Double {
        let (start, end) = (word.start.nanoseconds, max(word.end.nanoseconds, word.start.nanoseconds))
        var kept: UInt64 = 0
        var instantKept = false
        for clip in sequence where clip.take == take {
            let (clipStart, clipEnd) = (clip.start.nanoseconds, clip.end.nanoseconds)
            if end == start {
                if clipStart <= start, start < clipEnd { instantKept = true }
                continue
            }
            let (low, high) = (max(start, clipStart), min(end, clipEnd))
            if low < high { kept += high - low }
        }
        if end == start { return instantKept ? 1 : 0 }
        return Double(min(kept, end - start)) / Double(end - start)
    }

    /// Whether less than half of the word's span stays in the sequence.
    public static func isCut(_ word: TranscriptWord, take: String, in sequence: [Clip]) -> Bool {
        keptFraction(of: word, take: take, in: sequence) < 0.5
    }

    /// The words that are not cut, in output order, each over the output range of its kept part (the cuts inside it
    /// closed). `[]` without a transcript.
    public static func keptWords(of document: EditDocument, timeMap: TimeMap) -> [KeptWord] {
        guard let transcript = document.transcript else { return [] }
        var result: [KeptWord] = []
        for (takeIndex, take) in transcript.takes.enumerated() {
            let clips = document.sequence.filter { $0.take == take.take }
            guard !clips.isEmpty else { continue }
            for (wordIndex, word) in take.words.enumerated() {
                guard !isCut(word, take: take.take, in: clips) else { continue }
                let range: Range<Int64>?
                if word.end > word.start {
                    range = timeMap.outputRange(ofSource: word.start..<word.end, take: take.take)
                } else {
                    range = timeMap.output(atSource: word.start, take: take.take).map { $0..<$0 }
                }
                guard let range else { continue }
                result.append(
                    KeptWord(ref: TranscriptWordRef(take: takeIndex, word: wordIndex), text: word.text, output: range))
            }
        }
        result.sort { ($0.output.lowerBound, $0.ref) < ($1.output.lowerBound, $1.ref) }
        return result
    }
}
