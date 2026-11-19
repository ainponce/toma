// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

// These run the system's `AUSoundIsolation`, so only on a Mac that has it (phase 2 rules); the voice is spoken on this
// Mac by `AVSpeechSynthesizer.write`, without the network, and the test is skipped without a Spanish voice.

/// What a speech synthesizer's buffers gave, in order, and whether it finished.
private final class SpokenSamples: Sendable {
    let state = Mutex<(samples: [Float], format: AVAudioFormat?, finished: Bool)>(([], nil, false))
}

/// `text` spoken by the first voice of `language` this Mac has, at 48 kHz in mono; `nil` without one.
@MainActor
private func speech(_ text: String, language: String) async throws -> [Float]? {
    guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == language }) else { return nil }
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    let spoken = SpokenSamples()
    let (samples, format): ([Float], AVAudioFormat?) = await withCheckedContinuation { continuation in
        synthesizer.write(utterance) { buffer in
            let pcm = buffer as? AVAudioPCMBuffer
            let done: ([Float], AVAudioFormat?)? = spoken.state.withLock { state in
                guard !state.finished else { return nil }
                guard let pcm, pcm.frameLength > 0, let data = pcm.floatChannelData else {
                    state.finished = true
                    return (state.samples, state.format)
                }
                state.format = pcm.format
                state.samples += UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength))
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
    withExtendedLifetime(synthesizer) {}
    guard let format, !samples.isEmpty else { return nil }
    return try resampled(samples, from: format.sampleRate)
}

/// Mono Float32 `samples` at `rate` to 48 kHz.
private func resampled(_ samples: [Float], from rate: Double) throws -> [Float] {
    let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let converter = try #require(AVAudioConverter(from: input, to: output))
    let source = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)))
    source.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let capacity = AVAudioFrameCount(Double(samples.count) * 48_000 / rate) + 4_096
    let result = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity))
    nonisolated(unsafe) var given = false
    var error: NSError?
    let status = converter.convert(to: result, error: &error) { _, inputStatus in
        if given {
            inputStatus.pointee = .endOfStream
            return nil
        }
        given = true
        inputStatus.pointee = .haveData
        return source
    }
    #expect(status != .error, "\(String(describing: error))")
    return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
}

/// White noise, uniform, at `dBFS` RMS (SplitMix64 from `seed`, the same on every run).
private func whiteNoise(_ count: Int, dBFS: Double, seed: UInt64) -> [Float] {
    let amplitude = pow(10, dBFS / 20) * 3.0.squareRoot()
    var state = seed
    return (0..<count).map { _ in
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float((Double(z >> 11) / Double(1 << 53) * 2 - 1) * amplitude)
    }
}

/// A take whose microphone records `samples` (48 kHz, mono) from `base`, padded with silence to whole blocks of 10 ms.
private func take(in dir: URL, name: String, recording samples: [Float]) async throws -> LoadedProject {
    let blocks = (samples.count + 479) / 480
    let padded = samples + Array(repeating: 0, count: blocks * 480 - samples.count)
    let seconds = Double(blocks) / 100
    let transform: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer = { block, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample)
        let values = Array(padded[(block * frames)..<min((block + 1) * frames, padded.count)])
            + Array(repeating: 0, count: max(0, (block + 1) * frames - padded.count))
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "recorded block: \(status)")
        return sample
    }
    return try await voiceTake(in: dir, name: name, seconds: seconds, mic: [AudioSegmentSpec(start: base, seconds: seconds, transform: transform)])
}

/// The frames of the clean file at `url`, which is mono Float32 at 48 kHz.
private func cleanFrames(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
    var frames: [Float] = []
    // A read gives at most some frames of its own: read until the end.
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        frames += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return frames
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))).squareRoot()
}

private func decibels(_ value: Double) -> Double { 20 * log10(max(value, 1e-12)) }

