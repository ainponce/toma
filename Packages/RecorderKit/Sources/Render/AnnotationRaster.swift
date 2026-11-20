// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreText
import Foundation
import Metal
import ProjectFormat
import Synchronization
import simd

/// How an annotation looks, `annotation-1` (phase 3 design §5.1, plan 3a decisions 4, 5 and 6): its texts, its arrow, its
/// shape, its speech bubble or its step drawn by CoreText and CoreGraphics into a premultiplied BGRA bitmap of the pixels
/// it touches (its box, its strokes, its tail, its shadow), which the compositor draws as a texture (`AnnotationRasters`,
/// `Compositor.drawContentAnnotations`, `drawOutputAnnotations`). An image and a clip are not drawn here (they have their
/// own textures).
///
/// - A layer's place is in the coordinates of its group (`AnnotationLayer`: the stage's, or the output's pixels), and the
///   bitmap is that place at `scale` (one texel a pixel of the output at 1, `scale(for:depth:)` under the zoom), so its
///   pixels are whole pixels of its group times `scale`: the bitmap of one at rest is drawn one texel per pixel. Its
///   opacity, its pop and its rotation are not in it: the compositor applies them as it draws it.
/// - A text (`AnnotationTypography`): its lines (`AnnotationTypography.lines(of:width:unit:padding:)`, wrapped at its
///   reference unit) one under the other from the top of its box less its padding, each `ascent + descent + leading` tall
///   at the text's size and aligned in the box less its padding, its baseline and its start on whole pixels of the
///   bitmap. Plain and Title with the captions' shadow (black at 50 %, 0.04 em down, blurred 0.12 em), over a box of
///   corners of 0.12 em in `fill` when they have one (then without the shadow); a Label over a pill of corners of 0.3 em
///   in `fill`; a Lower third over a box of corners of 0.12 em in `fill`, with a bar of 0.12 em of the text's colour along
///   its left edge, cut by its corners. Boxes snapped to whole pixels of the bitmap so their edges are sharp.
/// - An arrow (`AnnotationGeometry.ArrowPath`): its shaft the quadratic Bézier from its start with its control point to
///   where its head starts (`shaftEnd`, on the line from the control point to the tip, so the shaft meets the head along
///   its direction), stroked `width` wide with round ends; a filled head, the triangle; an open one, its two strokes with
///   round ends and join. All in its colour as one group: where they overlap, its alpha once.
/// - A shape: its border inside its rect (the stroke's middle `width / 2` in), `width` wide; a rounded rectangle's outer
///   corners are 0.18 of its shorter side (`AnnotationGeometry.roundedCorner(of:)`); its fill (when it has one) over the
///   whole shape, under the border.
/// - A speech bubble: its box (as a text's, measured with the Label's padding, `AnnotationLayer.rect`) with corners of
///   0.35 em, and its tail (`AnnotationGeometry.CalloutTail`), in `fill` as one group; its text over it, as a Label's,
///   without the shadow.
/// - A step: a disc as wide as the shorter side of its rect, centred (`AnnotationGeometry.stepCircle(in:)`), white, and
///   over it a disc of its colour 0.06 of its diameter smaller on each side, so a white ring of 0.06 d goes around it; its
///   number white, rounded and bold, 0.5 d, its glyphs centred in the circle.
/// - Being drawn (`AnnotationLayer.drawn` below 1, `draw`): an arrow's stroke runs from its start, the shaft then the head
///   (a filled one revealed from its base to its tip, an open one's strokes from the tip out), that fraction of their
///   length; a shape's border from its start (a rectangle's top-left corner, clockwise) that fraction of its perimeter,
///   with round ends, and its fill at that fraction of its alpha.
///
/// It is drawn in a `CGContext` of fixed sRGB without font smoothing, without subpixel positioning and antialiased (as
/// `CaptionTextures` and `TitleTexture`), so the bitmap depends neither on the system's settings nor on a display: the
/// preview and the export draw the same bytes. The system font itself changes from one macOS to another, and its bytes
/// with it.
enum AnnotationRaster {
    /// How far past a text's box (and a speech bubble's) its bitmap reaches, in em, besides `marginPixels`: its shadow,
    /// glyphs past their line and a word a little wider than its line.
    static let marginEm = 0.5
    /// How far past what a layer touches its bitmap reaches, in its pixels: the antialiased edges, and transparent texels
    /// all around for the filtering of a layer drawn rotated or zoomed.
    static let marginPixels = 2.0
    /// The most pixels across a bitmap.
    static let maxSide = 8192
    /// The most pixels of a bitmap drawn larger than its pixels (`scale(for:depth:)`): past them a deep zoom draws it at a
    /// smaller scale, magnified.
    static let maxZoomedPixels = 4096 * 4096
    /// The ring of a step, in its diameter, and its number's size.
    static let stepRing = 0.06
    static let stepNumberSize = 0.5

