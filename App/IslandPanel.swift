// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import QuartzCore
import SwiftUI

/// The island: one floating panel at the top center of the screen with the pointer, whose frame is always
/// its visible outline (it never covers clicks outside it). Its width, height and radius are springs
/// stepped at the display's rate; its content is `IslandView`. It runs `IslandMachine` on what the
/// pointer, clicks and keys do, and owns the hover zones and the on-screen selection.
@MainActor
final class IslandPanel: NSObject, NSWindowDelegate {
    /// Open or choosing what to record: the app stays out of the Dock meanwhile.
    var isSelecting: Bool {
        switch machine.state {
        case .open, .choosing: true
        case .rest, .peek: false
        }
    }

    /// `isSelecting` may have changed.
    var selectingChanged: () -> Void = {}

    /// While a system permission prompt (drawn by another process, at the top center) is up, the island
    /// goes down to `.normal` so it is never over it (Tasks 16a and 16e).
    var yieldsToSystemPrompt = false {
        didSet { panel.level = yieldsToSystemPrompt ? .normal : FloatingPanel.islandLevel }
    }

    private let recording: RecordingController
    private let store = SettingsStore()
    private let panel: FloatingPanel
    private let root: TrackingView
    private let model: IslandModel
    private let zones = IslandHoverZones()
    private let overlay = SelectionOverlay()
    /// Kept up to date from launch, so opening the panel never waits for it.
    private let microphones = MicrophoneList()
    private var machine = IslandMachine()
    private var presence = PointerPresence()
    private var width: SpringValue
    private var height: SpringValue
    private var radius: SpringValue
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var deadlineTask: Task<Void, Never>?
    /// The panel is fading out to rest on a screen without a notch.
    private var isHiding = false
    /// For the life of the app.
    private var observers: [any NSObjectProtocol] = []
    private let origin = ContinuousClock.now
    private var tops: [UInt32: ScreenTop]
    private var names: [UInt32: String]
    /// The display the island is on.
    private var displayID: UInt32

    /// The island starts at rest on the screen with the pointer.
    init(recording: RecordingController) {
        self.recording = recording
        let screens = Self.readScreens()
        tops = screens.tops
        names = screens.names
        displayID = Self.pointerDisplayID() ?? tops.keys.sorted().first ?? CGMainDisplayID()
        let top = tops[displayID] ?? ScreenTop(frame: NSScreen.main?.frame ?? .zero, notch: nil, menuBarHeight: 24)
        let workspace = NSWorkspace.shared
        model = IslandModel(
            top: top, reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
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
        root.onEnter = { [weak self] in self?.pointer(entered: .island) }
        root.onExit = { [weak self] in self?.pointer(exited: .island) }
        let link = root.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link

        zones.entered = { [weak self] id in self?.zoneEntered(id) }
        zones.exited = { [weak self] id in self?.pointer(exited: .zone(id)) }
        zones.clicked = { [weak self] id in self?.zoneClicked(id) }
        overlay.chose = { [weak self] id in self?.chose(display: id) }
        overlay.ended = { [weak self] in self?.send(.endedChoosing) }
        overlay.leftForAnotherApp = { [weak self] in self?.send(.endedChoosing, .dismiss) }
        overlay.closed = { [weak self] in self?.close() }
        overlay.reduceMotion = model.reduceMotion

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        observe(workspace.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.displayOptionsChanged() }

        zones.rebuild(tops)
        applyOutline()
        updateZones()
        showOrHide()
    }

    /// "New Recording" in the menu: the island opens on the screen with the pointer.
    func invoke() {
        if canMove, let id = Self.pointerDisplayID() { move(to: id) }
        send(.clicked)
    }

    // MARK: - Events

    private var now: Duration { ContinuousClock.now - origin }

    private func send(_ events: IslandEvent...) {
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

    /// Esc on the island: it closes the settings card if it is open, and otherwise the island.
    private func escape() {
        switch machine.state {
        case .open:
            if let panel = model.panel, panel.showsSettings {
                panel.showsSettings = false
            } else {
                send(.dismiss)
            }
        case .choosing: send(.endedChoosing)
        case .rest, .peek: break
        }
    }

    /// ⌘W while the island or the on-screen selection has the keyboard: the island closes.
    private func close() {
        switch machine.state {
        case .open: send(.dismiss)
        case .choosing: send(.endedChoosing, .dismiss)
        case .rest, .peek: break
        }
    }

    private func pointer(entered region: PointerPresence.Region) {
        if let event = presence.entered(region) { send(event) }
    }

    private func pointer(exited region: PointerPresence.Region) {
        if let event = presence.exited(region) { send(event) }
    }

    /// Entering a zone also brings the island to that screen. If that screen has a notch, the island now
    /// covers the zone just entered: the pointer is over the island (`updateZones`).
    private func zoneEntered(_ id: UInt32) {
        if canMove { move(to: id) }
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

    /// A click elsewhere closes the open island, unless the keyboard went to another of Toma's floating
    /// windows (the on-screen selection, the bubble, the teleprompter, a menu).
    func windowDidResignKey(_ notification: Notification) {
        guard machine.state == .open else { return }
        // Once the new key window is known.
        Task { @MainActor [weak self] in
            guard let self, machine.state == .open, !panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, !key.styleMask.contains(.titled) { return }
            send(.dismiss)
        }
    }

    // MARK: - States

    private func apply(from before: IslandState) {
        armDeadline()
        let state = machine.state
        guard state != before else { return }

        switch (before, state) {
        case (.rest, .open), (.peek, .open):
            model.panel = makePanelModel()
        case (_, .rest), (_, .peek):
            model.panel?.showsSettings = false
        default:
            break
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
        case .rest, .peek: overlay.end()
        case .open, .choosing: break
        }
        showOrHide()
        if state == .choosing { overlay.beginChoosing(names: names, pointerDisplayID: Self.pointerDisplayID()) }
        updateZones()
        selectingChanged()
    }

    private func makePanelModel() -> OpenPanelModel {
        let panelModel = OpenPanelModel(
            recording: recording, store: store, microphones: microphones, displays: displayChoices(), islandDisplayID: displayID)
        panelModel.highlight = { [weak self] id in
            guard let self else { return }
            overlay.highlight(id, names: names)
        }
        return panelModel
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
    /// Everywhere else it is on the screen, and key when its state wants the keyboard.
    private func showOrHide() {
        let visible = machine.state != .rest || model.top.notch != nil
        if visible {
            isHiding = false
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.show()
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

    /// The island goes to another screen only from rest or a peek.
    private var canMove: Bool {
        switch machine.state {
        case .rest, .peek: true
        case .open, .choosing: false
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
        retargetOutline()
        showOrHide()
    }

    private func displayOptionsChanged() {
        let workspace = NSWorkspace.shared
        model.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        model.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        overlay.reduceMotion = model.reduceMotion
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
        panel.setFrame(IslandGeometry.frame(shape, on: model.top), display: true)
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
