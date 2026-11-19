// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import ProjectFormat
import SwiftUI

/// A panel over each screen for choosing what to record on the screen itself. Highlighting (the pointer over a
/// display's row in the panel) only draws, and lets the mouse through. Choosing ("Choose on Screen") covers
/// every screen, so a click never reaches the app below: in Display mode it chooses the display under it; in
/// Window mode the window under the pointer is highlighted (`WindowHitTest`, with the selector spring) and a
/// click chooses it; in Area mode the area is drawn, moved and resized (`AreaSelectionView`). Esc and Return go
/// back.
@MainActor
final class SelectionOverlay: NSObject, NSWindowDelegate {
    /// What "Choose on Screen" chooses.
    enum Choosing {
        case display
        /// A window for `panel`, which says its size.
        case window(OpenPanelModel)
        /// The area of `panel`, which the screens draw and change.
        case area(OpenPanelModel)
    }

    /// A click on this display while choosing a display.
    var chose: (UInt32) -> Void = { _ in }
    /// A click on this window while choosing a window.
    var choseWindow: (WindowCandidate) -> Void = { _ in }
    /// Esc or Return while choosing.
    var ended: () -> Void = {}
    /// The keyboard went to another app (Cmd-Tab, Mission Control) while choosing.
    var leftForAnotherApp: () -> Void = {}
    /// ⌘W while choosing.
    var closed: () -> Void = {}
    /// "Reduce motion": the highlight fades in and out, without scale or spring.
    var reduceMotion = false {
        didSet { shared.reduceMotion = reduceMotion }
    }
    var reduceTransparency = false {
        didSet { shared.reduceTransparency = reduceTransparency }
    }

    private struct Screen {
        let panel: FloatingPanel
        let view: OverlayView
        let content: PassthroughHostingView<OverlayContent>
        let model: OverlayModel
    }

    private var screens: [UInt32: Screen] = [:]
    private let shared = SharedOverlayModel()
    /// The windows on the screen when choosing a window began, front to back.
    private var windows: [WindowCandidate] = []
    private(set) var isChoosing = false

    /// Highlights `displayID` alone (`nil`: none), without taking the mouse.
    func highlight(_ displayID: UInt32?, names: [UInt32: String]) {
        guard !isChoosing else { return }
        prepare(names: names, barTops: [:])
        shared.choosing = nil
        for (id, screen) in screens {
            screen.panel.ignoresMouseEvents = true
            screen.panel.wantsKey = false
            screen.content.passesThrough = true
            screen.view.layer?.backgroundColor = NSColor.clear.cgColor
            setHighlighted(id == displayID, on: screen)
            if id == displayID { screen.panel.orderFrontRegardless() }
        }
    }

    /// Covers every screen for `choosing`; the panel of the screen under the pointer takes the keyboard. Choosing a
    /// display highlights the one under the pointer; choosing a window, the window under it. `barTops` is where the
    /// area bar goes on each screen.
    func beginChoosing(_ choosing: Choosing, names: [UInt32: String], barTops: [UInt32: Double], pointerDisplayID: UInt32?) {
        prepare(names: names, barTops: barTops)
        isChoosing = true
        shared.choosing = choosing
        shared.startDisplayID = pointerDisplayID
        shared.hoveredWindow = nil
        windows = []
        if case .window = choosing { windows = WindowList.onScreen() }
        for (id, screen) in screens {
            let isArea = if case .area = choosing { true } else { false }
            screen.panel.ignoresMouseEvents = false
            screen.panel.wantsKey = true
            screen.panel.acceptsMouseMovedEvents = true
            // In Area mode the view draws the area and takes the mouse itself.
            screen.content.passesThrough = !isArea
            // Almost transparent: the window gets the mouse instead of the app below.
            screen.view.layer?.backgroundColor = NSColor(white: 0, alpha: 0.01).cgColor
            switch choosing {
            case .display:
                screen.view.onEnter = { [weak self] in self?.pointer(over: id) }
                screen.view.onMove = nil
                screen.view.onClick = { [weak self] in self?.chose(id) }
                setHighlighted(id == pointerDisplayID, on: screen)
            case .window:
                screen.view.onEnter = { [weak self] in self?.pointerMoved() }
                screen.view.onMove = { [weak self] in self?.pointerMoved() }
                screen.view.onClick = { [weak self] in self?.clickedWindow() }
                setHighlighted(false, on: screen)
            case .area:
                screen.view.onEnter = nil
                screen.view.onMove = nil
                screen.view.onClick = nil
                setHighlighted(false, on: screen)
            }
            screen.panel.orderFrontRegardless()
        }
        if case .window = choosing { pointerMoved() }
        if let pointerDisplayID, let screen = screens[pointerDisplayID] {
            screen.panel.makeKey()
        } else {
            screens.values.first?.panel.makeKey()
        }
    }

