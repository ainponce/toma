// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Synchronization
import os

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

/// What the camera session is configured for: a camera, at a preset and rate.
struct CameraSessionConfiguration: Equatable, Sendable {
    var deviceUniqueID: String
    var preset: CameraPreset
    var framesPerSecond: Int
}

/// The camera session as a new lease finds it.
struct CameraSessionSnapshot: Equatable {
    /// No other lease is alive.
    var isFirstLease: Bool
    var isRunning: Bool
    /// A lease `forRecording` is alive.
    var isPinned: Bool
    /// The camera of the session's input, if it has one.
    var inputDeviceUniqueID: String?
    /// That camera is still connected: one disconnected and connected again needs a new input.
    var inputConnected: Bool
    /// What the session was last configured for; `nil` if never, if a change failed, or if it stopped since.
    var configuration: CameraSessionConfiguration?
    /// The input's camera has the format and frame rate of `configuration`: the session, or another app, may have
    /// changed them.
    var deviceMatchesConfiguration: Bool
}

/// What a new lease does to the camera session.
struct CameraLeasePlan: Equatable {
    enum Camera: Equatable {
        /// A lease `forRecording` holds the session: the new lease shares it as it is.
        case share
        /// The session already captures the camera asked for, as asked for.
        case keep
        /// The session is pointed at this camera, in the format and at the rate for its preset and rate.
        case configure(CameraSessionConfiguration)
    }

    var camera: Camera
    /// The session is not running (no lease had it, or it stopped by itself: an error, an interruption): it starts.
    var startsSession: Bool
}

/// Who decides what the shared camera session captures (plan decision 28).
enum CameraLeaseRules {
    /// The plan for a new lease that asks for `preset` at `framesPerSecond`, on the camera `pick` gave (or with the
    /// reason there is none):
    /// - while a lease `forRecording` is alive, the session is shared as it is, whatever the new lease asks for:
    ///   the capture never changes silently in the middle of a take;
    /// - otherwise, without a camera to pick, the lease fails;
    /// - the session already capturing that camera (connected), configured for that preset and rate and with its
    ///   camera still in that format and rate, is kept as it is;
    /// - anything else reconfigures it;
    /// - and a session that is not running starts.
    static func plan(
        _ session: CameraSessionSnapshot, pick: Result<String, CaptureSourceError>, preset: CameraPreset, framesPerSecond: Int
    ) -> Result<CameraLeasePlan, CaptureSourceError> {
        let startsSession = session.isFirstLease || !session.isRunning
        if session.isPinned, session.inputDeviceUniqueID != nil {
            return .success(CameraLeasePlan(camera: .share, startsSession: startsSession))
        }
        return pick.map { uniqueID in
            let wanted = CameraSessionConfiguration(deviceUniqueID: uniqueID, preset: preset, framesPerSecond: framesPerSecond)
            let unchanged = session.inputDeviceUniqueID == uniqueID && session.inputConnected
                && session.configuration == wanted && session.deviceMatchesConfiguration
            return CameraLeasePlan(camera: unchanged ? .keep : .configure(wanted), startsSession: startsSession)
        }
    }
}

