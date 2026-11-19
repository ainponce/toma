// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A run of text an engine heard, with the time of its audio (`SpeechTranscriber`'s runs of `audioTimeRange`): what
/// `TranscriptWords` makes words of.
public struct SpeechRun: Equatable, Sendable {
    public var text: String
    /// Seconds on the take's timeline, from `TrackAudio.origin`; `nil`, a run without a time.
    public var start: Double?
    /// Seconds on the take's timeline, excluded; `nil`, a run without a time.
    public var end: Double?

    public init(text: String, start: Double?, end: Double?) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The words of what an engine heard (phase 2 design §5.1, plan decision 4).
///
/// Each run is split at its spaces. A piece without letters or digits (punctuation) joins the word before it, or the
/// next one when it starts with `¿` or `¡` or there is no word before it. A run with several words shares its time out
/// among them in proportion to their letters and digits (at least 1 each). The pieces of a run without a time join the
/// word before them, after a space (the next one when there is none). The words are in order and never overlap: one
/// that starts before the end of the one before it starts at that end.
public enum TranscriptWords {
    /// The words of `runs`, in source host time: a run's second `s` is `origin` plus `s` seconds.
    public static func words(from runs: [SpeechRun], origin: HostTime) -> [TranscriptWord] {
        var builder = Builder()
        for run in runs { builder.add(run) }
        return builder.words(origin: origin)
    }

    /// `words` without the quiet at their edges: a word that starts in one of `quiet` (the track's quiet spans, in
    /// order and apart, as `SilenceFinder` finds them) starts where that span ends, and one that ends in one ends where
    /// it starts, as long as something of the word is left; a word that is all quiet stays as it is.
    ///
    /// `SpeechTranscriber` (macOS 26.6) times the first word of what it hears after a pause from up to a second before
    /// it is said, and the last one before a pause up to half a second after: the pause would be part of the words.
    static func trimmed(_ words: [TranscriptWord], quiet: [Range<HostTime>]) -> [TranscriptWord] {
        guard !quiet.isEmpty else { return words }
        return words.map { word in
            var word = word
            // The quiet span the word starts in: the first that ends after its start, if it starts at or before it.
            if let span = quiet.first(endingAfter: word.start), span.lowerBound <= word.start, span.upperBound < word.end {
                word.start = span.upperBound
            }
            // The quiet span its last instant is in: the first that ends at its end or after, if it starts before it.
            if let span = quiet.first(endingAfter: word.end, orAt: true), span.lowerBound < word.end, span.lowerBound > word.start {
                word.end = span.lowerBound
            }
            return word
        }
    }

    /// How many letters and digits `text` has: what a word's share of its run's time goes by.
    static func letters(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    }
}

/// Builds the words of a sequence of runs, one run at a time, in seconds of the take's timeline.
private struct Builder {
    private struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    private var made: [Word] = []
    /// Text heard before a word that has not come yet: punctuation that opens it (`¿`, `¡`), or pieces with nothing
    /// before them to join. Kept in order: what comes while it waits, waits with it.
    private var pending = ""
    /// Whether a word, or punctuation that opens one, goes after a space when it follows `pending`.
    private var pendingSpace = false

    mutating func add(_ run: SpeechRun) {
        let pieces = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return }
        guard let start = run.start, let end = run.end, start.isFinite, end.isFinite else {
            for piece in pieces { addUntimed(piece) }
            return
        }
        // The run's own words, each with its share of the run's time.
        var own: [(text: String, share: Int)] = []
        for piece in pieces {
            let letters = TranscriptWords.letters(piece)
            if letters > 0 {
                own.append((takePending() + piece, letters))
            } else if !pending.isEmpty || opensAWord(piece) || (own.isEmpty && made.isEmpty) {
                addPending(piece)
            } else if own.isEmpty {
                made[made.count - 1].text += piece
            } else {
                own[own.count - 1].text += piece
            }
        }
        guard !own.isEmpty else { return }
        let total = Double(own.reduce(0) { $0 + max(1, $1.share) })
        let length = max(end, start) - start
        var before = 0
        for word in own {
            // The same expression for one word's end and the next one's start: they meet exactly.
            let from = start + length * Double(before) / total
            before += max(1, word.share)
            let to = Double(before) == total ? start + length : start + length * Double(before) / total
            made.append(Word(text: word.text, start: from, end: to))
        }
    }

    /// A piece of a run without a time: it joins the word before it, after a space (punctuation without one).
    private mutating func addUntimed(_ piece: String) {
        let isWord = TranscriptWords.letters(piece) > 0
        if pending.isEmpty, !made.isEmpty, isWord || !opensAWord(piece) {
            made[made.count - 1].text += isWord ? " " + piece : piece
        } else {
            addPending(piece)
        }
    }

    /// Adds `piece` to what waits for the next word: a word or punctuation that opens one after a space when it
    /// follows a word, punctuation that closes one right after what is there.
    private mutating func addPending(_ piece: String) {
        let isWord = TranscriptWords.letters(piece) > 0
        if isWord || opensAWord(piece) {
            pending += pendingSpace ? " " + piece : piece
            pendingSpace = isWord
        } else {
            pending += piece
        }
    }

    private func opensAWord(_ piece: String) -> Bool {
        piece.first == "¿" || piece.first == "¡"
    }

    /// `pending`, as the start of the word that comes now.
    private mutating func takePending() -> String {
        defer {
            pending = ""
            pendingSpace = false
        }
        return pendingSpace ? pending + " " : pending
    }

    /// The words, in order and apart, with what still waits for a word at the end of the last one.
    mutating func words(origin: HostTime) -> [TranscriptWord] {
        // What waits after the last word starts with a word or with punctuation that opens one.
        if !pending.isEmpty, !made.isEmpty { made[made.count - 1].text += " " + pending }
        // In the order of their starts; the engine's order among equal ones.
        let ordered = made.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        var words: [TranscriptWord] = []
        words.reserveCapacity(ordered.count)
        for (_, word) in ordered {
            var start = origin.adding(seconds: word.start)
            if let last = words.last, start < last.end { start = last.end }
            let end = max(origin.adding(seconds: word.end), start)
            words.append(TranscriptWord(start: start, end: end, text: word.text))
        }
        return words
    }
}

extension [Range<HostTime>] {
    /// The first of these spans (in order and apart) that ends after `time`, or at it with `orAt`.
    fileprivate func first(endingAfter time: HostTime, orAt: Bool = false) -> Range<HostTime>? {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].upperBound > time || (orAt && self[middle].upperBound == time) { high = middle } else { low = middle + 1 }
        }
        return low < count ? self[low] : nil
    }
}
