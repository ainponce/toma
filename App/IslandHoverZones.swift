// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport

/// Where the pointer makes the island peek on each screen: one panel over the notch (black, like it) or
/// over the 60 × 8 pt at the top center of a screen without one (almost transparent, so it gets the
/// mouse). On the notch screen the island is on, the island at rest covers the same rectangle and its own
/// tracking area is the zone, so that zone's panel is taken off the screen.
@MainActor
final class IslandHoverZones {
    var entered: (UInt32) -> Void = { _ in }
    var exited: (UInt32) -> Void = { _ in }
    /// A click on a notch zone.
    var clicked: (UInt32) -> Void = { _ in }

    /// The display whose zone the island stands in for.
    private(set) var covered: UInt32?
    private var zones: [UInt32: FloatingPanel] = [:]

    var displayIDs: [UInt32] { Array(zones.keys) }

    /// One zone per screen, replacing the ones there were.
    func rebuild(_ tops: [UInt32: ScreenTop]) {
        for panel in zones.values { panel.orderOut(nil) }
        zones = [:]
        for (id, top) in tops {
            let frame = IslandGeometry.hoverZone(on: top)
            let panel = FloatingPanel(contentRect: frame, level: FloatingPanel.floatingLevel, ignoresMouseEvents: false)
            let view = ZoneView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = (top.notch == nil ? NSColor(white: 0, alpha: 0.01) : NSColor.black).cgColor
            view.onEnter = { [weak self] in self?.entered(id) }
            view.onExit = { [weak self] in self?.exited(id) }
            if top.notch != nil {
                view.onClick = { [weak self] in self?.clicked(id) }
            }
            panel.contentView = view
            panel.setFrame(frame, display: false)
            zones[id] = panel
        }
        show()
    }

    /// The island stands in for this display's zone (`nil`: for none).
    func setCovered(_ id: UInt32?) {
        covered = id
        show()
    }

    private func show() {
        for (id, panel) in zones {
            if id == covered {
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
    }
}

private final class ZoneView: TrackingView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
