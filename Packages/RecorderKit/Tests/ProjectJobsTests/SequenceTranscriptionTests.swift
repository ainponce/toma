// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat
import ProjectJobs

/// Three takes of 30 s of `display-1`: `take-001` and `take-002` with the microphone `mic`, `take-003` with system audio
/// only, and `take-004` with nothing to hear. Pure: no package, no Speech.
private enum Takes {
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ take: String, _ seconds: Double) -> HostTime {
        let index = Double(take.suffix(1)) ?? 1
        return origin.adding(seconds: (index - 1) * 60 + seconds)
    }

    static func segment(_ take: String, _ track: String) -> SegmentRecord {
        SegmentRecord(
            index: 1, file: "takes/\(take)/\(track)/seg-0001.mov", startHostTime: at(take, 0), endHostTime: at(take, 30),
            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
    }

    static func record(_ take: String) -> TakeRecord {
        var tracks = [
            TrackRecord(
                id: "display-1", kind: .display, source: TrackSource(name: "Display", displayID: 1),
                segments: [segment(take, "display-1")])
        ]
        switch take {
        case "take-001", "take-002":
            tracks.append(TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Mic"), segments: [segment(take, "mic")]))
        case "take-003":
            tracks.append(TrackRecord(
                id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System"), segments: [segment(take, "system-audio")]))
        default:
            break
        }
        return TakeRecord(id: take, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    }

    static func clip(_ number: Int, _ take: String) -> Clip {
        Clip(id: "c-0000000\(number)", take: take, start: at(take, 0), end: at(take, 10), speed: 1)
    }

    static func heard(_ take: String) -> TranscriptTake {
        TranscriptTake(
            take: take, track: "mic",
            words: [TranscriptWord(start: at(take, 1), end: at(take, 1.5), text: "hola")])
    }

    /// A document whose sequence shows `takes` in that order, with a transcript of `heard` in `language` (none when `nil`).
    static func document(_ takes: [String], heard: [String]?, language: String = "es-MX") -> EditDocument {
        var document = EditDocument.legacy(take: record(takes[0]), events: [])
        document.sequence = takes.enumerated().map { clip($0.offset + 1, $0.element) }
        document.transcript = heard.map { Transcript(language: language, engine: "speechTranscriber-1", takes: $0.map(Takes.heard)) }
        return document
    }

    static func shown(_ takes: [String]) -> [TakeRecord] { takes.map(record) }
}

private typealias T = Takes

@Suite struct SequenceTranscriptionTests {
    /// Every take of the sequence that has something to hear, in its order: a take without sound is left out.
    @Test func onlyTakesWithSomethingToHear() {
        let takes = ["take-002", "take-004", "take-001", "take-003"]
        #expect(SequenceTranscription.transcribable(T.shown(takes)) == ["take-002", "take-001", "take-003"])
        #expect(SequenceTranscription.transcribable(T.shown(["take-004"])) == [])
    }

    /// Transcribe hears the takes whose words the transcript does not have in the language chosen: all of them without a
    /// transcript, the new one with one, all of them in another language; and, once each has its own, all of them again.
    @Test func transcribeHearsWhatIsMissingElseEverything() {
        let takes = ["take-002", "take-001", "take-003"]
        let shown = T.shown(takes)
        #expect(SequenceTranscription.takes(toTranscribe: T.document(takes, heard: nil), shown: shown, language: "es-MX") == takes)
        let some = T.document(takes, heard: ["take-001"])
        #expect(SequenceTranscription.takes(toTranscribe: some, shown: shown, language: "es-MX") == ["take-002", "take-003"])
        // `es_MX` is `es-MX`.
        #expect(SequenceTranscription.takes(toTranscribe: some, shown: shown, language: "es_MX") == ["take-002", "take-003"])
        #expect(SequenceTranscription.takes(toTranscribe: some, shown: shown, language: "en-US") == takes)
        let all = T.document(takes, heard: takes)
        #expect(SequenceTranscription.takes(toTranscribe: all, shown: shown, language: "es-MX") == takes)
    }

    /// With one take, Transcribe and Transcribe Again hear it, as in phase 2; with nothing to hear, nothing.
    @Test func oneTakeIsThePhase2Transcription() {
        let shown = T.shown(["take-001"])
        #expect(SequenceTranscription.takes(toTranscribe: T.document(["take-001"], heard: nil), shown: shown, language: "es-MX") == ["take-001"])
        #expect(SequenceTranscription.takes(toTranscribe: T.document(["take-001"], heard: ["take-001"]), shown: shown, language: "es-MX") == ["take-001"])
        #expect(SequenceTranscription.newTakes(T.document(["take-001"], heard: ["take-001"]), shown: shown) == [])
        #expect(SequenceTranscription.takes(toTranscribe: T.document(["take-004"], heard: nil), shown: T.shown(["take-004"]), language: "es-MX") == [])
    }

    /// A take new to a transcribed sequence is transcribed by itself; without a transcript, nothing is.
    @Test func newTakesOfATranscribedSequence() {
        let takes = ["take-001", "take-002", "take-004"]
        #expect(SequenceTranscription.newTakes(T.document(takes, heard: ["take-001"]), shown: T.shown(takes)) == ["take-002"])
        #expect(SequenceTranscription.newTakes(T.document(takes, heard: ["take-001", "take-002"]), shown: T.shown(takes)) == [])
        #expect(SequenceTranscription.newTakes(T.document(takes, heard: nil), shown: T.shown(takes)) == [])
        // A take of the transcript the sequence no longer shows changes nothing.
        #expect(SequenceTranscription.newTakes(T.document(["take-002"], heard: ["take-001", "take-002"]), shown: T.shown(["take-002"])) == [])
    }

    /// The silences are between the words when the transcript has every take of the sequence that can be heard; otherwise
    /// where each take's microphone is quiet, so a take not transcribed yet never counts as one long silence.
    @Test func silencesFromTheWordsOnlyWhenEveryTakeIsTranscribed() {
        let takes = ["take-001", "take-002", "take-004"]
        #expect(SequenceTranscription.silencesFromWords(T.document(takes, heard: ["take-001", "take-002"]), shown: T.shown(takes)))
        #expect(!SequenceTranscription.silencesFromWords(T.document(takes, heard: ["take-001"]), shown: T.shown(takes)))
        #expect(!SequenceTranscription.silencesFromWords(T.document(takes, heard: nil), shown: T.shown(takes)))
        // One take: with a transcript, its words; without, its microphone, as in phase 2.
        #expect(SequenceTranscription.silencesFromWords(T.document(["take-001"], heard: ["take-001"]), shown: T.shown(["take-001"])))
        #expect(!SequenceTranscription.silencesFromWords(T.document(["take-001"], heard: nil), shown: T.shown(["take-001"])))
    }
}
