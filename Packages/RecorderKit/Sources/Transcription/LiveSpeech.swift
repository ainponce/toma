// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// What a live engine heard so far of a stretch of speech: `isFinal` false while it may still change (a volatile result,
/// which the next result replaces), true once it is settled.
public struct LiveSpeechResult: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// What hears the microphone as it records: `SpeechTranscriberLiveEngine` from macOS 26, or a test's.
public protocol LiveSpeechEngine: Sendable {
    /// What is said in `audio` (mono Float32 at 48 kHz, as it is heard), in `language` (BCP 47), as it is heard:
    /// volatile results as they come and the final ones once settled. Ends once `audio` has ended and everything is
    /// final; ending the iteration (cancelling its task) stops the engine. Never downloads a model.
    /// - Throws: `TranscriptionError` (`.notOnThisMac`, `.modelNotInstalled`, `.engine`).
    func results(of audio: AsyncStream<LiveAudioChunk>, language: String) -> AsyncThrowingStream<LiveSpeechResult, any Error>
}

/// Whether Follow the Voice can follow, and in which language, or why not.
public enum LiveSpeechAvailability: Equatable, Sendable {
    /// In this language, BCP 47.
    case available(String)
    /// Live transcription needs macOS 26 (`SpeechTranscriber`).
    case needsMacOS26
    /// This Mac cannot transcribe (`SpeechTranscriber.isAvailable` is false).
    case notOnThisMac
    /// The model of this language (BCP 47) is not on this Mac.
    case modelNotInstalled(String)
    /// No language the Mac transcribes.
    case noLanguage
}

/// Follow the Voice's engine and its language (plan 3d, decision 13).
public enum LiveSpeech {
    /// The language to follow in: `preferred` (the transcription's, `TranscriptionPreferences`) if its model is on the
    /// Mac; else `SpeechLanguages.defaultLanguage()` if its model is. Else the model that is missing: `preferred`'s
    /// if the Mac transcribes it, else the default's; `.noLanguage` without either. Asks only what is installed: never
    /// downloads, never asks for a permission.
    public static func availability(preferred: String?) async -> LiveSpeechAvailability {
        guard #available(macOS 26, *) else { return .needsMacOS26 }
        guard SpeechLanguages.isAvailable() else { return .notOnThisMac }
        var chosen: (String, LanguageModelStatus)?
        if let preferred {
            chosen = (SpeechLanguages.bcp47(preferred), await SpeechLanguages.status(of: preferred))
            if chosen?.1 == .installed { return availability(preferred: chosen, fallback: nil) }
        }
        var fallback: (String, LanguageModelStatus)?
        if let language = await SpeechLanguages.defaultLanguage() {
            fallback = (language, await SpeechLanguages.status(of: language))
        }
        return availability(preferred: chosen, fallback: fallback)
    }

    /// Decision 13 on what the Mac says of the preferred language and of the default one (BCP 47 and their status).
    static func availability(
        preferred: (String, LanguageModelStatus)?, fallback: (String, LanguageModelStatus)?
    ) -> LiveSpeechAvailability {
        if let preferred, preferred.1 == .installed { return .available(preferred.0) }
        if let fallback, fallback.1 == .installed { return .available(fallback.0) }
        if let preferred, preferred.1 != .unsupported { return .modelNotInstalled(preferred.0) }
        if let fallback { return .modelNotInstalled(fallback.0) }
        return .noLanguage
    }

    /// The engine of this Mac; `nil` before macOS 26.
    public static func engine() -> (any LiveSpeechEngine)? {
        if #available(macOS 26, *) { SpeechTranscriberLiveEngine() } else { nil }
    }
}

/// `SpeechTranscriber` in live mode (plan 3d, T5): volatile and fast results, no attributes, a `SpeechAnalyzer` fed
/// each chunk as it comes, converted to the analyzer's best format with `AVAudioConverter`. The model must be on the
/// Mac: it never downloads one. Ending the iteration (cancelling its task) ends the analyzer's input and stops it
/// (`cancelAndFinishNow`).
@available(macOS 26, *)
public struct SpeechTranscriberLiveEngine: LiveSpeechEngine {
    public init() {}

