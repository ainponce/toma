// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
@testable import Export

// The engine of `music-1` (plan 3c, U1): its arithmetic, its randomness, that a render is the same bytes every time and
// loops without a seam, and its file. The scores here are short (a loop of 4 s, rendered with its 8 s of tail), so the
// tests stay quick in a debug build.

// MARK: - Scores of the tests

/// 120 BPM, 4/4: a bar is 2 s, 96 000 frames.
private let testTempo = 120.0

/// Two bars (4 s): a pad (whose filter sways twice a loop) with two chords and a chorus, a pluck on the off-beats, a
/// kick on every beat, a reverb and a delay; repeated `passes` times, each copy with the same seeds as the first, so the
/// score of two passes is the score of one played twice.
private func testScore(passes: Int = 1, seed: UInt64 = 42) -> MusicScore {
    var pad: [ScoreNote] = []
    var pluck: [ScoreNote] = []
    var kick: [ScoreNote] = []
    for pass in 0..<passes {
        let offset = Double(pass * 8)
        for (i, pitch) in [48.0, 55, 60, 64].enumerated() {
            pad.append(ScoreNote(beat: offset, beats: 4, pitch: pitch, velocity: 0.6, seed: UInt64(i)))
        }
        for (i, pitch) in [45.0, 52, 57, 60].enumerated() {
            pad.append(ScoreNote(beat: offset + 4, beats: 4, pitch: pitch, velocity: 0.6, seed: UInt64(10 + i)))
        }
        for (i, pitch) in [72.0, 76, 79, 76, 69, 72, 76, 72].enumerated() {
            pluck.append(ScoreNote(beat: offset + Double(i) + 0.5, beats: 0.5, pitch: pitch, velocity: 0.7, seed: UInt64(100 + i)))
        }
        for i in 0..<8 {
            kick.append(ScoreNote(beat: offset + Double(i), beats: 0.25, pitch: 60, velocity: 0.8, seed: UInt64(200 + i)))
        }
    }
    let padPreset = PadPreset(attack: 0.3, release: 1, sweepDepth: 0.6, sweepRate: 0.5)
    return MusicScore(
        id: "test", tempo: testTempo, beatsPerBar: 4, bars: 2 * passes, seed: seed,
        parts: [
            ScorePart(instrument: .pad(padPreset), notes: pad, gain: 0.5, reverbSend: 0.3, chorus: ChorusSettings(rate: 0.5)),
            ScorePart(instrument: .pluck(.harp), notes: pluck, gain: 0.6, pan: 0.3, reverbSend: 0.4, delaySend: 0.3),
            ScorePart(instrument: .kick, notes: kick, gain: 0.7, reverbSend: 0),
        ],
        reverb: ReverbSettings(decay: 1.5), delay: DelaySettings(beats: 0.75, feedback: 0.3), masterGain: 0.6,
        isPlaceholder: false)
}

/// Equal bit for bit.
private func sameBits(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
}

private func largestDifference(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    zip(a, b).reduce(0) { max($0, ($1.0 - $1.1).magnitude) }
}

/// The mean square of frames `range` of `samples`, both channels.
private func meanSquare(_ samples: [Float], _ range: Range<Int>) -> Double {
    var sum = 0.0
    for k in range {
        sum += Double(samples[2 * k]) * Double(samples[2 * k]) + Double(samples[2 * k + 1]) * Double(samples[2 * k + 1])
    }
    return sum / Double(2 * range.count)
}

private func seconds(_ s: Double) -> Int { Int(s * 48_000) }

@Suite struct MusicSynthTests {
    // MARK: Arithmetic and randomness

