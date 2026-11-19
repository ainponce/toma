// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The transcript as the Captions tab's Text shows it (phase 2 design §5.3, plan 2a Task A11): every word of it, cut or
/// not, as running text in the order of the transcript, and the rules of the tab that are not drawing.
///
/// - Words are separated by a space, or by a paragraph (`"\n\n"`) where the source gap from the word before is at least
///   `paragraphPause`, and at the start of each take after the first. A line break inside a word's text (written by
///   hand) shows as a space, so the paragraphs are only the pauses'.
/// - The places are UTF-16 code units, as `NSString` and `NSTextView` count them.
/// - A word is cut by the one rule of the tab, the captions and the commands (`TranscriptTiming.isCut`): it is struck
///   through and dimmed, and still in the text, so it can be restored.
/// - A selection is of whole words (`words(inCharacters:)`); one of spaces only selects nothing.
public struct TranscriptText: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var ref: TranscriptWordRef
        /// Its text's place in `string`, in UTF-16 code units.
        public var characters: Range<Int>
        public var isCut: Bool
        /// A caption starts at it ("Start a Caption Here").
        public var breakBefore: Bool

        public init(ref: TranscriptWordRef, characters: Range<Int>, isCut: Bool, breakBefore: Bool = false) {
            self.ref = ref
            self.characters = characters
            self.isCut = isCut
            self.breakBefore = breakBefore
        }
    }

    /// The words of a selection that are of one take of the transcript, by their places in that take.
    public struct TakeRun: Equatable, Sendable {
        /// The take's index in `transcript.takes`.
        public var take: Int
        public var words: ClosedRange<Int>

        public init(take: Int, words: ClosedRange<Int>) {
            self.take = take
            self.words = words
        }
    }

    /// A source gap of at least this long between two words starts a paragraph.
    public static let paragraphPause: Int64 = 1_500_000_000
    /// The word being said stays so for this long after its end at most, if the next one has not started: a pause
    /// longer than that shows no word being said, a shorter one no flicker.
    public static let playingLinger: Int64 = 1_000_000_000

    public var string: String
    /// Every word of the transcript, in its order (by take, then word).
    public var words: [Word]
    /// The index in `words` of the first word of each take of the transcript.
    public var takeStarts: [Int]

    /// The text of `document`'s transcript; empty without one.
    public init(document: EditDocument) {
        var string = ""
        var length = 0
        var words: [Word] = []
        var takeStarts: [Int] = []
        let takes = document.transcript?.takes ?? []
        for (takeIndex, take) in takes.enumerated() {
            takeStarts.append(words.count)
            let clips = document.sequence.filter { $0.take == take.take }
            words.reserveCapacity(words.count + take.words.count)
            var previous: TranscriptWord?
            for (wordIndex, word) in take.words.enumerated() {
                if !words.isEmpty {
                    let paragraph = previous.map { Self.gap(from: $0, to: word) >= UInt64(Self.paragraphPause) } ?? true
                    let separator = paragraph ? "\n\n" : " "
                    string += separator
                    length += separator.utf16.count
                }
                let shown = Self.shown(word.text)
                let count = shown.utf16.count
                words.append(
                    Word(
                        ref: TranscriptWordRef(take: takeIndex, word: wordIndex), characters: length..<(length + count),
                        isCut: TranscriptTiming.isCut(word, take: take.take, in: clips), breakBefore: word.breakBefore))
                string += shown
                length += count
                previous = word
            }
        }
        self.string = string
        self.words = words
        self.takeStarts = takeStarts
    }

    // MARK: - Places

    /// The word whose text has the UTF-16 offset `offset`; `nil` on a space or a paragraph between words.
    public func word(atCharacter offset: Int) -> TranscriptWordRef? {
        wordIndex(atCharacter: offset).map { words[$0].ref }
    }

    /// The index in `words` of the word whose text has the UTF-16 offset `offset`; `nil` between words.
    public func wordIndex(atCharacter offset: Int) -> Int? {
        // The last word starting at or before `offset`.
        var (low, high) = (0, words.count)
        while low < high {
            let middle = low + (high - low) / 2
            if words[middle].characters.lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0, words[low - 1].characters.contains(offset) else { return nil }
        return low - 1
    }

    /// The words (indices in `words`) a selection of the UTF-16 range `range` is of: those it touches, whole. An empty
    /// range is the word it is in (a click); a range of spaces only, or past the text, is none.
    public func words(inCharacters range: Range<Int>) -> ClosedRange<Int>? {
        if range.isEmpty { return wordIndex(atCharacter: range.lowerBound).map { $0...$0 } }
        // The first word ending after the range starts, and the last starting before it ends.
        var (low, high) = (0, words.count)
        while low < high {
            let middle = low + (high - low) / 2
            if words[middle].characters.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        let first = low
        (low, high) = (first, words.count)
        while low < high {
            let middle = low + (high - low) / 2
            if words[middle].characters.lowerBound < range.upperBound { low = middle + 1 } else { high = middle }
        }
        let last = low - 1
        guard first < words.count, first <= last else { return nil }
        return first...last
    }

    /// The UTF-16 range of the words `words`, from the start of the first to the end of the last.
    public func characters(of words: ClosedRange<Int>) -> Range<Int> {
        self.words[words.lowerBound].characters.lowerBound..<self.words[words.upperBound].characters.upperBound
    }

    /// The index in `words` of the word `ref`; `nil` if the transcript has none there.
    public func index(of ref: TranscriptWordRef) -> Int? {
        guard takeStarts.indices.contains(ref.take), ref.word >= 0 else { return nil }
        let end = ref.take + 1 < takeStarts.count ? takeStarts[ref.take + 1] : words.count
        let index = takeStarts[ref.take] + ref.word
        return index < end ? index : nil
    }

    /// The words `words` by take, as the commands of the transcript take them (a take and its words' places in it).
    public func takeRuns(_ words: ClosedRange<Int>) -> [TakeRun] {
        var runs: [TakeRun] = []
        var first = words.lowerBound
        while first <= words.upperBound, first < self.words.count {
            let take = self.words[first].ref.take
            var last = first
            while last < words.upperBound, last + 1 < self.words.count, self.words[last + 1].ref.take == take { last += 1 }
            runs.append(TakeRun(take: take, words: self.words[first].ref.word...self.words[last].ref.word))
            first = last + 1
        }
        return runs
    }

    /// Whether any of `words` is cut ("Restore" can give it back).
    public func hasCut(_ words: ClosedRange<Int>) -> Bool {
        slice(words).contains { $0.isCut }
    }

    /// Whether any of `words` is not cut ("Cut" takes it out).
    public func hasKept(_ words: ClosedRange<Int>) -> Bool {
        slice(words).contains { !$0.isCut }
    }

    /// The words (indices in `words`) after which each of `pauses` (`TranscriptCommands.pauses`) is, where the text
    /// marks it: the word kept last before the pause starts, past the cut words inside the pause. A pause of a take the
    /// transcript does not have is left out.
    public func wordsBefore(pauses: [SourceRange], in document: EditDocument) -> [Int] {
        guard let takes = document.transcript?.takes else { return [] }
        var takeIndex: [String: Int] = [:]
        for (index, take) in takes.enumerated() where takeIndex[take.take] == nil { takeIndex[take.take] = index }
        var result: [Int] = []
        for pause in pauses {
            guard let t = takeIndex[pause.take], takeStarts.indices.contains(t) else { continue }
            let take = takes[t].words
            // The last word starting before the pause.
            var (low, high) = (0, take.count)
            while low < high {
                let middle = low + (high - low) / 2
                if take[middle].start < pause.start { low = middle + 1 } else { high = middle }
            }
            var j = low - 1
            while j >= 0, words[takeStarts[t] + j].isCut { j -= 1 }
            if j >= 0 { result.append(takeStarts[t] + j) }
        }
        return result
    }

    // MARK: - Playback

    /// The word being said at output time `output`, among `kept` (`TranscriptTiming.keptWords`, in output order): the
    /// last one started by then, until `playingLinger` after its end. `nil` before the first and in a long pause.
    public static func playingWord(atOutput output: Int64, in kept: [KeptWord]) -> TranscriptWordRef? {
        var (low, high) = (0, kept.count)
        while low < high {
            let middle = low + (high - low) / 2
            if kept[middle].output.lowerBound <= output { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let word = kept[low - 1]
        let (until, overflow) = word.output.upperBound.addingReportingOverflow(playingLinger)
        return overflow || output < until ? word.ref : nil
    }

    /// Where a click on the word `ref` puts the playhead, in output ns: where it is seen if it is not cut; if it is,
    /// the first instant kept after it. `nil` for a word the transcript does not have, or a cut one nothing is kept
    /// after.
    public static func seekOutput(of ref: TranscriptWordRef, in document: EditDocument, timeMap: TimeMap) -> Int64? {
        guard let takes = document.transcript?.takes, takes.indices.contains(ref.take),
            takes[ref.take].words.indices.contains(ref.word)
        else { return nil }
        let take = takes[ref.take]
        let word = take.words[ref.word]
        let clips = document.sequence.filter { $0.take == take.take }
        guard TranscriptTiming.isCut(word, take: take.take, in: clips) else {
            if word.end > word.start, let range = timeMap.outputRange(ofSource: word.start..<word.end, take: take.take) {
                return range.lowerBound
            }
            return timeMap.output(atSource: word.start, take: take.take)
                ?? timeMap.firstKeptOutput(atOrAfter: word.start, take: take.take)
        }
        return timeMap.firstKeptOutput(atOrAfter: max(word.end, word.start), take: take.take)
    }

    /// The first frame of the grid at `frameRate` whose time is at or after `output`, within the `frameCount` frames:
    /// the frame that shows what starts there.
    public static func firstFrame(atOrAfter output: Int64, frameRate: Int, frameCount: Int) -> Int {
        let rate = max(frameRate, 1)
        var frame = Int((Double(max(output, 0)) * Double(rate) / 1e9).rounded(.up))
        while frame > 0, Int64(TimeMap.frameTime(frame - 1, frameRate: rate)) >= output { frame -= 1 }
        while Int64(TimeMap.frameTime(frame, frameRate: rate)) < output { frame += 1 }
        return min(max(frame, 0), max(frameCount - 1, 0))
    }

    // MARK: - Private

    /// The words of `range` that there are.
    private func slice(_ range: ClosedRange<Int>) -> ArraySlice<Word> {
        let (low, high) = (max(range.lowerBound, 0), min(range.upperBound, words.count - 1))
        return low <= high ? words[low...high] : []
    }

    /// The source time between the end of `previous` and the start of `word`; 0 if they touch or overlap.
    private static func gap(from previous: TranscriptWord, to word: TranscriptWord) -> UInt64 {
        word.start > previous.end ? word.start.nanoseconds - previous.end.nanoseconds : 0
    }

    /// A word's text as the text shows it: its line breaks and tabs as spaces.
    private static func shown(_ text: String) -> String {
        guard text.contains(where: { $0.isNewline || $0 == "\t" }) else { return text }
        return String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }
}
