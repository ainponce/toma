// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Every floating window of the app (the island, its hover zones, the on-screen selection, the
/// teleprompter): borderless and non-activating, on every desktop and over other apps' full-screen windows,
/// never activating the app or changing the app in front. It takes the keyboard only while `wantsKey` (a
/// non-activating panel is key without activating the app, and while key it gets the keyboard even with
/// another app in front).
@MainActor
final class FloatingPanel: NSPanel {
    /// The on-screen selection: over the menu bar and the Dock.
    static let selectionLevel = NSWindow.Level.statusBar
    /// Notice capsules, the teleprompter, the camera bubble and the hover zones.
    static let floatingLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// The island: never under the bubble or a zone of the same level. Everything stays under
    /// `.popUpMenu`, so menu bar menus show over it.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// Whether the panel can be key; a borderless panel cannot by default.
    var wantsKey = false
    /// Esc.
    var onCancel: (() -> Void)?
    /// Return or Enter.
    var onConfirm: (() -> Void)?
    /// ⌘W.
    var onClose: (() -> Void)?
    /// The key press Esc was last handled for: it can arrive both as a key and as `cancelOperation`.
    private var cancelledEvent: TimeInterval?

    /// `ignoresMouseEvents` is always set: left alone, the window server lets the mouse through the
    /// transparent pixels.
    init(contentRect: NSRect, level: NSWindow.Level, ignoresMouseEvents: Bool) {
        // The style mask works only when given here; set afterwards it is not applied properly.
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // .canJoinAllApplications: what AppKit documents for a floating window to join other apps'
        // full-screen spaces, also while the app is .regular.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        // At rest the island blends into the notch.
        hasShadow = false
        // The app is never active with a floating panel in front: without this AppKit shows no tooltips.
        allowsToolTipsWhenApplicationIsInactive = true
        // A click on a button does not make the panel key.
        becomesKeyOnlyIfNeeded = true
        self.ignoresMouseEvents = ignoresMouseEvents
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    /// What reaches the panel after its views: Esc, Return and Tab (the key view loop of Full Keyboard
    /// Access). Any other key is dropped here, so it does not beep.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()  // Esc
        case 36, 76: onConfirm?()  // Return, Enter
        case 48: super.keyDown(with: event)  // Tab
        default: break
        }
    }

    /// While the panel is key the keyboard is the panel's, even with another app in front: ⌘W closes what it
    /// shows, and ⌘Q never quits Toma by surprise. While a text is edited (the teleprompter's script), Esc is
    /// `onCancel` (a text view would take it for word completion, and the window's key equivalents come
    /// first, as a dialog's Cancel button does), and the editing shortcuts (⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, ⇧⌘Z) go
    /// straight to it, as the app's Edit menu would send them, also while Toma is not the active app (a
    /// floating panel never activates it). Other shortcuts go to the panel's views as usual.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if isKeyWindow, event.keyCode == 53, modifiers.isEmpty, firstResponder is NSText, onCancel != nil {
            cancel()
            return true
        }
        guard isKeyWindow, modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "w":
                onClose?()
                return true
            case "q":
                return true
            default:
                break
            }
        }
        if firstResponder is NSText, let action = Self.editAction(key: key, shift: modifiers.contains(.shift)),
            NSApp.sendAction(action, to: nil, from: self)
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The editing action of ⌘`key` (with ⇧ if `shift`), if it is one.
    private static func editAction(key: String?, shift: Bool) -> Selector? {
        switch (key, shift) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
    }

    /// Once per key press.
    private func cancel() {
        let event = NSApp.currentEvent?.timestamp
        if let event, event == cancelledEvent { return }
        cancelledEvent = event
        onCancel?()
    }

    /// In front of everything at its level, without activating the app; key too if `makingKey` and it
    /// wants the keyboard.
    func show(makingKey: Bool) {
        orderFrontRegardless()
        if makingKey, wantsKey { makeKey() }
    }
}

/// SwiftUI content for a floating panel: a click on an inactive app is not spent activating it, and the
/// view never sizes its window (that would fight the island's spring).
final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func make(_ rootView: Content) -> FloatingHostingView<Content> {
        let view = FloatingHostingView(rootView: rootView)
        // Otherwise it sets the window's contentMinSize and contentMaxSize.
        view.sizingOptions = []
        // The notch's safe area does not push the content down.
        view.safeAreaRegions = []
        view.autoresizingMask = [.width, .height]
        return view
    }
}

/// An `NSView` that tells when the mouse enters and leaves it, wherever it is and whichever app is
/// active (the island and its hover zones; never a global event monitor).
class TrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
