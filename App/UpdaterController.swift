// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import Sparkle
import os

/// Sparkle's standard updater, with the app's rules for a take being recorded: no update check runs, neither
/// from the menu (its item is off) nor scheduled (`updater(_:mayPerform:)` refuses it, and the refused check
/// runs once the take is closed), so no update window shows up in a recording; and an update being installed
/// relaunches the app only once neither a take nor an export is in progress, so a relaunch never cuts one off.
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
    @ObservationIgnored private let exportGate: ExportGate
    @ObservationIgnored private let relaunchGate = UpdateRelaunchGate()
    @ObservationIgnored private let checkGate = UpdateCheckGate()
    @ObservationIgnored private var standardController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Updates")

    /// A take is being recorded or an export runs: a relaunch waits.
    private var isBusy: Bool { recording.isRecording || exportGate.isBusy }

    init(recording: RecordingController, exportGate: ExportGate) {
        self.recording = recording
        self.exportGate = exportGate
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

    /// Called whenever an export starts or ends. Once nothing is in progress, a postponed relaunch goes ahead.
    func exportStateChanged() {
        relaunchGate.busyChanged(isBusy: isBusy)
    }

    /// Called whenever a take starts or ends. Once nothing is in progress, a relaunch postponed for an update
    /// goes ahead; or else, once the take ends, a check refused during it runs.
    func recordingStateChanged() {
        let isRecording = recording.isRecording
        relaunchGate.busyChanged(isBusy: isBusy)
        guard checkGate.recordingChanged(isRecording: isRecording), let standardController,
            isStarted, standardController.updater.canCheckForUpdates
        else { return }
        Self.logger.notice("Checking for updates now that the take is closed")
        standardController.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard checkGate.mayCheck(isRecording: recording.isRecording) else {
            Self.logger.notice("No update check while recording; it runs once the take is closed")
            throw NSError(
                domain: "dev.toma.Toma.Updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Updates are checked once the recording ends.")])
        }
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let postpone = relaunchGate.shouldPostpone(isBusy: isBusy, relaunch: installHandler)
        if postpone {
            Self.logger.notice("Update \(item.displayVersionString, privacy: .public) installs once the take is closed and no export runs")
        }
        return postpone
    }
}
