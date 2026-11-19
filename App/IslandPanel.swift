// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Library
import QuartzCore
import Recording
import SwiftUI

/// The island: one floating panel at the top center of the screen with the pointer, whose frame is always
/// its visible outline (it never covers clicks outside it). Its width, height and radius are springs
/// stepped at the display's rate; its content is `IslandView`. It runs `IslandMachine` on what the
/// pointer, clicks, keys and the take (its phase, its notices, the take saved) do, and owns the hover
/// zones, the on-screen selection, the camera bubble, and what hangs under it: the teleprompter, and the
/// confirmation capsule (under the teleprompter while it shows, so they never cover each other). While a take
/// records it follows the pointer from screen to screen.
@MainActor
final class IslandPanel: NSObject, NSWindowDelegate {
    /// Open or choosing what to record: the app stays out of the Dock meanwhile.
    var isSelecting: Bool {
        switch machine.state {
        case .open, .choosing: true
        case .rest, .peek, .countdown, .recording, .recordingOpen, .notice, .saving, .saved: false
        }
    }

    /// `isSelecting` may have changed.
    var selectingChanged: () -> Void = {}

    /// Opens the library window, on a section if one is given; set by the app delegate.
    var openLibrary: (LibrarySection?) -> Void = { _ in }

    /// While a system permission prompt (drawn by another process, at the top center) is up, the island
    /// goes down to `.normal` so it is never over it (Tasks 16a, 16e and 15): the microphone's, which a take's
    /// start waits for, the camera's, which turning the camera on waits for, and system audio's, which turning
    /// system audio on shows.
    var yieldsToSystemPrompt = false {
        didSet { panel.level = yieldsToSystemPrompt ? .normal : FloatingPanel.islandLevel }
    }

    private let recording: RecordingController
    private let countdown: CountdownSetting
    private let afterStop: AfterStopSetting
    private let hideDesktopIcons: HideDesktopIconsSetting
    private let focusShortcut: FocusShortcutSetting
    private let store = SettingsStore()
    private let panel: FloatingPanel
    private let root: TrackingView
    private let model: IslandModel
    private let zones = IslandHoverZones()
    private let overlay = SelectionOverlay()
    private let capsule = ConfirmationCapsule()
    /// Shared by the teleprompter and the island's switches.
    private let teleprompterSetting: TeleprompterSetting
    private let teleprompter: TeleprompterPanel
    /// The desktops of the display the island is on, for the open island and the open recording island.
    private let desktops: DesktopsModel
    /// Kept up to date from launch, so opening the panel never waits for them.
    private let microphones = CaptureDeviceList(listing: { DeviceLists.microphones() })
    private let cameras = CaptureDeviceList(listing: { DeviceLists.cameras() })
    /// The open apps, for system audio by app.
    private let audioApplications = AudioApplicationList()
    /// The camera's look and permission, for the bubble and the open island's camera column.
    private let camera: CameraSetting
    /// System audio's permission, asked for when it is turned on in the open island.
    private let systemAudio: SystemAudioSetting
    private let bubble: CameraBubblePanel
    /// The camera prompt is up.
    private var isAskingForCamera = false
    /// System audio was asked for with the island open: macOS shows its prompt and never says when it is
    /// answered (the request is over in a second, the prompt may stay). The island stays under it, and open while
    /// the prompt has the keyboard, until the request is over and the island is back (`SystemPromptRoom`).
    private var systemAudioPrompt = SystemPromptRoom()
    private var machine = IslandMachine()
    private var presence = PointerPresence()
    private var width: SpringValue
    private var height: SpringValue
    private var radius: SpringValue
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var deadlineTask: Task<Void, Never>?
    /// While the wings show: moves the island to the screen with the pointer.
    private var pointerWatch: Task<Void, Never>?
    /// The take's phase the machine was last told.
    private var phase: RecordingController.Phase
    /// The take's notices the machine was last told.
    private var notices: [TakeNotice]
    /// The saved take the machine was last told.
    private var saved: SavedTake?
    /// The panel is fading out to rest on a screen without a notch.
    private var isHiding = false
    /// The panel is fading out to another screen, while recording.
    private var isChangingScreens = false
    /// For the life of the app.
    private var observers: [any NSObjectProtocol] = []
    private let origin = ContinuousClock.now
    private var tops: [UInt32: ScreenTop]
    private var names: [UInt32: String]
    /// The display the island is on.
    private var displayID: UInt32 {
        didSet { desktops.displayID = displayID }
    }

