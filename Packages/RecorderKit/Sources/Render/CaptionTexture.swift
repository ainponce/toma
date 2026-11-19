// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreText
import Foundation
import Metal
import ProjectFormat
import Synchronization

/// How the captions are set, `captionStyle-1` (phase 2 design §5.2, plan 2a decision 10): the system font for the
/// transcript's language in each preset's weight, the width and height of a line. `CaptionScene` measures with it and
/// `CaptionTextures` draws with it, so a caption is drawn exactly where its box says.
enum CaptionTypography {
    /// The weight of the system font (`kCTFontWeightTrait`, as AppKit's `NSFont.Weight`) of each preset: Classic
    /// semibold, Bold heavy, Minimal regular.
    static func weight(of preset: CaptionPreset) -> Double {
        switch preset {
        case .classic: 0.3
        case .bold: 0.56
        case .minimal: 0
        }
    }

    /// Letter spacing in capitals, as a fraction of the size: capitals set at the system font's own spacing look cramped
    /// next to each other, so they get a little more (only when the style asks for capitals).
    static let capitalsTracking = 0.02

    /// The system font (SF Pro) for `language` at `size` pixels in the weight of `preset`: `CTFontCreateUIFontForLanguage`,
    /// as the window title's, so a character it lacks falls back to the font of that language (Japanese and Chinese Han
    /// characters are drawn differently). CoreText applies the font's own tracking and optical size for `size`, a
    /// display size. `nil` if CoreText cannot make it, or for a size that is not a positive number.
    static func font(preset: CaptionPreset, language: String, size: Double) -> CTFont? {
        guard size > 0, size.isFinite, let base = CTFontCreateUIFontForLanguage(.system, size, language as CFString) else { return nil }
        let traits = [kCTFontWeightTrait: weight(of: preset)] as CFDictionary
        let weighted = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, weighted)
    }

    /// The font `layer` is drawn in.
    static func font(for layer: CaptionLayer) -> CTFont? {
        font(preset: layer.style.preset, language: layer.language, size: layer.fontSize)
    }

    /// The height of a line: CoreText's ascent, descent and leading of `font`.
    static func lineHeight(of font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The extra spacing after each character of a line in `style` at `size` pixels: only in capitals.
    static func tracking(style: CaptionStyle, size: Double) -> Double {
        style.uppercase ? capitalsTracking * size : 0
    }

    /// The width of `text` set in `font` in `style`: its typographic width, without the spacing after its last character.
    static func width(of text: String, font: CTFont, style: CaptionStyle, language: String) -> Double {
        let size = Double(CTFontGetSize(font))
        let line = self.line(text, font: font, style: style, language: language, color: white)
        let tracking = text.isEmpty ? 0 : self.tracking(style: style, size: size)
        return max(CTLineGetTypographicBounds(line, nil, nil, nil) - tracking, 0)
    }

    /// The width of `text` as `layer` draws it, in `font` (`font(for:)`).
    static func width(of text: String, font: CTFont, layer: CaptionLayer) -> Double {
        width(of: text, font: font, style: layer.style, language: layer.language)
    }

    /// `text` set in `font` for `language` in `color`, its characters in `highlight` (`Character`s of it) in
    /// `highlightColor`; stroked `stroke` wide (a fraction of the size) in black instead of filled when it is given.
    static func line(
        _ text: String, font: CTFont, style: CaptionStyle, language: String, color: CGColor, highlight: Range<Int>? = nil,
        highlightColor: CGColor? = nil, stroke: Double? = nil
    ) -> CTLine {
        let size = Double(CTFontGetSize(font))
        var attributes: [NSAttributedString.Key: Any] = [
            key(kCTFontAttributeName): font,
            key(kCTLanguageAttributeName): language,
            key(kCTForegroundColorAttributeName): color,
        ]
        let tracking = tracking(style: style, size: size)
        if tracking != 0 { attributes[key(kCTTrackingAttributeName)] = tracking }
        if let stroke {
            // A positive width strokes without filling; CoreText takes it as a percentage of the size.
            attributes[key(kCTStrokeWidthAttributeName)] = stroke * 100
            attributes[key(kCTStrokeColorAttributeName)] = black
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if let highlight, let highlightColor, highlight.lowerBound >= 0, highlight.upperBound <= text.count, !highlight.isEmpty {
            let lower = text.index(text.startIndex, offsetBy: highlight.lowerBound)
            let upper = text.index(lower, offsetBy: highlight.count)
            string.addAttribute(key(kCTForegroundColorAttributeName), value: highlightColor, range: NSRange(lower..<upper, in: text))
        }
        return CTLineCreateWithAttributedString(string)
    }

    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private static func key(_ name: CFString) -> NSAttributedString.Key { NSAttributedString.Key(name as String) }
}

/// The textures of the captions (phase 2 design §5.2, `captionStyle-1`): each a premultiplied `.bgra8Unorm` texture of
/// the whole pixels around a layer's box (`region(of:)`), the compositor's to draw there one texel a pixel, at the
/// output's own resolution (a 4K export's are drawn at 4K, never magnified).
///
/// - Classic: its box in black at 60 % with corners of 0.3 em, snapped to whole pixels so its edges are sharp; the text
///   semibold over it.
/// - Bold: heavy, over a black outline of 0.16 em stroked with round joins under the fill (0.08 em shows outside it), the
///   two with one soft shadow.
/// - Minimal: regular, with the soft shadow.
///
/// The text is white, the word being said in the highlight colour; each line centred in the box on a baseline of whole
/// pixels. The shadow is black at 50 %, 0.04 em down, blurred 0.12 em.
///
/// CoreText draws them into a `CGContext` of fixed sRGB without font smoothing, without subpixel positioning and
/// antialiased, as `TitleTexture`, so the texture depends neither on the system's settings nor on a display: the
/// preview and the export draw the same. The system font itself changes from one macOS to another, and its bytes with it.
///
/// Drawn the first time a layer is asked for and kept while the frames ask for it: the last four (a caption and its
/// highlighted words as the preview plays, and back), under a lock.
final class CaptionTextures: Sendable {
    private struct State {
        /// The layers last asked for, the latest last, and their textures (`nil` when they have none).
        var drawn: [(layer: CaptionLayer, texture: (any MTLTexture)?)] = []
        var drawCount = 0
    }

    private let state = Mutex(State())
    /// How many layers are kept.
    static let kept = 4
    /// How far past the box a texture reaches, in em, besides two pixels: the outline, the shadow and glyphs that go past
    /// their line (a long tail, a stacked accent).
    static let marginEm = 0.5
    /// The most pixels across a texture (Metal's limit).
    static let maxSide = 16384

    init() {}

    /// How many textures have been drawn, for tests.
    var drawCount: Int { state.withLock { $0.drawCount } }

    /// The whole pixels of the output `layer`'s texture covers, from the top left: its box and `marginEm` of its font
    /// size and two pixels around it. `nil` for a box or a size that is not a positive number, or a texture too large.
    static func region(of layer: CaptionLayer) -> (origin: SIMD2<Int>, size: SIMD2<Int>)? {
        let box = layer.box
        guard [box.x, box.y, box.width, box.height, layer.fontSize].allSatisfy(\.isFinite), box.width > 0, box.height > 0,
              layer.fontSize > 0
        else { return nil }
        let margin = marginEm * layer.fontSize + 2
        let lower = SIMD2((box.x - margin).rounded(.down), (box.y - margin).rounded(.down))
        let upper = SIMD2((box.x + box.width + margin).rounded(.up), (box.y + box.height + margin).rounded(.up))
        let size = upper - lower
        guard size.x <= Double(maxSide), size.y <= Double(maxSide), abs(lower.x) < 1e9, abs(lower.y) < 1e9 else { return nil }
        return (SIMD2(Int(lower.x), Int(lower.y)), SIMD2(Int(size.x), Int(size.y)))
    }

    /// The texture of `layer`, `region(of:)` big; `nil` when it has nothing to draw (no region, no font, no line).
    /// - Throws: `RenderError.metalResourceUnavailable` if CoreGraphics or Metal cannot make what it needs.
    func texture(for layer: CaptionLayer, device: any MTLDevice) throws -> (any MTLTexture)? {
        try state.withLock { state in
            if let index = state.drawn.firstIndex(where: { $0.layer == layer }) {
                let found = state.drawn.remove(at: index)
                state.drawn.append(found)
                return found.texture
            }
            // The oldest layer's memory goes before the next one is drawn.
            if state.drawn.count >= Self.kept { state.drawn.removeFirst() }
            let texture = try Self.makeTexture(for: layer, device: device)
            state.drawn.append((layer, texture))
            state.drawCount += 1
            return texture
        }
    }

    /// `layer` drawn into a new texture; `nil` when it has nothing to draw.
    private static func makeTexture(for layer: CaptionLayer, device: any MTLDevice) throws -> (any MTLTexture)? {
        guard let bytes = try bitmap(of: layer), let region = region(of: layer) else { return nil }
        let (columns, rows) = (region.size.x, region.size.y)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: columns, height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("caption texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0, withBytes: bytes, bytesPerRow: columns * 4)
        return texture
    }

    /// `layer` drawn as premultiplied BGRA bytes of its region (`region(of:)`), rows from the top; `nil` when it has
    /// nothing to draw. Internal for tests and the caption shots.
    static func bitmap(of layer: CaptionLayer) throws -> [UInt8]? {
        guard let region = region(of: layer), !layer.lines.isEmpty, let font = CaptionTypography.font(for: layer) else { return nil }
        let (columns, rows) = (region.size.x, region.size.y)
        let em = layer.fontSize
        // Output pixels (y down) to the context's (y up from the region's bottom).
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x - Double(region.origin.x), y: Double(region.origin.y + rows) - y)
        }
        let style = layer.style, language = layer.language
        let highlightColor = CGColor(
            srgbRed: style.highlightColor.r, green: style.highlightColor.g, blue: style.highlightColor.b,
            alpha: style.highlightColor.a)
        let ascent = Double(CTFontGetAscent(font)), lineHeight = CaptionTypography.lineHeight(of: font)
        let padding = CaptionMetrics.boxPaddingEm * em
        // Each line centred in the box, on a baseline of whole pixels.
        let placed: [(text: String, origin: CGPoint, highlight: Range<Int>?)] = layer.lines.enumerated().map { number, text in
            let width = CaptionTypography.width(of: text, font: font, style: style, language: language)
            let x = (layer.box.x + (layer.box.width - width) / 2).rounded()
            let baseline = (layer.box.y + padding.y + ascent + Double(number) * lineHeight).rounded()
            return (text, point(x, baseline), layer.highlight?.line == number ? layer.highlight?.range : nil)
        }
        guard placed.contains(where: { !$0.text.isEmpty }) else { return nil }

        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("caption bitmap") }
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldAntialias(true)
            context.textMatrix = .identity

            func drawLines(stroke: Double? = nil) {
                for line in placed where !line.text.isEmpty {
                    let set = CaptionTypography.line(
                        line.text, font: font, style: style, language: language, color: CaptionTypography.white,
                        highlight: stroke == nil ? line.highlight : nil, highlightColor: highlightColor, stroke: stroke)
                    context.textPosition = line.origin
                    CTLineDraw(set, context)
                }
            }
            switch style.preset {
            case .classic:
                // The box, its edges on whole pixels.
                let box = layer.box
                let left = box.x.rounded(), right = (box.x + box.width).rounded()
                let top = box.y.rounded(), bottom = (box.y + box.height).rounded()
                let corner = min(CaptionMetrics.boxCornerEm * em, (right - left) / 2, (bottom - top) / 2)
                let lowerLeft = point(left, bottom)
                let rect = CGRect(x: lowerLeft.x, y: lowerLeft.y, width: right - left, height: bottom - top)
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptionMetrics.boxOpacity))
                context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
                context.fillPath()
                drawLines()
            case .bold, .minimal:
                // One shadow for the outline and the fill together.
                context.setShadow(
                    offset: CGSize(width: 0, height: -CaptionMetrics.shadowOffsetEm * em), blur: CaptionMetrics.shadowBlurEm * em,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptionMetrics.shadowOpacity))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                if style.preset == .bold {
                    context.setLineJoin(.round)
                    context.setLineCap(.round)
                    drawLines(stroke: 2 * CaptionMetrics.outlineEm)
                }
                drawLines()
                context.endTransparencyLayer()
            }
        }
        return bytes
    }
}