    public func results(of audio: AsyncStream<LiveAudioChunk>, language: String) -> AsyncThrowingStream<LiveSpeechResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.hear(audio, language: language) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The transcriber of `locale` the live engine uses.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Hears `audio` until it ends (then every result is final) or the task is cancelled, giving each result to `heard`.
    private static func hear(
        _ audio: AsyncStream<LiveAudioChunk>, language: String, heard: @escaping @Sendable (LiveSpeechResult) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notOnThisMac }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TranscriptionError.engine("SpeechTranscriber does not transcribe \(language)")
        }
        guard await SpeechLanguages.isInstalled(locale) else { throw TranscriptionError.modelNotInstalled(language) }
        let transcriber = module(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.engine("SpeechAnalyzer has no audio format for \(language)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (input, inputs) = AsyncStream<AnalyzerInput>.makeStream()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // The results end when the analyzer finishes, or when this task is cancelled (the group's child is).
            group.addTask {
                for try await result in transcriber.results {
                    heard(LiveSpeechResult(text: String(result.text.characters), isFinal: result.isFinal))
                }
            }
            // The audio, converted as it comes, until it ends or this task is cancelled (then `audio` ends too).
            group.addTask {
                defer { inputs.finish() }
                var converter = try LiveAnalyzerConverter(to: format)
                for await chunk in audio {
                    if let buffer = try converter.convert(chunk) { inputs.yield(AnalyzerInput(buffer: buffer)) }
                }
                if !Task.isCancelled, let tail = try converter.convert(nil) { inputs.yield(AnalyzerInput(buffer: tail)) }
            }
            do {
                try await withTaskCancellationHandler {
                    try await analyzer.prepareToAnalyze(in: format)
                    try await analyzer.start(inputSequence: input)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } onCancel: {
                    inputs.finish()
                    Task { await analyzer.cancelAndFinishNow() }
                }
                try Task.checkCancellation()
            } catch {
                inputs.finish()
                await analyzer.cancelAndFinishNow()
                // Leaving the group cancels its children and waits for them.
                throw Task.isCancelled ? CancellationError() : engineError(error, language: language)
            }
            do {
                try await group.waitForAll()
                try Task.checkCancellation()
            } catch {
                throw Task.isCancelled ? CancellationError() : engineError(error, language: language)
            }
        }
    }

    /// What the engine throws for `error`, thrown by the analyzer: the model missing, or the engine's failure.
    private static func engineError(_ error: any Error, language: String) -> any Error {
        if error is CancellationError || error is TranscriptionError { return error }
        if let speech = error as? SFSpeechError, speech.code == .noModel || speech.code == .assetLocaleNotAllocated {
            return TranscriptionError.modelNotInstalled(language)
        }
        return TranscriptionError.engine(String(describing: error))
    }
}

/// Mono Float32 at 48 kHz (`LiveAudioChunk`) to the analyzer's format, one chunk at a time, the resampler carried from
/// one to the next (`AnalyzerFeed`'s conversion, for chunks that come as they are heard).
@available(macOS 26, *)
private struct LiveAnalyzerConverter {
    private let converter: AVAudioConverter

    init(to format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: AnalyzerFeed.chunkFormat, to: format) else {
            throw TranscriptionError.engine("no converter to \(format)")
        }
        self.converter = converter
    }

    /// `chunk` in the analyzer's format; `nil` the end: what the converter still holds. `nil` when it gives nothing yet.
    mutating func convert(_ chunk: LiveAudioChunk?) throws -> AVAudioPCMBuffer? {
        var input: AVAudioPCMBuffer?
        if let chunk {
            guard !chunk.samples.isEmpty else { return nil }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
                  let data = buffer.floatChannelData
            else { throw TranscriptionError.engine("no buffer of \(chunk.samples.count) frames") }
            chunk.samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: $0.count) }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            input = buffer
        }
        // Room for the chunk and what the resampler held back of the one before.
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.engine("no buffer of \(capacity) frames")
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if let input, !given {
                given = true
                status.pointee = .haveData
                return input
            }
            status.pointee = input == nil ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            throw TranscriptionError.engine("AVAudioConverter: \(error.map(String.init(describing:)) ?? "error")")
        }
        return output.frameLength > 0 ? output : nil
    }
}
