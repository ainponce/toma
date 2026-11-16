// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore
import SwiftUI

/// The overlays of the preview (design §5.3): an AppKit layer over the Metal view, never in the render. With one fixed
/// zoom selected, the box of what is seen inside it (its body moves the focus, its corners change the depth; in a split,
/// over the screen's card); with the camera on, its bubble, which is dragged and, once let go, thrown to the nearest of the
/// 8 places (the Bubble block's own style inside one, the take's outside the blocks); and, where a split rules, the handle
/// between its cards, which sets the camera's size (design §5.7). A drag is one gesture of the model (`beginGesture`): the
/// preview shows it without logging, and the end is one edit.
struct PreviewOverlay: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> PreviewOverlayView {
        PreviewOverlayView(model: model)
    }

    func updateNSView(_ view: PreviewOverlayView, context: Context) {
        view.refresh()
    }

    static func dismantleNSView(_ view: PreviewOverlayView, coordinator: ()) {
        view.stopDisplayLink()
    }
}

/// See `PreviewOverlay`. Flipped, in the preview's points; the stage is 1 tall, so one stage unit is `bounds.height`.
final class PreviewOverlayView: NSView {
    private let model: EditorModel

    /// What is shown, as of the last `refresh`.
    private struct ZoomBox {
        var id: String
        var focus: SIMD2<Double>
        var depth: Double
        var screen: Rect
        var stage: SIMD2<Double>
    }
    private var zoom: ZoomBox?
    private var bubbleStyle: CameraStyle?
    /// Whose style `bubbleStyle` is: the take's (1b) or a Bubble block's.
    private var bubbleTarget = LayoutTrackRules.BubbleTarget.none
    private var stagePoints: (document: EditDocument, points: StagePoints)?

    /// A drag of the box: where it started (stage units) and the box then.
    private struct BoxDrag {
        enum Part { case body, corner }
        var part: Part
        var start: SIMD2<Double>
        var box: Rect
        var zoom: ZoomBox
    }
    private var boxDrag: BoxDrag?

    /// A drag of the bubble, and the throw after it.
    private struct BubbleDrag {
        var grab: CGPoint
        var style: CameraStyle
        var target: LayoutTrackRules.BubbleTarget
        var samples: [CameraBubbleLayout.DragSample]
    }
    private var bubbleDrag: BubbleDrag?

    /// The split that rules at the playhead and what it is drawn from; `nil` where another layout rules.
    private struct SplitState {
        /// The block it belongs to; `nil` for the project's layout.
        var blockID: String?
        var split: SplitLayout
        /// The output the geometry is worked out in, in pixels: only its proportions count here.
        var output: SIMD2<Double>
        var padding: Double
        var cornerRadius: Double
        var screenAspect: Double?

        var orientation: SplitOrientation { CameraLayoutGeometry.orientation(output: output) }

        /// The cards, with `share` in place of the split's when it is given.
        func geometry(share: Double? = nil) -> LayoutGeometry {
            var split = split
            if let share { split.share = share }
            return CameraLayoutGeometry.geometry(
                kind: .split, split: split, bubble: nil, output: output, padding: padding, cornerRadius: cornerRadius,
                screenAspect: screenAspect)
        }
    }
    private var splitState: SplitState?
    /// A drag of the handle: the share the pointer says now.
    private var splitDrag: (share: Double?, step: EditStep?)?
    /// The pointer is over the handle (it shows then).
    private var overHandle = false
    private var trackingArea: NSTrackingArea?
    /// The bubble's shape while it is dragged and while it settles into its place: its top left, as springs.
    private var bubbleX = SpringValue(value: 0, spring: Motion.bubbleRelease)
    private var bubbleY = SpringValue(value: 0, spring: Motion.bubbleRelease)
    private var settling = false
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    private static let handle = 10.0

    // MARK: - What is shown

