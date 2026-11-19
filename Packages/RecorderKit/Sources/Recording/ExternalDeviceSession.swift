// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Synchronization

/// What an iPhone or iPad gives to record: its name and the size of its screen.
struct ExternalDeviceFormat: Equatable, Sendable {
    struct PixelSize: Equatable, Sendable {
        var width: Int
        var height: Int
    }

    var name: String
    /// In pixels; `nil` when the device does not tell it.
    var pixelSize: PixelSize?

    /// A device that is not connected: its name and size are not known.
    static let unknown = ExternalDeviceFormat(name: "iPhone or iPad", pixelSize: nil)

    /// The `source` of the device's screen track (plan decision 17): its name, its `uniqueID` and, with its size,
    /// `globalFrame` (0, 0, width, height) in pixels at `pixelScale` 1, so `ScreenGeometry` places it as it is.
    func trackSource(uniqueID: String) -> TrackSource {
        TrackSource(
            name: name, deviceUniqueID: uniqueID,
            globalFrame: pixelSize.map { Rect(x: 0, y: 0, width: Double($0.width), height: Double($0.height)) },
            pixelScale: pixelSize == nil ? nil : 1)
    }
}

/// The capture an `ExternalDeviceSession` drives: an `AVCaptureSession` with the device (`CaptureSessionEngine`),
/// or a fake in tests. `prepare`, `setDelivery` and `stop` are called one at a time, on the session's queue; the
/// others from any thread.
protocol ExternalDeviceEngine: AnyObject, Sendable {
    /// Whether it captures now.
    var isRunning: Bool { get }
    /// The clock of the samples it delivers; `nil` is the host clock.
    var clock: CMClock? { get }
    /// `handler` is told, from any thread, each time the capture stops by itself.
    func setOnStop(_ handler: @escaping @Sendable (ExternalDeviceSession.StopCause) -> Void)
    /// The device as it would be captured now; `nil` when it is not connected.
    func describe() -> ExternalDeviceFormat?
    /// Makes it capture the device, running, with `output` in it: as it is if it already does, with the device
    /// connected; otherwise with the device found again by its `uniqueID`, never another one. Returns what it
    /// captures. Throws `CaptureSourceError` (`.deviceNotFound`, `.sessionConfigurationFailed`,
    /// `.sessionDidNotStart`) or the device's own error (no camera permission, say).
    func prepare(for output: ExternalDeviceSession.Output) throws -> ExternalDeviceFormat
    /// Where the samples of `output` go from now on; `nil`, nowhere.
    func setDelivery(_ delivery: ExternalDeviceSession.Delivery?, for output: ExternalDeviceSession.Output)
    /// Stops capturing.
    func stop()
    /// Why it gives no samples now, if it does not: what a run that is starting could not hear.
    func currentStopCause() -> ExternalDeviceSession.StopCause?
}

/// The one capture of an iPhone or iPad connected by cable, shared by its screen (`ExternalDeviceCaptureSource`) and
/// its sound (`ExternalDeviceAudioSource`): an `AVCaptureSession` with the device, a video output in `420v` at the
/// device's own size and an audio output in the device's own format.
///
/// Each source holds a lease on its output while a run of it records. The session runs while there is a lease (the
/// first one starts it, the last one stops it), and each lease gets its output's samples on the queue it gave. When
/// the capture stops by itself (the cable is pulled, the session is interrupted, stops or fails) every lease is
/// told, so both runs end, and the restart policy brings them back: the first new lease finds the same device
/// again by its `uniqueID`, never another one.
///
/// Leases are given and ended on a serial queue of the session's own (`startRunning()` blocks).
final class ExternalDeviceSession: Sendable {
    enum Output: Hashable, Sendable {
        case video
        case audio
    }

    /// What ended the capture without a lease asking.
    enum StopCause: Equatable, Sendable {
        /// The device was disconnected.
        case disconnected
        /// The session was interrupted.
        case interrupted
        /// The session stopped running.
        case stoppedRunning
        /// The session reported an error (`AVCaptureSession.runtimeErrorNotification`).
        case failed(NSError)
    }

