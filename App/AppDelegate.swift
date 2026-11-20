// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Export
import Library
import ProjectFormat
import QuartzCore
import SwiftUI
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
    /// Dark unless the user chose otherwise; applied as the app launches, before any window shows.
    let appearance = AppearanceSetting()
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
    /// The editors whose windows closed and whose sessions are still closing (`EditorModel.closing`), by a number of
    /// their own, with where their packages were: a quit waits for them too, and the library counts them as open.
    private var closingEditors: [Int: (place: EditorPlace, task: Task<Void, Never>)] = [:]
    private var closedEditors = 0
    private var onboarding: OnboardingWindowController?
    #if DEBUG
    /// The window of the `formats` showcase.
    private var showcaseWindow: NSWindow?
    #endif
    private var notices: ThirdPartyNoticesWindowController?
    private var settings: SettingsWindowController?
    /// The library's one window, while it is open (design §6.1).
    private var library: LibraryWindowController?
    /// Whether a take is recorded, for the finishing of deletions at launch (`finishPendingDeletions`).
    private let launchState = LaunchLibraryState()
    /// The package the take records into, as the library was last told, and whether it was told a take recorded.
    private var libraryTakePackage: URL?
    private var libraryWasRecording = false
    /// The last package a take recorded into, which the library looks at once the take ends.
    private var libraryLastTake: URL?
    /// The packages opened from outside the projects folder this session: Other Places, once the library is open.
    private var openedElsewhere: Set<URL> = []
    /// The library's records (`library.json`): one store for the app, read off the main thread the first time it is
    /// needed. The library's window and the editors' actions share it, so what one writes (where a project in the trash
    /// came from) the other never writes over.
    private lazy var libraryRecords = Task.detached(priority: .userInitiated) {
        LibraryRecordsStore(url: LibraryRecords.defaultURL)
    }
    /// The packages edited here, looked at by the library once the edits pause.
    private var editedPackages: Set<URL> = []
    private var editedLook: Task<Void, Never>?
    /// How long edits are gathered before the library looks at the packages they changed.
    private static let editedLookDelay = Duration.seconds(1)
    /// The recording control at the notch; made once the app has launched.
    private var island: IslandPanel?
    /// The editor hidden for its "Re-record from Here" (phase 3 design §8.2), until the recorder tells how it ended: one at
    /// a time.
    private weak var rerecordingEditor: EditorWindowController?
    private var powerOffObserver: (any NSObjectProtocol)?
    /// Cancels the exports, closes the take and the editors, and waits for the library's copies (`LibraryWork.shared`, its
    /// default) before a quit goes ahead. Its time limits run on the suspending clock: they stop counting while the Mac
    /// sleeps, so closing the lid after quitting does not use them up and quit before the take is closed.
    private lazy var quit = QuitSequencer(
        closeTake: { [recording] in await recording.stop(openingEditor: false) },
        cancelExports: { [weak self] in
            guard let self else { return }
            for editor in Array(editors.values) { await editor.cancelExportAndWait() }
        },
        closeEditors: { [weak self] in
            guard let self else { return }
            // Every one closed first, so none takes an edit while another's session closes; then all waited for, those
            // of windows closed just before too.
            let open = Array(editors.values)
            for editor in open { editor.closeForQuit() }
            for editor in open { await editor.model.waitUntilClosed() }
            for closing in Array(closingEditors.values) { await closing.task.value }
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
        recording.takePackageChanged = { [weak self] in self?.takePackageChanged() }
        recording.rerecordEnded = { [weak self] target, outcome in self?.rerecordEnded(target, outcome) }
        recording.recordingStateChanged = { [weak self] in
            guard let self else { return }
            tellLibraryTake()
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
        if let showcase = Self.showcase {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self.runShowcase(showcase.surface, path: showcase.path) }
            }
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
        // What a crash left half done in the trash and the projects folder (design §6.4): off the main thread, after the
        // library's own work (it is paused while a take is recorded).
        let projectsFolder = recording.projectsFolder, launchState = launchState, records = libraryRecords
        Task.detached(priority: .utility) {
            let operations = LibraryOperations(
                projectsFolder: projectsFolder, fileSystem: SystemFileSystem(), records: await records.value, app: launchState)
            await operations.finishPendingDeletions()
        }
        // A take that turned Do Not Disturb on and never ended (the app was killed): turned off now. A take started
        // meanwhile runs its shortcut after this one.
        Task { await focus.recoverAfterLaunch() }
        // The named styles: the default style of 1b becomes «My Style» the first time (1c design §8).
        StyleCatalog.shared.start()
        makeIsland()
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

    /// The recording control at the notch.
    private func makeIsland() {
        let island = IslandPanel(
            recording: recording, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop,
            hideDesktopIcons: hideDesktopIcons, focusShortcut: focusShortcut, probe: probe, cameraHost: cameraHost)
        // Opening or closing the island never activates the app.
        island.selectingChanged = { [weak self] in self?.updateActivationPolicy(activatingIfRegular: false) }
        island.openLibrary = { [weak self] in self?.showLibrary(section: $0) }
        recording.onConfirmation = { [weak island] confirmation in island?.showConfirmation(confirmation) }
        self.island = island
    }

    /// Nothing in progress is lost to a quit (`TerminationDecision`): edits an editor couldn't save are asked about first
    /// (as closing its window asks, also while powering off); the take is closed and the exports are cancelled, within
    /// `QuitSequencer.quitTimeLimit` for the take; the user is asked before an export is cancelled, unless the Mac is
    /// powering off; then the editors' sessions are closed and waited for, within `QuitSequencer.editorsTimeLimit`; last,
    /// the library's copies are waited for (`LibraryWork`). A start that ended without a take counts as a take while Do
    /// Not Disturb goes off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An editor whose window is closing counts until it leaves `editors`: its session is closing.
        let decision = TerminationDecision.decide(
            isRecording: recording.isRecording || recording.isEndingHooks, isExporting: exportGate.isBusy,
            isPoweringOff: quit.isPoweringOff, isCopying: LibraryWork.shared.isCopying,
            hasEditSessions: !editors.isEmpty || !closingEditors.isEmpty,
            hasUnsavedEdits: editors.values.contains { !$0.model.closed && $0.model.losesEditsIfClosed })
        return quit.shouldTerminate(decision) { question in
            switch question {
            case .unsavedEdits: confirmQuittingWithUnsavedEdits()
            case .cancelExport: confirmCancellingExport()
            }
        }
    }

    /// "Some changes couldn't be saved · If you quit now, they're lost." with "Cancel", the default, and "Quit Anyway".
    private func confirmQuittingWithUnsavedEdits() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Some changes couldn't be saved", comment: "Closing an editor whose last changes are not on the disk")
        alert.informativeText = String(
            localized: "If you quit now, they're lost.", comment: "Quitting while an editor's last changes are not on the disk")
        alert.addButton(withTitle: String(localized: "Cancel"))
        let quit = alert.addButton(withTitle: String(
            localized: "Quit Anyway", comment: "Quitting while an editor's last changes are not on the disk: they are lost"))
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
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

    /// Projects opened from Finder (or dropped on the app) open in the editor; styles (`.tomastyle`) are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == ProjectPackage.fileExtension {
            showEditor(for: url, take: nil)
        }
        let styles = urls.filter(StyleMenu.isStyleFile)
        if !styles.isEmpty { StyleCatalog.shared.openFromFinder(styles) }
    }

    /// Opening Toma again (from Finder, Spotlight or the Launchpad) while no window of it is open opens the library; closing
    /// the last editor never does (design §6.1). The island's panels are not windows here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !hasOpenWindow { showLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The editors' windows close with the app: their states were written as their sessions closed for the quit
    /// (`QuitSequencer`), as when one closes (design §5.1); any still open is written now, and all are waited for.
    func applicationWillTerminate(_ notification: Notification) {
        for editor in editors.values where !editor.model.closed { editor.writeStateBeforeQuit() }
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

    /// The library's Recuperar (design §6.6): 1b's recovery of the takes of that one package that did not finish saving.
    private func recoverPackage(_ url: URL) {
        Task { await recovery.run(package: url) }
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

    /// Opens the library, or brings it forward, on `section` if one is given.
    func showLibrary(section: LibrarySection? = nil) {
        // A window that closed and is not yet let go of: its model is done.
        if let current = library, current.model.closed { library = nil }
        let controller: LibraryWindowController
        if let current = library {
            controller = current
        } else {
            let records = libraryRecords
            let model = LibraryModel(
                paths: .standard(projectsFolder: recording.projectsFolder),
                host: LibraryHost(
                    open: { [weak self] url in
                        // Once a quit began, no editor opens (a copy that "Duplicar como" opens): the quit closed them.
                        guard !LibraryWork.shared.isStopped else { return }
                        self?.showEditor(for: url, take: nil)
                    },
                    record: { [weak self] in self?.island?.invoke() },
                    recordShortcut: { [weak self] in self?.hotKeys.bindings.combos[.islandOrStop]?.displayString ?? "" },
                    close: { [weak self] url in await self?.closeEditor(at: url) ?? true },
                    holdsEditLock: { [weak self] url in self?.editor(at: url)?.model.access == .editable },
                    hasUnsavedChanges: { [weak self] url in self?.editor(at: url)?.model.losesEditsIfClosed ?? false },
                    recover: { [weak self] url in self?.recoverPackage(url) },
                    moved: { [weak self] in self?.libraryMovedPackages() },
                    records: { await records.value }),
                preferences: store.settings.library
            ) { [weak self] in self?.store.settings.library = $0 }
            controller = LibraryWindowController(model: model) { [weak self] in
                // Another window was made meanwhile.
                guard let self, library?.model === model else { return }
                library = nil
                updateActivationPolicy()
            }
            library = controller
            libraryTakePackage = nil
            libraryWasRecording = false
            libraryLastTake = nil
            tellLibraryTake()
            tellLibraryEditors()
            if !openedElsewhere.isEmpty { model.look(at: Array(openedElsewhere)) }
        }
        if let section { controller.model.section = section }
        if controller.window?.isVisible == true {
            present(controller)
        } else {
            updateActivationPolicy(activatingIfRegular: false)
            controller.showWhenLoaded { [weak self, weak controller] in
                guard let self, let controller, library === controller else { return }
                present(controller)
            }
        }
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                store: store, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop, hideDesktopIcons: hideDesktopIcons,
                focusShortcut: focusShortcut, appearance: appearance, probe: probe
            ) { [weak self] in
                guard let self, settings?.window?.isVisible != true else { return }  // shown again meanwhile
                settings = nil
                updateActivationPolicy()
            }
        }
        present(settings)
    }

    /// Settings, on the Recording pane (the editor's notes that point to it).
    func showRecordingSettings() {
        showSettings()
        settings?.showRecordingPane()
    }

    /// Settings, on the Share pane (the editor's Share, before it is set up).
    func showShareSettings() {
        showSettings()
        settings?.showSharePane()
    }

    /// A global shortcut was pressed.
    private func perform(_ action: HotKeyAction) {
        switch action {
        case .islandOrStop: island?.shortcutPressed()
        case .pauseResume: recording.togglePause()
        case .marker: recording.addMarker()
        case .restartTake: recording.restartTake()
        case .saveReplay: break
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

    // MARK: - -TomaShowcase

    /// `Toma -TomaShowcase <surface> [<path>]`: one surface to look at, for screenshots of the design
    /// (`scripts/ui-shots.sh`).
    private static var showcase: (surface: String, path: String?)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TomaShowcase"), index + 1 < arguments.count else { return nil }
        return (arguments[index + 1], index + 2 < arguments.count ? arguments[index + 2] : nil)
    }

    /// Opens `surface` and stays open, without the onboarding, the recovery, the deletions left at launch or anything
    /// else that touches the projects folder: `onboarding`, `settings`, `notices`, `island [<variant>]` (the island,
    /// open; `IslandPanel.showcase`), `editor <package>`, `export <package>` (the editor with its export sheet). The
    /// library over a folder of its own is `-TomaLibraryBench <folder> -TomaLibraryBenchKeepOpen`.
    private func runShowcase(_ surface: String, path: String?) {
        StyleCatalog.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        switch (surface, path) {
        // With TOMA_SHOWCASE_PANEL_PNG=<path>, the welcome and the settings are also drawn into `<path>-window.png`: a
        // locked screen captures nothing.
        case ("onboarding", let states?):  // new, mixed or done: made-up permissions
            onboarding = OnboardingWindowController(showcase: states)
            present(onboarding)
            CaptionsShowcase.snapshotLater(onboarding?.window)
        case ("onboarding", _):
            showOnboarding()
            CaptionsShowcase.snapshotLater(onboarding?.window)
        case ("settings", let pane):  // general, recording or shortcuts
            showSettings()
            if let pane { settings?.showcase(pane: pane) }
            CaptionsShowcase.snapshotLater(settings?.window)
        case ("notices", _): showThirdPartyNotices()
        case ("formats", _):  // the format selector's choices, as the toolbar's menu and the Project menu list them
            let window = NSWindow(contentViewController: NSHostingController(rootView: FormatMenu.showcase))
            window.title = "Format"
            window.makeKeyAndOrderFront(nil)
            showcaseWindow = window
        case ("island", let variant):
            makeIsland()
            if variant != "peek" { island?.invoke() }
            if let variant { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.island?.showcase(variant) } }
        case ("editor", let path?), ("export", let path?):
            let url = URL(fileURLWithPath: path).standardizedFileURL
            showEditor(for: url, take: nil)
            // TOMA_SHOWCASE_TAB=<0-5> shows that tab of the panel; TOMA_SHOWCASE_SELECT=zoom selects the first zoom, `items`
            // adds a zoom at 7 s and a Split block at the playhead (selected), `items-none` the same with nothing selected.
            let environment = ProcessInfo.processInfo.environment
            if environment["TOMA_SHOWCASE_TAB"] != nil || environment["TOMA_SHOWCASE_SELECT"] != nil
                || environment["TOMA_SHOWCASE_ASPECT"] != nil || environment["TOMA_SHOWCASE_SAFEZONES"] != nil
                || environment["TOMA_SHOWCASE_FRAME"] != nil || environment["TOMA_SHOWCASE_KEYS"] != nil
                || environment["TOMA_SHOWCASE_PICTURE"] != nil
                || environment["TOMA_SHOWCASE_SEEK"] != nil
                || environment["TOMA_SHOWCASE_DEVICEFRAME"] != nil || environment["TOMA_SHOWCASE_REFRAME"] != nil
                || environment["TOMA_SHOWCASE_PLAYHEAD"] != nil
                || environment.keys.contains(where: { $0.hasPrefix("TOMA_SHOWCASE_P3_") })
                || environment["TOMA_SHOWCASE_AI"] != nil
                || environment["TOMA_SHOWCASE_SHARE"] != nil
            {
                Task {
                    while editors[url]?.structureIsSettled != true { try? await Task.sleep(for: .milliseconds(100)) }
                    guard let model = editors[url]?.model else { return }
                    // TOMA_SHOWCASE_ASPECT=<16:9|9:16|1:1|4:5|4:3|3:4|auto> sets the project's format.
                    if let aspect = environment["TOMA_SHOWCASE_ASPECT"].flatMap(Aspect.init(rawValue:)) { model.setAspect(aspect) }
                    // TOMA_SHOWCASE_SAFEZONES=1 shows the safe-zone guide over the preview.
                    if environment["TOMA_SHOWCASE_SAFEZONES"] == "1" { model.showsSafeZones = true }
                    // TOMA_SHOWCASE_KEYS=<shortcuts|all> turns the keys on screen on (phase 2).
                    if let mode = environment["TOMA_SHOWCASE_KEYS"].flatMap(KeyOverlayMode.init(rawValue:)) {
                        model.setKeyOverlay(mode: mode, position: .bottomLeading, size: .large)
                    }
                    // TOMA_SHOWCASE_DEVICEFRAME=<none|macWindow|iPhone|iPad|macBook>[-light] sets the frame (phase 2), and
                    // TOMA_SHOWCASE_REFRAME=followCursor follows the cursor.
                    if let raw = environment["TOMA_SHOWCASE_DEVICEFRAME"], let current = model.document?.style.frame {
                        let parts = raw.split(separator: "-")
                        let choice: FrameChoice? = switch parts.first {
                        case "none": FrameChoice.none
                        case "macWindow": .macWindow
                        case "iPhone": .iPhone
                        case "iPad": .iPad
                        case "macBook": .macBook
                        default: nil
                        }
                        if let choice {
                            let frame = choice.frame(from: current)
                            model.setFrame(parts.last == "light" ? FrameTabRules.frame(frame, finish: .light) ?? frame : frame)
                        }
                    }
                    if let reframe = environment["TOMA_SHOWCASE_REFRAME"].flatMap(Reframe.init(rawValue:)) { model.setReframe(reframe) }
                    if let tab = environment["TOMA_SHOWCASE_TAB"].flatMap(Int.init).flatMap(EditorPanelTab.init) { model.panelTab = tab }
                    // TOMA_SHOWCASE_FRAME=<n> moves the playhead to output frame n (an iPhone's turned segment, say).
                    if let frame = environment["TOMA_SHOWCASE_FRAME"].flatMap(Int.init) { model.seek(frame: frame) }
                    // TOMA_SHOWCASE_SEEK=<seconds> puts the playhead on the frame of the project's grid there (phase 2).
                    if let seconds = environment["TOMA_SHOWCASE_SEEK"].flatMap(Double.init), let rate = model.document?.frameRate {
                        model.seek(frame: Int((seconds * Double(rate)).rounded()))
                    }
                    // TOMA_SHOWCASE_PLAYHEAD=<seconds> puts the playhead on the frame nearest that output time (a frame
                    // with keys on screen, say: they show only from the first key).
                    if let seconds = environment["TOMA_SHOWCASE_PLAYHEAD"].flatMap(Double.init) {
                        model.scrub(toSeconds: seconds)
                        model.endScrub()
                    }
                    if environment["TOMA_SHOWCASE_SELECT"] == "zoom", let id = model.document?.zoom.regions.first?.id {
                        model.selection = .zooms([id])
                    }
                    if environment["TOMA_SHOWCASE_SELECT"]?.hasPrefix("items") == true {
                        model.addZoom(at: 7_000_000_000)
                        model.addLayoutBlock(kind: .split)
                        if environment["TOMA_SHOWCASE_SELECT"] == "items-none" { model.selection = nil }
                    }
                    // TOMA_SHOWCASE_SELECT=privacy: two privacy blocks, one over the other, the second selected (phase 2);
                    // `privacy-fill`, the second a black fill.
                    // TOMA_SHOWCASE_SELECT=typing: the little window of Speed Up Typing, open.
                    if environment["TOMA_SHOWCASE_SELECT"] == "typing" { model.askTypingSpeed() }
                    if environment["TOMA_SHOWCASE_SELECT"]?.hasPrefix("privacy") == true {
                        model.showcasePrivacy(fill: environment["TOMA_SHOWCASE_SELECT"] == "privacy-fill")
                    }
                    // TOMA_SHOWCASE_SELECT=scan-running, scan-none, scan-found or scan-blurred: the Privacy tab's search of
                    // sensitive data, running, having found nothing, seven findings with their sheet, or those blurred (phase 2).
                    if let variant = environment["TOMA_SHOWCASE_SELECT"], variant.hasPrefix("scan-") {
                        model.showcaseSensitiveSearch(variant)
                    }
                    // TOMA_SHOWCASE_PICTURE=<background>:<framing>:<look>[:<panel scrolled, 0 to 1>[:<frame>[:<zoom>]]]
                    // sets the camera's picture (phase 2 design §6.1 to §6.3; "blurred:manual:warm:1:90:1.8"), scrolls the
                    // panel that far down, puts the playhead at that frame and sets the framing's zoom.
                    if let picture = environment["TOMA_SHOWCASE_PICTURE"]?.split(separator: ":").map(String.init) {
                        model.showcasePicture(picture)
                    }
                    // TOMA_SHOWCASE_P3_<NAME>: the screens of phase 3, each feature's in its own file.
                    await model.showcasePhase3(environment)
                    // TOMA_SHOWCASE_AI=<info|info-working|sheet|sheet-working|unavailable|no-transcript>: the local AI (5b).
                    await model.showcaseAI(environment)
                    // TOMA_SHOWCASE_SHARE=<unconfigured|ready|running|finished|failed|list>: Share's little window (5a).
                    model.showcaseShare(environment)
                    // TOMA_SHOWCASE_PANEL_PNG on the Zoom tab (its "Follow the Focus", 4a): the window and the panel drawn
                    // into PNGs, unless a showcase above drew them already.
                    if model.panelTab == .zoom { CaptionsShowcase.snapshotLater(model.window) }
                }
            }
            guard surface == "export" else { return }
            Task {
                let deadline = ContinuousClock.now + .seconds(30)
                while ContinuousClock.now < deadline, editors[url]?.structureIsSettled != true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(1))
                editors[url]?.model.openExportSheet()
                // TOMA_SHOWCASE_EXPORT=gif shows the sheet's GIF.
                if environment["TOMA_SHOWCASE_EXPORT"] == "gif" { editors[url]?.model.showcaseExportSheetGIF() }
                // TOMA_SHOWCASE_CODEC=hevc|proRes422|proRes422HQ shows the sheet with that codec.
                if let raw = environment["TOMA_SHOWCASE_CODEC"], let codec = ExportCodec(rawValue: raw) {
                    editors[url]?.model.showcaseExportSheetCodec(codec)
                }
            }
        default:
            print("unknown surface \(surface)")
            exit(2)
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
    /// and a few more open (`RecoveredProjects`); the recovery alert has listed them all. The library looks at them again
    /// (its Recuperar, design §6.6: a card of Other places is not watched).
    private func showRecovered(_ urls: [URL]) {
        guard let last = urls.last else { return }
        recording.noteRecovered(last)
        let openPaths = editors.values.reduce(into: Set<URL>()) { $0.formUnion($1.place.paths) }
        let (reload, open) = RecoveredProjects.editors(recovered: urls, openEditors: openPaths)
        for url in reload { editor(at: url)?.reloadIfNeeded() }
        for url in open { showEditor(for: url, take: nil) }
        library?.model.look(at: urls)
    }

    /// Opens the project at `url` in an editor. One open already (also through a symlink, or after it was moved) comes to
    /// the front instead: never a second session on the same package. A new editor shows its window once the state it was
    /// left in is read and applied (its frame, its panel).
    func showEditor(for url: URL, take: String?) {
        let key = url.standardizedFileURL
        if let editor = openEditor(of: key) {
            // Hidden while its re-record is recorded: it comes back once that ends.
            if editor === rerecordingEditor, editor.isHiddenForRerecord { return }
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
            packageURL: key, takeID: take, exportGate: exportGate, projectHost: editorProjectHost,
            onRecovered: { [weak self] url in self?.recording.noteRecovered(url) }
        ) { [weak self] in
            guard let self, let made, made.window?.isVisible != true else { return }  // shown again meanwhile
            editors = editors.filter { $0.value !== made }
            if let closing = made.model.closing { keep(closing, of: made.place) }
            updateActivationPolicy()
            // What the editor wrote as it closed, where its package is now.
            tellLibraryEditors()
            library?.model.look(at: [made.currentPackageURL])
        }
        made = editor
        editor.keyboard.open = { [weak self] in self?.openProject() }
        editor.onEdited = { [weak self, weak editor] in
            guard let editor else { return }
            self?.edited(editor.currentPackageURL)
        }
        editor.onAccessChanged = { [weak self] in self?.tellLibraryEditors() }
        editor.onPackageMoved = { [weak self] in self?.tellLibraryEditors() }
        editors[key] = editor
        // Opened during a take: its analysis queue starts paused.
        if recording.isRecording { editor.model.setRecording(true) }
        if !Self.isInProjectsFolder(key, projectsFolder: recording.projectsFolder) {
            // A project of another folder is one of Other Places (design §6.5).
            openedElsewhere.insert(key)
            library?.model.look(at: [key])
        }
        tellLibraryEditors()
        Task {
            await editor.restoreWindowState()
            // Gone meanwhile: nothing to show.
            guard editors.values.contains(where: { $0 === editor }) else { return }
            present(editor)
        }
    }

    /// Keeps the closing of an editor's session whose window closed, of the package at `place`, until it ends, for a quit
    /// and the library to wait for.
    private func keep(_ closing: Task<Void, Never>, of place: EditorPlace) {
        closedEditors += 1
        let number = closedEditors
        closingEditors[number] = (place, closing)
        Task {
            await closing.value
            closingEditors[number] = nil
            tellLibraryEditors()
        }
    }

    /// What an editor needs to act on its project as a whole (design §6.7): the library's records, whether a take
    /// records, and the library and the other editors told of what it did.
    private var editorProjectHost: EditorProjectHost {
        let records = libraryRecords, launchState = launchState
        return EditorProjectHost(
            projectsFolder: recording.projectsFolder, records: { await records.value },
            isRecording: { launchState.isRecording() },
            look: { [weak self] urls in self?.library?.model.look(at: urls) },
            open: { [weak self] url in self?.showEditor(for: url, take: nil) },
            moved: { [weak self] in self?.tellLibraryEditors() },
            recordedHere: { [weak self] url in self?.recording.recordedThisSession(url) ?? false },
            rerecord: { [weak self] request in self?.rerecord(request) ?? false })
    }

    // MARK: - Re-recording

    /// "Re-record from Here" of `request`'s editor (3d plan decisions 9 and 10): its window is hidden and the island records
    /// the take into its package. Refused (`false`), the window never hidden, while a take is recorded or another editor's
    /// re-record is under way, or before the island is made.
    private func rerecord(_ request: EditorRerecordRequest) -> Bool {
        guard let editor = editors.values.first(where: { $0.model === request.editor }), rerecordingEditor == nil,
            !recording.isRecording, let island
        else { return false }
        rerecordingEditor = editor
        editor.hideForRerecord()
        Task {
            await island.rerecord(
                request.take, target: request.target, scriptWord: request.scriptWord, cameraStyle: request.cameraStyle,
                projectName: request.projectName, asked: request.asked)
        }
        return true
    }

    /// The recorder told how the re-record of `target` ended (`RecordingController.rerecordEnded`). A start that failed
    /// while the open island says why is held there (`IslandRerecordRules.end`): Record tries it again into the same
    /// package, and closing the island cancels it, which ends it again, for good. Otherwise the island lets it go, and its
    /// editor comes back, whatever "When Recording Stops" says, and applies a take recorded. Coming back to say nothing was
    /// recorded, the editor stays behind a window that asks for something (the permissions), and doesn't take Toma to the
    /// front if the user went to another app meanwhile; to quit, it is only put back on the screen.
    private func rerecordEnded(_ target: RerecordTarget, _ outcome: RerecordOutcome) {
        if let island, island.holdsRerecord,
            IslandRerecordRules.end(outcome, islandShowsStartFailure: island.isShowingStartFailure) == .holdForRetry
        {
            Self.logger.notice("A re-record's start failed: the island holds it, its editor hidden")
            return
        }
        island?.rerecordEnded(target)
        let editor = rerecordingEditor
        rerecordingEditor = nil
        guard let editor, editors.values.contains(where: { $0 === editor }) else { return }
        editor.rerecordEnded(outcome)
        switch outcome {
        case .recorded:
            present(editor)
        case .nothing where onboarding?.window?.isVisible == true || !NSApp.isActive:
            // Shown without being made key or activating Toma: in front of its own windows only.
            updateActivationPolicy(activatingIfRegular: false)
            editor.window?.orderFront(nil)
            if let front = onboarding?.window, front.isVisible { front.orderFront(nil) }
        case .nothing:
            present(editor)
        case .quit:
            editor.window?.orderFront(nil)
        }
    }

    /// The editor whose package `url` names now (`EditorPlace`): it follows a package renamed or moved while open, and a
    /// project that took the path of one that moved is another one's.
    private func editor(at url: URL) -> EditorWindowController? {
        let open = Array(editors.values)
        return EditorPlace.index(at: url, in: open.map(\.place)).map { open[$0] }
    }

    /// The library's `close` (design §6.3): the window of the editor of the package at `url` closes, after asking if its
    /// export runs, and this returns once its session closed (what was pending written, `edit.lock` let go), and that of
    /// a window closed just before. `false` if the user kept the window open.
    private func closeEditor(at url: URL) async -> Bool {
        let key = url.standardizedFileURL
        if let editor = editor(at: key), !(await editor.closeAsking()) { return false }
        for closing in Array(closingEditors.values) where EditorPlace.index(at: key, in: [closing.place]) != nil {
            await closing.task.value
        }
        return true
    }

    /// The library moved packages: the editors that have one of them open show where it is now (one restored from the
    /// trash opens again editable), and the library is told where the editors' packages are.
    private func libraryMovedPackages() {
        for editor in editors.values { editor.model.packageMayHaveMoved() }
        tellLibraryEditors()
    }

    /// The editor that has the package at `url` open: one whose package is that folder (`PackageIdentity`), also through
    /// a symlink or where it was moved to; by its path only when nothing is there now. The folder comes first: the path an
    /// editor was opened from may hold another package by now.
    private func openEditor(of url: URL) -> EditorWindowController? {
        guard let identity = PackageIdentity(url) else { return editors[url] }
        return editors.values.first { $0.showsPackage(identity) }
    }

    // MARK: - The library's view of the app

    private static func isInProjectsFolder(_ url: URL, projectsFolder: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: projectsFolder.standardizedFileURL.pathComponents)
    }

    /// The library is told whether a take records and into which package, and looks at the packages a take made, changed
    /// or finished (design §6.6, §6.8).
    private func tellLibraryTake() {
        let isRecording = recording.isRecording
        launchState.setRecording(isRecording)
        // The editors' analysis queues stop while a take records and go on after it.
        for editor in editors.values { editor.model.setRecording(isRecording) }
        guard let model = library?.model else { return }
        let package = recording.takePackageURL
        model.setTake(isRecording: isRecording, package: package)
        if libraryWasRecording, !isRecording, let last = libraryLastTake { model.look(at: [last]) }
        libraryWasRecording = isRecording
        libraryTakePackage = package
        if let package { libraryLastTake = package }
    }

    /// A take opened its project, was restarted into a new one (the old one went to the trash) or was closed.
    private func takePackageChanged() {
        let before = libraryTakePackage
        tellLibraryTake()
        guard let model = library?.model else { return }
        let now = recording.takePackageURL
        var urls = [before, now].compactMap { $0 }
        // A restart moved the old take to the trash.
        if before != nil, now != nil, before != now { urls.append(ProjectTrash.folder(in: recording.projectsFolder)) }
        if !urls.isEmpty { model.look(at: urls) }
    }

    /// The library is told which packages the editors have open, by the paths that name them now (`EditorPlace`: where they
    /// are, and where they were opened from while they have not moved), those of windows whose sessions are still closing
    /// too; and which of them another app has too.
    private func tellLibraryEditors() {
        guard let model = library?.model else { return }
        let open = editors.values.map(\.place) + closingEditors.values.map(\.place)
        model.setOpenEditors(open.reduce(into: Set()) { $0.formUnion($1.paths) })
        let elsewhere = editors.values.filter(\.isOpenElsewhere).map(\.place)
        model.setOpenElsewhere(elsewhere.reduce(into: Set()) { $0.formUnion($1.paths) })
    }

    /// An editor changed its project: the library looks at it once the edits pause.
    private func edited(_ url: URL) {
        guard library != nil else { return }
        editedPackages.insert(url)
        guard editedLook == nil else { return }
        editedLook = Task { [weak self] in
            try? await Task.sleep(for: Self.editedLookDelay)
            guard let self else { return }
            editedLook = nil
            let urls = Array(editedPackages)
            editedPackages = []
            library?.model.look(at: urls)
        }
    }

    /// Whether a window of the app is open, minimized ones too.
    private var hasOpenWindow: Bool {
        let windows = editors.values.map(\.window) + [onboarding?.window, notices?.window, settings?.window, library?.window]
        return windows.contains { $0?.isVisible == true || $0?.isMiniaturized == true }
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
            + (library == nil ? 0 : 1)
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
