// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Transcription

// With Speech's own model, which these tests never download: they run on macOS 26 when the model of es-MX is on the
// Mac and the system has a voice to speak es-MX with, which `AVSpeechSynthesizer` writes to buffers here (no network).

/// Whether the model of es-MX is on this Mac and there is an es-MX voice: asked once for all the tests.
private let modelIsInstalled = Task<Bool, Never> {
    guard SpeechLanguages.isAvailable(), AVSpeechSynthesisVoice(language: "es-MX") != nil else { return false }
    return await SpeechLanguages.installed().contains("es-MX")
}

@Test func availabilityBeforeMacOS26SaysSo() async {
    if #available(macOS 26, *) {
        #expect(LiveSpeech.engine() != nil)
        #expect(await LiveSpeech.availability(preferred: "es-MX") != .needsMacOS26)
        #expect(await LiveSpeech.availability(preferred: nil) != .needsMacOS26)
    } else {
        #expect(LiveSpeech.engine() == nil)
        #expect(await LiveSpeech.availability(preferred: "es-MX") == .needsMacOS26)
        #expect(await LiveSpeech.availability(preferred: nil) == .needsMacOS26)
    }
}

/// Decision 13: the transcription's language if its model is installed, else the default language if its model is;
/// else the one whose model is missing, the transcription's first if the Mac transcribes it.
@Test func availabilityPrefersTheTranscriptionsLanguageThenTheDefault() {
    let choose = LiveSpeech.availability(preferred:fallback:)
    #expect(choose(("es-MX", .installed), ("en-US", .installed)) == .available("es-MX"))
    #expect(choose(("es-MX", .downloadable), ("en-US", .installed)) == .available("en-US"))
    #expect(choose(("xx-YY", .unsupported), ("en-US", .installed)) == .available("en-US"))
    #expect(choose(nil, ("en-US", .installed)) == .available("en-US"))
    #expect(choose(("es-MX", .downloadable), ("en-US", .downloadable)) == .modelNotInstalled("es-MX"))
    #expect(choose(("es-MX", .downloading), ("en-US", .downloadable)) == .modelNotInstalled("es-MX"))
    #expect(choose(("xx-YY", .unsupported), ("en-US", .downloadable)) == .modelNotInstalled("en-US"))
    #expect(choose(nil, ("en-US", .downloading)) == .modelNotInstalled("en-US"))
    #expect(choose(("es-MX", .downloadable), nil) == .modelNotInstalled("es-MX"))
    #expect(choose(("xx-YY", .unsupported), nil) == .noLanguage)
    #expect(choose(nil, nil) == .noLanguage)
}

/// On this Mac, with the model of es-MX: the transcription's language, in BCP 47; an unknown one falls to the default.
@Test(.enabled { await modelIsInstalled.value })
func availabilityOfAnInstalledLanguage() async throws {
    #expect(await LiveSpeech.availability(preferred: "es-MX") == .available("es-MX"))
    #expect(await LiveSpeech.availability(preferred: "es_MX") == .available("es-MX"))
    let fallback = try #require(await SpeechLanguages.defaultLanguage())
    let expected: LiveSpeechAvailability =
        await SpeechLanguages.status(of: fallback) == .installed ? .available(fallback) : .modelNotInstalled(fallback)
    #expect(await LiveSpeech.availability(preferred: "xx-YY") == expected)
    #expect(await LiveSpeech.availability(preferred: nil) == expected)
}

/// A language the Mac does not transcribe: the results end with the engine's error, and nothing is downloaded.
@Test(.enabled(if: SpeechLanguages.isAvailable()), .timeLimit(.minutes(1)))
func liveEngineRefusesALanguageItDoesNotKnow() async throws {
    guard #available(macOS 26, *) else { return }
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    input.yield(LiveAudioChunk(samples: [Float](repeating: 0, count: 4_800)))
    await #expect(throws: TranscriptionError.self) {
        for try await _ in SpeechTranscriberLiveEngine().results(of: audio, language: "xx-YY") {}
    }
    input.finish()
}

