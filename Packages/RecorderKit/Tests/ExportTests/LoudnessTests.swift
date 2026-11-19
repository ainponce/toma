// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// A stereo-ready 1 kHz sine at 48 kHz, continuous across its parts, each at its peak level in dBFS for its seconds: the
/// signals of EBU Tech 3341, made here.
private func tone(_ parts: [(dBFS: Double, seconds: Double)]) -> [Float] {
    let period = (0..<48).map { sin(2 * Double.pi * Double($0) / 48) }
    var samples: [Float] = []
    samples.reserveCapacity(Int(parts.reduce(0) { $0 + $1.seconds } * 48_000) + 1)
    for part in parts {
        let amplitude = pow(10, part.dBFS / 20)
        for _ in 0..<Int((part.seconds * 48_000).rounded()) { samples.append(Float(amplitude * period[samples.count % 48])) }
    }
    return samples
}

/// `count` samples of noise from `seed`, up to `amplitude` (SplitMix64, so it is the same on every run).
private func noise(_ count: Int, seed: UInt64, amplitude: Double) -> [Double] {
    var state = seed
    return (0..<count).map { _ in
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) / Double(1 << 53) * 2 - 1) * amplitude
    }
}

/// The largest relative difference between two lists of block energies of the same length.
private func relativeError(_ a: [Double], _ b: [Double]) -> Double {
    precondition(a.count == b.count, "\(a.count) blocks against \(b.count)")
    return zip(a, b).map { abs($0 - $1) / max(abs($1), .leastNormalMagnitude) }.max() ?? 0
}

/// Writes `samples` as the cleanup caches hold the clean voice: CAF, Float32 LPCM, mono, 48 kHz.
private func writeClean(_ samples: [Float], to url: URL) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// A case of EBU Tech 3341: its parts (peak level in dBFS, seconds) and the loudness it measures, in LUFS.
struct EBUCase: Sendable, CustomTestStringConvertible {
    var number: Int
    var parts: [Part]
    var expected: Double
    struct Part: Sendable {
        var dBFS: Double
        var seconds: Double
    }
    var testDescription: String { "case \(number)" }
}

/// The five integrated-loudness cases of EBU Tech 3341 (1 kHz, stereo, both channels alike) give their −23 or −33 LUFS
/// within 0.1 LU: the gates leave out the quiet parts, and a step does not pull the measure.
@Test(arguments: [
    EBUCase(number: 1, parts: [.init(dBFS: -23, seconds: 20)], expected: -23),
    EBUCase(number: 2, parts: [.init(dBFS: -33, seconds: 20)], expected: -33),
    EBUCase(
        number: 3, parts: [.init(dBFS: -36, seconds: 10), .init(dBFS: -23, seconds: 60), .init(dBFS: -36, seconds: 10)], expected: -23),
    EBUCase(number: 4, parts: [
        .init(dBFS: -72, seconds: 10), .init(dBFS: -36, seconds: 10), .init(dBFS: -23, seconds: 60), .init(dBFS: -36, seconds: 10),
        .init(dBFS: -72, seconds: 10),
    ], expected: -23),
    EBUCase(number: 5, parts: [.init(dBFS: -26, seconds: 20), .init(dBFS: -20, seconds: 20.1), .init(dBFS: -26, seconds: 20)], expected: -23),
])
func ebuTech3341Cases(_ test: EBUCase) {
    let signal = tone(test.parts.map { ($0.dBFS, $0.seconds) })
    let blocks = Loudness.blockEnergies([signal, signal])
    // 400 ms blocks every 100 ms: (length − 400 ms) / 100 ms + 1 of them.
    #expect(blocks.count == (signal.count - Loudness.blockFrames) / Loudness.hopFrames + 1)
    let measured = Loudness.integrated(blocks)
    #expect(measured.map { abs($0 - test.expected) <= 0.1 } == true, "\(String(describing: measured)) LUFS")
}

