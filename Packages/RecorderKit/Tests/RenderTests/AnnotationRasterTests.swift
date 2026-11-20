// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
// @testable for `AnnotationRaster` and `AnnotationTypography`.
@testable import Render
import simd
import Testing

// The bitmaps of the annotations (`annotation-1`, phase 3 plan 3a task A6, decisions 4, 5 and 6), without Metal: each
// kind drawn where its layer says, an arrow and a shape drawn in, the same bytes every time, and the scale of the zoom.
// The layers are made here as the scene makes them, in an output of 1280 × 720.

private let space = Rect(x: 0, y: 0, width: 1280, height: 720)
private let red = RGBA.annotationRed

/// A layer of `content` in `rect`, in the output's space, shown whole unless `drawn` says.
private func layer(_ content: AnnotationLayer.Content, rect: Rect, drawn: Double = 1) -> AnnotationLayer {
    AnnotationLayer(
        id: "a-00000001", content: content, rect: rect, space: space, unit: space.height, rotation: 0, opacity: 1, scale: 1,
        drawn: drawn)
}

/// The layer of `arrow`, its rect and its path as the scene places them.
private func arrowLayer(_ arrow: ArrowAnnotation, drawn: Double = 1) -> AnnotationLayer {
    let rect = AnnotationGeometry.pixels(AnnotationGeometry.arrowRect(arrow, aspect: space.width / space.height), in: space)
    return layer(.arrow(arrow, path: AnnotationGeometry.arrow(arrow, in: space)), rect: rect, drawn: drawn)
}

/// The layer of a text `text` `width` wide at (`x`, `y`), as tall as its text measured.
private func textLayer(_ text: TextAnnotation, x: Double = 200, y: Double = 200, width: Double = 500) -> AnnotationLayer {
    let height = AnnotationTypography.box(of: text, width: width, unit: space.height).y
    return layer(.text(text), rect: Rect(x: x, y: y, width: width, height: height))
}

/// A speech bubble 300 wide at (500, 100) pointing at `target` (pixels).
private func calloutLayer(target: SIMD2<Double>) -> AnnotationLayer {
    let text = TextAnnotation(string: "Click here", preset: .label, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1))
    let callout = CalloutAnnotation(text: text, target: NormalizedPoint(x: target.x / space.width, y: target.y / space.height))
    let height = AnnotationTypography.box(of: text, width: 300, unit: space.height, padding: .label).y
    let box = Rect(x: 500, y: 100, width: 300, height: height)
    let em = text.size * space.height
    let corner = min(AnnotationTypography.calloutCornerEm * em, box.width / 2, box.height / 2)
    let tail = AnnotationGeometry.calloutTail(bubble: box, cornerRadius: corner, target: target, em: em)
    return layer(.callout(callout, tail: tail), rect: box)
}

/// A layer's bitmap at `scale`, read by points of the layer's coordinates.
private struct Bitmap {
    let bytes: [UInt8]
    let region: Rect
    let scale: Double

    init(_ layer: AnnotationLayer, scale: Double = 1) throws {
        let bitmap = try #require(try AnnotationRaster.bitmap(of: layer, scale: scale))
        (bytes, region, self.scale) = (bitmap.bytes, bitmap.region, scale)
        #expect(bytes.count == columns * rows * 4)
    }

    var columns: Int { Int((region.width * scale).rounded()) }
    var rows: Int { Int((region.height * scale).rounded()) }

