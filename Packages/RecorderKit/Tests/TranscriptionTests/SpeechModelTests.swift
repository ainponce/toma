// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
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

/// The words of a transcript as they are said: lowercase letters.
private func said(_ transcript: Transcript) -> [String] {
    transcript.takes.flatMap(\.words).map { $0.text.lowercased().filter(\.isLetter) }
}

/// The real model hears what the system's voice says, in order, where it is said on the take's timeline.
@Test(.enabled { await modelIsInstalled.value })
func realModelTranscribesSynthesizedSpeech() async throws {
    guard #available(macOS 26, *) else { return }
    let voice = try await speech("Hola, esto es una prueba de Toma.")
    try await withTemporaryDirectory { dir in
        // The voice half a second into a segment that starts 1 s into the take.
        let project = try await spokenTake(in: dir, voice, segmentStart: 1, offset: 0.5, seconds: 6)
        let spoken = takeTime(1.5)..<takeTime(1.5 + Double(voice.count) / 48_000)
        let progress = Mutex<[Double]>([])
        let transcript = try await Transcriber.transcribe(project, language: "es-MX", engine: SpeechTranscriberEngine()) { value in
            progress.withLock { $0.append(value) }
        }
        let words = said(transcript)
        let hola = try #require(words.firstIndex(of: "hola")), prueba = try #require(words.firstIndex(of: "prueba"))
        #expect(hola < prueba)
        let all = transcript.takes.flatMap(\.words)
        #expect(all.allSatisfy { $0.start >= spoken.lowerBound.adding(seconds: -0.3) && $0.end <= spoken.upperBound.adding(seconds: 0.3) })
        #expect(transcript.language == "es-MX" && transcript.engine == "speechTranscriber-1")
        let reported = progress.withLock { $0 }
        #expect(reported.last == 1 && zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

/// Cancelled while it hears, the real engine stops and gives nothing back.
@Test(.enabled { await modelIsInstalled.value }, .timeLimit(.minutes(1)))
func realModelStopsWhenCancelled() async throws {
    guard #available(macOS 26, *) else { return }
    let voice = try await speech(String(repeating: "Esto es una prueba larga de Toma, que se cancela a mitad. ", count: 6))
    try await withTemporaryDirectory { dir in
        let project = try await spokenTake(in: dir, voice, segmentStart: 0, offset: 0, seconds: Double(voice.count) / 48_000 + 0.5)
        let (started, start) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await Transcriber.transcribe(project, language: "es-MX", engine: SpeechTranscriberEngine()) { _ in start.yield() }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// The model of es-MX is installed; the engine transcribes en-US and es-MX; a language it does not know is unsupported.
@Test(.enabled { await modelIsInstalled.value })
func statusOfAnInstalledLanguage() async throws {
    #expect(await SpeechLanguages.status(of: "es-MX") == .installed)
    #expect(await SpeechLanguages.status(of: "es_MX") == .installed)
    #expect(await SpeechLanguages.status(of: "xx-YY") == .unsupported)
    let supported = await SpeechLanguages.supported()
    #expect(supported.contains("en-US") && supported.contains("es-MX") && supported == supported.sorted())
    #expect(await SpeechLanguages.installed().contains("es-MX"))
    let language = try #require(await SpeechLanguages.defaultLanguage())
    #expect(supported.contains(language))
}

/// Transcribing runs at 10 times real time or faster: a minute of speech in under 6 s.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .enabled { await modelIsInstalled.value })
func transcribesTenTimesRealTime() async throws {
    guard #available(macOS 26, *) else { return }
    let paragraph = """
        Esta es una grabación de prueba para medir la transcripción. Se habla de manera continua, con frases cortas \
        y largas, con números como veinticinco y cien, y con preguntas: ¿se entiende bien? Sí, se entiende. \
        Después se sigue hablando del editor, de los subtítulos, de los cortes y de la cámara.
        """
    var voice: [Float] = []
    while voice.count < 60 * 48_000 { voice += try await speech(paragraph) }
    voice = Array(voice.prefix(60 * 48_000))
    try await withTemporaryDirectory { dir in
        let project = try await spokenTake(in: dir, voice, segmentStart: 0, offset: 0, seconds: 60)
        let clock = ContinuousClock()
        var transcript: Transcript?
        let elapsed = try await clock.measure {
            transcript = try await Transcriber.transcribe(project, language: "es-MX", engine: SpeechTranscriberEngine()) { _ in }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("transcribesTenTimesRealTime: 60 s of es-MX in \(seconds) s (\(60 / seconds) × real time), \(said(try #require(transcript)).count) words")
        #expect(seconds < 6)
    }
}

/// A take whose microphone has one segment `seconds` long from `segmentStart` s into the take, silent but for `voice`
/// (mono, 48 kHz) from `offset` s into it.
private func spokenTake(in dir: URL, _ voice: [Float], segmentStart: Double, offset: Double, seconds: Double) async throws -> LoadedProject {
    let first = Int((offset * 48_000).rounded())
    let transform: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer = { block, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample)
        let values = (0..<frames).map { i -> Float in
            let n = block * frames + i - first
            return voice.indices.contains(n) ? voice[n] : 0
        }
        _ = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        return sample
    }
    return try await voiceTake(
        in: dir, name: "spoken", seconds: segmentStart + seconds,
        mic: [AudioSegmentSpec(start: takeTime(segmentStart), seconds: seconds, transform: transform)])
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
