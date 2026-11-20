// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// Editing the timeline with the mouse (design §5.5), on top of the commands (`SequenceCommands`, `ZoomCommands`,
/// `TrackCommands`): what is under the mouse (`TimelineHitTest`), the selection, hover, the drags that trim and move and
/// make, the menus. Every rule is in AppSupport (`TimelineHitTest`, `TimelineDragRules`) and in the commands; this class
/// only reads the mouse and the geometry and says what to do.
///
/// - A click selects (⇧ adds, on the same track); a click on nothing deselects and moves the playhead; a click or a drag
///   on the ruler moves the playhead, and with ⌥ a drag marks a range.
/// - A drag is one gesture of the model (`beginGesture` … `endGesture`): while it lasts the timeline and the preview show
///   the document with the drag's step applied, and on the mouse's release the step is made once, one undo step with its
///   label. Esc during a drag gives it up (`cancelDrag()`); releasing outside does the same as inside.
/// - Within 6 pt of an edge of a clip or a block, the cursor is `resizeLeftRight` and a drag trims it, with a label
///   ("−1,20 s · 0:18,40"); a drag of a block moves it; a drag in an empty place of the Zoom track makes one (at least 0.3 s)
///   and a double click makes one of 3 s; the diamonds of the camera and the limits between screens are dragged in time.
/// - Edges snap to the playhead, the marks, the edges of clips and blocks, the diamonds, the markers and the start and the
///   end, within 8 pt (`snapping` of the view, ⌘ inverts it while dragging).
@MainActor
final class TimelineInteraction {
    private unowned let view: EditorTimelineView
    weak var model: EditorModel?

    private var drag = Drag.none
    private var hover: TimelineHit?
    private let highlight = CALayer()
    private let dragLabel = CATextLayer()
    private let noticeLabel = CATextLayer()
    private var noticeTask: Task<Void, Never>?
    /// The step the gesture in progress has now.
    private var lastStep: EditStep?

    /// What a drag started from: the document and what it needs to work out its steps, taken once at its start.
    private struct Base {
        var document: EditDocument
        var map: TimeMap
        /// The edit points that edges snap to, in output time.
        var points: [Int64]
        var project: LoadedProject?
    }

    private enum Drag {
        case none
        /// The playhead follows the mouse.
        case playhead
        /// ⌥ on the ruler: the marks follow the mouse.
        case marks(anchor: Int64)
        /// An empty place of the Zoom track: a click, or a drag that makes a block.
        case emptyZoom(down: CGPoint, anchor: Int64)
        /// An item pressed, not yet dragged.
        case pressed(down: CGPoint, hit: TimelineHit)
        case trimClip(Base, clip: Clip, edge: ClipEdge, outputStart: Int64, limits: ClosedRange<HostTime>)
        case trimZoom(Base, id: String, edge: ClipEdge, range: Range<Int64>)
        case moveZoom(Base, id: String, range: Range<Int64>, grab: Int64)
        case createZoom(Base, anchor: Int64)
        case moveCamera(Base, id: String)
        /// An empty place of the Camera track: a click, or a drag that makes a layout block.
        case emptyLayout(down: CGPoint, anchor: Int64)
        case trimLayout(Base, id: String, edge: ClipEdge, range: Range<Int64>)
        case moveLayout(Base, id: String, range: Range<Int64>, grab: Int64)
        case createLayout(Base, anchor: Int64)
        case moveBoundary(Base, changeID: String)
        /// A privacy block (phase 2): trimmed by an edge, or moved by its body; neither stops at another block.
        case trimPrivacy(Base, id: String, edge: ClipEdge, range: Range<Int64>)
        case movePrivacy(Base, id: String, range: Range<Int64>, grab: Int64)
    }

    init(view: EditorTimelineView) {
        self.view = view
        highlight.cornerRadius = 4
        highlight.opacity = 0
        highlight.isHidden = true
        view.overlay.addSublayer(highlight)
        for text in [dragLabel, noticeLabel] {
            text.cornerRadius = 4
            text.alignmentMode = .center
            text.opacity = 0
            TimelineText.setUp(text, size: 11, weight: .medium, monospacedDigits: true)
            view.overlay.addSublayer(text)
        }
    }

    // MARK: - Looking

    private var canEdit: Bool { model?.canEdit == true }

    private func point(_ event: NSEvent) -> CGPoint {
        view.convert(event.locationInWindow, from: nil)
    }

    /// What is under `point` (the view's coordinates).
    private func hit(at point: CGPoint) -> TimelineHit {
        guard let content = view.content else { return .playhead }
        let scrolled = CGPoint(
            x: point.x, y: point.y < TimelineLayout.rulerHeight ? point.y : point.y + view.verticalOffset)
        let hit = TimelineHitTest.hit(at: scrolled, items: view.hitItems, layout: content.layout, scale: view.scale, offset: view.offset)
        return normalized(hit)
    }

    /// The edge of a screen's stretch is the limit between two: the start of the first stretch, and the end of the last, are
    /// not limits that move.
    private func normalized(_ hit: TimelineHit) -> TimelineHit {
        // A caption has no edges to grab: its body is all there is (the captions follow the words).
        if case let .edge(.captions, id, _) = hit { return .item(.captions, id: id) }
        guard case let .edge(.screen, id, edge) = hit, let content = view.content else { return hit }
        switch edge {
        case .start: return id == "initial" ? .item(.screen, id: id) : hit
        case .end: return content.screens.items.last?.id == id ? .item(.screen, id: id) : hit
        }
    }

    /// The output time at `point`.
    private func output(at point: CGPoint) -> Int64 {
        view.content?.layout.output(atX: point.x, scale: view.scale, offset: view.offset) ?? 0
    }

