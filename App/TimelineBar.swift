// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// The timeline's track bar (design §5.1 and §5.5), 32 pt over the ruler: on the left Split, the speed menu and Add Zoom;
/// on the right Snapping, the scale (− slider +) and Fit to Window. It holds no state of the document: the controller says
/// what is enabled and the speed shown, and each control calls back. Its controls are the accessory bar's, each as wide as
/// its label needs (none is cut): the actions and the menus with their bezel; Snapping with one only while it is on, its
/// symbol then in the accent color; the scale's −, + and Fit to Window quiet until the mouse is over them.
@MainActor
final class TimelineBar: NSView {
    static let height = 32.0

    var onSplit: () -> Void = {}
    var onSpeed: (Double) -> Void = { _ in }
    var onCustomSpeed: () -> Void = {}
    var onAddZoom: () -> Void = {}
    /// "Add Blur" (phase 2 design §7.1): a privacy block of 3 s from the playhead.
    var onAddBlur: () -> Void = {}
    /// A layout of "Layout ▾": a block of it at the playhead or over the marked range.
    var onAddLayout: (LayoutKind) -> Void = { _ in }
    var onSnapping: (Bool) -> Void = { _ in }
    /// The slider moved to a scale.
    var onScale: (Double) -> Void = { _ in }
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var onFit: () -> Void = {}

