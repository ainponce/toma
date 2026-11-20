// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The music in the mix (phase 3 design §7.4 to §7.6 and §13, step 3; plan 3c task U7, decisions 7 and 8): each piece of
/// `document.music` plays its file (`analysis.musicFiles`, a `MusicFile`) over its output frames, anchored to the output,
/// at its gain, with its smoothstep fades of at most half of it each; a theme of the library starts again with no fade, a
/// file of one's own with a crossfade of 480 frames, and without `loop` it is silence after the file's end; it ends with
/// the output. It goes down by the envelope of the ducking (`ducking-1`) where the microphone or the device's sound of the
/// take of a clip that sounds has a voice, through the cuts of the sound. Without music the mix is the base's.
///
/// The files are written here (`MusicFile.write`); the takes start their display at `base`, and their microphone is a sine
/// of 1 kHz at 1/4 of full scale.
@Suite struct MusicMixTests {
    /// Each case of golden 3 that mixes has no music (`hasSound` false, nothing played, no envelope), and the same with a
    /// theme whose file is not there and a voice on every track over all of each take: the samples of the base, bit for
    /// bit, in the mix made for it and in the mix of another revision.
    @Test func noMusicIsTheBase() async throws {
        let cases = GoldenDocuments.golden3Cases.filter(\.mixes).map(\.name)
        #expect(!cases.isEmpty)
        try await withTemporaryDirectory { tmp in
            try await withThrowingTaskGroup { group in
                for name in cases { group.addTask { try await Self.checkIsTheBase(name, in: tmp) } }
                try await group.waitForAll()
            }
        }
    }

    /// `noMusicIsTheBase` of the golden case `name`, its project written into `tmp`.
    private static func checkIsTheBase(_ name: String, in tmp: URL) async throws {
        let project = try await GoldenDocuments.makeProject(name, in: tmp)
        let document = try GoldenDocuments.makeDocument(name, for: project)
        let plain = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        #expect(!plain.music.hasSound && plain.music.played.isEmpty && plain.music.envelope.isUnity, "\(name)")
        var analysis = AnalysisInputs.none
        for take in project.takesShown(by: document) {
            for track in take.take.tracks where !track.kind.isVideo {
                analysis.voiceActivity[AudioPlan.key(take: take.take.id, track: track.id)] =
                    VoiceActivity(spans: [HostTime(nanoseconds: 0)..<HostTime(nanoseconds: .max)])
            }
        }
        var withTheme = document
        withTheme.music.items = [MusicItem(id: "mu-00000001", source: calm, start: 0, end: .max)]
        let reference = bits(try await rendered(plain))
        let silent = try await EditedMix.make(project: project, document: withTheme, framesPerSecond: 60, analysis: analysis)
        for mix in [silent, plain.with(document: withTheme, framesPerSecond: 60)] {
            #expect(!mix.music.hasSound && mix.music.played.isEmpty && mix.music.envelope.isUnity, "\(name)")
            #expect(mix.playDescription == plain.playDescription, "\(name)")
            #expect(bits(try await rendered(mix)) == reference, "\(name)")
        }
    }

