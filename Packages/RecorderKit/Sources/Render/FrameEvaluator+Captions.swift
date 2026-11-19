// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreText
import ProjectFormat

/// The captions shown in a frame (phase 2 design §5.2, `captionStyle-1`), drawn over everything (§11, step 6): their
/// lines as drawn (in capitals if the style asks), the word being said, the style, the transcript's language (which picks
/// the system font's glyphs for it), the size of the font and the box of the text with Classic's padding, in pixels of
/// the output. The compositor draws the texture `CaptionTextures` makes of it, one texel a pixel.
///
/// Hashable by all of its fields (by hand: `CaptionStyle` is only `Equatable`), the key of its texture (`CaptionTextures`).
public struct CaptionLayer: Hashable, Sendable {
    /// One or two lines, their words joined by a space.
    public var lines: [String]
    /// The word being said, drawn in `style.highlightColor`; `nil` without the highlight (`style.highlight` false).
    public var highlight: CaptionHighlight?
    public var style: CaptionStyle
    /// BCP 47, the transcript's (`Transcript.language`).
    public var language: String
    /// Pixels of the output: the nominal size of `style.size` (`CaptionMetrics.fontSize`), smaller if the widest line
    /// would be wider than `CaptionMetrics.maxWidthFraction` of the output.
    public var fontSize: Double
    /// Pixels of the output: the lines at CoreText's height and the widest line's width, with Classic's padding around
    /// them (`CaptionMetrics.boxPaddingEm`), centred across the output and `CaptionMetrics.edgeMargin` of its height from
    /// the bottom or the top edge. Every preset is placed by it; only Classic draws it.
    public var box: Rect

    public init(lines: [String], highlight: CaptionHighlight?, style: CaptionStyle, language: String, fontSize: Double, box: Rect) {
        self.lines = lines
        self.highlight = highlight
        self.style = style
        self.language = language
        self.fontSize = fontSize
        self.box = box
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lines)
        hasher.combine(highlight)
        hasher.combine(style.preset)
        hasher.combine(style.size)
        hasher.combine(style.position)
        hasher.combine(style.uppercase)
        hasher.combine(style.highlight)
        for component in [style.highlightColor.r, style.highlightColor.g, style.highlightColor.b, style.highlightColor.a] {
            hasher.combine(component)
        }
        hasher.combine(language)
        hasher.combine(fontSize)
        for value in [box.x, box.y, box.width, box.height] { hasher.combine(value) }
    }
}

/// The word of a caption being said: its line, and its characters in that line (`Character`s of `CaptionLayer.lines`).
public struct CaptionHighlight: Hashable, Sendable {
    public var line: Int
    public var range: Range<Int>

    public init(line: Int, range: Range<Int>) {
        self.line = line
        self.range = range
    }
}

/// The captions of a document (`EditDocument.captions` over its `transcript`) as the frames draw them, worked out once for
/// the scene and again for each size (`FrameEvaluator.init` and `resized(to:)`): the captions of `CaptionLines`, each with
/// its size and box (`CaptionMetrics`, plan 2a decision 10), measured with CoreText in the font they are drawn in.
///
/// None when the captions are hidden (`captions.show` false) or there is no transcript: a document of phase 1 draws as
/// it did.
struct CaptionScene: Sendable {
    /// The captions in output order, and where each is drawn (`nil` for one the system font cannot set).
    private let captions: [Caption]
    private let placements: [Placement?]
    private let style: CaptionStyle
    private let language: String

    /// A caption's size and box (`CaptionLayer.fontSize`, `box`).
    struct Placement: Equatable, Sendable {
        var fontSize: Double
        var box: Rect
    }

    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {
        style = document.captions.style
        language = document.transcript?.language ?? ""
        guard document.captions.show, document.transcript != nil, outputSize.x > 0, outputSize.y > 0 else {
            (captions, placements) = ([], [])
            return
        }
        let (style, language) = (style, language)
        captions = CaptionLines.captions(of: document, timeMap: timeMap, outputSize: outputSize)
        // Most captions fit at the nominal size: its font is made once.
        let nominal = CaptionTypography.font(
            preset: style.preset, language: language, size: CaptionMetrics.fontSize(style.size, outputSize: outputSize))
        placements = captions.map {
            Self.placement(of: Self.lines(of: $0), style: style, language: language, outputSize: outputSize, nominalFont: nominal)
        }
    }

    /// The captions at output time `output` (nanoseconds): the caption shown then (`CaptionLines.index(atOutput:in:)`),
    /// with the word being said highlighted when the style asks (plan 2a decision 11: from its start to the start of the
    /// next word of the caption, the last to the caption's end); `nil` between captions and without any.
    func layer(atOutput output: Int64) -> CaptionLayer? {
        guard let index = CaptionLines.index(atOutput: output, in: captions), let placed = placements[index] else { return nil }
        let caption = captions[index]
        return CaptionLayer(
            lines: Self.lines(of: caption), highlight: style.highlight ? Self.highlight(in: caption, atOutput: output) : nil,
            style: style, language: language, fontSize: placed.fontSize, box: placed.box)
    }

