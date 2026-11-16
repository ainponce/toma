// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Library
import ProjectFormat
import QuartzCore
import Recording
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
        if let folder = Self.libraryBenchFolder {
            // Once the app has finished launching (its menu bar item, its scenes): the library opens in a running app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self.runLibraryBench(folder: folder) }
            }
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
    /// cancelled first, within `QuitSequencer.quitTimeLimit` for the take, and the library's copies are waited for;
    /// the user is asked before an export is cancelled, unless the Mac is powering off. A start that ended without a
    /// take counts as a take while Do Not Disturb goes off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = TerminationDecision.decide(
            isRecording: recording.isRecording || recording.isEndingHooks, isExporting: exportGate.isBusy,
            isPoweringOff: quit.isPoweringOff, isCopying: LibraryWork.shared.isCopying)
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

    // MARK: - -TomaLibraryBench

    /// `Toma -TomaLibraryBench <folder>`: the folder the library opens over.
    private static var libraryBenchFolder: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TomaLibraryBench"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Opens the library window over `folder` with its cached index (`index.json` in it, as `reconcileAndIndexAThousand`
    /// leaves it, written again by the library as it goes), as the app opens it, without the onboarding, the recovery or
    /// anything that asks (design §15). Writes to stdout `first-frame <ms>`, from the moment it starts opening until the
    /// index's cards are laid out, drawn and handed to the window server, and `longest-main-wait <ms>`, the longest the
    /// main thread stayed busy without going back to wait for events from that frame until the library settled (its walk
    /// ended and the thumbnails of the cards on the screen were looked for) and a second more; then writes the index and
    /// quits, with 1 if it did not settle within 60 s, unless `-TomaLibraryBenchKeepOpen` is given too.
    private func runLibraryBench(folder: String) {
        let start = ContinuousClock.now
        let watch = MainThreadWatch()
        let model = LibraryModel(
            paths: .bench(folder: URL(filePath: folder, directoryHint: .isDirectory)),
            host: LibraryHost(open: { [weak self] url in self?.showEditor(for: url, take: nil) }),
            preferences: LibraryPreferences()
        ) { _ in }
        let controller = LibraryWindowController(model: model) {}
        var firstFrame: Duration?
        var cards = 0
        controller.showWhenLoaded { [weak controller] in
            guard let controller, let window = controller.window else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            // Laid out, drawn and handed to the window server now.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            firstFrame = start.duration(to: .now)
            watch.start()
            DispatchQueue.main.async { MainActor.assumeIsolated { cards = model.cardsOnScreen } }
        }
        Task {
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline, firstFrame == nil || !model.isSettled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let settled = firstFrame != nil && model.isSettled
            try? await Task.sleep(for: .seconds(1))
            watch.stop()
            func milliseconds(_ duration: Duration?) -> String {
                guard let duration else { return "none" }
                return String(format: "%.1f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3)
            }
            print("first-frame \(milliseconds(firstFrame))")
            print("longest-main-wait \(milliseconds(watch.longest))")
            print("projects \(model.counts[.all] ?? 0) cards-on-screen \(cards) settled \(settled)")
            fflush(stdout)
            // `-TomaLibraryBenchKeepOpen`: the window stays, for the owner's checks (design §16.2); ⌘Q quits.
            guard !ProcessInfo.processInfo.arguments.contains("-TomaLibraryBenchKeepOpen") else { return }
            await model.close()
            exit(settled ? 0 : 1)
        }
        libraryBench = controller
    }

    /// The window of `-TomaLibraryBench`, kept while it runs.
    private var libraryBench: LibraryWindowController?
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

#if DEBUG
/// How long the main thread stays busy without going back to wait for events (`-TomaLibraryBench`): each stretch from
/// the run loop waking up until it waits again, the one under way when it starts included.
@MainActor
private final class MainThreadWatch {
    private(set) var longest: Duration = .zero
    private var busySince: ContinuousClock.Instant?
    private var observer: CFRunLoopObserver?

    func start() {
        guard observer == nil else { return }
        busySince = .now
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        if let busySince { longest = max(longest, busySince.duration(to: .now)) }
        busySince = nil
    }

    private func note(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting {
            busySince = .now
        } else if let busySince {
            longest = max(longest, busySince.duration(to: .now))
            self.busySince = nil
        }
    }
}
#endif