    /// The BGRA pixel under `p`; transparent outside the bitmap.
    func pixel(_ p: SIMD2<Double>) -> SIMD4<Int> {
        let x = Int((p.x * scale).rounded(.down)) - Int((region.x * scale).rounded())
        let y = Int((p.y * scale).rounded(.down)) - Int((region.y * scale).rounded())
        guard x >= 0, y >= 0, x < columns, y < rows else { return .zero }
        let i = (y * columns + x) * 4
        return SIMD4(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    func alpha(_ p: SIMD2<Double>) -> Int { pixel(p).w }

    /// Whether some pixel of `rect` (the layer's coordinates) is `color`, opaque, within 1.
    func has(_ color: RGBA, in rect: Rect) -> Bool {
        let expected = SIMD4(Int((color.b * 255).rounded()), Int((color.g * 255).rounded()), Int((color.r * 255).rounded()), 255)
        var y = rect.y
        while y < rect.y + rect.height {
            var x = rect.x
            while x < rect.x + rect.width {
                let d = pixel(SIMD2(x, y)) &- expected
                if max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= 1 { return true }
                x += 1 / scale
            }
            y += 1 / scale
        }
        return false
    }
}

/// BGRA of `color`, opaque.
private func bgra(_ color: RGBA) -> SIMD4<Int> {
    SIMD4(Int((color.b * 255).rounded()), Int((color.g * 255).rounded()), Int((color.r * 255).rounded()), 255)
}

private func close(_ a: SIMD4<Int>, _ b: SIMD4<Int>, _ tolerance: Int = 1) -> Bool {
    let d = a &- b
    return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= tolerance
}

@Test func eachKindRasters() throws {
    // A filled arrow: its head, its shaft, and nothing beside it; the tip at `to`.
    let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.6, y: 0.5), head: .filled)
    let filled = arrowLayer(arrow)
    let w = arrow.width * space.height
    let bitmap = try Bitmap(filled)
    let tip = SIMD2(0.6 * 1280, 0.5 * 720)
    #expect(close(bitmap.pixel(tip - SIMD2(1.5 * w, 0)), bgra(red)), "inside the head")
    #expect(bitmap.alpha(tip + SIMD2(2, 0)) == 0, "past the tip")
    #expect(close(bitmap.pixel(SIMD2(0.4 * 1280, 360)), bgra(red)), "on the shaft")
    #expect(bitmap.alpha(SIMD2(0.4 * 1280, 360 + 3 * w)) == 0, "beside the shaft")
    #expect(bitmap.alpha(SIMD2(0.6 * 1280 - 3 * w, 360 + 1.2 * w)) == 255, "the head's width")
    // An open one: its two strokes; nothing between them past the shaft.
    var open = arrow
    open.head = .open
    let openBitmap = try Bitmap(arrowLayer(open))
    let path = AnnotationGeometry.arrow(open, in: space)
    #expect(openBitmap.alpha((path.head[0] * 0.8 + path.head[1] * 0.2)) == 255, "one stroke")
    #expect(openBitmap.alpha((path.head[2] * 0.8 + path.head[1] * 0.2)) == 255, "the other")
    // A shape: its border inside its rect, nothing inside it without a fill, the fill with one.
    let rect = Rect(x: 400, y: 200, width: 300, height: 200)
    let border = ShapeAnnotation(shape: .rect, width: 0.004)
    let stroke = border.width * space.height
    let shape = try Bitmap(layer(.shape(border), rect: rect))
    #expect(close(shape.pixel(SIMD2(rect.x + stroke / 2, 300)), bgra(red)), "the left border")
    #expect(shape.alpha(SIMD2(rect.x - 1.5, 300)) == 0, "outside it")
    #expect(shape.alpha(SIMD2(550, 300)) == 0, "inside it")
    var filledShape = border
    filledShape.fill = RGBA(0, 1, 0, 1)
    for kind in AnnotationShape.allCases {
        filledShape.shape = kind
        let drawn = try Bitmap(layer(.shape(filledShape), rect: rect))
        #expect(close(drawn.pixel(SIMD2(550, 300)), bgra(RGBA(0, 1, 0, 1))), "\(kind)")
    }
    // A rounded rectangle's and an ellipse's corners are empty.
    filledShape.shape = .ellipse
    #expect(try Bitmap(layer(.shape(filledShape), rect: rect)).alpha(SIMD2(rect.x + 3, rect.y + 3)) == 0)
    // A speech bubble: white, its tail down to its point, its text black.
    let target = SIMD2(650.0, 320)
    let callout = calloutLayer(target: target)
    let bubble = try Bitmap(callout)
    let tail = try #require({ if case let .callout(_, tail) = callout.content { return tail } else { return nil } }())
    let inTheTail = (tail.baseStart + tail.baseEnd) / 2 * 0.6 + tail.tip * 0.4
    #expect(close(bubble.pixel(inTheTail), bgra(RGBA(1, 1, 1, 1))), "in the tail")
    #expect(bubble.alpha(tail.tip + SIMD2(0, 3)) == 0, "past its point")
    #expect(bubble.has(RGBA(0, 0, 0, 1), in: callout.rect), "its text")
    // A step: a white ring, its colour, its number white at its centre.
    let stepRect = Rect(x: 600, y: 300, width: 80, height: 60)
    let step = try Bitmap(layer(.step(StepAnnotation(), number: 1), rect: stepRect))
    let centre = SIMD2(640.0, 330), d = 60.0
    #expect(close(step.pixel(centre + SIMD2(0, 0.47 * d)), bgra(RGBA(1, 1, 1, 1)), 2), "the ring")
    #expect(close(step.pixel(centre + SIMD2(0.31 * d, 0)), bgra(red)), "its colour")
    #expect(close(step.pixel(centre - SIMD2(0.31 * d, 0)), bgra(red)), "its colour, on the other side")
    #expect(step.has(RGBA(1, 1, 1, 1), in: Rect(x: centre.x - 0.12 * d, y: centre.y - 0.12 * d, width: 0.24 * d, height: 0.24 * d)), "its number")
    #expect(step.alpha(centre + SIMD2(0.4 * d, 0.4 * d)) == 0, "outside the circle")
}

