// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// Where things are drawn in the timeline's area (right of the headers) at a scale and a scroll.
struct TimelineGeometry {
    /// A row under the ruler: its top in the rows (before they are scrolled up and down) and its height.
    struct Row {
        var track: TimelineTrack
        var top: Double
        var height: Double
    }

    let layout: TimelineLayout
    /// Points per second, and how far the timeline is scrolled left, in points.
    let scale: Double
    let offset: Double
    let areaWidth: Double
    let verticalOffset: Double
    let rows: [Row]
    let rowsHeight: Double
    let backingScale: Double

    /// Where output time `τ` is, from the left of the area: `TimelineLayout.x(ofOutput:)` without the headers.
    func x(_ τ: Int64) -> Double {
        layout.x(ofOutput: τ, scale: scale, offset: offset) - TimelineLayout.headerWidth
    }

    /// The output time at `x` from the left of the area.
    func output(atX x: Double) -> Int64 {
        layout.output(atX: x + TimelineLayout.headerWidth, scale: scale, offset: offset)
    }

    /// The output times at the area's left and right edges.
    var visibleOutput: (lower: Int64, upper: Int64) { (output(atX: 0), output(atX: areaWidth)) }

    /// The frame of `item` in the area (from its left and from its top, the ruler first), as it is drawn: its rectangle in
    /// its row, or a square on the diamond of a camera change; `nil` if its row or it is out of sight.
    func itemFrame(of item: TimelineItem) -> CGRect? {
        guard let row = rows.first(where: { $0.track == item.track }) else { return nil }
        let top = TimelineLayout.rulerHeight + row.top - verticalOffset
        switch item.track {
        case .video, .screen: return itemRect(item.output, top: top + 2, height: row.height - 4, gap: 1)
        case .zoom: return itemRect(item.output, top: top + 3, height: row.height - 6, gap: 1)
        case .camera:
            let x = snapped(self.x(item.output.lowerBound))
            guard x > -8, x < areaWidth + 8 else { return nil }
            return CGRect(x: x - 6, y: top + row.height / 2 - 6, width: 12, height: 12)
        case .ruler, .audio: return nil
        }
    }

    /// `x` on the display's pixels.
    func snapped(_ x: Double) -> Double {
        (x * backingScale).rounded() / backingScale
    }

    /// The rectangle of an item over `output`, on pixels, `gap` points narrower (so items side by side are apart), at
    /// least a point wide, and cut to the area and 8 pt more on each side; `nil` if it is out of sight.
    func itemRect(_ output: Range<Int64>, top: Double, height: Double, gap: Double) -> CGRect? {
        let overhang = 8.0
        var minX = snapped(x(output.lowerBound) + gap / 2), maxX = snapped(x(output.upperBound) - gap / 2)
        if maxX - minX < 1 { maxX = minX + 1 }
        guard maxX > -overhang, minX < areaWidth + overhang else { return nil }
        minX = max(minX, -overhang)
        maxX = min(maxX, areaWidth + overhang)
        return CGRect(x: minX, y: top, width: maxX - minX, height: height)
    }
}

/// The timeline's colors in an appearance (the system's, which also follow Increase Contrast), and whether items get a
/// 1 pt border (Increase Contrast, design §5.10).
struct TimelinePalette {
    var background, rulerBackground, separator, tick, label: CGColor
    var clipFill, badgeFill, badgeText, hatchStroke, hatchFill: CGColor
    var zoomFill, zoomAutoFill, zoomStroke, zoomText, zoomAutoText: CGColor
    var screenFill, screenText, camera, microphone, systemAudio: CGColor
    var marker, marksFill, marksEdge, playhead, contrastBorder: CGColor
    /// The selection's outline, the hovered item's wash and the label of a drag.
    var selection, hoverFill, dragLabelFill, dragLabelText: CGColor
    var increaseContrast: Bool

    @MainActor
    static func make(_ appearance: NSAppearance) -> TimelinePalette {
        var palette: TimelinePalette?
        appearance.performAsCurrentDrawingAppearance {
            palette = TimelinePalette(
                background: NSColor.controlBackgroundColor.cgColor, rulerBackground: NSColor.windowBackgroundColor.cgColor,
                separator: NSColor.separatorColor.cgColor, tick: NSColor.tertiaryLabelColor.cgColor,
                label: NSColor.secondaryLabelColor.cgColor,
                clipFill: NSColor.systemGray.withAlphaComponent(0.45).cgColor, badgeFill: NSColor.black.withAlphaComponent(0.6).cgColor,
                badgeText: NSColor.white.cgColor, hatchStroke: NSColor.systemOrange.cgColor,
                hatchFill: NSColor.systemOrange.withAlphaComponent(0.18).cgColor,
                zoomFill: NSColor.systemPurple.withAlphaComponent(0.85).cgColor,
                zoomAutoFill: NSColor.systemPurple.withAlphaComponent(0.28).cgColor, zoomStroke: NSColor.systemPurple.cgColor,
                zoomText: NSColor.white.cgColor, zoomAutoText: NSColor.labelColor.cgColor,
                screenFill: NSColor.systemTeal.withAlphaComponent(0.35).cgColor, screenText: NSColor.labelColor.cgColor,
                camera: NSColor.systemPink.cgColor, microphone: NSColor.systemGreen.withAlphaComponent(0.85).cgColor,
                systemAudio: NSColor.systemBlue.withAlphaComponent(0.85).cgColor, marker: NSColor.systemOrange.cgColor,
                marksFill: NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor, marksEdge: NSColor.controlAccentColor.cgColor,
                playhead: NSColor.systemRed.cgColor, contrastBorder: NSColor.labelColor.cgColor,
                selection: NSColor.controlAccentColor.cgColor, hoverFill: NSColor.labelColor.withAlphaComponent(0.12).cgColor,
                dragLabelFill: NSColor.black.withAlphaComponent(0.75).cgColor, dragLabelText: NSColor.white.cgColor,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        }
        return palette!
    }
}

/// Layers for the items of a track, one per item in sight: those of items that left the sight are hidden and given to
/// the next items that come into it, never made again.
@MainActor
final class LayerPool<L: CALayer> {
    private weak var parent: CALayer?
    private let make: () -> L
    private var shown: [String: L] = [:]
    private var spare: [L] = []
    private var used: Set<String> = []