    /// The scale an annotation stuck to the recording drawn through a zoom of `depth` (`StageTransform.depth`) is drawn at:
    /// 1 at rest; otherwise the depth rounded up to √2^k (as `TitleTexture.scale(for:)`, which is the window frame's and
    /// 1 without one), so the bitmap is never magnified and a zoom that moves draws it again only at each step of √2, at
    /// most what keeps it within `maxSide` and `maxZoomedPixels`. A depth within 10⁻⁹ of a step is that step (√2 is √2, not
    /// 2, whatever `log2` rounds it to).
    static func scale(for layer: AnnotationLayer, depth: Double) -> Double {
        guard depth.isFinite, depth > 1, let bounds = bounds(of: layer) else { return 1 }
        var level = Int(min((2 * log2(depth) - 1e-9).rounded(.up), 64))
        while level > 0 {
            let s = pow(2, Double(level) / 2)
            let width = bounds.width * s + 2 * marginPixels + 2, height = bounds.height * s + 2 * marginPixels + 2
            if width <= Double(maxSide), height <= Double(maxSide), width * height <= Double(maxZoomedPixels) { break }
            level -= 1
        }
        return pow(2, Double(level) / 2)
    }

    /// The whole pixels of `layer`'s bitmap at `scale`, in its coordinates times `scale`, from the top left: what it touches
    /// (`bounds(of:)`) and `marginPixels` around it. `nil` for an image or a clip, a layer with nothing finite to draw, or a
    /// bitmap of more than `maxSide` pixels across.
    static func pixels(of layer: AnnotationLayer, scale: Double) -> (origin: SIMD2<Int>, size: SIMD2<Int>)? {
        guard scale > 0, scale.isFinite, let bounds = bounds(of: layer) else { return nil }
        let lower = SIMD2((bounds.x * scale - marginPixels).rounded(.down), (bounds.y * scale - marginPixels).rounded(.down))
        let upper = SIMD2(
            ((bounds.x + bounds.width) * scale + marginPixels).rounded(.up),
            ((bounds.y + bounds.height) * scale + marginPixels).rounded(.up))
        let size = upper - lower
        guard [lower.x, lower.y, size.x, size.y].allSatisfy(\.isFinite), size.x >= 1, size.y >= 1,
            size.x <= Double(maxSide), size.y <= Double(maxSide), abs(lower.x) < 1e9, abs(lower.y) < 1e9
        else { return nil }
        return (SIMD2(Int(lower.x), Int(lower.y)), SIMD2(Int(size.x), Int(size.y)))
    }

    /// `pixels(of:scale:)` in `layer`'s own coordinates: where its bitmap is drawn, before its pop, its rotation and the
    /// zoom.
    static func region(of layer: AnnotationLayer, scale: Double) -> Rect? {
        guard let pixels = pixels(of: layer, scale: scale) else { return nil }
        return Rect(
            x: Double(pixels.origin.x) / scale, y: Double(pixels.origin.y) / scale, width: Double(pixels.size.x) / scale,
            height: Double(pixels.size.y) / scale)
    }