    /// Where a lease's samples go.
    struct Delivery: Sendable {
        let queue: DispatchSerialQueue
        /// Called on `queue`.
        let receive: @Sendable (CMSampleBuffer) -> Void
    }

    let deviceUniqueID: String
    private let engine: any ExternalDeviceEngine
    private let queue = DispatchSerialQueue(label: "dev.toma.ExternalDeviceSession")
    /// Changed only on `queue`; read anywhere.
    private let state = Mutex(State())

    private struct State {
        var counter = CameraLeaseCounter()
        var nextLeaseID = 0
        /// The live leases.
        var leases: [Int: Holder] = [:]
        /// The lease whose delivery each output has.
        var deliveryLease: [Output: Int] = [:]
    }

    /// A live lease: its output and who to tell when the capture stops by itself.
    private struct Holder: Sendable {
        let output: Output
        let onStop: @Sendable (any Error) -> Void
    }

    /// The device `deviceUniqueID`, through an `AVCaptureSession`.
    convenience init(deviceUniqueID: String) {
        self.init(deviceUniqueID: deviceUniqueID, engine: CaptureSessionEngine(deviceUniqueID: deviceUniqueID))
    }

    init(deviceUniqueID: String, engine: any ExternalDeviceEngine) {
        self.deviceUniqueID = deviceUniqueID
        self.engine = engine
        engine.setOnStop { [weak self] cause in self?.captureStopped(cause) }
    }

    /// The error that ends a run for `cause`.
    static func stopError(for cause: StopCause) -> any Error {
        switch cause {
        case .disconnected: CaptureSourceError.deviceDisconnected
        case .interrupted, .stoppedRunning: CaptureSourceError.deviceInterrupted
        case .failed(let error): error
        }
    }

    /// The clock of the samples delivered; `nil` is the host clock.
    var clock: CMClock? { engine.clock }

    /// The device as it would be captured now; `nil` when it is not connected.
    func describe() -> ExternalDeviceFormat? {
        engine.describe()
    }

    /// The error a run that is starting now would end with, if the capture gives no samples now.
    func currentStopError() -> (any Error)? {
        engine.currentStopCause().map(Self.stopError)
    }

    /// Holds `output` until `ExternalDeviceLease.end()`: the session runs (`ExternalDeviceEngine.prepare`), and the
    /// output's samples go to `delivery`. `onStop` is told, from any thread, when the capture stops by itself while the
    /// lease is alive. `isWanted` is asked on the session's queue right before: if it says no, nothing is done and the
    /// call throws `CancellationError`. Throws what `prepare` throws; the session then stops if no other lease is alive.
    func lease(
        _ output: Output, delivery: Delivery, onStop: @escaping @Sendable (any Error) -> Void,
        isWanted: @escaping @Sendable () -> Bool
    ) async throws -> ExternalDeviceLease {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExternalDeviceLease, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try acquire(output, delivery: delivery, onStop: onStop, isWanted: isWanted)
                })
            }
        }
    }

    /// Returns once everything queued on the session's queue before the call has run: the leases that ended have let go
    /// of their outputs and, if they were the last, stopped the session.
    func drain() async {
        await queue.drain()
    }

    /// Ends lease `id`, once. Its output delivers nowhere if it still had the lease's delivery; the last lease stops the
    /// session.
    func end(_ id: Int) {
        queue.async { [self] in
            let (cleared, stops) = state.withLock { state -> (Output?, Bool) in
                guard let holder = state.leases.removeValue(forKey: id) else { return (nil, false) }
                var cleared: Output?
                if state.deliveryLease[holder.output] == id {
                    state.deliveryLease[holder.output] = nil
                    cleared = holder.output
                }
                return (cleared, state.counter.release())
            }
            if let cleared { engine.setDelivery(nil, for: cleared) }
            if stops { engine.stop() }
        }
    }

    // MARK: - On the session's queue

    private func acquire(
        _ output: Output, delivery: Delivery, onStop: @escaping @Sendable (any Error) -> Void,
        isWanted: @Sendable () -> Bool
    ) throws -> ExternalDeviceLease {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isWanted() else { throw CancellationError() }
        _ = state.withLock { $0.counter.acquire() }
        let format: ExternalDeviceFormat
        do {
            format = try engine.prepare(for: output)
        } catch {
            if state.withLock({ $0.counter.release() }) { engine.stop() }
            throw error
        }
        engine.setDelivery(delivery, for: output)
        let id = state.withLock { state in
            let id = state.nextLeaseID
            state.nextLeaseID += 1
            state.leases[id] = Holder(output: output, onStop: onStop)
            state.deliveryLease[output] = id
            return id
        }
        return ExternalDeviceLease(session: self, id: id, format: format)
    }

    // MARK: - From any thread

    /// The capture stopped by itself: every live lease is told.
    private func captureStopped(_ cause: StopCause) {
        // A late notice of a stop from before the session ran again (the last lease stopped it, a new one started
        // it) is not about the leases alive now.
        if cause == .stoppedRunning, engine.isRunning { return }
        let error = Self.stopError(for: cause)
        let told = state.withLock { Array($0.leases.values) }
        for holder in told { holder.onStop(error) }
    }
}