    init(parent: CALayer, make: @escaping () -> L) {
        self.parent = parent
        self.make = make
    }

    /// Starts a pass over the items in sight.
    func begin() {
        used.removeAll(keepingCapacity: true)
    }

    /// The layer of item `id`, and whether it was just given to it (to be set up for it).
    func layer(_ id: String) -> (L, isNew: Bool) {
        used.insert(id)
        if let layer = shown[id] { return (layer, false) }
        let layer: L
        if let reused = spare.popLast() {
            layer = reused
            layer.isHidden = false
        } else {
            layer = make()
            parent?.addSublayer(layer)
        }
        shown[id] = layer
        return (layer, true)
    }

    /// Ends the pass: the layers of the items not asked for are hidden and kept for others.
    func end() {
        for id in shown.keys where !used.contains(id) {
            guard let layer = shown.removeValue(forKey: id) else { continue }
            layer.isHidden = true
            spare.append(layer)
        }
    }

    func removeAll() {
        for layer in Array(shown.values) + spare { layer.removeFromSuperlayer() }
        shown = [:]
        spare = []
    }

    var shownCount: Int { shown.count }
}

/// The timeline's text layers: the system font on one line, cut with "…".
enum TimelineText {
    static func setUp(_ text: CATextLayer, size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) {
        text.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.isWrapped = false
        text.truncationMode = .end
    }
}

// MARK: - The view

/// The editor's timeline (design §5.5), in AppKit with Core Animation (design §4.3): the headers of the tracks on the
/// left, and right of them the ruler and the tracks, drawn by `TimelineRuler` and `TimelineTracks` with one layer per
/// item in sight; the playhead (`systemRed`) is a layer of its own that moves without anything else being drawn again.
///
/// - Scale: from the whole sequence in the width to 600 pt per second; ⌘+ and ⌘− double and halve it with
///   `Motion.timelineZoom` around the playhead (or the middle, when it is out of sight), a pinch on the trackpad follows
///   the fingers 1:1 without animation, ⌥ and the scroll wheel too, and ⇧Z fits the sequence to the width again. It opens
///   fitted, and stays fitted as the window or the sequence changes until it is scaled.
/// - Scrolling: sideways with the trackpad or the wheel, up and down when the rows are taller than the timeline. While
///   playing, a page at a time with `Motion.timelineScroll` when the playhead reaches the right edge
///   (`TimelineLayout.autoscrollOffset`), unless it was scrolled away by hand, until the playhead is in sight again.
/// - With Reduce Motion, the scale and the scroll change at once with a fade (`Motion.reducedMotionFade`).
/// - A click or a drag on the ruler moves the playhead (`onScrub`, `onScrubEnd`).
@MainActor
final class EditorTimelineView: NSView, NSViewToolTipOwner {
    // MARK: What it shows

    /// The playhead while paused, in output nanoseconds; playing, `playbackTime` is read on each refresh.
    var playhead: Int64 = 0 {
        didSet { if playhead != oldValue, !isPlaying { placePlayhead() } }
    }
    var isPlaying = false {
        didSet { if isPlaying != oldValue { playingChanged() } }
    }
    var playbackTime: () -> Int64 = { 0 }
    var marks = TimelineMarks() {
        didSet { if marks != oldValue { needsLayout = true } }
    }
    /// Whether the document can be changed (the headers' Mute).
    var canEdit = false {
        didSet { if canEdit != oldValue { updateHeaders() } }
    }
    var onScrub: (Int64) -> Void = { _ in }
    var onScrubEnd: () -> Void = {}
    var onMute: (_ track: String, _ muted: Bool) -> Void = { _, _ in }
    /// What is selected, by id: drawn outlined in the accent color.
    var selected: Set<String> = [] {
        didSet { if selected != oldValue { tracks.selected = selected; needsLayout = true } }
    }
    /// Edges snap (design §5.5): N, and the bar's button, toggle it; ⌘ held while dragging inverts it.
    var snapping = true {
        didSet { if snapping != oldValue { onSnappingChange() } }
    }
    var onSnappingChange: () -> Void = {}
    /// The scale changed (the bar's slider follows it).
    var onScaleChange: () -> Void = {}
    /// The mouse's editing of the timeline: its drags, hover and menus.
    private(set) lazy var interaction = TimelineInteraction(view: self)

    let tracks = TimelineTracks()
    private(set) var content: TimelineContent?
    /// What `content` was made from.
    private var shown: (take: TakeRecord, document: EditDocument, missing: [ClosedRange<Double>])?
    private var shownEvents: [InputEvent] = []
    /// The document a drag shows while it lasts, and until the committed one arrives (`show`): the timeline follows it.
    private var preview: EditDocument?
    /// The next layout settles the items to their new places with `Motion.trackItem`.
    private var settleNext = false
    private var notifiedScale = 0.0
    private var notifiedFit = 0.0
    private var itemsCache: [TimelineItem]?

    // MARK: Scale and scroll

    private(set) var scale = TimelineLayout.maxPointsPerSecond
    private(set) var offset = 0.0
    private(set) var verticalOffset = 0.0
    /// The whole sequence is in the width, and stays so.
    private var fitted = true
    /// ⌘+, ⌘− or ⇧Z under way: the scale's spring (`Self.springValue(ofScale:)`), the scale it goes to, and the output
    /// time that stays at `anchorX`.
    private var zoomAnimation: (spring: SpringValue, target: Double, anchor: Int64, anchorX: Double)?
    private var scrollAnimation: SpringValue?
    /// Playing, the page turns with the playhead; scrolled by hand, not until the playhead is in sight again.
    private var followsPlayhead = true
    private var scrubbing = false
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?
    /// The playhead drawn: `playhead`, or while playing the last time read.
    private var drawnPlayhead: Int64 = 0

    // MARK: Parts

