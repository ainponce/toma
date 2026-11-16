// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import Dispatch
import Foundation
import ProjectFormat
import ScreenCaptureKit
import Synchronization
import os

/// What `DisplayCaptureSource` and `WindowCaptureSource` share: one `SCStream` per run, with the run life cycle of
/// `CaptureRunLifecycle`; the complete frames, to the run's sink; and the stream following the size of what it
/// captures.
///
/// A run's stream starts in its `start` and stops once, when the run ends: from the `start` or `stop` that comes next
/// or from the stream's own error (then it has stopped already), or, if the run ends while the stream is still
/// starting, from its own `start` as soon as it has started. `start` and `stop` wait for every `stopCapture` in flight,
/// so a stream that had started is stopped before the next one is made; `stopTimeLimit` at most: a ScreenCaptureKit
/// that never answers (replayd stuck) must not keep a take from closing. A stream still starting when its run ends is
/// not stopping yet, and the next run's stream can be made while it starts; it stops once started, and none of its
/// frames reaches a sink.
///
/// On each complete frame it reads the frame's geometry (`StreamFrameGeometry`). When `WindowStreamSizing.resize` asks
/// for another size (a window resized, a display whose resolution or proportion changed), the stream is given the
/// configuration `reconfiguration` makes for it, at most every 250 ms (`StreamResizeThrottle`); the frames that follow
/// have the new size, and the pipeline opens a `.formatChanged` segment.
final class ScreenStreamCapture: Sendable {
    /// What a run's stream captures, and how. `@unchecked Sendable`: `start`'s setup builds it, then it is only read.
    struct Setup: @unchecked Sendable {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    /// The configuration for a stream that should now be `size` pixels, asked for by a frame with `geometry`.
    typealias Reconfiguration = @Sendable (_ size: CGSize, _ geometry: StreamFrameGeometry) -> SCStreamConfiguration

    private let trackID: String
    private let scale: CaptureScale
    private let reconfiguration: Reconfiguration
    private let runs: CaptureRunLifecycle<StreamRun>
    /// Holds every `stopCapture` in flight: `start` and `stop` wait for it to empty.
    private let stopping = DispatchGroup()
    private let lastComplete = Mutex<HostTime?>(nil)

    fileprivate static let logger = Logger(subsystem: "dev.toma.Toma", category: "ScreenStreamCapture")
    /// How long `start` and `stop` wait for the `stopCapture` calls in flight; they take a fraction of a second.
    static let stopTimeLimit = Duration.seconds(3)

    init(trackID: String, scale: CaptureScale, reconfiguration: @escaping Reconfiguration) {
        self.trackID = trackID
        self.scale = scale
        self.reconfiguration = reconfiguration
        self.runs = CaptureRunLifecycle(trackID: trackID)
    }

    /// When the last complete frame arrived, on the host clock; `nil` before the first one. Kept across runs.
    var lastCompleteFrameTime: HostTime? { lastComplete.withLock { $0 } }

    // MARK: - Start and stop