    @Test func synthMathIsBitExact() {
        // Pinned: the same bits on every Mac. They change only if `SynthMath` does (and with it every theme). Each is
        // within one unit in the last place of libm's value; six of them are libm's very bits.
        let pinned: [(String, Double, UInt64)] = [
            ("sine 0.1", SynthMath.sine(cycles: 0.1), 0x3FE2_CF23_0475_5A5E),
            ("sine 0.37", SynthMath.sine(cycles: 0.37), 0x3FE7_53B6_03D2_B816),
            ("sine -0.8", SynthMath.sine(cycles: -0.8), 0x3FEE_6F0E_1344_54FF),
            ("sine 12345.678", SynthMath.sine(cycles: 12_345.678), 0xBFEC_C7ED_85AA_7580),
            ("cosine 0.2", SynthMath.cosine(cycles: 0.2), 0x3FD3_C6EF_372F_E94E),
            ("exp2 0.5", SynthMath.exp2(0.5), 0x3FF6_A09E_667F_3BCC),
            ("exp2 -3.3", SynthMath.exp2(-3.3), 0x3FB9_FDF8_BCCE_533E),
            ("exp2 10.25", SynthMath.exp2(10.25), 0x4093_06FE_0A31_B715),
            ("tanh 0.1", SynthMath.tanh(0.1), 0x3FB9_83D7_795F_413A),
            ("tanh -1.5", SynthMath.tanh(-1.5), 0xBFEC_F6F9_786D_F576),
            ("frequency 60", SynthMath.frequency(midi: 60), 0x4070_5A02_50C2_B956),
            ("frequency 69.5", SynthMath.frequency(midi: 69.5), 0x407C_4E49_A9B8_4B7F),
        ]
        for (name, value, bits) in pinned {
            #expect(value.bitPattern == bits, "\(name): 0x\(String(value.bitPattern, radix: 16, uppercase: true))")
        }
        #expect((SynthMath.sine(cycles: 0.25) - 1).magnitude <= 1e-12)
        #expect(SynthMath.sine(cycles: 0) == 0)
        #expect(SynthMath.sine(cycles: .infinity).isNaN)
        #expect(SynthMath.exp2(0) == 1)
        #expect(SynthMath.exp2(-2000) == 0)
        #expect(SynthMath.exp2(2000) == .infinity)
        #expect(SynthMath.tanh(30) == 1 && SynthMath.tanh(-30) == -1)
        #expect(SynthMath.frequency(midi: 69) == 440)
        // Against libm (in the test only), over many points.
        var worstSine = 0.0, worstExp2 = 0.0, worstProduct = 0.0, worstTanh = 0.0
        for i in 0...20_000 {
            let x = Double(i) / 20_000
            worstSine = max(worstSine, (SynthMath.sine(cycles: x * 7 - 3.5) - sin(2 * Double.pi * (x * 7 - 3.5))).magnitude)
            let y = x * 128 - 64
            worstExp2 = max(worstExp2, ((SynthMath.exp2(y) - Foundation.exp2(y)) / Foundation.exp2(y)).magnitude)
            worstProduct = max(worstProduct, (SynthMath.exp2(y) * SynthMath.exp2(-y) - 1).magnitude)
            let z = x * 12 - 6
            worstTanh = max(worstTanh, (SynthMath.tanh(z) - Foundation.tanh(z)).magnitude)
        }
        #expect(worstSine <= 1e-9, "sine \(worstSine)")
        #expect(worstSine <= 1e-14, "sine \(worstSine)")
        #expect(worstExp2 <= 1e-12, "exp2 \(worstExp2)")
        #expect(worstProduct <= 1e-15, "exp2(x)·exp2(−x) \(worstProduct)")
        #expect(worstTanh <= 1e-15, "tanh \(worstTanh)")
    }