    /// What `layer` touches, in its coordinates: a text's box and `marginEm` around it; an arrow's path and its head, half
    /// its width around them; a shape's rect; a speech bubble's box with `marginEm` and its tail's tip; a step's circle.
    /// `nil` for an image or a clip, and for numbers that are not finite.
    static func bounds(of layer: AnnotationLayer) -> Rect? {
        let rect = layer.rect, unit = layer.unit
        guard [rect.x, rect.y, rect.width, rect.height, unit].allSatisfy(\.isFinite), rect.width >= 0, rect.height >= 0
        else { return nil }
        let bounds: Rect
        switch layer.content {
        case let .text(text):
            bounds = outset(rect, by: marginEm * em(text, unit: unit))
        case let .arrow(arrow, path):
            let shaft = quadraticBounds(path.start, path.control, path.shaftEnd)
            var low = simd_min(shaft.low, path.end), high = simd_max(shaft.high, path.end)
            for point in path.head {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
            bounds = outset(Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y), by: width(arrow.width, unit: unit) / 2)
        case .shape:
            bounds = rect
        case let .callout(callout, tail):
            var box = outset(rect, by: marginEm * em(callout.text, unit: unit))
            if let tip = tail?.tip, tip.x.isFinite, tip.y.isFinite {
                let low = simd_min(SIMD2(box.x, box.y), tip), high = simd_max(SIMD2(box.x + box.width, box.y + box.height), tip)
                box = Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
            }
            bounds = box
        case .step:
            let circle = AnnotationGeometry.stepCircle(in: rect)
            bounds = Rect(
                x: circle.center.x - circle.radius, y: circle.center.y - circle.radius, width: 2 * circle.radius,
                height: 2 * circle.radius)
        case .image, .clip:
            return nil
        }
        guard [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        return bounds
    }

    /// `layer` drawn at `scale` (see the type's notes) as premultiplied BGRA bytes, rows from the top, and the rect they
    /// cover in its coordinates (`region(of:scale:)`); `nil` when it has nothing to draw (an image, a clip, an empty text
    /// without a box, no region).
    /// - Throws: `RenderError.metalResourceUnavailable` if CoreGraphics cannot make its context.
    static func bitmap(of layer: AnnotationLayer, scale: Double) throws -> (bytes: [UInt8], region: Rect)? {
        guard let pixels = pixels(of: layer, scale: scale), let region = region(of: layer, scale: scale) else { return nil }
        let (columns, rows) = (pixels.size.x, pixels.size.y)
        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        let drew = try bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("annotation bitmap") }
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldAntialias(true)
            context.textMatrix = .identity
            let canvas = Canvas(context: context, scale: scale, origin: pixels.origin, rows: rows)
            switch layer.content {
            case let .text(text):
                return canvas.text(text, box: layer.rect, unit: layer.unit)
            case let .arrow(arrow, path):
                return canvas.arrow(arrow, path: path, unit: layer.unit, drawn: layer.drawn)
            case let .shape(shape):
                return canvas.shape(shape, rect: layer.rect, unit: layer.unit, drawn: layer.drawn)
            case let .callout(callout, tail):
                return canvas.callout(callout, box: layer.rect, tail: tail, unit: layer.unit)
            case let .step(step, number):
                return canvas.step(step, number: number, rect: layer.rect)
            case .image, .clip:
                return false
            }
        }
        return drew ? (bytes, region) : nil
    }

    // MARK: - Measures

    /// An em of `text` in its layer's coordinates: its size times the unit.
    static func em(_ text: TextAnnotation, unit: Double) -> Double {
        let em = text.size * unit
        return em.isFinite && em > 0 ? em : 0
    }

    /// A width of `fraction` of the unit, as a stroke's: 0 for one that is not a positive number.
    static func width(_ fraction: Double, unit: Double) -> Double {
        let width = fraction * unit
        return width.isFinite && width > 0 ? width : 0
    }

    /// `rect` grown by `amount` on every side.
    static func outset(_ rect: Rect, by amount: Double) -> Rect {
        Rect(x: rect.x - amount, y: rect.y - amount, width: rect.width + 2 * amount, height: rect.height + 2 * amount)
    }

    /// The box around the quadratic Bézier from `a` with control `b` to `c`: its ends and its extremes.
    static func quadraticBounds(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>
    ) -> (low: SIMD2<Double>, high: SIMD2<Double>) {
        var low = simd_min(a, c), high = simd_max(a, c)
        for axis in 0..<2 {
            let denominator = a[axis] - 2 * b[axis] + c[axis]
            guard abs(denominator) > 1e-12 else { continue }
            let u = (a[axis] - b[axis]) / denominator
            guard u > 0, u < 1 else { continue }
            let v = (1 - u) * (1 - u) * a[axis] + 2 * (1 - u) * u * b[axis] + u * u * c[axis]
            low[axis] = min(low[axis], v)
            high[axis] = max(high[axis], v)
        }
        return (low, high)
    }

    /// The point at `t` of the quadratic Bézier from `a` with control `b` to `c`.
    static func quadratic(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, at t: Double) -> SIMD2<Double> {
        (1 - t) * (1 - t) * a + 2 * (1 - t) * t * b + t * t * c
    }

    /// The parameter of the quadratic Bézier from `a` with control `b` to `c` where its length from `a` is `fraction` of the
    /// whole, from 64 straight pieces of it.
    static func quadraticParameter(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, atLength fraction: Double) -> Double {
        let pieces = 64
        var lengths = [0.0]
        var previous = a
        for i in 1...pieces {
            let point = quadratic(a, b, c, at: Double(i) / Double(pieces))
            lengths.append(lengths[i - 1] + simd_distance(previous, point))
            previous = point
        }
        guard let total = lengths.last, total > 0 else { return min(max(fraction, 0), 1) }
        let wanted = min(max(fraction, 0), 1) * total
        for i in 1...pieces where lengths[i] >= wanted {
            let piece = lengths[i] - lengths[i - 1]
            let within = piece > 0 ? (wanted - lengths[i - 1]) / piece : 0
            return (Double(i - 1) + within) / Double(pieces)
        }
        return 1
    }

    /// The length of the quadratic Bézier from `a` with control `b` to `c`, from 64 straight pieces of it.
    static func quadraticLength(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        var length = 0.0, previous = a
        for i in 1...64 {
            let point = quadratic(a, b, c, at: Double(i) / 64)
            length += simd_distance(previous, point)
            previous = point
        }
        return length
    }
}

