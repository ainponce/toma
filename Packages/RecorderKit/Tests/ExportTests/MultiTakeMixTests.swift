// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The mix of a sequence that shows more than one take (phase 3 design §9, base plan task B8): each clip plays the tracks
/// of its own take, a track's gain holds by its id in every take, the clicks of every take sound, and with one take the
/// mix is phase 2's.
@Suite struct MultiTakeMixTests {
    /// What phase 2's mix played for each case of golden 3 that mixes (`EditedMix.playDescription`, recorded from the code
    /// of `fase-3` aad3341, before the mix had more than one take), with the document `GoldenDocuments.makeDocument` makes
    /// and, with Normalize, the loudness of its tracks: the pieces, the runs, the gains, the click frames and the spans
    /// left silent. The samples themselves are `make golden-3`'s.
    static let phase2Plans: [String: String] = [
        "cutsAndSpeed": """
            channels 1 total 108000 content 108000 limited false
            piece 0..<48000 source 0 out
            piece 48000..<108000 run 0 in
            run 48000..<108000 from 72000 heard 72000..<192000 at 2.0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "zoomWithBlur": """
            channels 1 total 192000 content 192000 limited false
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks [33600, 91200]
            """,
        "twoScreens": """
            channels 1 total 144000 content 144000 limited false
            piece 0..<144000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "portraitSplit": """
            channels 1 total 192000 content 192000 limited true
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "namedStyle": """
            channels 1 total 192000 content 192000 limited false
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks [33600, 91200]
            """,
        "captionsBold": """
            channels 1 total 192000 content 192000 limited false
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "keysOnScreen": """
            channels 1 total 192000 content 192000 limited false
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "cameraLookWarm": """
            channels 1 total 192000 content 192000 limited false
            piece 0..<192000 source 0
            track take-001/mic gain 1.0 dry 1.0 cleanup 0.0
            clicks []
            """,
        "normalizedMix": """
            channels 2 total 192000 content 192000 limited true
            piece 0..<192000 source 0
            track take-001/mic gain 3.4290488 dry 3.4290488 cleanup 0.0
            track take-001/system-audio gain 0.35429907 dry 0.35429907 cleanup 0.0
            clicks []
            """,
    ]

    /// A document of one take plays what phase 2 played: one source, its take's, and every piece, run, gain, click and
    /// silent span as before; the mix of the same document made again from it (`with(document:framesPerSecond:)`) too.
    @Test func singleTakeMixKeepsEveryPiece() async throws {
        let cases = GoldenDocuments.golden3Cases.filter(\.mixes)
        #expect(Set(cases.map(\.name)) == Set(Self.phase2Plans.keys))
        try await withTemporaryDirectory { tmp in
            for golden in cases {
                let project = try await GoldenDocuments.makeProject(golden.name, in: tmp)
                let document = try GoldenDocuments.makeDocument(golden.name, for: project)
                let mix = try await EditedMix.make(
                    project: project, document: document, framesPerSecond: 60,
                    analysis: try await loudnessAnalysis(of: project, document: document))
                #expect(mix.takeIDs == [project.take.id], "\(golden.name)")
                #expect(mix.hasSound, "\(golden.name)")
                #expect(mix.playDescription == Self.phase2Plans[golden.name], "\(golden.name):\n\(mix.playDescription)")
                let again = mix.with(document: document, framesPerSecond: 60)
                #expect(again.playDescription == mix.playDescription && again.takeIDs == mix.takeIDs, "\(golden.name)")
            }
        }
    }

    /// Each clip of a sequence of two takes plays its take as the take alone does: [take-001 0–2 s, take-002 0,5–2,5 s]
    /// gives the samples of [take-001 0–2] in its first clip, but for its last 192 frames (the fade into the other take),
    /// and those of [take-002 0,5–2,5] in its second, moved to where it starts, but for its first 192.
    @Test func twoTakesMixEachTakeAsAlone() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let both = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)]),
                framesPerSecond: 60)
            #expect(both.takeIDs == ["take-001", "take-002"] && both.channels == 1 && both.totalFrames == 192_000)
            let first = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), framesPerSecond: 60)
            let second = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-002", 0.5, 2.5)]), framesPerSecond: 60)
            #expect(first.takeIDs == ["take-001"] && second.takeIDs == ["take-002"])
            let mixed = try await rendered(both), alone1 = try await rendered(first), alone2 = try await rendered(second)
            #expect(alone1.count == 96_000 && alone2.count == 96_000)
            #expect(bits(mixed[0..<(96_000 - 192)]) == bits(alone1[0..<(96_000 - 192)]))
            #expect(bits(mixed[(96_000 + 192)...]) == bits(alone2[192...]))
            // Each is its own take: the 440 Hz of take-001, then the 660 Hz of take-002.
            #expect(toneAmplitude(mixed, start: 0, frequency: 440, from: 0.5, to: 1.5) > 0.2)
            #expect(toneAmplitude(mixed, start: 0, frequency: 660, from: 2.5, to: 3.5) > 0.2)
            #expect(toneAmplitude(mixed, start: 0, frequency: 660, from: 0.5, to: 1.5) < 0.001)
            // The border between the takes fades out and in, as at a cut.
            #expect(mixed[96_000 - 1] == 0 && mixed[96_000] == 0)
        }
    }

    /// The output's edges fade by the take of the clip there: a first clip trimmed inside take-001 fades in, even with the
    /// project focused on take-002, and a last clip to the end of take-002 does not fade out.
    @Test func outputEdgesFadeByTheirOwnTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            #expect(project.take.id == "take-002")
            let second = EditDocument.legacy(for: try #require(project.focused(on: "take-002")))
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0.5, 2)])
            document.sequence.append(second.sequence[0])
            let both = try await rendered(try await EditedMix.make(project: project, document: document, framesPerSecond: 60))
            let first = try await rendered(try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0.5, 2)]), framesPerSecond: 60))
            let whole = try await rendered(try await EditedMix.make(project: project, document: second, framesPerSecond: 60))
            #expect(both[0] == 0 && bits(both[0..<192]) == bits(first[0..<192]))
            #expect(both.last != 0 && bits(both.suffix(192)) == bits(whole.suffix(192)))
        }
    }

    /// A track that one take has and the other does not plays only in the clips of the one: take-001's system audio is
    /// never heard in a clip of take-002, which has only its microphone.
    @Test func aTrackOnlyInOneTakeIsSilentInTheOther() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(
                in: dir, TakeAudio(systemAudio: (frequency: 1_000, channels: 1)), TakeAudio(mic: (frequency: 660, channels: 1)))
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let heard = try await rendered(try await EditedMix.make(project: project, document: document, framesPerSecond: 60))
            #expect(toneAmplitude(heard, start: 0, frequency: 1_000, from: 0.5, to: 1.5) > 0.2)
            #expect(toneAmplitude(heard, start: 0, frequency: 660, from: 2.5, to: 3.5) > 0.2)
            #expect(toneAmplitude(heard, start: 0, frequency: 1_000, from: 2.5, to: 3.5) < 0.001)
            // With the microphone muted in both takes, the second clip is silence.
            document.audio.tracks = [
                AudioPlan.key(take: "take-001", track: micID): TrackGain(gain: 1, muted: true),
                AudioPlan.key(take: "take-002", track: micID): TrackGain(gain: 1, muted: true),
            ]
            let muted = try await rendered(try await EditedMix.make(project: project, document: document, framesPerSecond: 60))
            #expect(muted[96_000...].allSatisfy { $0 == 0 })
            #expect(toneAmplitude(muted, start: 0, frequency: 1_000, from: 0.5, to: 1.5) > 0.2)
        }
    }

    /// A row's gain holds in every take (phase 3 base plan decision 11): 0.5 on take-001's microphone alone halves
    /// take-002's too, which has no gain of its own; one of its own rules over it.
    @Test func rowGainHoldsInEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            document.audio.tracks = [:]
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let plain = try await rendered(mix)
            #expect(toneAmplitude(plain, start: 0, frequency: 660, from: 2.5, to: 3.5) > 0.2)
            let first = AudioPlan.key(take: "take-001", track: "mic"), second = AudioPlan.key(take: "take-002", track: "mic")
            document.audio.tracks = [first: TrackGain(gain: 0.5, muted: false)]
            let half = try await rendered(mix.with(document: document, framesPerSecond: 60))
            #expect(bits(half) == bits(plain.map { $0 * 0.5 }))
            // Its own gain rules in take-002.
            document.audio.tracks[second] = TrackGain(gain: 1, muted: false)
            let own = try await rendered(mix.with(document: document, framesPerSecond: 60))
            #expect(bits(own[..<96_000]) == bits(plain[..<96_000].map { $0 * 0.5 }) && bits(own[96_000...]) == bits(plain[96_000...]))
            // Muted on the row: silent in both takes.
            document.audio.tracks = [first: TrackGain(gain: 1, muted: true)]
            let muted = try await rendered(mix.with(document: document, framesPerSecond: 60))
            #expect(muted.allSatisfy { $0 == 0 })
        }
    }

    /// The clicks of both takes sound, each at its output time, and one less than `ClickSounds.minimumSpacing` after the
    /// last that sounded, even of the other take, does not.
    @Test func clicksOfBothTakesSound() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir, TakeAudio(clicks: [1.0, 1.99]), TakeAudio(clicks: [0, 0.5]))
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            #expect(document.sequence.map(\.start) == [base, base.adding(seconds: 60)])
            document.cursor.clickSound = "soft-1"
            document.cursor.clickSoundGain = 1
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            // At 1.0 s and 1.99 s of take-001, and 2.5 s of the output in take-002; its click at 2.0 s comes 10 ms after
            // the one at 1.99 s.
            #expect(mix.clickFrames == [48_000, 95_520, 120_000])
            // With take-001 cut at 1.5 s, its click at 1.99 s is cut and take-002's at its start sounds, at 1.5 s.
            document.sequence[0].end = base.adding(seconds: 1.5)
            #expect(mix.with(document: document, framesPerSecond: 60).clickFrames == [48_000, 72_000, 96_000])
        }
    }

    /// The mix has as many channels as the widest take needs: with a mono take and a stereo one, 2, and the mono take
    /// sounds in both, as it sounds alone.
    @Test func channelsAreTheWidestTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir, TakeAudio(), TakeAudio(mic: (frequency: 660, channels: 2)))
            let both = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)]),
                framesPerSecond: 60)
            #expect(both.channels == 2)
            let alone = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), framesPerSecond: 60)
            #expect(alone.channels == 1)
            let stereo = try await rendered(both), mono = try await rendered(alone)
            let left = stride(from: 0, to: stereo.count, by: 2).map { stereo[$0] }
            let right = stride(from: 1, to: stereo.count, by: 2).map { stereo[$0] }
            #expect(bits(left) == bits(right))
            #expect(bits(left[0..<(96_000 - 192)]) == bits(mono[0..<(96_000 - 192)]))
            #expect(toneAmplitude(left, start: 0, frequency: 660, from: 2.5, to: 3.5) > 0.2)
        }
    }

    /// The silent spans of every take are listed, in output seconds: take-002's microphone, empty, over its clip.
    @Test func missingAudioOfEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir, TakeAudio(), TakeAudio(micEndReason: .empty))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let file = try #require(project.focused(on: "take-002")?.take.tracks.first { $0.id == micID }?.segments.first?.file)
            #expect(mix.missingAudio == [MissingAudio(track: micID, file: file, start: 2, end: 4, reason: .empty)])
            #expect(toneAmplitude(try await rendered(mix), start: 0, frequency: 440, from: 0.5, to: 1.5) > 0.2)
        }
    }

    /// A span missing in a take is listed only where that take is heard, in each run of its clips: with take-001's
    /// microphone empty from 8 to 14 s in [take-001 0–10 s, take-002 0–5 s, take-001 12–20 s], 8–10 s and 15–17 s of the
    /// output, never 10–15 s, where take-002's microphone sounds (a range export of 11–14 s has no gap).
    @Test func aMissingSpanNeverCoversAnotherTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(
                in: dir, TakeAudio(seconds: 20, micGap: (from: 8, to: 14)), TakeAudio(seconds: 6, mic: (frequency: 660, channels: 1)))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 10), ("take-002", 0, 5), ("take-001", 12, 20)])
            #expect(document.sequence.map(\.start) == [base, base.adding(seconds: 60), base.adding(seconds: 12)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let file = try gapFile(of: project)
            #expect(mix.missingAudio == [
                MissingAudio(track: micID, file: file, start: 8, end: 10, reason: .empty),
                MissingAudio(track: micID, file: file, start: 15, end: 17, reason: .empty),
            ])
            #expect(!mix.missingAudio.contains { $0.start < 14 && $0.end > 11 })
            let samples = try await rendered(mix)
            #expect(toneAmplitude(samples, start: 0, frequency: 660, from: 11, to: 14) > 0.2)
            #expect(samples[(8 * 48_000)..<(10 * 48_000)].allSatisfy { $0 == 0 })
        }
    }

    /// A span open to the end (a segment without an end) is listed to the end of each run of its take, and to the end of
    /// the mix only in the run that ends the output: take-001's microphone gone from 8 s on in [take-001 0–10 s,
    /// take-002 0–5 s, take-001 12–20 s] is 8–10 s and 15–23 s.
    @Test func aSpanOpenToTheEndStopsAtAnotherTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(
                in: dir, TakeAudio(seconds: 20, micGap: (from: 8, to: nil)), TakeAudio(seconds: 6, mic: (frequency: 660, channels: 1)))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 10), ("take-002", 0, 5), ("take-001", 12, 20)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(mix.totalFrames == 23 * 48_000)
            let file = try gapFile(of: project)
            #expect(mix.missingAudio == [
                MissingAudio(track: micID, file: file, start: 8, end: 10, reason: .empty),
                MissingAudio(track: micID, file: file, start: 15, end: 23, reason: .empty),
            ])
            // Ended by a clip of another take, the same span stops at the end of the run.
            var other = document
            other.sequence.append(try #require(MultiTakeFixtures.sequence(of: project, [("take-002", 5, 6)]).sequence.first))
            #expect(mix.with(document: other, framesPerSecond: 60).missingAudio == [
                MissingAudio(track: micID, file: file, start: 8, end: 10, reason: .empty),
                MissingAudio(track: micID, file: file, start: 15, end: 23, reason: .empty),
            ])
        }
    }

    /// A clip of a take the manifest does not have is silent, whatever source instants it names: it never plays another
    /// take's audio. A sequence of only such clips mixes the project's own take, silent.
    @Test func aClipOfAnUnknownTakeIsSilent() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            // `take-009` names the source instants of `project`'s own take, take-002.
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-009", 0, 2), ("take-002", 0, 2)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(mix.takeIDs == ["take-001", "take-002"])
            let samples = try await rendered(mix)
            #expect(samples[96_000..<192_000].allSatisfy { $0 == 0 })
            #expect(toneAmplitude(samples, start: 0, frequency: 660, from: 4.5, to: 5.5) > 0.2)
            let only = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-009", 0, 2)]), framesPerSecond: 60)
            #expect(only.takeIDs == ["take-002"] && only.totalFrames == 96_000)
            #expect(try await rendered(only).allSatisfy { $0 == 0 })
        }
    }

    /// A take whose event log cannot be read (here a link to the other take's, never followed) is silent: none of its
    /// tracks nor its clicks, and never the other take's audio; the clips of the other take sound as they do.
    @Test func aTakeWhoseEventsCannotBeReadIsSilent() async throws {
        try await withTemporaryDirectory { dir in
            let written = try await twoTakes(in: dir, TakeAudio(clicks: [0.5]), TakeAudio(mic: (frequency: 660, channels: 1), clicks: [0.5]))
            let package = written.package
            try FileManager.default.removeItem(at: package.eventsURL(take: "take-002"))
            try FileManager.default.createSymbolicLink(at: package.eventsURL(take: "take-002"), withDestinationURL: package.eventsURL(take: "take-001"))
            let project = try LoadedProject.load(package.url, take: "take-001")
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            document.cursor.clickSound = "soft-1"
            document.cursor.clickSoundGain = 1
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(mix.takeIDs == ["take-001", "take-002"] && mix.clickFrames == [24_000])
            let samples = try await rendered(mix)
            #expect(samples[(96_000 + 192)...].allSatisfy { $0 == 0 })
            #expect(toneAmplitude(samples, start: 0, frequency: 440, from: 1.0, to: 1.9) > 0.2)
        }
    }

    /// A take whose segments cannot be read is silent where it is shown, and its spans are listed there: the other take's
    /// audio never fills them.
    @Test func aTakeWhoseSegmentsCannotBeReadIsSilent() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir, TakeAudio(), TakeAudio(micUnreadable: true))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(mix.missingAudio.count == 1)
            let missing = try #require(mix.missingAudio.first)
            #expect(missing.track == micID && missing.file.hasPrefix("takes/take-002/") && missing.start == 2 && missing.end == 4)
            guard case .cannotOpen = missing.reason else {
                Issue.record("\(missing.reason)")
                return
            }
            let samples = try await rendered(mix)
            #expect(samples[(96_000 + 192)...].allSatisfy { $0 == 0 })
            #expect(toneAmplitude(samples, start: 0, frequency: 440, from: 0.5, to: 1.5) > 0.2)
        }
    }

    /// The mix of another revision keeps the takes it has (`takeIDs`): a clip of a take it has no source for is silent
    /// there, and the mix made anew has both.
    @Test func anotherRevisionKeepsItsTakes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let one = try await EditedMix.make(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), framesPerSecond: 60)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let next = one.with(document: document, framesPerSecond: 60)
            #expect(next.takeIDs == ["take-001"] && next.prereadSegments == 0)
            let anew = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(anew.takeIDs == ["take-001", "take-002"])
            let kept = try await rendered(next), made = try await rendered(anew)
            #expect(kept[96_000...].allSatisfy { $0 == 0 })
            #expect(bits(kept[..<96_000]) == bits(made[..<96_000]))
        }
    }
}

// MARK: - Helpers

/// The audio and clicks of one take of `twoTakes(in:_:_:)`, `seconds` long.
private struct TakeAudio {
    var seconds: Double = 3
    /// The microphone's sine and channels (`mic`), at 1/4 of full scale; none when `nil`.
    var mic: (frequency: Double, channels: Int)? = (frequency: 440, channels: 1)
    /// How the microphone's segment ended, as the manifest says.
    var micEndReason: SegmentEndReason? = .stopped
    /// A segment of 0 bytes in the microphone from `from` (seconds from the take's start): closed at `to` as `.empty`,
    /// with the sine again from there to the end, or open (no end) when `to` is `nil`.
    var micGap: (from: Double, to: Double?)?
    /// The microphone is one segment of the whole take whose file is not a movie.
    var micUnreadable = false
    /// System audio's sine and channels (`system-audio`), at 1/4 of full scale; none when `nil`.
    var systemAudio: (frequency: Double, channels: Int)?
    /// Seconds from the take's start of its left clicks.
    var clicks: [Double] = []
}

/// Writes `Takes.toma` into `dir`, with `take-001` from `base` as `first` says and `take-002` from 60 s later as `second`
/// says, each with the display (320 × 180 at 10 fps) over the whole take, and returns it as `LoadedProject.load` reads it
/// without a take: focused on `take-002`.
private func twoTakes(in dir: URL, _ first: TakeAudio, _ second: TakeAudio) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Takes")
    try await record(first, into: builder, start: base)
    _ = try builder.write()
    let next = try TakeBuilder(appendingTo: builder.package, take: "take-002")
    try await record(second, into: next, start: base.adding(seconds: 60))
    _ = try next.write()
    return try LoadedProject.load(builder.package.url)
}

private func record(_ take: TakeAudio, into builder: TakeBuilder, start: HostTime) async throws {
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: start, seconds: take.seconds, framesPerSecond: 10, width: 320, height: 180)])
    if let mic = take.mic {
        func sine(from: Double, to: Double) -> AudioSegmentSpec {
            AudioSegmentSpec(
                start: start.adding(seconds: from), seconds: to - from, channels: mic.channels, frequency: mic.frequency,
                endReason: take.micEndReason)
        }
        if take.micUnreadable {
            try await builder.addAudioTrack(id: micID, source: micSource, segments: [])
            try builder.addEmptySegment(
                track: micID, index: 1, start: start, end: start.adding(seconds: take.seconds), endReason: .stopped, file: .garbage())
        } else if let gap = take.micGap {
            try await builder.addAudioTrack(id: micID, source: micSource, segments: [sine(from: 0, to: gap.from)])
            try builder.addEmptySegment(
                track: micID, index: 2, start: start.adding(seconds: gap.from), end: gap.to.map { start.adding(seconds: $0) },
                endReason: gap.to == nil ? nil : .empty, file: .zeroBytes)
            if let to = gap.to { try await builder.addAudioTrack(id: micID, source: micSource, segments: [sine(from: to, to: take.seconds)]) }
        } else {
            try await builder.addAudioTrack(id: micID, source: micSource, segments: [sine(from: 0, to: take.seconds)])
        }
    }
    if let system = take.systemAudio {
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: start, seconds: take.seconds, channels: system.channels, frequency: system.frequency)])
    }
    try builder.addEvents(take.clicks.flatMap { t in
        [
            InputEvent(t: start.adding(seconds: t), kind: .mouseDown(.left, x: 100, y: 100)),
            InputEvent(t: start.adding(seconds: t + 0.05), kind: .mouseUp(.left, x: 100, y: 100)),
        ]
    })
}

/// The file of take-001's microphone segment of 0 bytes (`TakeAudio.micGap`).
private func gapFile(of project: LoadedProject) throws -> String {
    let take = try #require(project.focused(on: "take-001")?.take)
    return try #require(take.tracks.first { $0.id == micID }?.segments.first { $0.index == 2 }?.file)
}

/// `mix.render` of the whole mix, read off the cooperative pool.
private func rendered(_ mix: EditedMix) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
        return samples
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// What the mix of `document` reads of the caches, as golden 3's mix gets it (`golden3Analysis`): with Normalize, the
/// loudness of every audio track of the take with segments, each segment heard measured whole without a clean voice;
/// without it, nothing.
private func loudnessAnalysis(of project: LoadedProject, document: EditDocument) async throws -> AnalysisInputs {
    var analysis = AnalysisInputs()
    guard document.audio.normalize else { return analysis }
    for track in project.take.tracks where !track.kind.isVideo && !track.segments.isEmpty {
        let audio = try await TrackAudio.load(project, track: track.id)
        var measures: [SegmentLoudness] = []
        for span in audio.spans {
            measures.append(try await Loudness.measure(audio, span: span, clean: nil))
        }
        let first = try #require(measures.first)
        analysis.loudness[AudioPlan.key(take: project.take.id, track: track.id)] = TrackLoudness(
            channels: first.channels, dry: measures.flatMap(\.dry), wet: nil, cross: nil)
    }
    return analysis
}
