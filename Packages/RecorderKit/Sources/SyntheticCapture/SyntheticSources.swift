// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Dispatch
import Foundation
import ProjectFormat
import Recording
import Synchronization

/// A fake display: `SampleFactory` frames at `framesPerSecond`, each timestamped with `clock()`
/// when it is made. Delivers on the start queue like `DisplayCaptureSource`, and can fail on demand.
public final class SyntheticVideoSource: CaptureSource {
    public let trackID: String
    public let kind = TrackKind.display
    public let media: TrackMedia
    public let sourceInfo: TrackSource
    public var activeDeviceUniqueID: String? { nil }

    /// Calls to `start`, including the ones that threw.
    public var startCount: Int { runner.startCount }
    /// The next `failOnStart` calls to `start` throw `NSError(domain: "Synthetic", code: -1)`.
    public var failOnStart: Int {
        get { runner.failOnStart }
        set { runner.failOnStart = newValue }
    }

    private let width: Int
    private let height: Int
    private let framesPerSecond: Int
    private let clock: @Sendable () -> HostTime
    private let runner = SyntheticRunner()
    private let frames = Mutex(Frames())

    private struct Frames {
        var paused = false
        var nextIndex = 0
    }

    public init(
        trackID: String = "display-1",
        width: Int,
        height: Int,
        framesPerSecond: Int,
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        precondition(framesPerSecond > 0, "SyntheticVideoSource: framesPerSecond must be positive")
        self.trackID = trackID
        self.media = .video(framesPerSecond: framesPerSecond)
        self.sourceInfo = TrackSource(
            name: "Synthetic Display",
            displayID: 1,
            globalFrame: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
            pixelScale: 1
        )
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.clock = clock
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await runner.start(
            on: queue, sink: sink, interval: .nanoseconds(1_000_000_000 / framesPerSecond)
        ) { [weak self] sink in
            self?.emitFrame(to: sink)
        }
    }

    public func stop() async {
        await runner.stop()
    }

    /// Delivers `didStopWithError` with `NSError(domain:code:)` on the start queue, after the frames
    /// already queued, and emits nothing more until the next `start`.
    public func failNow(domain: String, code: Int) {
        runner.fail(trackID: trackID, error: NSError(domain: domain, code: code))
    }

    /// While paused, no frames are emitted but the source keeps running (a static screen).
    public func pauseFrames(_ paused: Bool) {
        frames.withLock { $0.paused = paused }
    }

    private func emitFrame(to sink: any CaptureSink) {
        let index = frames.withLock { frames -> Int? in
            guard !frames.paused else { return nil }
            defer { frames.nextIndex += 1 }
            return frames.nextIndex
        }
        guard let index else { return }
        sink.source(trackID, didOutput: SampleFactory.videoSample(width: width, height: height, pts: clock(), frameIndex: index))
    }
}

/// A fake microphone: 10 ms blocks of `SampleFactory` audio, paced in real time. The first block
/// is stamped with `clock()` at `start`; each block moves the next PTS by
/// `frames / sampleRate × (1 + clockSkewPPM / 1e6)`, like a device clock that drifts from the host's.
public final class SyntheticAudioSource: CaptureSource {
    public let trackID: String
    public let kind = TrackKind.microphone
    public let media = TrackMedia.audio

    public var sourceInfo: TrackSource {
        TrackSource(name: "Synthetic Microphone", deviceUniqueID: deviceUniqueID)
    }

    /// The device a `start` reports as active. Change it to simulate a restart on another device.
    public var deviceUniqueID: String {
        get { audio.withLock { $0.deviceUniqueID } }
        set { audio.withLock { $0.deviceUniqueID = newValue } }
    }

    public var activeDeviceUniqueID: String? { audio.withLock { $0.activeDeviceUniqueID } }

    /// Calls to `start`, including the ones that threw.
    public var startCount: Int { runner.startCount }
    /// The next `failOnStart` calls to `start` throw `NSError(domain: "Synthetic", code: -1)`.
    public var failOnStart: Int {
        get { runner.failOnStart }
        set { runner.failOnStart = newValue }
    }

    private let clockSkewPPM: Double
    private let clock: @Sendable () -> HostTime
    private let runner = SyntheticRunner()
    private let audio: Mutex<Audio>

    private struct Audio {
        var sampleRate: Double
        var channels: Int
        var deviceUniqueID = "synthetic-mic"
        var activeDeviceUniqueID: String?
        var timeline: Timeline?
    }

    private struct Timeline {
        var firstPTS: HostTime
        var startUptimeNanoseconds: UInt64
        /// Nominal duration of the blocks emitted so far: Σ frames / sampleRate.
        var emittedSeconds = 0.0
    }

    private struct Block {
        var pts: HostTime
        var frames: Int
        var sampleRate: Double
        var channels: Int
    }

