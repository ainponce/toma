// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import QuartzCore
import os

/// What the camera bubble shows the camera with: the bubble knows only this (Task 14's shared camera, which
/// also records it, takes `CameraPreviewHost`'s place).
@MainActor
protocol CameraPreviewProviding: AnyObject {
    /// The live image, mirrored like a mirror (the video is not).
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    /// Shows the camera with `deviceUniqueID` if it is connected, otherwise the system's preferred camera,
    /// otherwise the first one; called again, it changes to the camera that resolves to now. If that camera
    /// cannot be used, it goes on showing the one it showed. Throws only when it shows no camera at all.
    func start(deviceUniqueID: String?) async throws
    /// Turns the camera off.
    func stop()
}

enum CameraPreviewError: Error {
    /// The Mac has no camera connected.
    case noCamera
    /// The camera is connected but cannot be shown (in use by the system, or gone meanwhile).
    case cannotUse
}

/// The camera preview of this version (plan decision 28): an `AVCaptureSession` of its own with no output
/// but `previewLayer`. The session is configured, started and stopped on a serial queue of its own:
/// `startRunning()` and `stopRunning()` block, so they never run on the main thread. The layer is mirrored
/// after every change of input, since each one makes a new connection with the default settings: also when a
/// camera that cannot be used gives its place back to the one before.
@MainActor
final class CameraPreviewHost: CameraPreviewProviding {
    let previewLayer = AVCaptureVideoPreviewLayer()

    /// Used only on `queue`, and on the main actor while `queue` does nothing with it (to attach the layer).
    private final class Session: @unchecked Sendable {
        let value = AVCaptureSession()
    }

    private let session = Session()
    private let queue = DispatchQueue(label: "dev.toma.Toma.camera-preview", qos: .userInitiated)
    /// Goes up with every `start` and `stop`: a start that a later call overtook does not go on.
    private var generation = 0
    /// The input changed since the layer was last mirrored (also by a start that was overtaken).
    private var needsMirroring = false

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Camera")

    /// What `configure` did to the session.
    private enum Outcome: Sendable {
        /// It already showed that camera.
        case unchanged
        /// It shows that camera now, on a new connection.
        case changed
        /// That camera cannot be used: it goes on showing the one it showed, on a new connection if that one was
        /// taken out and put back.
        case keptPrevious(reconnected: Bool, reason: String)
    }

    init() {
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start(deviceUniqueID: String?) async throws {
        generation += 1
        let generation = generation
        let outcome = try await onQueue { session in try Self.configure(session, deviceUniqueID: deviceUniqueID) }
        switch outcome {
        case .unchanged:
            break
        case .changed:
            needsMirroring = true
        case .keptPrevious(let reconnected, let reason):
            if reconnected { needsMirroring = true }
            Self.logger.error("Cannot show the camera asked for, the one before stays: \(reason, privacy: .public)")
        }
        guard generation == self.generation else { return }
        // Before, the layer has no connection to mirror.
        if previewLayer.session == nil { previewLayer.session = session.value }
        if needsMirroring {
            needsMirroring = false
            mirror()
        }
        try await onQueue { session in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        generation += 1
        let session = session
        queue.async { session.value.stopRunning() }
    }

    /// Mirrored by the connection when it can be; otherwise by the layer. Setting `isVideoMirrored` on a
    /// connection that does not support it, or that adjusts it by itself, raises an Objective-C exception,
    /// which Swift cannot catch.
    private func mirror() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            previewLayer.setAffineTransform(.identity)
        } else {
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
        CATransaction.commit()
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable (AVCaptureSession) throws -> T) async throws -> T {
        let session = session
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(session.value) }) }
        }
    }

    /// Makes the session show the camera `deviceUniqueID` resolves to. Throws only when it is left without a
    /// camera to show: none is connected, or neither that camera nor the one before (still connected) can be used.
    nonisolated private static func configure(_ session: AVCaptureSession, deviceUniqueID: String?) throws -> Outcome {
        guard let device = device(uniqueID: deviceUniqueID) else { throw CameraPreviewError.noCamera }
        let current = session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
        if current?.device.uniqueID == device.uniqueID { return .unchanged }
        // The one before still shows, unless its camera is gone.
        let previous = current.flatMap { $0.device.isConnected ? $0 : nil }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            guard previous != nil else { throw error }
            return .keptPrevious(reconnected: false, reason: String(describing: error))
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let current { session.removeInput(current) }
        if session.canAddInput(input) {
            session.addInput(input)
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            return .changed
        }
        if let previous, session.canAddInput(previous) {
            session.addInput(previous)
            return .keptPrevious(reconnected: true, reason: "the session cannot add \(device.localizedName)")
        }
        throw CameraPreviewError.cannotUse
    }

    /// The camera with `uniqueID` if it is connected; otherwise the system's preferred camera; otherwise the
    /// first one listed.
    nonisolated private static func device(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID), device.isConnected { return device }
        return AVCaptureDevice.systemPreferredCamera ?? DeviceLists.cameraDiscovery().devices.first
    }
}