/// Silence has no loudness, and a track without one is left as it is.
@Test func silenceIsNoMeasure() {
    let zeros = [Float](repeating: 0, count: 48_000)
    let blocks = Loudness.blockEnergies([zeros, zeros])
    #expect(blocks.count == 7 && blocks.allSatisfy { $0 == 0 })
    #expect(Loudness.integrated(blocks) == nil && Loudness.integrated([]) == nil)
    // Under the absolute gate (−70 LUFS), as good as silence.
    #expect(Loudness.integrated(Loudness.blockEnergies([tone([(-80, 2)])])) == nil)
    #expect(Loudness.gain(measured: nil, kind: .microphone) == 1 && Loudness.gain(measured: nil, kind: .systemAudio) == 1)
}

/// The gain brings a microphone to −16 LUFS and the rest to −20, by at most 20 dB either way, and leaves a track under
/// −60 LUFS alone.
@Test func gainFollowsTheTargetAndItsLimits() {
    func decibels(_ gain: Float) -> Double { 20 * log10(Double(gain)) }
    #expect(abs(Loudness.gain(measured: -26, kind: .microphone) - 3.1623) < 1e-4)
    #expect(abs(decibels(Loudness.gain(measured: -26, kind: .systemAudio)) - 6) < 1e-5)
    #expect(abs(decibels(Loudness.gain(measured: -26, kind: .deviceAudio)) - 6) < 1e-5)
    #expect(abs(decibels(Loudness.gain(measured: -45, kind: .microphone)) - 20) < 1e-5)
    #expect(abs(decibels(Loudness.gain(measured: -60, kind: .microphone)) - 20) < 1e-5)
    #expect(Loudness.gain(measured: -61, kind: .microphone) == 1)
    #expect(abs(decibels(Loudness.gain(measured: -2, kind: .microphone)) + 14) < 1e-5)
    #expect(abs(decibels(Loudness.gain(measured: 30, kind: .systemAudio)) + 20) < 1e-5)
    #expect(Loudness.gain(measured: .nan, kind: .microphone) == 1)
}

/// The blocks of a track measured once, dry, clean and their cross, give for any cleanup the blocks of the sound the mix
/// plays, `c·w + (1 − c)·d` on each of its channels (a mono track on both of a stereo mix, the clean voice, mono, on
/// every one): exactly, up to rounding, in double precision; within the rounding of single precision, as the mix sums.
@Test func mixedBlocksAreExact() {
    let frames = 62_400 // 1.3 s: 10 blocks.
    for (n, m) in [(1, 1), (1, 2), (2, 2)] {
        let dry = (0..<n).map { noise(frames, seed: UInt64(11 + $0), amplitude: 0.3) }
        let wet = noise(frames, seed: 5, amplitude: 0.2).enumerated().map { $1 + 0.5 * dry[0][$0] }
        let measured = Loudness.energies(dry: dry, wet: wet)
        let loudness = TrackLoudness(channels: n, dry: measured.dry, wet: measured.wet, cross: measured.cross)
        #expect(measured.dry.count == 10 && measured.wet.count == 10 && measured.cross.count == 10)
        for c in [0, 0.6, 1] {
            let blocks = Loudness.blocks(of: loudness, cleanup: c, mixChannels: m)
            let mixed = (0..<m).map { j in (0..<frames).map { c * wet[$0] + (1 - c) * dry[n == m ? j : 0][$0] } }
            let exact = relativeError(blocks, Loudness.blockEnergies(doubles: mixed))
            #expect(exact < 1e-9, "n \(n), m \(m), cleanup \(c): \(exact)")
            let sounded = (0..<m).map { j in
                (0..<frames).map { Float(c) * Float(wet[$0]) + Float(1 - c) * Float(dry[n == m ? j : 0][$0]) }
            }
            let single = relativeError(blocks, Loudness.blockEnergies(sounded))
            #expect(single < 1e-5, "n \(n), m \(m), cleanup \(c), as Float: \(single)")
        }
    }
    // Without the clean voice, the track sounds dry whatever the cleanup says.
    let dry = [noise(frames, seed: 3, amplitude: 0.3)]
    let measured = Loudness.energies(dry: dry, wet: noise(frames, seed: 4, amplitude: 0.3))
    let onlyDry = TrackLoudness(channels: 1, dry: measured.dry, wet: nil, cross: nil)
    #expect(Loudness.blocks(of: onlyDry, cleanup: 1, mixChannels: 2) == measured.dry.map { 2 * $0 })
    #expect(Loudness.blocks(of: onlyDry, cleanup: 0, mixChannels: 1) == measured.dry)
}

