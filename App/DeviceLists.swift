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
}

/// A connected microphone, as the island lists it.
struct Microphone: Identifiable, Sendable {
    /// `AVCaptureDevice.uniqueID`.
    let id: String
    let name: String
}

/// The connected microphones, listed off the main thread when the app starts and again whenever a
/// capture device is connected or disconnected: opening the island never waits for the list.
@MainActor @Observable
final class MicrophoneList {
    private(set) var devices: [Microphone] = []

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Only the newest listing is kept.
    @ObservationIgnored private var generation = 0

    init() {
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
        Task.detached(priority: .utility) { [weak self] in
            let devices = DeviceLists.microphones().map { Microphone(id: $0.uniqueID, name: $0.name) }
            await self?.update(devices, generation: generation)
        }
    }

    private func update(_ devices: [Microphone], generation: Int) {
        guard generation == self.generation else { return }
        self.devices = devices
    }
}
