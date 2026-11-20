// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore
import Render

/// The rect of the privacy block selected, over the preview (phase 2 design §7.1, plan 2c decision 5): with one block
/// selected and the playhead in it, paused, its rect where the frame at the playhead draws it (`RenderFrame.drawnScreen`
/// of the scene shown), through the zoom, the card and the reframe, with 8 handles. The body moves it, a corner or an edge
/// changes its size; the drag follows the pointer 1:1, snaps its moving edges (or, moving it, its edges and its centre) to
/// the drawn screen's edges and centre (⌘ held, not), and is one gesture of the model: the preview shows the blur
/// following it, and letting go makes one step, `privacy.change` (`PrivacyCommands.setRect` at the playhead's source
/// instant: a block with keys moves all of them).
///
/// A subview of `PreviewOverlayView`, over all of it, in its points; the overlay asks it first what is under the pointer.
/// Core Animation layers, so the handles grow under the pointer with `Motion.hover`, show they are pressed on mouse-down
/// and pop in with `Motion.selector` (a fade with Reduce Motion).
final class PrivacyRectEditorView: NSView {
    private let model: EditorModel

    /// What is shown, as of the last `refresh`, or as the drag has it.
    private struct Shown: Equatable {
        var id: String
        /// In fractions of the screen's content, at `source`.
        var rect: NormalizedRect
        /// The playhead's source instant, whose rect it is.
        var source: HostTime
        /// The screen as the frame at the playhead draws it: its rect in output pixels and its crop, and the content shown
        /// then (the Area in Area mode), all as `PrivacyRectHandles` takes them.
        var drawn: Rect
        var layerCrop: Rect
        var contentCrop: Rect
        var outputSize: SIMD2<Double>
    }
    private var shown: Shown?

    private struct Drag {
        var part: PrivacyRectHandles.Part
        /// Where the pointer went down, in view points.
        var start: SIMD2<Double>
        var from: Shown
        var document: EditDocument
    }
    private var drag: Drag?
    /// The part under the pointer: its handle is larger.
    private var hovered: PrivacyRectHandles.Part?
    private var guides: (x: Double?, y: Double?) = (nil, nil)
    /// The stage's points of the document shown, kept while it is the same document and take.
    private var stagePoints: (document: EditDocument, take: String, points: StagePoints)?
    private var trackingArea: NSTrackingArea?

    private let container = CALayer()
    private let outline = CAShapeLayer()
    private let guideLines = CAShapeLayer()
    /// The corners (0 top left, 1 top right, 2 bottom left, 3 bottom right), then the edges (0 top, 1 right, 2 bottom,
    /// 3 left), as `PrivacyRectHandles.Part` numbers them.
    private let handles: [CALayer] = (0..<8).map { _ in CALayer() }

