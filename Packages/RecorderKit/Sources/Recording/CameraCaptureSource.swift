// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Synchronization

/// Records a camera through the shared `CameraSessionHost`, in `420v`, re-timing its frames on the host clock.
///
/// Each run holds a lease `forRecording` (which keeps the session's camera and format until the run ends) and
/// gets the session's frames on the pipeline's queue. The run ends, with `source(_:didStopWithError:)`, when
/// the camera is disconnected (`.cameraDisconnected`), when the session reports an error, and, as
/// `.cameraInterrupted`, when another app takes the camera, when the session stops running, or when the camera
/// is suspended (the lid is closed, the privacy iris too): the restart policy then brings the camera back, or
/// moves to the system's preferred one, instead of leaving the track without frames. Every run ends its lease
/// before the next one asks for another, so a restart picks the camera again (`CameraCatalog.pick`); the
/// bubble's lease, if any, keeps the session running meanwhile.
public final class CameraCaptureSource: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let trackID = "camera"
    public let kind = TrackKind.camera
    public let media: TrackMedia

    /// What ended a run besides a session error.
    enum StopCause: Equatable {
        /// The camera was disconnected.
        case disconnected
        /// The session was interrupted: another app took the camera.
        case interrupted
        /// The session stopped running.
        case stoppedRunning
        /// The camera was suspended: the lid was closed, or its privacy iris.
        case suspended
    }

    private let host: CameraSessionHost
    private let preferredDeviceUniqueID: String?
    private let preset: CameraPreset
    private let framesPerSecond: Int
    private let state = Mutex(State())

    private struct State {
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        /// Queue of the last run installed. Kept when the run ends, so `start` and `stop` can wait for a
        /// delivery still running there, such as the error that ended it.
        var lastQueue: DispatchSerialQueue?
        /// Kept here, not read from the host: once the run's lease ends, the host may capture another camera
        /// for the bubble.
        var activeDeviceUniqueID: String?
    }

    /// A run's hold on the camera: its lease and what watches the camera. `@unchecked Sendable` because the
    /// observers and the key-value observation are not annotated; whoever ends the run tears them down, once.
    private struct Capture: @unchecked Sendable {
        let lease: CameraLease
        let observers: [any NSObjectProtocol]
        let suspension: NSKeyValueObservation

        func tearDown() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            suspension.invalidate()
            // Lets go of the output's delegate and, if it was the last lease, stops the session: on the host's
            // queue, before any later lease.
            lease.end()
        }
    }

    /// One `start`, until it is stopped or fails.
    private struct Run: Sendable {
        let id: Int
        let capture: Capture
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        /// Set once `start` is about to return successfully.
        var started = false
        /// An error before `started`, which `start` throws instead of delivering.
        var failure: (any Error)?
    }

    private enum StartOutcome {
        case started
        case failed(any Error)
        case overtaken
    }

    /// `nil` records the system's preferred camera. A preferred camera that is not connected when `start` runs
    /// (a restart included) falls back like `CameraCatalog.pick`.
    public init(host: CameraSessionHost, preferredDeviceUniqueID: String?, preset: CameraPreset = .p1080, framesPerSecond: Int = 30) {
        self.host = host
        self.preferredDeviceUniqueID = preferredDeviceUniqueID
        self.preset = preset
        self.framesPerSecond = framesPerSecond
        self.media = .video(framesPerSecond: framesPerSecond)
        super.init()
    }

    /// The error that ends a run for `cause`; `nil` when no run is active, so nothing is ended.
    static func stopError(for cause: StopCause, runActive: Bool) -> CaptureSourceError? {
        guard runActive else { return nil }
        switch cause {
        case .disconnected: return .cameraDisconnected
        case .interrupted, .stoppedRunning, .suspended: return .cameraInterrupted
        }
    }

    public var activeDeviceUniqueID: String? { state.withLock { $0.activeDeviceUniqueID } }

    /// The active camera while running, otherwise the camera `start` would pick.
    public var sourceInfo: TrackSource {
        if let active = state.withLock({ $0.activeDeviceUniqueID }) {
            return TrackSource(name: AVCaptureDevice(uniqueID: active)?.localizedName ?? "Camera", deviceUniqueID: active)
        }
        guard let camera = try? CameraCatalog.resolve(preferred: preferredDeviceUniqueID).info else {
            return TrackSource(name: "Camera")
        }
        return TrackSource(name: camera.name, deviceUniqueID: camera.uniqueID)
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        let (id, previous, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue)
        }
        previous?.capture.tearDown()
        // The previous run's lease has ended and the output has no delegate (on the host's queue); then what it
        // had already queued here has run, and found no run: nothing of it reaches this one.
        await host.drain()
        await lastQueue?.drain()

        // Asked on the host's queue right before the lease is given: a `stop` or `start` that came meanwhile (during
        // the waits above, say) has the last word, and the camera is not turned on for nothing.
        let lease = try await host.lease(
            preferredDeviceUniqueID: preferredDeviceUniqueID, preset: preset, framesPerSecond: framesPerSecond,
            forRecording: true, delivery: CameraSessionHost.SampleDelivery(delegate: self, queue: queue),
            isWanted: { [weak self] in self?.state.withLock { $0.generation == id } ?? false })
        let device = lease.device
        let suspension = device.observe(\.isSuspended, options: [.new]) { [weak self] device, _ in
            if device.isSuspended { self?.end(runID: id, cause: .suspended) }
        }
        let capture = Capture(lease: lease, observers: observers(runID: id, device: device), suspension: suspension)
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = Run(id: id, capture: capture, queue: queue, sink: sink)
            state.lastQueue = queue
            return true
        }
        guard installed else {
            capture.tearDown()
            throw CancellationError()
        }

        // What happened before the observers were there, they did not hear.
        let missed = Self.stopCause(device: device, session: host.session)
        let outcome = state.withLock { state -> StartOutcome in
            guard var run = state.run, run.id == id else { return .overtaken }
            if let failure = run.failure ?? missed.flatMap({ Self.stopError(for: $0, runActive: true) }) {
                state.run = nil
                return .failed(failure)
            }
            run.started = true
            state.run = run
            state.activeDeviceUniqueID = device.uniqueID
            return .started
        }
        switch outcome {
        case .started:
            return
        case .failed(let error):
            capture.tearDown()
            throw error
        case .overtaken:
            // The `stop` or `start` that took this run tore it down.
            throw CancellationError()
        }
    }

    public func stop() async {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            state.activeDeviceUniqueID = nil
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        run?.capture.tearDown()
        // The run's lease has ended and the output has no delegate, and deliveries already queued, an error
        // included, have finished. A `start` in progress whose lease the host has not given yet gets none (the
        // host asks it, on its queue, whether it is still wanted); one whose lease was already given ends it as
        // soon as it sees this stop, which may be after this returns: it then throws `CancellationError`, and none
        // of its frames reaches a sink.
        await host.drain()
        await lastQueue?.drain()
    }

    /// Why the camera gives no frames now, if it does not.
    private static func stopCause(device: AVCaptureDevice, session: AVCaptureSession) -> StopCause? {
        if !device.isConnected { return .disconnected }
        if device.isSuspended { return .suspended }
        if !session.isRunning { return .stoppedRunning }
        return nil
    }

    /// What ends run `runID`, heard from any thread.
    private func observers(runID id: Int, device: AVCaptureDevice) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        let session = host.session
        return [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.fail(runID: id, error: error ?? AVError(.unknown))
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
                [weak self] _ in
                self?.end(runID: id, cause: .disconnected)
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
                [weak self] _ in
                self?.end(runID: id, cause: .interrupted)
            },
            center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) {
                [weak self] _ in
                // A late notice of a stop from before this run (the session runs again since) is not this run's.
                guard let self, !self.host.session.isRunning else { return }
                end(runID: id, cause: .stoppedRunning)
            },
        ]
    }

    /// From any thread: ends run `runID` for `cause`, if it is the active run.
    private func end(runID: Int, cause: StopCause) {
        let active = state.withLock { $0.run?.id == runID }
        guard let error = Self.stopError(for: cause, runActive: active) else { return }
        fail(runID: runID, error: error)
    }

    /// From any thread: handled on the run's queue, after the frames already queued there.
    private func fail(runID: Int, error: any Error) {
        let queue = state.withLock { $0.run?.id == runID ? $0.run?.queue : nil }
        queue?.async { [self] in failOnQueue(runID: runID, error: error) }
    }

    /// Runs on the run's queue. Before `start` has succeeded the error is kept for `start` to throw; afterwards
    /// the run ends: its lease ends first (on the host's queue, before the lease of a restart from inside the
    /// sink), then the error is the run's last delivery.
    private func failOnQueue(runID: Int, error: any Error) {
        let ended = state.withLock { state -> Run? in
            guard var run = state.run, run.id == runID, run.failure == nil else { return nil }
            guard run.started else {
                run.failure = error
                state.run = run
                return nil
            }
            state.run = nil
            return run
        }
        guard let ended else { return }
        ended.capture.tearDown()
        ended.sink.source(trackID, didStopWithError: error)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    /// Called on the queue given to `start`.
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let run = state.withLock { state in state.run.flatMap { $0.failure == nil ? $0 : nil } }
        guard let run else { return }
        do {
            let retimed = try CaptureClock.retimed(sampleBuffer, from: host.session.synchronizationClock)
            run.sink.source(trackID, didOutput: retimed)
        } catch {
            // Already on the run's queue: end the run now, so no later frame goes out before the error.
            failOnQueue(runID: run.id, error: error)
        }
    }
}