@Test(.enabled { await modelIsInstalled.value }, .timeLimit(.minutes(2)))
func liveEngineHearsSyntheticSpanish() async throws {
    guard #available(macOS 26, *) else { return }
    let voice = try await speech("Hola, esto es una prueba del teleprompter.")
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    let results = SpeechTranscriberLiveEngine().results(of: audio, language: "es-MX")
    // The voice and a second of silence, 100 ms at a time, in real time; then the audio ends.
    let feeder = Task {
        let padded = voice + [Float](repeating: 0, count: 48_000)
        let clock = ContinuousClock()
        let start = clock.now
        for (index, offset) in stride(from: 0, to: padded.count, by: 4_800).enumerated() {
            try await clock.sleep(until: start + .milliseconds(100 * index))
            input.yield(LiveAudioChunk(samples: Array(padded[offset..<min(offset + 4_800, padded.count)])))
        }
        input.finish()
    }
    var heard: [LiveSpeechResult] = []
    for try await result in results { heard.append(result) }
    try await feeder.value
    let final = normalized(heard.filter(\.isFinal).map(\.text).joined(separator: " "))
    #expect(final.contains("prueba") && final.contains("teleprompter"), "\(heard)")
    let firstFinal = try #require(heard.firstIndex { $0.isFinal })
    #expect(heard[..<firstFinal].contains { !$0.isFinal }, "no volatile result before the first final one: \(heard)")
}

/// Cancelled while it hears audio that never ends (a microphone still open), the engine stops: its results end.
@Test(.enabled { await modelIsInstalled.value }, .timeLimit(.minutes(1)))
func liveEngineStopsWhenCancelled() async throws {
    guard #available(macOS 26, *) else { return }
    let voice = try await speech("Esto es una prueba larga que se cancela a mitad.")
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    let (first, heardOne) = AsyncStream<Void>.makeStream()
    let listener = Task {
        var count = 0
        for try await _ in SpeechTranscriberLiveEngine().results(of: audio, language: "es-MX") {
            count += 1
            heardOne.yield()
        }
        return count
    }
    let feeder = Task {
        var offset = 0
        while !Task.isCancelled {
            let end = offset + 4_800
            let chunk = end <= voice.count ? Array(voice[offset..<end]) : [Float](repeating: 0, count: 4_800)
            input.yield(LiveAudioChunk(samples: chunk))
            offset = end
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    for await _ in first { break }
    listener.cancel()
    // It ends, however it ends (cancelled), with the audio still coming.
    _ = try? await listener.value
    feeder.cancel()
    input.finish()
}

/// From the last sample of a word fed to the feed to the first result that has it, and the process's CPU while it
/// listens, through the whole chain: 10 ms blocks to `LiveMicrophoneFeed`, its chunks to `SpeechTranscriberLiveEngine`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .enabled { await modelIsInstalled.value })
func liveLatencyAndCPU() async throws {
    guard #available(macOS 26, *) else { return }
    let words = ["hola", "manzana", "ventana", "guitarra", "montaña", "biblioteca", "elefante", "chocolate", "mariposa", "teleprompter"]
    // Each word said on its own, 400 ms of silence after it: where each one ends is known.
    var voice = [Float](repeating: 0, count: 24_000)
    var ends: [Int] = []
    for word in words {
        let said = try await speech(word)
        let last = said.lastIndex { abs($0) > 0.01 } ?? said.count - 1
        ends.append(voice.count + last)
        voice += said + [Float](repeating: 0, count: 19_200)
    }
    voice += [Float](repeating: 0, count: 48_000)

    let feed = LiveMicrophoneFeed()
    let results = SpeechTranscriberLiveEngine().results(of: feed.chunks, language: "es-MX")
    let clock = ContinuousClock()
    let fed = Mutex<[ContinuousClock.Instant?]>(Array(repeating: nil, count: words.count))
    let wanted = words.map(normalized)
    let cpuBefore = processCPUSeconds()
    let start = clock.now
    let feeder = Task {
        for (index, offset) in stride(from: 0, to: voice.count, by: 480).enumerated() {
            try await clock.sleep(until: start + .milliseconds(10 * index))
            let range = offset..<min(offset + 480, voice.count)
            feed.append(monoSample(Array(voice[range]), firstFrame: offset))
            let now = clock.now
            fed.withLock { fed in
                for (word, end) in ends.enumerated() where range.contains(end) { fed[word] = now }
            }
        }
        feed.finish()
    }
    var heardAt = [ContinuousClock.Instant?](repeating: nil, count: words.count)
    var texts: [String] = []
    for try await result in results {
        let now = clock.now
        let text = normalized(result.text)
        texts.append(result.text)
        for (word, form) in wanted.enumerated() where heardAt[word] == nil && text.contains(form) { heardAt[word] = now }
    }
    try await feeder.value
    let wall = clock.now - start
    let cpu = processCPUSeconds() - cpuBefore
    let fedAt = fed.withLock { $0 }
    let latencies = zip(fedAt, heardAt).compactMap { fed, heard -> Double? in
        guard let fed, let heard else { return nil }
        return Double((heard - fed).components.attoseconds) / 1e18 + Double((heard - fed).components.seconds)
    }.sorted()
    let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
    let median = latencies.isEmpty ? .infinity : latencies[latencies.count / 2]
    print("""
        liveLatencyAndCPU: \(latencies.count) of \(words.count) words heard; latency \
        min \(latencies.first ?? .nan) s, median \(median) s, max \(latencies.last ?? .nan) s \
        (\(latencies.map { String(format: "%.3f", $0) }.joined(separator: ", "))); \
        process CPU \(cpu) s over \(wallSeconds) s = \(100 * cpu / wallSeconds) % of a core; results: \(texts.count)
        """)
    #expect(latencies.count >= words.count / 2)
    // The goal (design §15). `SpeechTranscriber` with fast results gives its results about once a second (0.96 s apart
    // on macOS 26.6): a word heard waits up to that long, 0.86 s at the median (docs/performance.md, T5).
    withKnownIssue("SpeechTranscriber in live mode reports about once a second", isIntermittent: true) {
        #expect(median < 0.6)
    }
    #expect(cpu / wallSeconds < 0.15)
}

/// Lowercase letters and digits without accents: how the teleprompter compares words.
private func normalized(_ text: String) -> String {
    text.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
}

/// The user and system CPU time of this process so far, in seconds.
private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// `samples` as a block of mono Float32 at 48 kHz, `firstFrame` frames into the take: what a microphone delivers.
private func monoSample(_ samples: [Float], firstFrame: Int) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format)
    let byteCount = samples.count * 4
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block)
    _ = samples.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
    }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!, sampleCount: samples.count,
        presentationTimeStamp: CMTime(value: CMTimeValue(firstFrame), timescale: 48_000), packetDescriptions: nil,
        sampleBufferOut: &sample)
    return sample!
}