    /// Takes every panel off the screen.
    func end() {
        isChoosing = false
        shared.choosing = nil
        shared.hoveredWindow = nil
        windows = []
        for screen in screens.values {
            screen.view.onEnter = nil
            screen.view.onMove = nil
            screen.view.onClick = nil
            screen.panel.wantsKey = false
            screen.content.passesThrough = true
            setHighlighted(false, on: screen)
            screen.panel.orderOut(nil)
        }
    }

    /// The panels follow the screens: made again when they changed.
    private func prepare(names: [UInt32: String], barTops: [UInt32: Double]) {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let current = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.frame) } }) { first, _ in first }
        let unchanged = Set(current.keys) == Set(screens.keys) && current.allSatisfy { screens[$0.key]?.panel.frame == $0.value }
        if unchanged {
            for (id, screen) in screens {
                screen.model.name = names[id] ?? ""
                screen.model.screen = OverlayScreen(displayID: id, frame: screen.model.screen.frame, barTop: barTops[id] ?? 0)
            }
            return
        }
        for screen in screens.values { screen.panel.orderOut(nil) }
        screens = [:]
        for (id, frame) in current {
            let panel = FloatingPanel(contentRect: frame, level: FloatingPanel.selectionLevel, ignoresMouseEvents: true)
            let global = ScreenCoordinates.global(fromAppKit: frame, primaryScreenHeight: primaryHeight)
            let model = OverlayModel(name: names[id] ?? "", screen: OverlayScreen(displayID: id, frame: global, barTop: barTops[id] ?? 0))
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            let content = PassthroughHostingView(rootView: OverlayContent(model: model, shared: shared))
            content.sizingOptions = []
            content.safeAreaRegions = []
            content.frame = view.bounds
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panel.delegate = self
            panel.onCancel = { [weak self] in self?.endedIfChoosing() }
            panel.onConfirm = { [weak self] in self?.endedIfChoosing() }
            panel.onClose = { [weak self] in
                guard let self, isChoosing else { return }
                closed()
            }
            screens[id] = Screen(panel: panel, view: view, content: content, model: model)
        }
    }

    private func pointer(over id: UInt32) {
        for (other, screen) in screens { setHighlighted(other == id, on: screen) }
    }

    private func setHighlighted(_ highlighted: Bool, on screen: Screen) {
        guard screen.model.isHighlighted != highlighted else { return }
        withAnimation(.island(Motion.selector, reduceMotion: reduceMotion)) {
            screen.model.isHighlighted = highlighted
        }
    }

    /// The window under the pointer is highlighted, moving from the last one with the selector spring.
    private func pointerMoved() {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let pointer = ScreenCoordinates.global(fromAppKit: CGRect(origin: NSEvent.mouseLocation, size: .zero), primaryScreenHeight: primaryHeight)
        let under = WindowHitTest.topmost(
            at: CGPoint(x: pointer.x, y: pointer.y), in: windows, excludingPID: ProcessInfo.processInfo.processIdentifier)
        guard under != shared.hoveredWindow else { return }
        withAnimation(.island(Motion.selector, reduceMotion: reduceMotion)) {
            shared.hoveredWindow = under
        }
    }

    private func clickedWindow() {
        pointerMoved()
        if let window = shared.hoveredWindow { choseWindow(window) }
    }

    private func endedIfChoosing() {
        if isChoosing { ended() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isChoosing else { return }
        // Once the key window has changed: to another of these panels or the island, choosing goes on.
        Task { @MainActor [weak self] in
            guard let self, isChoosing else { return }
            if let key = NSApp.keyWindow, !key.styleMask.contains(.titled) { return }
            leftForAnotherApp()
        }
    }
}

