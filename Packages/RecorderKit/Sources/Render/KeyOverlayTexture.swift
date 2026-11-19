// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreText
import Foundation
import Metal
import Synchronization

/// How the keys on screen are laid out, `keyOverlay-1` (phase 2 design §7.4, plan 2c decision 14), in whole pixels of
/// the output: `KeyOverlayScene` sizes its items with it and `KeyOverlayTexture` draws them with it, so a box is drawn
/// exactly as large as it is placed.
///
/// With `h` the height of a key (`KeyOverlayPlacement.capHeight`): the box is a key high and `padding` above and below
/// it (1.36 h), its corners `cornerFraction` of its height. A shortcut's keys are `h` square (a longer label, as `esc` or
/// `F12`, widens its key to fit it with `wordInset` at each side), `spacing` apart and `padding` from the box's sides,
/// their corners concentric with the box's. A pill's text is `textSize` and as far from the box's sides as its capitals
/// are from its top and bottom. Every edge, the keys' and the box's, is on a whole pixel, so they are sharp at any
/// size.
///
/// The labels are white semibold SF Pro (the system font; `fallbackFont` for the arrows it lacks: ↩ ⇥ ⇞ ⇟), ␣ drawn as
/// a bracket as wide as ⌘ in a stroke like theirs (`spacePath`: no font has one that matches), each centred across its
/// key on its ink. Letters, digits and ⌘ ⇧ ⌥ sit on one baseline, the one that centres the capitals down the key (a word
/// in small letters, `esc`, centres them instead); any other symbol (⌃, which sits high on it, the arrows, ␣) is centred
/// down the key on its ink. The pill's text sits on the baseline that centres its capitals down the box.
enum KeyOverlayMetrics {
    /// Fractions of the height of a key.
    static let padding = 0.18
    static let spacing = 0.15
    static let textSize = 0.6
    /// The size of a key's label of one character, and of a longer one.
    static let glyphSize = 0.54
    static let wordSize = 0.36
    /// The room at each side of a longer label in its key.
    static let wordInset = 0.24
    /// The corners' radius, a fraction of the box's height.
    static let cornerFraction = 0.22

    /// The symbols that sit on the letters' baseline: drawn from it to the capitals' height, they are centred with them.
    static let baselineSymbols: Set<String> = ["⌘", "⇧", "⌥"]
    /// The language the font is asked for, as the window title's (`TitleTexture.fontLanguage`): the same glyphs whatever
    /// language the system is set to.
    static let fontLanguage = "en"
    /// The weight of the system font, as AppKit's `NSFont.Weight.semibold` (`kCTFontWeightTrait`).
    static let semibold = 0.3
    /// Where the glyphs SF Pro lacks are taken from, before the system's own fallbacks: its bold has them all, in a stroke
    /// close to SF Pro's semibold (the system's fallback for ␣ is a thin Japanese font).
    static let fallbackFont = "LucidaGrande-Bold"

    /// A label: its text, its font size and the start of its baseline, in pixels of the box from its top-left corner
    /// (`y` down), whole pixels.
    struct Label: Equatable, Sendable {
        var text: String
        var fontSize: Double
        var origin: SIMD2<Double>
    }

    /// A key of a shortcut, in whole pixels of the box from its top-left corner.
    struct Cap: Equatable, Sendable {
        var origin: SIMD2<Int>
        var size: SIMD2<Int>
        var radius: Double
        var label: Label
    }

    /// A box laid out: its size in whole pixels, its corners, and its keys or its text.
    struct Layout: Equatable, Sendable {
        var size: SIMD2<Int>
        var radius: Double
        var caps: [Cap]
        var text: Label?
    }