    /// A sine of 220 Hz at 0.5 (its right channel −1/2 of its left) over [0, 4) s at −6 dB, with fades of 1 s: over [1, 3] s
    /// each channel is the file's times 0.501, and a mono mix hears (L + R) / 2; an offset of 1 s plays the file from 1 s on.
    /// Nothing after its end.
    @Test func aThemePlaysWhereItIsAtItsGain() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "gain", seconds: 6)
            let sine = { (n: Int) -> Float in Float(0.5 * sin(2 * Double.pi * 220 * Double(n) / 48_000)) }
            let url = try writeFile(dir, "sine", frames: 6 * 48_000) { (sine($0), -sine($0) / 2) }
            let gain = Float(pow(10, -6.0 / 20))
            for offset in [0.0, 1.0] {
                let document = edited(project, [(0, 6)], items: [item(calm, 0, 4, offset: offset, gain: -6, fadeIn: 1, fadeOut: 1)])
                let music = await musicMix(project, document, files: [calm: url])
                #expect(music.hasSound)
                #expect(music.played == [MusicMix.PlayedItem(
                    id: "mu-00000001", source: calm, frames: 0..<192_000, gain: gain, fadeIn: 48_000, fadeOut: 48_000,
                    offset: Int64(offset * 48_000), loop: true, length: 288_000, crossfade: 0)])
                let shift = Int(offset * 48_000)
                let stereo = heard(music, 0..<288_000)
                let mono = heard(music, 0..<288_000, channels: 1)
                var worst: Float = 0
                for n in 48_000...144_000 {
                    let value = gain * sine(n + shift)
                    worst = max(worst, abs(stereo[2 * n] - value), abs(stereo[2 * n + 1] + value / 2), abs(mono[n] - value / 4))
                }
                #expect(worst <= 1e-6, "offset \(offset): \(worst)")
                #expect(abs(gain - 0.501) < 0.001)
                #expect(stereo[(2 * 192_000)...].allSatisfy { $0 == 0 } && mono[192_000...].allSatisfy { $0 == 0 })
            }
        }
    }

    /// Fades are smoothsteps in amplitude from the item's edges: a fade in of 1 s is at 1/2 at 0.5 s, a fade out of 2 s at
    /// 1/2 1 s before the end; in an item of 1 s each fade is 0.5 s.
    @Test func fadesAreSmoothstepsInsideTheItem() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "fades", seconds: 6)
            let url = try writeFile(dir, "dc", frames: 6 * 48_000) { _ in (0.5, 0.5) }
            let long = await musicMix(project, edited(project, [(0, 6)], items: [item(calm, 0, 4, fadeIn: 1, fadeOut: 2)]), files: [calm: url])
            let samples = heard(long, 0..<192_000, channels: 1)
            var worst: Float = 0
            for n in 0..<192_000 {
                let fade = smoothstep(Double(n) / 48_000) * smoothstep(Double(192_000 - n) / 96_000)
                worst = max(worst, abs(samples[n] - Float(0.5 * fade)))
            }
            #expect(worst <= 1e-6, "\(worst)")
            #expect(samples[0] == 0 && abs(samples[24_000] - 0.25) <= 1e-6 && abs(samples[144_000] - 0.25) <= 1e-6)
            #expect(samples[48_000..<96_000].allSatisfy { $0 == 0.5 })

            let short = await musicMix(project, edited(project, [(0, 6)], items: [item(calm, 1, 2, fadeIn: 1, fadeOut: 2)]), files: [calm: url])
            #expect(short.played.first?.fadeIn == 24_000 && short.played.first?.fadeOut == 24_000)
            let middle = heard(short, 48_000..<96_000, channels: 1)
            #expect(abs(middle[12_000] - 0.25) <= 1e-6 && abs(middle[24_000] - 0.5) <= 1e-6 && abs(middle[36_000] - 0.25) <= 1e-6)
        }
    }

    /// A theme of the library starts again at its end with no fade: output frame `N` is its frame 0, every frame is the
    /// file's `n mod N`, bit for bit. A file of one's own starts again with a crossfade of 480 frames, so no step is larger
    /// than the file's own (where its end and its start are 0.28 apart), and after the crossfade it is the file again.
    /// Without `loop`, silence after the file's end.
    @Test func aThemeLoopsAndAFileCrossfades() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "loops", seconds: 4)
            let stair = { (n: Int) -> Float in Float(n % 48_000 + 1) / 100_000 }
            let stairs = try writeFile(dir, "stairs", frames: 48_000) { (stair($0), -stair($0)) }
            let theme = await musicMix(project, edited(project, [(0, 4)], items: [item(calm, 0, 3)]), files: [calm: stairs])
            let looped = heard(theme, 0..<144_000)
            #expect(looped[96_000] == looped[0] && looped[96_001] == looped[1])
            let wrong = (0..<144_000).filter { (n: Int) -> Bool in
                let (left, right) = (looped[2 * n].bitPattern, looped[2 * n + 1].bitPattern)
                return left != stair(n).bitPattern || right != (-stair(n)).bitPattern
            }
            #expect(wrong.isEmpty, "\(wrong.count) frames, first \(wrong.first ?? -1)")

            // 1.005 s of a sine of 220 Hz: its end is not its start.
            let length = 48_240
            let sine = { (n: Int) -> Float in Float(0.5 * sin(2 * Double.pi * 220 * Double(n) / 48_000)) }
            let wave = try writeFile(dir, "wave", frames: length) { (sine($0), sine($0)) }
            let fileJump = (1..<length).map { abs(sine($0) - sine($0 - 1)) }.max()!
            #expect(abs(sine(length - 1) - sine(0)) > 0.25, "a seam to hide")
            let own = await musicMix(project, edited(project, [(0, 4)], items: [item(ownFile, 0, 3)]), files: [ownFile: wave])
            #expect(own.played.first?.crossfade == 480 && own.played.first?.length == Int64(length))
            let ownLooped = heard(own, 0..<144_000)
            let left = stride(from: 0, to: ownLooped.count, by: 2).map { ownLooped[$0] }
            let jump = (1..<left.count).map { abs(left[$0] - left[$0 - 1]) }.max()!
            #expect(jump <= fileJump + 0.004, "\(jump) against the file's \(fileJump)")
            let period = length - 480
            #expect(bits(left[..<period]) == bits((0..<period).map(sine)))
            #expect(bits(left[(period + 480)..<(2 * period)]) == bits((480..<period).map(sine)))

            let once = await musicMix(
                project, edited(project, [(0, 4)], items: [item(ownFile, 0, 3, loop: false)]), files: [ownFile: wave])
            let single = heard(once, 0..<144_000)
            #expect(bits(stride(from: 0, to: 2 * length, by: 2).map { single[$0] }) == bits((0..<length).map(sine)))
            #expect(single[(2 * length)...].allSatisfy { $0 == 0 })
        }
    }

    /// An item past the end of the output ends with it: it fades out there, nothing of it sounds after 6 s, and the mix
    /// still lasts 6 s.
    @Test func itemsEndWithTheOutput() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "end", seconds: 6)
            let url = try writeFile(dir, "dc", frames: 12 * 48_000) { _ in (0.5, 0.5) }
            var document = edited(project, [(0, 6)], items: [item(calm, 0, 10, fadeOut: 2)])
            document.audio.tracks[AudioPlan.key(take: takeID, track: micID)] = TrackGain(gain: 1, muted: true)
            let music = await musicMix(project, document, files: [calm: url])
            #expect(music.played.first?.frames == 0..<288_000 && music.played.first?.fadeOut == 96_000)
            let samples = heard(music, 0..<480_000, channels: 1)
            #expect(abs(samples[240_000] - 0.25) <= 1e-6 && samples[288_000...].allSatisfy { $0 == 0 })
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: analysis([calm: url]))
            #expect(mix.totalFrames == 288_000)
            let mixed = try await rendered(mix)
            #expect(mixed.count == 288_000 && abs(mixed[240_000] - 0.25) <= 1e-6)
        }
    }

    /// The music is anchored to the output: cutting 1 s of the video before the theme leaves the music the same at
    /// every instant of the output.
    @Test func aCutDoesNotMoveTheMusic() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "anchor", seconds: 6)
            let url = try writeFile(dir, "stairs", frames: 6 * 48_000) { (Float($0 % 977) / 2_000, Float($0 % 613) / 2_000) }
            let items = [item(calm, 2, 4, gain: -3, fadeIn: 0.5, fadeOut: 0.5)]
            let whole = await musicMix(project, edited(project, [(0, 6)], items: items), files: [calm: url])
            let cut = await musicMix(project, edited(project, [(0, 1), (2, 6)], items: items), files: [calm: url])
            #expect(whole.played == cut.played)
            #expect(bits(heard(whole, 0..<240_000)) == bits(heard(cut, 0..<240_000)))
        }
    }

    /// The voice of the microphone over the source [1, 2) s, with [1.5, 3) s cut and a J cut of −0.2 s at the clip after
    /// the cut: it is heard over the output [1.0, 1.3) s, and the music goes to −12 dB just there, with its attack before
    /// and its release after, as `DuckingEnvelope` gives it. With an L cut of 0.2 s it is heard over [1.0, 1.7) s, and
    /// without a cut moved over [1.0, 1.5) s.
    @Test func duckingFollowsTheVoiceThroughTheCuts() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "voice", seconds: 4)
            let url = try writeFile(dir, "dc", frames: 4 * 48_000) { _ in (0.5, 0.5) }
            let inputs = analysis([calm: url], voice: [micKey: [(1, 2)]])
            let items = [item(calm, 0, 2.5)]
            let j = await musicMix(project, edited(project, [(0, 1.5), (3, 4)], items: items, shifts: [1: -200_000_000]), analysis: inputs)
            #expect(j.envelope.runs == [48_000..<62_400])
            let envelope = DuckingEnvelope(voiced: [48_000..<62_400], ducking: .default)
            let samples = heard(j, 0..<120_000, channels: 1)
            let wrong = (0..<120_000).filter { samples[$0].bitPattern != (0.5 * envelope.gain(atFrame: Int64($0))).bitPattern }
            #expect(wrong.isEmpty, "\(wrong.count) frames, first \(wrong.first ?? -1)")
            #expect(abs(samples[55_200] - Float(0.5 * pow(10, -12.0 / 20))) <= 1e-6 && samples[33_000] == 0.5 && samples[110_000] == 0.5)

            let l = await musicMix(project, edited(project, [(0, 1.5), (3, 4)], items: items, shifts: [1: 200_000_000]), analysis: inputs)
            #expect(l.envelope.runs == [48_000..<81_600])
            let none = await musicMix(project, edited(project, [(0, 1.5), (3, 4)], items: items), analysis: inputs)
            #expect(none.envelope.runs == [48_000..<72_000])
        }
    }

    /// A muted microphone, or one at 0, does not lower the music, nor does the ducking turned off; a range at −∞ over the
    /// microphone (the solo's) still does (decision 11): the ranges do not count.
    @Test func aMutedMicDoesNotDuck() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "muted", seconds: 4)
            let url = try writeFile(dir, "dc", frames: 4 * 48_000) { _ in (0.5, 0.5) }
            let inputs = analysis([calm: url], voice: [micKey: [(1, 2)]])
            let plain = edited(project, [(0, 4)], items: [item(calm, 0, 4)])
            #expect(await musicMix(project, plain, analysis: inputs).envelope.runs == [48_000..<96_000])
            var muted = plain
            muted.audio.tracks[micKey] = TrackGain(gain: 1, muted: true)
            var silent = plain
            silent.audio.tracks[micKey] = TrackGain(gain: 0, muted: false)
            var off = plain
            off.music.ducking.enabled = false
            for document in [muted, silent, off] {
                let music = await musicMix(project, document, analysis: inputs)
                #expect(music.envelope.isUnity)
                #expect(heard(music, 0..<192_000, channels: 1).allSatisfy { $0 == 0.5 })
            }
            var soloed = plain
            soloed.audio.tracks[micKey] = TrackGain(gain: 1, muted: false, ranges: [
                GainRange(id: "g-00000001", take: takeID, start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: .max), gain: GainRange.silence),
            ])
            #expect(await musicMix(project, soloed, analysis: inputs).envelope.runs == [48_000..<96_000])
        }
    }

    /// The sound of a device with a voice lowers the music; the sound of an app with a voice does not.
    @Test func deviceAudioDucksAppAudioDoesNot() async throws {
        try await withTemporaryDirectory { dir in
            let builder = try TakeBuilder(in: dir, name: "Device", formatVersion: 4)
            try await builder.addVideoTrack(
                id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 10, width: 320, height: 180)])
            try await builder.addAudioTrack(
                id: "device-audio", kind: .deviceAudio, source: TrackSource(name: "iPhone", deviceUniqueID: "00008110-000A1234"),
                segments: [AudioSegmentSpec(start: base, seconds: 3)])
            try await builder.addAudioTrack(
                id: safariID, kind: .systemAudio, source: TrackSource(name: "Safari", includedBundleIDs: ["com.apple.Safari"]),
                segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 660)])
            let project = try builder.write()
            let url = try writeFile(dir, "dc", frames: 3 * 48_000) { _ in (0.5, 0.5) }
            let inputs = analysis([calm: url], voice: [
                AudioPlan.key(take: takeID, track: "device-audio"): [(0.5, 1)], AudioPlan.key(take: takeID, track: safariID): [(2, 2.5)],
            ])
            let document = edited(project, [(0, 3)], items: [item(calm, 0, 3)])
            #expect(await musicMix(project, document, analysis: inputs).envelope.runs == [24_000..<48_000])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: inputs)
            #expect(mix.music.envelope.runs == [24_000..<48_000])
        }
    }

    /// A frozen frame in the middle of a sentence is silent: the voice stops for its 2 s, so the music comes up with the
    /// release (−6 dB 0.4 s in, all the way after 0.8 s) and goes down again with the attack before the voice goes on.
    @Test func frozenFrameLetsTheMusicUp() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "freeze", seconds: 4)
            let url = try writeFile(dir, "dc", frames: 6 * 48_000) { _ in (0.5, 0.5) }
            let inputs = analysis([calm: url], voice: [micKey: [(0.5, 3.5)]])
            var document = edited(project, [(0, 2), (2, 4)], items: [item(calm, 0, 6)])
            document.sequence.insert(
                Clip(id: "c-00000009", take: takeID, start: at(2), end: at(2), speed: 1, content: .freeze(duration: 2_000_000_000)), at: 1)
            let music = await musicMix(project, document, analysis: inputs)
            #expect(music.envelope.runs == [24_000..<96_000, 192_000..<264_000])
            let samples = heard(music, 0..<288_000, channels: 1)
            let half = Float(0.5 * pow(10, -6.0 / 20))
            #expect(abs(samples[115_200] - half) <= 1e-6, "0.4 s into the freeze")
            #expect(samples[140_000..<177_600].allSatisfy { $0 == 0.5 }, "up from 2.8 s to the attack at 3.7 s")
            #expect(abs(samples[184_800] - half) <= 1e-6, "halfway down the attack")
        }
    }

    /// In a sequence of two takes each clip ducks with the voice of its own take's microphone, wherever that take is in
    /// the sequence; a voice of a take out of its clips is not heard.
    @Test func twoTakesDuckWithTheirOwnVoice() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let url = try writeFile(dir, "dc", frames: 4 * 48_000) { _ in (0.5, 0.5) }
            let firstThenSecond = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let (one, two) = (firstThenSecond.sequence[0].start, firstThenSecond.sequence[1].start)
            var inputs = AnalysisInputs.none
            inputs.musicFiles = [calm: url]
            inputs.voiceActivity = [
                AudioPlan.key(take: "take-001", track: micID): VoiceActivity(spans: [one.adding(seconds: 0.5)..<one.adding(seconds: 1.5)]),
                AudioPlan.key(take: "take-002", track: micID): VoiceActivity(spans: [
                    two.adding(seconds: 0.2)..<two.adding(seconds: 0.6), two.adding(seconds: 2.5)..<two.adding(seconds: 2.9),
                ]),
            ]
            var document = firstThenSecond
            document.music.items = [item(calm, 0, 4)]
            #expect(await musicMix(project, document, analysis: inputs).envelope.runs == [24_000..<72_000, 105_600..<124_800])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: inputs)
            #expect(mix.music.envelope.runs == [24_000..<72_000, 105_600..<124_800])

            var secondThenFirst = MultiTakeFixtures.sequence(of: project, [("take-002", 0, 2), ("take-001", 0, 2)])
            secondThenFirst.music.items = [item(calm, 0, 4)]
            #expect(await musicMix(project, secondThenFirst, analysis: inputs).envelope.runs == [9_600..<28_800, 120_000..<168_000])
        }
    }

    /// A piece whose source has no file in the analysis, whose file is not there or is not ours is silent, and logged; the
    /// others sound as they would alone.
    @Test func aMissingFileIsSilentNotAnError() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "missing", seconds: 4)
            let url = try writeFile(dir, "dc", frames: 4 * 48_000) { _ in (0.5, 0.5) }
            let text = dir.appendingPathComponent("text.caf")
            try Data("not ours".utf8).write(to: text)
            let focus = MusicThemes.source("focus"), drive = MusicThemes.source("drive")
            let files = [calm: url, ownFile: dir.appendingPathComponent("gone.caf"), drive: text]
            let all = edited(project, [(0, 4)], items: [
                item(focus, 0, 1, id: 2), item(calm, 1, 2), item(ownFile, 2, 3, id: 3), item(drive, 3, 4, id: 4),
            ])
            let music = await musicMix(project, all, files: files)
            #expect(music.played.map(\.source) == [calm] && music.openedFiles == 1)
            let alone = await musicMix(project, edited(project, [(0, 4)], items: [item(calm, 1, 2)]), files: [calm: url])
            #expect(bits(heard(music, 0..<192_000)) == bits(heard(alone, 0..<192_000)))
            let mix = try await EditedMix.make(project: project, document: all, framesPerSecond: 60, analysis: analysis(files))
            #expect(mix.music.hasSound)
        }
    }

    /// The music of another revision (`with(document:timeMap:cuts:)`) opens no file again and plays what the music made for
    /// that document plays, sample for sample; a source the analysis it was made with has no file for is silent in it until
    /// the mix reads an analysis that has (`EditedMix.with(analysis:)`).
    @Test func withDocumentReusesTheFiles() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "reuse", seconds: 6)
            let calmFile = try writeFile(dir, "calm", frames: 2 * 48_000) { (Float($0 % 977) / 2_000, Float($0 % 613) / 2_000) }
            let focusFile = try writeFile(dir, "focus", frames: 3 * 48_000) { (Float($0 % 331) / 1_000, -Float($0 % 331) / 1_000) }
            let focus = MusicThemes.source("focus")
            var first = analysis([calm: calmFile], voice: [micKey: [(1, 2), (4, 4.6)]])
            let made = await musicMix(project, edited(project, [(0, 6)], items: [item(calm, 0, 3)]), analysis: first)
            #expect(made.openedFiles == 1)
            var next = edited(project, [(0, 2.5), (3, 6)], items: [item(calm, 0.5, 2.5, offset: 1.5, gain: -3, fadeIn: 0.3, fadeOut: 0.5)],
                              shifts: [1: -300_000_000])
            next.music.ducking = Ducking(enabled: true, amount: -20, attack: 0.1, release: 0.4)
            let timeMap = TimeMap(sequence: next.sequence)
            let again = made.with(document: next, timeMap: timeMap, cuts: AudioCuts(document: next, timeMap: timeMap))
            let fresh = await musicMix(project, next, analysis: first)
            #expect(again.openedFiles == 0)
            #expect(again.played == fresh.played && again.envelope.runs == fresh.envelope.runs && !again.envelope.isUnity)
            #expect(bits(heard(again, 0..<264_000)) == bits(heard(fresh, 0..<264_000)))

            var added = next
            added.music.items.append(item(focus, 3, 5, id: 2))
            let addedMap = TimeMap(sequence: added.sequence)
            #expect(made.with(document: added, timeMap: addedMap, cuts: AudioCuts(document: added, timeMap: addedMap)).played.map(\.source) == [calm])
            let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 6)], items: [item(calm, 0, 3)]),
                                               framesPerSecond: 60, analysis: first)
            #expect(mix.with(document: added, framesPerSecond: 60).music.played.map(\.source) == [calm])
            first.musicFiles[focus] = focusFile
            let read = await mix.with(document: added, framesPerSecond: 60).with(analysis: first)
            #expect(read.music.played.map(\.source) == [calm, focus] && read.music.openedFiles == 2)
        }
    }

    /// The preview hears the music as the export does: the mix of another revision (`EditedMix.with(document:)`) and the
    /// samples the export's encoder gets are those of the mix made for the document, bit for bit, with a theme, a file of
    /// one's own that loops, a J cut, the voice ducking it and the limiter; and the music is the same in any blocks.
    @Test func previewEqualsExportWithMusic() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "parity", seconds: 4)
            let theme = try writeFile(dir, "theme", frames: 3 * 48_000) { (Float($0 % 977) / 2_000, Float($0 % 613) / 2_000) }
            let wave = try writeFile(dir, "wave", frames: 30_000) { n in
                let value = Float(0.4 * sin(2 * Double.pi * 330 * Double(n) / 48_000))
                return (value, value * 0.8)
            }
            let inputs = analysis([calm: theme, ownFile: wave], voice: [micKey: [(0.5, 1.2), (2.5, 3)]])
            var document = edited(project, [(0, 1.5), (2, 4)], items: [item(calm, 0, 2, gain: -8, fadeIn: 1, fadeOut: 2), item(ownFile, 2, 3.4, offset: 0.4, id: 2)],
                                  shifts: [1: -150_000_000])
            document.audio.limiter = true
            let made = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: inputs)
            #expect(made.music.played.count == 2 && !made.music.envelope.isUnity)
            let reference = try await rendered(made)
            let preview = try await EditedMix.make(project: project, document: edited(project, [(0, 4)]), framesPerSecond: 60, analysis: inputs)
                .with(document: document, framesPerSecond: 60)
            #expect(bits(try await rendered(preview)) == bits(reference))
            let exported = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 60, analysis: inputs)
            #expect(bits(exported) == bits(reference))

            // In blocks of any size, one after the other.
            var sizes = SplitMix64(seed: 0x6D75_7369_6342_6C6B)
            let whole = heard(made.music, -1_000..<180_000)
            var pieces: [Float] = []
            var from: Int64 = -1_000
            while from < 180_000 {
                let to = min(180_000, from + Int64(sizes.next() % 6_000) + 1)
                pieces += heard(made.music, from..<to)
                from = to
            }
            #expect(bits(pieces) == bits(whole))
        }
    }

    /// The gain of the ducking at every frame is `DuckingEnvelope.gain(atFrame:)`, bit for bit, read from the ramps
    /// worked out once: 24 envelopes of random voices and settings (ramps that overlap among them).
    @Test func duckingGainsAreTheEnvelopes() {
        var generator = SplitMix64(seed: 0x6475_636B_696E_6731)
        for round in 0..<24 {
            let ducking = Ducking(
                enabled: true, amount: -Double(generator.next() % 4_000) / 100 - 0.5,
                attack: Double(generator.next() % 2_000) / 1_000, release: Double(generator.next() % 4_000) / 1_000)
            var voiced: [Range<Int64>] = []
            var at = Int64(generator.next() % 50_000)
            for _ in 0..<Int(generator.next() % 6) {
                let length = Int64(generator.next() % 30_000) + 1
                voiced.append(at..<(at + length))
                at += length + Int64(generator.next() % 60_000)
            }
            let envelope = DuckingEnvelope(voiced: voiced, ducking: ducking)
            let ramps = MusicMix.DuckingRamps(DuckingEnvelope.held(ducking))
            var gains: [Float] = []
            ramps.gains(of: envelope, -10_000..<(at + 200_000), into: &gains)
            let wrong = (-10_000..<(at + 200_000)).filter { gains[Int($0 + 10_000)].bitPattern != envelope.gain(atFrame: $0).bitPattern }
            #expect(wrong.isEmpty, "round \(round): \(wrong.count) frames, first \(wrong.first ?? 0)")
        }
    }

    /// A mix reads an analysis with other music files or another voice as one that sounds otherwise.
    @Test func otherMusicOrVoiceSoundsOtherwise() {
        var a = AnalysisInputs.none
        a.musicFiles = [calm: URL(fileURLWithPath: "/tmp/calm.caf")]
        var b = a
        #expect(EditedMix.hearsTheSame(a, b))
        b.musicFiles = [:]
        #expect(!EditedMix.hearsTheSame(a, b))
        b = a
        b.voiceActivity = [micKey: VoiceActivity(spans: [at(1)..<at(2)])]
        #expect(!EditedMix.hearsTheSame(a, b))
    }

    /// The mix of the export of a minute with a microphone, four apps, a theme and its ducking is at least 20 times real
    /// time (design §15): all of its blocks in less than 3 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func musicMixIsTwentyTimesRealTime() async throws {
        try await withTemporaryDirectory { dir in
            let builder = try TakeBuilder(in: dir, name: "Bench")
            try await builder.addVideoTrack(
                id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 60, framesPerSecond: 2, width: 320, height: 180)])
            try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 60, frequency: 1_000)])
            let apps = ["com.apple.Safari", "com.spotify.client", "com.apple.Music", "us.zoom.xos"]
            for (i, app) in apps.enumerated() {
                try await builder.addAudioTrack(
                    id: "system-audio-" + app.replacingOccurrences(of: ".", with: "-"), kind: .systemAudio,
                    source: TrackSource(name: app, includedBundleIDs: [app]),
                    segments: [AudioSegmentSpec(start: base, seconds: 60, channels: 2, frequency: 300 + 110 * Double(i), amplitude: 0.1)])
            }
            let project = try builder.write()
            let theme = try writeFile(dir, "theme", frames: MusicThemes.loopFrames) { n in
                let value = Float(0.3 * sin(2 * Double.pi * 110 * Double(n) / 48_000))
                return (value, -value)
            }
            let spans = stride(from: 0.5, to: 60, by: 3).map { ($0, $0 + 1.8) }
            let inputs = analysis([calm: theme], voice: [micKey: spans])
            var document = edited(project, [(0, 20), (21, 60)], items: [item(calm, 0, 59, fadeIn: 1, fadeOut: 2)])
            document.audio.limiter = true
            let clock = ContinuousClock()
            var samples: [Float] = []
            let elapsed = try await clock.measure {
                samples = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 60, analysis: inputs)
            }
            var plain = document
            plain.music.items = []
            let without = try await clock.measure {
                _ = try await MP4Exporter.mixSamples(of: project, document: plain, framesPerSecond: 60, analysis: inputs)
            }
            print("music mix bench: 59 s with a theme and ducking \(elapsed), without the theme \(without)")
            #expect(samples.count == 2 * 59 * 48_000)
            #expect(elapsed < .seconds(3), "\(elapsed)")

            // The preview's share: a revision with the same ducking, one with another (its ramps worked out again, the
            // longest there are), and the music alone in blocks of 1 024 frames.
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: inputs)
            var louder = document
            louder.music.items[0].gain = -10
            var deeper = document
            deeper.music.ducking = Ducking(enabled: true, amount: -40, attack: 2, release: 4)
            let revision = clock.measure { _ = mix.with(document: louder, framesPerSecond: 60) }
            let retuned = clock.measure { _ = mix.with(document: deeper, framesPerSecond: 60) }
            var block = [Float](repeating: 0, count: 2 * 1_024)
            let blocks = clock.measure {
                for start in stride(from: Int64(0), to: 59 * 48_000, by: 1_024) {
                    mix.music.add(start..<(start + 1_024), into: &block, channels: 2)
                }
            }
            let perBlock = blocks / (59 * 48_000 / 1_024)
            print("music preview bench: a revision \(revision), with other ducking \(retuned), a block of 1 024 frames \(perBlock)")
            #expect(perBlock < .milliseconds(1), "\(perBlock)")
        }
    }
}