    private let areaView = TimelineAreaView()
    private let ruler = TimelineRuler()
    private let playheadLayer = CALayer()
    let overlay = CALayer()
    private var trackingArea: NSTrackingArea?
    private let playheadLine = CALayer()
    private let playheadHead = CAShapeLayer()
    private let headerColumn = FlippedView()
    private let headerRows = FlippedView()
    private let headerSeparator = NSBox()
    private var headers: [TrackHeaderView] = []
    private(set) var palette: TimelinePalette
    private var displayObserver: NSObjectProtocol?
    /// Where the help over the hatching is.
    private var helpRect: CGRect?

    override init(frame: NSRect) {
        palette = TimelinePalette.make(NSApp.effectiveAppearance)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(areaView)
        headerColumn.clipsToBounds = true
        headerRows.clipsToBounds = true
        headerColumn.addSubview(headerRows)
        headerSeparator.boxType = .separator
        headerColumn.addSubview(headerSeparator)
        addSubview(headerColumn)
        let area = areaView.layer!
        area.masksToBounds = true
        area.addSublayer(ruler.layer)
        area.addSublayer(tracks.layer)
        playheadLayer.addSublayer(playheadLine)
        playheadLayer.addSublayer(playheadHead)
        area.addSublayer(overlay)
        area.addSublayer(playheadLayer)
        tracks.thumbnailArrived = { [weak self] in self?.needsLayout = true }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recolor() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The window closed: the display link, which holds the view, and the notifications stop.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
        displayObserver = nil
        tracks.clear()
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = palette.background
    }

    /// Shows `document` of `take` (with `events`' markers), the spans in `missing` hatched; `nil`, nothing (the project is
    /// opening or cannot be shown).
    func show(take: TakeRecord, events: [InputEvent], document: EditDocument, missing: [ClosedRange<Double>]) {
        if let shown, shown.take == take, shown.document == document, shown.missing == missing, preview == nil { return }
        // A document that is not the one on screen moves the items to their places, unless a drag showed it already.
        settleNext = content != nil && preview == nil && shown?.document != document
        preview = nil
        shown = (take, document, missing)
        shownEvents = events
        rebuildContent()
    }

    /// Shows `document` instead of the committed one while a drag lasts (`nil`: the committed one again). The next `show`
    /// puts the committed one back.
    func setPreview(_ document: EditDocument?) {
        guard shown != nil, document != preview else { return }
        preview = document
        rebuildContent()
    }

    private func rebuildContent() {
        guard let shown else { return }
        let rows = content?.layout.tracks
        let content = TimelineContent(take: shown.take, events: shownEvents, document: preview ?? shown.document, missing: shown.missing)
        self.content = content
        itemsCache = nil
        if content.layout.tracks != rows { makeHeaders() } else { updateHeaders() }
        needsLayout = true
    }

    /// The items the mouse can point at, in the order of their tracks.
    var hitItems: [TimelineItem] {
        if let itemsCache { return itemsCache }
        guard let content else { return [] }
        let items = content.clips.items.map { TimelineItem(id: $0.id, track: .video, output: $0.output) }
            + content.screens.items.map { TimelineItem(id: $0.id, track: .screen, output: $0.output) }
            + content.zooms.items.map { TimelineItem(id: $0.id, track: .zoom, output: $0.output) }
            + content.cameraChanges.items.map { TimelineItem(id: $0.id, track: .camera, output: $0.output) }
        itemsCache = items
        return items
    }

    func showNothing() {
        guard shown != nil else { return }
        shown = nil
        preview = nil
        content = nil
        itemsCache = nil
        fitted = true
        stopAnimations()
        makeHeaders()
        needsLayout = true
    }

    /// A waveform worked out for audio track `track`.
    func setWaveform(_ levels: WaveformLevels, for track: String) {
        tracks.waveformLevels[track] = levels
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutContent()
    }

    private var areaWidth: Double { max(bounds.width - TimelineLayout.headerWidth, 0) }
    private var durationSeconds: Double { Double(content?.map.duration ?? 0) / 1e9 }
    private var rowsHeight: Double { content.map { $0.layout.tracks.dropFirst().reduce(0) { $0 + $1.height } } ?? 0 }
    private var rowsAreaHeight: Double { max(bounds.height - TimelineLayout.rulerHeight, 0) }

