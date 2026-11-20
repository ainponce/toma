// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
@testable import Export

// The gentle themes of `music-1` (plan 3c, U2): Calma, Piano and Brisa, measured as the plan's decision 5 asks — the
// length, the loudness and the peak, the seam, no drop-out, mono, no rumble nor hiss — their scale and their phrases,
// and their bytes, pinned. Listening to them is the owner's (`docs/release.md`).

/// Each theme rendered once per test process (a debug build renders one in 20 to 60 s), when a test first asks for it.
private let calmSamples = MusicSynth.render(gentleScore("calm"))
private let pianoSamples = MusicSynth.render(gentleScore("piano"))
private let breezeSamples = MusicSynth.render(gentleScore("breeze"))

private func gentleScore(_ id: String) -> MusicScore {
    guard let score = MusicThemes.score(id) else { preconditionFailure("no theme \(id)") }
    return score
}

private func samples(_ id: String) -> [Float] {
    switch id {
    case "calm": calmSamples
    case "piano": pianoSamples
    case "breeze": breezeSamples
    default: preconditionFailure("not a gentle theme: \(id)")
    }
}

/// The pitch classes of each theme's key (0 is C): Calma in D lydian, Piano in A minor and C major, Brisa in G major.
private let scales: [String: Set<Int>] = [
    "calm": [2, 4, 6, 8, 9, 11, 1],
    "piano": [0, 2, 4, 5, 7, 9, 11],
    "breeze": [7, 9, 11, 0, 2, 4, 6],
]

/// The SHA-256 of each theme's samples as the cache file holds them (Float32 little-endian, stereo interleaved, without
/// the header): the same on every Mac. They may change until phase 3 is merged into `main`; after it, another sound is
/// `music-2` (plan decision 4, `docs/music.md`).
private let pinned: [String: String] = [
    "calm": "7df702cbd5249deb2c0038ac82f779cd31725cec7d99c78b12c226f58a9073f0",
    "piano": "1d5565fbd54c36579d8b9386066a1106d4e19b8e092c1aed51f2350c615268a4",
    "breeze": "846c90b1cdd7cfb691c51aa578b949250ae8091d0cb8e0be1016e1cccd81eedd",
]

private func isPitched(_ instrument: Instrument) -> Bool {
    switch instrument {
    case .pad, .electricPiano, .piano, .pluck, .bass, .lead: true
    case .kick, .snare, .hat, .clap, .shaker, .vinyl: false
    }
}

private func decibels(_ x: Float) -> Double { 20 * log10(Double(x)) }