/// The lag, in frames from −`range` to `range`, at which `signal` best matches `reference` (`signal[i + lag]` against
/// `reference[i]`), over the frames `over` of `reference`: every 8th lag over every 16th frame, then each lag next to
/// the best of those over every other frame.
private func bestLag(of signal: [Float], against reference: [Float], over: Range<Int>, range: Int) -> Int {
    func correlation(_ lag: Int, step: Int) -> Double {
        signal.withUnsafeBufferPointer { signal in
            reference.withUnsafeBufferPointer { reference in
                var sum = 0.0
                for i in stride(from: max(over.lowerBound, -lag), to: min(over.upperBound, signal.count - lag), by: step) {
                    sum += Double(reference[i]) * Double(signal[i + lag])
                }
                return sum
            }
        }
    }
    let coarse = stride(from: -range, through: range, by: 8).map { ($0, correlation($0, step: 16)) }.max { $0.1 < $1.1 }?.0 ?? 0
    return ((coarse - 8)...(coarse + 8)).map { ($0, correlation($0, step: 2)) }.max { $0.1 < $1.1 }?.0 ?? coarse
}

/// The unit takes the high-quality voice model, all wet: `SoundToIsolate` reads back 0, `WetDryMixPercent` 100.
@Test(.enabled(if: SoundIsolation.isAvailable))
func parameterTakesHighQualityVoice() throws {
    let parameters = try #require(SoundIsolation.configuredParameters())
    #expect(parameters.soundToIsolate == 0)
    #expect(parameters.wetDryMixPercent == 100)
}

/// Speech with white noise at −30 dBFS: the clean file holds exactly the span's frames, the voice in it is where it is
/// in the dry sound (the unit's latency made up for, within 1 ms), and the noise where nobody speaks drops by at least
/// 10 dB.
@Test(.enabled(if: SoundIsolation.isAvailable), .timeLimit(.minutes(5)))
func cleanKeepsTheLengthAndTheTiming() async throws {
    guard let voice = try await speech("Hola, esta es una prueba de la limpieza del ruido de la voz.", language: "es-MX") else { return }
    try await withTemporaryDirectory { dir in
        // 1 s of noise alone, the speech over the noise, 1 s of noise alone.
        let lead = 48_000, length = lead + voice.count + 48_000
        var spoken = Array(repeating: Float(0), count: lead) + voice
        spoken += Array(repeating: 0, count: length - spoken.count)
        let noise = whiteNoise(length, dBFS: -30, seed: 7)
        let project = try await take(in: dir, name: "speech", recording: zip(spoken, noise).map(+))
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let span = try #require(audio.spans.first)
        #expect(span.frames.lowerBound == 0)
        let url = dir.appending(path: "clean.caf")
        let reported = Mutex<[Double]>([])
        try await SoundIsolation.clean(audio, span: span, to: url) { fraction in reported.withLock { $0.append(fraction) } }
        let clean = try cleanFrames(url)
        #expect(clean.count == span.frames.count)
        let progress = reported.withLock { $0 }
        #expect(progress.last == 1 && zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
        // Where the voice is.
        let lag = bestLag(of: clean, against: spoken, over: lead..<(lead + voice.count), range: 4_800)
        #expect(abs(lag) <= 48, "the clean voice is \(lag) frames off the dry one")
        #expect(decibels(rms(clean[lead..<(lead + voice.count)])) > -40)
        // The noise alone, away from the voice's edges.
        let before = 4_800..<(lead - 9_600), after = (lead + voice.count + 9_600)..<(length - 4_800)
        let dry = zip(spoken, noise).map(+)
        for quiet in [before, after] {
            let drop = decibels(rms(dry[quiet])) - decibels(rms(clean[quiet]))
            #expect(drop >= 10, "the noise only drops \(drop) dB over \(quiet)")
        }
    }
}

/// A take whose microphone records `samples` (48 kHz) as `channels` interleaved channels, the same on all of them.
private func takeOnAllChannels(in dir: URL, name: String, recording samples: [Float], channels: Int) async throws -> LoadedProject {
    let blocks = (samples.count + 479) / 480
    let padded = samples + Array(repeating: 0, count: blocks * 480 - samples.count)
    let seconds = Double(blocks) / 100
    let transform: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer = { block, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample)
        var values = [Float](repeating: 0, count: frames * channels)
        for n in 0..<frames {
            let at = block * frames + n
            for c in 0..<channels { values[n * channels + c] = at < padded.count ? padded[at] : 0 }
        }
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "recorded block: \(status)")
        return sample
    }
    return try await voiceTake(
        in: dir, name: name, seconds: seconds,
        mic: [AudioSegmentSpec(start: base, seconds: seconds, channels: channels, transform: transform)])
}