/// A source's hold on one output of an `ExternalDeviceSession`, for one run. `end()` lets go of it; ending it again
/// does nothing.
struct ExternalDeviceLease: CaptureRunResource {
    let session: ExternalDeviceSession
    let id: Int
    /// What the session captured when the lease was given.
    let format: ExternalDeviceFormat

    func end() {
        session.end(id)
    }
}

/// The AVFoundation side of an `ExternalDeviceSession`.
///
/// `@unchecked Sendable`: the session, its input and its outputs are configured only on the session's queue
/// (`prepare`, `setDelivery`, `stop`); what is read from any thread (`isRunning`, the clock, whether the device is
/// connected) AVFoundation lets be read there, and the rest is in a `Mutex`.
final class CaptureSessionEngine: ExternalDeviceEngine, @unchecked Sendable {
    private let deviceUniqueID: String
    private let session = AVCaptureSession()
    /// `420v`, with no size: the device's own.
    private let videoOutput = AVCaptureVideoDataOutput()
    /// No settings: the device's own format, every channel.
    private let audioOutput = AVCaptureAudioDataOutput()
    private let state = Mutex(State())
    /// Set once, in `init`; removed in `deinit`.
    private var observers: [any NSObjectProtocol] = []

    private struct State {
        /// The device of the session's input.
        var device: DeviceBox?
        /// That device was disconnected since its input was added.
        var disconnected = false
        /// What each output delivers to, kept alive here.
        var forwarders: [ExternalDeviceSession.Output: SampleForwarder] = [:]
        var onStop: (@Sendable (ExternalDeviceSession.StopCause) -> Void)?
    }

    /// `AVCaptureDevice` is not annotated `Sendable`; only its connection is read away from the session's queue.
    private struct DeviceBox: @unchecked Sendable {
        let device: AVCaptureDevice
    }

