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
    private let sessionQueue = DispatchQueue(label: "dev.toma.MicrophoneCaptureSource.session")
    private let state = Mutex(State())

    private struct State {
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        var activeDeviceUniqueID: String?
    }

    /// One `start`, until it is stopped or fails. `@unchecked Sendable` because the AVFoundation
    /// objects are not annotated: the session queue builds them and hands them to the state, and
    /// whoever ends the run takes them out and tears them down on the session queue. The sample
    /// callback only compares the output's identity and reads the session's clock.
    private struct Run: @unchecked Sendable {
        let id: Int
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        let observers: [any NSObjectProtocol]

        func tearDown() {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
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
        let (id, previous) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run)
        }
        if let previous { await end(previous) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [self] in
                continuation.resume(with: Result { try begin(id: id, queue: queue, sink: sink) })
            }
        }
    }

    public func stop() async {
        let run = state.withLock { state in
            state.generation += 1
            state.activeDeviceUniqueID = nil
            defer { state.run = nil }
            return state.run
        }
        if let run { await end(run) }
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
        let run = Run(id: id, session: session, output: output, queue: queue, sink: sink, observers: observers)
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = run
            state.activeDeviceUniqueID = device.uniqueID
            return true
        }
        guard installed else {
            run.tearDown()
            throw CancellationError()
        }

        session.startRunning()
        guard session.isRunning else {
            let mine = state.withLock { state in
                guard state.run?.id == id else { return false }
                state.run = nil
                return true
            }
            if mine { run.tearDown() }
            throw CaptureSourceError.sessionDidNotStart
        }
    }

    /// Tears the session down on the session queue and waits for deliveries already queued, which
    /// see the run gone and drop.
    private func end(_ run: Run) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                run.tearDown()
                continuation.resume()
            }
        }
        await run.queue.drain()
    }

    /// Ends the run `runID` with `error`, delivered on its queue after the samples already queued there.
    private func fail(runID: Int, error: any Error) {
        let queue = state.withLock { $0.run?.id == runID ? $0.run?.queue : nil }
        guard let queue else { return }
        queue.async { [self] in
            let ended = state.withLock { state in
                guard state.run?.id == runID else { return nil as Run? }
                defer { state.run = nil }
                return state.run
            }
            guard let ended else { return }
            ended.sink.source(trackID, didStopWithError: error)
            sessionQueue.async { ended.tearDown() }
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        preferredDeviceUniqueID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    /// Called on the queue given to `start`.
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let outputID = ObjectIdentifier(output)
        let run = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.output) == outputID ? $0 : nil }
        }
        guard let run else { return }
        let hostClock = CMClockGetHostTimeClock()
        let sessionClock = run.session.synchronizationClock ?? hostClock
        do {
            let retimed = try Self.retimed(sampleBuffer) { CMSyncConvertTime($0, from: sessionClock, to: hostClock) }
            run.sink.source(trackID, didOutput: retimed)
        } catch {
            fail(runID: run.id, error: error)
        }
    }

    /// A copy of `sample` whose presentation (and decode, if any) timestamps go through `convert`.
    static func retimed(_ sample: CMSampleBuffer, _ convert: (CMTime) -> CMTime) throws -> CMSampleBuffer {
        var timings = try sample.sampleTimingInfos()
        for i in timings.indices {
            timings[i].presentationTimeStamp = convert(timings[i].presentationTimeStamp)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = convert(timings[i].decodeTimeStamp)
            }
        }
        return try CMSampleBuffer(copying: sample, withNewTiming: timings)
    }
}