    /// `CaptureSource.start`: `setup` says what the new run's stream captures; `output` is the source, which hands its
    /// `SCStreamOutput` and `SCStreamDelegate` calls to `output(_:didOutput:of:)` and `streamDidStop(_:error:)`.
    func start(
        on queue: DispatchSerialQueue, sink: any CaptureSink, output: some SCStreamOutput & SCStreamDelegate,
        setup: () async throws -> Setup
    ) async throws {
        // The previous run's stream, if any, stops (one still starting stops once its own `start` has started it);
        // the stops in flight and the deliveries already queued finish before this run's stream is made.
        let (id, lastQueue) = runs.beginStart()
        await waitForStops()
        await lastQueue?.drain()

        let setup = try await setup()
        let stream = SCStream(filter: setup.filter, configuration: setup.configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        let configured = CGSize(width: setup.configuration.width, height: setup.configuration.height)
        let run = StreamRun(stream: stream, configured: configured, stopping: stopping)
        guard runs.install(id: id, resource: run, queue: queue, sink: sink) else { throw CancellationError() }

        do {
            try await stream.startCapture()
        } catch {
            run.streamEnded()
            switch runs.finishStart(id: id, deviceUniqueID: nil, failure: error) {
            case .failed(let failure): throw failure
            case .started, .overtaken: throw CancellationError()
            }
        }
        // From here on the run's end stops the stream; if it ended while starting, it stops now.
        run.didStart()
        switch runs.finishStart(id: id, deviceUniqueID: nil, failure: nil) {
        case .started:
            return
        case .failed(let error):
            // The stream reported the error while starting, so it has stopped.
            throw error
        case .overtaken:
            // The `stop` or `start` that took this run ended it, and `didStart` stopped the stream.
            throw CancellationError()
        }
    }

    /// `CaptureSource.stop`.
    func stop() async {
        let lastQueue = runs.stop()
        // The run's stream has stopped (one still starting is stopped by its own `start` once it has started), and
        // deliveries already queued, an error included, have finished.
        await waitForStops()
        await lastQueue?.drain()
    }

    /// Gives the active run's stream `filter`. `false` when no run is active; throws what the stream refused.
    func updateContentFilter(_ filter: SCContentFilter) async throws -> Bool {
        guard let run = runs.activeRun() else { return false }
        try await run.resource.stream.updateContentFilter(filter)
        return true
    }

    /// Waits for the `stopCapture` calls in flight, `stopTimeLimit` at most; one that has not answered by then is
    /// logged and left behind.
    private func waitForStops() async {
        guard await Self.wait(for: stopping, atMost: Self.stopTimeLimit) else {
            Self.logger.error(
                "\(self.trackID, privacy: .public): stopCapture has not answered after \(Self.stopTimeLimit, privacy: .public); going on without it")
            return
        }
    }

    /// Waits until `group` is empty, `limit` at most: `false` when the limit came first.
    static func wait(for group: DispatchGroup, atMost limit: Duration) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                if once.claim() { continuation.resume(returning: true) }
            }
            let (seconds, attoseconds) = limit.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: - The stream's calls

    /// The source's `stream(_:didOutputSampleBuffer:of:)`, on the run's queue.
    func output(_ stream: SCStream, didOutput sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, ScreenCapture.isCompleteFrame(sample) else { return }
        let streamID = ObjectIdentifier(stream)
        guard let run = runs.activeRun(matching: { ObjectIdentifier($0.stream) == streamID }) else { return }
        lastComplete.withLock { $0 = HostTime.now() }
        if let geometry = StreamFrameGeometry(sample) { follow(geometry, run: run) }
        run.sink.source(trackID, didOutput: sample)
    }

    /// The source's `stream(_:didStopWithError:)`, on any queue: the run ends on its queue, after the frames already
    /// queued there.
    func streamDidStop(_ stream: SCStream, error: any Error) {
        let streamID = ObjectIdentifier(stream)
        guard let run = runs.activeRun(matching: { ObjectIdentifier($0.stream) == streamID }) else { return }
        run.resource.streamEnded()
        runs.fail(runID: run.id, error: error)
    }

    // MARK: - Following the content's size

    /// On the run's queue.
    private func follow(_ geometry: StreamFrameGeometry, run: CaptureRunLifecycle<StreamRun>.ActiveRun) {
        let pixelsPerPoint = ScreenCapture.recordedPixelScale(displayScale: geometry.scaleFactor, scale: scale) ?? 1
        let now = HostTime.now()
        let decision = run.resource.resizes.withLock { throttle in
            let size = WindowStreamSizing.resize(
                configured: throttle.configured, contentRect: geometry.contentRect, contentScale: geometry.contentScale,
                scaleFactor: pixelsPerPoint)
            return throttle.request(size.map { StreamResize(size: $0, geometry: geometry) }, now: now)
        }
        handle(decision, run: run)
    }

    private func handle(_ decision: StreamResizeThrottle.Decision, run: CaptureRunLifecycle<StreamRun>.ActiveRun) {
        switch decision {
        case .none:
            break
        case .apply(let resize):
            reconfigure(run.resource, to: resize)
        case .retry(let delay):
            let (seconds, attoseconds) = delay.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            run.queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [weak self, id = run.id] in
                self?.retryResize(runID: id)
            }
        }
    }

