// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// The Annotations track of one revision of the document (phase 3 design §5.6, plan 3a decision 17): a block for each
/// annotation where the output shows it (`AnnotationTrackRules`), in lanes when they overlap, and those of the whole video
/// as a thin bar on top; one all in a cut is not there.
struct TimelineAnnotationItems {
    struct Info {
        /// Its kind's symbol (plan 3a decision 20) and what the block says: a text's or a speech bubble's string, a step's
        /// number, the kind's name for the others.
        var symbol: String
        var title: String
        /// "Texto «Hola»", "Paso 2", "Flecha": what VoiceOver reads first.
        var name: String
        /// Anchored to the take ("pegada a la grabación"): the block has a pin.
        var pinned: Bool
        var lane: Int
        var whole: Bool
        /// Its place in the drawing, bottom to top.
        var rank: Int
    }

    /// In the order of their start, for what is in sight.
    let items: TrackItems<Info>
    /// The blocks bottom to top, as the mouse points at them (`AnnotationTrackRules.hit`).
    let hitOrder: [AnnotationTrackRules.Item]
    /// The lanes the row has and whether it has the bar.
    let lanes: Int
    let bar: Bool
    private let byID: [String: AnnotationTrackRules.Item]

    init(document: EditDocument, map: TimeMap) {
        hitOrder = AnnotationTrackRules.items(document)
        (lanes, bar) = AnnotationTrackRules.shape(of: hitOrder)
        byID = Dictionary(hitOrder.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !hitOrder.isEmpty else {
            items = TrackItems([])
            return
        }
        let numbers = StepNumbering.numbers(in: document, timeMap: map)
        let annotations = Dictionary(document.annotations.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = TrackItems(hitOrder.enumerated().compactMap { rank, shown in
            guard let annotation = annotations[shown.item.id] else { return nil }
            let (title, name) = Self.titleAndName(annotation, number: numbers[annotation.id])
            var pinned = false
            if case .content = annotation.anchor { pinned = true }
            return .init(
                id: shown.item.id, output: shown.item.output,
                info: Info(
                    symbol: Self.symbol(annotation.kind), title: title, name: name, pinned: pinned, lane: shown.lane,
                    whole: shown.whole, rank: rank))
        })
    }

    /// The block of annotation `id`, its lane and whether it is the bar; `nil` if the track does not show it.
    func item(_ id: String) -> AnnotationTrackRules.Item? {
        byID[id]
    }

    /// Where the row from `rowTop`, `rowHeight` tall, draws annotation `id`: its band (top and height).
    func band(of id: String, rowTop: Double, rowHeight: Double) -> (top: Double, height: Double)? {
        guard let shown = byID[id] else { return nil }
        return AnnotationTrackRules.band(
            lane: shown.whole ? nil : shown.lane, lanes: lanes, bar: bar, rowTop: rowTop, rowHeight: rowHeight)
    }

    /// What is at `point` (the timeline's own coordinates, the rows' scroll added below the ruler) when it is on the
    /// Annotations row of `layout`: a block or its edge, in its lane, or the row's empty place at that time.
    func hit(at point: CGPoint, layout: TimelineLayout, scale: Double, offset: Double) -> TimelineHit? {
        var top = TimelineLayout.rulerHeight
        for row in layout.tracks where row.track != .ruler {
            if row.track == .annotations {
                guard Double(point.y) >= top, Double(point.y) < top + row.height else { return nil }
                guard let found = AnnotationTrackRules.hit(
                    at: point, items: hitOrder, rowTop: top, rowHeight: row.height, scale: scale, offset: offset)
                else { return .empty(.annotations, output: layout.output(atX: point.x, scale: scale, offset: offset)) }
                return found.edge.map { .edge(.annotations, id: found.id, $0) } ?? .item(.annotations, id: found.id)
            }
            top += row.height
        }
        return nil
    }

    /// Where the output shows annotation `id` of `document` on the track (cut at its end); `nil` without one or if it
    /// shows nothing.
    static func range(of id: String, in document: EditDocument) -> Range<Int64>? {
        guard let annotation = document.annotations.items.first(where: { $0.id == id }) else { return nil }
        let map = TimeMap(sequence: document.sequence)
        guard let range = AnnotationTiming.outputRange(of: annotation, document: document, timeMap: map),
            range.lowerBound < map.duration
        else { return nil }
        let output = range.lowerBound..<min(range.upperBound, map.duration)
        return output.isEmpty ? nil : output
    }

    /// Whether annotation `id` of `document` is of the whole video (which neither moves nor trims).
    static func isWhole(_ id: String, in document: EditDocument) -> Bool {
        guard let annotation = document.annotations.items.first(where: { $0.id == id }) else { return false }
        if case .whole = annotation.anchor { return true }
        return false
    }

    /// The symbol of each kind (plan 3a decision 20).
    static func symbol(_ kind: AnnotationKind) -> String {
        switch kind {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .shape: "square.on.circle"
        case .callout: "bubble.left"
        case .step: "1.circle"
        case .image: "photo"
        case .clip: "film"
        }
    }

    /// What the block says and what VoiceOver reads of it: a text "Hola" and "Texto «Hola»", a step "Paso 2", an arrow
    /// "Flecha".
    private static func titleAndName(_ annotation: Annotation, number: Int?) -> (title: String, name: String) {
        func quoted(_ string: String) -> String? {
            let line = string.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        switch annotation.kind {
        case let .text(text):
            let kind = String(localized: "Text")
            guard let line = quoted(text.string) else { return (kind, kind) }
            return (line, String(format: String(localized: "Text “%@”", comment: "VoiceOver: a text annotation of the timeline and its words"), line))
        case let .callout(callout):
            let kind = String(localized: "Callout", comment: "An annotation: a text in a speech bubble with a tail that points at something")
            guard let line = quoted(callout.text.string) else { return (kind, kind) }
            return (line, String(format: String(localized: "Callout “%@”", comment: "VoiceOver: a speech bubble annotation of the timeline and its words"), line))
        case .step:
            let name = String(localized: "Step \(number ?? 1)", comment: "A step annotation and its number: a number in a circle")
            return (name, name)
        case .arrow:
            let name = String(localized: "Arrow", comment: "An annotation: an arrow")
            return (name, name)
        case .shape:
            let name = String(localized: "Shape")
            return (name, name)
        case .image:
            let name = String(localized: "Image")
            return (name, name)
        case .clip:
            let name = String(localized: "Clip", comment: "An annotation: an imported video over the video")
            return (name, name)
        }
    }

    /// What VoiceOver reads of a block: "Texto «Hola», de 0:12 a 0:15".
    static func accessibilityLabel(_ info: Info, output: Range<Int64>) -> String {
        String(
            format: String(localized: "%1$@, from %2$@ to %3$@", comment: "VoiceOver: a privacy block of the timeline, its effect, start and end"),
            info.name, Timecode.duration(Double(output.lowerBound) / 1e9), Timecode.duration(Double(output.upperBound) / 1e9))
    }
}

/// An annotation's block: filled with the track's hue, opaque so the one over it hides it, a border of the hue and a
/// lighter top edge; its kind's symbol and what it says, and a pin when it is anchored to the take.
final class AnnotationBlockLayer: CAShapeLayer {
    let label = CATextLayer()
    let icon = CALayer()
    let pin = CALayer()
    let highlight = CALayer()
    var labelText: String?
    var symbol: String?
    var pinColor: CGColor?
    var drawnSize = CGSize.zero

    override init() {
        super.init()
        lineWidth = 1
        TimelineText.setUp(label, size: 10, weight: .semibold)
        icon.contentsGravity = .resizeAspect
        pin.contentsGravity = .resizeAspect
        addSublayer(highlight)
        addSublayer(icon)
        addSublayer(label)
        addSublayer(pin)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Draws the Annotations row (`TimelineTracks` calls it inside its update, without actions): one layer per annotation in
/// sight, from a pool, in its lane, the bar of the whole video on top; selected, a stronger fill and an outline in the
/// accent color. After an edit the blocks settle into their places with `Motion.trackItem`, as the privacy blocks do.
@MainActor
final class TimelineAnnotationsRow {
    /// The row's blocks, over the rows' whole area (a sublayer of the rows, scrolled with them).
    let layer = CALayer()
    private let blocks: LayerPool<AnnotationBlockLayer>
    private let bars: LayerPool<CALayer>
    /// The track's colors, made for the palette they were made with.
    private var tint: (background: CGColor, increaseContrast: Bool, tint: TimelinePalette.Tint)?
    private static var symbols: [String: CGImage] = [:]

    init() {
        blocks = LayerPool(parent: layer) { AnnotationBlockLayer() }
        bars = LayerPool(parent: layer) {
            let bar = CALayer()
            bar.cornerRadius = AnnotationTrackRules.barHeight / 2
            return bar
        }
    }

    /// Starts a pass of `TimelineTracks.update`; the blocks not laid out by its end are hidden (the row may be gone).
    func begin() {
        blocks.begin()
        bars.begin()
    }

    func end() {
        blocks.end()
        bars.end()
    }

    /// Forgets the layers and the colors (the appearance changed).
    func reset() {
        blocks.removeAll()
        bars.removeAll()
        tint = nil
    }

    var layerCount: Int { blocks.shownCount + bars.shownCount }

    func layOut(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        selected: Set<String>, settling: Bool
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        let tint = tint(palette)
        let annotations = content.annotations
        let (lower, upper) = geometry.visibleOutput
        annotations.items.forEach(from: lower, to: upper) { item in
            guard let band = annotations.band(of: item.id, rowTop: row.top, rowHeight: row.height),
                let rect = geometry.itemRect(item.output, top: band.top, height: band.height, gap: 1)
            else { return }
            let isSelected = selected.contains(item.id)
            if item.info.whole {
                let (bar, isNew) = bars.layer(item.id)
                bar.zPosition = CGFloat(item.info.rank)
                bar.backgroundColor = isSelected ? palette.selection : tint.stroke
                Self.place(bar, rect, isNew: isNew, settling: settling)
                return
            }
            let (block, isNew) = blocks.layer(item.id)
            if isNew {
                block.label.contentsScale = geometry.backingScale
                block.icon.contentsScale = geometry.backingScale
                block.pin.contentsScale = geometry.backingScale
                block.label.foregroundColor = tint.text
                block.highlight.backgroundColor = palette.highlight
                block.symbol = nil
                block.pinColor = nil
            }
            block.zPosition = CGFloat(item.info.rank)
            block.fillColor = isSelected ? tint.selectedFill : tint.fill
            block.strokeColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : tint.stroke)
            block.lineWidth = isSelected ? 2 : 1
            let previousPath = block.path
            Self.place(block, rect, isNew: isNew, settling: settling)
            let radius = min(4, rect.width / 2, rect.height / 2)
            if block.drawnSize != rect.size {
                block.drawnSize = rect.size
                block.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(radius - 0.5, 0),
                    cornerHeight: max(radius - 0.5, 0), transform: nil)
                if settling, !isNew, let previousPath, let path = block.path {
                    let morph = CASpringAnimation(keyPath: "path", spring: Motion.trackItem)
                    morph.fromValue = previousPath
                    morph.toValue = path
                    block.add(morph, forKey: "settleShape")
                }
            }
            if block.symbol != item.info.symbol {
                block.symbol = item.info.symbol
                block.icon.contents = Self.symbolImage(item.info.symbol, scale: geometry.backingScale, color: tint.text)
            }
            if block.labelText != item.info.title {
                block.labelText = item.info.title
                block.label.string = item.info.title
            }
            if item.info.pinned, block.pinColor != tint.text {
                block.pinColor = tint.text
                block.pin.contents = Self.symbolImage("pin", scale: geometry.backingScale, color: tint.text)
            }
            // The symbol and the text stay at the left of what is in sight, the pin at its right.
            let height = rect.height
            let left = max(6, -rect.minX + 6)
            let right = min(rect.width, geometry.areaWidth - rect.minX) - 5
            let pinned = item.info.pinned && right - left >= 40
            block.pin.isHidden = !pinned
            block.pin.frame = CGRect(x: right - 10, y: (height - 10) / 2, width: 10, height: 10)
            block.icon.isHidden = rect.width < 24
            block.icon.frame = CGRect(x: left, y: (height - 11) / 2, width: 11, height: 11)
            let textRight = pinned ? right - 13 : right
            block.label.frame = CGRect(x: left + 15, y: (height - 13) / 2, width: max(textRight - left - 15, 0), height: 13)
            block.label.isHidden = rect.width < 44
            let inset = max(radius, 1)
            block.highlight.isHidden = rect.width < 2 * inset + 2
            block.highlight.frame = CGRect(x: inset, y: 1, width: max(rect.width - 2 * inset, 0), height: 1 / geometry.backingScale)
        }
    }

    /// The track's hue, orange (between the indigo of the captions and the teal of the zoom), made opaque over the
    /// timeline's background: blocks one over another hide each other's words instead of mixing them.
    private func tint(_ palette: TimelinePalette) -> TimelinePalette.Tint {
        if let tint, tint.background == palette.background, tint.increaseContrast == palette.increaseContrast { return tint.tint }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        var made: TimelinePalette.Tint?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let hue = NSColor.systemOrange.usingColorSpace(.sRGB) ?? .systemOrange
            func over(_ fraction: CGFloat) -> CGColor { (background.blended(withFraction: fraction, of: hue) ?? hue).cgColor }
            let text = dark ? hue.blended(withFraction: 0.55, of: .white) ?? .white : hue.blended(withFraction: 0.6, of: .black) ?? .black
            made = TimelinePalette.Tint(
                fill: over(dark ? 0.26 : 0.24), selectedFill: over(dark ? 0.42 : 0.40),
                stroke: hue.withAlphaComponent(dark ? 0.62 : 0.8).cgColor, text: text.cgColor)
        }
        let result = made ?? TimelinePalette.Tint(
            fill: palette.clipFill, selectedFill: palette.clipFill, stroke: palette.separator, text: palette.label)
        self.tint = (palette.background, palette.increaseContrast, result)
        return result
    }

    /// Puts `layer` at `rect`; settling, it goes there from where it was with `Motion.trackItem`.
    private static func place(_ layer: CALayer, _ rect: CGRect, isNew: Bool, settling: Bool) {
        let from = layer.presentation()?.frame ?? layer.frame
        layer.frame = rect
        guard settling, !isNew, from != rect else { return }
        let move = CASpringAnimation(keyPath: "position", spring: Motion.trackItem)
        move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        move.toValue = NSValue(point: CGPoint(x: rect.midX, y: rect.midY))
        let grow = CASpringAnimation(keyPath: "bounds", spring: Motion.trackItem)
        grow.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        grow.toValue = NSValue(rect: CGRect(origin: .zero, size: rect.size))
        layer.add(move, forKey: "settleMove")
        layer.add(grow, forKey: "settleSize")
    }

    /// The symbol in `color`, at the block's text size, for a display of `scale` pixels per point.
    private static func symbolImage(_ name: String, scale: Double, color: CGColor) -> CGImage? {
        let key = "\(name)@\(scale) \(color.components ?? [])"
        if let image = symbols[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        let drawn = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scaleByX: scale, byY: scale)])
        if let drawn { symbols[key] = drawn }
        return drawn
    }
}