    /// The system font in semibold at `size` pixels for `fontLanguage`, with `fallbackFont` first among its fallbacks;
    /// `nil` for a size that is not a positive number or if CoreText cannot make it.
    static func font(size: Double) -> CTFont? {
        guard size > 0, size.isFinite, let base = CTFontCreateUIFontForLanguage(.system, size, fontLanguage as CFString) else { return nil }
        let attributes: [CFString: Any] = [
            kCTFontTraitsAttribute: [kCTFontWeightTrait: semibold] as CFDictionary,
            kCTFontCascadeListAttribute: [CTFontDescriptorCreateWithNameAndSize(fallbackFont as CFString, size)] as CFArray,
        ]
        return CTFontCreateCopyWithAttributes(base, size, nil, CTFontDescriptorCreateWithAttributes(attributes as CFDictionary))
    }

    /// `text` set in `font`, white.
    static func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]))
    }

    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The box of `content` with keys `capHeight` pixels high, in whole pixels; zero when it cannot be laid out.
    static func size(of content: KeyOverlayContent, capHeight: Double) -> SIMD2<Double> {
        guard let frame = Frame(capHeight: capHeight) else { return .zero }
        switch content {
        case let .keys(labels):
            guard let widths = capWidths(of: labels, frame: frame) else { return .zero }
            return SIMD2(Double(frame.width(ofKeys: widths)), Double(frame.height))
        case let .text(text):
            guard let measured = pill(of: text, frame: frame) else { return .zero }
            return SIMD2(Double(measured.width), Double(frame.height))
        }
    }

    /// `content` laid out with keys `capHeight` pixels high: what `KeyOverlayTexture` draws. `nil` for nothing to draw
    /// (no key, no text) or a font CoreText cannot make.
    static func layout(of content: KeyOverlayContent, capHeight: Double) -> Layout? {
        guard let frame = Frame(capHeight: capHeight) else { return nil }
        let radius = cornerFraction * Double(frame.height)
        switch content {
        case let .keys(labels):
            guard let widths = capWidths(of: labels, frame: frame) else { return nil }
            let capRadius = max(radius - Double(frame.padding), 0)
            var x = frame.padding
            var caps: [Cap] = []
            for (text, width) in zip(labels, widths) {
                let origin = SIMD2(x, frame.padding), size = SIMD2(width, frame.cap)
                guard let label = label(text, in: origin, size, frame: frame) else { return nil }
                caps.append(Cap(origin: origin, size: size, radius: capRadius, label: label))
                x += width + frame.spacing
            }
            return Layout(size: SIMD2(frame.width(ofKeys: widths), frame.height), radius: radius, caps: caps, text: nil)
        case let .text(text):
            guard let measured = pill(of: text, frame: frame) else { return nil }
            return Layout(size: SIMD2(measured.width, frame.height), radius: radius, caps: [], text: measured.label)
        }
    }

    /// The ink of `label` (its glyphs' outlines) in pixels of the box (`y` down); `nil` without a font or any ink.
    static func inkBounds(of label: Label) -> CGRect? {
        guard let ink = ink(of: label.text, fontSize: label.fontSize) else { return nil }
        return CGRect(x: label.origin.x + ink.minX, y: label.origin.y - ink.maxY, width: ink.width, height: ink.height)
    }

    /// The label drawn as a path, not a glyph.
    static let space = "␣"

    /// ␣ at `fontSize` as the outline of its stroke, from the start of its baseline (`y` up): a bracket 0.7 em wide
    /// (⌘'s ink) and 0.22 em high, stroked 0.075 em (SF Pro semibold's stem) with round ends and joins.
    static func spacePath(fontSize: Double) -> CGPath {
        let f = fontSize, path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0.1 * f, y: 0.22 * f), CGPoint(x: 0.1 * f, y: 0), CGPoint(x: 0.8 * f, y: 0), CGPoint(x: 0.8 * f, y: 0.22 * f)])
        return path.copy(strokingWithWidth: 0.075 * f, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// The ink of `text` at `fontSize` from the start of its baseline (`y` up): its glyphs' outlines, or `spacePath`'s.
    /// `nil` without a font or any ink.
    static func ink(of text: String, fontSize: Double) -> CGRect? {
        let ink: CGRect
        if text == space {
            guard fontSize > 0, fontSize.isFinite else { return nil }
            ink = spacePath(fontSize: fontSize).boundingBoxOfPath
        } else {
            guard let font = font(size: fontSize) else { return nil }
            ink = CTLineGetImageBounds(line(text, font: font), nil)
        }
        guard !ink.isNull, ink.width > 0, ink.height > 0 else { return nil }
        return ink
    }

    // MARK: - Private

    /// The whole pixels a box is made of for keys `h` high: the key, the padding and the spacing.
    private struct Frame {
        let h: Double
        let cap: Int
        let padding: Int
        let spacing: Int

        init?(capHeight h: Double) {
            guard h.isFinite, h >= 1, h < 4096 else { return nil }
            self.h = h
            cap = Int(h.rounded())
            padding = Int((KeyOverlayMetrics.padding * h).rounded())
            spacing = Int((KeyOverlayMetrics.spacing * h).rounded())
        }

        var height: Int { cap + 2 * padding }

        func width(ofKeys widths: [Int]) -> Int {
            2 * padding + widths.reduce(0, +) + spacing * max(widths.count - 1, 0)
        }
    }

    /// The width of each key of `labels`: square for one character, a longer label's with its inset; `nil` for no key or
    /// a font that cannot be made.
    private static func capWidths(of labels: [String], frame: Frame) -> [Int]? {
        guard !labels.isEmpty else { return nil }
        var wordFont: CTFont?
        var widths: [Int] = []
        for label in labels {
            guard label.count > 1 else {
                widths.append(frame.cap)
                continue
            }
            if wordFont == nil { wordFont = font(size: wordSize * frame.h) }
            guard let wordFont else { return nil }
            let text = CTLineGetTypographicBounds(line(label, font: wordFont), nil, nil, nil)
            widths.append(max(frame.cap, Int((text + 2 * wordInset * frame.h).rounded())))
        }
        return widths
    }

    /// The label `text` in the key at `origin` of `size`: centred across it on its ink, and down it on the capitals'
    /// baseline (letters, digits, `baselineSymbols`) or on its ink.
    private static func label(_ text: String, in origin: SIMD2<Int>, _ size: SIMD2<Int>, frame: Frame) -> Label? {
        let fontSize = (text.count > 1 ? wordSize : glyphSize) * frame.h
        guard let font = font(size: fontSize) else { return nil }
        let ink = self.ink(of: text, fontSize: fontSize)
        let left = Double(origin.x), top = Double(origin.y), width = Double(size.x), height = Double(size.y)
        let x = ink.map { left + (width - $0.width) / 2 - $0.minX } ?? left + width / 2
        let onBaseline = baselineSymbols.contains(text) || text.allSatisfy { $0.isLetter || $0.isNumber }
        // A word in small letters (esc) centres its small letters instead of the capitals' height.
        let small = text.allSatisfy(\.isLowercase) ? CTFontGetXHeight(font) : CTFontGetCapHeight(font)
        // `y` down: the baseline is below the ink's middle by the middle's height above it.
        let baseline = onBaseline || ink == nil ? top + (height + small) / 2 : top + height / 2 + (ink?.midY ?? 0)
        return Label(text: text, fontSize: fontSize, origin: SIMD2(x.rounded(), baseline.rounded()))
    }

    /// The pill of `text`: its width and its text, inset from the sides as far as its capitals are from the top and
    /// bottom; `nil` for no text or no font.
    private static func pill(of text: String, frame: Frame) -> (width: Int, label: Label)? {
        guard !text.isEmpty else { return nil }
        let fontSize = textSize * frame.h
        guard let font = font(size: fontSize) else { return nil }
        let advance = CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil)
        guard advance > 0, advance.isFinite else { return nil }
        let capitals = Double(CTFontGetCapHeight(font)), height = Double(frame.height)
        let inset = ((height - capitals) / 2).rounded()
        let width = Int((advance + 2 * inset).rounded())
        let baseline = ((height + capitals) / 2).rounded()
        return (width, Label(text: text, fontSize: fontSize, origin: SIMD2(inset, baseline)))
    }
}

