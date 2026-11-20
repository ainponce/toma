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

/// What hears the microphone as it records: `DictationLiveEngine` or `SpeechTranscriberLiveEngine` from macOS 26
/// (`LiveSpeech.engine(_:)`), or a test's.
public protocol LiveSpeechEngine: Sendable {
    /// What is said in `audio` (mono Float32 at 48 kHz, as it is heard), in `language` (BCP 47), as it is heard:
    /// volatile results as they come and the final ones once settled. Ends once `audio` has ended and everything is
    /// final; ending the iteration (cancelling its task) stops the engine. Never downloads a model.
    /// - Throws: `TranscriptionError` (`.notOnThisMac`, `.modelNotInstalled`, `.engine`).
    func results(of audio: AsyncStream<LiveAudioChunk>, language: String) -> AsyncThrowingStream<LiveSpeechResult, any Error>
}

/// Which of the system's models follows the voice (plan 3d, T5): dictation when its model of the language is on the
/// Mac, the faster; else the transcription's (docs/performance.md, fase 3).
public enum LiveSpeechEngineKind: String, CaseIterable, Equatable, Sendable {
    /// `DictationTranscriber`, progressive short dictation (`DictationLiveEngine`): about 0.4 s after a word.
    case dictation
    /// `SpeechTranscriber` with volatile and fast results (`SpeechTranscriberLiveEngine`): results about once a second.
    case transcriber
}

/// Whether Follow the Voice can follow, in which language and with which engine, or why not.
public enum LiveSpeechAvailability: Equatable, Sendable {
    /// In `language` (BCP 47), with `engine`.
    case available(language: String, engine: LiveSpeechEngineKind)
    /// Live transcription needs macOS 26 (`SpeechAnalyzer`).
    case needsMacOS26
    /// This Mac cannot transcribe (`SpeechTranscriber.isAvailable` is false).
    case notOnThisMac
    /// Neither model of this language (BCP 47) is on this Mac; the transcription's is the one "Download the Language"
    /// gets.
    case modelNotInstalled(String)
    /// No language the Mac transcribes.
    case noLanguage
}

/// What `LiveSpeech.availability` asks of the Mac's speech models; a test's stands in for them. Only asks what is
/// installed: never downloads a model, never asks for one, never asks for a permission.
public struct LiveSpeechModels: Sendable {
    /// Whether this Mac runs speech models at all (`SpeechTranscriber.isAvailable` on macOS 26).
    public var isAvailable: @Sendable () -> Bool
    /// The language to follow in when the transcription's cannot be (`SpeechLanguages.defaultLanguage()`).
    public var defaultLanguage: @Sendable () async -> String?
    /// Whether the model of `language` (BCP 47) that `engine` uses is on the Mac: for `.transcriber`,
    /// `SpeechLanguages.status(of:)`; for `.dictation` only `.installed` counts (Toma never downloads that one).
    public var status: @Sendable (_ language: String, _ engine: LiveSpeechEngineKind) async -> LanguageModelStatus

    public init(
        isAvailable: @escaping @Sendable () -> Bool,
        defaultLanguage: @escaping @Sendable () async -> String?,
        status: @escaping @Sendable (_ language: String, _ engine: LiveSpeechEngineKind) async -> LanguageModelStatus
    ) {
        self.isAvailable = isAvailable
        self.defaultLanguage = defaultLanguage
        self.status = status
    }

    /// This Mac's.
    public static let system = LiveSpeechModels(
        isAvailable: { SpeechLanguages.isAvailable() },
        defaultLanguage: { await SpeechLanguages.defaultLanguage() },
        status: { language, engine in
            switch engine {
            case .transcriber:
                return await SpeechLanguages.status(of: language)
            case .dictation:
                guard #available(macOS 26, *) else { return .unsupported }
                return await DictationLiveEngine.status(of: language)
            }
        })
}

/// Follow the Voice's engine and its language (plan 3d, decision 13, and the controller's ruling on T5).
public enum LiveSpeech {
    /// The language and the engine to follow in: `preferred` (the transcription's, `TranscriptionPreferences`) if one
    /// of its models is on the Mac, else `SpeechLanguages.defaultLanguage()` if one of its models is; for the language,
    /// dictation if its model is there, else the transcription's. Else the model that is missing: `preferred`'s if the
    /// Mac can download it ("Download the Language"), else the default's; `.noLanguage` without either.
    public static func availability(preferred: String?, models: LiveSpeechModels = .system) async -> LiveSpeechAvailability {
        guard #available(macOS 26, *) else { return .needsMacOS26 }
        guard models.isAvailable() else { return .notOnThisMac }
        var first: Candidate?
        if let preferred {
            let candidate = await Candidate(SpeechLanguages.bcp47(preferred), models)
            if candidate.engine != nil { return availability(preferred: candidate, fallback: nil) }
            first = candidate
        }
        var fallback: Candidate?
        if let language = await models.defaultLanguage() { fallback = await Candidate(language, models) }
        return availability(preferred: first, fallback: fallback)
    }

    /// A language and what the Mac has of its models.
    struct Candidate: Equatable {
        var language: String
        var dictation: LanguageModelStatus
        var transcriber: LanguageModelStatus

        init(_ language: String, dictation: LanguageModelStatus, transcriber: LanguageModelStatus) {
            self.language = language
            self.dictation = dictation
            self.transcriber = transcriber
        }

