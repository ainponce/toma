// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// What the Captions track knows of a caption (phase 2 design §5.2): its text and its words with where each is said.
struct CaptionInfo {
    /// The lines joined by a space: what the block shows and VoiceOver reads.
    var text: String
    var words: [(ref: TranscriptWordRef, output: Range<Int64>)]

    /// The word said at output time `τ`, or the first one.
    func word(at τ: Int64) -> TranscriptWordRef? {
        (words.first { $0.output.contains(τ) } ?? words.first)?.ref
    }
}

enum TimelineCaptionItems {
    /// The captions of `document` for the track: one per caption, ids `cap-<n>`, in order.
    static func items(document: EditDocument, map: TimeMap, outputSize: SIMD2<Int>) -> TrackItems<CaptionInfo> {
        guard document.transcript != nil else { return TrackItems([]) }
        let captions = CaptionLines.captions(of: document, timeMap: map, outputSize: outputSize)
        return TrackItems(captions.enumerated().map { n, caption in
            .init(
                id: "cap-\(n)", output: caption.output,
                info: CaptionInfo(
                    text: caption.text.replacingOccurrences(of: "\n", with: " "),
                    words: caption.lines.flatMap { $0 }.map { ($0.ref, $0.output) }))
        })
    }

    /// What VoiceOver reads of a caption: "Subtítulo «hola mundo», de 0:12 a 0:15".
    static func accessibilityLabel(_ info: CaptionInfo, output: Range<Int64>) -> String {
        String(
            format: String(localized: "Caption “%1$@”, from %2$@ to %3$@", comment: "VoiceOver: a caption of the timeline's Captions track, its text, start and end"),
            info.text, Timecode.duration(Double(output.lowerBound) / 1e9), Timecode.duration(Double(output.upperBound) / 1e9))
    }
}

/// A caption's block: a rounded fill and its text on one line, cut with an ellipsis where the block ends.
final class CaptionBlockLayer: CAShapeLayer {
    let label = CATextLayer()
    var labelText: String?
    var drawnSize = CGSize.zero
    var output: Range<Int64> = 0..<0
    var isCurrent: Bool?

    override init() {
        super.init()
        lineWidth = 1
        TimelineText.setUp(label, size: 10, weight: .medium)
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

/// Draws the Captions row (`TimelineTracks` calls it inside its update, without actions): one layer per caption in sight,
/// from a pool (thousands of captions cost only what is on screen), the one under the playhead highlighted. The row is not
/// selected, dragged or trimmed: the captions follow the words.
@MainActor
final class CaptionTrackLayers {
    /// The row's blocks, over the rows' whole area (a sublayer of the rows, scrolled with them).
    let layer = CALayer()
    private let blocks: LayerPool<CaptionBlockLayer>
    private var tint: (background: CGColor, increaseContrast: Bool, tint: TimelinePalette.Tint)?
    /// The blocks laid out by the last pass, and the colors they were styled with, so the playhead can move the highlight
    /// over them without laying the row out again.
    private var shown: [CaptionBlockLayer] = []
    private var colors: (tint: TimelinePalette.Tint, selection: CGColor, border: CGColor)?

    init() {
        blocks = LayerPool(parent: layer) { CaptionBlockLayer() }
    }

    func begin() {
        blocks.begin()
        shown.removeAll(keepingCapacity: true)
    }

    func end() {
        blocks.end()
    }

    func reset() {
        blocks.removeAll()
        shown = []
        tint = nil
        colors = nil
    }

    var layerCount: Int { blocks.shownCount }

    /// `playhead`: the output time under the playhead, whose caption is highlighted.
    func layOut(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        playhead: Int64
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        let tint = tint(palette)
        let top = row.top + 3, height = row.height - 6
        let (lower, upper) = geometry.visibleOutput
        colors = (tint, palette.selection, palette.increaseContrast ? palette.contrastBorder : tint.stroke)
        defer { highlight(playhead: playhead) }
        content.captions.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (block, isNew) = blocks.layer(item.id)
            if isNew {
                block.label.contentsScale = geometry.backingScale
                block.label.foregroundColor = tint.text
            }
            block.output = item.output
            block.isCurrent = nil
            shown.append(block)
            block.frame = rect
            if block.drawnSize != rect.size {
                block.drawnSize = rect.size
                let radius = min(5, rect.width / 2, rect.height / 2)
                block.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(radius - 0.5, 0),
                    cornerHeight: max(radius - 0.5, 0), transform: nil)
            }
            if block.labelText != item.info.text {
                block.labelText = item.info.text
                block.label.string = item.info.text
            }
            // The text stays at the left of what is in sight.
            let left = max(6, -rect.minX + 6)
            block.label.frame = CGRect(x: left, y: (height - 13) / 2, width: max(rect.width - left - 4, 0), height: 13)
            block.label.isHidden = rect.width < 24
        }
    }

    /// Highlights the caption shown at output time `playhead` among those in sight (the playhead moved; nothing is laid out).
    func highlight(playhead: Int64) {
        guard let colors else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for block in shown {
            let current = block.output.contains(playhead)
            guard block.isCurrent != current else { continue }
            block.isCurrent = current
            block.fillColor = current ? colors.tint.selectedFill : colors.tint.fill
            block.strokeColor = current ? colors.selection : colors.border
            block.lineWidth = current ? 2 : 1
        }
    }

    /// The track's hue made opaque over the timeline's background.
    private func tint(_ palette: TimelinePalette) -> TimelinePalette.Tint {
        if let tint, tint.background == palette.background, tint.increaseContrast == palette.increaseContrast { return tint.tint }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        var made: TimelinePalette.Tint?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let hue = NSColor.systemIndigo.usingColorSpace(.sRGB) ?? .systemIndigo
            func over(_ fraction: CGFloat) -> CGColor { (background.blended(withFraction: fraction, of: hue) ?? hue).cgColor }
            let text = dark ? hue.blended(withFraction: 0.65, of: .white) ?? .white : hue.blended(withFraction: 0.55, of: .black) ?? .black
            made = TimelinePalette.Tint(
                fill: over(dark ? 0.28 : 0.22), selectedFill: over(dark ? 0.46 : 0.38),
                stroke: hue.withAlphaComponent(dark ? 0.55 : 0.7).cgColor, text: text.cgColor)
        }
        let result = made ?? TimelinePalette.Tint(
            fill: palette.clipFill, selectedFill: palette.clipFill, stroke: palette.separator, text: palette.label)
        self.tint = (palette.background, palette.increaseContrast, result)
        return result
    }
}