// MARK: - The menu

extension TimelineInteraction {
    /// The menu of an annotation (plan 3a, Task A12): Bring Forward, Send Backward, Bring to Front and Send to Back (of
    /// the one selected, each where it changes something), Duplicate and Delete Annotation, of the selection.
    func addAnnotationItems(to menu: NSMenu, id: String) {
        guard let model, let document = model.document else { return }
        var one: String?
        if case let .annotations(ids)? = model.selection, ids.count == 1 { one = ids.first }
        let moves: [(String, AnnotationCommands.LayerMove)] = [
            (String(localized: "Bring Forward", comment: "The menu of an annotation: one layer up, over the next one it overlaps"), .forward),
            (String(localized: "Send Backward", comment: "The menu of an annotation: one layer down, under the previous one it overlaps"), .backward),
            (String(localized: "Bring to Front", comment: "The menu of an annotation: over all of its group"), .front),
            (String(localized: "Send to Back", comment: "The menu of an annotation: under all of its group"), .back),
        ]
        for (title, move) in moves {
            let item = AnnotationMenuItem(title) { model.reorderSelectedAnnotation(move) }
            item.isEnabled = model.canEdit && one.flatMap { AnnotationCommands.reorder(document, id: $0, move) } != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let duplicate = AnnotationMenuItem(String(localized: "Duplicate")) { model.duplicateSelectedAnnotations() }
        duplicate.isEnabled = model.canEdit
        menu.addItem(duplicate)
        let delete = AnnotationMenuItem(String(localized: "Delete Annotation")) { model.deleteSelectedAnnotations() }
        delete.isEnabled = model.canEdit
        menu.addItem(delete)
    }
}

/// A menu item that runs a closure.
private final class AnnotationMenuItem: NSMenuItem {
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