/// A microphone with the same loud voice on every channel (L = R, as a common stereo USB microphone records): the clean
/// voice is at the level of one channel of the dry sound (within 1 dB), not the sum of the channels, and nothing in it
/// reaches full scale.
@Test(.enabled(if: SoundIsolation.isAvailable), .timeLimit(.minutes(5)), arguments: [(2, Float(0.7)), (3, Float(0.3))])
func cleanOfSeveralChannelsKeepsOneChannelsLevel(recorded: Int, peaking: Float) async throws {
    guard var voice = try await speech("Hola, esta es una prueba de la limpieza del ruido de la voz.", language: "es-MX") else { return }
    // Loud enough that the sum of two channels would be past full scale (a third channel is mixed into the two by the
    // timeline, so it gets a lower peak: what the timeline does is not what is under test).
    let peak = voice.reduce(0) { max($0, abs($1)) }
    voice = voice.map { $0 / peak * peaking }
    try await withTemporaryDirectory { dir in
        let lead = 24_000, length = lead + voice.count + 24_000
        let spoken = Array(repeating: Float(0), count: lead) + voice + Array(repeating: 0, count: length - lead - voice.count)
        let project = try await takeOnAllChannels(in: dir, name: "wide-\(recorded)", recording: spoken, channels: recorded)
        // As a voice job loads it: with the channels the track needs (a 3-channel one is mixed down to stereo).
        let audio = try await TrackAudio.load(project, track: micID)
        let channels = audio.channels
        #expect(channels == 2)
        let span = try #require(audio.spans.first)
        let url = dir.appending(path: "clean.caf")
        try await SoundIsolation.clean(audio, span: span, to: url) { _ in }
        let clean = try cleanFrames(url)
        #expect(clean.count == span.frames.count)
        // The dry sound, read as the mix reads it, one channel of it.
        var dry: [Float] = []
        audio.makeReader().read(span.frames, into: &dry)
        let first = (0..<span.frames.count).map { dry[$0 * channels] }
        let voiced = lead..<(lead + voice.count)
        let difference = decibels(rms(clean[voiced])) - decibels(rms(first[voiced]))
        #expect(abs(difference) <= 1, "the clean voice is \(difference) dB from one channel of the dry sound")
        #expect(!clean.contains { abs($0) >= 1 })
    }
}

/// A span in the middle of the timeline: its clean file starts at the span's first frame, not at frame 0.
@Test(.enabled(if: SoundIsolation.isAvailable))
func cleanStartsAtTheSpan() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "late", seconds: 3, mic: [
            AudioSegmentSpec(start: voiceAt(0.5), seconds: 1),
            AudioSegmentSpec(start: voiceAt(2), seconds: 0.5, amplitude: 0),
        ])
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        #expect(audio.spans.count == 2 && audio.spans[0].frames.lowerBound == 24_000)
        for (k, span) in audio.spans.enumerated() {
            let url = dir.appending(path: "clean-\(k).caf")
            try await SoundIsolation.clean(audio, span: span, to: url) { _ in }
            let clean = try cleanFrames(url)
            #expect(clean.count == span.frames.count)
            // A silent segment stays silent.
            if k == 1 { #expect(decibels(rms(clean[...])) < -80) }
        }
    }
}

/// Cancelled, cleaning stops with `CancellationError`.
@Test(.enabled(if: SoundIsolation.isAvailable))
func cancelledCleanThrows() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cancel", seconds: 20, mic: [AudioSegmentSpec(start: base, seconds: 20, transform: voiceNoise)])
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let span = try #require(audio.spans.first)
        let started = AsyncStream<Void>.makeStream()
        let url = dir.appending(path: "clean.caf")
        let task = Task {
            try await SoundIsolation.clean(audio, span: span, to: url) { _ in started.continuation.yield() }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// 60 s of microphone are cleaned in under 12 s (five times real time); the figure goes to docs/performance.md.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && SoundIsolation.isAvailable))
func cleanupIsFiveTimesRealTime() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "bench", seconds: 60, mic: [AudioSegmentSpec(start: base, seconds: 60, transform: voiceNoise)])
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let span = try #require(audio.spans.first)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await SoundIsolation.clean(audio, span: span, to: dir.appending(path: "clean.caf")) { _ in }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("soundIsolation-2 of 60 s of microphone: \(seconds) s (\(60 / seconds) × real time)")
        #expect(seconds < 12)
    }
}