/// What `AnnotationRaster` draws into: `context`, a bitmap `rows` tall whose top-left pixel is `origin` of a layer's
/// coordinates times `scale`. Points of the layer (y down) go to the context's (y up from its bottom).
private struct Canvas {
    let context: CGContext
    let scale: Double
    let origin: SIMD2<Int>
    let rows: Int

    /// From the layer's coordinates to the context's.
    var transform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: -Double(origin.x), ty: Double(origin.y + rows))
    }

    /// Point `p` of the layer in the context.
    func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: p.x * scale - Double(origin.x), y: Double(origin.y + rows) - p.y * scale)
    }

    /// `path`, in the layer's coordinates, in the context's.
    func placed(_ path: CGPath) -> CGPath {
        var transform = self.transform
        return path.copy(using: &transform) ?? path
    }

    /// `rect` of the layer with its edges on whole pixels of the bitmap, still in the layer's coordinates.
    func snapped(_ rect: Rect) -> Rect {
        let left = (rect.x * scale).rounded() / scale, right = ((rect.x + rect.width) * scale).rounded() / scale
        let top = (rect.y * scale).rounded() / scale, bottom = ((rect.y + rect.height) * scale).rounded() / scale
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func color(_ c: RGBA, alpha: Double? = nil) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha ?? c.a)
    }

    /// A rounded rect of the layer, its corners at most half its shorter side.
    static func roundedRect(_ rect: Rect, radius: Double) -> CGPath {
        let cg = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let r = max(min(radius, rect.width / 2, rect.height / 2), 0)
        return r > 0 ? CGPath(roundedRect: cg, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: cg, transform: nil)
    }

    /// Draws what `body` draws in `color`'s colour, opaque, then the whole of it at `color`'s alpha (times `alpha`): where
    /// its parts overlap, the alpha once.
    func group(_ color: RGBA, alpha: Double = 1, _ body: (CGColor) -> Void) {
        let a = min(max(color.a * alpha, 0), 1)
        guard a > 0 else { return }
        context.saveGState()
        context.setAlpha(a)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body(Self.color(color, alpha: 1))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Texts

    /// `text`'s lines drawn in `box` (the layer's coordinates) with the padding of `paddingPreset` (its own preset's when
    /// `nil`), `unit` the height of its space; with the captions' shadow when `shadow`. Whether a line had something.
    @discardableResult
    func lines(_ text: TextAnnotation, box: Rect, unit: Double, padding paddingPreset: TextPreset? = nil, shadow: Bool) -> Bool {
        guard let lines = AnnotationTypography.lines(of: text, width: box.width, unit: unit, padding: paddingPreset),
            lines.contains(where: { !$0.isEmpty }),
            let measured = AnnotationTypography.font(text, unit: unit, scale: 1),
            let font = AnnotationTypography.font(text, unit: unit, scale: scale)
        else { return false }
        let em = AnnotationRaster.em(text, unit: unit)
        let padding = AnnotationTypography.padding(paddingPreset ?? text.preset, em: em)
        // Laid out at the size the scene measured, so the lines are in the same place at every scale; drawn at this one.
        let ascent = Double(CTFontGetAscent(measured)), lineHeight = AnnotationTypography.lineHeight(of: measured)
        let left = box.x + padding.x, room = box.width - 2 * padding.x
        var attributes = AnnotationTypography.attributes(font: font)
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = Self.color(text.color)
        context.saveGState()
        if shadow {
            let size = em * scale
            context.setShadow(
                offset: CGSize(width: 0, height: -CaptionMetrics.shadowOffsetEm * size), blur: CaptionMetrics.shadowBlurEm * size,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptionMetrics.shadowOpacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for (number, string) in lines.enumerated() where !string.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            // Its width as drawn, in the layer's coordinates.
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) / scale
            let start: Double
            switch text.align {
            case .leading: start = left
            case .center: start = left + (room - width) / 2
            case .trailing: start = left + room - width
            }
            let baseline = box.y + padding.y + ascent + Double(number) * lineHeight
            // Its start and its baseline on whole pixels of the bitmap.
            let x = (start * scale).rounded() - Double(origin.x), y = Double(origin.y + rows) - (baseline * scale).rounded()
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        if shadow { context.endTransparencyLayer() }
        context.restoreGState()
        return true
    }

    /// A text (see `AnnotationRaster`'s notes) in `box`.
    func text(_ text: TextAnnotation, box: Rect, unit: Double) -> Bool {
        let em = AnnotationRaster.em(text, unit: unit)
        let sharp = snapped(box)
        var drew = false
        switch text.preset {
        case .plain, .title:
            if let fill = text.fill, fill.a > 0 {
                fillPath(Self.roundedRect(sharp, radius: AnnotationTypography.lowerThirdCornerEm * em), fill)
                drew = true
            }
            drew = lines(text, box: box, unit: unit, shadow: !drew) || drew
        case .label:
            if let fill = text.fill, fill.a > 0 {
                fillPath(Self.roundedRect(sharp, radius: AnnotationTypography.labelCornerEm * em), fill)
                drew = true
            }
            drew = lines(text, box: box, unit: unit, shadow: false) || drew
        case .lowerThird:
            let shape = Self.roundedRect(sharp, radius: AnnotationTypography.lowerThirdCornerEm * em)
            if let fill = text.fill, fill.a > 0 { fillPath(shape, fill) }
            // The bar along its left edge, cut by its corners.
            let bar = snapped(Rect(x: box.x, y: box.y, width: AnnotationTypography.lowerThirdBarEm * em, height: box.height))
            if bar.width > 0, bar.height > 0, text.color.a > 0 {
                context.saveGState()
                context.addPath(placed(shape))
                context.clip()
                fillPath(CGPath(rect: CGRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height), transform: nil), text.color)
                context.restoreGState()
            }
            drew = lines(text, box: box, unit: unit, shadow: false) || drew || text.fill != nil || bar.width > 0
        }
        return drew
    }

    /// Fills `path` (the layer's coordinates) in `color`.
    func fillPath(_ path: CGPath, _ color: RGBA, alpha: Double = 1) {
        context.setFillColor(Self.color(color, alpha: color.a * alpha))
        context.addPath(placed(path))
        context.fillPath()
    }

    // MARK: - Arrows

    /// An arrow (see `AnnotationRaster`'s notes) along `path`, `drawn` of it.
    func arrow(_ arrow: ArrowAnnotation, path: AnnotationGeometry.ArrowPath, unit: Double, drawn: Double) -> Bool {
        let w = AnnotationRaster.width(arrow.width, unit: unit)
        let fraction = drawn.isNaN ? 1 : min(max(drawn, 0), 1)
        guard w > 0, fraction > 0, arrow.color.a > 0 else { return false }
        let shaftLength = AnnotationRaster.quadraticLength(path.start, path.control, path.shaftEnd)
        // The head's length along the arrow: from its base to its tip, or one stroke of an open one.
        let headLength: Double
        switch (arrow.head, path.head.count) {
        case (.filled, 3): headLength = simd_distance(path.head[0], (path.head[1] + path.head[2]) / 2)
        case (.open, 3): headLength = simd_distance(path.head[0], path.head[1])
        default: headLength = 0
        }
        let reach = fraction * (shaftLength + headLength)
        group(arrow.color) { color in
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(w * scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            // The shaft, up to where it is drawn: the first part of its curve.
            let shaft = CGMutablePath()
            shaft.move(to: point(path.start))
            if reach >= shaftLength {
                shaft.addQuadCurve(to: point(path.shaftEnd), control: point(path.control))
            } else {
                let t = AnnotationRaster.quadraticParameter(path.start, path.control, path.shaftEnd, atLength: reach / max(shaftLength, 1e-12))
                let control = path.start + t * (path.control - path.start)
                shaft.addQuadCurve(
                    to: point(AnnotationRaster.quadratic(path.start, path.control, path.shaftEnd, at: t)), control: point(control))
            }
            context.addPath(shaft)
            context.strokePath()
            let revealed = headLength > 0 ? min(max((reach - shaftLength) / headLength, 0), 1) : 0
            guard revealed > 0, path.head.count == 3 else { return }
            switch arrow.head {
            case .filled:
                let (tip, left, right) = (path.head[0], path.head[1], path.head[2])
                let triangle = CGMutablePath()
                triangle.addLines(between: [point(tip), point(left), point(right)])
                triangle.closeSubpath()
                context.saveGState()
                if revealed < 1 {
                    // From its base to `revealed` of the way to its tip.
                    let base = (left + right) / 2
                    let along = tip - base, across = right - left
                    let front = base + along * revealed
                    let cut = CGMutablePath()
                    cut.addLines(between: [
                        point(base - along - across), point(base - along + across), point(front + across), point(front - across),
                    ])
                    cut.closeSubpath()
                    context.addPath(cut)
                    context.clip()
                }
                context.addPath(triangle)
                context.fillPath()
                context.restoreGState()
            case .open:
                let (one, tip, other) = (path.head[0], path.head[1], path.head[2])
                let strokes = CGMutablePath()
                strokes.addLines(between: [point(tip + (one - tip) * revealed), point(tip), point(tip + (other - tip) * revealed)])
                context.addPath(strokes)
                context.strokePath()
            case .none:
                break
            }
        }
        return true
    }

    // MARK: - Shapes

    /// A shape (see `AnnotationRaster`'s notes) in `rect`, `drawn` of its border.
    func shape(_ shape: ShapeAnnotation, rect: Rect, unit: Double, drawn: Double) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let fraction = drawn.isNaN ? 1 : min(max(drawn, 0), 1)
        let w = min(AnnotationRaster.width(shape.width, unit: unit), min(rect.width, rect.height) / 2)
        let outerRadius = AnnotationGeometry.roundedCorner(of: rect)
        let outer = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let inner = outer.insetBy(dx: w / 2, dy: w / 2)
        let fill: CGPath, border: CGPath, perimeter: Double
        switch shape.shape {
        case .rect:
            fill = CGPath(rect: outer, transform: nil)
            border = CGPath(rect: inner, transform: nil)
            perimeter = 2 * (inner.width + inner.height)
        case .roundedRect:
            fill = Self.roundedRect(rect, radius: outerRadius)
            let r = max(min(outerRadius - w / 2, inner.width / 2, inner.height / 2), 0)
            border = r > 0 ? CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: inner, transform: nil)
            perimeter = 2 * (inner.width + inner.height) - 8 * r + 2 * .pi * r
        case .ellipse:
            fill = CGPath(ellipseIn: outer, transform: nil)
            border = CGPath(ellipseIn: inner, transform: nil)
            // Ramanujan's.
            let a = inner.width / 2, b = inner.height / 2
            perimeter = .pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        }
        var drew = false
        if let color = shape.fill, color.a > 0, fraction > 0 {
            fillPath(fill, color, alpha: fraction)
            drew = true
        }
        if w > 0, shape.stroke.a > 0, fraction > 0 {
            context.saveGState()
            context.setStrokeColor(Self.color(shape.stroke))
            context.setLineWidth(w * scale)
            context.setLineJoin(shape.shape == .rect ? .miter : .round)
            if fraction < 1 {
                // From its start, `fraction` of its perimeter (in the bitmap's pixels), with round ends.
                let length = max(perimeter * scale, 0)
                context.setLineCap(.round)
                context.setLineDash(phase: 0, lengths: [fraction * length, length + 1])
            }
            context.addPath(placed(border))
            context.strokePath()
            context.restoreGState()
            drew = true
        }
        return drew
    }

    // MARK: - Speech bubbles

    /// A speech bubble (see `AnnotationRaster`'s notes): its `box`, its `tail`, its text.
    func callout(_ callout: CalloutAnnotation, box: Rect, tail: AnnotationGeometry.CalloutTail?, unit: Double) -> Bool {
        let em = AnnotationRaster.em(callout.text, unit: unit)
        var drew = false
        if let fill = callout.text.fill, fill.a > 0 {
            let sharp = snapped(box)
            group(fill) { color in
                context.setFillColor(color)
                context.addPath(placed(Self.roundedRect(sharp, radius: AnnotationTypography.calloutCornerEm * em)))
                context.fillPath()
                if let tail {
                    // Its base pushed two pixels into the bubble along its sides, so the two join without a seam.
                    let push = 2 / scale
                    func inside(_ p: SIMD2<Double>) -> SIMD2<Double> {
                        let away = p - tail.tip
                        let length = simd_length(away)
                        return length > 0 ? p + away / length * push : p
                    }
                    let triangle = CGMutablePath()
                    triangle.addLines(between: [point(tail.tip), point(inside(tail.baseStart)), point(inside(tail.baseEnd))])
                    triangle.closeSubpath()
                    context.addPath(triangle)
                    context.fillPath()
                }
            }
            drew = true
        }
        return lines(callout.text, box: box, unit: unit, padding: .label, shadow: false) || drew
    }

    // MARK: - Steps

    /// A step (see `AnnotationRaster`'s notes) numbered `number` in `rect`.
    func step(_ step: StepAnnotation, number: Int, rect: Rect) -> Bool {
        let circle = AnnotationGeometry.stepCircle(in: rect)
        let radius = circle.radius
        guard radius > 0, radius.isFinite else { return false }
        func disc(_ r: Double) -> CGPath {
            CGPath(ellipseIn: CGRect(x: circle.center.x - r, y: circle.center.y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        let white = RGBA(1, 1, 1, 1)
        fillPath(disc(radius), white)
        fillPath(disc(radius * (1 - 2 * AnnotationRaster.stepRing)), step.color)
        // Its number, white, its glyphs centred in the circle.
        let text = TextAnnotation(
            string: String(number), preset: .plain, font: .rounded, weight: .bold, size: AnnotationRaster.stepNumberSize * 2,
            color: white, fill: nil)
        guard let font = AnnotationTypography.font(text, unit: radius, scale: scale) else { return true }
        var attributes = AnnotationTypography.attributes(font: font)
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = Self.color(white)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text.string, attributes: attributes))
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let centre = point(circle.center)
        context.textPosition = CGPoint(x: (centre.x - glyphs.midX).rounded(), y: (centre.y - glyphs.midY).rounded())
        CTLineDraw(line, context)
        return true
    }
}

