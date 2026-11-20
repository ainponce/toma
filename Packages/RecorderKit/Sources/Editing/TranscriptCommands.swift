// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// The commands of editing the video through its transcript (phase 2 design §5.3 and §5.4), as pure functions of the
/// document, one undo step each: the transcription itself, cutting and restoring words, correcting one, starting a
/// caption at one, and taking out the filler words and the long pauses.
///
/// - A word is cut when less than half of its source span stays in the sequence (`TranscriptTiming.isCut`, plan
///   decision 5): the same rule the text strikes through and the captions leave out.
/// - Words are addressed by their place (`TranscriptWordRef`, or a take's index in `transcript.takes` and a range of its
///   words); an index that is not in the transcript, or a document without one, gives `nil`.
/// - Cutting takes out source of the clips (`SequenceCommands.deleteSource`) and restoring gives it back
///   (`SequenceCommands.restore`), so a cut follows the words wherever their clips and speeds are.
public enum TranscriptCommands {
    /// How long before a word its cut starts: the pause before it stays.
    public static let cutLead: Int64 = 40_000_000
    /// How long after the last word of the transcript its cut ends, when no word after it is kept.
    public static let cutTail: Int64 = 200_000_000
    /// How much of a pause stays on each side when it is shortened: 0.4 s in all.
    public static let pauseKeep: Int64 = 200_000_000
    /// The thresholds of "Shorten Pauses": 0.5, 1 and 2 s.
    public static let pauseThresholds: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000]
    public static let defaultPauseThreshold: Int64 = 1_000_000_000
    /// The filler words of each language, frozen as they are below.
    public static let fillersID = "fillers-1"

    // MARK: - The transcription

    /// Puts `transcript` in the document, whole (`transcript.create`, target `/transcript`): from `null` if there was
    /// none, and then, in the same step, the captions shown (plan decision 8). `nil` if it is the one there already.
    public static func create(_ doc: EditDocument, _ transcript: Transcript) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["transcript"], from: doc.transcript, to: transcript)
        if doc.transcript == nil {
            changes.set(["captions", "show"], from: doc.captions.show, to: true)
        }
        return changes.step(label: .transcriptCreate, target: "/transcript")
    }

    /// How many corrections replacing `old` with `new` would lose (plan decision 7): the words of `old` with the same
    /// take, start and end as one of `new` but another text or `breakBefore`, and those with `breakBefore` that have no
    /// such word in `new`.
    public static func lostCorrections(_ old: Transcript, _ new: Transcript) -> Int {
        struct Place: Hashable {
            var take: String
            var start: HostTime
            var end: HostTime
        }
        var partners: [Place: TranscriptWord] = [:]
        for take in new.takes {
            for word in take.words {
                partners[Place(take: take.take, start: word.start, end: word.end)] =
                    partners[Place(take: take.take, start: word.start, end: word.end)] ?? word
            }
        }
        var lost = 0
        for take in old.takes {
            for word in take.words {
                if let partner = partners[Place(take: take.take, start: word.start, end: word.end)] {
                    if partner.text != word.text || partner.breakBefore != word.breakBefore { lost += 1 }
                } else if word.breakBefore {
                    lost += 1
                }
            }
        }
        return lost
    }

    // MARK: - Several takes

    /// Puts the takes of `transcript` in the document's transcription, each in the place of the one of its take there,
    /// and the others as they are (phase 3 design §8.1, plan 3d decision 16): what the user corrected in a take that was
    /// not transcribed again stays. The transcription gets `transcript`'s language and engine. One step,
    /// `transcript.create` with target `/transcript`, as the phase 2's:
    ///
    /// - A take there already is removed and the new one inserted in its place (`EditCollection.transcriptTakes`, whose
    ///   takes are never replaced); another entry of the same take after it (a transcription edited by hand) is removed.
    /// - A take the transcription does not have goes after the others, in the order of `transcript`.
    /// - Without a transcription, it is `create`: the captions shown with it.
    ///
    /// With a transcription, `nil` if that changes nothing or `transcript` has no take.
    public static func mergeTakes(_ doc: EditDocument, _ transcript: Transcript) -> EditStep? {
        guard let old = doc.transcript else { return create(doc, transcript) }
        // The first take of `transcript` of each id, in its order.
        var brought: [String: TranscriptTake] = [:]
        var order: [TranscriptTake] = []
        for take in transcript.takes where brought[take.take] == nil {
            brought[take.take] = take
            order.append(take)
        }
        guard !order.isEmpty else { return nil }
        var changes = DocumentChanges()
        changes.set(["transcript", "language"], from: old.language, to: transcript.language)
        changes.set(["transcript", "engine"], from: old.engine, to: transcript.engine)
        var placed: Set<String> = []
        var duplicates: [Int] = []
        for (index, take) in old.takes.enumerated() {
            guard let new = brought[take.take] else { continue }
            guard placed.insert(take.take).inserted else {
                duplicates.append(index)
                continue
            }
            if new != take {
                changes.remove(take, from: .transcriptTakes, at: index)
                changes.insert(new, into: .transcriptTakes, at: index)
            }
        }
        for index in duplicates.reversed() { changes.remove(old.takes[index], from: .transcriptTakes, at: index) }
        var count = old.takes.count - duplicates.count
        for take in order where !placed.contains(take.take) {
            changes.insert(take, into: .transcriptTakes, at: count)
            count += 1
        }
        return changes.step(label: .transcriptCreate, target: "/transcript")
    }

    /// `lostCorrections(_:_:)` of the takes `takes` alone (by their ids): how many corrections the user made in them that
    /// transcribing them again into `new` would lose. The other takes of `old` are kept by `mergeTakes`, so none of
    /// theirs is lost.
    public static func lostCorrections(_ old: Transcript, _ new: Transcript, inTakes takes: Set<String>) -> Int {
        func only(_ transcript: Transcript) -> Transcript {
            var transcript = transcript
            transcript.takes.removeAll { !takes.contains($0.take) }
            return transcript
        }
        return lostCorrections(only(old), only(new))
    }

    // MARK: - Cut and restore

    /// The source the text's ⌫ cuts for the words `words` of take `take` (design §5.3): from `cutLead` before the first
    /// to `cutLead` before the next word of the take that is kept, or, with none, to `cutTail` after the last; the start
    /// never before host time 0. The pause before the words stays and the one after them goes, as in Descript. `nil` if
    /// that is empty.
    public static func cutRange(_ doc: EditDocument, take: Int, words: ClosedRange<Int>) -> Range<HostTime>? {
        guard let entry = transcriptTake(doc, take, words) else { return nil }
        return cutRange(entry, words: words, clips: takeClips(entry.take, in: doc))
    }

    /// Cuts the words `words` of take `take` (`transcript.cut`): `cutRange` out of the clips (`deleteSource`). `nil` if
    /// every one of them is cut already.
    public static func cut(
        _ doc: EditDocument, take: Int, words: ClosedRange<Int>, makeID: (String) -> String
    ) -> Result<EditStep, SequenceError>? {
        guard let entry = transcriptTake(doc, take, words) else { return nil }
        let clips = takeClips(entry.take, in: doc)
        guard entry.words[words].contains(where: { !TranscriptTiming.isCut($0, take: entry.take, in: clips) }),
            let range = cutRange(entry, words: words, clips: clips)
        else { return nil }
        return SequenceCommands.deleteSource(doc, take: entry.take, ranges: [range], label: .transcriptCut, makeID: makeID)
    }

    /// Gives back the cut words among `words` of take `take`, in one step (`transcript.restore`, plan decision 6): for
    /// each run of cut words one after the other, from `cutLead` before its first to `cutLead` before the word after its
    /// last (cut or not), or, without one, to `cutTail` after its last, as `SequenceCommands.restore` gives source back
    /// within `bounds` (the take's `TakeTimeline.editableBounds`). The exact inverse of their cut. `nil` if none is cut.
    public static func restore(
        _ doc: EditDocument, take: Int, words: ClosedRange<Int>, bounds: ClosedRange<HostTime>, makeID: (String) -> String
    ) -> EditStep? {
        guard let entry = transcriptTake(doc, take, words) else { return nil }
        let clips = takeClips(entry.take, in: doc)
        func isCut(_ j: Int) -> Bool { TranscriptTiming.isCut(entry.words[j], take: entry.take, in: clips) }
        var ranges: [Range<HostTime>] = []
        var first = words.lowerBound
        while first <= words.upperBound {
            guard isCut(first) else {
                first += 1
                continue
            }
            var last = first
            while last < words.upperBound, isCut(last + 1) { last += 1 }
            let start = earlier(entry.words[first].start, by: cutLead)
            let end =
                last + 1 < entry.words.count
                ? earlier(entry.words[last + 1].start, by: cutLead) : later(entry.words[last].end, by: cutTail)
            if start < end { ranges.append(start..<end) }
            first = last + 1
        }
        guard !ranges.isEmpty else { return nil }
        return SequenceCommands.restore(doc, take: entry.take, ranges: ranges, bounds: bounds, makeID: makeID)
    }

    // MARK: - Correct and break

    /// Sets the text of the word `ref` to `text` without the spaces and line breaks at its ends (`transcript.word`,
    /// target the text's pointer): it changes the captions, not the sound. `nil` if that is empty or the word's text.
    public static func correct(_ doc: EditDocument, _ ref: TranscriptWordRef, text: String) -> EditStep? {
        guard let word = word(doc, ref) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != word.text else { return nil }
        let path = wordPath(ref) + ["text"]
        var changes = DocumentChanges()
        changes.set(path, from: word.text, to: trimmed)
        return changes.step(label: .transcriptWord, target: JSONPointer(components: path).string)
    }

    /// "Start a Caption Here": whether a caption starts at the word `ref` (`transcript.break`, target the pointer of its
    /// `breakBefore`). The JSON never holds a `false` (plan decision 5), so the member is added from `null` and taken
    /// away to `null`.
    public static func toggleBreak(_ doc: EditDocument, _ ref: TranscriptWordRef) -> EditStep? {
        guard let word = word(doc, ref) else { return nil }
        let path = JSONPointer(components: wordPath(ref) + ["breakBefore"])
        let change: EditChange =
            word.breakBefore
            ? .set(path: path, before: .bool(true), after: .null) : .set(path: path, before: .null, after: .bool(true))
        return EditStep(label: .transcriptBreak, target: path.string, changes: [change])
    }

    // MARK: - Fillers

    /// Whether `text` is a filler word of `language` (`fillers-1`, design §5.4): the whole word, in lowercase and without
    /// its punctuation, is one of the list of its language. Spanish and English have one (any BCP 47 tag whose language
    /// is `es` or `en`); other languages, none.
    public static func isFiller(_ text: String, language: String) -> Bool {
        let bare = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        return fillerWords(of: language).contains(bare)
    }

    /// The filler words of the transcript that are not cut, in order.
    public static func fillers(in doc: EditDocument) -> [TranscriptWordRef] {
        guard let transcript = doc.transcript else { return [] }
        var fillers: [TranscriptWordRef] = []
        for (i, take) in transcript.takes.enumerated() {
            let clips = takeClips(take.take, in: doc)
            for (j, word) in take.words.enumerated()
            where isFiller(word.text, language: transcript.language)
                && !TranscriptTiming.isCut(word, take: take.take, in: clips)
            {
                fillers.append(TranscriptWordRef(take: i, word: j))
            }
        }
        return fillers
    }

    /// "Remove Filler Words" (`transcript.fillers`): the `cutRange` of each of `fillers(in:)`, worked out on the document
    /// as it is, all in one step. `nil` without any.
    public static func removeFillers(_ doc: EditDocument, makeID: (String) -> String) -> Result<EditStep, SequenceError>? {
        guard let transcript = doc.transcript else { return nil }
        var ranges: [String: [Range<HostTime>]] = [:]
        var clipsByTake: [String: [Clip]] = [:]
        for ref in fillers(in: doc) {
            let take = transcript.takes[ref.take]
            let clips = clipsByTake[take.take] ?? takeClips(take.take, in: doc)
            clipsByTake[take.take] = clips
            if let range = cutRange(take, words: ref.word...ref.word, clips: clips) {
                ranges[take.take, default: []].append(range)
            }
        }
        guard !ranges.isEmpty else { return nil }
        return SequenceCommands.deleteSource(doc, ranges: ranges, label: .transcriptFillers, makeID: makeID)
    }

    // MARK: - Pauses

    /// The pauses of at least `threshold` between words (design §5.4), as the source each one's shortening cuts: between
    /// two words of a take that are kept, one after the other among those kept, whose kept source between them lasts at
    /// least `threshold` (what is cut already is not counted), `[end + pauseKeep, start − pauseKeep)` if at least a frame
    /// of output of it is kept. In the order of the transcript.
    public static func pauses(in doc: EditDocument, threshold: Int64) -> [SourceRange] {
        guard let transcript = doc.transcript else { return [] }
        let frame = SequenceCommands.oneFrame(of: doc)
        let least = UInt64(max(threshold, 0))
        var pauses: [SourceRange] = []
        for take in transcript.takes {
            let clips = takeClips(take.take, in: doc)
            var previous: TranscriptWord?
            for word in take.words where !TranscriptTiming.isCut(word, take: take.take, in: clips) {
                let before = previous
                previous = word
                guard let before, before.end <= word.start, kept(before.end..<word.start, in: clips).source >= least
                else { continue }
                let (start, end) = (later(before.end, by: pauseKeep), earlier(word.start, by: pauseKeep))
                guard start < end, kept(start..<end, in: clips).output >= frame else { continue }
                pauses.append(SourceRange(take: take.take, start: start, end: end))
            }
        }
        return pauses
    }

    /// "Shorten Pauses" (`transcript.pauses`): every one of `pauses(in:threshold:)` cut, in one step. `nil` without any.
    public static func shortenPauses(
        _ doc: EditDocument, threshold: Int64, makeID: (String) -> String
    ) -> Result<EditStep, SequenceError>? {
        var ranges: [String: [Range<HostTime>]] = [:]
        for pause in pauses(in: doc, threshold: threshold) {
            ranges[pause.take, default: []].append(pause.start..<pause.end)
        }
        guard !ranges.isEmpty else { return nil }
        return SequenceCommands.deleteSource(doc, ranges: ranges, label: .transcriptPauses, makeID: makeID)
    }

    // MARK: - Private

    /// The fillers of `fillers-1`, by language.
    private static let spanishFillers: Set<String> = ["eh", "ehh", "ehm", "em", "emm", "mm", "mmm", "mhm", "ah", "ahh"]
    private static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "mmm", "ah"]

    private static func fillerWords(of language: String) -> Set<String> {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        switch code {
        case "es": return spanishFillers
        case "en": return englishFillers
        default: return []
        }
    }

    /// The take `take` of the transcript, if it has the words `words`.
    private static func transcriptTake(_ doc: EditDocument, _ take: Int, _ words: ClosedRange<Int>) -> TranscriptTake? {
        guard let takes = doc.transcript?.takes, takes.indices.contains(take),
            takes[take].words.indices.contains(words.lowerBound), takes[take].words.indices.contains(words.upperBound)
        else { return nil }
        return takes[take]
    }

    private static func word(_ doc: EditDocument, _ ref: TranscriptWordRef) -> TranscriptWord? {
        transcriptTake(doc, ref.take, ref.word...ref.word)?.words[ref.word]
    }

    /// The pointer of the word `ref`, as components.
    private static func wordPath(_ ref: TranscriptWordRef) -> [String] {
        ["transcript", "takes", String(ref.take), "words", String(ref.word)]
    }

    /// The clips of `take`, in the order of the sequence.
    private static func takeClips(_ take: String, in doc: EditDocument) -> [Clip] {
        doc.sequence.filter { $0.take == take }
    }

    /// `cutRange` of `words` of `take`, whose clips are `clips`.
    private static func cutRange(_ take: TranscriptTake, words: ClosedRange<Int>, clips: [Clip]) -> Range<HostTime>? {
        let start = earlier(take.words[words.lowerBound].start, by: cutLead)
        let next = take.words[(words.upperBound + 1)...].first { !TranscriptTiming.isCut($0, take: take.take, in: clips) }
        let end = next.map { earlier($0.start, by: cutLead) } ?? later(take.words[words.upperBound].end, by: cutTail)
        return start < end ? start..<end : nil
    }

    /// How much of the source `range` the clips `clips` keep, in source nanoseconds and in output nanoseconds at their
    /// speeds.
    private static func kept(_ range: Range<HostTime>, in clips: [Clip]) -> (source: UInt64, output: Int64) {
        var (source, output): (UInt64, Int64) = (0, 0)
        for clip in clips {
            let (start, end) = (max(range.lowerBound, clip.start), min(range.upperBound, clip.end))
            guard start < end else { continue }
            // Saturating: clips that overlap (a document edited by hand) never overflow.
            let length = source.addingReportingOverflow(end.nanoseconds - start.nanoseconds)
            source = length.overflow ? .max : length.partialValue
            let shown = output.addingReportingOverflow(
                TimeMap.outputDuration(of: Clip(id: clip.id, take: clip.take, start: start, end: end, speed: clip.speed)))
            output = shown.overflow ? .max : shown.partialValue
        }
        return (source, output)
    }

    /// `nanoseconds` before `t`, never before host time 0.
    private static func earlier(_ t: HostTime, by nanoseconds: Int64) -> HostTime {
        HostTime(nanoseconds: t.nanoseconds - min(t.nanoseconds, UInt64(max(nanoseconds, 0))))
    }

    /// `nanoseconds` after `t`, never past the last host time.
    private static func later(_ t: HostTime, by nanoseconds: Int64) -> HostTime {
        let (sum, overflow) = t.nanoseconds.addingReportingOverflow(UInt64(max(nanoseconds, 0)))
        return HostTime(nanoseconds: overflow ? .max : sum)
    }
}
