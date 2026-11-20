// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
@testable import Export

// The rhythmic themes of `music-1` (plan 3c, U3): Foco (lo-fi), Impulso (happy pop) and Pulso (electronic). Listening is
// the owner's (`docs/release.md`); these are the measures of plan decision 5, that each stays in its key and changes
// along its two minutes, that its drums sit on the grid and nothing piles up at the seam, and its bytes.

/// Each theme rendered once per process: two minutes take tens of seconds in a debug build. A `static let` is made the
/// first time a test asks for it, and the other tests wait for it.
private enum Rendered {
    static let focus = MusicSynth.render(MusicThemes.focus())
    static let drive = MusicSynth.render(MusicThemes.drive())
    static let pulse = MusicSynth.render(MusicThemes.pulse())

    static func samples(_ id: String) -> [Float] {
        switch id {
        case "focus": focus
        case "drive": drive
        default: pulse
        }
    }
}

/// What each theme must be.
private struct Expected {
    /// The pitch classes of its key (0 is C).
    var scale: Set<Int>
    /// How late its even sixteenths are (the second and fourth of each beat), as a fraction of a sixteenth; `nil` for
    /// straight sixteenths.
    var swing: ClosedRange<Double>?
    /// The SHA-256 of its samples as Float32 little-endian (plan decision 4). It changes with any change to the theme
    /// or the engine: until the first published version that is fine (update it); after, another sound is music-2.
    var digest: String

    static func of(_ id: String) -> Expected {
        switch id {
        // C major: Fmaj9, Em7, Dm9, Cmaj9, Am9, G9.
        case "focus":
            Expected(
                scale: [0, 2, 4, 5, 7, 9, 11], swing: 0.15...0.25,
                digest: "595c7b8b411d5c441f8ab0ea54b63656bc9c3230be63575bc566c5dad720966d")
        // E major: E, B, C#m, A, F#m.
        case "drive":
            Expected(
                scale: [4, 6, 8, 9, 11, 1, 3], swing: nil,
                digest: "9c85793b2f5a942b0ffc72e0dbf9080cf4c3c74934176e61039bafa7bde57953")
        // F# minor: F#m, D, A, E, Bm.
        default:
            Expected(
                scale: [6, 8, 9, 11, 1, 2, 4], swing: nil,
                digest: "3fecadcbd32ae74bf55d1d26e3a549a130460947ea7a80783e5001cab360b222")
        }
    }
}

private let themes = ["focus", "drive", "pulse"]

private func score(_ id: String) throws -> MusicScore {
    try #require(MusicThemes.score(id))
}

private func isDrum(_ instrument: Instrument) -> Bool {
    switch instrument {
    case .kick, .snare, .hat, .clap, .shaker, .vinyl: true
    case .pad, .electricPiano, .piano, .pluck, .bass, .lead: false
    }
}

/// The largest magnitude over `count` frames from `start`, around the loop.
private func peak(_ samples: [Float], from start: Int, count: Int) -> Float {
    let frames = samples.count / 2
    var largest: Float = 0
    for j in 0..<count {
        let k = ((start + j) % frames + frames) % frames
        largest = max(largest, samples[2 * k].magnitude, samples[2 * k + 1].magnitude)
    }
    return largest
}

@Suite struct Music1RhythmThemesTests {
    @Test(arguments: themes)
    func lastsTwoMinutesInStereo(_ id: String) throws {
        let score = try score(id)
        #expect(!score.isPlaceholder)
        #expect(score.id == id)
        #expect(score.loopFrames == MusicThemes.loopFrames)
        let samples = Rendered.samples(id)
        #expect(samples.count == 2 * 5_760_000)
        #expect(samples.allSatisfy { $0.isFinite })
    }

    @Test(arguments: themes)
    func isAtItsLoudnessAndUnderItsPeak(_ id: String) throws {
        let samples = Rendered.samples(id)
        let loudness = try #require(MusicMetrics.loudness(samples))
        #expect((-17.0 ... -15.0).contains(loudness), "\(id): \(loudness) LUFS")
        #expect(MusicMetrics.peak(samples) <= 0.891)
        let (left, right) = MusicMetrics.channels(samples)
        for channel in [left, right] {
            let mean = channel.reduce(0.0) { $0 + Double($1) } / Double(channel.count)
            #expect(mean.magnitude < 1e-4, "\(id): mean \(mean)")
        }
    }

    /// No step from the last frame to the first larger than one inside, and the 50 ms on each side of the seam within
    /// 1 dB of each other. Inside a theme every downbeat with its kick rises 9 to 16 dB over the end of the bar before,
    /// so each one turns around with a push instead: its last bar plays the first chord and its bass on the and of 4,
    /// tied over the seam, and the first beat of bar 1 holds it without a kick.
    @Test(arguments: themes)
    func loopsWithoutASeam(_ id: String) {
        let samples = Rendered.samples(id)
        let seam = MusicMetrics.seam(samples)
        #expect(seam.jump <= seam.largestInside, "\(id): \(seam)")
        #expect(abs(seam.windowsAcross) <= 1, "\(id): \(seam)")
    }

    @Test(arguments: themes)
    func neverDropsOut(_ id: String) {
        let quietest = MusicMetrics.quietestWindow(Rendered.samples(id))
        #expect(quietest >= -45, "\(id): \(quietest) dBFS")
    }

