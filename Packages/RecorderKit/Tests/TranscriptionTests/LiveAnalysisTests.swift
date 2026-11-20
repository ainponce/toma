// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import Transcription

/// The live analysis with a recognizer made up by the test (no Speech model): what it does when the recognizer stops
/// reading, and when it fails during the take.
@Suite(.timeLimit(.minutes(1))) struct LiveAnalysisTests {
    /// A recognizer that stops reading keeps nothing piling up: the audio waits in the feed, the newest two seconds, and
    /// the recognizer goes on from there.
    @Test func aStalledRecognizerGoesOnFromTheNewestTwoSeconds() async throws {
        guard #available(macOS 26, *) else { return }
        let feed = LiveMicrophoneFeed()
        let recognizer = FakeRecognizer(stallsAfterFirstInput: true)
        let results = LiveAnalysis.results { heard in
            try await LiveAnalysis.run(feed.chunks, with: recognizer, language: "es-MX", heard: heard)
        }
        let listening = Task { for try await _ in results {} }
        feed.append(block(0))
        #expect(await eventually { recognizer.readFirstInput })
        // 10 s of microphone while it does not read.
        for index in 1...1_000 { feed.append(block(index)) }
        feed.finish()
        recognizer.goOn()
        try await listening.value
        // After the stall it was given the newest two seconds, at once, and nothing else.
        #expect(recognizer.framesAfterStall == 96_000)
        #expect(recognizer.stops == 0)
    }

    /// The results fail while the audio goes on: the caller hears it at once, and the recognizer is stopped.
    @Test func aFailureReachesTheCallerDuringTheTake() async throws {
        guard #available(macOS 26, *) else { return }
        let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
        let recognizer = FakeRecognizer(failsAfterFirstInput: true)
        let feeding = Task {
            while !Task.isCancelled {
                input.yield(LiveAudioChunk(samples: [Float](repeating: 0.1, count: 480)))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var heard: [LiveSpeechResult] = []
        await #expect(throws: TranscriptionError.self) {
            for try await result in LiveAnalysis.results({ heard in
                try await LiveAnalysis.run(audio, with: recognizer, language: "es-MX", heard: heard)
            }) {
                heard.append(result)
            }
        }
        #expect(clock.now - start < .seconds(5), "the failure came after \(clock.now - start)")
        #expect(heard == [LiveSpeechResult(text: "hola", isFinal: false)])
        #expect(recognizer.stops >= 1)
        feeding.cancel()
        input.finish()
    }

    /// Ending the iteration while the audio goes on stops the recognizer, and its analysis ends.
    @Test func endingTheIterationStopsTheRecognizer() async throws {
        guard #available(macOS 26, *) else { return }
        let (audio, input) = AsyncStream<LiveAudioChunk>.makeStream()
        let recognizer = FakeRecognizer()
        input.yield(LiveAudioChunk(samples: [Float](repeating: 0.1, count: 480)))
        let listening = Task {
            for try await _ in LiveAnalysis.results({ heard in
                try await LiveAnalysis.run(audio, with: recognizer, language: "es-MX", heard: heard)
            }) {}
        }
        #expect(await eventually { recognizer.readFirstInput })
        listening.cancel()
        _ = try? await listening.value
        #expect(await eventually { recognizer.stops >= 1 && recognizer.analysisEnded })
        input.finish()
    }
}

/// 10 ms of mono Float32 at 48 kHz, every sample `index` / 1000.
private func block(_ index: Int) -> CMSampleBuffer {
    let samples = [Float](repeating: Float(index) / 1_000, count: 480)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format)
    var data: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 1_920, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: 1_920, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &data)
    _ = samples.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data!, offsetIntoDestination: 0, dataLength: 1_920)
    }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: data!, formatDescription: format!, sampleCount: 480,
        presentationTimeStamp: CMTime(value: CMTimeValue(index * 480), timescale: 48_000), packetDescriptions: nil,
        sampleBufferOut: &sample)
    return sample!
}

/// A recognizer of mono Float32 at 48 kHz that reads its input as the test says: it can stop reading after its first
/// input until `goOn()`, or fail its results after it.
@available(macOS 26, *)
private final class FakeRecognizer: LiveRecognizer {
    let format = AnalyzerFeed.chunkFormat
    private let stallsAfterFirstInput: Bool
    private let failsAfterFirstInput: Bool

    private struct State {
        var readFirstInput = false
        var waitingToGoOn: CheckedContinuation<Void, Never>?
        var goesOn = false
        var framesAfterStall: Int?
        var stops = 0
        var analysisEnded = false
        /// `hear` waits for the first input (to fail) or for the end of the analysis.
        var hearing: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    init(stallsAfterFirstInput: Bool = false, failsAfterFirstInput: Bool = false) {
        self.stallsAfterFirstInput = stallsAfterFirstInput
        self.failsAfterFirstInput = failsAfterFirstInput
    }

    var readFirstInput: Bool { state.withLock { $0.readFirstInput } }
    var framesAfterStall: Int? { state.withLock { $0.framesAfterStall } }
    var stops: Int { state.withLock { $0.stops } }
    var analysisEnded: Bool { state.withLock { $0.analysisEnded } }

    func goOn() {
        let waiting = state.withLock { state in
            state.goesOn = true
            defer { state.waitingToGoOn = nil }
            return state.waitingToGoOn
        }
        waiting?.resume()
    }

    func analyze(_ input: LiveAnalyzerInput) async throws {
        defer { wakeHearing { $0.analysisEnded = true } }
        var reader = input.makeAsyncIterator()
        guard try await reader.next() != nil else { return }
        wakeHearing { $0.readFirstInput = true }
        guard stallsAfterFirstInput else {
            while try await reader.next() != nil {}
            return
        }
        let before = input.framesTaken
        await withCheckedContinuation { continuation in
            let goes = state.withLock { state in
                if !state.goesOn { state.waitingToGoOn = continuation }
                return state.goesOn
            }
            if goes { continuation.resume() }
        }
        while try await reader.next() != nil {}
        let after = input.framesTaken
        state.withLock { $0.framesAfterStall = after - before }
    }

    func hear(_ heard: @escaping @Sendable (LiveSpeechResult) -> Void) async throws {
        // Until the first input when it fails, until the end of the analysis otherwise.
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                let ready = failsAfterFirstInput ? state.readFirstInput : state.analysisEnded
                if !ready { state.hearing = continuation }
                return ready
            }
            if now { continuation.resume() }
        }
        guard failsAfterFirstInput else { return }
        heard(LiveSpeechResult(text: "hola", isFinal: false))
        throw FakeFailure()
    }

    func stop() async {
        let waiting = state.withLock { state in
            state.stops += 1
            state.goesOn = true
            defer { state.waitingToGoOn = nil }
            return state.waitingToGoOn
        }
        waiting?.resume()
        wakeHearing { $0.analysisEnded = true }
    }

    /// Changes the state, and wakes `hear` if what it waits for came.
    private func wakeHearing(_ change: (inout State) -> Void) {
        let hearing = state.withLock { state -> CheckedContinuation<Void, Never>? in
            change(&state)
            let ready = failsAfterFirstInput ? state.readFirstInput : state.analysisEnded
            guard ready else { return nil }
            defer { state.hearing = nil }
            return state.hearing
        }
        hearing?.resume()
    }
}

private struct FakeFailure: Error {}