    private let split = NSButton()
    private let speed = NSPopUpButton(frame: .zero, pullsDown: true)
    private let addZoom = NSButton()
    private let addBlur = NSButton()
    private let addLayout = NSPopUpButton(frame: .zero, pullsDown: true)
    private let snapping = NSButton()
    private let smaller = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let larger = NSButton()
    private let fit = NSButton()
    private let separator = NSBox()
    private var fitScale = TimelineLayout.maxPointsPerSecond
    private var shownSpeed: Double??

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        separator.boxType = .separator
        addSubview(separator)
        configure(split, symbol: "scissors", title: String(localized: "Split"), action: #selector(splitClicked))
        configure(addZoom, symbol: "plus.magnifyingglass", title: String(localized: "Add Zoom"), action: #selector(addZoomClicked))
        configure(addBlur, symbol: "eye.slash", title: String(localized: "Add Blur"), action: #selector(addBlurClicked))
        Self.style(addLayout)
        addLayout.setAccessibilityLabel(String(localized: "Add Layout"))
        addLayout.toolTip = String(localized: "Add Layout")
        addLayout.addItem(withTitle: String(localized: "Add Layout"))
        addLayout.item(at: 0)?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        for kind in LayoutNames.order {
            let item = NSMenuItem(title: LayoutNames.name(kind), action: #selector(layoutChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = NSImage(systemSymbolName: LayoutTrackRules.symbol(kind, orientation: .beside), accessibilityDescription: nil)
            addLayout.menu?.addItem(item)
        }
        addLayout.isHidden = true
        configure(snapping, symbol: "arrow.right.and.line.vertical.and.arrow.left", title: String(localized: "Snapping"), action: #selector(snappingClicked))
        snapping.setButtonType(.pushOnPushOff)
        snapping.bezelStyle = .accessoryBar
        snapping.alternateImage = snapping.image
        snapping.state = .on
        showSnapping()
        configure(smaller, symbol: "minus", title: String(localized: "Zoom Out"), action: #selector(smallerClicked), iconOnly: true)
        configure(larger, symbol: "plus", title: String(localized: "Zoom In"), action: #selector(largerClicked), iconOnly: true)
        configure(fit, symbol: "arrow.left.and.right", title: String(localized: "Fit to Window"), action: #selector(fitClicked), iconOnly: true)
        for quiet in [smaller, larger, fit, snapping] { quiet.showsBorderOnlyWhileMouseInside = true }
        Self.style(speed)
        speed.setAccessibilityLabel(String(localized: "Speed"))
        speed.toolTip = String(localized: "Speed")
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.setAccessibilityLabel(String(localized: "Timeline Scale"))
        for view in [split, speed, addZoom, addBlur, addLayout, snapping, smaller, slider, larger, fit] { addSubview(view) }
        setSpeed(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector, iconOnly: Bool = false) {
        Self.style(button)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.title = iconOnly ? "" : title
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
    }

    /// The accessory bar's look, small.
    private static func style(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
    }

    override var isFlipped: Bool { true }

    /// As wide as `button`'s title and symbol need, at least `minimum`; a pull-down menu by its title (its first item),
    /// not by the widest of its items, and room for its arrow.
    private static func width(_ button: NSButton, minimum: Double) -> Double {
        guard let popUp = button as? NSPopUpButton else { return max(ceil(button.intrinsicContentSize.width) + 6, minimum) }
        let item = popUp.itemArray.first
        let font = popUp.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = ((item?.title ?? "") as NSString).size(withAttributes: [.font: font]).width
        let image = item?.image.map { $0.size.width + 5 } ?? 0
        return max(ceil(text + image + 30), minimum)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let y = (bounds.height - 22) / 2
        var x = 8.0
        for (view, minimum) in [(split, 60.0), (speed, 52), (addZoom, 80), (addBlur, 80), (addLayout, 80)] as [(NSButton, Double)] {
            guard !view.isHidden else { continue }
            let width = Self.width(view, minimum: minimum)
            view.frame = NSRect(x: x, y: y, width: width, height: 22)
            x += width + 6
        }
        var right = bounds.width - 8
        for (view, width) in [(fit, 26.0), (larger, 24), (slider, 110), (smaller, 24)] as [(NSView, Double)] {
            right -= width
            view.frame = NSRect(x: right, y: y, width: width, height: 22)
            right -= 2
        }
        right -= 8
        let snappingWidth = Self.width(snapping, minimum: 60)
        snapping.frame = NSRect(x: right - snappingWidth, y: y, width: snappingWidth, height: 22)
    }

    // MARK: - State

    /// Enables the controls that edit (`canEdit`), and shows `speed` (`nil`: none, or mixed) in the speed menu.
    func setEnabled(_ canEdit: Bool, hasClip: Bool, hasCamera: Bool = false) {
        if addLayout.isHidden == hasCamera { needsLayout = true }
        addLayout.isHidden = !hasCamera
        addLayout.isEnabled = canEdit && hasCamera
        split.isEnabled = canEdit
        addZoom.isEnabled = canEdit
        addBlur.isEnabled = canEdit
        speed.isEnabled = canEdit && hasClip
    }

    /// The speed menu: its title is the speed of what it applies to, and its items the presets, "Custom Speed…" and the note.
    func setSpeed(_ value: Double?) {
        guard shownSpeed != .some(value) else { return }
        shownSpeed = .some(value)
        speed.removeAllItems()
        speed.addItem(withTitle: value.map { TimelineFormat.multiplier($0) } ?? "—")
        needsLayout = true
        guard let menu = speed.menu else { return }
        for preset in SequenceCommands.speedPresets {
            let item = NSMenuItem(title: TimelineFormat.multiplier(preset), action: #selector(speedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = value == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: String(localized: "Custom Speed…"), action: #selector(customChosen), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.addItem(Self.speedNote())
    }

    /// The note under the speeds: up to 4× the sound goes faster with the same pitch; faster, there is none.
    static func speedNote() -> NSMenuItem {
        let note = NSMenuItem(title: String(localized: "Up to 4× the sound speeds up without changing pitch; faster, the clip has no sound."), action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.attributedTitle = NSAttributedString(
            string: note.title, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        return note
    }

    func setSnapping(_ on: Bool) {
        snapping.state = on ? .on : .off
        showSnapping()
    }

    /// On, the magnet in the accent color; off, as the other symbols.
    private func showSnapping() {
        snapping.contentTintColor = snapping.state == .on ? .controlAccentColor : nil
    }

    /// The scale is `scale` now, in a range that starts at `fit`.
    func setScale(_ scale: Double, fit: Double) {
        fitScale = fit
        slider.doubleValue = TimelineDragRules.sliderValue(scale: scale, fit: fit)
        slider.isEnabled = fit < TimelineLayout.maxPointsPerSecond
        smaller.isEnabled = slider.isEnabled
        larger.isEnabled = slider.isEnabled
        self.fit.isEnabled = slider.isEnabled
        slider.setAccessibilityValue(String(format: "%.0f%%", slider.doubleValue * 100))
    }

    // MARK: - Actions

    @objc private func splitClicked() { onSplit() }
    @objc private func addZoomClicked() { onAddZoom() }
    @objc private func addBlurClicked() { onAddBlur() }

    @objc private func layoutChosen(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = LayoutKind(rawValue: raw) { onAddLayout(kind) }
    }
    @objc private func snappingClicked() {
        showSnapping()
        onSnapping(snapping.state == .on)
    }
    @objc private func smallerClicked() { onZoomOut() }
    @objc private func largerClicked() { onZoomIn() }
    @objc private func fitClicked() { onFit() }
    @objc private func customChosen() { onCustomSpeed() }

    @objc private func speedChosen(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { onSpeed(value) }
    }

    @objc private func sliderMoved() {
        onScale(TimelineDragRules.sliderScale(value: slider.doubleValue, fit: fitScale))
    }
}

/// The timeline's part of the window: the track bar over the timeline.
final class TimelineContainer: NSView {
    private let bar: TimelineBar
    let timeline: EditorTimelineView

    init(bar: TimelineBar, timeline: EditorTimelineView) {
        self.bar = bar
        self.timeline = timeline
        super.init(frame: .zero)
        addSubview(bar)
        addSubview(timeline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineBar.height)
        timeline.frame = CGRect(x: 0, y: TimelineBar.height, width: bounds.width, height: max(bounds.height - TimelineBar.height, 0))
    }
}