    @Test(arguments: themes)
    func soundsInMonoToo(_ id: String) throws {
        let samples = Rendered.samples(id)
        let correlation = MusicMetrics.correlation(samples)
        #expect((0.3...0.98).contains(correlation), "\(id): \(correlation)")
        var mono = [Float](repeating: 0, count: samples.count)
        for k in 0..<(samples.count / 2) {
            let m = (samples[2 * k] + samples[2 * k + 1]) / 2
            mono[2 * k] = m
            mono[2 * k + 1] = m
        }
        let stereo = try #require(MusicMetrics.loudness(samples))
        let folded = try #require(MusicMetrics.loudness(mono))
        #expect((folded - stereo).magnitude <= 3, "\(id): \(folded) LUFS in mono, \(stereo) in stereo")
    }

    @Test(arguments: themes)
    func hasNoRumbleNorHiss(_ id: String) {
        let samples = Rendered.samples(id)
        let low = MusicMetrics.band(samples, below: 30), high = MusicMetrics.band(samples, above: 16_000)
        #expect(low <= -25, "\(id): \(low) dB under 30 Hz")
        #expect(high <= -35, "\(id): \(high) dB over 16 kHz")
    }

    /// Every pitched note is in the theme's key, and at least 4 of its phrases of 8 bars are different (what each part
    /// plays in it, to the sixteenth).
    @Test(arguments: themes)
    func staysInItsKeyAndChanges(_ id: String) throws {
        let score = try score(id)
        let expected = Expected.of(id)
        for part in score.parts where !isDrum(part.instrument) {
            for note in part.notes {
                #expect(note.pitch == note.pitch.rounded(), "\(id): \(note.pitch)")
                let pitchClass = (Int(note.pitch.rounded()) % 12 + 12) % 12
                #expect(expected.scale.contains(pitchClass), "\(id): \(note.pitch) at beat \(note.beat)")
            }
        }
        #expect(score.bars % 8 == 0)
        let phraseBeats = Double(8 * score.beatsPerBar)
        var phrases = [[String]](repeating: [], count: score.bars / 8)
        for (p, part) in score.parts.enumerated() {
            for note in part.notes {
                let phrase = min(max(Int((note.beat / phraseBeats).rounded(.down)), 0), phrases.count - 1)
                let sixteenth = Int(((note.beat - Double(phrase) * phraseBeats) * 4).rounded())
                phrases[phrase].append("\(p):\(sixteenth):\(Int(note.pitch.rounded()))")
            }
        }
        let distinct = Set(phrases.map { $0.sorted() })
        #expect(distinct.count >= 4, "\(id): \(distinct.count) different phrases")
        #expect(phrases.allSatisfy { !$0.isEmpty })
    }

    @Test(arguments: themes)
    func samplesArePinned(_ id: String) {
        var data = Data()
        let samples = Rendered.samples(id)
        data.reserveCapacity(4 * samples.count)
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Expected.of(id).digest, "\(id)")
    }

    /// Every kick of the score is within 1 ms of its sixteenth (swung, in Foco), and so is the frame it starts at; in
    /// Foco, every drum on the second or fourth sixteenth of a beat is late by 15 to 25 % of a sixteenth.
    @Test(arguments: themes)
    func drumsLandOnTheGrid(_ id: String) throws {
        let score = try score(id)
        let swing = Expected.of(id).swing
        let middle = swing.map { ($0.lowerBound + $0.upperBound) / 2 } ?? 0
        var kicks = 0, swung = 0
        for part in score.parts where isDrum(part.instrument) && part.instrument != .vinyl {
            for note in part.notes {
                // Its sixteenth: a swung one is late by less than half a sixteenth.
                let step = Int((note.beat * 4).rounded())
                let straight = Double(step) * 0.25
                let odd = (step % 2 + 2) % 2 == 1
                if odd, let swing, part.instrument != .kick {
                    let late = (note.beat - straight) / 0.25
                    #expect(swing.contains(late), "\(id): \(part.instrument) at beat \(note.beat), \(late) late")
                    swung += 1
                }
                guard part.instrument == .kick else { continue }
                kicks += 1
                let grid = straight + (odd ? middle * 0.25 : 0)
                let error = (note.beat - grid) * 60 / score.tempo
                #expect(error.magnitude <= 0.001, "\(id): kick at beat \(note.beat)")
                let exact = grid * 60 / score.tempo * Double(MusicSynth.sampleRate)
                #expect((Double(score.frame(atBeat: note.beat)) - exact).magnitude <= 48.5, "\(id): kick at beat \(note.beat)")
            }
        }
        #expect(kicks >= score.bars * 2, "\(id): \(kicks) kicks")
        if swing != nil { #expect(swung >= score.bars * 2, "\(id): \(swung) swung sixteenths") }
    }

    /// The 50 ms on each side of the seam peak no higher than the first bar does: no fill or hit piles up at the loop's
    /// end.
    @Test(arguments: themes)
    func drumsDoNotSpikeAtTheSeam(_ id: String) throws {
        let score = try score(id)
        let samples = Rendered.samples(id)
        let window = MusicMetrics.windowFrames
        let aroundSeam = peak(samples, from: -window, count: 2 * window)
        let firstBar = peak(samples, from: 0, count: score.frame(atBeat: Double(score.beatsPerBar)))
        #expect(aroundSeam <= firstBar, "\(id): \(aroundSeam) around the seam, \(firstBar) in the first bar")
    }

    /// Release: `swift test -c release -Xswiftc -enable-testing`. Each theme renders in under 3 s (40 times real time).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), arguments: themes)
    func isFortyTimesRealTime(_ id: String) throws {
        let score = try score(id)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<3 {
            let started = clock.now
            _ = MusicSynth.render(score)
            times.append(clock.now - started)
        }
        func inSeconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let seconds = try #require(times.map(inSeconds).min())
        let all = times.map { String(format: "%.2f", inSeconds($0)) }.joined(separator: ", ")
        print("\(id): \(all) s, \(String(format: "%.0f", 120 / seconds))× real time")
        #expect(seconds < 3, "\(id): \(seconds) s")
    }
}
