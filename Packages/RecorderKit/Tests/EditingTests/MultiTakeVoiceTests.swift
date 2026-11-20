// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// Two takes in one document (phase 3 design §8.1 and §9), namespaced so that no other file of EditingTests meets its
/// names: `take-001` from `origin` and `take-002` from 60 s later, each a timeline of 30 s of `display-1`, at 60 fps.
/// Each take has a transcription of its own: the words `<prefix>0`…`<prefix>9`, each `<prefix>i` over [i s, i + 0.5 s)
/// of its take.
private enum TwoTakes {
    static let first = "take-001"
    static let second = "take-002"
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)

    /// The source instant `seconds` after the start of `take`.
    static func at(_ take: String, _ seconds: Double) -> HostTime {
        origin.adding(seconds: (take == second ? 60 : 0) + seconds)
    }

    /// `take`'s editable timeline, [0 s, 30 s].
    static func bounds(_ take: String) -> ClosedRange<HostTime> { at(take, 0)...at(take, 30) }

    static func record(_ take: String) -> TakeRecord {
        TakeRecord(
            id: take, status: .complete, startedAt: Date(timeIntervalSince1970: take == second ? 1_800_000_060 : 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "display-1", kind: .display, source: TrackSource(name: "Display", displayID: 1),
                    segments: [
                        SegmentRecord(
                            index: 1, file: "takes/\(take)/display-1/seg-0001.mov", startHostTime: at(take, 0),
                            endHostTime: at(take, 30), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                    ])
            ])
    }

    static func clip(_ number: Int, _ take: String, _ from: Double, _ to: Double) -> Clip {
        Clip(id: "c-0000000\(number)", take: take, start: at(take, from), end: at(take, to), speed: 1)
    }

    /// The words `<prefix>0`…`<prefix>9` of `take`, in their places.
    static func words(_ take: String, _ prefix: String) -> [TranscriptWord] {
        (0..<10).map { TranscriptWord(start: at(take, Double($0)), end: at(take, Double($0) + 0.5), text: "\(prefix)\($0)") }
    }

    static func heard(_ take: String, _ prefix: String) -> TranscriptTake {
        TranscriptTake(take: take, track: "mic", words: words(take, prefix))
    }

    static func transcript(_ takes: [TranscriptTake], language: String = "es-MX") -> Transcript {
        Transcript(language: language, engine: "speechTranscriber-1", takes: takes)
    }

    /// Both takes in the sequence, `take-001`'s first (or the clips given), with a transcription of each (or the one given).
    static func document(
        _ sequence: [Clip] = [clip(1, first, 0, 10), clip(2, second, 0, 10)],
        transcript: Transcript? = transcript([heard(first, "a"), heard(second, "b")])
    ) -> EditDocument {
        var document = EditDocument.legacy(take: record(first), events: [])
        let other = EditDocument.legacy(take: record(second), events: [])
        document.screens.initial.merge(other.screens.initial) { own, _ in own }
        document.camera.initial.merge(other.camera.initial) { own, _ in own }
        document.sequence = sequence
        document.transcript = transcript
        document.captions.show = transcript != nil
        return document
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// The indices of the words of the transcription's take `take` (its index) that are cut.
    static func cutWords(_ document: EditDocument, take: Int) -> [Int] {
        guard let entry = document.transcript?.takes[take] else { return [] }
        return entry.words.indices.filter { TranscriptTiming.isCut(entry.words[$0], take: entry.take, in: document.sequence) }
    }

    /// `keyActivity` of `take` every 0.25 s from `from` to `to` seconds.
    static func keys(_ take: String, _ from: Double, _ to: Double) -> [InputEvent] {
        let count = Int(((to - from) / 0.25).rounded())
        return (0...count).map { InputEvent(t: at(take, from + Double($0) * 0.25), kind: .keyActivity) }
    }
}

private typealias F = TwoTakes

@Suite struct MultiTakeVoiceTests {
    // MARK: - The transcription of some takes