    private func clamped(_ τ: Int64) -> Int64 {
        min(max(τ, 0), view.content?.map.duration ?? 0)
    }

    private func item(_ id: String) -> TimelineItem? {
        view.hitItems.first { $0.id == id }
    }

    // MARK: - Selection

    private var selectedIDs: Set<String> {
        switch model?.selection {
        case let .clips(ids)?, let .zooms(ids)?: ids
        case let .cameraChange(id)?, let .screenChange(id)?, let .layoutBlock(id)?: [id]
        case let .privacyBlocks(ids)?: ids
        case nil: []
        }
    }

    private func select(_ hit: TimelineHit, shift: Bool) {
        guard let model else { return }
        let next = TimelineHitTest.selection(selectedIDs, clicking: hit, shift: shift) { [weak self] in self?.item($0)?.track }
        guard hit != .playhead else { return }
        let track = next.first.flatMap { item($0)?.track }
        if track == .camera, let id = next.first, !isLayoutBlock(id), let output = item(id)?.output.lowerBound {
            // A change of the bubble, as the Camera tab's list selects one: the playhead goes onto it, so the tab edits it.
            model.selectCameraChange(id, output: output)
            return
        }
        model.selection = selection(next, on: track)
    }

    /// Whether `id`, an item of the Camera track, is a layout block (and not a change of the bubble).
    private func isLayoutBlock(_ id: String) -> Bool {
        view.content?.layoutBlockIDs.contains(id) == true
    }

    /// `ids`, all of `track`, as the model's selection.
    private func selection(_ ids: Set<String>, on track: TimelineTrack?) -> EditorSelection? {
        guard let id = ids.first, let track else { return nil }
        switch track {
        case .video: return .clips(ids)
        case .zoom: return .zooms(ids)
        case .camera: return isLayoutBlock(id) ? .layoutBlock(id) : .cameraChange(id)
        case .screen: return id == "initial" ? nil : .screenChange(id)
        case .privacy: return .privacyBlocks(ids)
        case .ruler, .audio, .captions, .annotations, .importedAudio, .music: return nil
        }
    }

    // MARK: - Mouse

    func mouseDown(_ event: NSEvent) {
        guard view.content != nil else { return }
        let point = point(event)
        guard point.x >= TimelineLayout.headerWidth else { return }
        clearHover()
        let hit = hit(at: point)
        if hit == .playhead {
            if event.modifierFlags.contains(.option) {
                drag = .marks(anchor: snapped(output(at: point), event: event, base: nil))
            } else {
                drag = .playhead
                view.scrub(at: point.x)
            }
            return
        }
        // A caption is not selected, dragged or trimmed; a double click shows its word in the Captions tab.
        if case let .item(.captions, id) = hit {
            if event.clickCount >= 2 { revealCaption(id, at: output(at: point)) }
            drag = .none
            return
        }
        select(hit, shift: event.modifierFlags.contains(.shift))
        // A double click on a privacy block selects it and takes the playhead into it: the preview shows its rect.
        if event.clickCount >= 2, case let .item(.privacy, id) = hit {
            model?.selectPrivacyBlock(id, showingIt: true)
            drag = .none
            return
        }
        switch hit {
        case let .empty(track, τ):
            if track == .zoom, canEdit {
                if event.clickCount >= 2 {
                    model?.addZoom(at: clamped(τ))
                    drag = .none
                } else {
                    drag = .emptyZoom(down: point, anchor: τ)
                }
            } else if track == .camera, canEdit {
                if event.clickCount >= 2 {
                    model?.addLayoutBlock(click: clamped(τ))
                    drag = .none
                } else {
                    drag = .emptyLayout(down: point, anchor: τ)
                }
            } else {
                // A click on nothing moves the playhead, and dragging goes on moving it.
                drag = .playhead
                view.scrub(at: point.x)
            }
        case .item, .edge:
            drag = .pressed(down: point, hit: hit)
        case .playhead:
            break
        }
    }

    /// Shows in the Captions tab the word of caption `id` said at output time `τ` (the first one if none is).
    private func revealCaption(_ id: String, at τ: Int64) {
        guard let model, let ref = view.content?.captions.items.first(where: { $0.id == id })?.info.word(at: τ) else { return }
        model.voice.reveal(ref)
    }

    func mouseDragged(_ event: NSEvent) {
        let point = point(event)
        switch drag {
        case .none:
            break
        case .playhead:
            view.scrub(toX: point.x)
        case let .marks(anchor):
            guard let duration = view.content?.map.duration else { return }
            let τ = snapped(output(at: point), event: event, base: nil)
            if let marks = TimelineDragRules.marks(from: anchor, to: τ, duration: duration) {
                model?.timelineMarks = TimelineMarks(in: marks.in, out: marks.out)
            }
        case let .emptyZoom(down, anchor):
            guard TimelineDragRules.isDrag(from: down, to: point), let base = begin() else { return }
            drag = .createZoom(base, anchor: anchor)
            updateDrag(event)
        case let .emptyLayout(down, anchor):
            guard TimelineDragRules.isDrag(from: down, to: point), let base = begin() else { return }
            drag = .createLayout(base, anchor: anchor)
            updateDrag(event)
        case let .pressed(down, hit):
            guard TimelineDragRules.isDrag(from: down, to: point) else { return }
            start(hit, at: point)
            updateDrag(event)
        case .trimClip, .trimZoom, .moveZoom, .createZoom, .moveCamera, .trimLayout, .moveLayout, .createLayout, .moveBoundary:
            updateDrag(event)
        case .trimPrivacy, .movePrivacy:
            updateDrag(event)
        }
    }