    /// How often the pointer's screen is read while recording (plan decision 22).
    private static let pointerInterval = Duration.milliseconds(250)

    /// The island starts at rest on the screen with the pointer. `probe` asks for Accessibility, to jump to
    /// another desktop; the bubble shows the camera of `cameraHost`, the session the take records.
    init(
        recording: RecordingController, hotKeys: HotKeyCenter, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting, probe: any PermissionProbe,
        cameraHost: CameraSessionHost
    ) {
        self.recording = recording
        self.countdown = countdown
        self.afterStop = afterStop
        self.hideDesktopIcons = hideDesktopIcons
        self.focusShortcut = focusShortcut
        phase = recording.phase
        notices = recording.notices
        saved = recording.lastSaved
        let screens = Self.readScreens()
        tops = screens.tops
        names = screens.names
        displayID = Self.pointerDisplayID() ?? tops.keys.sorted().first ?? CGMainDisplayID()
        let top = tops[displayID] ?? ScreenTop(frame: NSScreen.main?.frame ?? .zero, notch: nil, menuBarHeight: 24)
        let workspace = NSWorkspace.shared
        teleprompterSetting = TeleprompterSetting(store: store)
        teleprompter = TeleprompterPanel(setting: teleprompterSetting, recording: recording)
        desktops = DesktopsModel(displayID: displayID, probe: probe)
        camera = CameraSetting(store: store, probe: probe)
        systemAudio = SystemAudioSetting(probe: probe)
        bubble = CameraBubblePanel(setting: camera, preview: SharedCameraPreview(host: cameraHost))
        model = IslandModel(
            recording: recording, hotKeys: hotKeys, teleprompter: teleprompterSetting, desktops: desktops, top: top,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
        let rest = IslandGeometry.shape(.rest, on: top)
        width = SpringValue(value: rest.width, spring: Motion.islandCollapse)
        height = SpringValue(value: rest.height, spring: Motion.islandCollapse)
        radius = SpringValue(value: rest.bottomRadius, spring: Motion.islandCollapse)
        let frame = IslandGeometry.frame(rest, on: top)
        panel = FloatingPanel(contentRect: frame, level: FloatingPanel.islandLevel, ignoresMouseEvents: false)
        root = TrackingView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()

        let content = FloatingHostingView.make(IslandView(model: model))
        content.frame = root.bounds
        root.addSubview(content)
        panel.contentView = root
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.escape() }
        panel.onClose = { [weak self] in self?.close() }
        model.send = { [weak self] event in self?.send(event) }
        desktops.send = { [weak self] event in self?.send(event) }
        root.onEnter = { [weak self] in
            self?.pointer(entered: .island)
            self?.islandIsBackAfterSystemAudioRequest()
        }
        root.onExit = { [weak self] in self?.pointer(exited: .island) }
        let link = root.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link

        zones.entered = { [weak self] id in self?.zoneEntered(id) }
        zones.exited = { [weak self] id in self?.pointer(exited: .zone(id)) }
        zones.clicked = { [weak self] id in self?.zoneClicked(id) }
        overlay.chose = { [weak self] id in self?.chose(display: id) }
        overlay.choseWindow = { [weak self] window in self?.chose(window: window) }
        overlay.ended = { [weak self] in self?.send(.endedChoosing) }
        overlay.leftForAnotherApp = { [weak self] in self?.send(.endedChoosing, .dismiss) }
        overlay.closed = { [weak self] in self?.close() }
        overlay.reduceMotion = model.reduceMotion
        overlay.reduceTransparency = model.reduceTransparency
        capsule.reduceMotion = model.reduceMotion
        capsule.reduceTransparency = model.reduceTransparency
        teleprompter.reduceMotion = model.reduceMotion
        teleprompter.reduceTransparency = model.reduceTransparency
        teleprompter.visibilityChanged = { [weak self] in self?.placeHanging() }
        teleprompter.resignedKey = { [weak self] in self?.keyboardLeft() }
        teleprompter.islandTakesKeyboard = { [weak self] in self?.takeKeyboardBack() ?? false }
        bubble.reduceMotion = model.reduceMotion
        camera.askingChanged = { [weak self] asking in self?.cameraPromptChanged(asking) }
        // A take in progress follows the bubble: let go, or given another shape or size (notch design §5.6).
        camera.changed = { [weak recording] style in recording?.setCameraStyle(style) }
        systemAudio.askingChanged = { [weak self] asking in self?.systemAudioRequested(asking) }

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        observe(workspace.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.displayOptionsChanged() }

        zones.rebuild(tops)
        applyOutline()
        updateZones()
        showOrHide()
        teleprompter.update(island: machine.state)
        bubble.update(island: machine.state)
        bubble.follow { [weak self] in self?.recordedSelection }
        observeRecording()
    }