    /// Transcribing a take new to the sequence adds its words and keeps what the user corrected in the others, none of
    /// which counts as lost; transcribing again a take the transcription has replaces only that one, in its place.
    @Test func transcribingATakeKeepsTheOthersCorrections() throws {
        let document = F.document(transcript: F.transcript([F.heard(F.first, "a")]))
        let correct = try #require(TranscriptCommands.correct(document, TranscriptWordRef(take: 0, word: 1), text: "Hola"))
        let toggle = try #require(TranscriptCommands.toggleBreak(document, TranscriptWordRef(take: 0, word: 3)))
        let corrected = try F.applying(toggle, to: try F.applying(correct, to: document))
        let new = F.transcript([F.heard(F.second, "b")])

        let step = try #require(TranscriptCommands.mergeTakes(corrected, new))
        #expect(step.label == .transcriptCreate)
        #expect(step.target == "/transcript")
        let merged = try F.applying(step, to: corrected)
        #expect(merged.transcript?.takes.map(\.take) == [F.first, F.second])
        #expect(merged.transcript?.takes[0] == corrected.transcript?.takes[0])
        #expect(merged.transcript?.takes[0].words[1].text == "Hola")
        #expect(merged.transcript?.takes[0].words[3].breakBefore == true)
        #expect(merged.transcript?.takes[1] == new.takes[0])
        // Only the takes transcribed count: take-001 is not in the new one, and its break would count otherwise.
        let old = try #require(corrected.transcript)
        #expect(TranscriptCommands.lostCorrections(old, new, inTakes: [F.second]) == 0)
        #expect(TranscriptCommands.lostCorrections(old, new) == 1)

        // take-002 heard again, otherwise: its words in its place, take-001's as the user left them.
        let again = F.transcript([F.heard(F.second, "c")])
        let replaced = try F.applying(try #require(TranscriptCommands.mergeTakes(merged, again)), to: merged)
        #expect(replaced.transcript?.takes == [merged.transcript?.takes[0], again.takes[0]].compactMap { $0 })
        // The same words again: nothing to do.
        #expect(TranscriptCommands.mergeTakes(replaced, again) == nil)
    }

    /// Without a transcription, merging is creating it: the same step, the captions shown with it.
    @Test func mergeWithoutTranscriptIsCreate() throws {
        let document = F.document(transcript: nil)
        let new = F.transcript([F.heard(F.second, "b")])
        let step = try #require(TranscriptCommands.mergeTakes(document, new))
        #expect(step == TranscriptCommands.create(document, new))
        let created = try F.applying(step, to: document)
        #expect(created.transcript == new)
        #expect(created.captions.show)
        // The language and the engine are the new transcription's, for every take.
        let english = F.transcript([F.heard(F.first, "a")], language: "en-US")
        let relabelled = try F.applying(try #require(TranscriptCommands.mergeTakes(F.document(), english)), to: F.document())
        #expect(relabelled.transcript?.language == "en-US")
        #expect(relabelled.transcript?.takes == F.document().transcript?.takes)
    }

    /// Transcribing a take again loses its own corrections, and they are counted: only those of that take.
    @Test func retranscribingTheSameTakesCountsTheirLosses() throws {
        let document = F.document()
        let corrected = try F.applying(
            try #require(TranscriptCommands.correct(document, TranscriptWordRef(take: 0, word: 2), text: "Hola")), to: document)
        let second = try F.applying(
            try #require(TranscriptCommands.correct(corrected, TranscriptWordRef(take: 1, word: 4), text: "Chau")), to: corrected)
        let again = F.transcript([F.heard(F.first, "a")])
        let old = try #require(second.transcript)
        #expect(TranscriptCommands.lostCorrections(old, again, inTakes: [F.first]) == 1)
        let merged = try F.applying(try #require(TranscriptCommands.mergeTakes(second, again)), to: second)
        #expect(merged.transcript?.takes[0] == F.heard(F.first, "a"))
        #expect(merged.transcript?.takes[1].words[4].text == "Chau")
        // A take that is twice in a transcription edited by hand is once after it is transcribed again, in its first place.
        var twice = F.document()
        twice.transcript?.takes.append(F.heard(F.first, "z"))
        let once = try F.applying(try #require(TranscriptCommands.mergeTakes(twice, again)), to: twice)
        #expect(once.transcript?.takes == [F.heard(F.first, "a"), F.heard(F.second, "b")])
    }

    // MARK: - Editing by the text

    /// The words of the second take are cut out of its clip and given back within its own timeline: exactly the
    /// sequence there was, and the first take's words never touched.
    @Test func cutAndRestoreInTheSecondTake() throws {
        let document = F.document()
        let cut = try #require(TranscriptCommands.cut(document, take: 1, words: 3...4, makeID: BySource.newIDs)).get()
        let edited = try F.applying(cut, to: document)
        #expect(F.cutWords(edited, take: 1) == [3, 4])
        #expect(F.cutWords(edited, take: 0) == [])
        #expect(edited.sequence.filter { $0.take == F.first } == [F.clip(1, F.first, 0, 10)])
        #expect(TimeMap(sequence: edited.sequence).duration == 18_000_000_000)

        let ids = BySource.CountingIDs()
        let restore = try #require(
            TranscriptCommands.restore(edited, take: 1, words: 3...4, bounds: F.bounds(F.second), makeID: ids.make))
        let restored = try F.applying(restore, to: edited)
        #expect(F.cutWords(restored, take: 1) == [])
        #expect(BySource.spans(restored) == BySource.spans(document))
        // The first take's timeline is not the second's: nothing of it comes back with those limits.
        #expect(TranscriptCommands.restore(edited, take: 1, words: 3...4, bounds: F.bounds(F.first), makeID: ids.make) == nil)
    }

    /// The captions and their `.srt` go in the order of the sequence, whatever the order of the transcription's takes.
    @Test func captionsAndSrtFollowTheSequenceAcrossTakes() throws {
        func sentence(_ take: String, _ texts: [String]) -> TranscriptTake {
            TranscriptTake(
                take: take, track: "mic",
                words: texts.enumerated().map {
                    TranscriptWord(start: F.at(take, 0.5 * Double($0)), end: F.at(take, 0.5 * Double($0) + 0.4), text: $1)
                })
        }
        let transcript = F.transcript([sentence(F.first, ["Primera", "toma."]), sentence(F.second, ["Segunda", "toma."])])
        let document = F.document([F.clip(1, F.second, 0, 2), F.clip(2, F.first, 0, 2)], transcript: transcript)
        let captions = CaptionLines.captions(
            of: document, timeMap: TimeMap(sequence: document.sequence), outputSize: SIMD2(1920, 1080))
        #expect(captions.map(\.text) == ["Segunda toma.", "Primera toma."])
        #expect(captions.map(\.lines.first?.first?.ref.take) == [1, 0])
        #expect(
            CaptionFiles.srt(captions)
                == "1\n00:00:00,000 --> 00:00:01,200\nSegunda toma.\n\n2\n00:00:02,000 --> 00:00:03,200\nPrimera toma.\n")
    }

    // MARK: - Typing speed

    /// The typing of every take the sequence shows is sped up in one step; with one take, it is today's step.
    @Test func typingSpeedOverEveryTake() throws {
        let document = F.document(transcript: nil)
        // take-001 types from 1 to 4 s (output 1 to 4 s), take-002 from 2 to 6 s (output 12 to 16 s).
        let first = (F.record(F.first), F.keys(F.first, 1, 4))
        let second = (F.record(F.second), F.keys(F.second, 2, 6))

        let summary = TypingSpeed.summary(document, takes: [first, second], speed: 3)
        let one = TypingSpeed.summary(document, take: first.0, events: first.1, speed: 3)
        let other = TypingSpeed.summary(document, take: second.0, events: second.1, speed: 3)
        #expect(summary.count == 2)
        #expect(summary == TypingSpeed.Summary(count: one.count + other.count, before: one.before + other.before, after: one.after + other.after))
        #expect(summary.before == 6_500_000_000)

        let ids = BySource.CountingIDs()
        let step = try #require(TypingSpeed.apply(document, takes: [first, second], speed: 3, makeID: ids.make))
        #expect(step.label == .speedTyping)
        #expect(step.target == "c-00000001,c-00000002")
        let edited = try F.applying(step, to: document)
        #expect(edited.sequence.map(\.take) == [F.first, F.first, F.first, F.second, F.second, F.second])
        #expect(edited.sequence.map(\.speed) == [1, 3, 1, 1, 3, 1])
        #expect(edited.sequence.map(\.start) == [
            F.at(F.first, 0), F.at(F.first, 1.25), F.at(F.first, 4), F.at(F.second, 0), F.at(F.second, 2.25), F.at(F.second, 6),
        ])
        #expect(edited.sequence.map(\.id) == ["c-00000001", "c-00000010", "c-00000011", "c-00000002", "c-00000012", "c-00000013"])
        // The order the takes are given in changes nothing.
        #expect(TypingSpeed.apply(document, takes: [second, first], speed: 3, makeID: BySource.newIDs) == step)
        #expect(TypingSpeed.summary(document, takes: [second, first], speed: 3) == summary)

        // One take: exactly the step and the summary of the phase 2.
        let single = F.document([F.clip(1, F.first, 0, 30)], transcript: nil)
        let today = TypingSpeed.apply(single, take: first.0, events: first.1, speed: 3, makeID: BySource.newIDs)
        #expect(today != nil)
        #expect(TypingSpeed.apply(single, takes: [first], speed: 3, makeID: BySource.newIDs) == today)
        #expect(TypingSpeed.summary(single, takes: [first], speed: 3) == TypingSpeed.summary(single, take: first.0, events: first.1, speed: 3))
        // Nothing typed long enough in any take: no step.
        #expect(TypingSpeed.apply(document, takes: [(first.0, []), (second.0, F.keys(F.second, 2, 3))], speed: 3, makeID: BySource.newIDs) == nil)
        #expect(TypingSpeed.summary(document, takes: [], speed: 3) == TypingSpeed.Summary(count: 0, before: 0, after: 0))
    }
}
