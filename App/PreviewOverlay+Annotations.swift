// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore
import Render
import simd

/// An annotation as a frame draws it, in the frame's output pixels (phase 3 plan 3a, Task A13): its layer, and how the
/// layer's coordinates go to the output's. One stuck to the recording is in the stage's coordinates and is drawn through
/// the zoom, or in a card through the card's content, as the screen is (`RenderFrame.drawnScreen`): a scale and a move,
/// the ones that take the screen's rect to where it is drawn. One of the output is in the output's pixels already.
struct DrawnAnnotation {
    var layer: AnnotationLayer
    /// Stuck to the recording.
    var stuck: Bool
    /// The layer's point `p` is drawn at `p × scale + offset`.
    var scale: Double
    var offset: SIMD2<Double>

    func output(_ p: SIMD2<Double>) -> SIMD2<Double> { p * scale + offset }

    func output(_ r: Rect) -> Rect {
        Rect(x: r.x * scale + offset.x, y: r.y * scale + offset.y, width: r.width * scale, height: r.height * scale)
    }

    /// Its box (`AnnotationLayer.rect`, unrotated) and its space, in output pixels.
    var box: Rect { output(layer.rect) }
    var space: Rect { output(layer.space) }

    /// The annotations `frame` draws, from the lowest to the topmost, as the compositor draws them: those stuck to the
    /// recording (none when the screen they are on cannot be placed), then those of the output.
    static func all(in frame: RenderFrame) -> [DrawnAnnotation] {
        var drawn: [DrawnAnnotation] = []
        if !frame.contentAnnotations.isEmpty, let screen = frame.screen, let shown = frame.drawnScreen, screen.rect.width > 0 {
            let scale = shown.rect.width / screen.rect.width
            let offset = SIMD2(shown.rect.x, shown.rect.y) - SIMD2(screen.rect.x, screen.rect.y) * scale
            if scale.isFinite, scale > 0, offset.x.isFinite, offset.y.isFinite {
                drawn += frame.contentAnnotations.map { DrawnAnnotation(layer: $0, stuck: true, scale: scale, offset: offset) }
            }
        }
        drawn += frame.outputAnnotations.map { DrawnAnnotation(layer: $0, stuck: false, scale: 1, offset: .zero) }
        return drawn
    }
}

/// The annotations over the preview (phase 3 design §5.1, plan 3a decisions 5, 6 and 16, Task A13). Paused, with the
/// frame at the playhead as the render draws it (`EditorModel.shownScene`, `DrawnAnnotation`): through the zoom, the card
/// and the reframe, so its handles sit on what is drawn.
///
/// - A click on an annotation the frame shows selects it, the topmost first (⇧ or ⌘ adds it or takes it out); the one
///   selected shows its outline and its handles (`AnnotationHandles`): a text's or a speech bubble's corners scale it and
///   its sides change its width, a shape's, an image's and a clip's corners and sides are free (⇧ keeps the proportion),
///   a step's corners keep it round, an arrow's ends and a bubble's point are dragged on their own. Several selected show
///   their outlines, and a drag of one moves them all.
/// - A drag follows the pointer 1:1 and is one gesture of the model: its body, its ends and its point snap to the centre
///   and the edges of its space (the content of the screen, or the output frame), with the guides shown (⌘ held, not);
///   letting go makes one step (`AnnotationCommands.place`, or `nudge` for several).
/// - A double click on a text or a speech bubble edits its text in place (`AnnotationTextEditor`): ⌘↩ or a click
///   elsewhere keeps it, as one step; Esc gives it up. The render draws the annotation hidden meanwhile (the gesture's
///   look), so it is not seen twice.
/// - An image or a clip dropped on the preview is imported and goes over the video, centred where it was dropped
///   (`EditorModel.addOverlay(from:at:)`), with "Importing «name»…" meanwhile and "Couldn't add the file." if it cannot.
///
/// A subview of `PreviewOverlayView`, over all of it, in its points, under the rect of a privacy block: the overlay asks
/// it what is under the pointer after the privacy rect and before its own items. Core Animation layers, so the handles
/// grow under the pointer with `Motion.hover` and pop in with `Motion.selector` (a fade with Reduce Motion).
final class AnnotationEditorView: NSView {
    private let model: EditorModel

    /// An annotation the frame at the playhead shows, in the view's points (y down).
    private struct Item {
        var id: String
        var behavior: AnnotationHandles.Behavior
        var anchor: AnnotationAnchor
        /// Its box, unrotated, and its turn about the box's centre (degrees clockwise; 0 for an arrow and a bubble).
        var box: Rect
        var rotation: Double
        /// What its geometry is fractions of: the content of the screen shown, or the output frame.
        var space: Rect
        /// An arrow's ends and a bubble's point.
        var points: [AnnotationHandles.Part: SIMD2<Double>]
        /// An arrow's curve as a line through it, and how near it a click takes it.
        var curve: [SIMD2<Double>]
        var reach: Double
        /// A bubble's tail: the ends of its base and its tip.
        var tail: [SIMD2<Double>]
        /// What a drag edits, in fractions of `space`: a text's and a bubble's box as tall as its text is drawn.
        var frame: AnnotationFrame
        /// Shown at more than nothing (one entering at 0 is not clicked, unless it is selected).
        var visible: Bool
        /// A text's or a bubble's text, edited by a double click.
        var text: TextAnnotation?
    }
    private var items: [Item] = []
    private var selected: Set<String> = []