    /// Reads the model (so the view updates with it) and shows what it has now: the box of a selected fixed zoom, the
    /// bubble of the camera at the playhead. Nothing while it plays, nor while the project cannot be edited.
    func refresh() {
        let document = model.document, selection = model.selection, playing = model.isPlaying, editable = model.canEdit
        _ = model.playheadFrame
        let project = model.overlayProject, now = model.playheadNanoseconds
        guard boxDrag == nil, bubbleDrag == nil, splitDrag == nil else { return }
        zoom = nil
        splitState = nil
        if !settling {
            bubbleStyle = nil
            bubbleTarget = .none
        }
        defer {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        guard let document, let project, editable, !playing else { return }
        let stage = SIMD2(document.aspect.ratio, 1)
        let map = TimeMap(sequence: document.sequence)
        splitState = makeSplitState(of: document, project: project, atOutput: now, timeMap: map)
        if case let .zooms(ids)? = selection, ids.count == 1, let id = ids.first,
            let region = document.zoom.regions.first(where: { $0.id == id }), case let .fixed(x, y) = region.focus
        {
            // In a split, the screen is its card (design §5.7).
            let screen = splitState.map { SplitHandleGeometry.stageUnits($0.geometry().screen.rect, output: $0.output) }
                ?? points(of: document, project)?.screenRect(at: region.start) ?? Rect(x: 0, y: 0, width: stage.x, height: stage.y)
            zoom = ZoomBox(
                id: id, focus: SIMD2(x, y), depth: region.depth ?? document.zoom.auto.depth, screen: screen, stage: stage)
        }
        if !settling, let bubble = CameraBubble(document: document, take: project.take, timeMap: map),
            let (_, host) = map.source(atOutput: now), host >= bubble.start
        {
            // Inside a Bubble block, its own style; outside the blocks with the Bubble layout, the take's (1b); with another
            // layout, no bubble.
            let target = LayoutTrackRules.bubbleTarget(document, atOutput: now, timeMap: map)
            switch target {
            case .none:
                break
            case .take:
                bubbleStyle = TrackCommands.rulingCameraStyle(document, atOutput: now, timeMap: map).style
            case let .block(id):
                bubbleStyle = document.camera.layouts.first { $0.id == id }?.bubble?.style
            }
            bubbleTarget = bubbleStyle == nil ? .none : target
        }
    }

    /// The stage's points of `document`, kept while it is the same document.
    private func points(of document: EditDocument, _ project: LoadedProject) -> StagePoints? {
        if stagePoints?.document != document {
            stagePoints = (document, StagePoints(take: project.take, events: project.events, document: document))
        }
        return stagePoints?.points
    }

    /// The split that rules at output instant `now`, if one does: the block's or the project's, with the screen's aspect at
    /// the playhead. Documents without layouts (every one of 1b) have none.
    private func makeSplitState(of document: EditDocument, project: LoadedProject, atOutput now: Int64, timeMap: TimeMap) -> SplitState? {
        guard !document.camera.layouts.isEmpty || document.camera.layout.kind == .split else { return nil }
        let span = LayoutTimeline(document: document, take: project.take, timeMap: timeMap, cameraReadable: !model.cameraUnreadable)
            .span(atOutput: now)
        guard span.kind == .split else { return nil }
        let size = StageLayout.outputSize(aspect: document.aspect, shortSide: 1080)
        let screen = timeMap.source(atOutput: now).flatMap { points(of: document, project)?.screenRect(at: $0.1) }
        return SplitState(
            blockID: span.blockID, split: span.split ?? SplitLayout(side: .end), output: SIMD2(Double(size.x), Double(size.y)),
            padding: document.style.padding, cornerRadius: document.style.cornerRadius,
            screenAspect: screen.flatMap { $0.height > 0 ? $0.width / $0.height : nil })
    }

    // MARK: - Geometry

    private var unit: Double { bounds.height }

    private func viewRect(_ rect: Rect) -> CGRect {
        CGRect(x: rect.x * unit, y: rect.y * unit, width: rect.width * unit, height: rect.height * unit)
    }

    private func stagePoint(_ point: CGPoint) -> SIMD2<Double> {
        SIMD2(point.x / unit, point.y / unit)
    }

    private func box(of zoom: ZoomBox) -> Rect {
        ZoomBoxGeometry.box(focus: zoom.focus, depth: zoom.depth, screen: zoom.screen, stage: zoom.stage)
    }

    private var region: Rect { Rect(x: 0, y: 0, width: bounds.width, height: bounds.height) }

    private func bubbleFrame(_ style: CameraStyle) -> CameraFrame {
        style.frame(in: region)
    }

    /// The bubble's rect now: its resting place, or where the drag or the throw has it.
    private func bubbleRect(_ style: CameraStyle) -> CGRect {
        let frame = bubbleFrame(style)
        if bubbleDrag != nil || settling {
            return CGRect(x: bubbleX.value, y: bubbleY.value, width: frame.rect.width, height: frame.rect.height)
        }
        return CGRect(x: frame.rect.x, y: frame.rect.y, width: frame.rect.width, height: frame.rect.height)
    }

    private func corners(of rect: CGRect) -> [(part: Int, point: CGPoint)] {
        [(0, CGPoint(x: rect.minX, y: rect.minY)), (1, CGPoint(x: rect.maxX, y: rect.minY)),
            (2, CGPoint(x: rect.minX, y: rect.maxY)), (3, CGPoint(x: rect.maxX, y: rect.maxY))]
    }

    /// Where the split handle is, in the view: the gap between the cards, which the dragged share moves, and the rect it is
    /// pointed at (at least `SplitHandleGeometry.hitWidth` points across the split).
    private func handleRects(_ state: SplitState) -> (gap: CGRect, hit: CGRect) {
        let scale = bounds.height / state.output.y
        let handle = SplitHandleGeometry.handle(geometry: state.geometry(share: splitDrag?.share), orientation: state.orientation)
        func scaled(_ rect: Rect) -> CGRect {
            CGRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let hit = SplitHandleGeometry.hitRect(of: handle, orientation: state.orientation, pointsPerUnit: scale)
        return (scaled(handle), scaled(hit))
    }

    /// The point `point` of the view in the split's output pixels.
    private func outputPoint(_ point: CGPoint, _ state: SplitState) -> SIMD2<Double> {
        let scale = state.output.y / max(bounds.height, 1)
        return SIMD2(point.x * scale, point.y * scale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let zoom {
            var shown = zoom
            if let drag = boxDrag { shown = drag.zoom }
            drawBox(viewRect(box(of: shown)))
        }
        if let style = bubbleStyle { drawBubble(style) }
        if let splitState, overHandle || splitDrag != nil { drawHandle(splitState) }
    }

    /// A grip in the middle of the gap, and while it is dragged, the camera's share ("34 %") by it.
    private func drawHandle(_ state: SplitState) {
        let gap = handleRects(state).gap
        let beside = state.orientation == .beside
        let long = min(max((beside ? gap.height : gap.width) * 0.12, 28), 56)
        let grip = beside
            ? CGRect(x: gap.midX - 2, y: gap.midY - long / 2, width: 4, height: long)
            : CGRect(x: gap.midX - long / 2, y: gap.midY - 2, width: long, height: 4)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let share = splitDrag?.share else { return }
        let text = NSAttributedString(
            string: "\(SplitHandleGeometry.percent(share)) %",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
            ])
        let size = text.size()
        let box = CGRect(
            x: min(max(gap.midX - size.width / 2 - 7, 4), max(bounds.width - size.width - 18, 4)),
            y: max(grip.minY - size.height - 12, 4), width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    private func drawBox(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
        NSColor.white.setFill()
        for (_, point) in corners(of: rect) {
            NSBezierPath(
                roundedRect: CGRect(x: point.x - Self.handle / 2, y: point.y - Self.handle / 2, width: Self.handle, height: Self.handle),
                xRadius: 2, yRadius: 2
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBubble(_ style: CameraStyle) {
        let rect = bubbleRect(style)
        let radius = bubbleFrame(style).cornerRadius
        let lifted = bubbleDrag != nil || settling
        if lifted {
            // The 8 places, under the bubble.
            NSColor.white.withAlphaComponent(0.85).setFill()
            for place in CameraBubbleLayout.anchorFrames(style: style, region: region) {
                let center = CGPoint(x: place.rect.x + place.rect.width / 2, y: place.rect.y + place.rect.height / 2)
                let dot = place.anchor == style.anchor && !settling ? 8.0 : 6.0
                NSBezierPath(ovalIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if lifted {
            NSColor.white.withAlphaComponent(0.25).setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(lifted ? 0.95 : 0.55).setStroke()
        path.lineWidth = lifted ? 2 : 1
        if !lifted { path.setLineDash([4, 3], count: 2, phase: 0) }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Hits

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hit(at: local) == nil ? nil : self
    }

    private enum Hit {
        case corner
        case box
        case bubble
        case splitHandle
    }

    private func hit(at point: CGPoint) -> Hit? {
        if boxDrag != nil { return .box }
        if bubbleDrag != nil { return .bubble }
        if splitDrag != nil { return .splitHandle }
        if let state = splitState, handleRects(state).hit.contains(point) { return .splitHandle }
        if let style = bubbleStyle, bubbleRect(style).insetBy(dx: -4, dy: -4).contains(point) { return .bubble }
        if let zoom {
            let rect = viewRect(box(of: zoom))
            if corners(of: rect).contains(where: { hypot($0.point.x - point.x, $0.point.y - point.y) <= Self.handle }) { return .corner }
            if rect.contains(point) { return .box }
        }
        return nil
    }

    override func resetCursorRects() {
        if let state = splitState {
            addCursorRect(handleRects(state).hit, cursor: state.orientation == .beside ? .resizeLeftRight : .resizeUpDown)
        }
        if let style = bubbleStyle { addCursorRect(bubbleRect(style), cursor: .openHand) }
        if let zoom {
            let rect = viewRect(box(of: zoom))
            addCursorRect(rect, cursor: .openHand)
            for (_, point) in corners(of: rect) {
                addCursorRect(
                    CGRect(x: point.x - Self.handle, y: point.y - Self.handle, width: 2 * Self.handle, height: 2 * Self.handle),
                    cursor: .crosshair)
            }
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hit(at: point), model.canEdit else { return }
        switch hit {
        case .corner, .box:
            guard let zoom else { return }
            boxDrag = BoxDrag(part: hit == .corner ? .corner : .body, start: stagePoint(point), box: box(of: zoom), zoom: zoom)
            model.beginGesture { document in
                // The frame without zoom, which the box is drawn over.
                var shown = document
                shown.zoom.show = false
                return shown
            }
        case .splitHandle:
            guard let state = splitState else { return }
            if event.clickCount >= 2 {
                // Back to Automatic: one edit of its own.
                model.setSplitShare(percent: nil, id: state.blockID)
                return
            }
            splitDrag = (nil, nil)
            model.beginGesture()
        case .bubble:
            guard let style = bubbleStyle else { return }
            stopSettling()
            let rect = bubbleRect(style)
            bubbleX = SpringValue(value: rect.minX, spring: Motion.bubbleRelease)
            bubbleY = SpringValue(value: rect.minY, spring: Motion.bubbleRelease)
            bubbleDrag = BubbleDrag(
                grab: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY), style: style, target: bubbleTarget,
                samples: [.init(time: event.timestamp, point: rect.origin)])
            model.beginGesture { document in
                // The bubble is the overlay's while it is dragged.
                var shown = document
                shown.camera.show = false
                return shown
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var drag = boxDrag {
            let here = stagePoint(point)
            var shown = drag.zoom
            let step: EditStep?
            switch drag.part {
            case .body:
                let focus = ZoomBoxGeometry.focus(
                    afterDragging: drag.box, by: here - drag.start, screen: drag.zoom.screen, stage: drag.zoom.stage)
                shown.focus = focus
                step = model.document.flatMap { ZoomCommands.change($0, id: shown.id, focus: .fixed(x: focus.x, y: focus.y)) }
            case .corner:
                let depth = ZoomBoxGeometry.depth(
                    afterDraggingCorner: drag.box, to: here, screen: drag.zoom.screen, stage: drag.zoom.stage)
                shown.depth = depth
                step = model.document.flatMap { ZoomCommands.change($0, id: shown.id, depth: .some(depth)) }
            }
            drag.zoom = shown
            boxDrag = drag
            if let step { model.updateGesture(step) }
        } else if let state = splitState, splitDrag != nil {
            // The gap follows the pointer 1:1.
            let share = SplitHandleGeometry.share(
                pointer: outputPoint(point, state), output: state.output, padding: state.padding, orientation: state.orientation,
                side: state.split.side)
            let step = model.document.flatMap { LayoutCommands.setSplit($0, id: state.blockID, share: .some(share)) }
            splitDrag = (share, step)
            model.updateGesture(step)
        } else if var drag = bubbleDrag {
            // 1:1 with the pointer.
            let origin = CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y)
            bubbleX = SpringValue(value: origin.x, spring: Motion.bubbleRelease)
            bubbleY = SpringValue(value: origin.y, spring: Motion.bubbleRelease)
            drag.samples.append(.init(time: event.timestamp, point: origin))
            if drag.samples.count > 64 { drag.samples.removeFirst(drag.samples.count - 64) }
            bubbleDrag = drag
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if boxDrag != nil {
            boxDrag = nil
            model.endGesture()
        } else if splitDrag != nil {
            // One step, once let go.
            splitDrag = nil
            model.endGesture()
        } else if let drag = bubbleDrag {
            releaseBubble(drag, at: event.timestamp, point: convert(event.locationInWindow, from: nil))
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Let go: it goes where its throw ends, to the nearest of the 8 places, and the edit is that place.
    private func releaseBubble(_ drag: BubbleDrag, at time: Double, point: CGPoint) {
        bubbleDrag = nil
        var samples = drag.samples
        let origin = CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y)
        samples.append(.init(time: time, point: origin))
        let velocity = CameraBubbleLayout.releaseVelocity(samples: samples, at: time)
        var style = drag.style
        style.anchor = CameraBubbleLayout.releaseAnchor(origin: origin, velocity: velocity, style: style, region: region)
        let target = bubbleFrame(style).rect
        if let document = model.document {
            let map = TimeMap(sequence: document.sequence)
            let step: EditStep?
            if case let .block(id) = drag.target {
                step = LayoutCommands.setBubbleStyle(document, id: id, style)
            } else {
                step = TrackCommands.setCameraStyle(document, atOutput: model.playheadNanoseconds, timeMap: map, style)
            }
            if let step {
                model.updateGesture(step)
                model.endGesture()
            } else {
                model.cancelGesture()
            }
        } else {
            model.cancelGesture()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        bubbleStyle = style
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            bubbleX = SpringValue(value: target.x, spring: Motion.bubbleRelease)
            bubbleY = SpringValue(value: target.y, spring: Motion.bubbleRelease)
            return
        }
        // The throw: from where it was let go, at the speed it had.
        bubbleX = SpringValue(value: origin.x, spring: Motion.bubbleRelease)
        bubbleY = SpringValue(value: origin.y, spring: Motion.bubbleRelease)
        bubbleX.velocity = Double(velocity.dx)
        bubbleY.velocity = Double(velocity.dy)
        bubbleX.retarget(target.x, spring: Motion.bubbleRelease)
        bubbleY.retarget(target.y, spring: Motion.bubbleRelease)
        settling = true
        startDisplayLink()
    }

    // MARK: - The throw

    private func startDisplayLink() {
        stopDisplayLink()
        guard window != nil else {
            stopSettling()
            return
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = nil
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let seconds = lastTick.map { link.timestamp - $0 } ?? 0
        lastTick = link.timestamp
        bubbleX.step(by: min(seconds, 0.05))
        bubbleY.step(by: min(seconds, 0.05))
        if bubbleX.isSettled, bubbleY.isSettled { stopSettling() }
        needsDisplay = true
    }

    private func stopSettling() {
        guard settling || displayLink != nil else { return }
        settling = false
        stopDisplayLink()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setOverHandle(hit(at: convert(event.locationInWindow, from: nil)) == .splitHandle)
    }

    override func mouseExited(with event: NSEvent) {
        setOverHandle(false)
    }

    private func setOverHandle(_ over: Bool) {
        guard over != overHandle else { return }
        overHandle = over
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopDisplayLink() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}