    @Test func randomIsSplitMix64() {
        // The reference outputs of Vigna's splitmix64.c from 0.
        var random = SynthRandom(seed: 0)
        #expect(random.next() == 0xE220_A839_7B1D_CDAF)
        #expect(random.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(random.next() == 0x06C4_5D18_8009_454F)
        var other = SynthRandom(seed: 0xDEAD_BEEF)
        var lowest = 1.0, highest = 0.0
        for _ in 0..<10_000 {
            let u = other.unit()
            lowest = min(lowest, u)
            highest = max(highest, u)
            #expect(u >= 0 && u < 1)
            let b = other.bipolar()
            #expect(b >= -1 && b < 1)
        }
        #expect(lowest < 0.01 && highest > 0.99)
        #expect(SynthRandom.mix(1, 2, 3) == SynthRandom.mix(1, 2, 3))
        #expect(SynthRandom.mix(1, 2, 3) != SynthRandom.mix(1, 3, 2))
    }

    // MARK: Rendering

    @Test func renderIsTheSameBytesEveryRun() {
        let score = testScore()
        let first = MusicSynth.render(score)
        #expect(first.count == 2 * 192_000)
        #expect(sameBits(first, MusicSynth.render(score)))
        _ = MusicSynth.render(testScore(seed: 7))
        #expect(sameBits(first, MusicSynth.render(score)))
        #expect(first.allSatisfy { $0.isFinite && $0.magnitude < 0.9 })
        #expect(MusicMetrics.peak(first) > 0.05)
        // Pinned, so another Mac (or another version of macOS) gives these very bytes. A change to the engine that changes
        // them raises `MusicSynth.engineVersion` (so the music library makes its themes again) and adds a row here for
        // it; a row is never edited. Until the first published version that is fine; after, another sound is music-2.
        let pinned = [1: "9c136a165a700d05c21d0e57af74ad83dcd4f9445969ef77b6db729ba180d597"]
        let digest = SHA256.hash(data: MusicFile.data(interleaved: first)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == pinned[MusicSynth.engineVersion])
    }

    @Test func fingerprintFollowsTheScore() {
        let score = testScore()
        #expect(score.fingerprint == testScore().fingerprint)
        #expect(score.fingerprint.count == 16 && score.fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        var other = score
        other.seed = 43
        #expect(other.fingerprint != score.fingerprint)
        other = score
        other.parts[0].instrument = .pad(.airy)
        #expect(other.fingerprint != score.fingerprint)
        other = score
        other.reverb.decay = 1.6
        #expect(other.fingerprint != score.fingerprint)
        other = score
        other.isPlaceholder = true
        #expect(other.fingerprint != score.fingerprint)
    }

    @Test func aDifferentSeedIsADifferentSound() {
        var score = testScore()
        score.parts = score.parts.map { part in
            var part = part
            part.notes = part.notes.map { note in
                var note = note
                note.seed = nil
                return note
            }
            return part
        }
        var other = score
        other.seed = 43
        #expect(!sameBits(MusicSynth.render(score), MusicSynth.render(other)))
    }

