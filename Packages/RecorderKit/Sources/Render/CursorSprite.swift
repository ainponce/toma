// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Metal
import ProjectFormat

/// Toma's cursors (design §7.5): originals drawn in code with CoreGraphics, black with a white outline (no Apple
/// artwork), each into a premultiplied BGRA texture 128 px tall that stands for 24 pt.
///
/// - The arrow (phase 0's, unchanged): 96 × 128, its tip at the top-left corner.
/// - The I-beam (64 × 128), the crosshair, the two resize arrows and the open and closed hands (128 × 128): their
///   centre at the pointer.
/// - The pointing hand (128 × 128): the tip of its finger at the pointer.
/// - Not allowed (128 × 128): the arrow with a no-entry badge, its tip at the pointer.
///
/// Each mip level is drawn from the vector shape at its own size, so a cursor stays crisp at the 20–50 px it is usually
/// shown at.
public enum CursorSprite {
    /// The point of the arrow placed at the cursor position, as a fraction of its size (0, 0 is the top-left corner): its
    /// tip.
    public static let hotspot = SIMD2<Double>(0, 0)
    /// Width over height of the arrow.
    public static let aspect = 0.75

    static let width = 96
    static let height = 128
    /// Half the outline's width, in pixels of level 0: the arrow's path is inset by it, so the outline
    /// fits inside the sprite and its outer edge reaches the top-left corner.
    private static let outline = 6.0
    /// The arrow's path, in fractions of the inset height, y growing down, tip first.
    private static let arrow: [SIMD2<Double>] = [
        [0, 0], [0, 0.78], [0.19, 0.615], [0.31, 0.885], [0.43, 0.835], [0.315, 0.575], [0.55, 0.575],
    ]

    /// The point of the cursor of `kind` placed at the cursor position, as a fraction of its size.
    public static func hotspot(of kind: CursorKind) -> SIMD2<Double> {
        switch kind {
        case .arrow, .notAllowed: hotspot
        case .pointingHand: SIMD2(49, 8) / Double(height)
        case .iBeam, .openHand, .closedHand, .crosshair, .resizeLeftRight, .resizeUpDown: SIMD2(0.5, 0.5)
        }
    }

    /// Width over height of the cursor of `kind`.
    public static func aspect(of kind: CursorKind) -> Double {
        Double(width(of: kind)) / Double(height)
    }

    /// The arrow.
    public static func makeTexture(device: any MTLDevice) throws -> any MTLTexture {
        try makeTexture(device: device, kind: .arrow)
    }

