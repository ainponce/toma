// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Observation

/// The capture devices the island lists. Listing them needs no permission.
enum DeviceLists {
    /// The connected microphones, in the system's order.
    static func microphones() -> [(uniqueID: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { (uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// The connected cameras, in the system's order: the built-in one, an iPhone (Continuity Camera) and
    /// external ones.
    static func cameras() -> [(uniqueID: String, name: String)] {
        cameraDiscovery().devices.map { (uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// The cameras the island lists.
    static func cameraDiscovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
    }
}

/// A connected microphone or camera, as the island lists it.
struct CaptureDevice: Identifiable, Sendable {
    /// `AVCaptureDevice.uniqueID`.
    let id: String
    let name: String
}

/// The connected devices of a kind (`DeviceLists.microphones`, `DeviceLists.cameras`), listed off the main
/// thread when the app starts and again whenever a capture device is connected or disconnected: opening the
/// island never waits for the list.
@MainActor @Observable
final class CaptureDeviceList {
    private(set) var devices: [CaptureDevice] = []

    @ObservationIgnored private let list: @Sendable () -> [(uniqueID: String, name: String)]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Only the newest listing is kept.
    @ObservationIgnored private var generation = 0

    init(listing list: @escaping @Sendable () -> [(uniqueID: String, name: String)]) {
        self.list = list
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
        refresh()
    }

    private func refresh() {
        generation += 1
        let generation = generation
        let list = list
        Task.detached(priority: .utility) { [weak self] in
            let devices = list().map { CaptureDevice(id: $0.uniqueID, name: $0.name) }
            await self?.update(devices, generation: generation)
        }
    }

    private func update(_ devices: [CaptureDevice], generation: Int) {
        guard generation == self.generation else { return }
        self.devices = devices
    }
}