    /// Lays out everything at the scale and scroll there are now.
    private func layoutContent() {
        keepScaleAndScroll()
        let width = areaWidth, height = bounds.height
        let header = TimelineLayout.headerWidth
        let frames: [(NSView, CGRect)] = [
            (headerColumn, CGRect(x: 0, y: 0, width: header, height: height)),
            (headerSeparator, CGRect(x: header - 1, y: 0, width: 1, height: height)),
            (headerRows, CGRect(x: 0, y: TimelineLayout.rulerHeight, width: header - 1, height: rowsAreaHeight)),
            (areaView, CGRect(x: header, y: 0, width: width, height: height)),
        ]
        for (view, frame) in frames where view.frame != frame {
            view.frame = frame
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ruler.layer.frame = CGRect(x: 0, y: 0, width: width, height: TimelineLayout.rulerHeight)
        tracks.layer.frame = CGRect(x: 0, y: TimelineLayout.rulerHeight, width: width, height: rowsAreaHeight)
        guard let geometry = geometry() else {
            ruler.clear(palette)
            tracks.clear()
            playheadLayer.isHidden = true
            return
        }
        ruler.update(content!, geometry, palette, marks: marks)
        tracks.settling = settleNext && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if settleNext, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { fade() }
        settleNext = false
        tracks.update(content!, geometry, palette)
        tracks.settling = false
        placeHeaders(geometry)
        placePlayhead(geometry)
        interaction.viewDidLayout(geometry)
        let fit = TimelineLayout.fitScale(duration: durationSeconds, width: areaWidth)
        if scale != notifiedScale || fit != notifiedFit {
            (notifiedScale, notifiedFit) = (scale, fit)
            onScaleChange()
        }
    }

    func geometry() -> TimelineGeometry? {
        guard let content else { return nil }
        var top = 0.0
        let rows = content.layout.tracks.dropFirst().map { row in
            defer { top += row.height }
            return TimelineGeometry.Row(track: row.track, top: top, height: row.height)
        }
        return TimelineGeometry(
            layout: content.layout, scale: scale, offset: offset, areaWidth: areaWidth, verticalOffset: verticalOffset,
            rows: rows, rowsHeight: top, backingScale: Double(window?.backingScaleFactor ?? 2))
    }

    /// The scale within its range (fitted while it is), and the scrolls within the content.
    private func keepScaleAndScroll() {
        let fit = TimelineLayout.fitScale(duration: durationSeconds, width: areaWidth)
        if fitted, zoomAnimation == nil {
            scale = fit
            offset = 0
        } else if zoomAnimation == nil {
            scale = TimelineLayout.clampScale(scale, duration: durationSeconds, width: areaWidth)
        }
        offset = clampedOffset(offset)
        verticalOffset = min(max(verticalOffset, 0), max(rowsHeight - rowsAreaHeight, 0))
    }

    private func clampedOffset(_ offset: Double, scale: Double? = nil) -> Double {
        let end = durationSeconds * (scale ?? self.scale)
        return min(max(offset, 0), max(end - areaWidth, 0))
    }

    // MARK: - Playhead

    private func placePlayhead(_ geometry: TimelineGeometry? = nil) {
        guard let geometry = geometry ?? self.geometry() else { return }
        if !isPlaying { drawnPlayhead = playhead }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let x = geometry.snapped(geometry.x(drawnPlayhead))
        let height = bounds.height
        playheadLayer.isHidden = x < -6 || x > geometry.areaWidth + 6
        playheadLayer.frame = CGRect(x: x - 5.5, y: 0, width: 11, height: height)
        playheadLine.backgroundColor = palette.playhead
        playheadLine.frame = CGRect(x: 5, y: 0, width: 1, height: height)
        playheadHead.fillColor = palette.playhead
        if playheadHead.path == nil {
            let head = CGMutablePath()
            head.move(to: CGPoint(x: 0.5, y: 0))
            head.addLine(to: CGPoint(x: 10.5, y: 0))
            head.addLine(to: CGPoint(x: 10.5, y: 6))
            head.addLine(to: CGPoint(x: 5.5, y: 11))
            head.addLine(to: CGPoint(x: 0.5, y: 6))
            head.closeSubpath()
            playheadHead.path = head
        }
        playheadHead.frame = playheadLayer.bounds
    }

    private func playingChanged() {
        if isPlaying {
            followsPlayhead = true
            lastTick = nil
        } else {
            placePlayhead()
        }
        updateDisplayLink()
    }

    /// Playing: the playhead where the clock is, and the next page once it reaches the right edge.
    private func followPlayback() {
        drawnPlayhead = playbackTime()
        guard !scrubbing, zoomAnimation == nil, let content else { return }
        let layout = content.layout
        let x = layout.x(ofOutput: drawnPlayhead, scale: scale, offset: offset)
        if !followsPlayhead {
            if x >= TimelineLayout.headerWidth, x < TimelineLayout.headerWidth + areaWidth { followsPlayhead = true }
            return
        }
        let target = scrollAnimation?.target ?? offset
        let shown = layout.x(ofOutput: drawnPlayhead, scale: scale, offset: target)
        guard let next = TimelineLayout.autoscrollOffset(playheadX: shown, offset: target, width: areaWidth) else { return }
        let page = clampedOffset(next)
        if page != target { scroll(to: page) }
    }

    /// Scrolls to `target` with `Motion.timelineScroll` (a fade with Reduce Motion).
    private func scroll(to target: Double) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollAnimation = nil
            fade()
            offset = target
            layoutContent()
            return
        }
        var spring = scrollAnimation ?? SpringValue(value: offset, spring: Motion.timelineScroll)
        spring.retarget(target, spring: Motion.timelineScroll)
        scrollAnimation = spring
        updateDisplayLink()
    }

    // MARK: - Scale

    /// ⌘+: twice the scale.
    func zoomIn() {
        zoom(to: (zoomAnimation?.target ?? scale) * 2, anchorX: anchorX(), animated: true)
    }

    /// ⌘−: half the scale.
    func zoomOut() {
        zoom(to: (zoomAnimation?.target ?? scale) / 2, anchorX: anchorX(), animated: true)
    }

    /// ⇧Z: the whole sequence in the width.
    func fitToWindow() {
        // The start stays at the left edge: the scroll ends at 0.
        zoom(to: 0, anchorX: TimelineLayout.headerWidth, animated: true, anchor: 0)
    }

    /// Where the scale changes around: the playhead if it is in sight, otherwise the middle of the area.
    private func anchorX() -> Double {
        guard let content else { return TimelineLayout.headerWidth }
        let x = content.layout.x(ofOutput: drawnPlayhead, scale: scale, offset: offset)
        return (TimelineLayout.headerWidth...(TimelineLayout.headerWidth + areaWidth)).contains(x)
            ? x : TimelineLayout.headerWidth + areaWidth / 2
    }