    /// How many layers a frame has ahead (`layersAhead(atOutput:)`): the next word, and the one after it for a word too
    /// short for its texture to be drawn before it comes (or for playback faster than 1×).
    static let ahead = 2

    /// The layers the frames draw next after the one at output time `output` (`layer(atOutput:)`), in output order, at
    /// most `ahead`: with the highlight, the layer of each word that starts after `output`, in the caption shown and then
    /// in the next ones; without it, each caption that starts after `output`. What the compositor draws ahead
    /// (`RenderFrame.captionsAhead`); a layer the frames then draw otherwise is only drawn in its frame.
    func layersAhead(atOutput output: Int64) -> [CaptionLayer] {
        guard !captions.isEmpty else { return [] }
        // The first caption that ends after `output`: the one shown, or the next.
        var (low, high) = (0, captions.count)
        while low < high {
            let middle = low + (high - low) / 2
            if captions[middle].output.upperBound <= output { low = middle + 1 } else { high = middle }
        }
        var ahead: [CaptionLayer] = []
        for index in low..<captions.count where ahead.count < Self.ahead {
            guard let placed = placements[index] else { continue }
            let caption = captions[index]
            func layer(_ highlight: CaptionHighlight?) -> CaptionLayer {
                CaptionLayer(
                    lines: Self.lines(of: caption), highlight: highlight, style: style, language: language,
                    fontSize: placed.fontSize, box: placed.box)
            }
            guard style.highlight else {
                if caption.output.lowerBound > output { ahead.append(layer(nil)) }
                continue
            }
            // Each word as the frame at its start draws it.
            for word in caption.lines.joined() where word.output.lowerBound > output && ahead.count < Self.ahead {
                ahead.append(layer(Self.highlight(in: caption, atOutput: word.output.lowerBound)))
            }
        }
        return ahead
    }

    /// The lines of `caption` as drawn: their words joined by a space.
    static func lines(of caption: Caption) -> [String] {
        caption.lines.map { $0.map(\.text).joined(separator: " ") }
    }

    /// The word of `caption` said at `output`, in characters of its line; `nil` if none is (never inside the caption).
    static func highlight(in caption: Caption, atOutput output: Int64) -> CaptionHighlight? {
        for (number, line) in caption.lines.enumerated() {
            var start = 0
            for word in line {
                let length = word.text.count
                if word.output.contains(output) { return CaptionHighlight(line: number, range: start..<(start + length)) }
                start += length + 1
            }
        }
        return nil
    }

    /// Where `lines` are drawn in `style` in an output of `outputSize` (plan 2a decision 10): at the nominal size, made
    /// smaller until the widest line is at most `maxWidthFraction` of the output's width; the box of their lines and
    /// Classic's padding, centred, at `edgeMargin` from the bottom or the top. `nil` when the font cannot be made or the
    /// lines have no width. `nominalFont`: the font at the nominal size, made already (the same as made here).
    static func placement(
        of lines: [String], style: CaptionStyle, language: String, outputSize: SIMD2<Int>, nominalFont: CTFont? = nil
    ) -> Placement? {
        let width = Double(outputSize.x), height = Double(outputSize.y)
        let room = CaptionMetrics.maxWidthFraction * width
        let nominal = CaptionMetrics.fontSize(style.size, outputSize: outputSize)
        var size = nominal
        func widest(at size: Double) -> (font: CTFont, width: Double)? {
            let made = size == nominal ? nominalFont : nil
            guard let font = made ?? CaptionTypography.font(preset: style.preset, language: language, size: size) else { return nil }
            let widths = lines.map { CaptionTypography.width(of: $0, font: font, style: style, language: language) }
            return (font, widths.max() ?? 0)
        }
        guard var measured = widest(at: size), measured.width > 0, measured.width.isFinite else { return nil }
        if measured.width > room {
            // Proportional first, then in steps of 1 %: the system font's tracking and optical size change with the size,
            // so the width is not quite proportional to it.
            size *= room / measured.width
            for _ in 0..<64 {
                guard let smaller = widest(at: size) else { return nil }
                measured = smaller
                if measured.width <= room { break }
                size *= 0.99
            }
            guard measured.width <= room else { return nil }
        }
        let padding = CaptionMetrics.boxPaddingEm * size
        let boxWidth = measured.width + 2 * padding.x
        let boxHeight = Double(lines.count) * CaptionTypography.lineHeight(of: measured.font) + 2 * padding.y
        let y = style.position == .top
            ? CaptionMetrics.edgeMargin * height : (1 - CaptionMetrics.edgeMargin) * height - boxHeight
        return Placement(fontSize: size, box: Rect(x: (width - boxWidth) / 2, y: y, width: boxWidth, height: boxHeight))
    }
}
