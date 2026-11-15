// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Every floating window of the app (the island, its hover zones, the on-screen selection): borderless and
/// non-activating, on every desktop and over other apps' full-screen windows, never activating the app or
/// changing the app in front. It takes the keyboard only while `wantsKey` (a non-activating panel is key
/// without activating the app, and while key it gets the keyboard even with another app in front).
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()  // Esc
        case 36, 76: onConfirm?()  // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    /// Once per key press.
    private func cancel() {
        let event = NSApp.currentEvent?.timestamp
        if let event, event == cancelledEvent { return }
        cancelledEvent = event
        onCancel?()
    }

    /// In front of everything at its level, and key if it wants the keyboard, without activating the app.
    func show() {
        orderFrontRegardless()
        if wantsKey { makeKey() }
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

extension Duration {
    /// For AppKit and SwiftUI animations.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

extension NSScreen {
    /// Its `CGDirectDisplayID`.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
