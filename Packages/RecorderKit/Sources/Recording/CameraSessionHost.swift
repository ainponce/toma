// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Synchronization

/// How many leases a camera session has: the first one starts it, the last one stops it.
struct CameraLeaseCounter: Equatable {
    private(set) var count = 0

    /// Counts a new lease. `true` when it is the only one: the session has to start.
    mutating func acquire() -> Bool {
        count += 1
        return count == 1
    }

    /// Counts a lease that ended. `true` when it was the last one: the session has to stop. Without leases it
    /// changes nothing.
    mutating func release() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }
}

/// The app's one camera session (plan decision 28), shared by what shows the camera (the bubble, with
/// `makePreviewLayer()`) and what records it (`CameraCaptureSource`): they show and record the same camera, and
/// a change of camera takes both along. Each of them holds a `CameraLease` while it uses the camera; the session
/// runs while there is one.
///
/// Who decides what the session captures: each new lease points it at the camera `CameraCatalog.pick` gives
/// for its preferred device, in the format `CameraFormatChoice` picks for its preset and rate, unless a lease
/// `forRecording` is alive: that one keeps the camera and its format until it ends, since the capture never
/// changes silently in the middle of a take. The bubble asks for the take's quality, so in practice the two agree.
///
/// The session is configured, started and stopped on a serial queue of its own: `startRunning()` blocks.
/// `@unchecked Sendable`: the session, its input and its output are only touched on that queue (the preview
/// layer is attached where `makePreviewLayer()` is called), and the state is in a `Mutex`.
public final class CameraSessionHost: @unchecked Sendable {
    /// Configured only on `queue`.
    let session = AVCaptureSession()
    /// The frames the camera track records, in `420v`, late ones dropped. Its delegate is that of the recording
    /// lease that asked for one: nothing else gets the frames.
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchSerialQueue(label: "dev.toma.CameraSessionHost.session")
    private let state = Mutex(State())

    /// Changed only on `queue`; read anywhere.
    private struct State {
        var counter = CameraLeaseCounter()
        var nextLeaseID = 0
        /// The live leases, and whether each one records.
        var leases: [Int: Bool] = [:]
        /// The lease whose delegate the output has.
        var delegateLease: Int?
        /// What the session was last configured for; `nil` while a change is under way or after one failed.
        var configuration: Configuration?
        var activeDeviceUniqueID: String?

        var isPinned: Bool { leases.values.contains(true) }
    }

    private struct Configuration: Equatable {
        var deviceUniqueID: String
        var preset: CameraPreset
        var framesPerSecond: Int
    }

    /// Who gets a recording lease's frames, and on which queue.
    struct SampleDelivery: Sendable {
        let delegate: any AVCaptureVideoDataOutputSampleBufferDelegate & Sendable
        let queue: DispatchSerialQueue
    }

    public init() {
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
    }

    /// The camera the session captures while a lease is alive; `nil` once the last one has ended.
    public var activeDeviceUniqueID: String? { state.withLock { $0.activeDeviceUniqueID } }

    /// Uses the camera until `CameraLease.end()`: the session runs while there is a lease. The camera is
    /// `preferredDeviceUniqueID` if it is connected, otherwise the system's preferred one, otherwise the first
    /// (`CameraCatalog.pick`), skipping suspended ones (a closed lid, a closed privacy iris); recorded at `preset`
    /// and `framesPerSecond` (`CameraFormatChoice`). While a lease `forRecording` is alive, the session stays as
    /// it is and the new lease shares it.
    ///
    /// Throws `CaptureSourceError.cameraNotFound` without a camera, `.cameraFormatUnavailable` when the camera
    /// has no format at that rate, `.sessionConfigurationFailed` or `.sessionDidNotStart` when the session
    /// refuses it, or the error of the device (no permission, in use). The session goes on as it was then.
    public func lease(
        preferredDeviceUniqueID: String?, preset: CameraPreset, framesPerSecond: Int, forRecording: Bool = false
    ) async throws -> CameraLease {
        try await lease(
            preferredDeviceUniqueID: preferredDeviceUniqueID, preset: preset, framesPerSecond: framesPerSecond,
            forRecording: forRecording, delivery: nil)
    }