    /// What the bubble shows: the take's selection from its countdown on, otherwise what the open island chooses.
    private var recordedSelection: CaptureSelection? {
        recording.currentRequest?.selection ?? model.panel?.selection
    }

    /// "New Recording" in the menu: the island opens on the screen with the pointer.
    func invoke() {
        if canMove, let id = Self.pointerDisplayID() { move(to: id) }
        send(.clicked)
    }

    #if DEBUG
    /// `-TomaShowcase island <variant>`: the open island in a mode (`display`, `window`, `area`), with its settings
    /// (`settings`) or with the camera on if it is allowed (`camera`), for screenshots; nothing is saved.
    func showcase(_ variant: String) {
        guard let panel = model.panel else { return }
        switch variant {
        case "display", "settings", "camera": panel.selection.mode = .display
        case "window": panel.selection.mode = .window
        case "area": panel.selection.mode = .area
        default: break
        }
        if variant == "settings" { panel.showsSettings = true }
        if variant == "camera", panel.camera.permission == .granted { panel.setCamera(on: true) }
    }
    #endif

    /// The island's shortcut (⇧⌘2): during a take it stops it, its countdown included; otherwise the
    /// island opens on the screen with the pointer, or closes.
    func shortcutPressed() {
        if recording.isRecording {
            recording.stopRecording()
            return
        }
        if canMove, let id = Self.pointerDisplayID() { move(to: id) }
        send(.toggle)
    }

    /// A take could not start: the island opens and says why, above Record (no alert during a take).
    func startFailed(_ error: any Error) {
        // The start went back to idle first.
        syncTake()
        model.startFailure = userFacingDescription(of: error)
        send(.startFailed)
    }

    /// The capsule under the island confirms what the user just did.
    func showConfirmation(_ confirmation: IslandConfirmation) {
        var item = confirmation.capsule
        // "The take went to the trash." opens the trash (design §6.1).
        if confirmation == .movedToTrash { item.action = { [weak self] in self?.openLibrary(.trash) } }
        capsule.show(item)
    }

    // MARK: - The take

    /// Tells the machine what the take does, and makes room for a system prompt the start waits for.
    private func observeRecording() {
        withObservationTracking {
            _ = recording.phase
            _ = recording.isAskingPermission
            _ = recording.notices
            _ = recording.lastSaved
        } onChange: { [weak self] in
            // Called before the change: read it once it is made.
            Task { @MainActor in self?.recordingChanged() }
        }
    }

    private func recordingChanged() {
        observeRecording()
        updateYield()
        syncTake()
    }