/// The textures of the keys on screen (phase 2 design §7.4, `keyOverlay-1`): each a premultiplied `.bgra8Unorm` texture
/// of a box as `KeyOverlayMetrics` lays it out, the compositor's to draw at its item's rect one texel a pixel, at the
/// output's own resolution (a 4K export's at 4K, never magnified).
///
/// The box is #1C1C1E at 85 % with a hairline of white at 8 % inside its edge. A key is #3A3A3C, a shade lighter at its
/// top and darker at its bottom (#3E3E40 to #363638, its colour halfway down), with a lit edge along its top (white at
/// 12 %, 2 % of its height) and a lip under it (black at 40 %, 3.5 % of its height) where it stands on the box; its label
/// and the pill's text are white.
///
/// CoreText and CoreGraphics draw it into a `CGContext` of fixed sRGB without font smoothing, without subpixel
/// positioning and antialiased, as `TitleTexture`, so the texture depends neither on the system's settings nor on a
/// display: the preview and the export draw the same. The system font itself changes from one macOS to another, and its
/// bytes with it.
///
/// Drawn the first time a content is asked for at a size and kept while the frames ask for it: the last four (a pill as
/// it grows, a shortcut and the pill under it during a cross-fade), under a lock.
final class KeyOverlayTexture: Sendable {
    private struct Key: Equatable {
        let content: KeyOverlayContent
        let capHeight: Double
    }

