// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat

/// Captures a microphone in its native format (every channel, no conversion) and re-times its
/// samples on the host clock.
public final class MicrophoneCaptureSource: NSObject, CaptureSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let trackID = "mic"
    public let kind = TrackKind.microphone
    public let media = TrackMedia.audio

    private let preferredDeviceUniqueID: String?
    /// Session setup, `startRunning` (which blocks) and teardown happen here, one at a time.
    private let sessionQueue = DispatchSerialQueue(label: "dev.toma.MicrophoneCaptureSource.session")
    private let runs = CaptureRunLifecycle<Capture>(trackID: "mic")

    /// The AVFoundation side of a run. `@unchecked Sendable` because those objects are not
    /// annotated: the session queue builds them, the run holds them, and whoever ends the run
    /// tears them down on the session queue. The sample callback only compares the output's
    /// identity and reads the session's clock.
    private struct Capture: CaptureRunResource, @unchecked Sendable {
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let observers: [any NSObjectProtocol]
        let sessionQueue: DispatchSerialQueue

        func tearDown() {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        /// Tears it down on the session queue, after anything already queued there.
        func end() {
            sessionQueue.async { tearDown() }
        }
    }

    /// `nil` captures the default input. A preferred device that is not connected when `start` runs
    /// (including a restart) falls back to the default input.
    public init(preferredDeviceUniqueID: String?) {
        self.preferredDeviceUniqueID = preferredDeviceUniqueID
        super.init()
    }

    public var activeDeviceUniqueID: String? { runs.activeDeviceUniqueID }

    /// The active device while running, otherwise the device `start` would pick.
    public var sourceInfo: TrackSource {
        let active = runs.activeDeviceUniqueID
        guard let device = active.flatMap(AVCaptureDevice.init(uniqueID:)) ?? resolveDevice() else {
            return TrackSource(name: "Microphone")
        }
        return TrackSource(name: device.localizedName, deviceUniqueID: device.uniqueID)
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        // The previous run, if any, is torn down on the session queue.
        let (id, lastQueue) = runs.beginStart()
        await lastQueue?.drain()
        // Runs after any teardown already queued, so two sessions never overlap.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [self] in
                continuation.resume(with: Result { try begin(id: id, queue: queue, sink: sink) })
            }
        }
    }

    public func stop() async {
        let lastQueue = runs.stop()
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
                self?.runs.fail(runID: id, error: error ?? AVError(.unknown))
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
                [weak self] _ in
                self?.runs.fail(runID: id, error: AVError(.deviceWasDisconnected))
            },
        ]
        let capture = Capture(session: session, output: output, observers: observers, sessionQueue: sessionQueue)
        guard runs.install(id: id, resource: capture, queue: queue, sink: sink) else {
            capture.tearDown()
            throw CancellationError()
        }

        session.startRunning()
        let running = session.isRunning
        let outcome = runs.finishStart(
            id: id, deviceUniqueID: device.uniqueID, failure: running ? nil : CaptureSourceError.sessionDidNotStart)
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

    private func resolveDevice() -> AVCaptureDevice? {
        preferredDeviceUniqueID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    /// Called on the queue given to `start`.
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let outputID = ObjectIdentifier(output)
        guard let run = runs.activeRun(matching: { ObjectIdentifier($0.output) == outputID }) else { return }
        do {
            let retimed = try CaptureClock.retimed(sampleBuffer, from: run.resource.session.synchronizationClock)
            run.sink.source(trackID, didOutput: retimed)
        } catch {
            // Already on the run's queue: end the run now (its teardown queued first, so a restart from inside the
            // sink cannot overlap the old session), and no later sample goes out before the error.
            runs.failOnQueue(runID: run.id, error: error)
        }
    }
}
