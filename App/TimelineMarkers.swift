// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// The markers' flags on the timeline's ruler (phase 3 design §8.3, 3d plan decisions 1 to 3), on top of
/// `MarkerCommands` and `MarkerRulerRules`: what the mouse does to a flag. A click takes the playhead to its marker; a
/// drag moves it (one gesture: the timeline and the preview follow it, it snaps to the edit points as an edge does, and
/// its release is one `marker.move` step); a double click names it in a popover (↩ keeps the name, Esc leaves it); its
/// menu has Rename… and Delete. ⌥ on the ruler is still the marks'. Markers are never part of the timeline's selection.
extension TimelineInteraction {
    /// The marker whose flag is under `point` (the view's coordinates), if it is on the ruler: the nearest flag within
    /// `MarkerRulerRules.hitTolerance` of the mouse, measured from the middle of the flag.
    func marker(at point: CGPoint) -> VisibleMarker? {
        guard point.y < TimelineLayout.rulerHeight, let content = view.content, !content.markers.isEmpty,
            let geometry = view.geometry()
        else { return nil }
        let flags = content.markers.map { (id: $0.id, x: geometry.snapped(geometry.x($0.output)) + TimelineRuler.flagWidth / 2) }
        // The playhead's head wins over a flag under it (a click on the flag leaves the playhead on its marker).
        let playheadX = geometry.snapped(geometry.x(view.drawnPlayhead))
        guard let id = MarkerRulerRules.hit(x: point.x - TimelineLayout.headerWidth, flags: flags, playheadX: playheadX)
        else { return nil }
        return content.markers.first { $0.id == id }
    }

    /// The mouse pressed on the ruler at `point`: on a flag, a press (a click or a drag, as the mouse goes on), or with a
    /// double click its name asked for. Whether it was on one.
    func markerMouseDown(_ event: NSEvent, at point: CGPoint) -> Bool {
        guard let marker = marker(at: point) else { return false }
        if event.clickCount >= 2 {
            drag = .none
            if canEdit { askMarkerName(marker) }
            return true
        }
        drag = .pressedMarker(down: point, marker: marker)
        return true
    }

    /// A flag pressed or being dragged: from 3 pt on (`MarkerRulerRules.isDrag`), the marker follows the mouse. For
    /// viewing only, the ruler's drag moves the playhead, as it would anywhere else on it.
    func markerMouseDragged(_ event: NSEvent) {
        let point = point(event)
        switch drag {
        case let .pressedMarker(down, marker):
            guard MarkerRulerRules.isDrag(from: down.x, to: point.x) else { return }
            guard let base = begin() else {
                drag = .playhead
                view.scrub(at: point.x)
                return
            }
            drag = .moveMarker(base, marker: marker)
            updateMarkerDrag(base, marker, event)
        case let .moveMarker(base, marker):
            updateMarkerDrag(base, marker, event)
        default:
            break
        }
    }

    /// The mouse released over a flag: a click takes the playhead to its marker; a drag makes its last step, once.
    func markerMouseUp() {
        switch drag {
        case let .pressedMarker(_, marker):
            model?.goTo(marker)
        case .moveMarker:
            guard let model else { return }
            lastStep = nil
            if !model.endGesture() { view.setPreview(nil) }
        default:
            break
        }
    }

    /// The marker at the output time under the mouse, snapped as an edge is (`snapped(_:event:base:)`): the step of
    /// `MarkerCommands.move` (none where it is already, or where nothing is shown), shown by the timeline and the
    /// preview, with its time and how far it went beside the mouse.
    private func updateMarkerDrag(_ base: Base, _ marker: VisibleMarker, _ event: NSEvent) {
        let point = point(event)
        // Within the output: a marker needs a frame that shows something.
        let last = max(base.map.duration - 1, 0)
        let τ = min(snapped(clamped(output(at: point)), event: event, base: base), last)
        let step = MarkerCommands.move(base.document, marker, toOutput: τ, timeMap: base.map) { EditorModel.newID($0) }
        lastStep = step
        NSCursor.closedHand.set()
        view.setPreview(model?.updateGesture(step))
        let now = step.flatMap { step in view.content?.markers.first { $0.id == step.target }?.output } ?? marker.output
        showLabel(
            TimelineDragRules.trimLabel(delta: now - marker.output, position: now, total: base.map.duration, locale: .current),
            at: point.x)
    }

    /// The menu of a flag at `point` (the view's coordinates): Rename… and Delete; `nil` if no flag is there.
    func markerMenu(at point: CGPoint) -> NSMenu? {
        guard let model, let marker = marker(at: point) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rename = MarkerMenuItem(String(localized: "Rename…", comment: "The menu of a marker's flag on the timeline's ruler")) {
            [weak self] in self?.askMarkerName(marker)
        }
        let delete = MarkerMenuItem(String(localized: "Delete")) { model.deleteMarker(marker) }
        for item in [rename, delete] {
            item.isEnabled = canEdit
            menu.addItem(item)
        }
        return menu
    }

    /// The name of `marker`, asked for in a popover over its flag (at the ruler's edge if it is out of sight): ↩ keeps it,
    /// Esc or a click elsewhere leaves it as it was.
    func askMarkerName(_ marker: VisibleMarker) {
        guard let model, model.canEdit, view.window != nil, let geometry = view.geometry() else { return }
        let x = min(max(geometry.x(marker.output), 0), geometry.areaWidth)
        let anchor = CGRect(
            x: TimelineLayout.headerWidth + x - 2, y: 0, width: TimelineRuler.flagWidth + 4, height: TimelineLayout.rulerHeight)
        MarkerNamePopover.show(name: marker.name, relativeTo: anchor, of: view) { [weak model] name in
            model?.renameMarker(marker, to: name)
        }
    }
}

/// The popover that names a marker: one field with its name, ↩ keeps what is typed, Esc leaves it. One at a time.
@MainActor
final class MarkerNamePopover: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    private static var shown: NSPopover?
    private let field = NSTextField()
    private let name: String
    private let save: (String) -> Void
    private weak var popover: NSPopover?

    private init(name: String, save: @escaping (String) -> Void) {
        self.name = name
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Shows the popover under `rect` of `view` with `name`; `save` gets what is typed when ↩ is pressed.
    static func show(name: String, relativeTo rect: CGRect, of view: NSView, save: @escaping (String) -> Void) {
        shown?.performClose(nil)
        let controller = MarkerNamePopover(name: name, save: save)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        popover.delegate = controller
        controller.popover = popover
        shown = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        controller.focusField()
    }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Marker Name", comment: "The popover that names a marker of the timeline"))
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        field.stringValue = name
        field.placeholderString = String(localized: "Unnamed Marker")
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(String(localized: "Marker Name", comment: "The popover that names a marker of the timeline"))
        let stack = NSStackView(views: [title, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        view = stack
    }

    private func focusField() {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save(field.stringValue)
            popover?.performClose(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.performClose(nil)
            return true
        default:
            return false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.shown === popover { Self.shown = nil }
    }
}

/// A menu item of a flag's menu, which runs a closure.
private final class MarkerMenuItem: NSMenuItem {
    private let body: () -> Void

    init(_ title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }

    @objc private func run() {
        body()
    }
}