    @Test func renderStopsWhenCancelled() {
        var asked = 0
        #expect(MusicSynth.render(testScore(), until: {
            asked += 1
            return asked > 2
        }) == nil)
        #expect(asked == 3)
    }

    @Test func twoLoopsAreOneLoopTwice() {
        let one = MusicSynth.render(testScore())
        let two = MusicSynth.render(testScore(passes: 2))
        #expect(two.count == 2 * one.count)
        let half = one.count
        let first = largestDifference(two[0..<half], one[...])
        let second = largestDifference(two[half...], one[...])
        #expect(first <= 1e-6, "first pass \(first)")
        #expect(second <= 1e-6, "second pass \(second)")
    }

    @Test func tailsWrapOntoTheStart() {
        // One pluck on the last beat of a 4 s loop, through a reverb of 3 s and nothing else.
        func score(bars: Int) -> MusicScore {
            let note = ScoreNote(beat: 7, beats: 1, pitch: 64, velocity: 0.9, seed: 5)
            return MusicScore(
                id: "tail", tempo: testTempo, beatsPerBar: 4, bars: bars, seed: 1,
                parts: [ScorePart(instrument: .pluck(.harp), notes: [note], gain: 0.5, reverbSend: 1)],
                reverb: ReverbSettings(decay: 3, damping: 8_000, preDelay: 0), delay: nil, masterGain: 0.5, isPlaceholder: false)
        }
        let looped = MusicSynth.render(score(bars: 2))
        // Its tail is in the first 3 s of the file, fading…
        let start = meanSquare(looped, 0..<seconds(0.5))
        #expect(10 * log10(start) > -60)
        #expect(start > meanSquare(looped, seconds(1)..<seconds(1.5)))
        #expect(meanSquare(looped, seconds(1)..<seconds(1.5)) > meanSquare(looped, seconds(2.5)..<seconds(3)))
        // …and it is where the same note's tail is in a loop long enough not to wrap (6 bars, 12 s, the note at 3.5 s):
        // the 4 s loop is the long render's three stretches of 4 s added up.
        let long = MusicSynth.render(score(bars: 6))
        let frames = 192_000
        var worst: Float = 0
        for k in 0..<seconds(3) {
            for c in 0..<2 {
                let sum = long[2 * k + c] + long[2 * (k + frames) + c] + long[2 * (k + 2 * frames) + c]
                worst = max(worst, (looped[2 * k + c] - sum).magnitude)
            }
        }
        #expect(worst <= 1e-5, "\(worst)")
    }

    @Test func aNoteAcrossTheLoopsEndIsNotCut() {
        // 6 bars at 120 BPM: a loop of 12 s. A pad starts just before its end (beat −0.02, as `humanized` may leave a
        // downbeat), held 8 s with a release of 2 s: it sounds 10 s into the next pass, past the 8 s of tail. It must tie
        // across the seam and end where its release ends, never cut where the tail of 8 s would have ended.
        let pad = PadPreset(attack: 0.05, release: 2, cutoff: 600, sweepDepth: 0)
        let score = MusicScore(
            id: "tie", tempo: testTempo, beatsPerBar: 4, bars: 6, seed: 1,
            parts: [ScorePart(instrument: .pad(pad), notes: [ScoreNote(beat: -0.02, beats: 16, pitch: 57, velocity: 0.8)], gain: 0.5, reverbSend: 0)],
            reverb: .none, delay: nil, masterGain: 1, isPlaceholder: false)
        let samples = MusicSynth.render(score)
        let frames = samples.count / 2
        #expect(frames == 576_000)
        /// The largest step from frame k to the next (around the loop), over both channels.
        func step(_ k: Int) -> Float {
            let next = (k + 1) % frames
            return max((samples[2 * next] - samples[2 * k]).magnitude, (samples[2 * next + 1] - samples[2 * k + 1]).magnitude)
        }
        /// Whether the step after frame `k` is like the steps within 10 ms of it: no more than twice the largest of them.
        func isLocal(_ k: Int) -> (Bool, Float, Float) {
            var around: Float = 0
            for j in (k - 480)...(k + 480) where j != k { around = max(around, step((j + frames) % frames)) }
            return (step(k) <= 2 * around, step(k), around)
        }
        let atTheSeam = isLocal(frames - 1)
        #expect(atTheSeam.0, "at the seam: \(atTheSeam.1) against \(atTheSeam.2)")
        // Where the render of N + 8 s would end: frame 8 s of the loop, in the note's release.
        let atTheTail = isLocal(MusicSynth.tailFrames - 1)
        #expect(atTheTail.0, "at 8 s: \(atTheTail.1) against \(atTheTail.2)")
        #expect(meanSquare(samples, seconds(7.9)..<seconds(8)) > 1e-4)
        // Its release ends at 10 s minus 10 ms; after it, silence (but for the channel's mean taken out).
        #expect(meanSquare(samples, seconds(10)..<seconds(11.9)) < 1e-10)
    }

    @Test func seamIsNotAJump() {
        // What goes on across the seam: two pad chords held a bar each, a record's crackle the whole loop, a chorus, the
        // reverb and the delay. Each pass of the loop leads into the next as any frame into the next.
        let chords = ScoreBuilder.chords([Chord("Cmaj7"), Chord("Am7")], bars: 1, velocity: 0.6)
        let pad = PadPreset(attack: 2, release: 2, sweepDepth: 0.5, sweepRate: 0.25)
        let score = MusicScore(
            id: "seam", tempo: testTempo, beatsPerBar: 4, bars: 2, seed: 9,
            parts: [
                ScorePart(instrument: .pad(pad), notes: chords, gain: 0.5, reverbSend: 0.4, delaySend: 0.2, chorus: .lush),
                ScorePart(instrument: .vinyl, notes: [ScoreNote(beat: 0, beats: 8, pitch: 60, velocity: 1)], gain: 1),
            ],
            reverb: .hall, delay: DelaySettings(), masterGain: 0.8, isPlaceholder: false)
        let samples = MusicSynth.render(score)
        let seam = MusicMetrics.seam(samples)
        #expect(seam.jump <= seam.largestInside, "\(seam)")
        #expect(seam.windowsAcross.magnitude <= 0.5, "\(seam)")
    }

    @Test func loopFramesAreExact() {
        let themes: [(Double, Int, Int)] = [(64, 4, 32), (80, 4, 40), (112, 4, 56), (72, 3, 48), (128, 4, 64), (96, 4, 48)]
        for (tempo, beatsPerBar, bars) in themes {
            let score = MusicScore(
                id: "x", tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: 0, parts: [], reverb: .none, delay: nil,
                masterGain: 1, isPlaceholder: false)
            #expect(score.loopFrames == 5_760_000, "\(tempo) BPM")
        }
        func frames(_ tempo: Double, bars: Int, beatsPerBar: Int = 4) -> Int? {
            MusicScore(
                id: "x", tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: 0, parts: [], reverb: .none, delay: nil,
                masterGain: 1, isPlaceholder: false
            ).loopFrames
        }
        #expect(frames(100, bars: 3) == 345_600)
        #expect(frames(60, bars: 3) == 576_000)
        #expect(frames(7, bars: 1) == nil)
        #expect(frames(7, bars: 7) == 11_520_000)
        #expect(frames(0, bars: 1) == nil)
        #expect(frames(.nan, bars: 1) == nil)
        #expect(frames(120, bars: 0) == nil)
        #expect(frames(120, bars: 1000) == nil) // 33 min: longer than a loop may be
    }

    @Test func emptyScoreIsSilence() {
        let score = MusicScore(
            id: "x", tempo: 120, beatsPerBar: 4, bars: 1, seed: 0, parts: [], reverb: .hall, delay: DelaySettings(),
            masterGain: 1, isPlaceholder: false)
        let samples = MusicSynth.render(score)
        #expect(samples.count == 2 * 96_000)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test func everyInstrumentSounds() {
        let instruments: [Instrument] = [
            .pad(.warm), .electricPiano(.mellow), .piano(.grand), .pluck(.steel), .bass(.synth), .lead(.bright), .kick, .snare,
            .hat(open: false), .hat(open: true), .clap, .shaker, .vinyl,
        ]
        for instrument in instruments {
            let score = MusicScore(
                id: "x", tempo: 120, beatsPerBar: 4, bars: 1, seed: 3,
                parts: [ScorePart(instrument: instrument, notes: [ScoreNote(beat: 0, beats: 1, pitch: 57, velocity: 0.8)])],
                reverb: .none, delay: nil, masterGain: 1, isPlaceholder: false)
            let samples = MusicSynth.render(score)
            let peak = MusicMetrics.peak(samples)
            #expect(peak > 0.01 && peak < 0.9, "\(instrument): \(peak)")
            #expect(samples.allSatisfy { $0.isFinite }, "\(instrument)")
        }
    }

    // MARK: The file

    @Test func musicFileIsOurCAF() async throws {
        let samples = (0..<4_800).map { i -> Float in
            let tone = Float(SynthMath.sine(cycles: Double(i / 2) * 440 / 48_000))
            return tone * (i % 2 == 0 ? 0.5 : -0.25)
        }
        try await withTemporaryDirectory { folder in
            let url = folder.appending(path: "calm.caf")
            try MusicFile.write(interleaved: samples, to: url)
            let bytes = try Data(contentsOf: url)
            #expect(bytes == MusicFile.data(interleaved: samples))
            #expect(bytes.count == 68 + 4 * samples.count)
            let header = bytes.prefix(68).map { String(format: "%02x", $0) }.joined()
            #expect(header == "6361666600010000" + "64657363" + "0000000000000020" + "40e7700000000000" + "6c70636d"
                + "00000003" + "00000008" + "00000001" + "00000002" + "00000020" + "64617461" + "0000000000004b04"
                + "00000000")
            // AVAudioFile reads it as what it is.
            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 2)
            #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
            #expect(file.length == 2_400)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_400))
            try file.read(into: buffer)
            let channels = try #require(buffer.floatChannelData)
            var same = buffer.frameLength == 2_400
            for k in 0..<Int(buffer.frameLength) {
                same = same && channels[0][k] == samples[2 * k] && channels[1][k] == samples[2 * k + 1]
            }
            #expect(same)
            // Our reader: the same samples, silence outside the file.
            let ours = try MusicFile(contentsOf: url)
            #expect(ours.frames == 2_400)
            var read: [Float] = []
            ours.read(-2..<3, into: &read)
            #expect(read == [0, 0, 0, 0] + Array(samples[0..<6]))
            ours.read(2_398..<2_402, into: &read)
            #expect(read == Array(samples[4_796..<4_800]) + [0, 0, 0, 0])
            ours.read(5_000..<5_002, into: &read)
            #expect(read == [0, 0, 0, 0])
            #expect(MusicFile.isOurs(at: url, frames: 2_400))
            #expect(!MusicFile.isOurs(at: url, frames: 2_401))

            // A link to it is not it, and is not followed.
            let link = folder.appending(path: "link.caf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            #expect(throws: POSIXError(.ELOOP)) { try MusicFile(contentsOf: link) }
            #expect(!MusicFile.isOurs(at: link, frames: 2_400))
            // One cut short is not.
            let short = folder.appending(path: "short.caf")
            try bytes.prefix(bytes.count - 8).write(to: short)
            #expect(!MusicFile.isOurs(at: short, frames: 2_400))
            try bytes.prefix(bytes.count - 3).write(to: short)
            #expect(throws: MusicFileError.notOurs) { try MusicFile(contentsOf: short) }
            // Nor is a WAV of the same samples.
            let wav = folder.appending(path: "calm.wav")
            do {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
                let writer = try AVAudioFile(forWriting: wav, settings: format.settings)
                try writer.write(from: buffer)
            }
            #expect(throws: MusicFileError.notOurs) { try MusicFile(contentsOf: wav) }
            // Nor a folder.
            #expect(throws: POSIXError(.EFTYPE)) { try MusicFile(contentsOf: folder) }
        }
    }

    // MARK: The library's themes

    @Test func everyThemeHasAScore() {
        #expect(MusicThemes.ids == ["calm", "focus", "drive", "piano", "pulse", "breeze"])
        #expect(MusicThemes.algorithm == "music-1")
        for id in MusicThemes.ids {
            let score = MusicThemes.score(id)
            #expect(score?.id == id)
            #expect(score?.loopFrames == MusicThemes.loopFrames, "\(id)")
            #expect(score.map { !$0.parts.isEmpty } == true)
            #expect(MusicThemes.source(id) == "library:music-1/\(id)")
            #expect(MusicThemes.id(ofSource: MusicThemes.source(id)) == id)
        }
        #expect(MusicThemes.loopFrames == 5_760_000)
        #expect(MusicThemes.score("rain") == nil)
        #expect(MusicThemes.id(ofSource: "library:music-2/calm") == nil)
        #expect(MusicThemes.id(ofSource: "library:music-1/rain") == nil)
        #expect(MusicThemes.id(ofSource: "library:music-1/") == nil)
        #expect(MusicThemes.id(ofSource: "asset:music.m4a") == nil)
    }

    // MARK: Writing a score

    @Test func scoreBuilderLaysOutNotes() {
        #expect(Pitch.midi("C4") == 60)
        #expect(Pitch.midi("A4") == 69)
        #expect(Pitch.midi("Eb3") == 51)
        #expect(Pitch.midi("F#2") == 42)
        #expect(Pitch.parse("H2") == nil)
        #expect(Chord("Am7", octave: 3).pitches == [57, 60, 64, 67])
        #expect(Chord("F#", octave: 2).pitches == [42, 46, 49])
        #expect(Voicing.open.apply([60, 64, 67, 71]) == [60, 67, 76, 83])
        #expect(Voicing.inversion(1).apply([60, 64, 67]) == [64, 67, 72])
        #expect(Voicing.root(octaves: -1).apply([60, 64, 67]) == [48])

        #expect(Chord("C").root == 48)
        let spans = ScoreBuilder.progression([Chord("C", octave: 4), Chord("G", octave: 4)], bars: 1)
        #expect(spans.map(\.beat) == [0, 4])
        let chords = ScoreBuilder.chords(spans, voicing: .close, velocity: 0.5)
        #expect(chords.count == 6)
        #expect(chords.allSatisfy { $0.beats == 4 && $0.velocity == 0.5 })

        let arpeggio = ScoreBuilder.arpeggio([spans[0]], pattern: ArpeggioPattern(step: 1, order: [0, 2, 3, -1], gate: 1, velocity: 0.5, accent: 0))
        #expect(arpeggio.map(\.pitch) == [60, 67, 72])
        #expect(arpeggio.map(\.beat) == [0, 1, 2])

        let drums = ScoreBuilder.drums(DrumPattern(steps: "X-x- | o-g-", step: 0.5, bars: 1), swing: 0.2)
        #expect(drums.map(\.beat) == [0, 1, 2, 3])
        #expect(drums.map(\.velocity) == [1, 0.8, 0.55, 0.3])
        let swung = ScoreBuilder.drums(DrumPattern(steps: "xx", step: 0.5, bars: 1), swing: 0.5)
        #expect(swung.map(\.beat) == [0, 0.75, 1, 1.75, 2, 2.75, 3, 3.75])

        let melody = ScoreBuilder.melody("C5 - E5 . | G5 72", step: 0.5, from: 1)
        #expect(melody.map(\.pitch) == [72, 76, 79, 72])
        #expect(melody.map(\.beat) == [1, 2, 3, 3.5])
        #expect(melody.map(\.beats) == [1, 0.5, 0.5, 0.5])

        let humanized = ScoreBuilder.humanized(chords, seed: 5, timing: 0.02, velocity: 0.1)
        #expect(humanized == ScoreBuilder.humanized(chords, seed: 5, timing: 0.02, velocity: 0.1))
        #expect(humanized != chords)
        #expect(zip(humanized, chords).allSatisfy { ($0.beat - $1.beat).magnitude <= 0.02 && $0.pitch == $1.pitch })

        let repeated = ScoreBuilder.repeated(melody, every: 8, times: 3)
        #expect(repeated.count == 12)
        #expect(repeated[4].beat == 9)
        #expect(ScoreBuilder.transposed(melody, by: -12).map(\.pitch) == [60, 64, 67, 60])
    }
}
