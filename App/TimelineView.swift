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

    let tracks = TimelineTracks()
    private(set) var content: TimelineContent?
    /// What `content` was made from.
    private var shown: (take: TakeRecord, document: EditDocument, missing: [ClosedRange<Double>])?

    // MARK: Scale and scroll

    private(set) var scale = TimelineLayout.maxPointsPerSecond
    private(set) var offset = 0.0
    private var verticalOffset = 0.0
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
    private let playheadLine = CALayer()
    private let playheadHead = CAShapeLayer()
    private let headerColumn = FlippedView()
    private let headerRows = FlippedView()
    private let headerSeparator = NSBox()
    private var headers: [TrackHeaderView] = []
    private var palette: TimelinePalette
    private var displayObserver: NSObjectProtocol?
    /// `stop()` was called: no display link is made again.
    private var isStopped = false
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
        isStopped = true
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
        if let shown, shown.take == take, shown.document == document, shown.missing == missing { return }
        let rows = content?.layout.tracks
        shown = (take, document, missing)
        let content = TimelineContent(take: take, events: events, document: document, missing: missing)
        self.content = content
        if content.layout.tracks != rows { makeHeaders() } else { updateHeaders() }
        needsLayout = true
    }

    func showNothing() {
        guard shown != nil else { return }
        shown = nil
        content = nil
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
        tracks.update(content!, geometry, palette)
        placeHeaders(geometry)
        placePlayhead(geometry)
    }

    private func geometry() -> TimelineGeometry? {
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

    /// ⇧Z: the whole sequence in the width, scaled around the instant that is at the same place now and fitted
    /// (`TimelineLayout.fitAnchor`), so it goes from this view to the fitted one without a jump.
    func fitToWindow() {
        guard let content else { return }
        let fit = TimelineLayout.fitScale(duration: durationSeconds, width: areaWidth)
        let anchor = TimelineLayout.fitAnchor(scale: scale, offset: offset, duration: durationSeconds, width: areaWidth)
        zoom(to: fit, anchorX: content.layout.x(ofOutput: anchor, scale: fit, offset: 0), animated: true, anchor: anchor)
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
        guard window != nil, !isStopped else { return }
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
        let point = convert(event.locationInWindow, from: nil)
        guard content != nil, point.x >= TimelineLayout.headerWidth, point.y < TimelineLayout.rulerHeight else { return }
        scrubbing = true
        scrub(at: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrubbing else { return }
        scrub(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard scrubbing else { return }
        scrubbing = false
        onScrubEnd()
    }

    private func scrub(at x: Double) {
        guard let content else { return }
        let τ = content.layout.output(atX: x, scale: scale, offset: offset)
        onScrub(min(max(τ, 0), content.map.duration))
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