    /// Like the public `lease`; with `delivery`, the output's frames go to its delegate until the lease ends.
    func lease(
        preferredDeviceUniqueID: String?, preset: CameraPreset, framesPerSecond: Int, forRecording: Bool,
        delivery: SampleDelivery?
    ) async throws -> CameraLease {
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Granted, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try acquire(
                        preferred: preferredDeviceUniqueID, preset: preset, framesPerSecond: framesPerSecond,
                        forRecording: forRecording, delivery: delivery)
                })
            }
        }
        return CameraLease(host: self, id: granted.id, device: granted.device)
    }

    /// A layer that shows what the session captures while it runs. Not mirrored: the app mirrors it.
    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer(session: session)
    }

    /// Returns once everything queued on the session's queue before the call has run: the leases that ended
    /// have let go of the output and, if they were the last, stopped the session.
    func drain() async {
        await queue.drain()
    }

    /// Ends lease `id`, once. Its delegate, if the output has it, goes; the last lease stops the session.
    func end(_ id: Int) {
        queue.async { [self] in
            let (clearsDelegate, stops) = state.withLock { state -> (Bool, Bool) in
                guard state.leases.removeValue(forKey: id) != nil else { return (false, false) }
                let clearsDelegate = state.delegateLease == id
                if clearsDelegate { state.delegateLease = nil }
                let stops = state.counter.release()
                if stops {
                    state.activeDeviceUniqueID = nil
                    // Another app may change the camera's format while the session is stopped: the next lease
                    // sets it again.
                    state.configuration = nil
                }
                return (clearsDelegate, stops)
            }
            if clearsDelegate { output.setSampleBufferDelegate(nil, queue: nil) }
            if stops { session.stopRunning() }
        }
    }

    // MARK: - On the session's queue

    /// A lease that was given: its ID and the camera the session had then.
    private struct Granted: @unchecked Sendable {
        let id: Int
        let device: AVCaptureDevice
    }

    private func acquire(
        preferred: String?, preset: CameraPreset, framesPerSecond: Int, forRecording: Bool, delivery: SampleDelivery?
    ) throws -> Granted {
        dispatchPrecondition(condition: .onQueue(queue))
        let device: AVCaptureDevice
        if state.withLock(\.isPinned), let current = currentInput()?.device {
            device = current
        } else {
            device = try configure(preferred: preferred, preset: preset, framesPerSecond: framesPerSecond)
        }
        let starts = state.withLock { $0.counter.acquire() }
        // Also when other leases hold it: the session may have stopped by itself (an error, an interruption).
        if starts || !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            state.withLock { _ = $0.counter.release() }
            throw CaptureSourceError.sessionDidNotStart
        }
        if let delivery { output.setSampleBufferDelegate(delivery.delegate, queue: delivery.queue) }
        let id = state.withLock { state in
            let id = state.nextLeaseID
            state.nextLeaseID += 1
            state.leases[id] = forRecording
            if delivery != nil { state.delegateLease = id }
            state.activeDeviceUniqueID = device.uniqueID
            return id
        }
        return Granted(id: id, device: device)
    }

    /// Points the session at the camera to use, in its format and at its rate, unless it already is. Returns that
    /// camera. A camera that cannot be used leaves the session with the one it had.
    private func configure(preferred: String?, preset: CameraPreset, framesPerSecond: Int) throws -> AVCaptureDevice {
        let usable = CameraCatalog.usable()
        guard let uniqueID = CameraCatalog.pick(preferred: preferred, among: usable.map(\.info)),
            let discovered = usable.first(where: { $0.info.uniqueID == uniqueID })?.device
        else { throw CaptureSourceError.cameraNotFound }
        let wanted = Configuration(deviceUniqueID: uniqueID, preset: preset, framesPerSecond: framesPerSecond)
        let current = currentInput()
        // A camera disconnected and connected again needs a new input.
        let kept = current.flatMap { $0.device.uniqueID == uniqueID && $0.device.isConnected ? $0 : nil }
        if let kept, state.withLock({ $0.configuration }) == wanted { return kept.device }
        let device = kept?.device ?? discovered

        let formats = device.formats
        guard let index = CameraFormatChoice.best(among: formats.map(Self.info), preset: preset, framesPerSecond: framesPerSecond),
            let duration = CameraFormatChoice.frameDuration(
                framesPerSecond: framesPerSecond, ranges: formats[index].videoSupportedFrameRateRanges.map(Self.range))
        else { throw CaptureSourceError.cameraFormatUnavailable }
        let input = try kept ?? AVCaptureDeviceInput(device: device)

        state.withLock { $0.configuration = nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if input !== current {
            if let current { session.removeInput(current) }
            guard session.canAddInput(input) else {
                if let current, session.canAddInput(current) {
                    session.addInput(current)
                } else {
                    state.withLock { $0.activeDeviceUniqueID = nil }
                }
                throw CaptureSourceError.sessionConfigurationFailed
            }
            session.addInput(input)
            // The leases alive already see this camera, even if setting its format fails below.
            state.withLock { if $0.counter.count > 0 { $0.activeDeviceUniqueID = uniqueID } }
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CaptureSourceError.sessionConfigurationFailed }
            session.addOutput(output)
        }
        // Inside the session's configuration, after the input is added (adding it resets the format), with
        // values the format lists (any other raises an Objective-C exception).
        try device.lockForConfiguration()
        device.activeFormat = formats[index]
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        state.withLock { $0.configuration = wanted }
        return device
    }

    private func currentInput() -> AVCaptureDeviceInput? {
        session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
    }

    private static func info(_ format: AVCaptureDevice.Format) -> CameraFormatInfo {
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return CameraFormatInfo(
            width: Int(dimensions.width), height: Int(dimensions.height),
            maxFramesPerSecond: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
            isVideoRange420: CMFormatDescriptionGetMediaSubType(description) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    private static func range(_ range: AVFrameRateRange) -> CameraFormatChoice.RateRange {
        CameraFormatChoice.RateRange(
            minRate: range.minFrameRate, maxRate: range.maxFrameRate,
            minDuration: range.minFrameDuration, maxDuration: range.maxFrameDuration)
    }
}

/// A hold on the camera of a `CameraSessionHost`: the session runs while there is one. Ends with `end()`, or
/// when it is released.
public final class CameraLease: Sendable {
    private let host: CameraSessionHost
    private let id: Int
    private let deviceBox: DeviceBox

    /// `AVCaptureDevice` is not annotated `Sendable`; the lease only hands it to whoever holds the lease.
    private struct DeviceBox: @unchecked Sendable {
        let device: AVCaptureDevice
    }

    init(host: CameraSessionHost, id: Int, device: AVCaptureDevice) {
        self.host = host
        self.id = id
        self.deviceBox = DeviceBox(device: device)
    }

    deinit {
        host.end(id)
    }

    /// The camera the session had when the lease was given.
    var device: AVCaptureDevice { deviceBox.device }

    /// Lets go of the camera: once no lease is left, the session stops. Returns at once (the session changes
    /// on its queue); calling it again does nothing.
    public func end() {
        host.end(id)
    }
}
