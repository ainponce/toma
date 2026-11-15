// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Synchronization

/// Captures a microphone in its native format (every channel, no conversion) and re-times its
/// samples on the host clock.
public final class MicrophoneCaptureSource: NSObject, CaptureSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let trackID = "mic"
    public let kind = TrackKind.microphone
    public let media = TrackMedia.audio

    private let preferredDeviceUniqueID: String?
    /// Session setup, `startRunning` (which blocks) and teardown happen here, one at a time.
    private let sessionQueue = DispatchSerialQueue(label: "dev.toma.MicrophoneCaptureSource.session")
    private let state = Mutex(State())

    private struct State {
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        /// Queue of the last run installed. Kept when the run ends, so `start` and `stop` can wait
        /// for a delivery still running there, such as the error that ended it.
        var lastQueue: DispatchSerialQueue?
        var activeDeviceUniqueID: String?
    }

    /// The AVFoundation side of a run. `@unchecked Sendable` because those objects are not
    /// annotated: the session queue builds them, the state holds them, and whoever ends the run
    /// tears them down on the session queue. The sample callback only compares the output's
    /// identity and reads the session's clock.
    private struct Capture: @unchecked Sendable {
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let observers: [any NSObjectProtocol]

        func tearDown() {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// One `start`, until it is stopped or fails.
    private struct Run: Sendable {
        let id: Int
        let capture: Capture
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        /// Set once the session runs and `start` is about to return successfully.
        var started = false
        /// An error before `started`, which `start` throws instead of delivering.
        var failure: (any Error)?
    }

    private enum StartOutcome {
        case started
        case failed(any Error)
        case overtaken
    }

    /// `nil` captures the default input. A preferred device that is not connected when `start` runs
    /// (including a restart) falls back to the default input.
    public init(preferredDeviceUniqueID: String?) {
        self.preferredDeviceUniqueID = preferredDeviceUniqueID
        super.init()
    }

    public var activeDeviceUniqueID: String? { state.withLock { $0.activeDeviceUniqueID } }

    /// The active device while running, otherwise the device `start` would pick.
    public var sourceInfo: TrackSource {
        let active = state.withLock { $0.activeDeviceUniqueID }
        guard let device = active.flatMap(AVCaptureDevice.init(uniqueID:)) ?? resolveDevice() else {
            return TrackSource(name: "Microphone")
        }
        return TrackSource(name: device.localizedName, deviceUniqueID: device.uniqueID)
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        let (id, previous, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue)
        }
        if let previous {
            let capture = previous.capture
            sessionQueue.async { capture.tearDown() }
        }
        await lastQueue?.drain()
        // Runs after any teardown already queued, so two sessions never overlap.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [self] in
                continuation.resume(with: Result { try begin(id: id, queue: queue, sink: sink) })
            }
        }
    }

    public func stop() async {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            state.activeDeviceUniqueID = nil
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        if let run {
            let capture = run.capture
            sessionQueue.async { capture.tearDown() }
        }
        // The session is torn down (a `start` in progress included, which then throws
        // `CancellationError`), and deliveries already queued, an error included, have finished.
        await sessionQueue.drain()
        await lastQueue?.drain()
    }

    /// Builds and starts the session. Runs on `sessionQueue`.
    private func begin(id: Int, queue: DispatchSerialQueue, sink: any CaptureSink) throws {
        guard let device = resolveDevice() else { throw CaptureSourceError.microphoneNotFound }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()  // No `audioSettings`: native format, every channel.
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureSourceError.sessionConfigurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)

        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.fail(runID: id, error: error ?? AVError(.unknown))
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
                [weak self] _ in
                self?.fail(runID: id, error: AVError(.deviceWasDisconnected))
            },
        ]
        let capture = Capture(session: session, output: output, observers: observers)
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

        session.startRunning()
        let running = session.isRunning
        let outcome = state.withLock { state -> StartOutcome in
            guard var run = state.run, run.id == id else { return .overtaken }
            if let failure = run.failure {
                state.run = nil
                return .failed(failure)
            }
            guard running else {
                state.run = nil
                return .failed(CaptureSourceError.sessionDidNotStart)
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
            // The `stop` or `start` that took this run queued its teardown after this call.
            throw CancellationError()
        }
    }

    /// From any thread: handled on the run's queue, after the samples already queued there.
    private func fail(runID: Int, error: any Error) {
        let queue = state.withLock { $0.run?.id == runID ? $0.run?.queue : nil }
        queue?.async { [self] in failOnQueue(runID: runID, error: error) }
    }

    /// Runs on the run's queue. Before `start` has succeeded the error is kept for `start` to throw;
    /// afterwards the run ends: its teardown is queued first, so a restart from inside the sink
    /// cannot overlap the old session, then the error is the run's last delivery.
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
        let capture = ended.capture
        sessionQueue.async { capture.tearDown() }
        ended.sink.source(trackID, didStopWithError: error)
    }

    private func resolveDevice() -> AVCaptureDevice? {
        preferredDeviceUniqueID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    /// Called on the queue given to `start`.
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let outputID = ObjectIdentifier(output)
        let run = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.capture.output) == outputID && $0.failure == nil ? $0 : nil }
        }
        guard let run else { return }
        do {
            let retimed = try CaptureClock.retimed(sampleBuffer, from: run.capture.session.synchronizationClock)
            run.sink.source(trackID, didOutput: retimed)
        } catch {
            // Already on the run's queue: end the run now, so no later sample goes out before the error.
            failOnQueue(runID: run.id, error: error)
        }
    }
}