    private func updateYield() {
        let yields = recording.isAskingPermission || isAskingForCamera || systemAudioPrompt.isMakingRoom
        if yieldsToSystemPrompt != yields { yieldsToSystemPrompt = yields }
    }

    /// System audio is being asked for (with the island open, the island makes room for the prompt), or the
    /// request is over (the prompt may still be up: the island waits until it is back).
    private func systemAudioRequested(_ asking: Bool) {
        if asking {
            guard machine.state == .open else { return }
            systemAudioPrompt.requestStarted()
        } else {
            systemAudioPrompt.requestEnded()
        }
        updateYield()
    }

    /// The camera prompt came up, or was answered: the island makes room for it meanwhile, and then takes the
    /// keyboard back if it is open (the prompt had it).
    private func cameraPromptChanged(_ asking: Bool) {
        isAskingForCamera = asking
        updateYield()
        if !asking { _ = takeKeyboardBack() }
    }

    /// Tells the machine what changed in the take since it was last told: its phase first (a restart's
    /// countdown keeps the notice it carries for when the new take records), then its notices, then a take
    /// just saved. A new notice that confirms shows in the capsule.
    private func syncTake() {
        var events: [IslandEvent] = []
        if recording.phase != phase {
            phase = recording.phase
            events.append(.phaseChanged(phase))
        }
        let current = recording.notices
        if current != notices {
            let new = current.filter { !notices.contains($0) }
            notices = current
            events.append(.noticesChanged(current))
            for notice in new where notice.presentation == .confirmation { capsule.show(notice.capsule) }
        }
        if let lastSaved = recording.lastSaved, lastSaved != saved {
            saved = lastSaved
            events.append(.saved(lastSaved))
        }
        send(events)
    }

    // MARK: - Events

    private var now: Duration { ContinuousClock.now - origin }

    private func send(_ events: IslandEvent...) {
        send(events)
    }

    private func send(_ events: [IslandEvent]) {
        guard !events.isEmpty else { return }
        let before = machine.state
        let now = now
        for event in events { machine.handle(event, at: now) }
        apply(from: before)
    }

    private func tick() {
        let before = machine.state
        machine.tick(at: now)
        apply(from: before)
    }

    /// Esc on the island: it closes the settings card if it is open, and otherwise the island; during the
    /// countdown it cancels the take. While recording the island never has the keyboard.
    private func escape() {
        switch machine.state {
        case .open:
            if let panel = model.panel, panel.showsSettings {
                panel.showsSettings = false
            } else {
                send(.dismiss)
            }
        case .choosing: send(.endedChoosing)
        case .countdown: recording.stopRecording()
        case .rest, .peek, .recording, .recordingOpen, .notice, .saving, .saved: break
        }
    }

    /// ⌘W while the island or the on-screen selection has the keyboard: the island closes. It never stops
    /// a take: Esc and the island's shortcut do.
    private func close() {
        switch machine.state {
        case .open: send(.dismiss)
        case .choosing: send(.endedChoosing, .dismiss)
        case .rest, .peek, .countdown, .recording, .recordingOpen, .notice, .saving, .saved: break
        }
    }

    private func pointer(entered region: PointerPresence.Region) {
        if let event = presence.entered(region) { send(event) }
    }

    private func pointer(exited region: PointerPresence.Region) {
        if let event = presence.exited(region) { send(event) }
    }

    /// Entering a zone also brings the island to that screen (with a fade while recording). If that screen
    /// has a notch, the island now covers the zone just entered: the pointer is over the island
    /// (`updateZones`).
    private func zoneEntered(_ id: UInt32) {
        if canMove {
            move(to: id)
        } else if machine.state == .recording {
            changeScreens(to: id)
        }
        pointer(entered: .zone(id))
        updateZones()
    }

    private func zoneClicked(_ id: UInt32) {
        if canMove { move(to: id) }
        send(.clicked)
    }

    private func chose(display id: UInt32) {
        model.panel?.choose(display: id)
        send(.endedChoosing)
    }