/// What the system's es-MX voice says of `text`, in mono Float32 at 48 kHz.
private func speech(_ text: String) async throws -> [Float] {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "es-MX")
    let heard = SynthesizedSpeech()
    let (samples, rate) = await withCheckedContinuation { continuation in
        synthesizer.write(utterance) { buffer in heard.add(buffer, then: continuation) }
    }
    withExtendedLifetime(synthesizer) {}
    return try resampled(samples, from: rate)
}

/// The buffers the synthesizer writes, as samples of their first channel, until it writes an empty one.
private final class SynthesizedSpeech: Sendable {
    private let state = Mutex<(samples: [Float], rate: Double, done: Bool)>(([], 0, false))

    func add(_ buffer: AVAudioBuffer, then continuation: CheckedContinuation<([Float], Double), Never>) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let count = Int(pcm.frameLength)
        var samples: [Float] = []
        if let data = pcm.floatChannelData {
            samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        } else if let data = pcm.int16ChannelData {
            samples = UnsafeBufferPointer(start: data[0], count: count).map { Float($0) / 32_768 }
        }
        let rate = pcm.format.sampleRate
        let finished = state.withLock { state -> ([Float], Double)? in
            guard !state.done else { return nil }
            guard count > 0 else {
                state.done = true
                return (state.samples, state.rate)
            }
            state.samples += samples
            state.rate = rate
            return nil
        }
        if let finished { continuation.resume(returning: finished) }
    }
}

/// `samples` at `rate`, mono, at 48 kHz.
private func resampled(_ samples: [Float], from rate: Double) throws -> [Float] {
    let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let converter = try #require(AVAudioConverter(from: source, to: target))
    let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)))
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    let output = try #require(AVAudioPCMBuffer(
        pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * 48_000 / rate) + 4_096))
    var given = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, status in
        guard !given else {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return input
    }
    #expect(status != .error, "\(String(describing: error))")
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}
