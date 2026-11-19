// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// The Privacy track of one revision of the document (phase 2 design §7.1, plan 2c decision 4): each privacy block where
/// the output shows it (`PrivacyTrackRules`), the longest at the bottom; one all in a cut is not there.
struct TimelinePrivacyItems {
    struct Info {
        var effect: PrivacyEffect
        /// Made by the search of sensitive data, not by hand.
        var automatic: Bool
        /// Its place in the drawing, bottom to top: the longest lowest.
        var rank: Int
    }

    /// In the order of their start, for what is in sight.
    let items: TrackItems<Info>
    /// The blocks as the mouse points at them, the longest first: the shortest under the pointer is the one found.
    let hitOrder: [TimelineItem]

    init(document: EditDocument) {
        hitOrder = document.privacy.blocks.isEmpty ? [] : PrivacyTrackRules.items(document)
        let blocks = Dictionary(document.privacy.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = TrackItems(hitOrder.enumerated().compactMap { rank, item in
            guard let block = blocks[item.id] else { return nil }
            return .init(
                id: item.id, output: item.output, info: Info(effect: block.effect, automatic: block.origin != .manual, rank: rank))
        })
    }

    /// Where the output shows block `id` of `document`; `nil` without one or if it shows nothing.
    static func range(of id: String, in document: EditDocument) -> Range<Int64>? {
        document.privacy.blocks.first { $0.id == id }.flatMap { PrivacyCommands.outputRange(of: $0, in: document) }
    }

    /// "Desenfoque", "Pixelado", "Relleno".
    static func name(_ effect: PrivacyEffect) -> String {
        switch effect {
        case .blur: String(localized: "Blur")
        case .pixelate:
            String(localized: "Pixelate", comment: "A privacy block's effect (the Privacy track and tab): the rectangle is drawn in big squares")
        case .fill:
            String(localized: "Fill", comment: "A privacy block's effect (the Privacy track and tab): the rectangle is covered with a plain color")
        }
    }

    /// The effect's symbol (plan 2c decision 21).
    static func symbol(_ effect: PrivacyEffect) -> String {
        switch effect {
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        case .fill: "rectangle.fill"
        }
    }

    /// What VoiceOver reads of a block: "Desenfoque, de 0:12 a 0:15" (with "Automático" for one the search made).
    static func accessibilityLabel(_ info: Info, output: Range<Int64>) -> String {
        let name = info.automatic ? name(info.effect) + ", " + String(localized: "Automatic") : name(info.effect)
        return String(
            format: String(localized: "%1$@, from %2$@ to %3$@", comment: "VoiceOver: a privacy block of the timeline, its effect, start and end"),
            name, Timecode.duration(Double(output.lowerBound) / 1e9), Timecode.duration(Double(output.upperBound) / 1e9))
    }
}

/// A privacy block of the track: filled with the track's hue, opaque so the one over it hides it, a border of the hue and
/// a lighter top edge; the effect's symbol (✦ for an automatic one) and its name.
final class PrivacyBlockLayer: CAShapeLayer {
    let label = CATextLayer()
    let icon = CALayer()
    let highlight = CALayer()
    var labelText: String?
    var symbol: String?
    var drawnSize = CGSize.zero