    func mouseUp(_ event: NSEvent) {
        defer {
            drag = .none
            hideLabel()
            mouseMoved(event)
        }
        switch drag {
        case .none, .marks, .pressed:
            break
        case .playhead:
            view.endScrub()
        case .emptyZoom, .emptyLayout:
            // A click: the playhead goes there.
            view.scrub(at: point(event).x)
            view.endScrub()
        case .trimClip, .trimZoom, .moveZoom, .createZoom, .moveCamera, .trimLayout, .moveLayout, .createLayout, .moveBoundary:
            finish()
        case .trimPrivacy, .movePrivacy:
            finish()
        }
    }

    // MARK: - Hover

    func mouseMoved(_ event: NSEvent) {
        guard case .none = drag, view.content != nil else { return }
        let point = point(event)
        guard point.x >= TimelineLayout.headerWidth else {
            clearHover()
            return
        }
        let next = hit(at: point)
        setCursor(for: next)
        guard next != hover else { return }
        hover = next
        refreshHighlight()
    }

    func mouseExited() {
        guard case .none = drag else { return }
        NSCursor.arrow.set()
        clearHover()
    }

    private func clearHover() {
        guard hover != nil else { return }
        hover = nil
        refreshHighlight()
    }

    private func setCursor(for hit: TimelineHit) {
        if case .edge = hit, canEdit {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// The layout changed (a scroll, a scale, an edit): the highlight goes where its item is now.
    func viewDidLayout(_ geometry: TimelineGeometry) {
        guard hover != nil else { return }
        refreshHighlight()
    }

    /// The highlight over the hovered item or edge: it moves to the next with `Motion.hover`, and fades in and out.
    private func refreshHighlight() {
        guard let geometry = view.geometry() else { return }
        var target: (rect: CGRect, edge: Bool)?
        switch hover {
        case let .item(_, id)?:
            if let item = item(id), let rect = geometry.itemFrame(of: item) { target = (rect, false) }
        case let .edge(_, id, edge)?:
            if let item = item(id), let rect = geometry.itemFrame(of: item) {
                let bar = 3.0
                let x = edge == .start ? rect.minX : rect.maxX - bar
                target = (CGRect(x: x, y: rect.minY, width: bar, height: rect.height), true)
            }
        default:
            break
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let target else {
            guard !highlight.isHidden, highlight.opacity != 0 else { return }
            highlight.opacity = 0
            fade(highlight, from: 1, to: 0, reduce: reduce)
            return
        }
        let wasShown = !highlight.isHidden && highlight.opacity != 0
        let from = highlight.presentation()?.frame ?? highlight.frame
        highlight.isHidden = false
        let palette = view.palette
        highlight.backgroundColor = target.edge ? palette.selection : palette.hoverFill
        highlight.cornerRadius = target.edge ? 1.5 : 4
        highlight.frame = target.rect
        highlight.opacity = 1
        if !wasShown {
            fade(highlight, from: 0, to: 1, reduce: reduce)
        } else if !reduce, from != target.rect {
            let move = CASpringAnimation(keyPath: "position", spring: Motion.hover)
            move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
            move.toValue = NSValue(point: CGPoint(x: target.rect.midX, y: target.rect.midY))
            let size = CASpringAnimation(keyPath: "bounds", spring: Motion.hover)
            size.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
            size.toValue = NSValue(rect: CGRect(origin: .zero, size: target.rect.size))
            highlight.add(move, forKey: "move")
            highlight.add(size, forKey: "size")
        }
    }

    /// `layer`'s opacity from `a` to `b` with `Motion.hover` (a plain fade with Reduce Motion).
    private func fade(_ layer: CALayer, from a: Float, to b: Float, reduce: Bool) {
        let animation: CAPropertyAnimation
        if reduce {
            let basic = CABasicAnimation(keyPath: "opacity")
            basic.duration = Motion.reducedMotionFade.timeInterval
            basic.fromValue = a
            basic.toValue = b
            animation = basic
        } else {
            let spring = CASpringAnimation(keyPath: "opacity", spring: Motion.hover)
            spring.fromValue = a
            spring.toValue = b
            animation = spring
        }
        layer.add(animation, forKey: "fade")
    }

    // MARK: - Drags

    /// Starts the model's gesture and takes what the drag's steps are made from: nothing if the document cannot be edited.
    private func begin() -> Base? {
        guard let model, canEdit, !model.isGesturing, let document = model.document else { return nil }
        model.beginGesture()
        guard model.isGesturing else { return nil }
        let map = TimeMap(sequence: document.sequence)
        let project = model.overlayProject
        let points = EditPoints(document: document, timeMap: map, markers: model.markerTimes).all
        lastStep = nil
        return Base(document: document, map: map, points: points, project: project)
    }

    /// The drag of the pressed item `hit`, if it has one.
    private func start(_ hit: TimelineHit, at point: CGPoint) {
        guard let model, canEdit, let document = model.document else {
            drag = .none
            return
        }
        switch hit {
        case let .edge(.video, id, edge):
            guard let k = document.sequence.firstIndex(where: { $0.id == id }), let base = begin(), let project = base.project else { return }
            let limits = SequenceCommands.trimLimits(document, clipID: id, edge: edge, take: project.take, events: project.events)
            drag = .trimClip(base, clip: document.sequence[k], edge: edge, outputStart: base.map.clipOutputStarts[k], limits: limits)
        case let .edge(.zoom, id, edge):
            guard let base = begin(), let range = zoomRange(id, in: base.document) else { return }
            drag = .trimZoom(base, id: id, edge: edge, range: range)
        case let .item(.zoom, id):
            guard let base = begin(), let range = zoomRange(id, in: base.document) else { return }
            drag = .moveZoom(base, id: id, range: range, grab: output(at: point) - range.lowerBound)
        case let .edge(.camera, id, edge) where isLayoutBlock(id):
            guard let base = begin(), let range = layoutRange(id, in: base.document) else { return }
            drag = .trimLayout(base, id: id, edge: edge, range: range)
        case let .item(.camera, id) where isLayoutBlock(id):
            guard let base = begin(), let range = layoutRange(id, in: base.document) else { return }
            drag = .moveLayout(base, id: id, range: range, grab: output(at: point) - range.lowerBound)
        case let .item(.camera, id), let .edge(.camera, id, _):
            guard let base = begin() else { return }
            drag = .moveCamera(base, id: id)
        case let .edge(.screen, id, edge):
            // The limit between two stretches is the change that starts the second.
            guard let screens = view.content?.screens.items, let k = screens.firstIndex(where: { $0.id == id }) else { return }
            let changeID = edge == .start ? id : (k + 1 < screens.count ? screens[k + 1].id : nil)
            guard let changeID, changeID != "initial", let base = begin() else { return }
            drag = .moveBoundary(base, changeID: changeID)
        case let .edge(.privacy, id, edge):
            guard let base = begin(), let range = TimelinePrivacyItems.range(of: id, in: base.document) else { return }
            drag = .trimPrivacy(base, id: id, edge: edge, range: range)
        case let .item(.privacy, id):
            guard let base = begin(), let range = TimelinePrivacyItems.range(of: id, in: base.document) else { return }
            drag = .movePrivacy(base, id: id, range: range, grab: output(at: point) - range.lowerBound)
        default:
            drag = .none
        }
    }

    /// The layout a block made by a drag gets: the last one chosen for a block, or the first time Full-Screen Camera.
    private var newBlockKind: LayoutKind {
        LayoutTrackRules.newBlock(playhead: 0, click: nil, marks: nil, lastKind: model?.lastBlockLayout).kind
    }

    /// Where the preview shows layout block `id` of `document`.
    private func layoutRange(_ id: String, in document: EditDocument) -> Range<Int64>? {
        guard let k = document.camera.layouts.firstIndex(where: { $0.id == id }) else { return nil }
        return LayoutTimeline.blockOutputs(of: document, timeMap: TimeMap(sequence: document.sequence))[k]
    }

    private func zoomRange(_ id: String, in document: EditDocument) -> Range<Int64>? {
        guard let region = document.zoom.regions.first(where: { $0.id == id }) else { return nil }
        return TimeMap(sequence: document.sequence).outputRange(ofSource: region.start..<region.end, take: region.take)
    }

    /// `τ` at what it snaps to: the edit points, the playhead and the marks (nothing, without a base: only the last two).
    private func snapped(_ τ: Int64, event: NSEvent, base: Base?) -> Int64 {
        let active = TimelineDragRules.snapActive(enabled: view.snapping, commandHeld: event.modifierFlags.contains(.command))
        return TimelineDragRules.snap(
            τ, points: base?.points ?? [], extra: snapTargets(), tolerance: TimelineHitTest.snapTolerance(scale: view.scale), active: active)
    }

    private func snapTargets() -> [Int64] {
        guard let model else { return [] }
        return [model.playheadNanoseconds] + [model.timelineMarks.in, model.timelineMarks.out].compactMap { $0 }
    }

    private func updateDrag(_ event: NSEvent) {
        let point = point(event)
        let makeID: (String) -> String = { EditorModel.newID($0) }
        var step: EditStep?
        var label: (delta: Int64, position: Int64)?
        // A trimmed zoom's or layout block's label is placed below, from the document the model applied the step to.
        var trimmedZoom: (id: String, edge: ClipEdge, output: Int64)?
        var trimmedLayout: (id: String, edge: ClipEdge, output: Int64)?
        var trimmedPrivacy: (id: String, edge: ClipEdge, output: Int64)?
        let base: Base
        switch drag {
        case let .trimClip(trimBase, clip, edge, outputStart, limits):
            base = trimBase
            let τ = snapped(output(at: point), event: event, base: base)
            let source = TimelineDragRules.sourceInstant(atOutput: τ, clipOutputStart: outputStart, clipStart: clip.start, speed: clip.speed)
            step = SequenceCommands.trim(base.document, clipID: clip.id, edge: edge, toSource: source, limits: limits)
            let speed = ClipSpeed.clamped(clip.speed)
            let origin = edge == .start ? clip.start : clip.end
            let to = min(max(source, limits.lowerBound), limits.upperBound)
            let moved = Double(Int64(clamping: to.nanoseconds) - Int64(clamping: origin.nanoseconds)) / speed
            let delta = Int64(moved.rounded())
            let edgeOutput = outputStart + (edge == .start ? 0 : TimeMap.outputDuration(of: clip))
            label = (delta, edgeOutput + delta)
        case let .trimZoom(trimBase, id, edge, range):
            base = trimBase
            let τ = snapped(output(at: point), event: event, base: base)
            step = ZoomCommands.trim(base.document, id: id, edge: edge, toOutput: τ)
            // Placed below, from the document the model applied the step to.
            trimmedZoom = (id, edge, edge == .start ? range.lowerBound : range.upperBound)
        case let .moveZoom(moveBase, id, range, grab):
            base = moveBase
            let proposed = output(at: point) - grab - range.lowerBound
            let active = TimelineDragRules.snapActive(enabled: view.snapping, commandHeld: event.modifierFlags.contains(.command))
            let shift = TimelineDragRules.snapShift(
                of: range, by: proposed, points: base.points, extra: snapTargets(),
                tolerance: TimelineHitTest.snapTolerance(scale: view.scale), active: active)
            step = ZoomCommands.move(base.document, id: id, toOutputStart: range.lowerBound + shift, makeID: makeID)
        case let .createZoom(createBase, anchor):
            base = createBase
            let a = snapped(anchor, event: event, base: base), b = snapped(output(at: point), event: event, base: base)
            if let range = TimelineDragRules.creationRange(from: a, to: b, duration: base.map.duration) {
                step = ZoomCommands.add(base.document, output: range, makeID: makeID)
            }
        case let .trimLayout(trimBase, id, edge, range):
            base = trimBase
            let τ = snapped(output(at: point), event: event, base: base)
            step = LayoutCommands.trim(base.document, id: id, edge: edge, toOutput: τ, timeMap: base.map)
            // Placed below, from the document the model applied the step to.
            trimmedLayout = (id, edge, edge == .start ? range.lowerBound : range.upperBound)
        case let .moveLayout(moveBase, id, range, grab):
            base = moveBase
            let proposed = output(at: point) - grab - range.lowerBound
            let active = TimelineDragRules.snapActive(enabled: view.snapping, commandHeld: event.modifierFlags.contains(.command))
            let shift = TimelineDragRules.snapShift(
                of: range, by: proposed, points: base.points, extra: snapTargets(),
                tolerance: TimelineHitTest.snapTolerance(scale: view.scale), active: active)
            step = LayoutCommands.move(base.document, id: id, toOutputStart: range.lowerBound + shift, timeMap: base.map)
        case let .createLayout(createBase, anchor):
            base = createBase
            let a = snapped(anchor, event: event, base: base), b = snapped(output(at: point), event: event, base: base)
            if let range = LayoutTrackRules.creationRange(from: a, to: b, duration: base.map.duration) {
                step = LayoutCommands.add(base.document, kind: newBlockKind, output: range, timeMap: base.map, makeID: makeID)
            }
        case let .moveCamera(cameraBase, id):
            base = cameraBase
            let τ = snapped(output(at: point), event: event, base: base)
            step = TrackCommands.moveCameraChange(base.document, id: id, toOutput: τ, timeMap: base.map)
        case let .moveBoundary(boundaryBase, changeID):
            base = boundaryBase
            let τ = snapped(output(at: point), event: event, base: base)
            step = TrackCommands.moveScreenBoundary(base.document, changeID: changeID, toOutput: τ, timeMap: base.map)
        case let .trimPrivacy(trimBase, id, edge, range):
            base = trimBase
            let τ = snapped(output(at: point), event: event, base: base)
            step = PrivacyCommands.trim(base.document, id: id, edge: edge, toOutput: τ)
            trimmedPrivacy = (id, edge, edge == .start ? range.lowerBound : range.upperBound)
        case let .movePrivacy(moveBase, id, range, grab):
            base = moveBase
            let proposed = output(at: point) - grab - range.lowerBound
            let active = TimelineDragRules.snapActive(enabled: view.snapping, commandHeld: event.modifierFlags.contains(.command))
            let shift = TimelineDragRules.snapShift(
                of: range, by: proposed, points: base.points, extra: snapTargets(),
                tolerance: TimelineHitTest.snapTolerance(scale: view.scale), active: active)
            step = PrivacyCommands.move(base.document, id: id, toOutputStart: range.lowerBound + shift)
        default:
            return
        }
        switch drag {
        case .trimPrivacy: NSCursor.resizeLeftRight.set()
        case .trimClip, .trimZoom, .trimLayout: NSCursor.resizeLeftRight.set()
        default: break
        }
        lastStep = step
        // The step is applied once a move, by the model (design §7.9: the main thread never waits long): the preview, the
        // timeline and the label all show that document.
        let preview = model?.updateGesture(step)
        if let trimmed = trimmedZoom ?? trimmedLayout {
            let moved = preview.flatMap { trimmedZoom != nil ? zoomRange(trimmed.id, in: $0) : layoutRange(trimmed.id, in: $0) }
            if let moved {
                let now = trimmed.edge == .start ? moved.lowerBound : moved.upperBound
                label = (now - trimmed.output, now)
            } else {
                label = (0, trimmed.output)
            }
        }
        if let trimmed = trimmedPrivacy {
            let moved = preview.flatMap { TimelinePrivacyItems.range(of: trimmed.id, in: $0) }
            let now = moved.map { trimmed.edge == .start ? $0.lowerBound : $0.upperBound } ?? trimmed.output
            label = (now - trimmed.output, now)
        }
        view.setPreview(preview)
        if let label, let total = view.content?.map.duration {
            showLabel(TimelineDragRules.trimLabel(delta: label.delta, position: label.position, total: total, locale: .current), at: point.x)
        } else {
            hideLabel()
        }
    }

    /// Esc while the mouse is down (design §5.7): a drag that edits is given up, nothing made, and the timeline and the
    /// preview show the document again; the playhead stays where it was dragged, and the marks where they were put. The
    /// rest of the drag does nothing. Whether there was one.
    func cancelDrag() -> Bool {
        switch drag {
        case .none:
            return false
        case .playhead:
            view.endScrub()
        case .marks, .emptyZoom, .emptyLayout, .pressed:
            break
        case .trimClip, .trimZoom, .moveZoom, .createZoom, .moveCamera, .trimLayout, .moveLayout, .createLayout, .moveBoundary:
            lastStep = nil
            model?.cancelGesture()
            view.setPreview(nil)
        case .trimPrivacy, .movePrivacy:
            lastStep = nil
            model?.cancelGesture()
            view.setPreview(nil)
        }
        drag = .none
        hideLabel()
        return true
    }

    /// The mouse was released: the gesture's last step is made, once.
    private func finish() {
        guard let model else { return }
        let step = lastStep
        lastStep = nil
        let made = model.endGesture()
        if !made {
            view.setPreview(nil)
            return
        }
        // A block made or moved is the one selected (a moved automatic one is another, with a new id).
        guard let step else { return }
        switch drag {
        case .createZoom, .moveZoom: model.selection = .zooms([step.target])
        case .createLayout:
            model.selection = .layoutBlock(step.target)
            model.rememberBlockLayout(newBlockKind)
        case .moveLayout, .trimLayout: model.selection = .layoutBlock(step.target)
        case .movePrivacy, .trimPrivacy: model.selection = .privacyBlocks([step.target])
        default: break
        }
    }

    // MARK: - Labels

    private func showLabel(_ text: String, at x: Double) {
        let palette = view.palette
        dragLabel.string = text
        dragLabel.foregroundColor = palette.dragLabelText
        dragLabel.backgroundColor = palette.dragLabelFill
        dragLabel.contentsScale = Double(view.window?.backingScaleFactor ?? 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        let width = (text as NSString).size(withAttributes: attributes).width.rounded(.up) + 14
        let areaX = x - TimelineLayout.headerWidth
        let left = min(max(areaX + 10, 2), max(view.bounds.width - TimelineLayout.headerWidth - width - 2, 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragLabel.frame = CGRect(x: left, y: TimelineLayout.rulerHeight + 4, width: width, height: 18)
        dragLabel.opacity = 1
        CATransaction.commit()
    }

    private func hideLabel() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragLabel.opacity = 0
        CATransaction.commit()
    }

    /// A short message over the timeline's bottom left ("There has to be at least one clip.").
    func showNotice(_ text: String) {
        noticeTask?.cancel()
        let palette = view.palette
        noticeLabel.string = text
        noticeLabel.foregroundColor = palette.dragLabelText
        noticeLabel.backgroundColor = palette.dragLabelFill
        noticeLabel.contentsScale = Double(view.window?.backingScaleFactor ?? 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        let width = (text as NSString).size(withAttributes: attributes).width.rounded(.up) + 16
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        noticeLabel.frame = CGRect(x: 8, y: max(view.bounds.height - 30, 0), width: width, height: 22)
        noticeLabel.opacity = 1
        CATransaction.commit()
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: text])
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.noticeLabel.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = reduce ? Motion.reducedMotionFade.timeInterval : 0.3
            self.noticeLabel.add(fade, forKey: "fade")
        }
    }

    // MARK: - Menus

    /// The context menu of what is under the mouse (design §5.5): a clip's (speed, split, delete), a block's (depth, focus,
    /// instant, delete), a screen's ("Show «name»", follow the cursor) and a camera change's (delete). The item is
    /// selected first, unless it is in the selection.
    func menu(for event: NSEvent) -> NSMenu? {
        guard let model, view.content != nil else { return nil }
        let point = point(event)
        guard point.x >= TimelineLayout.headerWidth else { return nil }
        let hit = hit(at: point)
        let τ = clamped(output(at: point))
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch hit {
        case let .item(.video, id), let .edge(.video, id, _):
            if !selectedIDs.contains(id) { select(hit, shift: false) }
            addClipItems(to: menu, at: τ)
        case let .item(.zoom, id), let .edge(.zoom, id, _):
            if !selectedIDs.contains(id) { select(hit, shift: false) }
            addZoomItems(to: menu, id: id)
        case let .item(.screen, id), let .edge(.screen, id, _):
            select(hit, shift: false)
            addScreenItems(to: menu, id: id)
        case let .item(.camera, id) where isLayoutBlock(id), let .edge(.camera, id, _) where isLayoutBlock(id):
            select(hit, shift: false)
            addLayoutItems(to: menu, id: id)
        case let .item(.privacy, id), let .edge(.privacy, id, _):
            if !selectedIDs.contains(id) { select(hit, shift: false) }
            addPrivacyItems(to: menu, id: id)
        case let .item(.camera, id), let .edge(.camera, id, _):
            select(hit, shift: false)
            let delete = MenuAction(String(localized: "Delete Change")) { model.deleteCameraChange(id) }
            delete.isEnabled = canEdit
            menu.addItem(delete)
        default:
            return nil
        }
        return menu
    }

    private func addClipItems(to menu: NSMenu, at τ: Int64) {
        guard let model else { return }
        let speeds = NSMenu()
        speeds.autoenablesItems = false
        let current = model.speedOfTargets
        for speed in SequenceCommands.speedPresets {
            let item = MenuAction(TimelineFormat.multiplier(speed)) { model.setSpeed(speed) }
            item.state = current == speed ? .on : .off
            item.isEnabled = canEdit
            speeds.addItem(item)
        }
        speeds.addItem(.separator())
        let custom = MenuAction(String(localized: "Custom Speed…")) { [weak self] in self?.askCustomSpeed() }
        custom.isEnabled = canEdit
        speeds.addItem(custom)
        speeds.addItem(TimelineBar.speedNote())
        let speedItem = NSMenuItem(title: String(localized: "Speed"), action: nil, keyEquivalent: "")
        speedItem.submenu = speeds
        speedItem.isEnabled = canEdit
        menu.addItem(speedItem)
        let split = MenuAction(String(localized: "Split")) { model.split(atOutput: τ) }
        split.isEnabled = canEdit
        menu.addItem(split)
        let typing = MenuAction(String(localized: "Speed Up Typing…")) { model.askTypingSpeed() }
        typing.isEnabled = canEdit
        menu.addItem(typing)
        menu.addItem(.separator())
        let delete = MenuAction(String(localized: "Delete")) { [weak self] in self?.deleteSelected() }
        delete.isEnabled = canEdit
        menu.addItem(delete)
    }

    private func addZoomItems(to menu: NSMenu, id: String) {
        guard let model, let document = model.document, let region = document.zoom.regions.first(where: { $0.id == id }) else { return }
        let depth = NSMenu()
        depth.autoenablesItems = false
        let current = region.depth ?? document.zoom.auto.depth
        for value in [1.25, 1.5, 2, 2.5, 3, 4] {
            let item = MenuAction(TimelineFormat.multiplier(value)) { model.changeZoom(id, depth: .some(value)) }
            item.state = abs(current - value) < 0.001 ? .on : .off
            item.isEnabled = canEdit
            depth.addItem(item)
        }
        let depthItem = NSMenuItem(title: String(localized: "Depth"), action: nil, keyEquivalent: "")
        depthItem.submenu = depth
        depthItem.isEnabled = canEdit
        menu.addItem(depthItem)

        let focus = NSMenu()
        focus.autoenablesItems = false
        let follows = MenuAction(String(localized: "Follow the Cursor")) { model.changeZoom(id, focus: .follow) }
        follows.state = region.focus == .follow ? .on : .off
        let center = MenuAction(String(localized: "Center of the Screen")) { model.changeZoom(id, focus: .fixed(x: 0.5, y: 0.5)) }
        center.state = region.focus == .fixed(x: 0.5, y: 0.5) ? .on : .off
        for item in [follows, center] {
            item.isEnabled = canEdit
            focus.addItem(item)
        }
        let focusItem = NSMenuItem(title: String(localized: "Focus"), action: nil, keyEquivalent: "")
        focusItem.submenu = focus
        focusItem.isEnabled = canEdit
        menu.addItem(focusItem)

        let instant = MenuAction(String(localized: "Instant")) { model.changeZoom(id, instant: !region.instant) }
        instant.state = region.instant ? .on : .off
        instant.isEnabled = canEdit
        menu.addItem(instant)
        menu.addItem(.separator())
        let delete = MenuAction(String(localized: "Delete Zoom")) { [weak self] in self?.deleteSelected() }
        delete.isEnabled = canEdit
        menu.addItem(delete)
    }

    /// The menu of a layout block (design §5.5): the five layouts, the camera's side and automatic size when it is a split,
    /// instant transition and delete.
    private func addLayoutItems(to menu: NSMenu, id: String) {
        guard let model, let document = model.document, let block = document.camera.layouts.first(where: { $0.id == id }),
            let range = layoutRange(id, in: document)
        else { return }
        let target = LayoutEditTarget.block(id: id, output: range.lowerBound)
        for kind in LayoutNames.order {
            let item = MenuAction(LayoutNames.name(kind)) { model.setLayoutKind(kind, target: target) }
            item.image = NSImage(
                systemSymbolName: LayoutTrackRules.symbol(kind, orientation: view.content?.splitOrientation ?? .beside),
                accessibilityDescription: nil)
            item.state = block.kind == kind ? .on : .off
            item.isEnabled = canEdit
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let isSplit = block.kind == .split
        let sides = NSMenu()
        sides.autoenablesItems = false
        let split = block.split ?? SplitLayout(side: .end)
        let beside = view.content?.splitOrientation != .stacked
        for (side, title) in [
            (CameraSide.start, beside ? String(localized: "Left") : String(localized: "Top")),
            (.end, beside ? String(localized: "Right") : String(localized: "Bottom")),
        ] {
            let item = MenuAction(title) { model.setSplitSide(side, id: id) }
            item.state = split.side == side ? .on : .off
            item.isEnabled = canEdit
            sides.addItem(item)
        }
        let sideItem = NSMenuItem(title: String(localized: "Camera Side"), action: nil, keyEquivalent: "")
        sideItem.submenu = sides
        sideItem.isEnabled = canEdit && isSplit
        menu.addItem(sideItem)
        let automatic = MenuAction(String(localized: "Automatic Size")) { model.setSplitShare(percent: nil, id: id) }
        automatic.state = isSplit && split.share == nil ? .on : .off
        automatic.isEnabled = canEdit && isSplit && split.share != nil
        menu.addItem(automatic)
        let instant = MenuAction(String(localized: "Instant Transition")) { model.setLayoutInstant(id, !block.instant) }
        instant.state = block.instant ? .on : .off
        instant.isEnabled = canEdit
        menu.addItem(instant)
        menu.addItem(.separator())
        let delete = MenuAction(String(localized: "Delete Block")) { [weak self] in self?.deleteSelected() }
        delete.isEnabled = canEdit
        menu.addItem(delete)
    }

    /// The same menu at `point` of the timeline, for VoiceOver's "Change Layout": the block is selected first.
    func popLayoutMenu(id: String, at point: CGPoint) {
        guard let model, view.content != nil else { return }
        model.selection = .layoutBlock(id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        addLayoutItems(to: menu, id: id)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func addScreenItems(to menu: NSMenu, id: String) {
        guard let model, let item = item(id), let project = model.overlayProject,
            let shown = view.content?.screens.items.first(where: { $0.id == id })
        else { return }
        let screens = project.take.tracks.filter { $0.kind.isScreen && !$0.segments.isEmpty }
        for screen in screens where screen.source.name != shown.info.name {
            let show = MenuAction(String(format: String(localized: "Show “%@”"), screen.source.name)) {
                model.showScreen(screen.id, over: item.output)
            }
            show.isEnabled = canEdit
            menu.addItem(show)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let follow = MenuAction(String(
            localized: "screen.followCursor", comment: "The screen track's menu: the screens shown follow the cursor (not a zoom's focus)")
        ) { model.followCursor() }
        follow.isEnabled = canEdit
        menu.addItem(follow)
    }

    // MARK: - Actions

    /// "Delete": what is selected; the last clip cannot be.
    func deleteSelected() {
        guard let model else { return }
        if model.deleteSelection() == .lastClip { showNotice(String(localized: "There has to be at least one clip.")) }
    }

    /// "Custom Speed…": a sheet that asks for a speed from 0.25× to 16×.
    func askCustomSpeed() {
        guard let model, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Custom Speed")
        alert.informativeText = String(localized: "From 0.25× to 16×.") + " " + String(localized: "Up to 4× the sound speeds up without changing pitch; faster, the clip has no sound.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        // In the user's language ("1,5"), rounded for display only: left as it is, nothing changes (`CustomSpeedEntry`).
        let entry = CustomSpeedEntry(shown: TimelineFormat.number(model.speedOfTargets ?? 1))
        field.stringValue = entry.shown
        field.setAccessibilityLabel(String(localized: "Speed"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, let speed = entry.speed(from: field.stringValue) else { return }
            MainActor.assumeIsolated { model.setSpeed(speed) }
        }
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
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

// MARK: - The model's editing of the timeline

/// What the buttons of the track bar, the menus and (Task 42) the keys do to the document: each one reads the selection
/// and the playhead, and makes one step of the commands, or none.
enum TimelineEditResult {
    case done
    case nothing
    /// Nothing was deleted: it would leave no clip.
    case lastClip
}

extension EditorModel {
    /// The clips a speed applies to: those selected, or the one under the playhead.
    var speedTargets: Set<String> {
        if case let .clips(ids)? = selection { return ids }
        guard let document, let (k, _) = TimeMap(sequence: document.sequence).source(atOutput: playheadNanoseconds) else { return [] }
        return [document.sequence[k].id]
    }

    /// The speed all of `speedTargets` play at; `nil` if there is none or they differ.
    var speedOfTargets: Double? {
        guard let document else { return nil }
        let speeds = Set(document.sequence.filter { speedTargets.contains($0.id) }.map { ClipSpeed.clamped($0.speed) })
        return speeds.count == 1 ? speeds.first : nil
    }

    /// "Split" (the bar, C and ⌘B): the two edges of the marked range, or the playhead.
    @discardableResult
    func splitAtPlayhead() -> Bool {
        guard canEdit, let document else { return false }
        let step: EditStep?
        if let start = timelineMarks.in, let end = timelineMarks.out, start < end {
            step = SequenceCommands.split(document, range: start..<end, makeID: Self.newID)
        } else {
            step = SequenceCommands.split(document, atOutput: playheadNanoseconds, makeID: Self.newID)
        }
        guard let step else { return false }
        return perform(step) != .refused
    }

    /// "Split" from the clip's menu: at output time `output`.
    func split(atOutput output: Int64) {
        guard canEdit, let document, let step = SequenceCommands.split(document, atOutput: output, makeID: Self.newID) else { return }
        perform(step)
    }

    /// Deletes what is selected: clips (the sequence closes the gap), zoom blocks, a camera change, or a layout block.
    @discardableResult
    func deleteSelection() -> TimelineEditResult {
        guard canEdit, let document else { return .nothing }
        let step: EditStep?
        switch selection {
        case let .clips(ids)?:
            switch SequenceCommands.delete(document, clipIDs: ids) {
            case .failure(.lastClip): return .lastClip
            case let .success(deleted): step = deleted.changes.isEmpty ? nil : deleted
            }
        case let .zooms(ids)?:
            step = ZoomCommands.delete(document, ids: ids)
        case let .cameraChange(id)?:
            step = TrackCommands.deleteCameraChange(document, id: id)
        case let .layoutBlock(id)?:
            step = LayoutCommands.delete(document, ids: [id])
        case let .privacyBlocks(ids)?:
            step = PrivacyCommands.delete(document, ids: ids)
        case .screenChange?, nil:
            step = nil
        }
        guard let step else { return .nothing }
        return perform(step) == .refused ? .nothing : .done
    }

    /// Plays the clips of `speedTargets` at `speed` (0.25× to 16×).
    func setSpeed(_ speed: Double) {
        guard canEdit, let document, let step = SequenceCommands.setSpeed(document, clipIDs: speedTargets, speed: speed) else { return }
        perform(step)
    }

    /// "Add Zoom": a block of 3 s centred on the playhead, or on `output`; it is the selected one.
    func addZoom(at output: Int64? = nil) {
        guard canEdit, let document,
            let step = ZoomCommands.addCentered(document, at: output ?? playheadNanoseconds, makeID: Self.newID),
            perform(step) != .refused
        else { return }
        selection = .zooms([step.target])
    }

    /// "Show «name»": screen track `track` over the output range `output`.
    func showScreen(_ track: String, over output: Range<Int64>) {
        guard canEdit, let document,
            let step = TrackCommands.showScreen(
                document, track: track, forOutput: output, timeMap: TimeMap(sequence: document.sequence), makeID: Self.newID)
        else { return }
        perform(step)
    }

    /// "Follow the Cursor": the screens regenerated, planned off the main thread (it reads every event of the take and
    /// looks at each segment's file), as the automatic zooms are; planned again from the document as it is then if it
    /// changed meanwhile.
    func followCursor() {
        guard canEdit, followCursorTask == nil else { return }
        followCursorTask = Task {
            defer { followCursorTask = nil }
            while !closed, canEdit, let document, let project = overlayProject {
                let step = await Task.detached { TrackCommands.followCursor(document, project: project) }.value
                guard self.document == document else { continue }
                if !step.changes.isEmpty { perform(step) }
                break
            }
        }
    }
}
