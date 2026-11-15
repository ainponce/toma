// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import SwiftUI

/// A panel over each screen that shows which display would be recorded. Highlighting (the pointer over a
/// display's row in the panel) only draws, and lets the mouse through. Choosing ("Choose on Screen")
/// covers every screen, so a click chooses the display under it and never reaches the app below; Esc and
/// Return go back.
@MainActor
final class SelectionOverlay: NSObject, NSWindowDelegate {
    /// A click on this display while choosing.
    var chose: (UInt32) -> Void = { _ in }
    /// Esc or Return while choosing.
    var ended: () -> Void = {}
    /// The keyboard went to another app (Cmd-Tab, Mission Control) while choosing.
    var leftForAnotherApp: () -> Void = {}
    /// ⌘W while choosing.
    var closed: () -> Void = {}
    /// "Reduce motion": the highlight fades in and out, without scale.
    var reduceMotion = false {
        didSet { for screen in screens.values { screen.model.reduceMotion = reduceMotion } }
    }

    private struct Screen {
        let panel: FloatingPanel
        let view: OverlayView
        let model: OverlayModel
    }

    private var screens: [UInt32: Screen] = [:]
    private(set) var isChoosing = false

    /// Highlights `displayID` alone (`nil`: none), without taking the mouse.
    func highlight(_ displayID: UInt32?, names: [UInt32: String]) {
        guard !isChoosing else { return }
        prepare(names: names)
        for (id, screen) in screens {
            screen.panel.ignoresMouseEvents = true
            screen.panel.wantsKey = false
            screen.view.layer?.backgroundColor = NSColor.clear.cgColor
            setHighlighted(id == displayID, on: screen)
            if id == displayID { screen.panel.orderFrontRegardless() }
        }
    }

    /// Covers every screen and highlights the one under the pointer, whose panel takes the keyboard.
    func beginChoosing(names: [UInt32: String], pointerDisplayID: UInt32?) {
        prepare(names: names)
        isChoosing = true
        for (id, screen) in screens {
            screen.panel.ignoresMouseEvents = false
            screen.panel.wantsKey = true
            // Almost transparent: the window gets the mouse instead of the app below.
            screen.view.layer?.backgroundColor = NSColor(white: 0, alpha: 0.01).cgColor
            screen.view.onEnter = { [weak self] in self?.pointer(over: id) }
            screen.view.onClick = { [weak self] in self?.chose(id) }
            setHighlighted(id == pointerDisplayID, on: screen)
            screen.panel.orderFrontRegardless()
        }
        if let pointerDisplayID, let screen = screens[pointerDisplayID] {
            screen.panel.makeKey()
        } else {
            screens.values.first?.panel.makeKey()
        }
    }

    /// Takes every panel off the screen.
    func end() {
        isChoosing = false
        for screen in screens.values {
            screen.view.onEnter = nil
            screen.view.onClick = nil
            screen.panel.wantsKey = false
            setHighlighted(false, on: screen)
            screen.panel.orderOut(nil)
        }
    }

    /// The panels follow the screens: made again when they changed.
    private func prepare(names: [UInt32: String]) {
        let current = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.frame) } }) { first, _ in first }
        let unchanged = Set(current.keys) == Set(screens.keys) && current.allSatisfy { screens[$0.key]?.panel.frame == $0.value }
        if unchanged {
            for (id, screen) in screens { screen.model.name = names[id] ?? "" }
            return
        }
        for screen in screens.values { screen.panel.orderOut(nil) }
        screens = [:]
        for (id, frame) in current {
            let panel = FloatingPanel(contentRect: frame, level: FloatingPanel.selectionLevel, ignoresMouseEvents: true)
            let model = OverlayModel(name: names[id] ?? "", reduceMotion: reduceMotion)
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            let content = PassthroughHostingView(rootView: SelectionHighlight(model: model))
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
            screens[id] = Screen(panel: panel, view: view, model: model)
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

@MainActor @Observable
private final class OverlayModel {
    var isHighlighted = false
    var name: String
    var reduceMotion: Bool

    init(name: String, reduceMotion: Bool) {
        self.name = name
        self.reduceMotion = reduceMotion
    }
}

/// The display that would be recorded: a blue frame around it and its name.
private struct SelectionHighlight: View {
    let model: OverlayModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isHighlighted {
                Rectangle()
                    .strokeBorder(Color(nsColor: .systemBlue).opacity(0.95), lineWidth: 3)
                    .background(Color(nsColor: .systemBlue).opacity(0.08))
                    .transition(.opacity)
                Label { Text(verbatim: model.name) } icon: { Image(systemName: "display") }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(nsColor: .systemBlue).opacity(0.92)))
                    .padding(.bottom, 36)
                    .transition(model.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Only draws: the clicks and the pointer go to the view under it.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class OverlayView: TrackingView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
