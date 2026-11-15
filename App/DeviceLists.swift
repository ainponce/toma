// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import Observation
import Recording
import os

/// The capture devices and the apps with audio the island lists. Listing them needs no permission.
enum DeviceLists {
    /// The connected microphones, in the system's order.
    static func microphones() -> [(uniqueID: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { (uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// The connected cameras (`CameraCatalog.devices`): the system's preferred one first, then the built-in one, an
    /// iPhone (Continuity Camera) and external ones in the system's order.
    static func cameras() -> [(uniqueID: String, name: String)] {
        CameraCatalog.devices().map { (uniqueID: $0.uniqueID, name: $0.name) }
    }

    /// The bundle IDs of the processes playing audio now (`AudioProcessCatalog`); none if Core Audio cannot say.
    static func playingBundleIDs() -> Set<String> {
        do {
            return Set(try AudioProcessCatalog.processes().filter(\.isPlayingAudio).compactMap(\.bundleIdentifier))
        } catch {
            Logger(subsystem: "dev.toma.Toma", category: "SystemAudio")
                .error("Cannot read the processes playing audio: \(String(describing: error), privacy: .public)")
            return []
        }
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

/// An open app, as system audio "By App" offers it.
struct AudioApplication: Identifiable {
    /// Its bundle ID, what system audio records by (`SystemAudioChoice.applications`).
    let id: String
    let name: String
    let icon: NSImage?
    /// One of its processes (a helper's bundle ID starts with the app's and a dot) plays audio now.
    let isPlayingAudio: Bool
}

/// The open apps system audio can record by app: the ones with a window in the Dock, not this one, by name, the
/// ones playing audio now first. Kept up to date while apps open and quit; which ones play audio is read off the
/// main thread each time.
@MainActor @Observable
final class AudioApplicationList {
    private(set) var applications: [AudioApplication] = []

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Only the newest listing is kept.
    @ObservationIgnored private var generation = 0

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
        refresh()
    }

    /// Reads the open apps again, and which of them play audio.
    func refresh() {
        generation += 1
        let generation = generation
        Task.detached(priority: .utility) { [weak self] in
            let playing = DeviceLists.playingBundleIDs()
            await self?.update(playing: playing, generation: generation)
        }
    }

    /// `bundleID`'s name and icon, whether or not it is open.
    func application(_ bundleID: String) -> AudioApplication {
        if let open = applications.first(where: { $0.id == bundleID }) { return open }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return AudioApplication(
            id: bundleID, name: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID,
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, isPlayingAudio: false)
    }

    private func update(playing: Set<String>, generation: Int) {
        guard generation == self.generation else { return }
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        let open = NSWorkspace.shared.runningApplications.compactMap { app -> AudioApplication? in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, bundleID != own,
                seen.insert(bundleID).inserted
            else { return nil }
            let plays = playing.contains { $0 == bundleID || $0.hasPrefix(bundleID + ".") }
            return AudioApplication(id: bundleID, name: app.localizedName ?? bundleID, icon: app.icon, isPlayingAudio: plays)
        }
        applications = open.sorted { first, second in
            if first.isPlayingAudio != second.isPlayingAudio { return first.isPlayingAudio }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}
