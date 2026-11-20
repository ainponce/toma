// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Export
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing

// Every test here runs in `make tsan`: the decoding runs on a thread of its own, off Swift's cooperative pool.

/// `seconds` of a sine at `url`, at `sampleRate` on `channels` channels: AAC in an `.m4a`, 16-bit PCM in a `.wav`. The
/// left channel at 440 Hz, the right one (if any) at 660 Hz, so a test tells them apart.
private func writeSound(at url: URL, seconds: Double, sampleRate: Double, channels: Int) throws {
    var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
    if url.pathExtension == "m4a" {
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    } else {
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int((seconds * sampleRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<channels {
        let samples = try #require(buffer.floatChannelData?[channel])
        let frequency = channel == 0 ? 440.0 : 660.0
        for n in 0..<frames { samples[n] = 0.25 * Float(sin(2 * Double.pi * frequency * Double(n) / sampleRate)) }
    }
    try file.write(from: buffer)
}

/// A CAF of Float32 at 48 kHz (no resampling, so the decoder gives its samples exactly) of `channels` channels with the
/// layout `tag`: `blocks` blocks of 4 800 frames, block `k` holding `value(k, c)` in channel `c`, the same in each frame.
private func writeMultichannel(
    at url: URL, channels: Int, tag: AudioChannelLayoutTag, blocks: Int, _ value: (Int, Int) -> Float
) throws {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = tag
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = blocks * 4_800
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<channels {
        let samples = try #require(buffer.floatChannelData?[c])
        for n in 0..<frames { samples[n] = value(n / 4_800, c) }
    }
    try file.write(from: buffer)
}

/// The frames of the file `AVAudioFile` reads at `url`, as it reads them: its format and its length.
private func readBack(_ url: URL) throws -> (sampleRate: Double, channels: Int, frames: Int64) {
    let file = try AVAudioFile(forReading: url)
    return (file.fileFormat.sampleRate, Int(file.fileFormat.channelCount), file.length)
}

/// The names in `folder`, hidden ones included.
private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// The fractions a decoding reported, in order.
private final class Fractions: Sendable {
    private let values = Mutex<[Double]>([])
    var all: [Double] { values.withLock { $0 } }
    func add(_ value: Double) { values.withLock { $0.append(value) } }
}

@Suite struct ImportedAudioTests {
    /// A WAV of 44.1 kHz mono, one of 22.05 kHz stereo and an M4A of 48 kHz stereo come out as our CAF, at 48 kHz in
    /// two channels, with the frames of their length (the resampler's missing last frames made up), and `AVAudioFile`
    /// reads it; the mono one in both channels, the stereo ones as they are.
    @Test func decodesToOurFormat() async throws {
        try await withTemporaryDirectory { dir in
            let sounds = [("mono.wav", 44_100.0, 1, 1.5), ("low.wav", 22_050.0, 2, 1.0), ("stereo.m4a", 48_000.0, 2, 2.0)]
            for (name, rate, channels, seconds) in sounds {
                let source = dir.appending(path: name)
                try writeSound(at: source, seconds: seconds, sampleRate: rate, channels: channels)
                let destination = dir.appending(path: "\(name).caf")
                let fractions = Fractions()
                try await ImportedAudio.decode(source, to: destination) { fractions.add($0) }

                let file = try MusicFile(contentsOf: destination)
                let expected = Int((seconds * 48_000).rounded())
                #expect(abs(file.frames - expected) <= 1, "\(name): \(file.frames) frames, not \(expected)")
                let read = try readBack(destination)
                #expect(read.sampleRate == 48_000 && read.channels == 2 && read.frames == Int64(file.frames))
                #expect(fractions.all.last == 1)
                #expect(fractions.all == fractions.all.sorted())

                // A tenth of a second from the middle: the mono one twice, the stereo one with its own right.
                var samples: [Float] = []
                file.read(24_000..<28_800, into: &samples)
                let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
                let right = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }
                #expect(left.map(abs).max() ?? 0 > 0.2)
                if channels == 1 {
                    #expect(left == right)
                } else {
                    #expect(left != right)
                    #expect(right.map(abs).max() ?? 0 > 0.2)
                }
            }
        }
    }

    /// A movie without sound, and bytes that are no audio at all, are `.notAudio`, and nothing is left where it would
    /// have been written.
    @Test func notAudioIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let movie = try MediaFixtures.clip(in: dir, seconds: 0.5, size: SIMD2(64, 64), pattern: 0)
            let garbage = dir.appending(path: "garbage.m4a")
            try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }).write(to: garbage)
            let empty = dir.appending(path: "empty.wav")
            try Data().write(to: empty)
            let output = dir.appending(path: "out", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for source in [movie, garbage, empty] {
                let destination = output.appending(path: "\(source.lastPathComponent).caf")
                await #expect(throws: ImportedAudioError.notAudio) {
                    try await ImportedAudio.decode(source, to: destination) { _ in }
                }
            }
            #expect(names(in: output) == [])
        }
    }

    /// A link to a sound is never followed: `.notAudio`, nothing written.
    @Test func aLinkIsNotFollowed() async throws {
        try await withTemporaryDirectory { dir in
            let sound = dir.appending(path: "sound.wav")
            try writeSound(at: sound, seconds: 0.5, sampleRate: 48_000, channels: 1)
            let link = dir.appending(path: "link.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sound)
            let destination = dir.appending(path: "link.caf")
            await #expect(throws: ImportedAudioError.notAudio) {
                try await ImportedAudio.decode(link, to: destination) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// A 5.1 sound (L R C LFE Ls Rs) is mixed down with ITU-R BS.775's coefficients, scaled so that no side adds up to
    /// more than 1: block `k` has only channel `k` at 0.5, and the last every channel at 0.9, which never goes past full
    /// scale (summed at unity gain it would be 3.6, clipped).
    @Test func fiveOneIsMixedDownWithoutClipping() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appending(path: "five-one.caf")
            try writeMultichannel(at: source, channels: 6, tag: kAudioChannelLayoutTag_MPEG_5_1_A, blocks: 7) { k, c in
                k == 6 ? 0.9 : (k == c ? 0.5 : 0)
            }
            let destination = dir.appending(path: "out.caf")
            try await ImportedAudio.decode(source, to: destination) { _ in }
            let file = try MusicFile(contentsOf: destination)
            #expect(file.frames == 7 * 4_800)
            let half = 1 / 2.0.squareRoot(), sum = 1 + 2 * half
            // Each channel's coefficients into the left and the right.
            let expected: [(Double, Double)] = [(1, 0), (0, 1), (half, half), (0, 0), (half, 0), (0, half)]
            var samples: [Float] = []
            for (k, weight) in expected.enumerated() {
                file.read((k * 4_800 + 2_400)..<(k * 4_800 + 2_401), into: &samples)
                #expect(abs(Double(samples[0]) - 0.5 * weight.0 / sum) < 1e-6, "channel \(k), left: \(samples[0])")
                #expect(abs(Double(samples[1]) - 0.5 * weight.1 / sum) < 1e-6, "channel \(k), right: \(samples[1])")
            }
            file.read((6 * 4_800 + 2_400)..<(6 * 4_800 + 2_401), into: &samples)
            #expect(abs(samples[0] - 0.9) < 1e-6 && abs(samples[1] - 0.9) < 1e-6, "\(samples)")
            file.read(0..<file.frames, into: &samples)
            #expect(samples.allSatisfy { abs($0) <= 0.9 + 1e-6 })
        }
    }

    /// A sound of four channels its layout does not name (discrete) is the average of them all in both channels.
    @Test func unnamedChannelsAreAveraged() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appending(path: "discrete.caf")
            try writeMultichannel(
                at: source, channels: 4, tag: kAudioChannelLayoutTag_DiscreteInOrder | 4, blocks: 5
            ) { k, c in k == 4 ? 1 : (k == c ? 0.5 : 0) }
            let destination = dir.appending(path: "out.caf")
            try await ImportedAudio.decode(source, to: destination) { _ in }
            let file = try MusicFile(contentsOf: destination)
            var samples: [Float] = []
            for k in 0..<5 {
                file.read((k * 4_800 + 2_400)..<(k * 4_800 + 2_401), into: &samples)
                let expected: Float = k == 4 ? 1 : 0.125
                #expect(abs(samples[0] - expected) < 1e-6 && abs(samples[1] - expected) < 1e-6, "block \(k): \(samples)")
            }
        }
    }

    /// With a maximum of 48 000 frames, a file of 3 s gives exactly its first second.
    @Test func longFilesStopAtTheirMaximum() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appending(path: "long.wav")
            try writeSound(at: source, seconds: 3, sampleRate: 48_000, channels: 1)
            let destination = dir.appending(path: "long.caf")
            try await ImportedAudio.decode(source, to: destination, maximumFrames: 48_000) { _ in }
            #expect(try MusicFile(contentsOf: destination).frames == 48_000)
            #expect(ImportedAudio.maximumFrames == 86_400_000)
            #expect(ImportedAudio.algorithm == "importedAudio-1")
        }
    }

    /// A decoding whose task is cancelled partway throws `CancellationError` and leaves nothing.
    @Test func aCancelledDecodingLeavesNoFile() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appending(path: "long.wav")
            try writeSound(at: source, seconds: 20, sampleRate: 44_100, channels: 2)
            let output = dir.appending(path: "out", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let destination = output.appending(path: "long.caf")
            let started = Fractions()
            let task = Task {
                try await ImportedAudio.decode(source, to: destination) { fraction in
                    started.add(fraction)
                    // Slow enough that the cancellation always comes partway.
                    usleep(5_000)
                }
            }
            #expect(await eventually(timeout: .seconds(60)) { !started.all.isEmpty })
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(started.all.last ?? 1 < 1)
            #expect(names(in: output) == [])
        }
    }
}