    private struct State {
        /// The boxes last asked for, the latest last, and their textures.
        var drawn: [(key: Key, texture: any MTLTexture)] = []
        var drawnCount = 0
    }

    private let device: any MTLDevice
    private let state = Mutex(State())
    /// How many textures are kept.
    static let kept = 4
    /// The most pixels across a texture (Metal's limit).
    static let maxSide = 16384

    init(device: any MTLDevice) {
        self.device = device
    }

    /// How many textures have been drawn, for tests.
    var drawnCount: Int { state.withLock { $0.drawnCount } }

    /// The whole pixels of the output `item` covers, from the top left: its rect, rounded. `nil` for a rect that is not a
    /// positive, finite size, or a texture too large.
    static func region(of item: KeyOverlayLayer.Item) -> (origin: SIMD2<Int>, size: SIMD2<Int>)? {
        let rect = item.rect
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.width >= 1, rect.height >= 1,
              rect.width <= Double(maxSide), rect.height <= Double(maxSide), abs(rect.x) < 1e9, abs(rect.y) < 1e9
        else { return nil }
        return (SIMD2(Int(rect.x.rounded()), Int(rect.y.rounded())), SIMD2(Int(rect.width.rounded()), Int(rect.height.rounded())))
    }

    /// The texture of `item`'s content at its key's height, as large as `KeyOverlayMetrics` lays it out.
    /// - Throws: `RenderError.metalResourceUnavailable` if there is nothing to draw or CoreGraphics or Metal cannot make
    ///   what it needs.
    func texture(for item: KeyOverlayLayer.Item) throws -> any MTLTexture {
        let key = Key(content: item.content, capHeight: item.capHeight)
        return try state.withLock { state in
            if let index = state.drawn.firstIndex(where: { $0.key == key }) {
                let found = state.drawn.remove(at: index)
                state.drawn.append(found)
                return found.texture
            }
            // The oldest box's memory goes before the next one is drawn.
            if state.drawn.count >= Self.kept { state.drawn.removeFirst() }
            let texture = try Self.makeTexture(of: item.content, capHeight: item.capHeight, device: device)
            state.drawn.append((key, texture))
            state.drawnCount += 1
            return texture
        }
    }