    /// On the run's queue.
    private func retryResize(runID: Int) {
        guard let run = runs.activeRun(), run.id == runID else { return }
        let decision = run.resource.resizes.withLock { $0.retryFired(now: HostTime.now()) }
        handle(decision, run: run)
    }

    private func reconfigure(_ run: StreamRun, to resize: StreamResize) {
        let configuration = reconfiguration(resize.size, resize.geometry)
        let size = CGSize(width: configuration.width, height: configuration.height)
        let previous = run.resizes.withLock { throttle in
            defer { throttle.applied(size, at: HostTime.now()) }
            return throttle.configured
        }
        Self.logger.notice(
            "\(self.trackID, privacy: .public) follows its content: \(Int(previous.width))×\(Int(previous.height)) to \(configuration.width)×\(configuration.height) px")
        run.stream.updateConfiguration(configuration) { [trackID] error in
            guard let error else { return }
            Self.logger.error("updateConfiguration failed for \(trackID, privacy: .public): \(error, privacy: .public)")
            run.resizes.withLock { $0.refused(size, previous: previous) }
        }
    }

    // MARK: - Configuration

    /// What every screen stream has: `width` × `height` pixels at the best resolution, BGRA in sRGB, at most
    /// `framesPerSecond`, a queue of 6, no cursor, no clicks and no audio.
    static func configuration(width: Int, height: Int, framesPerSecond: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        return configuration
    }
}

/// The first of several callers to `claim` it wins: a continuation that two callbacks race to resume is resumed once.
private final class ResumeOnce: Sendable {
    private let claimed = Mutex(false)

    /// `true` for the first call only.
    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

/// When a run's stream is stopped: once, and never before its `startCapture` has returned (a stream ended while
/// starting is stopped by its own `start`, once it has started).
struct StreamStopPhase: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// `startCapture` has not returned.
        case starting
        /// The run ended while starting: `didStart` stops the stream.
        case endRequested
        case capturing
        /// Stopped, being stopped, or never started.
        case ended
    }

    private(set) var phase = Phase.starting

    /// `startCapture` succeeded. `true`: stop the stream now, the run ended meanwhile.
    mutating func didStart() -> Bool {
        switch phase {
        case .starting:
            phase = .capturing
            return false
        case .endRequested:
            phase = .ended
            return true
        case .capturing, .ended:
            return false
        }
    }

    /// The run ended. `true`: stop the stream now.
    mutating func end() -> Bool {
        switch phase {
        case .starting:
            phase = .endRequested
            return false
        case .capturing:
            phase = .ended
            return true
        case .endRequested, .ended:
            return false
        }
    }

    /// `startCapture` failed, or the stream stopped with an error: there is nothing to stop.
    mutating func streamEnded() {
        phase = .ended
    }
}

/// A run's stream, and the size it follows. Ending the run stops the stream once (`StreamStopPhase`).
/// `@unchecked Sendable` because `SCStream` is not annotated: the stream's own calls only compare its identity, and
/// every change of state is under a lock.
final class StreamRun: CaptureRunResource, @unchecked Sendable {
    let stream: SCStream
    let resizes: Mutex<StreamResizeThrottle>
    private let phase = Mutex(StreamStopPhase())
    private let stopping: DispatchGroup

    init(stream: SCStream, configured: CGSize, stopping: DispatchGroup) {
        self.stream = stream
        self.resizes = Mutex(StreamResizeThrottle(configured: configured))
        self.stopping = stopping
    }

    /// `startCapture` succeeded. Stops the stream if the run ended meanwhile.
    func didStart() {
        if phase.withLock({ $0.didStart() }) { stopStream() }
    }

    /// `startCapture` failed, or the stream stopped with an error: there is nothing to stop.
    func streamEnded() {
        phase.withLock { $0.streamEnded() }
    }

    func end() {
        if phase.withLock({ $0.end() }) { stopStream() }
    }

    private func stopStream() {
        stopping.enter()
        stream.stopCapture { [stopping] error in
            if let error {
                ScreenStreamCapture.logger.error("stopCapture failed: \(error, privacy: .public)")
            }
            stopping.leave()
        }
    }
}