/// The app's one camera session (plan decision 28), shared by what shows the camera (the bubble, with
/// `makePreviewLayer()`) and what records it (`CameraCaptureSource`): they show and record the same camera, and
/// a change of camera takes both along. Each of them holds a `CameraLease` while it uses the camera; the session
/// runs while there is one. What each new lease does to the session is `CameraLeaseRules.plan`.
///
/// macOS has no input-priority session preset: a session may set a format of its own when it starts, over the one
/// chosen. So the camera stays locked for configuration from before the session is configured until it runs, and
/// its format and rate are checked then, and set again if they changed.
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

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "CameraSessionHost")

    /// Changed only on `queue`; read anywhere.
    private struct State {
        var counter = CameraLeaseCounter()
        var nextLeaseID = 0
        /// The live leases, and whether each one records.
        var leases: [Int: Bool] = [:]
        /// The lease whose delegate the output has.
        var delegateLease: Int?
        /// What the session was last configured for; `nil` while a change is under way, after one failed, after
        /// the camera kept another format or rate, and while the session is stopped.
        var configuration: CameraSessionConfiguration?
        var activeDeviceUniqueID: String?

        var isPinned: Bool { leases.values.contains(true) }
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
    /// `preferredDeviceUniqueID` if it is connected, otherwise the system's preferred one, otherwise the first,
    /// skipping suspended ones (a closed lid, a closed privacy iris: `CameraCatalog.pick(preferred:among:suspended:)`);
    /// recorded at `preset` and `framesPerSecond` (`CameraFormatChoice`). While a lease `forRecording` is alive,
    /// the session stays as it is and the new lease shares it (`CameraLeaseRules`).
    ///
    /// Throws `CaptureSourceError.cameraNotFound` without a camera, `.cameraInterrupted` when every camera is
    /// suspended, `.cameraFormatUnavailable` when the camera has no format at that rate, `.sessionConfigurationFailed`
    /// or `.sessionDidNotStart` when the session refuses it, or the error of the device (no permission, in use).
    /// A camera the session refuses leaves it with the camera it had; one that went in but whose format could not
    /// be set stays, as it comes, and the next lease sets it again.
    public func lease(
        preferredDeviceUniqueID: String?, preset: CameraPreset, framesPerSecond: Int, forRecording: Bool = false
    ) async throws -> CameraLease {
        try await lease(
            preferredDeviceUniqueID: preferredDeviceUniqueID, preset: preset, framesPerSecond: framesPerSecond,
            forRecording: forRecording, delivery: nil, isWanted: { true })
    }

    /// Like the public `lease`; with `delivery`, the output's frames go to its delegate until the lease ends.
    /// `isWanted` is asked on the session's queue right before the lease is given: if it says no, nothing is done
    /// and the call throws `CancellationError`.
    func lease(
        preferredDeviceUniqueID: String?, preset: CameraPreset, framesPerSecond: Int, forRecording: Bool,
        delivery: SampleDelivery?, isWanted: @escaping @Sendable () -> Bool
    ) async throws -> CameraLease {
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Granted, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    guard isWanted() else { throw CancellationError() }
                    return try acquire(
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
                return (clearsDelegate, state.counter.release())
            }
            if clearsDelegate { output.setSampleBufferDelegate(nil, queue: nil) }
            if stops { stopSession() }
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
        let isFirstLease = state.withLock { $0.counter.acquire() }
        let device: AVCaptureDevice
        do {
            device = try prepare(preferred: preferred, preset: preset, framesPerSecond: framesPerSecond, isFirstLease: isFirstLease)
        } catch {
            if state.withLock({ $0.counter.release() }) { stopSession() }
            throw error
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

    /// Makes the session capture what `CameraLeaseRules.plan` says for the new lease, and run. Returns its camera.
    private func prepare(preferred: String?, preset: CameraPreset, framesPerSecond: Int, isFirstLease: Bool) throws -> AVCaptureDevice {
        let current = currentInput()
        let configuration = state.withLock { $0.configuration }
        let picked = Result(catching: { () throws(CaptureSourceError) in try CameraCatalog.resolve(preferred: preferred) })
        let snapshot = CameraSessionSnapshot(
            isFirstLease: isFirstLease, isRunning: session.isRunning, isPinned: state.withLock(\.isPinned),
            inputDeviceUniqueID: current?.device.uniqueID, inputConnected: current?.device.isConnected ?? false,
            configuration: configuration,
            deviceMatchesConfiguration: current.map { Self.has($0.device, configuration) } ?? false)
        let plan = try CameraLeaseRules.plan(
            snapshot, pick: picked.map(\.info.uniqueID), preset: preset, framesPerSecond: framesPerSecond
        ).get()

        let device: AVCaptureDevice
        switch plan.camera {
        case .share, .keep:
            // Only a session with an input is shared or kept.
            guard let current else { throw CaptureSourceError.sessionConfigurationFailed }
            device = current.device
        case .configure(let wanted):
            // The input's camera when only its format or rate change; otherwise the one picked.
            let staying = current.flatMap { $0.device.uniqueID == wanted.deviceUniqueID && $0.device.isConnected ? $0.device : nil }
            device = try staying ?? picked.get().device
        }

        // Locked from before the session is configured until it runs (see the type's comment). A camera that is
        // only started again is locked if it can be: otherwise it starts as it is.
        var locked = false
        if case .configure = plan.camera {
            try device.lockForConfiguration()
            locked = true
        } else if plan.startsSession {
            locked = (try? device.lockForConfiguration()) != nil
        }
        defer { if locked { device.unlockForConfiguration() } }
        if case .configure(let wanted) = plan.camera { try configure(device, for: wanted, replacing: current) }
        if plan.startsSession {
            session.startRunning()
            guard session.isRunning else {
                // Stopped, it is no longer trusted to keep its format: the next lease sets it again.
                state.withLock { $0.configuration = nil }
                throw CaptureSourceError.sessionDidNotStart
            }
        }
        if locked { enforceConfiguration(on: device) }
        return device
    }

    /// Points the session at `device`, locked, in the format and at the rate `wanted` asks for; `current` is the
    /// session's input. A camera the session refuses leaves it with the camera it had. A camera that went in but
    /// whose output could not be added stays in the session, and no configuration is kept: the next lease sets it
    /// up again.
    private func configure(
        _ device: AVCaptureDevice, for wanted: CameraSessionConfiguration, replacing current: AVCaptureDeviceInput?
    ) throws {
        guard let target = Self.target(of: device, for: wanted) else { throw CaptureSourceError.cameraFormatUnavailable }
        let kept = current.flatMap { $0.device === device ? $0 : nil }
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
            // The leases alive already see this camera, even if what follows fails.
            state.withLock { $0.activeDeviceUniqueID = device.uniqueID }
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CaptureSourceError.sessionConfigurationFailed }
            session.addOutput(output)
        }
        // After the input is added (adding it may reset the format), inside the session's configuration, so the
        // format and the rate are applied together at the commit.
        Self.apply(Self.steps(for: device, to: target), to: device)
        state.withLock { $0.configuration = wanted }
    }

    /// With `device` locked and the session running: sets the format and rate of the configuration again if the
    /// session (or another app) changed them; if the camera still has others, the configuration is dropped, so the
    /// next lease sets them again.
    private func enforceConfiguration(on device: AVCaptureDevice) {
        guard let configuration = state.withLock({ $0.configuration }), configuration.deviceUniqueID == device.uniqueID,
            let target = Self.target(of: device, for: configuration)
        else { return }
        let steps = Self.steps(for: device, to: target)
        guard !steps.isEmpty else { return }
        Self.logger.notice("The camera's format or rate changed as the session started; setting them again: \(String(describing: steps), privacy: .public)")
        Self.apply(steps, to: device)
        let left = Self.steps(for: device, to: target)
        guard !left.isEmpty else { return }
        Self.logger.error("The camera keeps another format or rate than the one chosen: \(String(describing: left), privacy: .public)")
        state.withLock { $0.configuration = nil }
    }

    /// No lease is left: the session stops, and what it was configured for is forgotten (another app may change
    /// the camera's format while it is stopped: the next lease sets it again).
    private func stopSession() {
        state.withLock { state in
            state.activeDeviceUniqueID = nil
            state.configuration = nil
        }
        session.stopRunning()
    }

    private func currentInput() -> AVCaptureDeviceInput? {
        session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
    }

    // MARK: - The camera's format and rate

    /// Whether `device` is the camera of `configuration` and has its format and rate now.
    private static func has(_ device: AVCaptureDevice, _ configuration: CameraSessionConfiguration?) -> Bool {
        guard let configuration, configuration.deviceUniqueID == device.uniqueID,
            let target = target(of: device, for: configuration)
        else { return false }
        return steps(for: device, to: target).isEmpty
    }

    private static func target(of device: AVCaptureDevice, for configuration: CameraSessionConfiguration) -> CameraFormatChoice.Target? {
        let formats = device.formats
        return CameraFormatChoice.target(
            formats: formats.map(info), rateRanges: formats.map { $0.videoSupportedFrameRateRanges.map(range) },
            preset: configuration.preset, framesPerSecond: configuration.framesPerSecond)
    }

    private static func steps(for device: AVCaptureDevice, to target: CameraFormatChoice.Target) -> [CameraFormatChoice.DeviceStep] {
        let settings = CameraFormatChoice.DeviceSettings(
            formatIndex: device.formats.firstIndex(of: device.activeFormat),
            minFrameDuration: device.activeVideoMinFrameDuration, maxFrameDuration: device.activeVideoMaxFrameDuration,
            autoFrameRateEnabled: device.isAutoVideoFrameRateEnabled)
        return CameraFormatChoice.steps(from: settings, format: target.format, frameDuration: target.frameDuration)
    }

    /// Applies `steps` to `device`, which is locked for configuration. Every value set is one the camera lists:
    /// any other raises an Objective-C exception, which Swift cannot catch.
    private static func apply(_ steps: [CameraFormatChoice.DeviceStep], to device: AVCaptureDevice) {
        for step in steps {
            switch step {
            case .setFormat(let index):
                device.activeFormat = device.formats[index]
            case .disableAutoFrameRate:
                // Setting it raises an exception for a format without it, which cannot have it on anyway.
                if device.activeFormat.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = false }
            case .setFrameDuration(let duration):
                // With the automatic frame rate on, setting a frame duration raises an exception: the rate is left
                // to the camera then (a new format turns it off, so this is only a guard).
                guard !device.isAutoVideoFrameRateEnabled else { continue }
                // The minimum never above the maximum on the way: the maximum first when the rate goes down.
                if CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 {
                    device.activeVideoMaxFrameDuration = duration
                    device.activeVideoMinFrameDuration = duration
                } else {
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
            }
        }
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