    private static func makeTexture(of content: KeyOverlayContent, capHeight: Double, device: any MTLDevice) throws -> any MTLTexture {
        guard let bitmap = try bitmap(of: content, capHeight: capHeight) else {
            throw RenderError.metalResourceUnavailable("key overlay of nothing")
        }
        let (columns, rows) = (bitmap.size.x, bitmap.size.y)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: columns, height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("key overlay texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0, withBytes: bitmap.bytes, bytesPerRow: columns * 4)
        return texture
    }

    /// `content` drawn with keys `capHeight` pixels high as premultiplied BGRA bytes, rows from the top, and its size;
    /// `nil` when it has nothing to draw. Internal for tests and the shots.
    static func bitmap(of content: KeyOverlayContent, capHeight: Double) throws -> (bytes: [UInt8], size: SIMD2<Int>)? {
        guard let layout = KeyOverlayMetrics.layout(of: content, capHeight: capHeight),
              layout.size.x > 0, layout.size.y > 0, layout.size.x <= maxSide, layout.size.y <= maxSide
        else { return nil }
        let (columns, rows) = (layout.size.x, layout.size.y)
        let h = capHeight
        // Pixels of the box (y down) to the context's (y up from the bottom).
        func rect(_ origin: SIMD2<Int>, _ size: SIMD2<Int>, down: Double = 0) -> CGRect {
            CGRect(x: Double(origin.x), y: Double(rows - origin.y - size.y) - down, width: Double(size.x), height: Double(size.y))
        }
        func rounded(_ rect: CGRect, _ radius: Double) -> CGPath {
            let r = min(max(radius, 0), rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func color(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: alpha)
        }

        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let gradient = CGGradient(colorsSpace: space, colors: [color(0x3E, 0x3E, 0x40), color(0x36, 0x36, 0x38)] as CFArray, locations: [0, 1])
            else { throw RenderError.metalResourceUnavailable("key overlay bitmap") }
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldAntialias(true)
            context.textMatrix = .identity

            // The box, and the hairline inside its edge.
            let box = CGRect(x: 0, y: 0, width: columns, height: rows)
            context.addPath(rounded(box, layout.radius))
            context.setFillColor(color(0x1C, 0x1C, 0x1E, 0.85))
            context.fillPath()
            let hairline = max(1, (0.015 * h).rounded())
            context.addPath(rounded(box.insetBy(dx: hairline / 2, dy: hairline / 2), layout.radius - hairline / 2))
            context.setStrokeColor(color(255, 255, 255, 0.08))
            context.setLineWidth(hairline)
            context.strokePath()

            // The keys: the lip they stand on, their face, its lit top edge, their label.
            let lip = max(1, (0.035 * h).rounded()), lit = max(1, (0.02 * h).rounded())
            for cap in layout.caps {
                let face = rect(cap.origin, cap.size)
                context.addPath(rounded(face.offsetBy(dx: 0, dy: -lip), cap.radius))
                context.setFillColor(color(0, 0, 0, 0.4))
                context.fillPath()
                context.saveGState()
                context.addPath(rounded(face, cap.radius))
                context.clip()
                context.drawLinearGradient(
                    gradient, start: CGPoint(x: face.midX, y: face.maxY), end: CGPoint(x: face.midX, y: face.minY), options: [])
                context.addPath(rounded(face, cap.radius))
                context.addPath(rounded(face.offsetBy(dx: 0, dy: -lit), cap.radius))
                context.setFillColor(color(255, 255, 255, 0.12))
                context.fillPath(using: .evenOdd)
                context.restoreGState()
                draw(cap.label, in: context, rows: rows)
            }
            if let text = layout.text { draw(text, in: context, rows: rows) }
        }
        return (bytes, layout.size)
    }

    /// Draws `label` white at its origin into `context`, `rows` high.
    private static func draw(_ label: KeyOverlayMetrics.Label, in context: CGContext, rows: Int) {
        let origin = CGPoint(x: label.origin.x, y: Double(rows) - label.origin.y)
        if label.text == KeyOverlayMetrics.space {
            var placed = CGAffineTransform(translationX: origin.x, y: origin.y)
            guard let path = KeyOverlayMetrics.spacePath(fontSize: label.fontSize).copy(using: &placed) else { return }
            context.addPath(path)
            context.setFillColor(KeyOverlayMetrics.white)
            context.fillPath()
            return
        }
        guard let font = KeyOverlayMetrics.font(size: label.fontSize) else { return }
        context.textPosition = origin
        CTLineDraw(KeyOverlayMetrics.line(label.text, font: font), context)
    }
}
