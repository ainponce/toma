// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Transcription

// With Speech's own models, which these tests never download: they run on macOS 26 when the model of es-MX is on the
// Mac (the transcription's, or the dictation one) and the system has a voice to speak es-MX with, which
// `AVSpeechSynthesizer` writes to buffers here (no network).

/// Whether the transcription's model of es-MX is on this Mac and there is an es-MX voice: asked once for all the tests.
private let modelIsInstalled = Task<Bool, Never> {
    guard SpeechLanguages.isAvailable(), AVSpeechSynthesisVoice(language: "es-MX") != nil else { return false }
    return await SpeechLanguages.installed().contains("es-MX")
}

/// Whether the dictation model of es-MX is on this Mac and there is an es-MX voice.
private let dictationIsInstalled = Task<Bool, Never> {
    guard #available(macOS 26, *), SpeechLanguages.isAvailable(), AVSpeechSynthesisVoice(language: "es-MX") != nil else { return false }
    return await DictationLiveEngine.status(of: "es-MX") == .installed
}

@Test func availabilityBeforeMacOS26SaysSo() async {
    if #available(macOS 26, *) {
        #expect(LiveSpeech.engine(.dictation) is DictationLiveEngine)
        #expect(LiveSpeech.engine(.transcriber) is SpeechTranscriberLiveEngine)
        #expect(await LiveSpeech.availability(preferred: "es-MX") != .needsMacOS26)
        #expect(await LiveSpeech.availability(preferred: nil) != .needsMacOS26)
    } else {
        #expect(LiveSpeech.engine(.dictation) == nil && LiveSpeech.engine(.transcriber) == nil)
        #expect(await LiveSpeech.availability(preferred: "es-MX") == .needsMacOS26)
        #expect(await LiveSpeech.availability(preferred: nil) == .needsMacOS26)
    }
}

/// Decision 13 and the controller's ruling on T5, on models a test makes up: the transcription's language if one of its
/// models is installed, else the default language if one of its models is; dictation first; else the model that is
/// missing, the transcription's language first if "Download the Language" can get it.
@Test func availabilityChoosesTheLanguageThenTheEngine() async throws {
    guard #available(macOS 26, *) else { return }
    let (none, downloadable, installed) = (LanguageModelStatus.unsupported, LanguageModelStatus.downloadable, LanguageModelStatus.installed)
    func choice(
        _ preferred: String?, default fallback: String? = "en-US", _ models: [String: (LanguageModelStatus, LanguageModelStatus)],
        available: Bool = true
    ) async -> LiveSpeechAvailability {
        await LiveSpeech.availability(preferred: preferred, models: fakeModels(models, default: fallback, available: available))
    }
    // The transcription's language, dictation first.
    #expect(await choice("es-MX", ["es-MX": (installed, installed)]) == .available(language: "es-MX", engine: .dictation))
    #expect(await choice("es-MX", ["es-MX": (installed, none)]) == .available(language: "es-MX", engine: .dictation))
    #expect(await choice("es-MX", ["es-MX": (downloadable, installed)]) == .available(language: "es-MX", engine: .transcriber))
    #expect(await choice("es_MX", ["es-MX": (installed, installed)]) == .available(language: "es-MX", engine: .dictation))
    // Its language before the engine: the transcription's model of es-MX wins over the dictation one of en-US.
    #expect(await choice("es-MX", ["es-MX": (none, installed), "en-US": (installed, installed)])
        == .available(language: "es-MX", engine: .transcriber))
    // Else the default language, dictation first.
    #expect(await choice("es-MX", ["es-MX": (downloadable, downloadable), "en-US": (installed, installed)])
        == .available(language: "en-US", engine: .dictation))
    #expect(await choice("xx-YY", ["en-US": (none, installed)]) == .available(language: "en-US", engine: .transcriber))
    #expect(await choice(nil, ["en-US": (installed, downloadable)]) == .available(language: "en-US", engine: .dictation))
    // Else what is missing: the transcription's language if its model can be downloaded, else the default's.
    #expect(await choice("es-MX", ["es-MX": (downloadable, downloadable), "en-US": (none, downloadable)]) == .modelNotInstalled("es-MX"))
    #expect(await choice("es-MX", ["es-MX": (none, .downloading)]) == .modelNotInstalled("es-MX"))
    #expect(await choice("es-MX", ["es-MX": (downloadable, none), "en-US": (none, downloadable)]) == .modelNotInstalled("en-US"))
    #expect(await choice("xx-YY", ["en-US": (none, downloadable)]) == .modelNotInstalled("en-US"))
    #expect(await choice(nil, ["en-US": (none, .downloading)]) == .modelNotInstalled("en-US"))
    #expect(await choice("es-MX", default: nil, ["es-MX": (none, downloadable)]) == .modelNotInstalled("es-MX"))
    // Nothing the Mac transcribes; a Mac that cannot.
    #expect(await choice("xx-YY", default: nil, [:]) == .noLanguage)
    #expect(await choice(nil, default: nil, [:]) == .noLanguage)
    #expect(await choice("es-MX", ["es-MX": (installed, installed)], available: false) == .notOnThisMac)

    // With the transcription's language there, the default one is never asked for.
    let asked = Mutex(0)
    let models = fakeModels(["es-MX": (installed, none)], default: "en-US") { asked.withLock { $0 += 1 } }
    #expect(await LiveSpeech.availability(preferred: "es-MX", models: models) == .available(language: "es-MX", engine: .dictation))
    #expect(asked.withLock { $0 } == 0)
}