/// The bitmaps of the annotations as textures (`AnnotationRaster`), `annotation-1`: each a premultiplied `.bgra8Unorm`
/// texture of a layer at a scale, kept by what it draws (its content, its box, its space, its unit and how much of its
/// stroke is drawn: not its opacity, its pop or its rotation, which the compositor applies) and by the scale, the last
/// `kept` used, and at most `maxBytes` of them, under a lock. A layer the frames go on showing binds a texture made
/// already; one being drawn in (`draw`) makes one each frame until it is in. A layer with nothing to draw has none.
final class AnnotationRasters: Sendable {
    /// How many textures are kept.
    static let kept = 32
    /// The most bytes of textures kept: past them the oldest go first, though the latest is kept whatever its size.
    static let maxBytes = 256 << 20

    /// What a layer's bitmap depends on.
    private struct Key: Equatable {
        let content: AnnotationLayer.Content
        let rect: Rect
        let space: Rect
        let unit: Double
        let drawn: Double
        let scale: Double

        init(_ layer: AnnotationLayer, scale: Double) {
            (content, rect, space, unit, drawn, self.scale) = (layer.content, layer.rect, layer.space, layer.unit, layer.drawn, scale)
        }
    }

    private struct Entry {
        let key: Key
        let texture: (any MTLTexture)?
        let region: Rect
        let bytes: Int
    }

