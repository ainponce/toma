// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import Recording
import UniformTypeIdentifiers
import os

/// Owns the recording, the updater, the island, the windows and the app's life: the recovery prompt at
/// launch (and Do Not Disturb turned off if a take left it on), the permissions, settings and licenses windows,
/// the global shortcuts, editors (also for projects opened from Finder), the Dock icon, and what a quit waits for
/// (`QuitSequencer`).
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
    /// Whether the desktop's icons are hidden while recording, shared by the island's settings card and the settings
    /// window.
    private let hideDesktopIcons: HideDesktopIconsSetting
    /// Turns Do Not Disturb on and off around each take with the user's shortcut.
    private let focus = FocusGuard(runner: ShortcutsCLI())
    /// The shortcut it runs, shared by the island's settings card and the settings window.
    private let focusShortcut: FocusShortcutSetting
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
        let environment = LiveTakeEnvironment.make(cameraHost: cameraHost) {
            controller?.windowVisibilityChanged($0, inProjectAt: $1)
        }
        recording = RecordingController(probe: probe, environment: environment, hooks: LiveTakeHooks(focus: focus, store: store))
        controller = recording
        updater = UpdaterController(recording: recording, exportGate: exportGate)
        hotKeys = HotKeyCenter(bindings: store.settings.hotKeys)
        countdown = CountdownSetting(store: store)
        afterStop = AfterStopSetting(store: store)
        hideDesktopIcons = HideDesktopIconsSetting(store: store)
        focusShortcut = FocusShortcutSetting(store: store, runner: ShortcutsCLI())
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
        #if DEBUG
        if let path = Self.editorStructureDumpPath {
            dumpEditorStructure(of: path)
            return
        }
        #endif
        // The cache folders of projects not opened for 30 days (plan decision 27), off the main thread, only while no
        // project is open: projects opened from the Finder at launch are here already (`application(_:open:)` comes
        // before this), and their folders are left alone until the next launch.
        if editors.isEmpty {
            Task.detached(priority: .utility) { ProjectCaches.removeUnused(root: ProjectCaches.defaultRoot, now: Date()) }
        }
        // A take that turned Do Not Disturb on and never ended (the app was killed): turned off now. A take started
        // meanwhile runs its shortcut after this one.
        Task { await focus.recoverAfterLaunch() }
        let island = IslandPanel(
            recording: recording, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop,
            hideDesktopIcons: hideDesktopIcons, focusShortcut: focusShortcut, probe: probe, cameraHost: cameraHost)
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
    /// is cancelled, unless the Mac is powering off. A start that ended without a take counts as a take while Do Not
    /// Disturb goes off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = TerminationDecision.decide(
            isRecording: recording.isRecording || recording.isEndingHooks, isExporting: exportGate.isBusy,
            isPoweringOff: quit.isPoweringOff)
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
        quit.powerOff(isRecording: recording.isRecording || recording.isEndingHooks)
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

    /// The editors' windows close with the app: their states are written as when one closes (design §5.1), and waited for.
    func applicationWillTerminate(_ notification: Notification) {
        for editor in editors.values { editor.writeStateBeforeQuit() }
        EditorStateWriter.flush()
    }

    // MARK: - Menu actions

    /// Opens the island on the screen with the pointer.
    func newRecording() {
        island?.invoke()
    }

    /// File ▸ Open… (⌘O, design §5.1): the projects chosen in an open panel that shows only Toma's projects, from the
    /// projects folder, open in the editor (one open already comes to the front).
    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.fileExtension, conformingTo: .package) ?? .package]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = recording.projectsFolder
        NSApp.activate()
        Task {
            guard await panel.begin() == .OK else { return }
            for url in panel.urls { showEditor(for: url, take: nil) }
        }
    }

    func recoverRecordings() {
        Task { await recovery.run(in: recording.projectsFolder, atLaunch: false) }
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                probe: probe, openSettings: { [weak self] in self?.showSettings() }
            ) { [weak self] in
                guard let self, onboarding?.window?.isVisible != true else { return }  // shown again meanwhile
                onboarding = nil
                updateActivationPolicy()
            }
        }
        present(onboarding)
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                store: store, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop, hideDesktopIcons: hideDesktopIcons,
                focusShortcut: focusShortcut
            ) { [weak self] in
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

    #if DEBUG
    // MARK: - -TomaDumpEditorStructure

    /// `Toma -TomaDumpEditorStructure <package>`: the package to open and describe.
    private static var editorStructureDumpPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TomaDumpEditorStructure"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Opens the package in an editor, without the onboarding, the recovery or anything that asks, and once it has
    /// opened (or could not) and its bar has its items, writes to stdout a line `toolbar:` with the identifiers of the
    /// bar's items and a line `split:` with those of the splits' parts, in order, and quits: with 0, or with 1 if that
    /// did not happen within 30 s.
    private func dumpEditorStructure(of path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL
        showEditor(for: key, take: nil)
        Task {
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline, editors[key]?.structureIsSettled != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // The bar's items arrive from SwiftUI over a few turns of the run loop.
            try? await Task.sleep(for: .milliseconds(500))
            let editor = editors[key]
            print("toolbar: " + (editor?.toolbarIdentifiers ?? []).joined(separator: " "))
            print("split: " + (editor?.splitIdentifiers ?? []).joined(separator: " "))
            fflush(stdout)
            exit(editor?.structureIsSettled == true ? 0 : 1)
        }
    }
    #endif

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

    /// Opens the project at `url` in an editor. One open already (also through a symlink, or after it was moved) comes to
    /// the front instead: never a second session on the same package. A new editor shows its window once the state it was
    /// left in is read and applied (its frame, its panel).
    func showEditor(for url: URL, take: String?) {
        let key = url.standardizedFileURL
        if let editor = openEditor(of: key) {
            editor.reloadIfNeeded()
            // One still reading its state shows itself once it has.
            if editor.isRestored { present(editor) }
            return
        }
        if let moved = editors[key] {
            // Its package was moved away while open and another one is at its path now: it stays open, under its
            // package's place.
            editors[key] = nil
            editors[moved.currentPackageURL] = moved
        }
        weak var made: EditorWindowController?
        let editor = EditorWindowController(
            packageURL: key, takeID: take, exportGate: exportGate,
            onRecovered: { [weak self] url in self?.recording.noteRecovered(url) }
        ) { [weak self] in
            guard let self, let made, made.window?.isVisible != true else { return }  // shown again meanwhile
            editors = editors.filter { $0.value !== made }
            updateActivationPolicy()
        }
        made = editor
        editors[key] = editor
        Task {
            await editor.restoreWindowState()
            // Gone meanwhile: nothing to show.
            guard editors.values.contains(where: { $0 === editor }) else { return }
            present(editor)
        }
    }

    /// The editor that has the package at `url` open: one whose package is that folder (`PackageIdentity`), also through
    /// a symlink or where it was moved to; by its path only when nothing is there now. The folder comes first: the path an
    /// editor was opened from may hold another package by now.
    private func openEditor(of url: URL) -> EditorWindowController? {
        guard let identity = PackageIdentity(url) else { return editors[url] }
        return editors.values.first { $0.showsPackage(identity) }
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