/// On this Mac, with the model of es-MX: the transcription's language, in BCP 47, with dictation if its model is here.
@Test(.enabled { await modelIsInstalled.value })
func availabilityOfAnInstalledLanguage() async throws {
    let engine: LiveSpeechEngineKind = await dictationIsInstalled.value ? .dictation : .transcriber
    #expect(await LiveSpeech.availability(preferred: "es-MX") == .available(language: "es-MX", engine: engine))
    #expect(await LiveSpeech.availability(preferred: "es_MX") == .available(language: "es-MX", engine: engine))
}

/// A language the Mac does not transcribe: the results end with the engine's error, and nothing is downloaded.
@Test(.enabled(if: SpeechLanguages.isAvailable()), .timeLimit(.minutes(1)), arguments: LiveSpeechEngineKind.allCases)
func liveEngineRefusesALanguageItDoesNotKnow(_ kind: LiveSpeechEngineKind) async throws {
    let engine = try #require(LiveSpeech.engine(kind))
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    input.yield(LiveAudioChunk(samples: [Float](repeating: 0, count: 4_800)))
    await #expect(throws: TranscriptionError.self) {
        for try await _ in engine.results(of: audio, language: "xx-YY") {}
    }
    input.finish()
}

@Test(.enabled { await dictationIsInstalled.value }, .timeLimit(.minutes(2)))
func dictationHearsSyntheticSpanish() async throws {
    try await hearsSyntheticSpanish(try #require(LiveSpeech.engine(.dictation)))
}

@Test(.enabled { await modelIsInstalled.value }, .timeLimit(.minutes(2)))
func liveEngineHearsSyntheticSpanish() async throws {
    try await hearsSyntheticSpanish(try #require(LiveSpeech.engine(.transcriber)))
}

/// `engine` hears the system's voice say a sentence, given 100 ms at a time in real time: a final result with its
/// words, and a volatile one before it.
private func hearsSyntheticSpanish(_ engine: any LiveSpeechEngine) async throws {
    let voice = try await speech("Hola, esto es una prueba del teleprompter.")
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    let results = engine.results(of: audio, language: "es-MX")
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

@Test(.enabled { await dictationIsInstalled.value }, .timeLimit(.minutes(1)))
func dictationStopsWhenCancelled() async throws {
    try await stopsWhenCancelled(try #require(LiveSpeech.engine(.dictation)))
}

@Test(.enabled { await modelIsInstalled.value }, .timeLimit(.minutes(1)))
func liveEngineStopsWhenCancelled() async throws {
    try await stopsWhenCancelled(try #require(LiveSpeech.engine(.transcriber)))
}

/// Cancelled while it hears audio that never ends (a microphone still open), `engine` stops: its results end.
private func stopsWhenCancelled(_ engine: any LiveSpeechEngine) async throws {
    let voice = try await speech("Esto es una prueba larga que se cancela a mitad.")
    let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
    let (first, heardOne) = AsyncStream<Void>.makeStream()
    let listener = Task {
        var count = 0
        for try await _ in engine.results(of: audio, language: "es-MX") {
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

/// The two live engines measured one after the other, so the process's CPU is one engine's.
@Suite(.serialized) struct LiveSpeechBench {
    /// Dictation follows within the goal (design §15): under 0.6 s at the median, under 15 % of a core.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .enabled { await dictationIsInstalled.value })
    func liveLatencyAndCPU() async throws {
        let (median, cpu) = try await latencyAndCPU(try #require(LiveSpeech.engine(.dictation)), name: "dictation")
        #expect(median < 0.6)
        #expect(cpu < 0.15)
    }

    /// The transcription's model, what follows without the dictation one: its results come about once a second (0.96 s
    /// apart on macOS 26.6), 0.86 s at the median (docs/performance.md, T5).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .enabled { await modelIsInstalled.value })
    func transcriberLatencyAndCPU() async throws {
        let (median, cpu) = try await latencyAndCPU(try #require(LiveSpeech.engine(.transcriber)), name: "transcriber")
        withKnownIssue("SpeechTranscriber in live mode reports about once a second", isIntermittent: true) {
            #expect(median < 0.6)
        }
        #expect(cpu < 0.15)
    }
}

/// From the last sample of a word fed to the feed to the first result that has it, and the process's CPU while it
/// listens (a fraction of a core), through the whole chain: 10 ms blocks to `LiveMicrophoneFeed`, its chunks to `engine`.
/// Ten words, each said on its own with 400 ms of silence after it. Gives the median latency in seconds.
private func latencyAndCPU(_ engine: any LiveSpeechEngine, name: String) async throws -> (median: Double, cpu: Double) {
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
    let results = engine.results(of: feed.chunks, language: "es-MX")
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
        latencyAndCPU (\(name)): \(latencies.count) of \(words.count) words heard; latency \
        min \(latencies.first ?? .nan) s, median \(median) s, max \(latencies.last ?? .nan) s \
        (\(latencies.map { String(format: "%.3f", $0) }.joined(separator: ", "))); \
        process CPU \(cpu) s over \(wallSeconds) s = \(100 * cpu / wallSeconds) % of a core; results: \(texts.count)
        """)
    #expect(latencies.count >= words.count / 2)
    return (median, cpu / wallSeconds)
}

/// Models made up by a test: for each language (BCP 47), the status of its dictation model and of its transcription
/// one; any other is unsupported. `askedForDefault` hears each time the default language is asked for.
private func fakeModels(
    _ models: [String: (LanguageModelStatus, LanguageModelStatus)], default fallback: String?, available: Bool = true,
    askedForDefault: @escaping @Sendable () -> Void = {}
) -> LiveSpeechModels {
    LiveSpeechModels(
        isAvailable: { available },
        defaultLanguage: {
            askedForDefault()
            return fallback
        },
        status: { language, engine in
            guard let (dictation, transcriber) = models[language] else { return .unsupported }
            return engine == .dictation ? dictation : transcriber
        })
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
    try await Voice.shared.speech(text)
}

/// The system's es-MX voice for these tests: one synthesizer for the whole run, never released, one text at a time,
/// each said once. Synthesizers made and dropped by tests in parallel crashed the process (in TextToSpeech's thread,
/// and as corrupted memory found later).
private actor Voice {
    static let shared = Voice()

    private let synthesizer = AVSpeechSynthesizer()
    private var said: [String: Task<[Float], any Error>] = [:]
    /// The last text asked for: the next one waits for it.
    private var last: Task<Void, Never>?

    func speech(_ text: String) async throws -> [Float] {
        if let task = said[text] { return try await task.value }
        let before = last
        let task = Task { () async throws -> [Float] in
            await before?.value
            return try await write(text)
        }
        said[text] = task
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    private func write(_ text: String) async throws -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX")
        let heard = SynthesizedSpeech()
        let (samples, rate) = await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { buffer in heard.add(buffer, then: continuation) }
        }
        return try resampled(samples, from: rate)
    }
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
