// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import Recording
import os

/// Owns the recording, the updater, the island, the windows and the app's life: the recovery prompt at
/// launch, the permissions, settings and licenses windows, the global shortcuts, editors (also for projects
/// opened from Finder), the Dock icon, and what a quit waits for (`QuitSequencer`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recording: RecordingController
    let updater: UpdaterController
    /// The global shortcuts.
    let hotKeys: HotKeyCenter
    private let probe: any PermissionProbe = SystemPermissionProbe()
    /// The app's one camera session: the bubble shows it and the take records it (plan decision 28).
    private let cameraHost = CameraSessionHost()
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
    /// Closes the take and cancels the exports before a quit goes ahead. Its time limit runs on the suspending
    /// clock: it stops counting while the Mac sleeps, so closing the lid after quitting does not use it up and
    /// quit before the take is closed.
    private lazy var quit = QuitSequencer(
        closeTake: { [recording] in await recording.stop(openingEditor: false) },
        cancelExports: { [weak self] in
            guard let self else { return }
            for editor in Array(editors.values) { await editor.cancelExportAndWait() }
        },
        reply: { _ in NSApp.reply(toApplicationShouldTerminate: true) },
        sleep: { try await Task.sleep(for: $0, clock: .suspending) })

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    override init() {
        // The controller hears whether the window it records can be seen; it is made with the environment that tells.
        weak var controller: RecordingController?
        let environment = LiveTakeEnvironment.make(cameraHost: cameraHost) { controller?.windowVisibilityChanged($0) }
        recording = RecordingController(probe: probe, environment: environment)
        controller = recording
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
        let island = IslandPanel(
            recording: recording, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop, probe: probe, cameraHost: cameraHost)
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

    /// Nothing in progress is lost to a quit (`TerminationDecision`): the take is closed and the exports are
    /// cancelled first, within `QuitSequencer.quitTimeLimit` for the take; the user is asked before an export
    /// is cancelled, unless the Mac is powering off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = TerminationDecision.decide(
            isRecording: recording.isRecording, isExporting: exportGate.isBusy, isPoweringOff: quit.isPoweringOff)
        return quit.shouldTerminate(decision) { confirmCancellingExport() }
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

    /// Logging out, restarting or shutting down: the take starts closing now, before the system asks the
    /// app to quit.
    private func willPowerOff() {
        quit.powerOff(isRecording: recording.isRecording)
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
