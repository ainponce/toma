// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import Transcription

// The takes here start their display at `base`, frame 0 of the take's timeline; `takeTime(_:)` is a time in seconds
// from there. Shared with `SpeechModelTests`.

let base = HostTime(nanoseconds: 5_000_000_000_000)
let micID = "mic"
let systemAudioID = "system-audio"
private let displaySource = TrackSource(
    name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1)
private let micSource = TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic")
private let systemAudioSource = TrackSource(name: "System Audio", excludedBundleIDs: [])

func takeTime(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of the display, `seconds` long from `base`, with a microphone of `mic` and system audio of `systemAudio`
/// when they have segments.
func voiceTake(
    in dir: URL, name: String, seconds: Double, mic: [AudioSegmentSpec] = [], systemAudio: [AudioSegmentSpec] = []
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: "display-1", source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    if !mic.isEmpty { try await builder.addAudioTrack(id: micID, source: micSource, segments: mic) }
    if !systemAudio.isEmpty {
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: systemAudio)
    }
    return try builder.write()
}

/// Three segments of the microphone with pauses between them, at frames 24 000, 156 000 and 288 000.
private let threeSegments = [
    AudioSegmentSpec(start: takeTime(0.5), seconds: 1.5),
    AudioSegmentSpec(start: takeTime(3.25), seconds: 1, frequency: 660),
    AudioSegmentSpec(start: takeTime(6), seconds: 2.5, frequency: 220),
]

/// An engine that reads what it is given the way `SpeechTranscriberEngine` does (`SpeechFeed`), keeps every chunk, and
/// hears one run in each span, from the first frame it was given of it to the last.
private final class FeedEngine: SpeechEngine {
    let given = Mutex<[SpeechFeed.Chunk]>([])
    let languages = Mutex<[String]>([])
    let progress = Mutex<[Double]>([])

    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        languages.withLock { $0.append(language) }
        let feed = SpeechFeed(audio: audio) { [self] value in
            self.progress.withLock { $0.append(value) }
            progress(value)
        }
        var runs: [SpeechRun] = []
        for (i, span) in audio.spans.enumerated() {
            var heard: Range<Int64>?
            for try await chunk in feed.chunks(of: span) {
                given.withLock { $0.append(chunk) }
                heard = heard.map { $0.lowerBound..<chunk.frames.upperBound } ?? chunk.frames
            }
            guard let heard else { continue }
            runs.append(SpeechRun(text: " tramo\(i)", start: Double(heard.lowerBound) / 48_000, end: Double(heard.upperBound) / 48_000))
        }
        return runs
    }
}

/// Each segment's word is at the host time of the segment: no drift from one to the next, and the same again.
@Test func wordsFromThreeSegmentsLandAtTheirHostTimes() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "three", seconds: 9, mic: threeSegments)
        let segments = try #require(project.take.track(micID)).segments
        let transcript = try await Transcriber.transcribe(project, language: "es-MX", engine: FeedEngine()) { _ in }
        let words = try #require(transcript.takes.first).words
        #expect(words.map(\.text) == ["tramo0", "tramo1", "tramo2"])
        #expect(words.map(\.start) == segments.map(\.startHostTime))
        // Each ends where its segment's audio ends, to the frame.
        for (word, segment) in zip(words, segments) {
            let end = try #require(segment.endHostTime)
            #expect(abs(word.end.seconds(since: end)) <= 1 / 48_000.0)
        }
        let again = try await Transcriber.transcribe(project, language: "es-MX", engine: FeedEngine()) { _ in }
        #expect(again == transcript)
    }
}

/// The engine is given the frames of the spans and nothing between them, a second at most at a time, as the mix hears
/// them; its progress goes up to 1.
@Test func gapsBetweenSegmentsAreNotFed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "gaps", seconds: 9, mic: threeSegments)
        let engine = FeedEngine()
        _ = try await Transcriber.transcribe(project, language: "es-MX", engine: engine) { _ in }
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let chunks = engine.given.withLock { $0 }
        #expect(chunks.allSatisfy { chunk in
            chunk.frames.count <= 48_000 && chunk.samples.count == chunk.frames.count
                && audio.spans.contains { $0.frames.contains(chunk.frames.lowerBound) && $0.frames.upperBound >= chunk.frames.upperBound }
        })
        // Together, in order and without holes, exactly the spans.
        var covered: [Range<Int64>] = []
        for chunk in chunks {
            if let last = covered.last, last.upperBound == chunk.frames.lowerBound {
                covered[covered.count - 1] = last.lowerBound..<chunk.frames.upperBound
            } else {
                covered.append(chunk.frames)
            }
        }
        #expect(covered == audio.spans.map(\.frames))
        // What the mix plays there, sound and not silence.
        let first = try #require(chunks.first), last = try #require(chunks.last)
        for chunk in [first, last] {
            let heard = try await offThePool {
                let reader = audio.makeReader()
                var samples: [Float] = []
                reader.read(chunk.frames, into: &samples)
                return samples
            }
            #expect(chunk.samples == heard && heard.contains { abs($0) > 0.1 })
        }
        let progress = engine.progress.withLock { $0 }
        #expect(progress.count == chunks.count && zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 } && progress.last == 1)
    }
}

