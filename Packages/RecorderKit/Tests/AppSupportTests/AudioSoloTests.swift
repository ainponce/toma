// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct AudioSoloTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }

    private static func audio(_ id: String, kind: TrackKind) -> TrackRecord {
        TrackRecord(
            id: id, kind: kind, source: TrackSource(name: id),
            segments: [
                SegmentRecord(
                    index: 1, file: "x.m4a", startHostTime: base, endHostTime: at(20), endReason: .stopped, droppedFrames: 0,
                    heartbeatFrames: 0)
            ])
    }

    private static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "d.mov", startHostTime: base, endHostTime: at(20), endReason: .stopped, droppedFrames: 0,
                        heartbeatFrames: 0)
                ]),
            audio("mic", kind: .microphone), audio("system-audio-a", kind: .systemAudio),
        ])

    private static func document() -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        let media = MediaClip(asset: "assets/a.mov", start: 0, end: 2_000_000_000, volume: -3)
        document.sequence = [
            Clip(id: "c-1", take: "take-001", start: base, end: at(10), speed: 1),
            Clip(id: "c-2", take: "take-001", start: base, end: base, speed: 1, content: .media(media)),
        ]
        document.audio.tracks["take-001/mic"] = TrackGain(
            gain: 1.5, muted: true, cleanup: 0.4,
            ranges: [GainRange(id: "g-aaaaaaaa", take: "take-001", start: at(1), end: at(2), gain: 6)])
        document.music.items = [
            MusicItem(id: "mu-1", source: "library:music-1/calm", start: 0, end: 5_000_000_000),
            MusicItem(id: "mu-2", source: "library:music-1/pulse", start: 6_000_000_000, end: 9_000_000_000, gain: -20),
        ]
        document.annotations.items = [
            Annotation(
                id: "a-1", anchor: .whole, layer: 0, kind: .clip(ClipAnnotation(asset: "assets/b.mov", start: 0, end: 1_000_000_000)),
                rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        ]
        return document
    }

    private static func silentRange(_ gain: TrackGain?) -> Bool {
        guard let range = gain?.ranges.first, gain?.ranges.count == 1 else { return false }
        return range.gain == GainRange.silence && range.start.nanoseconds == 0 && range.end.nanoseconds == .max
            && range.take == "take-001"
    }

    @Test func emptySoloIsTheDocument() {
        let document = Self.document()
        #expect(AudioSolo().isEmpty)
        #expect(AudioSolo().applied(to: document, takes: [Self.take]) == document)
    }

    @Test func soloSilencesTheOthers() {
        let document = Self.document()
        let solo = AudioSolo(rows: [.track("mic")]).applied(to: document, takes: [Self.take])
        // The mic keeps its own stretches; the other track is silenced over its whole take, with the gain it had (none: 1).
        #expect(solo.audio.tracks["take-001/mic"] == document.audio.tracks["take-001/mic"])
        let other = solo.audio.tracks["take-001/system-audio-a"]
        #expect(Self.silentRange(other))
        #expect(other?.gain == 1 && other?.muted == false)
        #expect(solo.audio.tracks["take-001/display-1"] == nil)
        #expect(solo.music.items.allSatisfy { $0.gain == GainRange.silence })
        guard case let .media(media) = solo.sequence[1].content else { Issue.record("lost the clip"); return }
        #expect(media.volume == GainRange.silence)
        guard case let .clip(clip) = solo.annotations.items[0].kind else { Issue.record("lost the annotation"); return }
        #expect(clip.muted)

        let music = AudioSolo(rows: [.music]).applied(to: document, takes: [Self.take])
        #expect(music.music.items == document.music.items)
        #expect(Self.silentRange(music.audio.tracks["take-001/mic"]))
        #expect(Self.silentRange(music.audio.tracks["take-001/system-audio-a"]))
        guard case let .media(kept) = music.sequence[1].content, case let .clip(keptClip) = music.annotations.items[0].kind else {
            Issue.record("lost content")
            return
        }
        #expect(kept.volume == GainRange.silence)
        #expect(keptClip.muted)
    }

    @Test func severalRowsAreHeardAtOnce() {
        let document = Self.document()
        let solo = AudioSolo(rows: [.track("mic"), .music, .importedClips]).applied(to: document, takes: [Self.take])
        #expect(solo.audio.tracks["take-001/mic"] == document.audio.tracks["take-001/mic"])
        #expect(Self.silentRange(solo.audio.tracks["take-001/system-audio-a"]))
        #expect(solo.music == document.music)
        #expect(solo.sequence == document.sequence)
        #expect(solo.annotations == document.annotations)
    }

    @Test func soloKeepsTheDucking() {
        var document = Self.document()
        document.music.ducking = Ducking(enabled: true, amount: -9, attack: 0.2, release: 1)
        document.audio.tracks["take-001/system-audio-a"] = TrackGain(gain: 0.7, muted: false)
        for rows: Set<AudioRowID> in [[.music], [.track("system-audio-a")], [.importedClips]] {
            let solo = AudioSolo(rows: rows).applied(to: document, takes: [Self.take])
            #expect(solo.music.ducking == document.music.ducking)
            for key in ["take-001/mic", "take-001/system-audio-a"] {
                #expect(solo.audio.tracks[key]?.muted == document.audio.tracks[key]?.muted ?? false)
                #expect(solo.audio.tracks[key]?.gain == document.audio.tracks[key]?.gain ?? 1)
            }
            #expect(solo.sequence.map(\.id) == document.sequence.map(\.id))
            #expect(solo.audio.limiter == document.audio.limiter && solo.audio.normalize == document.audio.normalize)
        }
    }

    @Test func aTrackWithoutItsOwnGainKeepsTheOneAnotherTakeGives() {
        var document = Self.document()
        document.sequence.append(Clip(id: "c-3", take: "take-002", start: Self.base, end: Self.at(5), speed: 1))
        let second = TakeRecord(
            id: "take-002", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_100),
            tracks: [Self.audio("mic", kind: .microphone)])
        let solo = AudioSolo(rows: [.music]).applied(to: document, takes: [Self.take, second])
        // take-002/mic has none: it holds take-001's gain and cleanup (the mic's), over its own take.
        let held = solo.audio.tracks["take-002/mic"]
        #expect(held?.gain == 1.5 && held?.muted == true && held?.cleanup == 0.4)
        #expect(held?.ranges.count == 1 && held?.ranges.first?.take == "take-002")
        #expect(solo.audio.tracks["take-001/mic"]?.ranges.count == 1)
    }

    @Test func aTakeTheSequenceDoesNotShowIsLeftAlone() {
        let document = Self.document()
        let other = TakeRecord(
            id: "take-009", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_100),
            tracks: [Self.audio("mic", kind: .microphone)])
        let solo = AudioSolo(rows: [.music]).applied(to: document, takes: [Self.take, other])
        #expect(solo.audio.tracks["take-009/mic"] == nil)
    }
}