/// One screen's state.
@MainActor @Observable
private final class OverlayModel {
    var isHighlighted = false
    var name: String
    var screen: OverlayScreen

    init(name: String, screen: OverlayScreen) {
        self.name = name
        self.screen = screen
    }
}

/// What every screen shows alike.
@MainActor @Observable
private final class SharedOverlayModel {
    /// What is being chosen; `nil` while a display is only highlighted.
    var choosing: SelectionOverlay.Choosing?
    /// The screen with the pointer when choosing began: the area bar is there until there is an area.
    var startDisplayID: UInt32?
    /// The window under the pointer while choosing a window.
    var hoveredWindow: WindowCandidate?
    var reduceMotion = false
    var reduceTransparency = false
}

/// What one screen shows: the display highlighted, the window under the pointer, or the area being drawn.
private struct OverlayContent: View {
    let model: OverlayModel
    let shared: SharedOverlayModel

    var body: some View {
        Group {
            switch shared.choosing {
            case .window(let panel):
                WindowHighlight(
                    window: shared.hoveredWindow, size: shared.hoveredWindow.map(panel.pixelSize(of:)), screen: model.screen,
                    reduceMotion: shared.reduceMotion)
            case .area(let panel):
                AreaSelectionView(
                    panel: panel, screen: model.screen,
                    showsBar: (panel.selection.area?.displayID ?? shared.startDisplayID ?? model.screen.displayID) == model.screen.displayID,
                    reduceMotion: shared.reduceMotion, reduceTransparency: shared.reduceTransparency)
            case .display, nil:
                SelectionHighlight(model: model, reduceMotion: shared.reduceMotion)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.islandReduceMotion, shared.reduceMotion)
    }
}

/// The display that would be recorded: a frame in the accent color around it and its name.
private struct SelectionHighlight: View {
    let model: OverlayModel
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isHighlighted {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .transition(.opacity)
                Label { Text(verbatim: model.name) } icon: { Image(systemName: "display") }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor.opacity(0.92)))
                    .padding(.bottom, 36)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The window under the pointer (the prototype's): a frame in the accent color around it, and its app and size in the
/// middle.
/// It moves from one window to the next with the selector spring (`SelectionOverlay` changes it inside that
/// animation); each screen draws its part of it.
private struct WindowHighlight: View {
    let window: WindowCandidate?
    /// Its size in the pixels it would record at.
    let size: String?
    let screen: OverlayScreen
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let window {
                let rect = CGRect(
                    x: window.frame.x - screen.frame.x - 3, y: window.frame.y - screen.frame.y - 3, width: window.frame.width + 6,
                    height: window.frame.height + 6)
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                    .overlay {
                        Label {
                            Text(verbatim: "\(window.ownerName) · \(size ?? "")")
                        } icon: {
                            Image(systemName: "macwindow")
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(0.92)))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 8)
                        .fixedSize()
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Only draws while `passesThrough`: the clicks and the pointer go to the view under it. Otherwise it takes them
/// (the area being drawn), from the first click even while the app is not active.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var passesThrough = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThrough ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class OverlayView: TrackingView {
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?()
    }
}