@Test func textsInTheirFourStyles() throws {
    let white = RGBA(1, 1, 1, 1)
    // A Label: its pill in its fill (black at 70 %), its text.
    let label = textLayer(TextAnnotation(string: "Label", preset: .label))
    let em = 0.05 * 720
    let pill = try Bitmap(label)
    let padding = pill.pixel(SIMD2(label.rect.x + 0.3 * em, label.rect.y + 0.15 * em))
    #expect(abs(padding.w - 179) <= 1 && padding.x == 0 && padding.y == 0 && padding.z == 0, "\(padding)")
    #expect(pill.has(white, in: label.rect))
    #expect(pill.alpha(SIMD2(label.rect.x - 2, label.rect.y + label.rect.height / 2)) == 0)
    // A Lower third: its bar in the text's colour along its left edge.
    let lowerThird = textLayer(TextAnnotation(string: "Ana Pérez", preset: .lowerThird, color: RGBA(1, 0.8, 0, 1)))
    let lower = try Bitmap(lowerThird)
    #expect(close(lower.pixel(SIMD2(lowerThird.rect.x + 0.06 * em, lowerThird.rect.y + lowerThird.rect.height / 2)), bgra(RGBA(1, 0.8, 0, 1))))
    #expect(lower.pixel(SIMD2(lowerThird.rect.x + 0.3 * em, lowerThird.rect.y + lowerThird.rect.height / 2)).w - 179 <= 1)
    // Plain and Title: the text, and its shadow under it (black, translucent) where the text is not.
    for preset in [TextPreset.plain, .title] {
        let plain = textLayer(TextAnnotation(string: "Hello", preset: preset, size: 0.08))
        let text = try Bitmap(plain)
        #expect(text.has(white, in: plain.rect), "\(preset)")
        var shadowed = 0
        for i in stride(from: 0, to: text.bytes.count, by: 4) where text.bytes[i + 3] > 0 && text.bytes[i + 3] < 160 && text.bytes[i + 2] == 0 {
            shadowed += 1
        }
        #expect(shadowed > 50, "\(preset): \(shadowed) pixels of shadow")
    }
    // A text breaks where the scene measured it: two lines in a box as tall as two.
    let narrow = TextAnnotation(string: "One two three four five six", preset: .plain)
    let lines = try #require(AnnotationTypography.lines(of: narrow, width: 220, unit: 720))
    #expect(lines.count >= 2)
    let tall = textLayer(narrow, width: 220)
    let font = try #require(AnnotationTypography.font(narrow, unit: 720, scale: 1))
    #expect(abs(tall.rect.height - Double(lines.count) * AnnotationTypography.lineHeight(of: font)) < 1e-9)
    let wrapped = try Bitmap(tall)
    let lastLine = Rect(
        x: tall.rect.x, y: tall.rect.y + tall.rect.height - AnnotationTypography.lineHeight(of: font), width: tall.rect.width,
        height: AnnotationTypography.lineHeight(of: font))
    #expect(wrapped.has(white, in: lastLine), "its last line, at the bottom of its box")
    // An empty text without a box draws nothing.
    #expect(try AnnotationRaster.bitmap(of: textLayer(TextAnnotation(string: "", preset: .plain)), scale: 1) == nil)
    // Nor do an image or a clip here.
    let image = layer(.image(ImageAnnotation(asset: "assets/x.png", fit: .fit)), rect: Rect(x: 0, y: 0, width: 10, height: 10))
    #expect(try AnnotationRaster.bitmap(of: image, scale: 1) == nil)
}