    private static let handleSide = 8.0
    private static let hoveredHandleSide = 11.0
    /// How near an edge or the centre of the drawn screen a dragged edge snaps, in points.
    private static let snapDistance = 6.0

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        container.opacity = 0
        layer?.addSublayer(container)
        guideLines.fillColor = nil
        guideLines.lineWidth = 1
        container.addSublayer(guideLines)
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.55
        outline.shadowRadius = 2
        outline.shadowOffset = .zero
        container.addSublayer(outline)
        for handle in handles {
            handle.cornerRadius = 2
            handle.borderWidth = 0.5
            handle.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
            handle.shadowColor = NSColor.black.cgColor
            handle.shadowOpacity = 0.4
            handle.shadowRadius = 2
            handle.shadowOffset = .zero
            container.addSublayer(handle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    // MARK: - What is shown

    /// Reads the model (so the overlay updates with it) and shows the selected block's rect at the playhead, if there is
    /// one to show; not while it plays, nor while the project cannot be edited. A drag keeps what it shows.
    func refresh() {
        let document = model.document, selection = model.selection, playing = model.isPlaying, editable = model.canEdit
        let scene = model.shownScene, now = model.playheadNanoseconds
        if let superview, frame != superview.bounds { frame = superview.bounds }
        guard drag == nil else { return }
        var next: Shown?
        if let document, let scene, editable, !playing, case let .privacyBlocks(ids)? = selection, ids.count == 1, let id = ids.first {
            next = makeShown(id: id, document: document, scene: scene, atOutput: now)
        }
        let appearing = next != nil && next?.id != shown?.id
        let leaving = next == nil && shown != nil
        shown = next
        if next == nil { hovered = nil }
        place(appearing: appearing, leaving: leaving)
        window?.invalidateCursorRects(for: self)
    }

    /// Block `id`'s rect at output instant `now`, from the frame the scene draws there; `nil` if the playhead is not in it.
    private func makeShown(id: String, document: EditDocument, scene: FrameEvaluator, atOutput now: Int64) -> Shown? {
        guard let block = document.privacy.blocks.first(where: { $0.id == id }) else { return nil }
        let map = TimeMap(sequence: document.sequence)
        guard let (clip, source) = map.source(atOutput: now), document.sequence.indices.contains(clip),
            document.sequence[clip].take == block.take, block.start <= source, source < block.end
        else { return nil }
        let frame = scene.frame(at: Double(now) / 1e9) { _ in true }
        guard let drawn = frame.drawnScreen, drawn.rect.width > 0, drawn.rect.height > 0, frame.outputSize.x > 0, frame.outputSize.y > 0
        else { return nil }
        // The content of the screen drawn, as the render places the regions (`PrivacyScene.apply`).
        let content = points(of: document)?.shownScreen(at: source).flatMap { $0.track == drawn.trackID ? $0.view.crop : nil }
            ?? drawn.crop
        return Shown(
            id: id, rect: PrivacyGeometry.clamped(PrivacyGeometry.rect(of: block, atSource: source)), source: source,
            drawn: drawn.rect, layerCrop: drawn.crop, contentCrop: content,
            outputSize: SIMD2(Double(frame.outputSize.x), Double(frame.outputSize.y)))
    }

    private func points(of document: EditDocument) -> StagePoints? {
        // Of the take of the clip at the playhead, the block's (`makeShown`).
        guard let take = model.playheadProject?.take else { return nil }
        if stagePoints?.document != document || stagePoints?.take != take.id, let screens = model.screensByTake[take.id] {
            let ratio = model.contentRatio(of: document)
            stagePoints = (
                document, take.id, StagePoints(take: take, document: document, screens: screens, contentRatio: .some(ratio)))
        }
        return stagePoints?.take == take.id ? stagePoints?.points : nil
    }

    // MARK: - Geometry

    private var viewSize: SIMD2<Double> { SIMD2(Double(bounds.width), Double(bounds.height)) }

    private func viewRect(_ rect: NormalizedRect, _ shown: Shown) -> Rect {
        PrivacyRectHandles.viewRect(
            rect, drawnScreen: shown.drawn, layerCrop: shown.layerCrop, contentCrop: shown.contentCrop, outputSize: shown.outputSize,
            viewSize: viewSize)
    }

    /// The shown rect in the view, if it can be placed.
    private var shownViewRect: Rect? {
        guard let shown, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = viewRect(shown.rect, shown)
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }

    /// The screen as it is drawn, in the view: what a drag snaps to.
    private func screenInView(_ shown: Shown) -> Rect {
        let scale = viewSize / shown.outputSize
        return Rect(
            x: shown.drawn.x * scale.x, y: shown.drawn.y * scale.y, width: shown.drawn.width * scale.x,
            height: shown.drawn.height * scale.y)
    }

    private func point(_ event: NSEvent) -> SIMD2<Double> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(point.x), Double(point.y))
    }

    private func part(at point: SIMD2<Double>) -> PrivacyRectHandles.Part? {
        guard let rect = shownViewRect else { return nil }
        return PrivacyRectHandles.part(at: point, in: rect)
    }

    // MARK: - Drawing

    /// Where the handle of each part is: the corners, then the middles of the edges.
    private static func handleCenters(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private static func part(ofHandle k: Int) -> PrivacyRectHandles.Part {
        k < 4 ? .corner(k) : .edge(k - 4)
    }

    /// Lays the layers out for what is shown now, without actions; a rect coming into sight pops in, one leaving fades.
    private func place(appearing: Bool = false, leaving: Bool = false) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.frame = bounds
        for layer in [container, outline, guideLines] + handles where layer.contentsScale != scale { layer.contentsScale = scale }
        guard let rect = shownViewRect else {
            if leaving { fade(container, to: 0, reduceMotion: reduceMotion) } else { container.opacity = 0 }
            return
        }
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let accent = NSColor.controlAccentColor.cgColor
        let pressed = drag?.part
        outline.path = CGPath(rect: r, transform: nil)
        outline.shadowPath = outline.path?.copy(strokingWithWidth: 3, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
        outline.strokeColor = pressed == .body ? accent : NSColor.white.cgColor
        outline.lineWidth = pressed == .body ? 2 : 1.5
        // The edges' handles only where the side leaves room for them between the corners.
        let roomX = r.width >= 4 * Self.handleSide, roomY = r.height >= 4 * Self.handleSide
        for (k, (handle, center)) in zip(handles, Self.handleCenters(r)).enumerated() {
            let part = Self.part(ofHandle: k)
            handle.isHidden = (k == 4 || k == 6) && !roomX || (k == 5 || k == 7) && !roomY
            let side = hovered == part || pressed == part ? Self.hoveredHandleSide : Self.handleSide
            let from = handle.presentation()?.bounds ?? handle.bounds
            handle.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            handle.position = center
            handle.backgroundColor = pressed == part ? accent : NSColor.white.cgColor
            if drag == nil, !appearing, !reduceMotion, from.size != handle.bounds.size {
                let grow = CASpringAnimation(keyPath: "bounds", spring: Motion.hover)
                grow.fromValue = NSValue(rect: from)
                grow.toValue = NSValue(rect: handle.bounds)
                handle.add(grow, forKey: "hover")
            }
        }
        placeGuides()
        if appearing || container.opacity == 0 {
            container.opacity = 1
            fade(container, from: 0, to: 1, reduceMotion: reduceMotion)
            guard !reduceMotion else { return }
            for handle in handles {
                let pop = CASpringAnimation(keyPath: "transform.scale", spring: Motion.selector)
                pop.fromValue = 0.4
                pop.toValue = 1
                handle.add(pop, forKey: "pop")
            }
        }
    }

    /// The lines of the drawn screen a drag snapped to, across the view, in the accent color.
    private func placeGuides() {
        guard drag != nil, let shown, guides.x != nil || guides.y != nil else {
            guideLines.path = nil
            return
        }
        let screen = screenInView(shown)
        let visible = CGRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height).intersection(bounds)
        let path = CGMutablePath()
        if let x = guides.x {
            path.move(to: CGPoint(x: x, y: visible.minY))
            path.addLine(to: CGPoint(x: x, y: visible.maxY))
        }
        if let y = guides.y {
            path.move(to: CGPoint(x: visible.minX, y: y))
            path.addLine(to: CGPoint(x: visible.maxX, y: y))
        }
        guideLines.strokeColor = NSColor.controlAccentColor.cgColor
        guideLines.lineDashPattern = [4, 3]
        guideLines.path = path
    }

