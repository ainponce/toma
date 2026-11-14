// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import Sparkle
import os

/// Sparkle's standard updater, with the app's rules: no checking for updates while a take is being recorded,
/// and an update installed meanwhile relaunches the app only once the take is closed.
///
/// A build without an EdDSA public key (`SPARKLE_PUBLIC_KEY` empty) does not start the updater at launch:
/// Sparkle would refuse to start and show an alert every time. Checking for updates shows that alert instead.
@MainActor @Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    /// The updater runs: it checks for updates on its own and on request.
    private(set) var isStarted = false
    /// No check or update is in progress, so one can start.
    private(set) var canCheckForUpdates = false

    /// "Check for Updates…" can be chosen: also when the updater is not started, to show why.
    var isCheckAvailable: Bool { !isStarted || canCheckForUpdates }

    @ObservationIgnored private let recording: RecordingController
    @ObservationIgnored private let relaunchGate = UpdateRelaunchGate()
    @ObservationIgnored private var standardController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Updates")

    init(recording: RecordingController) {
        self.recording = recording
        super.init()
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let hasPublicKey = !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let controller = SPUStandardUpdaterController(startingUpdater: hasPublicKey, updaterDelegate: self, userDriverDelegate: nil)
        standardController = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
        // Starting succeeds at once, or fails with Sparkle's alert; checking for updates tries again.
        isStarted = hasPublicKey && controller.updater.canCheckForUpdates
        if !hasPublicKey {
            Self.logger.notice("This build has no EdDSA public key: the updater is not started")
        }
    }

    func checkForUpdates() {
        guard let standardController else { return }
        if !isStarted {
            // Without a valid key this fails, and Sparkle says so in an alert.
            standardController.startUpdater()
            guard standardController.updater.canCheckForUpdates else { return }
            isStarted = true
        }
        standardController.checkForUpdates(nil)
    }

    /// Called whenever a take starts or ends: a relaunch postponed for an update goes ahead once it ends.
    func recordingStateChanged() {
        relaunchGate.recordingChanged(isRecording: recording.isRecording)
    }

    // MARK: - SPUUpdaterDelegate

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let postpone = relaunchGate.shouldPostpone(isRecording: recording.isRecording, relaunch: installHandler)
        if postpone {
            Self.logger.notice("Update \(item.displayVersionString, privacy: .public) installs once the take is closed")
        }
        return postpone
    }
}