/// Without a microphone, the system audio is transcribed; without either, nothing is.
@Test func systemAudioWhenThereIsNoMicrophone() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(
            in: dir, name: "system", seconds: 3, systemAudio: [AudioSegmentSpec(start: takeTime(1), seconds: 1)])
        let engine = FeedEngine()
        let transcript = try await Transcriber.transcribe(project, language: "es-MX", engine: engine) { _ in }
        #expect(transcript.takes.map(\.track) == [systemAudioID])
        #expect(transcript.takes.first?.words.map(\.start) == [takeTime(1)])
        let silent = try await voiceTake(in: dir, name: "silent", seconds: 1)
        await #expect(throws: TranscriptionError.noAudio) {
            try await Transcriber.transcribe(silent, language: "es-MX", engine: engine) { _ in }
        }
    }
    // A microphone counts once it recorded a segment; then system audio, then a device's audio.
    func track(_ id: String, _ kind: TrackKind, segments: Int) -> TrackRecord {
        TrackRecord(id: id, kind: kind, source: TrackSource(name: id), segments: (0..<segments).map {
            SegmentRecord(index: $0 + 1, file: "takes/take-001/\(id)/seg-\($0 + 1).mov", startHostTime: base, droppedFrames: 0, heartbeatFrames: 0)
        })
    }
    func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: tracks)
    }
    let display = track("display-1", .display, segments: 1)
    #expect(Transcriber.track(for: take([display, track("system-audio", .systemAudio, segments: 1), track("mic-1", .microphone, segments: 0),
                                         track("mic-2", .microphone, segments: 2)]))?.id == "mic-2")
    #expect(Transcriber.track(for: take([display, track("mic-1", .microphone, segments: 0), track("device-audio", .deviceAudio, segments: 1),
                                         track("system-audio", .systemAudio, segments: 1)]))?.id == "system-audio")
    #expect(Transcriber.track(for: take([display, track("device-audio", .deviceAudio, segments: 1)]))?.id == "device-audio")
    #expect(Transcriber.track(for: take([display, track("camera-1", .camera, segments: 1), track("mic-1", .microphone, segments: 0)])) == nil)
}

/// The transcript is in BCP 47, names the engine and the take's track, and the engine is asked in BCP 47 too.
@Test func transcriptIsBCP47AndNamesTheEngine() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "bcp47", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2)])
        let engine = FeedEngine()
        let transcript = try await Transcriber.transcribe(project, language: "es_MX", engine: engine) { _ in }
        #expect(transcript.language == "es-MX" && transcript.engine == "speechTranscriber-1" && SpeechLanguages.engineID == transcript.engine)
        #expect(transcript.takes.map(\.take) == ["take-001"] && transcript.takes.map(\.track) == [micID])
        #expect(engine.languages.withLock { $0 } == ["es-MX"])
    }
}

/// An engine that stops after `after` chunks until its task is cancelled, then asks for the next one.
private final class PausingEngine: SpeechEngine {
    let given = Mutex(0)
    let paused: AsyncStream<Void>
    private let pause: AsyncStream<Void>.Continuation
    private let after: Int

    init(after: Int) {
        self.after = after
        (paused, pause) = AsyncStream.makeStream()
    }

    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        let feed = SpeechFeed(audio: audio, progress: progress)
        for span in audio.spans {
            for try await _ in feed.chunks(of: span) where given.withLock({ $0 += 1; return $0 }) == after {
                pause.yield()
                // Waits for the cancellation without throwing it: what stops is the feed.
                try? await Task.sleep(for: .seconds(60))
            }
        }
        return [SpeechRun(text: "nunca", start: 0, end: 1)]
    }
}

