// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Dispatch
import ProjectFormat

/// Records the screen of an iPhone or iPad connected by cable (a `device` track): the video of its
/// `ExternalDeviceSession`, in `420v` at the device's own size, encoded HEVC at `framesPerSecond`, its frames re-timed
/// on the host clock. Its sound is an `ExternalDeviceAudioSource` made from this source, on the same session.
///
/// A run ends with `source(_:didStopWithError:)` when the cable is pulled (`.deviceDisconnected`), when the session is
/// interrupted or stops running (`.deviceInterrupted`) or reports an error; the restart policy brings it back with
/// the same device only (`.deviceNotFound(uniqueID:)` while it is away). Turning the device changes the size of its
/// frames: the pipeline goes on in a new segment.
public final class ExternalDeviceCaptureSource: CaptureSource {
    public let trackID = "device"
    public let kind = TrackKind.device
    public let media: TrackMedia
    private let runs: ExternalDeviceRuns

    /// The device `deviceUniqueID` (`ExternalDeviceInfo.uniqueID`), through a session of its own.
    public convenience init(deviceUniqueID: String, framesPerSecond: Int = 60) {
        self.init(session: ExternalDeviceSession(deviceUniqueID: deviceUniqueID), framesPerSecond: framesPerSecond)
    }

    init(session: ExternalDeviceSession, framesPerSecond: Int = 60) {
        media = .video(framesPerSecond: framesPerSecond)
        runs = ExternalDeviceRuns(session: session, output: .video, trackID: "device")
    }

    /// The session this source and its sound share.
    var session: ExternalDeviceSession { runs.session }

    public var activeDeviceUniqueID: String? { runs.activeDeviceUniqueID }

    /// The device's name and `uniqueID`, with `globalFrame` (0, 0, width, height) in pixels at `pixelScale` 1: the size
    /// the active run started with, otherwise the size the device has now (what a take records as it starts). Without
    /// the device, no frame.
    public var sourceInfo: TrackSource {
        (runs.activeFormat ?? session.describe() ?? .unknown).trackSource(uniqueID: session.deviceUniqueID)
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await runs.start(on: queue, sink: sink)
    }

    public func stop() async {
        await runs.stop()
    }
}

/// The runs of one source of an iPhone or iPad: each run leases its output of the shared `ExternalDeviceSession`, and
/// ends when the capture stops by itself. The run life cycle is `CaptureRunLifecycle`'s.
final class ExternalDeviceRuns: Sendable {
    let session: ExternalDeviceSession
    private let output: ExternalDeviceSession.Output
    private let trackID: String
    private let runs: CaptureRunLifecycle<ExternalDeviceLease>

    init(session: ExternalDeviceSession, output: ExternalDeviceSession.Output, trackID: String) {
        self.session = session
        self.output = output
        self.trackID = trackID
        self.runs = CaptureRunLifecycle(trackID: trackID)
    }

    var activeDeviceUniqueID: String? { runs.activeDeviceUniqueID }

    /// What the active run's lease captured when it was given; `nil` without an active run.
    var activeFormat: ExternalDeviceFormat? { runs.activeRun()?.resource.format }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        // The previous run, if any, ends: its lease ends on the session's queue, and its output delivers nowhere;
        // then what it had already queued here has run, and found no run.
        let (id, lastQueue) = runs.beginStart()
        await session.drain()
        await lastQueue?.drain()

        // Asked on the session's queue right before the lease is given: a `stop` or `start` that came meanwhile has
        // the last word, and the device is not turned on for nothing.
        let delivery = ExternalDeviceSession.Delivery(queue: queue) { [weak self] sample in self?.receive(sample, run: id) }
        let lease = try await session.lease(
            output, delivery: delivery, onStop: { [weak self] error in self?.runs.fail(runID: id, error: error) },
            isWanted: { [weak self] in self?.runs.isLatest(id) ?? false })
        guard runs.install(id: id, resource: lease, queue: queue, sink: sink) else {
            lease.end()
            throw CancellationError()
        }

        // What stopped the capture before the lease was there to hear it.
        let outcome = runs.finishStart(id: id, deviceUniqueID: session.deviceUniqueID, failure: session.currentStopError())
        switch outcome {
        case .started:
            return
        case .failed(let error):
            lease.end()
            throw error
        case .overtaken:
            // The `stop` or `start` that took this run ended its lease.
            throw CancellationError()
        }
    }

    func stop() async {
        let lastQueue = runs.stop()
        // The run's lease has ended and its output delivers nowhere, and deliveries already queued, an error included,
        // have finished. A `start` in progress whose lease the session has not given yet gets none; one whose lease
        // was already given ends it as soon as it sees this stop, and then throws `CancellationError`.
        await session.drain()
        await lastQueue?.drain()
    }

    /// On run `id`'s queue.
    private func receive(_ sample: CMSampleBuffer, run id: Int) {
        guard let delivery = runs.delivery(forRun: id) else { return }
        do {
            let retimed = try CaptureClock.retimed(sample, from: session.clock)
            delivery.sink.source(trackID, didOutput: retimed)
        } catch {
            // Already on the run's queue: end the run now, so no later sample goes out before the error.
            runs.failOnQueue(runID: id, error: error)
        }
    }
}
