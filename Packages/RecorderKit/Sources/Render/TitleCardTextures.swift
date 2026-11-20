// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import Metal
import ProjectFormat
import Synchronization

/// How a title card's texts are set, `titleCard-1` (plan 3a decision 10), in an output `W × H` pixels big: the system font
/// (SF Pro) at a fraction of `H`, in the weights of `kCTFontWeightTrait` (regular 0, semibold 0.3, bold 0.4, heavy 0.56),
/// the lines broken by words within `0.8 W` and spaced by CoreText's line height.
///
/// - Centred: the title 0.085 H bold and the subtitle 0.04 H regular, each line centred; the block centred.
/// - To the left: the same, each line starting at 0.1 W; the block centred up and down.
/// - Large: the title 0.14 H heavy (0.56), the subtitle as Centred's, centred.
/// - Minimal: the title 0.05 H semibold and the subtitle 0.03 H regular, centred.
///
/// The subtitle goes `subtitleGap` of the title's size under the title's last line, in the text's colour at 70 % of its
/// alpha. A line that the user broke (`\n`) is broken there too. No word is broken: a text with a word wider than `0.8 W`
/// (a long word in Large at 9:16) is set smaller, as much as that word needs to fit.
enum TitleCardTypography {
    /// What one of a card's texts is set in: its size, a fraction of the output's height, and its weight.
    struct Face: Equatable {
        var size: Double
        var weight: Double
    }

    static let regular = 0.0
    static let semibold = 0.3
    static let bold = 0.4
    static let heavy = 0.56

    static func title(of style: TitleCardStyle) -> Face {
        switch style {
        case .centered, .leading: Face(size: 0.085, weight: bold)
        case .large: Face(size: 0.14, weight: heavy)
        case .minimal: Face(size: 0.05, weight: semibold)
        }
    }

    static func subtitle(of style: TitleCardStyle) -> Face {
        switch style {
        case .centered, .leading, .large: Face(size: 0.04, weight: regular)
        case .minimal: Face(size: 0.03, weight: regular)
        }
    }

    /// The subtitle's alpha, of the text's.
    static let subtitleOpacity = 0.7
    /// The widest a line is, of the output's width.
    static let maxWidth = 0.8
    /// Where To the left's lines start, of the output's width.
    static let leadingInset = 0.1
    /// The room between the title's last line and the subtitle's first, of the title's size.
    static let subtitleGap = 0.3

    /// The system font at `size` pixels in `weight`, for `TitleTexture.fontLanguage`, so a character in Chinese, Japanese
    /// or Korean is drawn the same whatever the system's language: `nil` for a size that is not a positive number, or if
    /// CoreText cannot make it.
    static func font(size: Double, weight: Double) -> CTFont? {
        guard size > 0, size.isFinite,
              let base = CTFontCreateUIFontForLanguage(.system, size, TitleTexture.fontLanguage as CFString)
        else { return nil }
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let weighted = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, weighted)
    }
}

/// The texts of a card laid out in an output (`TitleCardTypography`): each line with where it starts and its baseline, on
/// whole pixels, in output pixels from the top left; and the whole pixels the texture of them covers.
struct TitleCardLayout {
    struct Line {
        let line: CTLine
        let x: Double
        let baseline: Double
    }

    let lines: [Line]
    /// The whole pixels of the output the texture covers, from the top left: the block and a margin of
    /// `TitleCardTextures.marginEm` of the title's size and two pixels around it, cut to the output.
    let origin: SIMD2<Int>
    let size: SIMD2<Int>

