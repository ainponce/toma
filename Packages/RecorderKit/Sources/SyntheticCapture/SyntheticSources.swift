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
        /// PTS of the last frame emitted, by any run.
        var lastPTS: HostTime?
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

    /// The PTS is `clock()`, moved past the previous frame's if needed, so PTS keep increasing across
    /// restarts even with a clock that stalls or goes back.
    private func emitFrame(to sink: any CaptureSink) {
        let now = clock()
        let frame = frames.withLock { frames -> (index: Int, pts: HostTime)? in
            guard !frames.paused else { return nil }
            let pts = frames.lastPTS.map { max(now, HostTime(nanoseconds: $0.nanoseconds + 1)) } ?? now
            defer {
                frames.nextIndex += 1
                frames.lastPTS = pts
            }
            return (frames.nextIndex, pts)
        }
        guard let frame else { return }
        sink.source(
            trackID,
            didOutput: SampleFactory.videoSample(width: width, height: height, pts: frame.pts, frameIndex: frame.index))
    }
}

/// A fake microphone: 10 ms blocks of `SampleFactory` audio, paced in real time. The first block
/// is stamped with `clock()` at `start` (or where the previous run ended, if that is later, so PTS
/// never go back across a restart); each block moves the next PTS by
/// `frames / sampleRate × (1 + clockSkewPPM / 1e6)`, like a device clock that drifts from the host's.
/// `sampleRate` must be at least 100 Hz, so a 10 ms block has at least one frame.
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

        /// PTS of the next block, which is also where the last block emitted ends.
        func nextPTS(clockSkewPPM: Double) -> HostTime {
            firstPTS.adding(seconds: emittedSeconds * (1 + clockSkewPPM / 1_000_000))
        }
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
        Self.checkFormat(sampleRate: sampleRate, channels: channels)
        self.trackID = trackID
        self.clockSkewPPM = clockSkewPPM
        self.clock = clock
        self.audio = Mutex(Audio(sampleRate: sampleRate, channels: channels))
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await runner.start(
            on: queue, sink: sink, interval: .milliseconds(10),
            onInstall: { [self] in
                let now = clock()
                audio.withLock { audio in
                    let previousEnd = audio.timeline?.nextPTS(clockSkewPPM: clockSkewPPM)
                    audio.timeline = Timeline(
                        firstPTS: max(now, previousEnd ?? now),
                        startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
                    audio.activeDeviceUniqueID = audio.deviceUniqueID
                }
            }
        ) { [weak self] sink in
            self?.emitDueBlocks(to: sink)
        }
    }

    public func stop() async {
        await runner.stop { [self] in
            audio.withLock { $0.activeDeviceUniqueID = nil }
        }
    }

    /// Delivers `didStopWithError` with `NSError(domain:code:)` on the start queue, after the blocks
    /// already queued, and emits nothing more until the next `start`.
    public func failNow(domain: String, code: Int) {
        runner.fail(trackID: trackID, error: NSError(domain: domain, code: code))
    }

    /// The blocks emitted from now on use this format; the timeline continues where it was.
    public func switchFormat(sampleRate: Double, channels: Int) {
        Self.checkFormat(sampleRate: sampleRate, channels: channels)
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
            // Signed: a restart may have set the start after `now` was read.
            let elapsedNanoseconds = Int64(bitPattern: now &- timeline.startUptimeNanoseconds)
            guard timeline.emittedSeconds <= Double(elapsedNanoseconds) / 1_000_000_000 else { return nil }
            let frames = Int((audio.sampleRate / 100).rounded())
            let pts = timeline.nextPTS(clockSkewPPM: clockSkewPPM)
            timeline.emittedSeconds += Double(frames) / audio.sampleRate
            audio.timeline = timeline
            return Block(pts: pts, frames: frames, sampleRate: audio.sampleRate, channels: audio.channels)
        }
    }

    private static func checkFormat(sampleRate: Double, channels: Int) {
        precondition(
            sampleRate >= 100 && channels > 0,
            "SyntheticAudioSource: \(sampleRate) Hz × \(channels) channels gives empty 10 ms blocks")
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
    }

    private struct State {
        var startCount = 0
        var failOnStart = 0
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        /// Queue of the last run installed. Kept when the run ends, so `start` and `stop` can wait
        /// for a delivery still running there, such as the error that ended it.
        var lastQueue: DispatchSerialQueue?
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

    /// Ends the previous run and waits for its deliveries, then either throws the injected failure
    /// or starts a timer that calls `tick` with the sink on `queue` every `interval` while this run
    /// lasts. `onInstall` runs under the lock that installs the run.
    func start(
        on queue: DispatchSerialQueue,
        sink: any CaptureSink,
        interval: DispatchTimeInterval,
        onInstall: () -> Void = {},
        tick: @escaping @Sendable (any CaptureSink) -> Void
    ) async throws {
        let (id, previous, lastQueue, fails) = state.withLock { state in
            state.startCount += 1
            state.generation += 1
            let fails = state.failOnStart > 0
            if fails { state.failOnStart -= 1 }
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue, fails)
        }
        previous?.timer.cancel()
        await lastQueue?.drain()
        if fails { throw NSError(domain: "Synthetic", code: -1) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let sink = self?.sink(ifCurrent: id) else { return }
            tick(sink)
        }
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = Run(id: id, timer: timer, queue: queue, sink: sink)
            state.lastQueue = queue
            onInstall()
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

    /// Ends the current run, if any, and waits for the deliveries already queued (an error being
    /// delivered included). `onStop` runs under the lock that ends the run.
    func stop(onStop: () -> Void = {}) async {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            onStop()
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        run?.timer.cancel()
        await lastQueue?.drain()
    }

    /// Ends the current run with `error`, delivered on its queue after the ticks already queued.
    func fail(trackID: String, error: any Error) {
        guard let (id, queue) = state.withLock({ state in state.run.map { ($0.id, $0.queue) } }) else { return }
        queue.async { [self] in
            let ended = state.withLock { state -> Run? in
                guard state.run?.id == id else { return nil }
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
