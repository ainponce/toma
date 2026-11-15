// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import os

/// Owns the recording, the updater, the island, the windows and the app's life: the recovery prompt at
/// launch, the permissions, settings and licenses windows, the global shortcuts, editors (also for projects
/// opened from Finder), the Dock icon, and closing a take before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recording: RecordingController
    let updater: UpdaterController
    /// The global shortcuts.
    let hotKeys: HotKeyCenter
    private let probe: any PermissionProbe = SystemPermissionProbe()
    private let store = SettingsStore()
    /// The countdown before a take, shared by the island's settings card and the settings window.
    private let countdown: CountdownSetting
    /// What a stop does once the take is saved, shared by the island's settings card and the settings window.
    private let afterStop: AfterStopSetting
    private let recovery = RecoveryPrompt()
    private let exportGate = ExportGate()
    private var editors: [URL: EditorWindowController] = [:]
    private var onboarding: OnboardingWindowController?
    private var notices: ThirdPartyNoticesWindowController?
    private var settings: SettingsWindowController?
    /// The recording control at the notch; made once the app has launched.
    private var island: IslandPanel?
    private var powerOffObserver: (any NSObjectProtocol)?
    /// The take is being closed to quit or power off.
    private var closingForQuit = false
    /// Logging out, restarting or shutting down: nobody is asked before an export is cancelled.
    private var poweringOff = false
    /// Closing to quit has taken longer than `quitTimeLimit`.
    private var quitTimeLimitPassed = false
    /// `applicationShouldTerminate` answered `.terminateLater` and waits for a reply.
    private var terminationPending = false
    private var terminationReplied = false

    /// How long quitting waits for the take to close.
    private static let quitTimeLimit = Duration.seconds(30)

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    override init() {
        recording = RecordingController(probe: probe, environment: LiveTakeEnvironment.make())
        updater = UpdaterController(recording: recording, exportGate: exportGate)
        hotKeys = HotKeyCenter(bindings: store.settings.hotKeys)
        countdown = CountdownSetting(store: store)
        afterStop = AfterStopSetting(store: store)
        super.init()
        hotKeys.perform = { [weak self] action in self?.perform(action) }
        exportGate.busyChanged = { [weak self] in self?.updater.exportStateChanged() }
        recording.openEditor = { [weak self] url, take in self?.showEditor(for: url, take: take) }
        recording.openOnboarding = { [weak self] in self?.showOnboarding() }
        recording.showStartFailure = { [weak self] error in self?.showStartFailure(error) }
        recording.recordingStateChanged = { [weak self] in
            guard let self else { return }
            // Never activated by the take ending: the editor activates the app when it opens, and with "Stay
            // Where I Am" nothing does.
            updateActivationPolicy(activatingIfRegular: false)
            updater.recordingStateChanged()
            hotKeys.update(isRecording: recording.isRecording)
        }
        recovery.recovered = { [weak self] urls in self?.showRecovered(urls) }
    }

    // MARK: - Life cycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let island = IslandPanel(recording: recording, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop)
        // Opening or closing the island never activates the app.
        island.selectingChanged = { [weak self] in self?.updateActivationPolicy(activatingIfRegular: false) }
        recording.onConfirmation = { [weak island] confirmation in island?.showConfirmation(confirmation) }
        self.island = island
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willPowerOff() }
        }
        Task {
            await recovery.run(in: recording.projectsFolder, atLaunch: true)
            if PermissionsModel.needsAttention(probe: probe) { showOnboarding() }
        }
    }

    /// Nothing in progress is lost to a quit (`TerminationDecision`). A take in progress is closed before
    /// quitting: the app quits once `stop()` returns (even if closing failed: the take can still be recovered),
    /// or after `quitTimeLimit` if it has not returned by then. An export in progress is cancelled only once
    /// the user says so (without asking while powering off), and the app quits once it has ended and removed
    /// its partial file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = TerminationDecision.decide(
            isRecording: recording.isRecording, isExporting: exportGate.isBusy, isPoweringOff: poweringOff)
        switch decision {
        case .now:
            return .terminateNow
        case .closeTakeFirst:
            if quitTimeLimitPassed {
                // Closing for a power off already took too long.
                Self.logger.error("Quitting before the take closed; it stays recoverable")
                return .terminateNow
            }
            Self.logger.notice("Quitting while recording: closing the take first")
            terminationPending = true
            closeTakeBeforeQuitting()
            return .terminateLater
        case .confirmCancelExport(let alsoClosingTake):
            guard confirmCancellingExport() else { return .terminateCancel }
            cancelExportsBeforeQuitting(alsoClosingTake: alsoClosingTake)
            return .terminateLater
        case .cancelExportFirst(let alsoClosingTake):
            cancelExportsBeforeQuitting(alsoClosingTake: alsoClosingTake)
            return .terminateLater
        }
    }

    private func confirmCancellingExport() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "An export is in progress. Quit and cancel it?")
        alert.informativeText = String(localized: "The video being exported isn't saved. The project isn't changed.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Cancels the export and waits for it to end (it removes its partial file), closes the take too when
    /// asked, and then lets the pending quit go ahead.
    private func cancelExportsBeforeQuitting(alsoClosingTake: Bool) {
        terminationPending = true
        Self.logger.notice("Quitting during an export: cancelling it first")
        let open = Array(editors.values)
        Task {
            for editor in open { await editor.cancelExportAndWait() }
            if alsoClosingTake, recording.isRecording {
                closeTakeBeforeQuitting()  // replies once the take is closed, or after the time limit
            } else {
                replyToTermination(takeClosed: true)
            }
        }
    }

    /// Logging out, restarting or shutting down: the take starts closing now, before the system asks the
    /// app to quit, which then waits for the same stop and the same time limit.
    private func willPowerOff() {
        poweringOff = true
        guard recording.isRecording else { return }
        Self.logger.notice("Powering off while recording: closing the take")
        closeTakeBeforeQuitting()
    }

    /// Starts closing the take, once, with `quitTimeLimit`; whichever ends first answers a pending quit.
    private func closeTakeBeforeQuitting() {
        guard !closingForQuit else { return }
        closingForQuit = true
        let deadline = Task {
            // Suspending: the limit stops counting while the Mac sleeps, so closing the lid after quitting does
            // not use it up and quit before the take is closed.
            try? await Task.sleep(for: Self.quitTimeLimit, clock: .suspending)
            guard !Task.isCancelled else { return }
            quitTimeLimitPassed = true
            replyToTermination(takeClosed: false)
        }
        Task {
            await recording.stop(openingEditor: false)
            deadline.cancel()
            closingForQuit = false
            quitTimeLimitPassed = false
            replyToTermination(takeClosed: true)
        }
    }

    /// Lets a pending quit go ahead; only the first call replies.
    private func replyToTermination(takeClosed: Bool) {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        if !takeClosed { Self.logger.error("Quitting before the take closed; it stays recoverable") }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Projects opened from Finder (or dropped on the app) open in the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == ProjectPackage.fileExtension {
            showEditor(for: url, take: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu actions

    /// Opens the island on the screen with the pointer.
    func newRecording() {
        island?.invoke()
    }

    func recoverRecordings() {
        Task { await recovery.run(in: recording.projectsFolder, atLaunch: false) }
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(probe: probe) { [weak self] in
                guard let self, onboarding?.window?.isVisible != true else { return }  // shown again meanwhile
                onboarding = nil
                updateActivationPolicy()
            }
        }
        present(onboarding)
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop) { [weak self] in
                guard let self, settings?.window?.isVisible != true else { return }  // shown again meanwhile
                settings = nil
                updateActivationPolicy()
            }
        }
        present(settings)
    }

    /// A global shortcut was pressed.
    private func perform(_ action: HotKeyAction) {
        switch action {
        case .islandOrStop: island?.shortcutPressed()
        case .pauseResume: recording.togglePause()
        case .marker: recording.addMarker()
        case .restartTake: recording.restartTake()
        }
    }

    func showThirdPartyNotices() {
        if notices == nil {
            notices = ThirdPartyNoticesWindowController { [weak self] in
                guard let self, notices?.window?.isVisible != true else { return }  // shown again meanwhile
                notices = nil
                updateActivationPolicy()
            }
        }
        present(notices)
    }

    // MARK: - Windows

    /// Inside the island, above Record: an alert would activate the app during a take.
    private func showStartFailure(_ error: any Error) {
        guard let island else {
            Self.logger.error("A take could not start before the island was made: \(String(describing: error), privacy: .public)")
            return
        }
        island.startFailed(error)
    }

    /// After recovery: every recovered project is the last project in turn, open editors on them load again,
    /// and a few more open (`RecoveredProjects`); the recovery alert has listed them all.
    private func showRecovered(_ urls: [URL]) {
        guard let last = urls.last else { return }
        recording.noteRecovered(last)
        let (reload, open) = RecoveredProjects.editors(recovered: urls, openEditors: Set(editors.keys))
        for url in reload { editors[url]?.reloadIfNeeded() }
        for url in open { showEditor(for: url, take: nil) }
    }

    func showEditor(for url: URL, take: String?) {
        let key = url.standardizedFileURL
        if let editor = editors[key] {
            editor.reloadIfNeeded()
            present(editor)
            return
        }
        let editor = EditorWindowController(
            packageURL: key, takeID: take, exportGate: exportGate,
            onRecovered: { [weak self] url in self?.recording.noteRecovered(url) }
        ) { [weak self] in
            guard let self, editors[key]?.window?.isVisible != true else { return }  // shown again meanwhile
            editors[key] = nil
            updateActivationPolicy()
        }
        editors[key] = editor
        present(editor)
    }

    private func present(_ controller: NSWindowController?) {
        updateActivationPolicy()
        NSApp.activate()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    /// In the Dock and Cmd-Tab only while a window is open, no take is being recorded and the island is
    /// not open or choosing. The island's own panels are not windows here.
    private func updateActivationPolicy(activatingIfRegular: Bool = true) {
        let openWindows = editors.count + (onboarding == nil ? 0 : 1) + (notices == nil ? 0 : 1) + (settings == nil ? 0 : 1)
        let policy = ActivationPolicyDecision.policy(
            openWindows: openWindows, isRecording: recording.isRecording, isSelecting: island?.isSelecting ?? false)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular, activatingIfRegular { NSApp.activate() }
    }
}