@Test func drawProgressCutsTheStroke() throws {
    let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.6, y: 0.5), head: .filled)
    let w = arrow.width * 720
    let tip = SIMD2(0.6 * 1280, 360)
    let half = try Bitmap(arrowLayer(arrow, drawn: 0.5))
    #expect(half.alpha(tip - SIMD2(1.5 * w, 0)) == 0, "the head, not yet")
    #expect(half.alpha(SIMD2(0.2 * 1280 + 0.7 * 0.4 * 1280, 360)) == 0, "the last part of the shaft")
    #expect(half.alpha(SIMD2(0.2 * 1280 + 0.3 * 0.4 * 1280, 360)) == 255, "its first part")
    // Nearly drawn: the head comes in from its base.
    let nearly = try Bitmap(arrowLayer(arrow, drawn: 0.99))
    let headLength = 4.5 * w
    #expect(nearly.alpha(tip - SIMD2(0.9 * headLength, 0)) == 255, "the head's base")
    #expect(nearly.alpha(tip - SIMD2(0.5, 0)) == 0, "not its tip")
    #expect(try Bitmap(arrowLayer(arrow, drawn: 1)).alpha(tip - SIMD2(1.5, 0)) > 0)
    #expect(try AnnotationRaster.bitmap(of: arrowLayer(arrow, drawn: 0), scale: 1) == nil, "nothing drawn yet")
    // A shape's border: half of it drawn at 0.5, all of it at 1; its fill at half its alpha.
    let rect = Rect(x: 400, y: 200, width: 300, height: 300)
    let shape = ShapeAnnotation(shape: .rect, width: 0.004, fill: RGBA(0, 1, 0, 1))
    let stroke = shape.width * 720
    let middles = [
        SIMD2(550, rect.y + stroke / 2), SIMD2(rect.x + rect.width - stroke / 2, 350), SIMD2(550, rect.y + rect.height - stroke / 2),
        SIMD2(rect.x + stroke / 2, 350),
    ]
    let halfShape = try Bitmap(layer(.shape(shape), rect: rect, drawn: 0.5))
    let drawnSides = middles.filter { close(halfShape.pixel($0), bgra(red), 2) }.count
    #expect(drawnSides == 2, "two sides of four at half")
    #expect(abs(halfShape.pixel(SIMD2(550, 350)).w - 128) <= 1, "the fill at half")
    let whole = try Bitmap(layer(.shape(shape), rect: rect, drawn: 1))
    #expect(middles.allSatisfy { close(whole.pixel($0), bgra(red), 2) })
    for kind in [AnnotationShape.roundedRect, .ellipse] {
        var other = shape
        other.shape = kind
        other.fill = nil
        let quarter = try Bitmap(layer(.shape(other), rect: rect, drawn: 0.3))
        let full = try Bitmap(layer(.shape(other), rect: rect, drawn: 1))
        let count = { (bitmap: Bitmap) in stride(from: 3, to: bitmap.bytes.count, by: 4).filter { bitmap.bytes[$0] > 128 }.count }
        let ratio = Double(count(quarter)) / Double(count(full))
        #expect(ratio > 0.22 && ratio < 0.38, "\(kind): \(ratio)")
    }
}

