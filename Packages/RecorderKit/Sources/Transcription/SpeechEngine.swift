// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Export
import Synchronization

/// What hears the words of an audio track: `SpeechTranscriberEngine` from macOS 26, or a test's.
public protocol SpeechEngine: Sendable {
    /// The runs of text heard in `audio`, in order: only its spans (`TrackAudio.spans`), each on its own, never the
    /// silence between them, and only final results. Times in seconds of the take's timeline (`TrackAudio.origin`).
    /// `progress`, from 0 to 1 and never down: the frames given to the engine over those of all the spans.
    /// - Throws: `TranscriptionError`; `CancellationError` if the task is cancelled, and then nothing is given back.
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws
        -> [SpeechRun]
}

/// Why a track was not transcribed.
public enum TranscriptionError: Error, Equatable, Sendable {
    /// The take has no microphone, system audio or device audio that recorded anything.
    case noAudio
    /// Transcribing needs macOS 26 (`SpeechTranscriber`).
    case needsMacOS26
    /// This Mac cannot transcribe (`SpeechTranscriber.isAvailable` is false).
    case notOnThisMac
    /// The model of this language (BCP 47) is not on this Mac; `SpeechLanguages.download` gets it.
    case modelNotInstalled(String)
    /// The engine failed, with what it said.
    case engine(String)
}

/// What a speech engine is given of a track: each of its spans on its own, in order, one second at a time, in mono
/// Float32 at 48 kHz, read only when asked for (never more than a second ahead of the engine, never the take at once),
/// with `TrackAudio`'s reader on a queue of its own, never on Swift's cooperative pool.
///
/// `progress` hears the frames given over those of all the spans, from the thread of whoever asks for the chunks.
final class SpeechFeed: Sendable {
    /// One second at 48 kHz.
    static let chunkFrames: Int64 = 48_000

    let audio: TrackAudio
    /// The frames of all the spans.
    let totalFrames: Int64
    private let given = Atomic<Int64>(0)
    private let progress: @Sendable (Double) -> Void

    init(audio: TrackAudio, progress: @escaping @Sendable (Double) -> Void) {
        self.audio = audio
        totalFrames = audio.spans.reduce(0) { $0 + Int64($1.frames.count) }
        self.progress = progress
    }

    /// The frames of `span`, a second at a time, read as they are asked for.
    func chunks(of span: TrackAudioSpan) -> Chunks {
        Chunks(feed: self, frames: span.frames)
    }

    fileprivate func gave(_ frames: Int64) {
        let sum = given.wrappingAdd(frames, ordering: .relaxed).newValue
        progress(min(1, Double(sum) / Double(max(totalFrames, 1))))
    }

    /// Timeline frames `frames` of the track, in mono.
    struct Chunk: Sendable {
        var frames: Range<Int64>
        var samples: [Float]
    }

    struct Chunks: AsyncSequence, Sendable {
        fileprivate let feed: SpeechFeed
        fileprivate let frames: Range<Int64>

        func makeAsyncIterator() -> Iterator {
            Iterator(feed: feed, cursor: frames.lowerBound, end: frames.upperBound, reader: Reader(feed.audio))
        }

        struct Iterator: AsyncIteratorProtocol {
            fileprivate let feed: SpeechFeed
            fileprivate var cursor: Int64
            fileprivate let end: Int64
            fileprivate let reader: Reader

            /// The next second of the span, read now; `nil` past its end.
            /// - Throws: `CancellationError` if the task that asks is cancelled: nothing more is read.
            mutating func next() async throws -> Chunk? {
                try Task.checkCancellation()
                guard cursor < end else { return nil }
                let frames = cursor..<Swift.min(cursor + SpeechFeed.chunkFrames, end)
                let samples = await reader.read(frames)
                cursor = frames.upperBound
                feed.gave(Int64(frames.count))
                return Chunk(frames: frames, samples: samples)
            }
        }
    }

    /// A reader of the track, read on a serial queue of its own: one read at a time, off the cooperative pool.
    fileprivate final class Reader: Sendable {
        private let reader: Mutex<TrackAudioReader>
        private let channels: Int
        private let queue = DispatchQueue(label: "dev.toma.SpeechFeed", qos: .utility)

        init(_ audio: TrackAudio) {
            reader = Mutex(audio.makeReader())
            channels = audio.channels
        }

        func read(_ frames: Range<Int64>) async -> [Float] {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.readNow(frames)) }
            }
        }

        private func readNow(_ frames: Range<Int64>) -> [Float] {
            let samples = reader.withLock { reader in
                var samples: [Float] = []
                reader.read(frames, into: &samples)
                return samples
            }
            guard channels > 1 else { return samples }
            // The mean of the channels: a stream of two read as one.
            return stride(from: 0, to: samples.count, by: channels).map { i in
                samples[i..<(i + channels)].reduce(0, +) / Float(channels)
            }
        }
    }
}
