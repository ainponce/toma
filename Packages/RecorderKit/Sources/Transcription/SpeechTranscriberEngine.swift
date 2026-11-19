// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Export
import Foundation
import Speech
import Synchronization

/// The engine `speechTranscriber-1` (phase 2 design §5.1, plan decision 3): `SpeechAnalyzer` with a
/// `SpeechTranscriber` on the Mac, only final results, each with its `audioTimeRange`; it never downloads a model.
///
/// Each span of the track gets an analyzer of its own, fed its audio converted to the analyzer's best format a second
/// at a time, the first buffer at the span's place on the take's timeline: the times of the runs are then seconds of
/// that timeline. The results are gathered by a child task while the analyzer pulls the audio; cancelling the task
/// ends the audio and stops the analyzer (`cancelAndFinishNow`).
@available(macOS 26, *)
public struct SpeechTranscriberEngine: SpeechEngine {
    public init() {}

    public func transcribe(
        _ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeechRun] {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notOnThisMac }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TranscriptionError.engine("SpeechTranscriber does not transcribe \(language)")
        }
        guard await SpeechLanguages.isInstalled(locale) else { throw TranscriptionError.modelNotInstalled(language) }
        let feed = SpeechFeed(audio: audio, progress: progress)
        var runs: [SpeechRun] = []
        for span in audio.spans where !span.frames.isEmpty {
            try Task.checkCancellation()
            runs += try await Self.transcribe(feed.chunks(of: span), at: span.frames.lowerBound, locale: locale, language: language)
        }
        try Task.checkCancellation()
        return runs
    }

    /// The transcriber of `locale` the engine uses, also to ask for its model.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// The runs of one span, given as `chunks`, whose first frame is timeline frame `startFrame`.
    private static func transcribe(
        _ chunks: SpeechFeed.Chunks, at startFrame: Int64, locale: Locale, language: String
    ) async throws -> [SpeechRun] {
        let transcriber = module(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.engine("SpeechAnalyzer has no audio format for \(language)")
        }
        let input = AnalyzerFeed(chunks, format: format, startFrame: startFrame)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        return try await withThrowingTaskGroup(of: [SpeechRun].self) { group in
            // The results end when the analyzer finishes, or when this task is cancelled (the group's child is).
            group.addTask { try await runs(of: transcriber) }
            do {
                try await withTaskCancellationHandler {
                    try await analyzer.start(inputSequence: input)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } onCancel: {
                    input.stop()
                    Task { await analyzer.cancelAndFinishNow() }
                }
                try Task.checkCancellation()
            } catch {
                input.stop()
                await analyzer.cancelAndFinishNow()
                // Leaving the group cancels the results' child and waits for it.
                throw Task.isCancelled ? CancellationError() : engineError(error, language: language)
            }
            do {
                let runs = try await group.next() ?? []
                try Task.checkCancellation()
                return runs
            } catch {
                throw Task.isCancelled ? CancellationError() : engineError(error, language: language)
            }
        }
    }

    /// The runs of the final results of `transcriber`, in order, until its results end.
    private static func runs(of transcriber: SpeechTranscriber) async throws -> [SpeechRun] {
        var runs: [SpeechRun] = []
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                let range = run.audioTimeRange
                runs.append(SpeechRun(
                    text: String(result.text[run.range].characters),
                    start: range.flatMap { seconds($0.start) }, end: range.flatMap { seconds($0.end) }))
            }
        }
        return runs
    }

    private static func seconds(_ time: CMTime) -> Double? {
        time.isNumeric ? time.seconds : nil
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

/// The input of one analyzer: the chunks of a span converted to the analyzer's format with `AVAudioConverter`, a
/// buffer a second, the first one at timeline frame `startFrame` (in seconds) and the next ones after it. Read as the
/// analyzer asks for it, so the span is never in memory at once; `stop()` ends it at once, whatever is left.
///
/// The analyzer reads it from a task of its own, not the engine's: cancelling the engine's task does not reach it,
/// `stop()` does.
@available(macOS 26, *)
final class AnalyzerFeed: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    /// What `SpeechFeed` gives: mono Float32 at 48 kHz.
    static let chunkFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: false)!

    private let chunks: SpeechFeed.Chunks
    private let format: AVAudioFormat
    private let startTime: CMTime
    private let stopped = Atomic(false)

    init(_ chunks: SpeechFeed.Chunks, format: AVAudioFormat, startFrame: Int64) {
        self.chunks = chunks
        self.format = format
        startTime = CMTime(value: startFrame, timescale: CMTimeScale(TrackAudio.sampleRate))
    }

    /// Ends the input: the analyzer's next ask gets nothing.
    func stop() {
        stopped.store(true, ordering: .relaxed)
    }

    var isStopped: Bool { stopped.load(ordering: .relaxed) }

    func makeAsyncIterator() -> Iterator {
        Iterator(feed: self, chunks: chunks.makeAsyncIterator(), converter: AVAudioConverter(from: Self.chunkFormat, to: format))
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate let feed: AnalyzerFeed
        fileprivate var chunks: SpeechFeed.Chunks.Iterator
        fileprivate let converter: AVAudioConverter?
        private var first = true
        /// The chunks ran out and the converter gave what it held back.
        private var flushed = false

        fileprivate init(feed: AnalyzerFeed, chunks: SpeechFeed.Chunks.Iterator, converter: AVAudioConverter?) {
            self.feed = feed
            self.chunks = chunks
            self.converter = converter
        }

        mutating func next() async throws -> AnalyzerInput? {
            guard let converter else {
                throw TranscriptionError.engine("no converter to \(feed.format)")
            }
            while !flushed, !feed.isStopped {
                let chunk = try await chunks.next()
                if chunk == nil { flushed = true }
                let buffer = try Self.convert(chunk, with: converter)
                guard buffer.frameLength > 0 else { continue }
                defer { first = false }
                return AnalyzerInput(buffer: buffer, bufferStartTime: first ? feed.startTime : nil)
            }
            return nil
        }

        /// `chunk` converted; `nil`, the end of the span: what the converter still holds.
        private static func convert(_ chunk: SpeechFeed.Chunk?, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
            var input: AVAudioPCMBuffer?
            if let chunk {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)), let data = buffer.floatChannelData
                else { throw TranscriptionError.engine("no buffer of \(chunk.samples.count) frames") }
                chunk.samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: $0.count) }
                buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
                input = buffer
            }
            // A second more than the chunk makes: far more than the resampler ever holds back.
            let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
            let capacity = (Double(input?.frameLength ?? 0) * ratio).rounded(.up) + converter.outputFormat.sampleRate
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
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
            switch status {
            case .error:
                throw TranscriptionError.engine("AVAudioConverter: \(error.map(String.init(describing:)) ?? "error")")
            case .haveData where output.frameLength == output.frameCapacity:
                // The buffer filled up: there may be more than it holds, which never happens with a second to spare.
                throw TranscriptionError.engine("AVAudioConverter held back more than a second")
            default:
                return output
            }
        }
    }
}