// MARK: - Helpers

private let calm = MusicThemes.source("calm")
private let ownFile = "assets/" + String(repeating: "b", count: 32) + ".m4a"
private let safariID = "system-audio-com-apple-Safari"
private let micKey = AudioPlan.key(take: takeID, track: micID)

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// `seconds` in nanoseconds.
private func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

/// A take of `seconds` of the display and a microphone of a sine of 1 kHz at 1/4 of full scale.
private func voiceTake(in dir: URL, name: String, seconds: Double) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(
        id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: seconds, frequency: 1_000)])
    return try builder.write()
}

/// Writes our CAF of `frames` frames, frame `n` being `value(n)` (left, right), at `<dir>/<name>.caf`.
private func writeFile(_ dir: URL, _ name: String, frames: Int, _ value: (Int) -> (Float, Float)) throws -> URL {
    var interleaved: [Float] = []
    interleaved.reserveCapacity(2 * frames)
    for n in 0..<frames {
        let (left, right) = value(n)
        interleaved += [left, right]
    }
    let url = dir.appendingPathComponent("\(name).caf")
    try MusicFile.write(interleaved: interleaved, to: url)
    return url
}

/// A piece of `source` over output seconds `[from, to)`, its fades in seconds (none by default) and its gain in dB (0).
private func item(
    _ source: String, _ from: Double, _ to: Double, offset: Double = 0, gain: Double = 0, fadeIn: Double = 0, fadeOut: Double = 0,
    loop: Bool = true, id: Int = 1
) -> MusicItem {
    MusicItem(
        id: String(format: "mu-%08x", id), source: source, start: ns(from), end: ns(to), offset: ns(offset), gain: gain,
        fadeIn: ns(fadeIn), fadeOut: ns(fadeOut), loop: loop)
}