@Suite struct Music1GentleThemesTests {
    @Test(arguments: ["calm", "piano", "breeze"])
    func lastsTwoMinutesInStereo(_ id: String) {
        let score = gentleScore(id)
        #expect(!score.isPlaceholder)
        #expect(score.loopFrames == MusicThemes.loopFrames)
        let samples = samples(id)
        #expect(samples.count == 2 * 5_760_000)
        let finite = samples.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func isAtItsLoudnessAndUnderItsPeak(_ id: String) throws {
        let samples = samples(id)
        let loudness = try #require(MusicMetrics.loudness(samples))
        #expect(abs(loudness + 16) <= 1, "\(id): \(loudness) LUFS")
        let peak = MusicMetrics.peak(samples)
        #expect(peak <= 0.891, "\(id): peak \(decibels(peak)) dBFS")
        var sums = (0.0, 0.0)
        for k in 0..<(samples.count / 2) {
            sums.0 += Double(samples[2 * k])
            sums.1 += Double(samples[2 * k + 1])
        }
        let frames = Double(samples.count / 2)
        #expect(abs(sums.0 / frames) < 1e-4 && abs(sums.1 / frames) < 1e-4, "\(id): means \(sums.0 / frames), \(sums.1 / frames)")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func loopsWithoutASeam(_ id: String) {
        let seam = MusicMetrics.seam(samples(id))
        #expect(seam.jump <= seam.largestInside, "\(id): \(seam)")
        #expect(abs(seam.windowsAcross) <= 1, "\(id): \(seam)")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func neverDropsOut(_ id: String) {
        let quietest = MusicMetrics.quietestWindow(samples(id))
        #expect(quietest >= (id == "calm" ? -50 : -45), "\(id): \(quietest) dBFS")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func soundsInMonoToo(_ id: String) throws {
        let samples = samples(id)
        let correlation = MusicMetrics.correlation(samples)
        #expect(correlation >= 0.3 && correlation <= 0.98, "\(id): correlation \(correlation)")
        // Both sides added, as one speaker plays it, on both channels.
        var mono = samples
        for k in 0..<(samples.count / 2) {
            let sum = (samples[2 * k] + samples[2 * k + 1]) / 2
            mono[2 * k] = sum
            mono[2 * k + 1] = sum
        }
        let stereo = try #require(MusicMetrics.loudness(samples))
        let folded = try #require(MusicMetrics.loudness(mono))
        #expect(abs(folded - stereo) <= 3, "\(id): \(folded) LUFS in mono, \(stereo) in stereo")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func hasNoRumbleNorHiss(_ id: String) {
        let samples = samples(id)
        let low = MusicMetrics.band(samples, below: 30)
        let high = MusicMetrics.band(samples, above: 16_000)
        #expect(low <= -25, "\(id): \(low) dB under 30 Hz")
        #expect(high <= -35, "\(id): \(high) dB over 16 kHz")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func staysInItsKeyAndChanges(_ id: String) throws {
        let score = gentleScore(id)
        let scale = try #require(scales[id])
        let phraseBeats = Double(8 * score.beatsPerBar)
        let phrases = score.bars / 8
        #expect(score.bars % 8 == 0)
        // What each phrase plays, as (part, beat in the phrase to the nearest sixteenth, pitch): humanizing moves no
        // note that far.
        var played = [[[Double]]](repeating: [], count: phrases)
        for (p, part) in score.parts.enumerated() where isPitched(part.instrument) {
            for note in part.notes {
                let pitchClass = (Int(note.pitch.rounded()) % 12 + 12) % 12
                #expect(scale.contains(pitchClass), "\(id): \(note.pitch) at beat \(note.beat) is out of its key")
                let beat = (note.beat * 4).rounded() / 4
                let phrase = min(max(Int((beat / phraseBeats).rounded(.down)), 0), phrases - 1)
                played[phrase].append([Double(p), beat - Double(phrase) * phraseBeats, note.pitch])
            }
        }
        let distinct = Set(played.map { $0.sorted { $0.lexicographicallyPrecedes($1) } })
        #expect(distinct.count >= 4, "\(id): \(distinct.count) different phrases of \(phrases)")
        #expect(played.allSatisfy { !$0.isEmpty }, "\(id): a phrase plays nothing")
    }

    @Test(arguments: ["calm", "piano", "breeze"])
    func samplesArePinned(_ id: String) {
        var bytes = Data()
        bytes.reserveCapacity(4 * samples(id).count)
        for sample in samples(id) {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == pinned[id], "\(id): \(digest)")
    }

    /// The time to render each theme (the cache does it the first time a theme is used), against 40 times real time
    /// (3 s for 2 min), one theme at a time: a render already uses every core. Run by an agent in release, with
    /// `TOMA_BENCH=1`; the times go to `docs/performance.md`.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .serialized,
        arguments: ["calm", "piano", "breeze"])
    func isFortyTimesRealTime(_ id: String) {
        let score = gentleScore(id)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<3 {
            times.append(clock.measure { _ = MusicSynth.render(score) })
        }
        let best = times.min() ?? .zero
        print("isFortyTimesRealTime (\(id)): \(times.map(\.description).joined(separator: ", ")); best \(best)")
        #expect(best < .seconds(3), "\(id): \(best)")
    }
}