        init(_ language: String, _ models: LiveSpeechModels) async {
            self.init(language, dictation: await models.status(language, .dictation), transcriber: await models.status(language, .transcriber))
        }

        /// The engine that follows in it: dictation first.
        var engine: LiveSpeechEngineKind? {
            if dictation == .installed { return .dictation }
            if transcriber == .installed { return .transcriber }
            return nil
        }
    }

    /// The choice on what the Mac has of the preferred language and of the default one.
    static func availability(preferred: Candidate?, fallback: Candidate?) -> LiveSpeechAvailability {
        for candidate in [preferred, fallback].compactMap(\.self) {
            if let engine = candidate.engine { return .available(language: candidate.language, engine: engine) }
        }
        if let preferred, preferred.transcriber == .downloadable || preferred.transcriber == .downloading {
            return .modelNotInstalled(preferred.language)
        }
        if let fallback { return .modelNotInstalled(fallback.language) }
        return .noLanguage
    }

    /// The engine of `kind`; `nil` before macOS 26.
    public static func engine(_ kind: LiveSpeechEngineKind) -> (any LiveSpeechEngine)? {
        guard #available(macOS 26, *) else { return nil }
        switch kind {
        case .dictation: return DictationLiveEngine()
        case .transcriber: return SpeechTranscriberLiveEngine()
        }
    }
}

/// `DictationTranscriber` in live mode (the controller's ruling on T5: it follows within 0.6 s): the progressive short
/// dictation preset, a `SpeechAnalyzer` fed each chunk as it comes. Its model is the system's dictation one, which must
/// be on the Mac (`DictationTranscriber.installedLocales`): it never downloads one.
@available(macOS 26, *)
public struct DictationLiveEngine: LiveSpeechEngine {
    public init() {}

    public func results(of audio: AsyncStream<LiveAudioChunk>, language: String) -> AsyncThrowingStream<LiveSpeechResult, any Error> {
        LiveAnalysis.results { heard in
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                throw TranscriptionError.engine("DictationTranscriber does not transcribe \(language)")
            }
            guard await Self.isInstalled(locale) else { throw TranscriptionError.modelNotInstalled(language) }
            try await LiveAnalysis.hear(audio, with: Self.module(for: locale), language: language, heard: heard) {
                String($0.text.characters)
            }
        }
    }

    /// The transcriber of `locale` the engine uses.
    static func module(for locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }

    /// `.installed` if the dictation model of `language` is on the Mac, `.downloadable` if the system has one (Toma
    /// never downloads it), `.unsupported` otherwise.
    static func status(of language: String) async -> LanguageModelStatus {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            return .unsupported
        }
        return await isInstalled(locale) ? .installed : .downloadable
    }

    private static func isInstalled(_ locale: Locale) async -> Bool {
        let identifier = locale.identifier(.bcp47)
        return await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == identifier }
    }
}

/// `SpeechTranscriber` in live mode (plan 3d, T5; what follows when the dictation model is not on the Mac): volatile
/// and fast results, no attributes, a `SpeechAnalyzer` fed each chunk as it comes. The model must be on the Mac: it
/// never downloads one.
@available(macOS 26, *)
public struct SpeechTranscriberLiveEngine: LiveSpeechEngine {
    public init() {}

    public func results(of audio: AsyncStream<LiveAudioChunk>, language: String) -> AsyncThrowingStream<LiveSpeechResult, any Error> {
        LiveAnalysis.results { heard in
            guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notOnThisMac }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                throw TranscriptionError.engine("SpeechTranscriber does not transcribe \(language)")
            }
            guard await SpeechLanguages.isInstalled(locale) else { throw TranscriptionError.modelNotInstalled(language) }
            try await LiveAnalysis.hear(audio, with: Self.module(for: locale), language: language, heard: heard) {
                String($0.text.characters)
            }
        }
    }

    /// The transcriber of `locale` the live engine uses.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }
}

/// What the two live engines share: a `SpeechAnalyzer` with one module, fed each chunk as it comes, converted to the
/// analyzer's best format with `AVAudioConverter`. Ending the iteration (cancelling its task) ends the analyzer's input
/// and stops it (`cancelAndFinishNow`).
@available(macOS 26, *)
enum LiveAnalysis {
    /// The results `run` gives to its argument, in a task of their own that ending the iteration cancels.
    static func results(
        _ run: @escaping @Sendable (_ heard: @escaping @Sendable (LiveSpeechResult) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<LiveSpeechResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Hears `audio` with `module` until it ends (then every result is final) or the task is cancelled, giving each
    /// result to `heard`, with its text as `text` reads it.
    static func hear<Module: SpeechModule>(
        _ audio: AsyncStream<LiveAudioChunk>, with module: Module, language: String,
        heard: @escaping @Sendable (LiveSpeechResult) -> Void, text: @escaping @Sendable (Module.Result) -> String
    ) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.engine("SpeechAnalyzer has no audio format for \(language)")
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (input, inputs) = AsyncStream<AnalyzerInput>.makeStream()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // The results end when the analyzer finishes, or when this task is cancelled (the group's child is).
            group.addTask {
                for try await result in module.results {
                    heard(LiveSpeechResult(text: text(result), isFinal: result.isFinal))
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