    /// `layer`'s texts in an output of `outputSize`; `nil` with nothing to draw (both texts empty, no font, an output of no
    /// size) or a block entirely off the output.
    init?(_ layer: TitleCardLayer, outputSize: SIMD2<Int>) {
        let (width, height) = (Double(outputSize.x), Double(outputSize.y))
        guard width > 0, height > 0 else { return nil }
        let maxWidth = TitleCardTypography.maxWidth * width
        let color = layer.textColor
        func cgColor(alpha: Double) -> CGColor {
            func unit(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
            return CGColor(srgbRed: unit(color.r), green: unit(color.g), blue: unit(color.b), alpha: unit(alpha))
        }
        /// A text set and broken into lines within `maxWidth`, with its font's line height and ascent.
        struct Part {
            var lines: [(line: CTLine, width: Double)]
            var lineHeight: Double
            var ascent: Double
            var size: Double
        }
        func part(_ text: String, face: TitleCardTypography.Face, alpha: Double) -> Part? {
            guard !text.isEmpty else { return nil }
            let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            /// The paragraphs set in `font`, each with its typesetter.
            func set(in font: CTFont) -> [(string: NSAttributedString, typesetter: CTTypesetter)] {
                let attributes: [NSAttributedString.Key: Any] = [
                    Self.key(kCTFontAttributeName): font,
                    Self.key(kCTLanguageAttributeName): TitleTexture.fontLanguage,
                    Self.key(kCTForegroundColorAttributeName): cgColor(alpha: alpha),
                ]
                return paragraphs.map { paragraph in
                    let string = NSAttributedString(string: String(paragraph), attributes: attributes)
                    return (string, CTTypesetterCreateWithAttributedString(string))
                }
            }
            // A word wider than a line makes the text smaller until it fits: no word is ever broken.
            var size = face.size * height
            guard var font = TitleCardTypography.font(size: size, weight: face.weight) else { return nil }
            var paragraphsSet = set(in: font)
            for _ in 0..<4 {
                let widest = paragraphsSet.map { Self.widestWord(of: $0.string, typesetter: $0.typesetter) }.max() ?? 0
                guard widest > maxWidth, let smaller = TitleCardTypography.font(size: size * maxWidth / widest, weight: face.weight)
                else { break }
                size *= maxWidth / widest
                font = smaller
                paragraphsSet = set(in: font)
            }
            var lines: [(CTLine, Double)] = []
            for (string, typesetter) in paragraphsSet {
                let length = string.length
                guard length > 0 else {
                    // An empty line keeps its room.
                    lines.append((CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0)), 0))
                    continue
                }
                var start = 0
                while start < length {
                    let count = max(CTTypesetterSuggestLineBreak(typesetter, start, maxWidth), 1)
                    let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: min(count, length - start)))
                    lines.append((line, Self.width(of: line)))
                    start += count
                }
            }
            let ascent = Double(CTFontGetAscent(font))
            let lineHeight = ascent + Double(CTFontGetDescent(font) + CTFontGetLeading(font))
            return Part(lines: lines, lineHeight: lineHeight, ascent: ascent, size: size)
        }
        let style = layer.style
        let title = part(layer.title, face: TitleCardTypography.title(of: style), alpha: color.a)
        let subtitle = part(
            layer.subtitle, face: TitleCardTypography.subtitle(of: style), alpha: color.a * TitleCardTypography.subtitleOpacity)
        let parts = [title, subtitle].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let gap = title != nil && subtitle != nil ? TitleCardTypography.subtitleGap * (title?.size ?? 0) : 0
        let blockHeight = parts.reduce(gap) { $0 + Double($1.lines.count) * $1.lineHeight }
        let top = (height - blockHeight) / 2
        var lines: [Line] = []
        var y = top
        var left = Double.infinity, right = -Double.infinity
        for part in parts {
            for (number, (line, lineWidth)) in part.lines.enumerated() {
                let x = (style == .leading ? TitleCardTypography.leadingInset * width : (width - lineWidth) / 2).rounded()
                lines.append(Line(line: line, x: x, baseline: (y + part.ascent + Double(number) * part.lineHeight).rounded()))
                left = min(left, x)
                right = max(right, x + lineWidth)
            }
            y += Double(part.lines.count) * part.lineHeight + gap
        }
        let margin = TitleCardTextures.marginEm * (parts.map(\.size).max() ?? 0) + 2
        let lower = SIMD2(max((left - margin).rounded(.down), 0), max((top - margin).rounded(.down), 0))
        let upper = SIMD2(min((right + margin).rounded(.up), width), min((top + blockHeight + margin).rounded(.up), height))
        guard upper.x > lower.x, upper.y > lower.y, lines.contains(where: { CTLineGetGlyphCount($0.line) > 0 }) else { return nil }
        self.lines = lines
        origin = SIMD2(Int(lower.x), Int(lower.y))
        size = SIMD2(Int(upper.x - lower.x), Int(upper.y - lower.y))
    }

    private static func key(_ name: CFString) -> NSAttributedString.Key { NSAttributedString.Key(name as String) }

    /// The typographic width of `line` without the white space at its end.
    private static func width(of line: CTLine) -> Double {
        let set = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
        return max(set.isFinite ? set : 0, 0)
    }

    /// The widest of `string`'s words as `typesetter` sets them: from each word's start (`byWords`, which knows the
    /// languages without spaces) to the next one's, with the punctuation that goes with it and without the white space
    /// at its end, the least a line can hold of it.
    private static func widestWord(of string: NSAttributedString, typesetter: CTTypesetter) -> Double {
        let text = string.string as NSString
        var starts: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.location)
        }
        guard !starts.isEmpty else { return 0 }
        // What goes before the first word (an opening mark) goes with it.
        starts[0] = 0
        starts.append(text.length)
        var widest = 0.0
        for (start, end) in zip(starts, starts.dropFirst()) where end > start {
            widest = max(widest, width(of: CTTypesetterCreateLine(typesetter, CFRange(location: start, length: end - start))))
        }
        return widest
    }
}