    override init() {
        super.init()
        lineWidth = 1
        TimelineText.setUp(label, size: 10, weight: .semibold)
        icon.contentsGravity = .resizeAspect
        addSublayer(highlight)
        addSublayer(icon)
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Draws the Privacy row (`TimelineTracks` calls it inside its update, without actions): one layer per block in sight,
/// from a pool, the longer ones under the shorter; selected, a stronger fill and an outline in the accent color. After an
/// edit the blocks settle into their places with `Motion.trackItem`, as the zoom blocks do.
@MainActor
final class TimelinePrivacyRow {
    /// The row's blocks, over the rows' whole area (a sublayer of the rows, scrolled with them).
    let layer = CALayer()
    private let blocks: LayerPool<PrivacyBlockLayer>
    /// The track's colors, made for the palette they were made with.
    private var tint: (background: CGColor, increaseContrast: Bool, tint: TimelinePalette.Tint)?
    private static var symbols: [String: CGImage] = [:]

    init() {
        blocks = LayerPool(parent: layer) { PrivacyBlockLayer() }
    }

    /// Starts a pass of `TimelineTracks.update`; the blocks not laid out by its end are hidden (the row may be gone).
    func begin() {
        blocks.begin()
    }

    func end() {
        blocks.end()
    }

    /// Forgets the layers and the colors (the appearance changed).
    func reset() {
        blocks.removeAll()
        tint = nil
    }

    var layerCount: Int { blocks.shownCount }

    func layOut(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        selected: Set<String>, settling: Bool
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        let tint = tint(palette)
        let top = row.top + 3, height = row.height - 6
        let (lower, upper) = geometry.visibleOutput
        content.privacy.items.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (block, isNew) = blocks.layer(item.id)
            if isNew {
                block.label.contentsScale = geometry.backingScale
                block.icon.contentsScale = geometry.backingScale
                block.label.foregroundColor = tint.text
                block.highlight.backgroundColor = palette.highlight
                block.symbol = nil
            }
            block.zPosition = CGFloat(item.info.rank)
            let isSelected = selected.contains(item.id)
            block.fillColor = isSelected ? tint.selectedFill : tint.fill
            block.strokeColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : tint.stroke)
            block.lineWidth = isSelected ? 2 : 1
            let previousPath = block.path
            Self.place(block, rect, isNew: isNew, settling: settling)
            let radius = min(5, rect.width / 2, rect.height / 2)
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
            let symbol = item.info.automatic ? "sparkles" : TimelinePrivacyItems.symbol(item.info.effect)
            if block.symbol != symbol {
                block.symbol = symbol
                block.icon.contents = Self.symbolImage(symbol, scale: geometry.backingScale, color: tint.text)
            }
            let text = TimelinePrivacyItems.name(item.info.effect)
            if block.labelText != text {
                block.labelText = text
                block.label.string = text
            }
            // The symbol and the name stay at the left of what is in sight.
            let left = max(6, -rect.minX + 6)
            block.icon.isHidden = rect.width < 24
            block.icon.frame = CGRect(x: left, y: (height - 11) / 2, width: 11, height: 11)
            block.label.frame = CGRect(x: left + 15, y: (height - 13) / 2, width: max(rect.width - left - 18, 0), height: 13)
            block.label.isHidden = rect.width < 56
            let inset = max(radius, 1)
            block.highlight.isHidden = rect.width < 2 * inset + 2
            block.highlight.frame = CGRect(x: inset, y: 1, width: max(rect.width - 2 * inset, 0), height: 1 / geometry.backingScale)
        }
    }

    /// The track's hue, yellow (what hides, as a caution), made opaque over the timeline's background: blocks one over
    /// another hide each other's names instead of mixing them.
    private func tint(_ palette: TimelinePalette) -> TimelinePalette.Tint {
        if let tint, tint.background == palette.background, tint.increaseContrast == palette.increaseContrast { return tint.tint }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        var made: TimelinePalette.Tint?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let hue = NSColor.systemYellow.usingColorSpace(.sRGB) ?? .systemYellow
            func over(_ fraction: CGFloat) -> CGColor { (background.blended(withFraction: fraction, of: hue) ?? hue).cgColor }
            let text = dark ? hue.blended(withFraction: 0.55, of: .white) ?? .white : hue.blended(withFraction: 0.55, of: .black) ?? .black
            made = TimelinePalette.Tint(
                fill: over(dark ? 0.26 : 0.30), selectedFill: over(dark ? 0.42 : 0.46),
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
    /// The menu of a privacy block (design §7.1): its effect (Blur · Pixelate · Fill), and Delete Blur, of the selection.
    func addPrivacyItems(to menu: NSMenu, id: String) {
        guard let model, let block = model.document?.privacy.blocks.first(where: { $0.id == id }) else { return }
        for effect in PrivacyEffect.allCases {
            let item = PrivacyMenuItem(TimelinePrivacyItems.name(effect)) { model.setPrivacyEffect(effect, id: id) }
            item.image = NSImage(systemSymbolName: TimelinePrivacyItems.symbol(effect), accessibilityDescription: nil)
            item.state = block.effect == effect ? .on : .off
            item.isEnabled = model.canEdit
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = PrivacyMenuItem(String(localized: "Delete Blur")) { [weak self] in self?.deleteSelected() }
        delete.isEnabled = model.canEdit
        menu.addItem(delete)
    }
}

/// A menu item that runs a closure.
private final class PrivacyMenuItem: NSMenuItem {
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