/// The blocks of each segment start at its first frame: two segments of 1 s have 7 blocks each (400 ms every 100 ms), the
/// blocks of what the track reads over each, and none across the pause between them.
@Test func blocksRestartAtEachSegment() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "blocks", seconds: 4, mic: [
            AudioSegmentSpec(start: voiceAt(0.5), seconds: 1, transform: voiceNoise),
            AudioSegmentSpec(start: voiceAt(2.5), seconds: 1, transform: voiceNoise),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        try #require(audio.spans.count == 2)
        for span in audio.spans {
            let measured = try await Loudness.measure(audio, span: span, clean: nil)
            #expect(measured.algorithm == "loudness-1" && measured.channels == 1)
            #expect(measured.dry.count == 7 && measured.wet == nil && measured.cross == nil && measured.clean == nil)
            let read = try await voiceRead(audio, span.frames)
            #expect(measured.dry == Loudness.blockEnergies([read]))
        }
    }
}

/// With the clean voice of a segment, the measure has its blocks and their cross with the dry, which give the blocks of
/// the mix of both, and the identity of the file it read; a file of another length is not used.
@Test func theCleanVoiceIsMeasuredWithTheDry() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "clean", seconds: 2.5, mic: [
            AudioSegmentSpec(start: voiceAt(0.25), seconds: 2, transform: voiceNoise),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        let span = try #require(audio.spans.first)
        let dry = try await voiceRead(audio, span.frames)
        let clean = tone([(-12, Double(span.frames.count) / 48_000)])
        try #require(clean.count == span.frames.count)
        let url = dir.appending(path: "seg-0001-soundIsolation-1.caf")
        try writeClean(clean, to: url)
        let measured = try await Loudness.measure(audio, span: span, clean: url)
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #expect(measured.clean == "\(info.st_size)-\(modified)")
        #expect(measured.wet == Loudness.blockEnergies([clean]))
        let loudness = TrackLoudness(channels: 1, dry: measured.dry, wet: measured.wet, cross: measured.cross)
        let mixed = (0..<clean.count).map { 0.6 * Double(clean[$0]) + 0.4 * Double(dry[$0]) }
        #expect(relativeError(Loudness.blocks(of: loudness, cleanup: 0.6, mixChannels: 1), Loudness.blockEnergies(doubles: [mixed])) < 1e-9)
        // One frame short: stale, as if there were none.
        let short = dir.appending(path: "short.caf")
        try writeClean(Array(clean.dropLast()), to: short)
        let stale = try await Loudness.measure(audio, span: span, clean: short)
        #expect(stale.wet == nil && stale.cross == nil && stale.clean == nil && stale.dry == measured.dry)
        let none = try await Loudness.measure(audio, span: span, clean: dir.appending(path: "absent.caf"))
        #expect(none == stale)
    }
}

/// A segment's measure goes to JSON and back as it was, leaving out the clean voice it does not have.
@Test func segmentLoudnessRoundTrips() throws {
    let full = SegmentLoudness(
        algorithm: Loudness.algorithm, channels: 2, dry: [0.25, 1e-9, 0.1], wet: [0.125, 0, 3.5e-3], cross: [-0.01, 0, 2e-3],
        clean: "48213-1763561234123456789")
    let data = try ProjectJSON.encoder().encode(full)
    #expect(try ProjectJSON.decoder().decode(SegmentLoudness.self, from: data) == full)
    let dry = SegmentLoudness(algorithm: Loudness.algorithm, channels: 1, dry: [0.5, 0.25], wet: nil, cross: nil, clean: nil)
    let text = try #require(String(data: try ProjectJSON.encoder().encode(dry), encoding: .utf8))
    #expect(!text.contains("wet") && !text.contains("cross") && !text.contains("clean") && text.contains("loudness-1"))
    #expect(try ProjectJSON.decoder().decode(SegmentLoudness.self, from: Data(text.utf8)) == dry)
}

/// The analysis inputs of phase 1 read no clean voice and no loudness.
@Test func analysisInputsStartEmpty() {
    #expect(AnalysisInputs.none.cleanVoice == [:] && AnalysisInputs.none.loudness == [:])
    #expect(AnalysisInputs() == .none)
}