    /// Scales to `target` (clamped to the range), keeping the output time at `anchorX` there (`anchor`, if given; while a
    /// scale is under way, the one it keeps).
    private func zoom(to target: Double, anchorX: Double, animated: Bool, anchor: Int64? = nil) {
        guard let content else { return }
        let target = TimelineLayout.clampScale(target, duration: durationSeconds, width: areaWidth)
        let (time, anchorX) = anchor.map { ($0, anchorX) } ?? zoomAnimation.map { ($0.anchor, $0.anchorX) }
            ?? (content.layout.output(atX: anchorX, scale: scale, offset: offset), anchorX)
        scrollAnimation = nil
        fitted = target <= TimelineLayout.fitScale(duration: durationSeconds, width: areaWidth)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if animated { fade() }
            zoomAnimation = nil
            apply(scale: target, anchor: time, anchorX: anchorX)
            return
        }
        var spring = zoomAnimation?.spring ?? SpringValue(value: Self.springValue(ofScale: scale), spring: Motion.timelineZoom)
        spring.retarget(Self.springValue(ofScale: target), spring: Motion.timelineZoom)
        zoomAnimation = (spring, target, time, anchorX)
        updateDisplayLink()
    }

    /// The scale's spring runs on 1000 × log₂ of it: the scale changes by the same ratio in the same time whatever it is,
    /// and where the spring comes to rest (0.05 from its target) is a few hundred-thousandths of the scale.
    private static func springValue(ofScale scale: Double) -> Double {
        1000 * log2(scale)
    }

    private func apply(scale: Double, anchor: Int64, anchorX: Double) {
        self.scale = scale
        offset = clampedOffset(Double(anchor) * scale / 1e9 - (anchorX - TimelineLayout.headerWidth))
        layoutContent()
    }

    /// With Reduce Motion: what follows in this turn fades in over what was there.
    private func fade() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Motion.reducedMotionFade.timeInterval
        areaView.layer?.add(transition, forKey: "fade")
    }

    // MARK: - Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil, displayObserver != nil else { return }
        // In the common modes, so it goes on while a menu or a drag is tracking.
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDisplayLink()
        recolor()
    }

    private func updateDisplayLink() {
        let needed = isPlaying || zoomAnimation != nil || scrollAnimation != nil
        if needed, displayLink?.isPaused == true { lastTick = nil }
        displayLink?.isPaused = !needed
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let seconds = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 1.0 / 60
        lastTick = now
        var moved = false
        if var zoom = zoomAnimation {
            zoom.spring.step(by: seconds)
            zoomAnimation = zoom.spring.isSettled ? nil : zoom
            scale = zoom.spring.isSettled ? zoom.target : exp2(zoom.spring.value / 1000)
            offset = clampedOffset(Double(zoom.anchor) * scale / 1e9 - (zoom.anchorX - TimelineLayout.headerWidth))
            moved = true
        }
        if var scroll = scrollAnimation {
            scroll.step(by: seconds)
            scrollAnimation = scroll.isSettled ? nil : scroll
            offset = scroll.value
            moved = true
        }
        if isPlaying { followPlayback() }
        if moved { layoutContent() } else if isPlaying { placePlayhead() }
        updateDisplayLink()
    }

    // MARK: - Events

    override func scrollWheel(with event: NSEvent) {
        guard content != nil else { return super.scrollWheel(with: event) }
        let lines = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let dx = event.scrollingDeltaX * lines, dy = event.scrollingDeltaY * lines
        stopAnimations()
        if event.modifierFlags.contains(.option) {
            let x = convert(event.locationInWindow, from: nil).x
            zoom(to: scale * exp(dy / 100), anchorX: x, animated: false)
            return
        }
        if isPlaying { followsPlayhead = false }
        if abs(dx) >= abs(dy) {
            offset -= dx
        } else if rowsHeight > rowsAreaHeight || event.hasPreciseScrollingDeltas {
            verticalOffset -= dy
        } else {
            // A mouse's wheel, with the rows in sight: sideways.
            offset -= dy
        }
        layoutContent()
    }

    override func magnify(with event: NSEvent) {
        guard content != nil else { return }
        stopAnimations()
        let x = convert(event.locationInWindow, from: nil).x
        zoom(to: scale * (1 + event.magnification), anchorX: x, animated: false)
    }

    private func stopAnimations() {
        zoomAnimation = nil
        scrollAnimation = nil
        updateDisplayLink()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interaction.mouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        interaction.mouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        interaction.mouseUp(event)
    }

    override func mouseMoved(with event: NSEvent) {
        interaction.mouseMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        interaction.mouseExited()
    }

    override func cursorUpdate(with event: NSEvent) {
        interaction.mouseMoved(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        interaction.menu(for: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The playhead moves to the output time at `x` (from the view's left edge), as a click or a drag on the ruler does.
    func scrub(at x: Double) {
        scrubbing = true
        scrub(toX: x)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        onScrubEnd()
    }

    func scrub(toX x: Double) {
        guard let content else { return }
        let τ = content.layout.output(atX: x, scale: scale, offset: offset)
        onScrub(min(max(τ, 0), content.map.duration))
    }

    /// The scale changes to `scale` (clamped to its range) around the playhead, following the slider 1:1.
    func setScale(_ scale: Double) {
        stopAnimations()
        zoom(to: scale, anchorX: anchorX(), animated: false)
    }

    /// The range of scales, from the whole sequence in the width to 600 pt per second.
    var scaleRange: ClosedRange<Double> {
        TimelineLayout.fitScale(duration: durationSeconds, width: areaWidth)...TimelineLayout.maxPointsPerSecond
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if content != nil, modifiers == .command || modifiers == [.command, .shift], let key = event.charactersIgnoringModifiers {
            switch key {
            case "+", "=":
                zoomIn()
                return true
            case "-":
                zoomOut()
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if content != nil, modifiers == .shift, event.charactersIgnoringModifiers?.lowercased() == "z" {
            fitToWindow()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tracks.reset()
        ruler.reset()
        needsLayout = true
    }

    /// The colors again, for the appearance or Increase Contrast: the layers are made again with them.
    private func recolor() {
        palette = TimelinePalette.make(effectiveAppearance)
        tracks.reset()
        ruler.reset()
        needsDisplay = true
        needsLayout = true
    }

    // MARK: - Headers

    private func makeHeaders() {
        for header in headers { header.removeFromSuperview() }
        headers = (content?.layout.tracks.dropFirst() ?? []).map { row in
            let header = TrackHeaderView(track: row.track, take: shown?.take)
            header.onMute = { [weak self] muted in
                guard case let .audio(id) = row.track else { return }
                self?.onMute(id, muted)
            }
            headerRows.addSubview(header)
            return header
        }
        updateHeaders()
    }

    private func updateHeaders() {
        for header in headers {
            guard case let .audio(id) = header.track else { continue }
            header.setMuted(content?.audio[id]?.muted ?? false, enabled: canEdit)
        }
    }

    private func placeHeaders(_ geometry: TimelineGeometry) {
        for (header, row) in zip(headers, geometry.rows) {
            let frame = CGRect(x: 0, y: row.top - geometry.verticalOffset, width: headerRows.bounds.width, height: row.height)
            if header.frame != frame { header.frame = frame }
        }
        // The help over the hatching of the Video track.
        var help: CGRect?
        if let video = geometry.rows.first(where: { $0.track == .video }), !(content?.missing.isEmpty ?? true) {
            help = CGRect(
                x: TimelineLayout.headerWidth, y: TimelineLayout.rulerHeight + video.top - geometry.verticalOffset,
                width: geometry.areaWidth, height: video.height)
        }
        if help != helpRect {
            helpRect = help
            removeAllToolTips()
            if let help { addToolTip(help, owner: self, userData: nil) }
        }
    }

    nonisolated func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated {
            guard let content else { return "" }
            let τ = content.layout.output(atX: point.x, scale: scale, offset: offset)
            guard content.missing.contains(where: { $0.contains(τ) }) else { return "" }
            return String(localized: "This part of the recording couldn't be read: the frame before it is shown.")
        }
    }

    // MARK: - Benchmark

    #if DEBUG
    /// Shows `content` laid out at `scale` and `offset` now, for the benchmark.
    func benchLayout(scale: Double, offset: Double) {
        fitted = false
        self.scale = scale
        self.offset = offset
        layoutContent()
    }

    /// The layers in sight, for the benchmark.
    var benchLayerCount: Int { tracks.layerCount }
    #endif
}

/// The view whose layer holds the ruler, the tracks and the playhead: flipped, so its sublayers are placed from the top
/// left; it takes no events (the timeline does).
private final class TimelineAreaView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The header of a track (design §5.5): its icon and name, and on an audio track the Mute button.
private final class TrackHeaderView: NSView {
    let track: TimelineTrack
    var onMute: (Bool) -> Void = { _ in }
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var mute: NSButton?
    private let separator = CALayer()

    init(track: TimelineTrack, take: TakeRecord?) {
        self.track = track
        super.init(frame: .zero)
        wantsLayer = true
        let (title, symbol) = Self.titleAndSymbol(track, take: take)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        name.stringValue = title
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(name)
        if case .audio = track {
            let button = NSButton(
                image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)!, target: self,
                action: #selector(muteClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.alternateImage = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = String(localized: "Mute")
            button.setAccessibilityLabel(String(localized: "Mute"))
            addSubview(button)
            mute = button
        }
        layer?.addSublayer(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        separator.backgroundColor = NSColor.separatorColor.cgColor
    }

    func setMuted(_ muted: Bool, enabled: Bool) {
        mute?.state = muted ? .on : .off
        mute?.isEnabled = enabled
    }

    @objc private func muteClicked(_ sender: NSButton) {
        onMute(sender.state == .on)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // An audio track has its name on top and Mute under it; the others, the name in the middle.
        let line = mute == nil ? (height - 14) / 2 : 4
        icon.frame = CGRect(x: 8, y: line, width: 14, height: 14)
        name.frame = CGRect(x: 26, y: line, width: bounds.width - 30, height: 14)
        mute?.frame = CGRect(x: 24, y: line + 15, width: 18, height: 15)
        separator.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
    }

    private static func titleAndSymbol(_ track: TimelineTrack, take: TakeRecord?) -> (String, String) {
        switch track {
        case .ruler: ("", "ruler")
        case .video: (String(localized: "Video"), "film")
        case .screen: (String(localized: "Screen"), "display")
        case .zoom: (String(localized: "Zoom"), "plus.magnifyingglass")
        case .camera: (String(localized: "Camera"), "web.camera")
        case let .audio(id):
            take?.track(id)?.kind == .systemAudio
                ? (String(localized: "System"), "speaker.wave.2")
                : (String(localized: "Microphone"), "mic")
        }
    }
}

// MARK: - The controller

/// The timeline's part of the editor's window: it follows the model (the document shown, the playhead, the spans that
/// could not be read) and makes the project's thumbnail and waveform caches, which work off the main thread.
@MainActor
final class TimelineViewController: NSViewController {
    private let model: EditorModel
    private let timeline = EditorTimelineView()
    private let bar = TimelineBar()
    /// The package and the take the caches read, and the work of the waveforms.
    private var cachesFor: (url: URL, take: TakeRecord)?
    private var waveformWork: [Task<Void, Never>] = []
    private var stopped = false

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The window closed: nothing goes on drawing or working out waveforms.
    func stop() {
        stopped = true
        for work in waveformWork { work.cancel() }
        waveformWork = []
        timeline.stop()
    }

    override func loadView() {
        view = TimelineContainer(bar: bar, timeline: timeline)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        timeline.playbackTime = { [weak model] in TimeMap.outputNanoseconds(seconds: model?.playbackSeconds() ?? 0) }
        timeline.onScrub = { [weak model] τ in model?.scrub(toSeconds: Double(τ) / 1e9) }
        timeline.onScrubEnd = { [weak model] in model?.endScrub() }
        timeline.onMute = { [weak self] track, muted in self?.setMuted(track, muted) }
        timeline.interaction.model = model
        wireBar()
        followContent()
        followBar()
        followPlayhead()
    }

    /// The bar's controls do what the timeline's menus do, and follow its scale and its snapping.
    private func wireBar() {
        bar.onSplit = { [weak model] in model?.splitAtPlayhead() }
        bar.onSpeed = { [weak model] in model?.setSpeed($0) }
        bar.onCustomSpeed = { [weak timeline] in timeline?.interaction.askCustomSpeed() }
        bar.onAddZoom = { [weak model] in model?.addZoom() }
        bar.onSnapping = { [weak timeline] in timeline?.snapping = $0 }
        bar.onScale = { [weak timeline] in timeline?.setScale($0) }
        bar.onZoomIn = { [weak timeline] in timeline?.zoomIn() }
        bar.onZoomOut = { [weak timeline] in timeline?.zoomOut() }
        bar.onFit = { [weak timeline] in timeline?.fitToWindow() }
        timeline.onSnappingChange = { [weak self] in self.map { $0.bar.setSnapping($0.timeline.snapping) } }
        timeline.onScaleChange = { [weak self] in
            guard let self else { return }
            bar.setScale(timeline.scale, fit: timeline.scaleRange.lowerBound)
        }
    }

    /// The document, the spans that could not be read and whether it can be edited, as the model has them now and each
    /// time they change.
    private func followContent() {
        guard !stopped else { return }
        withObservationTracking {
            showContent()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followContent() }
        }
    }

    /// What the bar enables and shows: whether the document can be edited, and the speed of what the menu applies to.
    private func followBar() {
        guard !stopped else { return }
        withObservationTracking {
            bar.setEnabled(model.canEdit, hasClip: !model.speedTargets.isEmpty)
            bar.setSpeed(model.speedOfTargets)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followBar() }
        }
    }

    private func followPlayhead() {
        guard !stopped else { return }
        withObservationTracking {
            // The document too: the playhead's time depends on its frame rate.
            _ = model.document
            timeline.isPlaying = model.isPlaying
            timeline.playhead = model.playheadNanoseconds
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayhead() }
        }
    }

    private func showContent() {
        let missing = model.missingVideo
        timeline.canEdit = model.canEdit
        timeline.marks = model.timelineMarks
        timeline.selected = Self.selectedIDs(model.selection)
        guard model.state == .ready, let document = model.document, let project = model.overlayProject else {
            timeline.showNothing()
            return
        }
        if cachesFor?.url != project.package.url || cachesFor?.take != project.take, let caches = model.panelSession?.caches {
            cachesFor = (project.package.url, project.take)
            makeCaches(project, caches)
        }
        timeline.show(take: project.take, events: project.events, document: document, missing: missing)
    }

    /// The thumbnails' cache, and the waveform of each audio track worked out off the main thread (decoded by the cache on
    /// its queue, its levels in a task of their own).
    private func makeCaches(_ project: LoadedProject, _ caches: ProjectCaches) {
        timeline.tracks.forgetThumbnails()
        timeline.tracks.thumbnailCache = ThumbnailCache(project: project, caches: caches)
        for work in waveformWork { work.cancel() }
        timeline.tracks.waveformLevels = [:]
        let waveforms = WaveformCache(project: project, caches: caches)
        waveformWork = project.take.tracks.filter { !$0.kind.isVideo && !$0.segments.isEmpty }.map { track in
            Task { [weak self] in
                let waveform = await waveforms.waveform(track: track.id)
                let levels = await Task.detached(priority: .utility) { WaveformLevels(waveform) }.value
                guard !Task.isCancelled else { return }
                self?.timeline.setWaveform(levels, for: track.id)
            }
        }
    }

    private static func selectedIDs(_ selection: EditorSelection?) -> Set<String> {
        switch selection {
        case let .clips(ids)?, let .zooms(ids)?: ids
        case let .cameraChange(id)?, let .screenChange(id)?: [id]
        case nil: []
        }
    }

    private func setMuted(_ track: String, _ muted: Bool) {
        guard let take = model.overlayProject?.take, let record = take.track(track) else { return }
        model.setTrackMuted(
            AudioTrackRow(take: take.id, track: track, isMicrophone: record.kind == .microphone, deviceName: record.source.name),
            muted)
    }
}

#if DEBUG
// MARK: - Benchmark

/// `TOMA_BENCH_TIMELINE=1 Toma -TomaDumpEditorStructure <package>` (Debug): instead of describing the editor, measures
/// the timeline (design §7.9: an hour with 500 clips and 300 zooms scrolls and scales at the display's rate) and quits.
/// A timeline as wide as a 1440 pt window shows a take of an hour made up here (a screen, a camera, a microphone and the
/// system audio; 500 clips, a tenth of them at 2× and some at 0,5×; 300 zoom blocks, half automatic; 100 camera
/// changes; 40 markers; two spans hatched), and each frame is laid out and committed to the render server
/// (`CATransaction.flush()`) on the main thread: the time each frame takes there is what is printed, for five motions.
/// With `TOMA_BENCH_TIMELINE_SNAPSHOTS=<folder>`, it also writes there a PNG of the editor's own timeline (the package's
/// take) and of the hour's at four scales.
@MainActor
enum TimelineBench {
    static var isAsked: Bool { ProcessInfo.processInfo.environment["TOMA_BENCH_TIMELINE"] == "1" }

    /// `editor`: the timeline of the editor's window.
    static func run(editor: NSView) {
        let snapshots = ProcessInfo.processInfo.environment["TOMA_BENCH_TIMELINE_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        print("editor timeline: \(Int(editor.frame.width)) × \(Int(editor.frame.height)) pt")
        if let snapshots, let editor = editor.subviews.compactMap({ $0 as? EditorTimelineView }).first ?? editor as? EditorTimelineView {
            snapshot(editor, to: snapshots.appending(path: "timeline-editor.png"))
        }
        let (project, document) = makeProject()
        let view = EditorTimelineView(frame: NSRect(x: 0, y: 0, width: 1440, height: 236))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        let caches = ProjectCaches(root: FileManager.default.temporaryDirectory.appending(path: "toma-timeline-bench"), projectID: "bench")
        view.tracks.thumbnailCache = ThumbnailCache(project: project, caches: caches)
        view.show(take: project.take, events: project.events, document: document, missing: [600...630, 1800...1802])
        for id in ["mic", "system-audio"] { view.setWaveform(WaveformLevels(syntheticWaveform()), for: id) }
        view.playhead = 1_234_000_000_000
        view.layoutSubtreeIfNeeded()

        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let width = 1440 - TimelineLayout.headerWidth, duration = Double(TimeMap(sequence: document.sequence).duration) / 1e9
        let fit = TimelineLayout.fitScale(duration: duration, width: width)
        print("timeline bench: \(document.sequence.count) clips, \(document.zoom.regions.count) zooms, "
            + "\(String(format: "%.0f", duration)) s of output in \(Int(width)) pt (fitted: \(String(format: "%.3f", fit)) pt/s); "
            + "load \(String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]))")

        func centered(_ scale: Double) -> (Double, Double) { (scale, duration / 2 * scale - width / 2) }
        let frames = 600
        measure(view, "fitted, everything in sight, scale changing", (0..<frames).map { i in (fit * (1 + Double(i % 2) * 0.001), 0) })
        measure(view, "pinch from fitted to 600 pt/s and back", (0..<frames).map { i in
            let t = 1 - abs(Double(i) / Double(frames / 2) - 1)
            return centered(fit * pow(TimelineLayout.maxPointsPerSecond / fit, t))
        })
        for scale in [fit * 10, 60, 600] {
            measure(view, "scrolling at \(String(format: "%.1f", scale)) pt/s, 40 pt a frame", (0..<frames).map { i in
                (scale, Double(i) * 40)
            })
        }
        var times: [Double] = []
        view.benchLayout(scale: 60, offset: 70_000)
        for i in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            view.playhead = Int64(70_000 / 60 * 1e9) + Int64(i) * 16_666_667
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        report("the playhead alone, every frame", times, layers: view.benchLayerCount)
        paced(view, fit: fit, duration: duration, width: width)

        if let snapshots {
            for (name, scale, offset) in [("fitted", fit, 0.0), ("30", 30.0, 0.0), ("60", 60.0, 69_500.0), ("600", 600.0, 700_000.0)] {
                view.benchLayout(scale: scale, offset: offset)
                view.playhead = Int64((offset + 300) / scale * 1e9)
                CATransaction.flush()
                snapshot(view, to: snapshots.appending(path: "timeline-\(name).png"))
            }
        }
        fflush(stdout)
        exit(0)
    }

    private static func measure(_ view: EditorTimelineView, _ name: String, _ steps: [(Double, Double)]) {
        var times: [Double] = []
        var layers = 0
        for (scale, offset) in steps {
            let start = DispatchTime.now().uptimeNanoseconds
            view.benchLayout(scale: scale, offset: offset)
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            layers = max(layers, view.benchLayerCount)
        }
        report(name, times, layers: layers)
    }

    /// For 4 s, a pinch from fitted to 600 pt/s and back once a second, a step on each refresh of the display (the view's
    /// display link, as the timeline's own): how many refreshes there were and how many came later than one and a half
    /// periods after the one before.
    private static func paced(_ view: EditorTimelineView, fit: Double, duration: Double, width: Double) {
        var stamps: [CFTimeInterval] = []
        var period = 0.0
        let ticker = BenchTicker { link in
            stamps.append(link.timestamp)
            period = link.duration
            let t = Double(stamps.count % 120) / 60
            let scale = fit * pow(TimelineLayout.maxPointsPerSecond / fit, 1 - abs(t - 1))
            view.benchLayout(scale: scale, offset: duration / 2 * scale - width / 2)
        }
        let link = view.displayLink(target: ticker, selector: #selector(BenchTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))
        link.invalidate()
        guard stamps.count > 1, period > 0 else {
            print("  paced pinch: the display did not refresh (asleep?)")
            return
        }
        let late = zip(stamps.dropFirst(), stamps).filter { $0 - $1 > period * 1.5 }.count
        print("  paced pinch on the display link: \(stamps.count) refreshes in 4 s at \(String(format: "%.0f", 1 / period)) Hz, "
            + "\(late) more than 1.5 periods after the one before")
    }

    private static func report(_ name: String, _ times: [Double], layers: Int) {
        let sorted = times.sorted()
        func at(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
        print("  \(name): \(times.count) frames, p50 \(String(format: "%.2f", at(0.5))) ms, p95 \(String(format: "%.2f", at(0.95))) ms, "
            + "max \(String(format: "%.2f", sorted.last ?? 0)) ms, up to \(layers) layers of items")
    }

    private static func snapshot(_ view: EditorTimelineView, to url: URL) {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer,
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        // The layers are drawn top down, as the window shows them.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// A take of an hour from host 1 s, and its document: 500 clips of 7 s with 0.2 s cut between them, 300 zooms, 100
    /// camera changes and 40 markers.
    private static func makeProject() -> (LoadedProject, EditDocument) {
        let second: UInt64 = 1_000_000_000
        func at(_ seconds: Double) -> HostTime { HostTime(nanoseconds: second + UInt64(seconds * 1e9)) }
        func track(_ id: String, _ kind: TrackKind, frame: Rect? = nil) -> TrackRecord {
            TrackRecord(
                id: id, kind: kind, source: TrackSource(name: id == "display-1" ? "Built-in Display" : id, globalFrame: frame),
                segments: [SegmentRecord(
                    index: 1, file: "takes/take-001/\(id)/seg-0001.mov", startHostTime: at(0), endHostTime: at(3600),
                    endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])
        }
        let take = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(), tracks: [
                track("display-1", .display, frame: Rect(x: 0, y: 0, width: 1728, height: 1117)), track("camera", .camera),
                track("mic", .microphone), track("system-audio", .systemAudio),
            ])
        let events = (0..<40).map { InputEvent(t: at(Double($0) * 90 + 45), kind: .marker) }
        var document = EditDocument.legacy(take: take, events: events)
        func id(_ prefix: String, _ n: Int) -> String { prefix + String(format: "%08x", n) }
        document.sequence = (0..<500).map { i in
            let speed: Double = i % 10 == 3 ? 2 : (i % 25 == 7 ? 0.5 : 1)
            return Clip(id: id("c-", i), take: take.id, start: at(Double(i) * 7.2), end: at(Double(i) * 7.2 + 7), speed: speed)
        }
        document.zoom.regions = (0..<300).map { (j: Int) -> ZoomRegion in
            let start: Double = Double(j) * 12 + 2
            let depth: Double? = j % 3 == 0 ? nil : 1.5 + Double(j % 5) * 0.25
            let origin: Origin = j % 2 == 0 ? .auto : .user
            return ZoomRegion(
                id: id("z-", j), take: take.id, start: at(start), end: at(start + 3), origin: origin, depth: depth, focus: .follow,
                instant: false)
        }
        document.camera.changes = (0..<100).map { k in
            CameraChange(id: id("k-", k), take: take.id, t: at(Double(k) * 36 + 10), style: .default, origin: .user)
        }
        let package = ProjectPackage(url: FileManager.default.temporaryDirectory.appending(path: "toma-timeline-bench.toma"))
        let manifest = Manifest(formatVersion: 3, app: AppInfo(name: "Toma", version: "bench"), createdAt: Date(), takes: [take])
        return (LoadedProject(package: package, manifest: manifest, take: take, events: events), document)
    }

    /// The target of the paced run's display link.
    private final class BenchTicker: NSObject {
        let body: (CADisplayLink) -> Void
        init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
        @objc func tick(_ link: CADisplayLink) { body(link) }
    }

    /// An hour of a waveform that rises and falls.
    private static func syntheticWaveform() -> Waveform {
        Waveform(pairs: (0..<(3600 * Waveform.pairsPerSecond)).map { k in
            let level = Float(0.2 + 0.7 * abs(sin(Double(k) / 37)))
            return SIMD2(-level, level * 0.9)
        })
    }
}
#endif