    /// The cursor of `kind`, `.bgra8Unorm` with mipmaps, `128 × aspect(of: kind)` by 128 pixels.
    public static func makeTexture(device: any MTLDevice, kind: CursorKind) throws -> any MTLTexture {
        let width = width(of: kind)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("cursor texture")
        }
        for level in 0..<texture.mipmapLevelCount {
            let levelWidth = max(1, width >> level), levelHeight = max(1, height >> level)
            let bytes = try draw(kind, width: levelWidth, height: levelHeight)
            texture.replace(
                region: MTLRegionMake2D(0, 0, levelWidth, levelHeight), mipmapLevel: level,
                withBytes: bytes, bytesPerRow: levelWidth * 4)
        }
        return texture
    }

    /// The width of level 0 of the cursor of `kind`.
    private static func width(of kind: CursorKind) -> Int {
        switch kind {
        case .arrow: width
        case .iBeam: 64
        case .pointingHand, .openHand, .closedHand, .crosshair, .resizeLeftRight, .resizeUpDown, .notAllowed: 128
        }
    }

    /// The cursor of `kind` scaled to `width`×`height`, as premultiplied BGRA rows from the top.
    private static func draw(_ kind: CursorKind, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("cursor bitmap") }
            // Level-0 pixels, y down, origin at the top left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: CGFloat(width) / CGFloat(Self.width(of: kind)), y: -CGFloat(height) / CGFloat(Self.height))
            switch kind {
            case .arrow: drawArrow(in: context)
            case .iBeam: drawIBeam(in: context)
            case .pointingHand: drawPointingHand(in: context)
            case .openHand: drawOpenHand(in: context)
            case .closedHand: drawClosedHand(in: context)
            case .crosshair: drawCrosshair(in: context)
            case .resizeLeftRight: outlined(polygon(resizeArrow), in: context)
            case .resizeUpDown: outlined(polygon(resizeArrow.map { SIMD2($0.y, $0.x) }), in: context)
            case .notAllowed: drawNotAllowed(in: context)
            }
        }
        return bytes
    }

    // MARK: - The shapes, in pixels of level 0, y down

    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// `path` filled black with the white outline around it: stroked `2 × outline` wide, then filled over the stroke's
    /// inner half. The subpaths of `path` are joined (nonzero winding), and the outline runs around them all.
    private static func outlined(_ path: CGPath, in context: CGContext) {
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(2 * outline)
        context.setStrokeColor(white)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(black)
        context.fillPath()
    }

    /// A closed path through `points`.
    private static func polygon(_ points: [SIMD2<Double>]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
        path.closeSubpath()
        return path
    }

    /// Rounded rects (`x`, `y`, `width`, `height`, corner radius) as the subpaths of one path, each turned by its
    /// `degrees` about its pivot when it has one.
    private static func rounded(
        _ rects: [(x: Double, y: Double, width: Double, height: Double, radius: Double, turn: (degrees: Double, pivot: SIMD2<Double>)?)]
    ) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            var transform = CGAffineTransform.identity
            if let turn = rect.turn {
                transform = CGAffineTransform(translationX: turn.pivot.x, y: turn.pivot.y)
                    .rotated(by: turn.degrees * .pi / 180)
                    .translatedBy(x: -turn.pivot.x, y: -turn.pivot.y)
            }
            path.addRoundedRect(
                in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), cornerWidth: rect.radius,
                cornerHeight: rect.radius, transform: transform)
        }
        return path
    }

    /// White lines `width` wide from each first point to its second: the creases between fingers.
    private static func creases(_ lines: [(SIMD2<Double>, SIMD2<Double>)], width: Double = 3, in context: CGContext) {
        for (from, to) in lines {
            context.move(to: CGPoint(x: from.x, y: from.y))
            context.addLine(to: CGPoint(x: to.x, y: to.y))
        }
        context.setLineCap(.round)
        context.setLineWidth(width)
        context.setStrokeColor(white)
        context.strokePath()
    }

    /// The arrow, as phase 0 draws it.
    private static func drawArrow(in context: CGContext) {
        let scale = Double(Self.height) - 2 * outline
        outlined(polygon(arrow.map { SIMD2(outline + $0.x * scale, outline + $0.y * scale) }), in: context)
    }

    /// A stem 8 px wide between two serifs, 96 px from top to bottom.
    private static func drawIBeam(in context: CGContext) {
        outlined(polygon([
            [14, 14], [50, 14], [50, 22], [36, 22], [36, 106], [50, 106], [50, 114], [14, 114], [14, 106], [28, 106],
            [28, 22], [14, 22],
        ]), in: context)
    }

    /// Four arms 6 px thick around a free centre.
    private static func drawCrosshair(in context: CGContext) {
        let path = CGMutablePath()
        for rect in [
            CGRect(x: 72, y: 61, width: 38, height: 6), CGRect(x: 18, y: 61, width: 38, height: 6),
            CGRect(x: 61, y: 18, width: 6, height: 38), CGRect(x: 61, y: 72, width: 6, height: 38),
        ] {
            path.addRect(rect)
        }
        outlined(path, in: context)
    }

    /// A double-headed arrow from left to right; `.resizeUpDown` is it with x and y swapped.
    private static let resizeArrow: [SIMD2<Double>] = [
        [14, 64], [42, 38], [42, 56], [86, 56], [86, 38], [114, 64], [86, 90], [86, 72], [42, 72], [42, 90],
    ]

    /// The index finger up, the other three folded over the palm, the thumb to the left.
    private static func drawPointingHand(in context: CGContext) {
        outlined(rounded([
            (38, 10, 22, 70, 11, nil),
            (60, 46, 20, 40, 10, nil),
            (80, 52, 19, 38, 9.5, nil),
            (99, 60, 17, 34, 8.5, nil),
            (14, 72, 32, 22, 11, nil),
            (30, 66, 86, 54, 18, nil),
        ]), in: context)
        creases([([60, 50], [60, 80]), ([80, 56], [80, 84]), ([99, 64], [99, 88])], in: context)
    }

    /// Four fingers apart over the palm, the thumb out to the left.
    private static func drawOpenHand(in context: CGContext) {
        outlined(rounded([
            (40, 20, 17, 56, 8.5, nil),
            (59, 12, 17, 64, 8.5, nil),
            (78, 18, 17, 58, 8.5, nil),
            (97, 32, 15, 48, 7.5, nil),
            (30, 66, 18, 38, 9, (-30, [48, 104])),
            (38, 62, 74, 56, 20, nil),
        ]), in: context)
    }

    /// The fingers folded into the palm, their knuckles on top, the thumb across.
    private static func drawClosedHand(in context: CGContext) {
        outlined(rounded([
            (38, 36, 18, 34, 9, nil),
            (58, 36, 18, 34, 9, nil),
            (78, 36, 18, 34, 9, nil),
            (98, 40, 16, 30, 8, nil),
            (36, 52, 78, 60, 20, nil),
            (18, 66, 32, 22, 11, nil),
        ]), in: context)
        creases([([57, 40], [57, 58]), ([77, 40], [77, 58]), ([97, 44], [97, 58])], in: context)
    }

    /// The arrow with a no-entry badge at its bottom right: a ring and its bar, black on white.
    private static func drawNotAllowed(in context: CGContext) {
        drawArrow(in: context)
        let centre = CGPoint(x: 96, y: 96), ring = 22.0, inner = 15.0
        func disc(_ radius: Double, _ color: CGColor) {
            context.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            context.setFillColor(color)
            context.fillPath()
        }
        disc(ring + outline, white)
        disc(ring, black)
        disc(inner, white)
        // The bar, from top left to bottom right, cut by the ring.
        context.saveGState()
        context.addEllipse(in: CGRect(x: centre.x - inner, y: centre.y - inner, width: 2 * inner, height: 2 * inner))
        context.clip()
        context.move(to: CGPoint(x: centre.x - ring, y: centre.y - ring))
        context.addLine(to: CGPoint(x: centre.x + ring, y: centre.y + ring))
        context.setLineCap(.butt)
        context.setLineWidth(7)
        context.setStrokeColor(black)
        context.strokePath()
        context.restoreGState()
    }
}