    public init(
        trackID: String = "mic",
        sampleRate: Double = 48_000,
        channels: Int = 1,
        clockSkewPPM: Double = 0,
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        self.trackID = trackID
        self.clockSkewPPM = clockSkewPPM
        self.clock = clock
        self.audio = Mutex(Audio(sampleRate: sampleRate, channels: channels))
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await runner.start(
            on: queue, sink: sink, interval: .milliseconds(10),
            prepare: { [self] in
                let firstPTS = clock()
                audio.withLock { audio in
                    audio.timeline = Timeline(firstPTS: firstPTS, startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
                    audio.activeDeviceUniqueID = audio.deviceUniqueID
                }
            }
        ) { [weak self] sink in
            self?.emitDueBlocks(to: sink)
        }
    }

    public func stop() async {
        await runner.stop()
        audio.withLock { $0.activeDeviceUniqueID = nil }
    }

    /// Delivers `didStopWithError` with `NSError(domain:code:)` on the start queue, after the blocks
    /// already queued, and emits nothing more until the next `start`.
    public func failNow(domain: String, code: Int) {
        runner.fail(trackID: trackID, error: NSError(domain: domain, code: code))
    }

    /// The blocks emitted from now on use this format; the timeline continues where it was.
    public func switchFormat(sampleRate: Double, channels: Int) {
        audio.withLock { audio in
            audio.sampleRate = sampleRate
            audio.channels = channels
        }
    }

    /// Emits every block whose nominal start time has been reached, so late timer ticks catch up.
    private func emitDueBlocks(to sink: any CaptureSink) {
        while let block = nextDueBlock() {
            let sample = SampleFactory.audioSample(
                pts: block.pts, frames: block.frames, sampleRate: block.sampleRate, channels: block.channels)
            sink.source(trackID, didOutput: sample)
        }
    }

    private func nextDueBlock() -> Block? {
        let now = DispatchTime.now().uptimeNanoseconds
        return audio.withLock { audio -> Block? in
            guard var timeline = audio.timeline else { return nil }
            let elapsed = Double(now - timeline.startUptimeNanoseconds) / 1_000_000_000
            guard timeline.emittedSeconds <= elapsed else { return nil }
            let frames = Int((audio.sampleRate / 100).rounded())
            let pts = timeline.firstPTS.adding(seconds: timeline.emittedSeconds * (1 + clockSkewPPM / 1_000_000))
            timeline.emittedSeconds += Double(frames) / audio.sampleRate
            audio.timeline = timeline
            return Block(pts: pts, frames: frames, sampleRate: audio.sampleRate, channels: audio.channels)
        }
    }
}

/// What the synthetic sources share: a `DispatchSourceTimer` on the start queue per run, a sink
/// retained only while the run lasts, injected start failures and on-demand stream errors.
private final class SyntheticRunner: Sendable {
    private struct Run: Sendable {
        let id: Int
        let timer: any DispatchSourceTimer
        let queue: DispatchSerialQueue
        let sink: any CaptureSink

        /// Cancels the timer and waits for the ticks already queued, which see the run gone.
        func end() async {
            timer.cancel()
            await queue.drain()
        }
    }

    private struct State {
        var startCount = 0
        var failOnStart = 0
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
    }

    private let state = Mutex(State())

    var startCount: Int { state.withLock { $0.startCount } }

    var failOnStart: Int {
        get { state.withLock { $0.failOnStart } }
        set { state.withLock { $0.failOnStart = newValue } }
    }

    deinit {
        state.withLock { $0.run }?.timer.cancel()
    }

    /// Ends the previous run, then either throws the injected failure or calls `prepare` and starts
    /// a timer that calls `tick` with the sink on `queue` every `interval` while this run lasts.
    func start(
        on queue: DispatchSerialQueue,
        sink: any CaptureSink,
        interval: DispatchTimeInterval,
        prepare: () -> Void = {},
        tick: @escaping @Sendable (any CaptureSink) -> Void
    ) async throws {
        let (id, previous, fails) = state.withLock { state in
            state.startCount += 1
            state.generation += 1
            let fails = state.failOnStart > 0
            if fails { state.failOnStart -= 1 }
            defer { state.run = nil }
            return (state.generation, state.run, fails)
        }
        if let previous { await previous.end() }
        if fails { throw NSError(domain: "Synthetic", code: -1) }

        prepare()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let sink = self?.sink(ifCurrent: id) else { return }
            tick(sink)
        }
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = Run(id: id, timer: timer, queue: queue, sink: sink)
            return true
        }
        guard installed else {
            // A suspended dispatch source must not be released: cancel it, then let it run.
            timer.cancel()
            timer.resume()
            throw CancellationError()
        }
        timer.resume()
    }

    func stop() async {
        let run = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return state.run
        }
        await run?.end()
    }

    /// Ends the current run with `error`, delivered on its queue after the ticks already queued.
    func fail(trackID: String, error: any Error) {
        guard let run = state.withLock({ $0.run }) else { return }
        run.queue.async { [self] in
            let ended = state.withLock { state in
                guard state.run?.id == run.id else { return nil as Run? }
                defer { state.run = nil }
                return state.run
            }
            guard let ended else { return }
            ended.timer.cancel()
            ended.sink.source(trackID, didStopWithError: error)
        }
    }

    private func sink(ifCurrent id: Int) -> (any CaptureSink)? {
        state.withLock { $0.run?.id == id ? $0.run?.sink : nil }
    }
}

extension DispatchSerialQueue {
    /// Returns once every block submitted to the queue before the call has run.
    fileprivate func drain() async {
        await withCheckedContinuation { continuation in
            self.async { continuation.resume() }
        }
    }
}