    init(deviceUniqueID: String) {
        self.deviceUniqueID = deviceUniqueID
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.stopped(.failed(error ?? AVError(.unknown) as NSError))
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
                [weak self] _ in
                self?.stopped(.interrupted)
            },
            center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) {
                [weak self] _ in
                self?.stopped(.stoppedRunning)
            },
            // Any device's: the one recorded may be another object once it is connected again.
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
                [weak self] notification in
                guard let self, (notification.object as? AVCaptureDevice)?.uniqueID == deviceUniqueID else { return }
                state.withLock { $0.disconnected = true }
                stopped(.disconnected)
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isRunning: Bool { session.isRunning }
    var clock: CMClock? { session.synchronizationClock }

    func setOnStop(_ handler: @escaping @Sendable (ExternalDeviceSession.StopCause) -> Void) {
        state.withLock { $0.onStop = handler }
    }

    /// Reads the device's size before any run: for a format that is not video (a muxed one), from a device input made
    /// only to read its video port, which needs the camera's permission.
    func describe() -> ExternalDeviceFormat? {
        guard let device = try? ExternalDeviceCatalog.resolve(deviceUniqueID) else { return nil }
        return Self.format(of: device, input: nil)
    }

    func prepare(for output: ExternalDeviceSession.Output) throws -> ExternalDeviceFormat {
        let kept = state.withLock { $0.disconnected ? nil : $0.device?.device }
        if session.isRunning, let kept, kept.isConnected {
            // Already capturing it: the other output's lease shares it as it is.
            guard session.outputs.contains(captureOutput(output)) else { throw CaptureSourceError.sessionConfigurationFailed }
            return Self.format(of: kept, input: currentInput())
        }
        // The same device, found again: a reconnected one is a new input.
        ExternalDeviceCatalog.allowScreenCaptureDevices()
        let device = try ExternalDeviceCatalog.resolve(deviceUniqueID)
        let input = try AVCaptureDeviceInput(device: device)
        try configure(input)
        if !session.isRunning {
            session.startRunning()
            guard session.isRunning else { throw CaptureSourceError.sessionDidNotStart }
        }
        guard session.outputs.contains(captureOutput(output)) else { throw CaptureSourceError.sessionConfigurationFailed }
        return Self.format(of: device, input: input)
    }

    func setDelivery(_ delivery: ExternalDeviceSession.Delivery?, for output: ExternalDeviceSession.Output) {
        let forwarder = delivery.map { SampleForwarder(receive: $0.receive) }
        switch output {
        case .video: videoOutput.setSampleBufferDelegate(forwarder, queue: delivery?.queue)
        case .audio: audioOutput.setSampleBufferDelegate(forwarder, queue: delivery?.queue)
        }
        state.withLock { $0.forwarders[output] = forwarder }
    }

    func stop() {
        session.stopRunning()
    }

    func currentStopCause() -> ExternalDeviceSession.StopCause? {
        let (device, disconnected) = state.withLock { ($0.device, $0.disconnected) }
        if disconnected || device?.device.isConnected == false { return .disconnected }
        if !session.isRunning { return .stoppedRunning }
        return nil
    }

    // MARK: - On the session's queue

    /// Makes `input` the session's only input, and adds each output the session takes. Which outputs it took, each
    /// lease checks.
    private func configure(_ input: AVCaptureDeviceInput) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for old in session.inputs { session.removeInput(old) }
        state.withLock { $0.device = nil }
        guard session.canAddInput(input) else { throw CaptureSourceError.sessionConfigurationFailed }
        session.addInput(input)
        state.withLock { state in
            state.device = DeviceBox(device: input.device)
            state.disconnected = false
        }
        for output in [videoOutput, audioOutput] as [AVCaptureOutput]
        where !session.outputs.contains(output) && session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    private func currentInput() -> AVCaptureDeviceInput? {
        session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
    }

    private func captureOutput(_ output: ExternalDeviceSession.Output) -> AVCaptureOutput {
        switch output {
        case .video: videoOutput
        case .audio: audioOutput
        }
    }

    // MARK: - From any thread

    private func stopped(_ cause: ExternalDeviceSession.StopCause) {
        state.withLock { $0.onStop }?(cause)
    }

    /// `device`'s name and screen size: its active format's if that is video, otherwise its input's video port's
    /// (`input`, or one made for it).
    private static func format(of device: AVCaptureDevice, input: AVCaptureDeviceInput?) -> ExternalDeviceFormat {
        ExternalDeviceFormat(name: device.localizedName, pixelSize: pixelSize(of: device, input: input))
    }

    private static func pixelSize(of device: AVCaptureDevice, input: AVCaptureDeviceInput?) -> ExternalDeviceFormat.PixelSize? {
        if let size = videoSize(device.activeFormat.formatDescription) { return size }
        guard let input = input ?? (try? AVCaptureDeviceInput(device: device)) else { return nil }
        return input.ports.lazy.compactMap { $0.mediaType == .video ? $0.formatDescription.flatMap(videoSize) : nil }.first
    }

    private static func videoSize(_ description: CMFormatDescription) -> ExternalDeviceFormat.PixelSize? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return ExternalDeviceFormat.PixelSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }
}

/// The delegate of one output: hands each sample to a lease's delivery, on the delivery's queue.
private final class SampleForwarder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, Sendable
{
    private let receive: @Sendable (CMSampleBuffer) -> Void

    init(receive: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.receive = receive
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer)
    }
}