    private struct State {
        /// The textures last used, the latest last.
        var entries: [Entry] = []
        var bytes = 0
        var drawCount = 0
    }

    private let state = Mutex(State())

    init() {}

    /// How many textures have been made, for tests and the measures.
    var drawCount: Int { state.withLock { $0.drawCount } }

    /// How many are kept, and their bytes, for tests.
    var keptCount: (textures: Int, bytes: Int) { state.withLock { ($0.entries.count, $0.bytes) } }

    /// The texture of `layer` at `scale` (`AnnotationRaster.bitmap(of:scale:)`) and the rect it covers in the layer's
    /// coordinates; `nil` when it has nothing to draw. Kept, it is there; otherwise it is drawn now and kept.
    /// - Throws: `RenderError.metalResourceUnavailable` if CoreGraphics or Metal cannot make what it needs.
    func texture(for layer: AnnotationLayer, scale: Double, device: any MTLDevice) throws -> (texture: any MTLTexture, region: Rect)? {
        let key = Key(layer, scale: scale)
        return try state.withLock { state -> (texture: any MTLTexture, region: Rect)? in
            if let index = state.entries.firstIndex(where: { $0.key == key }) {
                let found = state.entries.remove(at: index)
                state.entries.append(found)
                return found.texture.map { ($0, found.region) }
            }
            let made = try Self.makeTexture(for: layer, scale: scale, device: device)
            let bytes = made.map { $0.texture.width * $0.texture.height * 4 } ?? 0
            // The oldest textures' memory goes before the next is kept.
            while !state.entries.isEmpty, state.entries.count >= Self.kept || state.bytes + bytes > Self.maxBytes {
                state.bytes -= state.entries.removeFirst().bytes
            }
            state.entries.append(Entry(key: key, texture: made?.texture, region: made?.region ?? Rect(x: 0, y: 0, width: 0, height: 0), bytes: bytes))
            state.bytes += bytes
            state.drawCount += 1
            return made
        }
    }

    /// `layer`'s bitmap at `scale` in a new texture; `nil` when it has nothing to draw.
    private static func makeTexture(
        for layer: AnnotationLayer, scale: Double, device: any MTLDevice
    ) throws -> (texture: any MTLTexture, region: Rect)? {
        guard let pixels = AnnotationRaster.pixels(of: layer, scale: scale), let bitmap = try AnnotationRaster.bitmap(of: layer, scale: scale)
        else { return nil }
        let (columns, rows) = (pixels.size.x, pixels.size.y)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: columns, height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("annotation texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0, withBytes: bitmap.bytes, bytesPerRow: columns * 4)
        return (texture, bitmap.region)
    }
}
