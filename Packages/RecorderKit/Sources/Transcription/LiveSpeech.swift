// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

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
            let recognizer = try await ModuleRecognizer(Self.module(for: locale), language: language) { String($0.text.characters) }
            try await LiveAnalysis.run(audio, with: recognizer, language: language, heard: heard)
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
            let recognizer = try await ModuleRecognizer(Self.module(for: locale), language: language) { String($0.text.characters) }
            try await LiveAnalysis.run(audio, with: recognizer, language: language, heard: heard)
        }
    }

    /// The transcriber of `locale` the live engine uses.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }
}

/// What `LiveAnalysis.run` drives: a `SpeechAnalyzer` with one module in the engines (`ModuleRecognizer`), a test's
/// otherwise.
@available(macOS 26, *)
protocol LiveRecognizer: Sendable {
    /// The format it takes its audio in.
    var format: AVAudioFormat { get }
    /// Analyzes `input`, reading it whenever it is ready for more, until it ends and everything is final.
    func analyze(_ input: LiveAnalyzerInput) async throws
    /// Gives each result to `heard` until the analysis is over.
    func hear(_ heard: @escaping @Sendable (LiveSpeechResult) -> Void) async throws
    /// Stops the analysis at once.
    func stop() async
}

/// A `SpeechAnalyzer` with `module`, at the analyzer's best format for it.
@available(macOS 26, *)
struct ModuleRecognizer<Module: SpeechModule>: LiveRecognizer {
    let format: AVAudioFormat
    private let module: Module
    private let analyzer: SpeechAnalyzer
    private let text: @Sendable (Module.Result) -> String

    /// `text` reads the text of a result.
    init(_ module: Module, language: String, text: @escaping @Sendable (Module.Result) -> String) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.engine("SpeechAnalyzer has no audio format for \(language)")
        }
        self.format = format
        self.module = module
        self.text = text
        analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
    }

    func analyze(_ input: LiveAnalyzerInput) async throws {
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func hear(_ heard: @escaping @Sendable (LiveSpeechResult) -> Void) async throws {
        for try await result in module.results {
            heard(LiveSpeechResult(text: text(result), isFinal: result.isFinal))
        }
    }

    func stop() async {
        await analyzer.cancelAndFinishNow()
    }
}

/// What the two live engines share. Ending the iteration (cancelling its task) ends the recognizer's input and stops it.
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

    /// Hears `audio` with `recognizer` until it ends (then every result is final), the task is cancelled, or either
    /// the analysis or its results fail, whichever comes first: a failure ends it at once, while the take goes on, and
    /// is what it throws. Gives each result to `heard`.
    ///
    /// The recognizer pulls the audio (`LiveAnalyzerInput`) as it is ready for more: while it does not, the audio waits
    /// in `audio`'s feed (`LiveMicrophoneFeed`, the newest two seconds) and nowhere else, and it goes on from the newest.
    static func run(
        _ audio: AsyncStream<LiveAudioChunk>, with recognizer: some LiveRecognizer, language: String,
        heard: @escaping @Sendable (LiveSpeechResult) -> Void
    ) async throws {
        let input = LiveAnalyzerInput(audio, format: recognizer.format)
        try await withThrowingTaskGroup(of: Void.self) { group in
            // The results, until the analysis is over.
            group.addTask { try await recognizer.hear(heard) }
            group.addTask {
                try await withTaskCancellationHandler {
                    try await recognizer.analyze(input)
                } onCancel: {
                    input.stop()
                    Task { await recognizer.stop() }
                }
            }
            do {
                // The first child to fail ends the run here, at once.
                while try await group.next() != nil {}
                try Task.checkCancellation()
            } catch {
                input.stop()
                await recognizer.stop()
                // Leaving the group cancels the other child and waits for it.
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

/// The recognizer's input: each chunk of `audio` converted to `format` when the recognizer asks for the next one, never
/// before, so nothing waits between the feed and the recognizer. `stop()` ends it: the next ask gets nothing (and one
/// that waits for audio gets nothing once the next chunk comes, or once its task is cancelled).
@available(macOS 26, *)
final class LiveAnalyzerInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    let format: AVAudioFormat
    private let audio: AsyncStream<LiveAudioChunk>
    private let stopped = Atomic(false)
    private let taken = Atomic(0)

    init(_ audio: AsyncStream<LiveAudioChunk>, format: AVAudioFormat) {
        self.audio = audio
        self.format = format
    }

    func stop() {
        stopped.store(true, ordering: .relaxed)
    }

    var isStopped: Bool { stopped.load(ordering: .relaxed) }

    /// The frames of `audio` (at 48 kHz) the recognizer has asked for so far.
    var framesTaken: Int { taken.load(ordering: .relaxed) }

    func makeAsyncIterator() -> Iterator {
        Iterator(input: self, chunks: audio.makeAsyncIterator(), converter: try? LiveAnalyzerConverter(to: format))
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate let input: LiveAnalyzerInput
        fileprivate var chunks: AsyncStream<LiveAudioChunk>.Iterator
        fileprivate let converter: LiveAnalyzerConverter?
        /// The audio ended and the converter gave what it held back.
        private var flushed = false

        fileprivate init(input: LiveAnalyzerInput, chunks: AsyncStream<LiveAudioChunk>.Iterator, converter: LiveAnalyzerConverter?) {
            self.input = input
            self.chunks = chunks
            self.converter = converter
        }

        mutating func next() async throws -> AnalyzerInput? {
            guard let converter else { throw TranscriptionError.engine("no converter to \(input.format)") }
            while !flushed, !input.isStopped {
                let chunk = await chunks.next()
                guard !input.isStopped else { return nil }
                if let chunk {
                    input.taken.add(chunk.samples.count, ordering: .relaxed)
                } else {
                    flushed = true
                }
                if let buffer = try converter.convert(chunk) { return AnalyzerInput(buffer: buffer) }
            }
            return nil
        }
    }
}

/// Mono Float32 at 48 kHz (`LiveAudioChunk`) to the analyzer's format, one chunk at a time, the resampler carried from
/// one to the next (`AnalyzerFeed`'s conversion, for chunks that come as they are heard).
@available(macOS 26, *)
fileprivate struct LiveAnalyzerConverter {
    private let converter: AVAudioConverter

    init(to format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: AnalyzerFeed.chunkFormat, to: format) else {
            throw TranscriptionError.engine("no converter to \(format)")
        }
        self.converter = converter
    }

    /// `chunk` in the analyzer's format; `nil` the end: what the converter still holds. `nil` when it gives nothing yet.
    func convert(_ chunk: LiveAudioChunk?) throws -> AVAudioPCMBuffer? {
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