/// The textures of the title cards' texts (`titleCard-1`): each a premultiplied `.bgra8Unorm` texture of the whole pixels
/// of the output around a card's block of text (`TitleCardLayout`), the compositor's to draw there one texel a pixel, at
/// the output's own resolution, and at the layer's opacity (which, like its fill and its veil, does not change it).
///
/// CoreText draws them into a `CGContext` of fixed sRGB without font smoothing, without subpixel positioning and
/// antialiased, as `CaptionTextures` and `TitleTexture`, so the texture depends neither on the system's settings nor on a
/// display: the preview and the export draw the same. The system font itself changes from one macOS to another, and its
/// bytes with it.
///
/// Drawn the first time a card's texts are asked for at an output size, and kept while the frames ask for them: the last
/// two (the export's size and the preview's while it plays, or two cards next to each other), under a lock.
final class TitleCardTextures: Sendable {
    /// What a texture depends on: the texts, the style, the colour and the output's size.
    struct Key: Equatable {
        let title: String
        let subtitle: String
        let style: TitleCardStyle
        let textColor: RGBA
        let outputSize: SIMD2<Int>

        init(_ layer: TitleCardLayer, outputSize: SIMD2<Int>) {
            (title, subtitle, style, textColor) = (layer.title, layer.subtitle, layer.style, layer.textColor)
            self.outputSize = outputSize
        }
    }

    private struct State {
        /// The textures last asked for, the latest last (`nil`: nothing to draw).
        var drawn: [(key: Key, region: (origin: SIMD2<Int>, size: SIMD2<Int>)?, texture: (any MTLTexture)?)] = []
        var drawCount = 0
    }

    private let state = Mutex(State())
    /// How many textures are kept.
    static let kept = 2
    /// How far past the block a texture reaches, of the largest size of its texts, besides two pixels: glyphs past their
    /// line (an accent over a capital, a long tail).
    static let marginEm = 0.3

    init() {}

    /// How many textures have been drawn, for tests.
    var drawCount: Int { state.withLock { $0.drawCount } }

    /// The texture of `layer`'s texts in an output of `outputSize` and the whole pixels of the output it covers, from the
    /// top left; `nil` when it has nothing to draw. Kept, it is there; otherwise it is drawn now and kept.
    /// - Throws: `RenderError.metalResourceUnavailable` if CoreGraphics or Metal cannot make what it needs.
    func texture(
        for layer: TitleCardLayer, outputSize: SIMD2<Int>, device: any MTLDevice
    ) throws -> (texture: any MTLTexture, origin: SIMD2<Int>, size: SIMD2<Int>)? {
        let key = Key(layer, outputSize: outputSize)
        return try state.withLock { state in
            if let index = state.drawn.firstIndex(where: { $0.key == key }) {
                let found = state.drawn.remove(at: index)
                state.drawn.append(found)
                guard let region = found.region, let texture = found.texture else { return nil }
                return (texture, region.origin, region.size)
            }
            let made = try Self.makeTexture(for: layer, outputSize: outputSize, device: device)
            if state.drawn.count >= Self.kept { state.drawn.removeFirst() }
            state.drawn.append((key, made.map { ($0.origin, $0.size) }, made?.texture))
            state.drawCount += 1
            return made
        }
    }

    /// `layer`'s texts drawn into a new texture; `nil` when it has nothing to draw.
    private static func makeTexture(
        for layer: TitleCardLayer, outputSize: SIMD2<Int>, device: any MTLDevice
    ) throws -> (texture: any MTLTexture, origin: SIMD2<Int>, size: SIMD2<Int>)? {
        guard let (bytes, origin, size) = try bitmap(of: layer, outputSize: outputSize) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("title card texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size.x * 4)
        return (texture, origin, size)
    }

    /// `layer`'s texts in an output of `outputSize` drawn as premultiplied BGRA bytes of the whole pixels they cover
    /// (`TitleCardLayout`), rows from the top, and where those pixels are; `nil` when it has nothing to draw. Internal for
    /// tests.
    static func bitmap(of layer: TitleCardLayer, outputSize: SIMD2<Int>) throws -> (bytes: [UInt8], origin: SIMD2<Int>, size: SIMD2<Int>)? {
        guard let layout = TitleCardLayout(layer, outputSize: outputSize) else { return nil }
        let (columns, rows) = (layout.size.x, layout.size.y)
        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("title card bitmap") }
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldAntialias(true)
            context.textMatrix = .identity
            for line in layout.lines {
                // Output pixels (y down) to the context's (y up from the region's bottom).
                context.textPosition = CGPoint(
                    x: line.x - Double(layout.origin.x), y: Double(layout.origin.y + rows) - line.baseline)
                CTLineDraw(line.line, context)
            }
        }
        return (bytes, layout.origin, layout.size)
    }
}