@Test func rasterIsDeterministic() throws {
    let arrow = ArrowAnnotation(
        from: NormalizedPoint(x: 0.1, y: 0.7), to: NormalizedPoint(x: 0.5, y: 0.3), curve: 0.4, head: .filled)
    let layers = [
        textLayer(TextAnnotation(string: "Título de prueba", preset: .title, font: .serif, weight: .heavy, size: 0.07)),
        textLayer(TextAnnotation(string: "Etiqueta", preset: .label, font: .rounded)),
        textLayer(TextAnnotation(string: "Ana Pérez\nDiseño", preset: .lowerThird, font: .mono, align: .leading)),
        arrowLayer(arrow), arrowLayer(arrow, drawn: 0.4),
        layer(.shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(0, 0, 1, 0.3))), rect: Rect(x: 100, y: 100, width: 400, height: 200)),
        calloutLayer(target: SIMD2(300, 400)),
        layer(.step(StepAnnotation(color: RGBA(0, 0.5, 1, 1)), number: 12), rect: Rect(x: 50, y: 50, width: 60, height: 60)),
    ]
    for scale in [1, 2.0.squareRoot(), 2] {
        let first = try layers.map { try AnnotationRaster.bitmap(of: $0, scale: scale) }
        let second = try layers.reversed().map { try AnnotationRaster.bitmap(of: $0, scale: scale) }.reversed()
        for (a, b) in zip(first, second) {
            let a = try #require(a), b = try #require(b)
            #expect(a.bytes == b.bytes && a.region == b.region, "at \(scale)")
        }
    }
}

@Test func zoomScaleStepsBySquareRootOfTwo() {
    let shape = layer(.shape(ShapeAnnotation(shape: .rect)), rect: Rect(x: 100, y: 100, width: 200, height: 100))
    let root2 = 2.0.squareRoot()
    #expect(AnnotationRaster.scale(for: shape, depth: 1) == 1)
    #expect(AnnotationRaster.scale(for: shape, depth: 0.8) == 1)
    #expect(AnnotationRaster.scale(for: shape, depth: .nan) == 1)
    #expect(AnnotationRaster.scale(for: shape, depth: 1.01) == root2)
    #expect(AnnotationRaster.scale(for: shape, depth: root2) == root2)
    #expect(AnnotationRaster.scale(for: shape, depth: 1.5) == 2)
    #expect(AnnotationRaster.scale(for: shape, depth: 2) == 2)
    #expect(AnnotationRaster.scale(for: shape, depth: 2.5) == 2 * root2)
    // Never more pixels than it may have: a large one magnified past them.
    let large = layer(.shape(ShapeAnnotation(shape: .rect)), rect: Rect(x: 0, y: 0, width: 1500, height: 900))
    let scale = AnnotationRaster.scale(for: large, depth: 8)
    let pixels = AnnotationRaster.pixels(of: large, scale: scale)!
    #expect(scale < 8 && pixels.size.x * pixels.size.y <= AnnotationRaster.maxZoomedPixels, "\(scale)")
    // The region is whole pixels of the bitmap, around what it touches.
    let region = AnnotationRaster.region(of: shape, scale: 2)!
    #expect(region.x * 2 == (region.x * 2).rounded() && region.x <= 100 && region.x + region.width >= 300)
}