    private struct Drag {
        var part: AnnotationHandles.Part
        /// Where the pointer went down, in view points.
        var start: SIMD2<Double>
        /// What is dragged, as it was then: one, or (by its body) every one selected the frame shows.
        var items: [Item]
        var document: EditDocument
        /// The gesture started: the pointer moved.
        var began = false
    }
    private var drag: Drag?
    private var hovered: (id: String, part: AnnotationHandles.Part)?
    private var guides: (x: Double?, y: Double?) = (nil, nil)
    /// The text being edited in place, and what notices a click elsewhere.
    private var editing: (id: String, editor: AnnotationTextEditor, monitor: Any?)?
    /// A file dropped on the preview, being imported.
    private var importing: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    private let container = CALayer()
    private let hoverOutline = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let guideLines = CAShapeLayer()
    /// The corners (0 top left, 1 top right, 2 bottom left, 3 bottom right), then the edges (0 top, 1 right, 2 bottom,
    /// 3 left), as `AnnotationHandles.Part` numbers them.
    private let squares: [CALayer] = (0..<8).map { _ in CALayer() }
    /// An arrow's `from` and `to`, and a bubble's `target`.
    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }
    private static let dotParts: [AnnotationHandles.Part] = [.from, .to, .target]
    private let dropOutline = CAShapeLayer()
    private let notice = CATextLayer()

    private static let handleSide = 8.0
    private static let hoveredHandleSide = 11.0
    private static let dotSide = 10.0
    private static let hoveredDotSide = 13.0
    /// The least distance, in points, a click on an arrow takes it from its curve.
    private static let arrowReach = 6.0

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        container.opacity = 0
        layer?.addSublayer(container)
        for line in [hoverOutline, outline, guideLines] {
            line.fillColor = nil
            container.addSublayer(line)
        }
        hoverOutline.lineWidth = 1
        hoverOutline.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        outline.lineWidth = 1.5
        outline.strokeColor = NSColor.white.cgColor
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.55
        outline.shadowRadius = 2
        outline.shadowOffset = .zero
        guideLines.lineWidth = 1
        for handle in squares + dots {
            handle.borderWidth = 0.5
            handle.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
            handle.shadowColor = NSColor.black.cgColor
            handle.shadowOpacity = 0.4
            handle.shadowRadius = 2
            handle.shadowOffset = .zero
            handle.isHidden = true
            container.addSublayer(handle)
        }
        for square in squares { square.cornerRadius = 2 }
        dropOutline.fillColor = nil
        dropOutline.lineWidth = 3
        dropOutline.isHidden = true
        layer?.addSublayer(dropOutline)
        notice.isHidden = true
        notice.alignmentMode = .center
        notice.cornerRadius = 6
        notice.fontSize = 12
        notice.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        notice.foregroundColor = NSColor.white.cgColor
        notice.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        notice.truncationMode = .middle
        layer?.addSublayer(notice)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    // MARK: - What is shown

    /// Reads the model (so the overlay updates with it) and shows the annotations of the frame at the playhead: not while
    /// it plays, nor while the project cannot be edited. A drag and a text being edited keep what they show.
    func refresh() {
        let document = model.document, selection = model.selection, playing = model.isPlaying, editable = model.canEdit
        let scene = model.shownScene, now = model.playheadNanoseconds
        if let superview, frame != superview.bounds { frame = superview.bounds }
        guard drag == nil, editing == nil else { return }
        let before = Set(items.filter { selected.contains($0.id) }.map(\.id))
        var next: [Item] = []
        if let document, let scene, editable, !playing, !document.annotations.items.isEmpty {
            next = makeItems(document: document, scene: scene, atOutput: now)
        }
        items = next
        if case let .annotations(ids)? = selection { selected = ids } else { selected = [] }
        if let hovered, !items.contains(where: { $0.id == hovered.id }) { self.hovered = nil }
        let shownNow = Set(items.filter { selected.contains($0.id) }.map(\.id))
        place(appearing: !shownNow.isEmpty && shownNow != before)
        window?.invalidateCursorRects(for: self)
    }

    /// The annotations the frame of `scene` at output instant `now` draws, from the lowest to the topmost.
    private func makeItems(document: EditDocument, scene: FrameEvaluator, atOutput now: Int64) -> [Item] {
        guard !AnnotationCommands.shown(atOutput: now, in: document).isEmpty else { return [] }
        let frame = scene.frame(at: Double(now) / 1e9) { _ in true }
        guard frame.outputSize.x > 0, frame.outputSize.y > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let k = SIMD2(Double(bounds.width) / Double(frame.outputSize.x), Double(bounds.height) / Double(frame.outputSize.y))
        func view(_ r: Rect) -> Rect { Rect(x: r.x * k.x, y: r.y * k.y, width: r.width * k.x, height: r.height * k.y) }
        let annotations = Dictionary(document.annotations.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DrawnAnnotation.all(in: frame).compactMap { drawn in
            let layer = drawn.layer
            guard let annotation = annotations[layer.id] else { return nil }
            let box = view(drawn.box), space = view(drawn.space)
            guard Self.isFinite(box), Self.isFinite(space), space.width > 0, space.height > 0 else { return nil }
            func point(_ p: SIMD2<Double>) -> SIMD2<Double> { drawn.output(p) * k }
            let measured = AnnotationGeometry.normalized(layer.rect, in: layer.space)
            let held = AnnotationGeometry.clamped(annotation.rect, anchor: annotation.anchor)
            var item = Item(
                id: layer.id, behavior: AnnotationHandles.behavior(of: annotation.kind), anchor: annotation.anchor, box: box,
                rotation: layer.rotation.isFinite ? layer.rotation : 0, space: space, points: [:], curve: [], reach: 0, tail: [],
                frame: AnnotationFrame(rect: held), visible: layer.opacity > 0, text: nil)
            switch layer.content {
            case let .text(text):
                // The box as tall as the text is drawn, as wide as the document has it.
                item.frame = AnnotationFrame(
                    rect: NormalizedRect(x: measured.x, y: measured.y, width: held.width, height: measured.height), size: text.size)
                item.text = text
            case let .callout(callout, tail):
                item.frame = AnnotationFrame(
                    rect: NormalizedRect(x: measured.x, y: measured.y, width: held.width, height: measured.height),
                    target: callout.target, size: callout.text.size)
                item.points[.target] = point(AnnotationGeometry.point(callout.target, in: layer.space))
                item.tail = tail.map { [point($0.baseStart), point($0.tip), point($0.baseEnd)] } ?? []
                item.text = callout.text
            case let .arrow(arrow, path):
                item.frame = AnnotationFrame(rect: measured, from: arrow.from, to: arrow.to)
                item.points[.from] = point(path.start)
                item.points[.to] = point(path.end)
                item.curve = (0...24).map { n in
                    let u = Double(n) / 24
                    let p = (1 - u) * (1 - u) * path.start + 2 * (1 - u) * u * path.control + u * u * path.end
                    return point(p)
                }
                let width = max(arrow.width, 0) * space.height
                item.reach = max(2.25 * width, Self.arrowReach)
            case .shape, .step, .image, .clip:
                break
            }
            return item
        }
    }

    private static func isFinite(_ r: Rect) -> Bool {
        [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite)
    }

    /// The one selected the frame shows, when only one is selected: the one with handles.
    private var handled: Item? {
        guard selected.count == 1, editing == nil else { return nil }
        return items.first { selected.contains($0.id) }
    }

    // MARK: - Geometry

    private static func rotated(_ v: SIMD2<Double>, degrees: Double) -> SIMD2<Double> {
        guard degrees != 0 else { return v }
        let a = degrees * .pi / 180
        return SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
    }

    private static func center(_ r: Rect) -> SIMD2<Double> {
        SIMD2(r.x + r.width / 2, r.y + r.height / 2)
    }

    /// Where the point `at` of `box` (fractions of it, from its top left) is drawn with the box turned `degrees`.
    private static func drawnPoint(_ at: SIMD2<Double>, of box: Rect, degrees: Double) -> SIMD2<Double> {
        let c = center(box)
        return c + rotated(SIMD2(box.x, box.y) + at * SIMD2(box.width, box.height) - c, degrees: degrees)
    }

    /// The four corners of `box` turned `degrees`, in the order of a path around it.
    private static func corners(of box: Rect, degrees: Double) -> [SIMD2<Double>] {
        [SIMD2(0.0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map { drawnPoint($0, of: box, degrees: degrees) }
    }

    /// Where each handle of a box is, as fractions of it: the corners, then the middles of the edges.
    private static let handleSpots: [SIMD2<Double>] = [
        SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(0.5, 0), SIMD2(1, 0.5), SIMD2(0.5, 1), SIMD2(0, 0.5),
    ]

    private static func part(ofSquare k: Int) -> AnnotationHandles.Part {
        k < 4 ? .corner(k) : .edge(k - 4)
    }

    /// Which of the 8 squares an annotation of `behavior` has.
    private static func hasSquare(_ k: Int, _ behavior: AnnotationHandles.Behavior) -> Bool {
        switch behavior {
        case .arrow: false
        case .step: k < 4
        case .text, .callout: k < 4 || k == 5 || k == 7
        case .free: true
        }
    }

    /// Whether `p` is on `item`: near an arrow's curve, in a bubble or its tail, in the box of the others (turned as it
    /// is drawn), a point of grace around each.
    private static func contains(_ item: Item, _ p: SIMD2<Double>) -> Bool {
        switch item.behavior {
        case .arrow:
            return zip(item.curve, item.curve.dropFirst()).contains { distance(p, segment: ($0, $1)) <= item.reach }
        case .callout:
            if item.tail.count == 3, inTriangle(p, item.tail) { return true }
            return inBox(p, item.box, degrees: 0, grace: 2)
        default:
            return inBox(p, item.box, degrees: item.rotation, grace: 2)
        }
    }

    private static func inBox(_ p: SIMD2<Double>, _ box: Rect, degrees: Double, grace: Double) -> Bool {
        let c = center(box)
        let local = c + rotated(p - c, degrees: -degrees)
        return local.x >= box.x - grace && local.x <= box.x + box.width + grace && local.y >= box.y - grace
            && local.y <= box.y + box.height + grace
    }

    private static func distance(_ p: SIMD2<Double>, segment: (SIMD2<Double>, SIMD2<Double>)) -> Double {
        let (a, b) = segment
        let ab = b - a
        let length = simd_length_squared(ab)
        let u = length > 0 ? min(max(simd_dot(p - a, ab) / length, 0), 1) : 0
        return simd_distance(p, a + u * ab)
    }

    private static func inTriangle(_ p: SIMD2<Double>, _ t: [SIMD2<Double>]) -> Bool {
        func side(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
        let (d1, d2, d3) = (side(t[0], t[1]), side(t[1], t[2]), side(t[2], t[0]))
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    /// What is under `p`: the handles of the one selected (drawn over everything), then the topmost annotation shown.
    private func target(at p: SIMD2<Double>) -> (item: Item, part: AnnotationHandles.Part)? {
        if let item = handled,
            let part = AnnotationHandles.part(
                at: p, box: item.box, rotation: item.rotation, points: item.points, behavior: item.behavior),
            part != .body
        {
            return (item, part)
        }
        for item in items.reversed() where item.visible || selected.contains(item.id) {
            if Self.contains(item, p) { return (item, .body) }
        }
        return nil
    }

    private func point(_ event: NSEvent) -> SIMD2<Double> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(point.x), Double(point.y))
    }

    // MARK: - Drawing

    /// Lays the layers out for what is shown now, without actions; a selection coming into sight pops in.
    private func place(appearing: Bool = false) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.frame = bounds
        for layer in [container, hoverOutline, outline, guideLines, dropOutline, notice] + squares + dots
        where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        let shown = items.filter { selected.contains($0.id) }
        let hoveredItem = hovered.flatMap { h in selected.contains(h.id) ? nil : items.first { $0.id == h.id } }
        guard !shown.isEmpty || hoveredItem != nil, editing == nil else {
            container.opacity = 0
            for handle in squares + dots { handle.isHidden = true }
            return
        }
        let accent = NSColor.controlAccentColor.cgColor
        let handled = self.handled
        // The outlines: of each selected (an arrow's own curve only while several are), and of the one under the pointer.
        let path = CGMutablePath()
        for item in shown { addOutline(of: item, to: path, curve: handled == nil) }
        outline.path = path
        outline.shadowPath = path.copy(strokingWithWidth: 3, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
        outline.strokeColor = drag?.part == .body ? accent : NSColor.white.cgColor
        outline.lineDashPattern = handled == nil ? [4, 3] : nil
        let hoverPath = CGMutablePath()
        if let hoveredItem { addOutline(of: hoveredItem, to: hoverPath, curve: true) }
        hoverOutline.path = hoverPath
        placeHandles(of: handled, reduceMotion: reduceMotion, appearing: appearing)
        placeGuides()
        if appearing || container.opacity == 0 {
            container.opacity = 1
            fade(container, from: 0, to: 1, reduceMotion: reduceMotion)
            guard appearing, !reduceMotion else { return }
            for handle in squares + dots where !handle.isHidden {
                let pop = CASpringAnimation(keyPath: "transform.scale", spring: Motion.selector)
                pop.fromValue = 0.4
                pop.toValue = 1
                handle.add(pop, forKey: "pop")
            }
        }
    }

    private func addOutline(of item: Item, to path: CGMutablePath, curve: Bool) {
        switch item.behavior {
        case .arrow:
            guard curve, let first = item.curve.first else { return }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in item.curve.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        default:
            let corners = Self.corners(of: item.box, degrees: item.rotation).map { CGPoint(x: $0.x, y: $0.y) }
            path.addLines(between: corners)
            path.closeSubpath()
        }
    }

    /// The handles of `item` (none without one): its squares, turned with its box, and its round points.
    private func placeHandles(of item: Item?, reduceMotion: Bool, appearing: Bool) {
        let accent = NSColor.controlAccentColor.cgColor
        let pressed = drag?.part
        let hoveredPart = item.flatMap { item in hovered?.id == item.id ? hovered?.part : nil }
        func size(_ handle: CALayer, side: Double) {
            let from = handle.presentation()?.bounds ?? handle.bounds
            handle.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            if drag == nil, !appearing, !reduceMotion, !handle.isHidden, from.size != handle.bounds.size {
                let grow = CASpringAnimation(keyPath: "bounds", spring: Motion.hover)
                grow.fromValue = NSValue(rect: from)
                grow.toValue = NSValue(rect: handle.bounds)
                handle.add(grow, forKey: "hover")
            }
        }
        for (k, square) in squares.enumerated() {
            guard let item, Self.hasSquare(k, item.behavior) else {
                square.isHidden = true
                continue
            }
            let part = Self.part(ofSquare: k)
            // The edges' handles only where the side leaves room for them between the corners.
            let room = k == 4 || k == 6 ? item.box.width : k == 5 || k == 7 ? item.box.height : .infinity
            let hide = room < 4 * Self.handleSide
            let on = hoveredPart == part || pressed == part
            size(square, side: on ? Self.hoveredHandleSide : Self.handleSide)
            square.isHidden = hide
            let center = Self.drawnPoint(Self.handleSpots[k], of: item.box, degrees: item.rotation)
            square.position = CGPoint(x: center.x, y: center.y)
            square.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(item.rotation * .pi / 180)))
            square.backgroundColor = pressed == part ? accent : NSColor.white.cgColor
        }
        for (dot, part) in zip(dots, Self.dotParts) {
            guard let item, let center = item.points[part] else {
                dot.isHidden = true
                continue
            }
            let on = hoveredPart == part || pressed == part
            let side = on ? Self.hoveredDotSide : Self.dotSide
            size(dot, side: side)
            dot.cornerRadius = side / 2
            dot.isHidden = false
            dot.position = CGPoint(x: center.x, y: center.y)
            dot.backgroundColor = pressed == part ? accent : NSColor.white.cgColor
        }
    }

    /// The lines of the space a drag snapped to, across the part of it the view shows, in the accent color.
    private func placeGuides() {
        guard let item = drag?.items.first, drag?.items.count == 1, guides.x != nil || guides.y != nil else {
            guideLines.path = nil
            return
        }
        let space = item.space
        let visible = CGRect(x: space.x, y: space.y, width: space.width, height: space.height).intersection(bounds)
        guard !visible.isNull else {
            guideLines.path = nil
            return
        }
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

    /// The text being edited where it is; itself on an annotation the frame shows (and all along a drag), nothing
    /// elsewhere: the overlay's own items, and the preview (a click there plays), are under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let editor = editing?.editor, editor.frame.contains(local) { return editor.hitTest(local) }
        if drag != nil { return self }
        guard model.canEdit, !model.isPlaying else { return nil }
        return target(at: SIMD2(Double(local.x), Double(local.y))) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The places of the handles of the one selected, and the bodies of those shown.
    override func resetCursorRects() {
        guard model.canEdit, editing == nil else { return }
        let out = AnnotationHandles.hitSize / 2
        func square(_ p: SIMD2<Double>, _ half: Double) -> CGRect { CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half) }
        for item in items where item.visible || selected.contains(item.id) {
            if item.behavior == .arrow {
                for p in item.curve { addCursorRect(square(p, item.reach), cursor: .openHand) }
            } else {
                let corners = Self.corners(of: item.box, degrees: item.rotation)
                let xs = corners.map(\.x), ys = corners.map(\.y)
                addCursorRect(
                    CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!), cursor: .openHand)
            }
        }
        guard let item = handled else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .right, .bottom, .left]
        for k in 0..<8 where Self.hasSquare(k, item.behavior) {
            let cursor = item.rotation == 0 ? NSCursor.frameResize(position: positions[k], directions: .all) : .crosshair
            addCursorRect(square(Self.drawnPoint(Self.handleSpots[k], of: item.box, degrees: item.rotation), out), cursor: cursor)
        }
        for p in item.points.values { addCursorRect(square(p, out), cursor: .crosshair) }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        guard model.canEdit, !model.isPlaying, !model.isGesturing, editing == nil, let document = model.document,
            let hit = target(at: p)
        else { return }
        let (item, part) = (hit.item, hit.part)
        window?.makeFirstResponder(self)
        var ids = selected
        if part == .body, !event.modifierFlags.intersection([.shift, .command]).isEmpty {
            // ⇧ or ⌘: it joins the selection or leaves it, and nothing is dragged.
            if ids.contains(item.id) { ids.remove(item.id) } else { ids.insert(item.id) }
            select(ids)
            return
        }
        if !ids.contains(item.id) {
            ids = [item.id]
            select(ids)
        }
        if event.clickCount == 2, part == .body, item.text != nil {
            beginEditing(item)
            return
        }
        let dragged = part == .body && ids.count > 1 ? items.filter { ids.contains($0.id) } : [item]
        drag = Drag(part: part, start: p, items: dragged, document: document)
        guides = (nil, nil)
        if part == .body { NSCursor.closedHand.set() }
        place()
    }

    private func select(_ ids: Set<String>) {
        selected = ids
        model.selection = ids.isEmpty ? nil : .annotations(ids)
        place(appearing: true)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        let delta = point(event) - drag.start
        if !drag.began {
            guard delta != .zero else { return }
            model.beginGesture()
            guard model.isGesturing else {
                self.drag = nil
                return
            }
            drag.began = true
        }
        let step: EditStep?
        var snapped: (x: Double?, y: Double?) = (nil, nil)
        if drag.items.count == 1, let item = drag.items.first {
            let moved = dragged(
                item, part: drag.part, by: delta, keepAspect: event.modifierFlags.contains(.shift),
                snapping: !event.modifierFlags.contains(.command))
            snapped = moved.guides
            step = AnnotationCommands.place(
                drag.document, id: item.id, rect: moved.frame.rect, from: moved.frame.from, to: moved.frame.to,
                target: moved.frame.target, size: moved.frame.size, label: drag.part == .body ? .annotationMove : .annotationChange)
            show(item, as: moved.frame)
        } else {
            var deltas: [String: SIMD2<Double>] = [:]
            for item in drag.items {
                deltas[item.id] = AnnotationHandles.spaceDelta(delta, space: item.space)
                var frame = item.frame
                frame.rect.x += deltas[item.id]!.x
                frame.rect.y += deltas[item.id]!.y
                show(item, as: frame, moving: delta)
            }
            step = AnnotationCommands.nudge(drag.document, by: deltas)
        }
        // A line that just snapped is felt.
        if snapped.x != nil && snapped.x != guides.x || snapped.y != nil && snapped.y != guides.y {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guides = snapped
        self.drag = drag
        model.updateGesture(step)
        place()
    }

    /// `item` after `part` is dragged `delta` view points (`AnnotationHandles.dragged`), snapped unless `snapping` is off
    /// (and for a corner or a side kept in proportion, or of a turned box): a corner or a side of a turned box is moved in
    /// the box's own directions and the box is then put back so its opposite corner or side stays where it is drawn; an
    /// end or a point stays inside where its anchor lets the rect be, and a body takes its points as far as its rect goes.
    private func dragged(
        _ item: Item, part: AnnotationHandles.Part, by delta: SIMD2<Double>, keepAspect: Bool, snapping: Bool
    ) -> (frame: AnnotationFrame, guides: (x: Double?, y: Double?)) {
        let resizing: Bool
        switch part {
        case .corner, .edge: resizing = true
        case .body, .from, .to, .target: resizing = false
        }
        let turned = resizing && item.rotation != 0
        let local = turned ? Self.rotated(delta, degrees: -item.rotation) : delta
        let aspect = item.space.width / item.space.height
        var frame = AnnotationHandles.dragged(
            item.frame, part: part, by: AnnotationHandles.spaceDelta(local, space: item.space), keepAspect: keepAspect,
            behavior: item.behavior, spaceAspect: aspect)
        var guides: (x: Double?, y: Double?) = (nil, nil)
        if snapping, !turned, !(resizing && keepAspect) {
            let snap = AnnotationHandles.snapped(
                frame, part: part, space: item.space, tolerance: AnnotationHandles.snapDistance, behavior: item.behavior)
            frame = snap.shape
            guides = snap.guides
        }
        if turned { frame = Self.kept(frame, from: item.frame, part: part, degrees: item.rotation, space: item.space) }
        return (held(frame, from: item.frame, part: part, anchor: item.anchor), guides)
    }

    /// `frame`, the rect of a box turned `degrees` after `part` was dragged, moved so the point opposite the part (the
    /// other corner, or the middle of the other side) is drawn where it was in `before`.
    private static func kept(
        _ frame: AnnotationFrame, from before: AnnotationFrame, part: AnnotationHandles.Part, degrees: Double, space: Rect
    ) -> AnnotationFrame {
        let opposite: SIMD2<Double>
        switch part {
        case let .corner(k): opposite = SIMD2(k == 1 || k == 3 ? 0 : 1, k >= 2 ? 0 : 1)
        case .edge(0): opposite = SIMD2(0.5, 1)
        case .edge(1): opposite = SIMD2(0, 0.5)
        case .edge(2): opposite = SIMD2(0.5, 0)
        case .edge: opposite = SIMD2(1, 0.5)
        case .body, .from, .to, .target: return frame
        }
        func drawn(_ rect: NormalizedRect) -> SIMD2<Double> {
            drawnPoint(opposite, of: AnnotationGeometry.pixels(rect, in: space), degrees: degrees)
        }
        let shift = AnnotationHandles.spaceDelta(drawn(before.rect) - drawn(frame.rect), space: space)
        var result = frame
        result.rect.x += shift.x
        result.rect.y += shift.y
        return result
    }

    /// `frame` where the anchor lets it be: a body's rect held (`AnnotationGeometry.clamped`) and its points moved as far
    /// as the rect moved; an arrow's end or a bubble's point inside the range a rect can be in (−0.5…1.5 of the content,
    /// 0…1 of the output), so it can always be grabbed again.
    private func held(
        _ frame: AnnotationFrame, from before: AnnotationFrame, part: AnnotationHandles.Part, anchor: AnnotationAnchor
    ) -> AnnotationFrame {
        let range: ClosedRange<Double>
        if case .content = anchor { range = AnnotationGeometry.contentRange } else { range = 0...1 }
        func clamp(_ p: NormalizedPoint?) -> NormalizedPoint? {
            p.map { NormalizedPoint(x: min(max($0.x, range.lowerBound), range.upperBound), y: min(max($0.y, range.lowerBound), range.upperBound)) }
        }
        var result = frame
        switch part {
        case .from: result.from = clamp(frame.from)
        case .to: result.to = clamp(frame.to)
        case .target: result.target = clamp(frame.target)
        case .body:
            if let from = before.from, let to = before.to {
                // An arrow: as far as both its ends can go.
                var shift = SIMD2((frame.from?.x ?? from.x) - from.x, (frame.from?.y ?? from.y) - from.y)
                for end in [from, to] {
                    shift.x = min(max(shift.x, range.lowerBound - end.x), range.upperBound - end.x)
                    shift.y = min(max(shift.y, range.lowerBound - end.y), range.upperBound - end.y)
                }
                result.from = NormalizedPoint(x: from.x + shift.x, y: from.y + shift.y)
                result.to = NormalizedPoint(x: to.x + shift.x, y: to.y + shift.y)
                result.rect.x = before.rect.x + shift.x
                result.rect.y = before.rect.y + shift.y
            } else {
                let rect = AnnotationGeometry.clamped(frame.rect, anchor: anchor)
                result.rect = rect
                if let target = before.target {
                    result.target = NormalizedPoint(x: target.x + rect.x - before.rect.x, y: target.y + rect.y - before.rect.y)
                }
            }
        case .corner, .edge:
            break
        }
        return result
    }

    /// Shows `item` dragged to `frame`; by `moving` view points when several move, as their boxes are.
    private func show(_ item: Item, as frame: AnnotationFrame, moving: SIMD2<Double>? = nil) {
        guard let k = items.firstIndex(where: { $0.id == item.id }) else { return }
        var now = item
        now.frame = frame
        if let moving {
            now.box.x += moving.x
            now.box.y += moving.y
            now.points = item.points.mapValues { $0 + moving }
            now.curve = item.curve.map { $0 + moving }
            now.tail = item.tail.map { $0 + moving }
        } else {
            let rect = item.behavior == .arrow ? frame.rect : AnnotationGeometry.clamped(frame.rect, anchor: item.anchor)
            now.box = AnnotationGeometry.pixels(rect, in: item.space)
            let shift = SIMD2(now.box.x - item.box.x, now.box.y - item.box.y)
            func view(_ p: NormalizedPoint?) -> SIMD2<Double>? { p.map { AnnotationGeometry.point($0, in: item.space) } }
            now.points[.from] = view(frame.from)
            now.points[.to] = view(frame.to)
            now.points[.target] = view(frame.target)
            if item.behavior == .arrow, let a = view(frame.from), let b = view(frame.to), let a0 = item.points[.from],
                let b0 = item.points[.to]
            {
                // The curve stretched with its ends (the render draws the bend anew).
                now.curve = item.curve.enumerated().map { n, p in
                    let u = Double(n) / Double(max(item.curve.count - 1, 1))
                    return p + (1 - u) * (a - a0) + u * (b - b0)
                }
            } else {
                now.curve = item.curve.map { $0 + shift }
            }
            now.tail = []
        }
        items[k] = now
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        guides = (nil, nil)
        // One step, once let go; what is shown comes from the frame the model draws next.
        if drag.began { model.endGesture() }
        hovered = target(at: point(event)).map { ($0.item.id, $0.part) }
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
        guard drag == nil, editing == nil else { return }
        let next = model.canEdit && !model.isPlaying ? target(at: point(event)).map { ($0.item.id, $0.part) } : nil
        guard next?.0 != hovered?.id || next?.1 != hovered?.part else { return }
        hovered = next
        place()
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil, hovered != nil else { return }
        hovered = nil
        place()
    }

    // MARK: - Editing a text

    /// Starts editing the text of annotation `id` in place, if the frame shows it (the showcase's `=text`).
    @discardableResult
    func beginEditingText(_ id: String) -> Bool {
        refresh()
        guard let item = items.first(where: { $0.id == id }), item.text != nil else { return false }
        beginEditing(item)
        return editing != nil
    }

    /// A text view over `item`'s box in its font, its size and its colours: the annotation is hidden in the preview
    /// meanwhile (a gesture whose look has it at opacity 0), and what is typed is one step when it is kept.
    private func beginEditing(_ item: Item) {
        guard let text = item.text, model.canEdit, !model.isGesturing, editing == nil else { return }
        let id = item.id
        model.beginGesture { document in
            var shown = document
            if let k = shown.annotations.items.firstIndex(where: { $0.id == id }) { shown.annotations.items[k].opacity = 0 }
            return shown
        }
        guard model.isGesturing else { return }
        let em = text.size * item.space.height
        let editor = AnnotationTextEditor(
            text: text, box: CGRect(x: item.box.x, y: item.box.y, width: item.box.width, height: item.box.height), em: em,
            callout: item.behavior == .callout)
        editor.onFinish = { [weak self] string, resigning in
            self?.finishEditing(id, string: string, resigning: resigning)
        }
        addSubview(editor)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak editor] event in
            MainActor.assumeIsolated {
                // A click anywhere but in the text keeps it (and goes on to where it was).
                if let editor, event.window !== editor.window
                    || !editor.bounds.contains(editor.convert(event.locationInWindow, from: nil))
                {
                    editor.finish(keeping: true)
                }
            }
            return event
        }
        editing = (id, editor, monitor)
        hovered = nil
        place()
        window?.makeFirstResponder(editor)
        editor.selectAll(nil)
        window?.invalidateCursorRects(for: self)
    }

    /// The text of annotation `id` was kept (`string`) or given up (`nil`): one step with it, or none. `resigning`: the
    /// text view is giving up the focus to another view, which keeps it.
    private func finishEditing(_ id: String, string: String?, resigning: Bool) {
        guard let current = editing, current.id == id else { return }
        editing = nil
        if let monitor = current.monitor { NSEvent.removeMonitor(monitor) }
        if let string, let document = model.document,
            let step = AnnotationCommands.change(document, id: id, { annotation in
                switch annotation.kind {
                case var .text(text):
                    text.string = string
                    annotation.kind = .text(text)
                case var .callout(callout):
                    callout.text.string = string
                    annotation.kind = .callout(callout)
                default:
                    break
                }
            })
        {
            model.updateGesture(step)
            model.endGesture()
        } else {
            model.cancelGesture()
        }
        if resigning {
            // Out of the window once its focus has gone where it goes.
            DispatchQueue.main.async { current.editor.removeFromSuperview() }
        } else {
            window?.makeFirstResponder(self)
            current.editor.removeFromSuperview()
        }
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        editing?.editor.finish(keeping: false)
        importing?.cancel()
        noticeTask?.cancel()
    }

    // MARK: - Dropping an image or a clip

    /// The kinds of files a drop takes: the images Toma imports (and those it turns into one, phase 3 design §5.4) and the
    /// clips.
    private static let droppable = Set(AssetImport.allowedExtensions + ["jpeg", "tif", "tiff", "gif", "pdf"])
        .union(ContentClipTrackRules.videoExtensions)

    /// The one file of a drag that can go over the video, when the project can be edited and no other is being imported.
    private func droppedFile(_ sender: any NSDraggingInfo) -> URL? {
        guard model.canEdit, importing == nil else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            ?? []
        guard urls.count == 1, let url = urls.first, Self.droppable.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = droppedFile(sender) != nil
        showDropOutline(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showDropOutline(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        showDropOutline(false)
    }

    /// The file is imported and goes over the video, centred where it was dropped (fractions of the preview).
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showDropOutline(false)
        guard let url = droppedFile(sender), bounds.width > 0, bounds.height > 0 else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let point = NormalizedPoint(x: Double(p.x / bounds.width), y: Double(p.y / bounds.height))
        let text = String(
            format: String(localized: "Importing “%@”…", comment: "Over the timeline, while a clip dropped on the Video track is copied into the project"),
            url.lastPathComponent)
        showNotice(text, for: nil)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text])
        let model = model
        importing = Task { [weak self] in
            let added = await model.addOverlay(from: url, at: point)
            guard let self else { return }
            self.importing = nil
            if Task.isCancelled { return }
            if added {
                self.hideNotice()
            } else {
                let failed = String(localized: "Couldn't add the file.", comment: "Over the preview: an image or a clip dropped on it could not be added")
                self.showNotice(failed, for: .seconds(3))
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: failed])
            }
        }
        return true
    }

    private func showDropOutline(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropOutline.frame = bounds
        dropOutline.path = CGPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        dropOutline.strokeColor = NSColor.controlAccentColor.cgColor
        dropOutline.isHidden = !on
        CATransaction.commit()
    }

    /// `text` in a pill at the bottom of the preview, for `duration` (until hidden without one).
    private func showNotice(_ text: String, for duration: Duration?) {
        noticeTask?.cancel()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let width = min((text as NSString).size(withAttributes: [.font: font]).width + 20, max(bounds.width - 24, 40))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notice.string = text
        notice.frame = CGRect(x: (bounds.width - width) / 2, y: max(bounds.height - 40, 4), width: width, height: 24)
        notice.contentsScale = window?.backingScaleFactor ?? 2
        notice.isHidden = false
        CATransaction.commit()
        guard let duration else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hideNotice()
        }
    }

    private func hideNotice() {
        noticeTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notice.isHidden = true
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        place()
    }

    /// The items are in the view's points: placed again at its new size (a drag or a text being edited keeps its own).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if drag == nil, editing == nil { refresh() } else { place() }
        window?.invalidateCursorRects(for: self)
    }
}