/// Cancelling the transcription stops what the engine is given, and nothing comes back.
@Test func cancellationStopsFeeding() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cancel", seconds: 12, mic: [AudioSegmentSpec(start: base, seconds: 12)])
        let engine = PausingEngine(after: 2)
        let task = Task { try await Transcriber.transcribe(project, language: "es-MX", engine: engine) { _ in } }
        for await _ in engine.paused { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(engine.given.withLock { $0 } == 2)
    }
}

/// The first of the Mac's languages that has an equivalent the engine supports; then en-US; then the first supported.
@Test func defaultLanguageFollowsThePreferences() async {
    let supported = ["en-GB", "en-US", "es-MX", "fr-FR"]
    let equivalents = ["es-419": "es_MX", "fr": "fr-FR"]
    func language(_ preferred: [String], _ supported: [String]) async -> String? {
        await SpeechLanguages.defaultLanguage(preferred: preferred, supported: supported) { equivalents[$0] }
    }
    #expect(await language(["es-419", "en-GB"], supported) == "es-MX")
    #expect(await language(["de-DE", "fr"], supported) == "fr-FR")
    #expect(await language(["de-DE", "ja-JP"], supported) == "en-US")
    #expect(await language(["de-DE"], ["fr-FR", "es-MX"]) == "fr-FR")
    // An equivalent that is not supported does not count.
    #expect(await language(["es-419"], ["fr-FR"]) == "fr-FR")
    #expect(await language(["es-419"], []) == nil)
}

/// A download reports how it moves, only up, and 1 at the end; cancelling its task cancels it.
@Test func downloadReportsItsProgressAndIsCancelledWithItsTask() async throws {
    let observed = Progress(totalUnitCount: 4)
    let reported = Mutex<[Double]>([])
    try await SpeechLanguages.install(observed, progress: { value in reported.withLock { $0.append(value) } }) {
        for unit in [1, 3, 2, 4] as [Int64] {
            observed.completedUnitCount = unit
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    #expect(reported.withLock { $0 } == [0, 0.25, 0.75, 1])

    let waiting = Progress(totalUnitCount: 1)
    let task = Task {
        try await SpeechLanguages.install(waiting, progress: { _ in }) {
            while !waiting.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(waiting.isCancelled)
}

/// The analyzer's input is the span's audio in its format, the first buffer at the span's place on the timeline and
/// every frame after it where it was: a click half a second into the span is half a second into what it is given.
@Test(.enabled(if: SpeechLanguages.isSupportedOS))
func analyzerInputIsOnTheTimeline() async throws {
    guard #available(macOS 26, *) else { return }
    try await withTemporaryDirectory { dir in
        // Silence but for a click of 10 ms half a second into the segment, which starts 1 s into the take.
        let click: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer = { block, sample in
            guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
            let values = [Float](repeating: block == 50 ? 0.5 : 0, count: CMSampleBufferGetNumSamples(sample))
            _ = values.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
            }
            return sample
        }
        let project = try await voiceTake(
            in: dir, name: "click", seconds: 4, mic: [AudioSegmentSpec(start: takeTime(1), seconds: 2.5, transform: click)])
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let span = try #require(audio.spans.first)
        #expect(span.frames.lowerBound == 48_000)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let input = AnalyzerFeed(SpeechFeed(audio: audio) { _ in }.chunks(of: span), format: format, startFrame: span.frames.lowerBound)
        var iterator = input.makeAsyncIterator()
        var times: [CMTime?] = []
        var samples: [Int16] = []
        while let next = try await iterator.next() {
            times.append(next.bufferStartTime)
            #expect(next.buffer.format == format)
            let data = try #require(next.buffer.int16ChannelData)
            samples += UnsafeBufferPointer(start: data[0], count: Int(next.buffer.frameLength))
        }
        #expect(times.first == CMTime(value: 48_000, timescale: 48_000) && times.dropFirst().allSatisfy { $0 == nil })
        // A third of the span's frames, all of them.
        #expect(abs(samples.count - span.frames.count / 3) <= 1)
        let clickAt = try #require(samples.firstIndex { abs($0) > 4_000 })
        #expect(abs(clickAt - 8_000) <= 8)
        // Stopped, it gives nothing more.
        let stopped = AnalyzerFeed(SpeechFeed(audio: audio) { _ in }.chunks(of: span), format: format, startFrame: 0)
        var rest = stopped.makeAsyncIterator()
        #expect(try await rest.next() != nil)
        stopped.stop()
        #expect(try await rest.next() == nil)
    }
}