    /// The open island is back after system audio was asked for (the pointer came over it, or it is key again) and
    /// the request is over: the prompt is taken as answered, and everything comes back at once — the island's
    /// level, the keyboard (Esc), and closing with a click elsewhere.
    private func islandIsBackAfterSystemAudioRequest() {
        guard systemAudioPrompt.islandIsBack() else { return }
        updateYield()
        if !panel.isKeyWindow { _ = takeKeyboardBack() }
    }

    private func chose(window: WindowCandidate) {
        model.panel?.choose(window: window)
        send(.endedChoosing)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        islandIsBackAfterSystemAudioRequest()
    }

    func windowDidResignKey(_ notification: Notification) {
        keyboardLeft()
    }

    /// The island or the teleprompter lost the keyboard: a click elsewhere closes the open island, unless the
    /// keyboard went to another of Toma's floating windows (the on-screen selection, the teleprompter, a menu)
    /// or to the camera's prompt or system audio's, or the desktop changed under it (a jump from the island, or
    /// ⌃← ⌃→: macOS makes a window of that desktop key). Then the island stays open and takes the keyboard back.
    private func keyboardLeft() {
        guard machine.state == .open else { return }
        // Once the new key window is known.
        Task { @MainActor [weak self] in
            guard let self, machine.state == .open, !panel.isKeyWindow, !isAskingForCamera, !systemAudioPrompt.isMakingRoom
            else { return }
            if let key = NSApp.keyWindow, !key.styleMask.contains(.titled) { return }
            if desktops.keyboardLostToADesktopChange() {
                _ = takeKeyboardBack()
                return
            }
            send(.dismiss)
        }
    }

    // MARK: - States

    private func apply(from before: IslandState) {
        armDeadline()
        // These change without the state changing.
        if model.attention != machine.attention { model.attention = machine.attention }
        if !machine.hasStartFailure, model.startFailure != nil { model.startFailure = nil }
        let state = machine.state
        guard state != before else { return }

        switch (before, state) {
        case (.choosing, .open):
            break
        case (_, .open):
            // From rest, a peek, a saved take (Record Another) or a start that failed: what was saved.
            model.panel = makePanelModel()
        case (_, .rest), (_, .peek):
            model.panel?.showsSettings = false
        default:
            break
        }
        if state != .recordingOpen { model.isConfirmingRestart = false }
        if state != .open, systemAudioPrompt.isMakingRoom {
            systemAudioPrompt.islandLeftOpen()
            updateYield()
        }
        withAnimation(.island(IslandGeometry.spring(to: state), reduceMotion: model.reduceMotion)) { model.state = state }
        retargetOutline()

        // Out of the keyboard states the keyboard goes back to the app in front: the window server gives
        // it back when the island is ordered out and in again.
        panel.wantsKey = state.needsKeyboard
        if before.needsKeyboard, !state.needsKeyboard, panel.isVisible {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if before == .choosing { overlay.end() }
        switch state {
        case .rest, .peek, .countdown, .recording, .recordingOpen, .notice, .saving, .saved: overlay.end()
        case .open, .choosing: break
        }
        // Key only on entering a keyboard state: never again at each second of the countdown, which would
        // take the keyboard back from an app the user clicked into meanwhile.
        showOrHide(makingKey: IslandState.becomesKey(from: before, to: state))
        if state == .choosing {
            overlay.beginChoosing(choosing, names: names, barTops: areaBarTops(), pointerDisplayID: Self.pointerDisplayID())
        }
        updateZones()
        watchPointer(state == .recording)
        teleprompter.update(island: state)
        bubble.update(island: state)
        selectingChanged()
    }

    /// The teleprompter is done with the keyboard: the island takes it back if its state uses it.
    private func takeKeyboardBack() -> Bool {
        guard machine.state.needsKeyboard, panel.isVisible else { return false }
        panel.show(makingKey: true)
        return true
    }

    private func makePanelModel() -> OpenPanelModel {
        let panelModel = OpenPanelModel(
            recording: recording, store: store, countdown: countdown, afterStop: afterStop, hideDesktopIcons: hideDesktopIcons,
            focusShortcut: focusShortcut, teleprompter: teleprompterSetting, camera: camera, systemAudio: systemAudio,
            audioApplications: audioApplications, microphones: microphones, cameras: cameras, displays: displayChoices(),
            islandDisplayID: displayID)
        panelModel.highlight = { [weak self] id in
            guard let self else { return }
            overlay.highlight(id, names: names)
        }
        panelModel.confirm = { [weak self] confirmation in self?.showConfirmation(confirmation) }
        panelModel.openLibrary = { [weak self] in
            guard let self else { return }
            // The island closes: it is the library that is in front now.
            send(.dismiss)
            openLibrary(nil)
        }
        return panelModel
    }

    /// What "Choose on Screen" chooses: what the open island's mode records.
    private var choosing: SelectionOverlay.Choosing {
        guard let panel = model.panel else { return .display }
        switch panel.selection.mode {
        case .display: return .display
        case .window: return .window(panel)
        case .area: return .area(panel)
        // Nothing of the Mac's screen to choose: what there is without a panel.
        case .device: return .display
        }
    }

    /// Where the area bar goes on each screen, from its top: under the choosing island (where it would be on that
    /// screen) and the confirmation capsule that may hang from it.
    private func areaBarTops() -> [UInt32: Double] {
        tops.mapValues { top in
            let island = IslandGeometry.frame(IslandGeometry.shape(.choosing, on: top), on: top)
            return Double(top.frame.maxY - island.minY) + ConfirmationCapsule.clearance
        }
    }

    private func displayChoices() -> [DisplayChoice] {
        LiveTakeEnvironment.displays().map { DisplayChoice(info: $0, name: names[$0.id] ?? "") }
    }

    /// Asks for a `tick` once the machine's deadline is reached.
    private func armDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = machine.deadline else { return }
        let delay = deadline - now
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: max(delay, .zero))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: - Showing and hiding