/// The legacy document of `project` with its clips over `spans` (seconds from the take's start) at 1×, the cut of the
/// sound of clip `k` moved by `shifts[k]` ns, and `items` as its music.
private func edited(
    _ project: LoadedProject, _ spans: [(Double, Double)], items: [MusicItem] = [], shifts: [Int: Int64] = [:]
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = spans.enumerated().map { k, span in
        Clip(id: String(format: "c-%08x", k + 1), take: project.take.id, start: at(span.0), end: at(span.1), speed: 1,
             audioShift: shifts[k] ?? 0)
    }
    document.music.items = items
    return document
}

/// The analysis with `files` as its music and `voice` (from, to in seconds of each track's take, from `base`) as the voice
/// of each track by its key.
private func analysis(_ files: [String: URL], voice: [String: [(Double, Double)]] = [:]) -> AnalysisInputs {
    var inputs = AnalysisInputs.none
    inputs.musicFiles = files
    inputs.voiceActivity = voice.mapValues { spans in VoiceActivity(spans: spans.map { at($0.0)..<at($0.1) }) }
    return inputs
}

/// The music of `document` of `project` in a mix of 2 channels, reading `files` and no voice.
private func musicMix(_ project: LoadedProject, _ document: EditDocument, files: [String: URL]) async -> MusicMix {
    await musicMix(project, document, analysis: analysis(files))
}

/// The music of `document` of `project` in a mix of 2 channels, reading `analysis`.
private func musicMix(_ project: LoadedProject, _ document: EditDocument, analysis: AnalysisInputs) async -> MusicMix {
    await MusicMix.make(
        project: project, document: document, timeMap: TimeMap(sequence: document.sequence), analysis: analysis, channels: 2)
}

/// What `music` adds over output frames `frames` to silence, with `channels` channels.
private func heard(_ music: MusicMix, _ frames: Range<Int64>, channels: Int = 2) -> [Float] {
    var samples = [Float](repeating: 0, count: frames.count * channels)
    music.add(frames, into: &samples, channels: channels)
    return samples
}

/// 3x² − 2x³ of `x` held to [0, 1].
private func smoothstep(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
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

/// The SplitMix64 generator (Steele, Lea and Flood), for a fixed seed's sequence of numbers on every run.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
