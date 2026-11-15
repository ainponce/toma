// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import QuartzCore

/// What the camera bubble shows the camera with: the bubble knows only this (Task 14's shared camera, which
/// also records it, takes `CameraPreviewHost`'s place).
@MainActor
protocol CameraPreviewProviding: AnyObject {
    /// The live image, mirrored like a mirror (the video is not).
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    /// Shows the camera with `deviceUniqueID` if it is connected, otherwise the system's preferred camera,
    /// otherwise the first one; called again, it changes to the camera that resolves to now. Throws when there
    /// is no camera to show.
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
/// after every change of camera, since each one makes a new connection with the default settings.
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
    /// The camera changed since the layer was last mirrored (also by a start that was overtaken).
    private var needsMirroring = false

    init() {
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start(deviceUniqueID: String?) async throws {
        generation += 1
        let generation = generation
        let changed = try await onQueue { session in try Self.configure(session, deviceUniqueID: deviceUniqueID) }
        if changed { needsMirroring = true }
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

    /// Makes the session show the camera `deviceUniqueID` resolves to; whether it changed camera.
    nonisolated private static func configure(_ session: AVCaptureSession, deviceUniqueID: String?) throws -> Bool {
        guard let device = device(uniqueID: deviceUniqueID) else { throw CameraPreviewError.noCamera }
        let current = session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
        if current?.device.uniqueID == device.uniqueID { return false }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let current { session.removeInput(current) }
        guard session.canAddInput(input) else {
            if let current, session.canAddInput(current) { session.addInput(current) }
            throw CameraPreviewError.cannotUse
        }
        session.addInput(input)
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        return true
    }

    /// The camera with `uniqueID` if it is connected; otherwise the system's preferred camera; otherwise the
    /// first one listed.
    nonisolated private static func device(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID), device.isConnected { return device }
        return AVCaptureDevice.systemPreferredCamera ?? DeviceLists.cameraDiscovery().devices.first
    }
}