    /// At rest on a screen without a notch nothing is drawn: the island fades out and leaves the screen.
    /// Everywhere else it is on the screen, and made key if `makingKey` (it just entered a state that wants
    /// the keyboard).
    private func showOrHide(makingKey: Bool = false) {
        let visible = machine.state != .rest || model.top.notch != nil
        if visible {
            isHiding = false
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.show(makingKey: makingKey)
            if panel.alphaValue < 1 { fade(to: 1) }
        } else if panel.isVisible, !isHiding {
            isHiding = true
            fade(to: 0) { [weak self] in
                guard let self, isHiding else { return }
                isHiding = false
                panel.orderOut(nil)
                // Off the screen the display link stops: the outline lands at rest now, so the next peek grows
                // from the pill and not from where the fade left it.
                landOutline()
                // Its tracking area left with it.
                pointer(exited: .island)
            }
        }
    }

    private func fade(to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        let duration = (model.reduceMotion ? Motion.reducedMotionFade : Motion.contentExit).timeInterval
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: - Screens

    /// The island goes to another screen only from rest or a peek; while recording it changes screens with
    /// a fade (`changeScreens`).
    private var canMove: Bool {
        switch machine.state {
        case .rest, .peek: true
        case .open, .choosing, .countdown, .recording, .recordingOpen, .notice, .saving, .saved: false
        }
    }

    /// Moves the island to `id`'s screen, growing out of its notch (or pill) from there.
    private func move(to id: UInt32) {
        guard id != displayID, let top = tops[id] else { return }
        displayID = id
        model.top = top
        let rest = IslandGeometry.shape(.rest, on: top)
        width = SpringValue(value: rest.width, spring: width.spring)
        height = SpringValue(value: rest.height, spring: height.spring)
        radius = SpringValue(value: rest.bottomRadius, spring: radius.spring)
        applyOutline()
        retargetOutline()
        updateZones()
        showOrHide()
    }

    /// While the wings show, the island is on the screen with the pointer: every `pointerInterval` it reads
    /// where the pointer is, and changes screens if it is on another one.
    private func watchPointer(_ watching: Bool) {
        guard watching else {
            pointerWatch?.cancel()
            pointerWatch = nil
            return
        }
        guard pointerWatch == nil else { return }
        pointerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pointerInterval)
                guard !Task.isCancelled, let self else { return }
                if machine.state == .recording, let id = Self.pointerDisplayID() { changeScreens(to: id) }
            }
        }
    }

    /// While recording, the island goes to `id`'s screen with a fade of `Motion.reducedMotionFade` (half out,
    /// half in), already in its outline there.
    private func changeScreens(to id: UInt32) {
        guard id != displayID, tops[id] != nil, !isChangingScreens, panel.isVisible else { return }
        isChangingScreens = true
        let half = Motion.reducedMotionFade.timeInterval / 2
        teleprompter.fadeWithIsland(leaving: true, duration: half)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = half
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.arrive(at: id, fadingIn: half) }
        }
    }

    /// Out of sight: the island is put on `id`'s screen in its outline there, and fades in. If the take
    /// ended (or is counting down again) during the fade-out, it stays where it was and is shown or hidden
    /// as its state says: a pill at rest is not drawn. It still goes, open, when the pointer entered the
    /// other screen's zone and opened it (`zoneEntered`).
    private func arrive(at id: UInt32, fadingIn duration: TimeInterval) {
        isChangingScreens = false
        switch machine.state {
        case .recording, .recordingOpen, .notice:
            break
        case .rest, .peek, .open, .choosing, .countdown, .saving, .saved:
            showOrHide()
            teleprompter.fadeWithIsland(leaving: false, duration: duration)
            return
        }
        if let top = tops[id] {
            displayID = id
            model.top = top
            let shape = IslandGeometry.shape(machine.state, on: top)
            let spring = IslandGeometry.spring(to: machine.state)
            width = SpringValue(value: shape.width, spring: spring)
            height = SpringValue(value: shape.height, spring: spring)
            radius = SpringValue(value: shape.bottomRadius, spring: spring)
            landOutline()
            updateZones()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        }
        teleprompter.fadeWithIsland(leaving: false, duration: duration)
    }

    /// On the notch screen it is on, the island stands in for that screen's zone, whose panel leaves the
    /// screen: a pointer over that zone is over the island. Also when the zone is entered after it was
    /// covered (the island arriving from another screen), since its panel can no longer say it was left.
    private func updateZones() {
        let covered: UInt32? = model.top.notch == nil ? nil : displayID
        if let covered { presence.islandCovers(.zone(covered)) }
        guard covered != zones.covered else { return }
        zones.setCovered(covered)
    }

    /// A display was connected or disconnected, the lid was closed or opened, or a resolution like "More
    /// Space" changed the notch in points.
    private func screensChanged() {
        let screens = Self.readScreens()
        guard !screens.tops.isEmpty else { return }
        for id in zones.displayIDs { pointer(exited: .zone(id)) }
        tops = screens.tops
        names = screens.names
        if tops[displayID] == nil {
            displayID = Self.pointerDisplayID() ?? tops.keys.sorted()[0]
        }
        if let top = tops[displayID] { model.top = top }
        zones.rebuild(tops)
        updateZones()
        if machine.state == .choosing { send(.endedChoosing) }
        model.panel?.update(displays: displayChoices())
        bubble.screensChanged()
        retargetOutline()
        showOrHide()
    }

    private func displayOptionsChanged() {
        let workspace = NSWorkspace.shared
        model.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        model.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        overlay.reduceMotion = model.reduceMotion
        overlay.reduceTransparency = model.reduceTransparency
        capsule.reduceMotion = model.reduceMotion
        capsule.reduceTransparency = model.reduceTransparency
        teleprompter.reduceMotion = model.reduceMotion
        teleprompter.reduceTransparency = model.reduceTransparency
        bubble.reduceMotion = model.reduceMotion
    }

    // MARK: - Outline

    /// Sends the springs to the current state's outline; with "Reduce motion" the outline jumps there.
    private func retargetOutline() {
        let shape = IslandGeometry.shape(machine.state, on: model.top)
        let spring = IslandGeometry.spring(to: machine.state)
        width.retarget(shape.width, spring: spring)
        height.retarget(shape.height, spring: spring)
        radius.retarget(shape.bottomRadius, spring: spring)
        if model.reduceMotion {
            landOutline()
            outlineSettled()
        } else if !(width.isSettled && height.isSettled && radius.isSettled) {
            lastFrameTime = nil
            displayLink?.isPaused = false
        }
    }

    /// The outline jumps to its target.
    private func landOutline() {
        func land(_ spring: inout SpringValue) {
            spring.value = spring.target
            spring.velocity = 0
        }
        land(&width)
        land(&height)
        land(&radius)
        displayLink?.isPaused = true
        lastFrameTime = nil
        applyOutline()
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let time = link.timestamp
        // At most one 30th of a second per frame: after a hitch the motion slows down instead of jumping.
        let seconds = lastFrameTime.map { min(max(time - $0, 0), 1.0 / 30) } ?? max(link.targetTimestamp - link.timestamp, 0)
        lastFrameTime = time
        width.step(by: seconds)
        height.step(by: seconds)
        radius.step(by: seconds)
        applyOutline()
        if width.isSettled, height.isSettled, radius.isSettled {
            link.isPaused = true
            lastFrameTime = nil
            outlineSettled()
        }
    }

    /// The window's frame is the outline as it is now.
    private func applyOutline() {
        let roundsTop = model.top.notch == nil
        let width = max(1, width.value)
        let height = max(1, height.value)
        // A radius the outline has room for, even while its size and radius are halfway.
        let limit = roundsTop ? min(width, height) / 2 : min(height, width / 2)
        let shape = IslandShape(width: width, height: height, bottomRadius: min(max(0, radius.value), limit), roundsTopCorners: roundsTop)
        // The clip first: the frame change draws the window at once.
        model.outline = shape
        let frame = IslandGeometry.frame(shape, on: model.top)
        panel.setFrame(frame, display: true)
        placeHanging()
    }

    /// What hangs under the island goes where the island is now, in the same frame: the teleprompter, and
    /// the capsule under what `TeleprompterLayout.capsuleAnchor` says.
    private func placeHanging() {
        let frame = panel.frame
        teleprompter.follow(frame)
        capsule.follow(TeleprompterLayout.capsuleAnchor(island: frame, teleprompterOnScreen: teleprompter.isShown))
    }

    /// The island grew under a pointer that did not move, or shrank away from it: no tracking event says so.
    private func outlineSettled() {
        guard panel.isVisible, !isHiding else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if inside != presence.inside.contains(.island) {
            inside ? pointer(entered: .island) : pointer(exited: .island)
        }
    }

    // MARK: - Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (IslandPanel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }

    /// The top of every screen, and its name, by display ID.
    private static func readScreens() -> (tops: [UInt32: ScreenTop], names: [UInt32: String]) {
        var tops: [UInt32: ScreenTop] = [:]
        var names: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            tops[id] = ScreenTop.make(
                frame: screen.frame, safeAreaTop: Double(screen.safeAreaInsets.top),
                auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea,
                menuBarHeight: max(Double(screen.frame.maxY - screen.visibleFrame.maxY), 24))
            names[id] = screen.localizedName
        }
        return (tops, names)
    }

    /// The display with the pointer.
    private static func pointerDisplayID() -> UInt32? {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let pointer = ScreenCoordinates.global(
            fromAppKit: CGRect(origin: NSEvent.mouseLocation, size: .zero), primaryScreenHeight: primaryHeight)
        return IslandPlacement.displayID(containing: CGPoint(x: pointer.x, y: pointer.y), displays: LiveTakeEnvironment.displays())
    }
}