    private func fade(_ layer: CALayer, from: Float? = nil, to: Float, reduceMotion: Bool) {
        let start = from ?? layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = to
        let animation: CABasicAnimation
        if reduceMotion {
            animation = CABasicAnimation(keyPath: "opacity")
            animation.duration = Motion.reducedMotionFade.timeInterval
        } else {
            animation = CASpringAnimation(keyPath: "opacity", spring: Motion.hover)
        }
        animation.fromValue = start
        animation.toValue = to
        layer.add(animation, forKey: "fade")
    }

    // MARK: - Hits

    /// Itself on the rect's parts (and all along a drag), nothing elsewhere: the overlay's own items are under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if drag != nil { return self }
        return part(at: SIMD2(Double(local.x), Double(local.y))) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The places of the parts, none over another: the corners, the edges between them and the body inside.
    override func resetCursorRects() {
        guard let rect = shownViewRect, model.canEdit else { return }
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let out = PrivacyRectHandles.hitSize / 2
        let inX = min(out, r.width / 4), inY = min(out, r.height / 4)
        let xs = [(r.minX - out, r.minX + inX), (r.minX + inX, r.maxX - inX), (r.maxX - inX, r.maxX + out)]
        let ys = [(r.minY - out, r.minY + inY), (r.minY + inY, r.maxY - inY), (r.maxY - inY, r.maxY + out)]
        let positions: [[NSCursor.FrameResizePosition?]] = [[.topLeft, .top, .topRight], [.left, nil, .right], [.bottomLeft, .bottom, .bottomRight]]
        for (row, y) in ys.enumerated() {
            for (column, x) in xs.enumerated() where x.1 > x.0 && y.1 > y.0 {
                let place = CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
                let cursor = positions[row][column].map { NSCursor.frameResize(position: $0, directions: .all) } ?? .openHand
                addCursorRect(place, cursor: cursor)
            }
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let point = point(event)
        guard let shown, model.canEdit, !model.isGesturing, let document = model.document, let part = part(at: point) else { return }
        model.beginGesture()
        guard model.isGesturing else { return }
        drag = Drag(part: part, start: point, from: shown, document: document)
        guides = (nil, nil)
        if part == .body { NSCursor.closedHand.set() }
        place()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let from = drag.from
        let delta = point(event) - drag.start
        func contentDelta(_ d: SIMD2<Double>) -> SIMD2<Double> {
            PrivacyRectHandles.contentDelta(
                d, drawnScreen: from.drawn, layerCrop: from.layerCrop, contentCrop: from.contentCrop, outputSize: from.outputSize,
                viewSize: viewSize)
        }
        var rect = PrivacyRectHandles.dragged(from.rect, part: drag.part, by: contentDelta(delta))
        var snapped: (x: Double?, y: Double?) = (nil, nil)
        if !event.modifierFlags.contains(.command) {
            let snap = PrivacyRectHandles.snap(
                viewRect(rect, from), part: drag.part, to: screenInView(from), tolerance: Self.snapDistance)
            if snap.offset != .zero { rect = PrivacyRectHandles.dragged(from.rect, part: drag.part, by: contentDelta(delta + snap.offset)) }
            snapped = (snap.guideX, snap.guideY)
        }
        // A line that just snapped is felt.
        if snapped.x != nil && snapped.x != guides.x || snapped.y != nil && snapped.y != guides.y {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guides = snapped
        model.updateGesture(PrivacyCommands.setRect(drag.document, id: from.id, rect, atSource: from.source))
        var now = from
        now.rect = rect
        shown = now
        place()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        guides = (nil, nil)
        // One step, once let go.
        model.endGesture()
        hovered = part(at: point(event))
        place()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(drag == nil ? part(at: point(event)) : drag?.part)
    }

    override func mouseExited(with event: NSEvent) {
        if drag == nil { setHovered(nil) }
    }

    private func setHovered(_ part: PrivacyRectHandles.Part?) {
        guard part != hovered else { return }
        hovered = part
        place()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        place()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
        window?.invalidateCursorRects(for: self)
    }
}
