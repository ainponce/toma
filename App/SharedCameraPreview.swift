// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppSupport
import QuartzCore
import Recording
import os

/// What the camera bubble shows the camera with: the bubble knows only this.
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

/// The bubble's camera (plan decision 28): a lease `forRecording: false` on the app's one `CameraSessionHost`, the
/// one the camera track records, at the quality and rate the take records it (`QuickSettings.cameraPreset` and
/// `cameraFramesPerSecond`, read at each start). So the bubble shows the camera the take records, and the session
/// does not change when the take starts; while a take records the camera, the bubble shows it as the take has it,
/// whatever it asks for (`CameraLeaseRules`). The layer is `makePreviewLayer()`, mirrored after every start and every
/// change of camera the host reports: each new input gives it a new connection, with the default settings (a
/// restart of the camera track that moves to another camera included).
@MainActor
final class SharedCameraPreview: CameraPreviewProviding {
    let previewLayer: AVCaptureVideoPreviewLayer

    private let host: CameraSessionHost
    private let settings: @MainActor () -> QuickSettings
    /// The bubble's hold on the camera while it shows.
    private var lease: CameraLease?
    /// Goes up with every `start` and `stop`: a start that a later call overtook lets its lease go.
    private var generation = 0

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Camera")

    init(host: CameraSessionHost, settings: @escaping @MainActor () -> QuickSettings = { SettingsStore().settings.quick }) {
        self.host = host
        self.settings = settings
        previewLayer = host.makePreviewLayer()
        previewLayer.videoGravity = .resizeAspectFill
        host.setOnCameraChange { [weak self] _ in
            Task { @MainActor in self?.mirror() }
        }
    }

    func start(deviceUniqueID: String?) async throws {
        generation += 1
        let generation = generation
        let quick = settings()
        do {
            let new = try await host.lease(
                preferredDeviceUniqueID: deviceUniqueID, preset: quick.cameraPreset, framesPerSecond: quick.cameraFramesPerSecond,
                forRecording: false)
            guard generation == self.generation else {
                new.end()
                return
            }
            // The new lease before the old one ends: the session never stops in between.
            lease?.end()
            lease = new
        } catch {
            guard generation == self.generation else { return }
            guard lease != nil else { throw error }
            Self.logger.error("Cannot show the camera asked for, the one before stays: \(String(describing: error), privacy: .public)")
        }
        mirror()
    }

    func stop() {
        generation += 1
        lease?.end()
        lease = nil
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
}
