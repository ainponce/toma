// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `CalmZoomLook`, `DrawCounts`, the compositor's counting `encode` and its calm zoom's textures.
@testable import Render
import simd
import Testing

/// The calm zoom drawn (phase 3 design §6 and §12, step 4, plan 3b Task Z3, `calmZoom-1` and `loupe-1`): Highlight in the
/// pass of the stage, Dim and the loupe from a copy of the frame as drawn in a pass of their own into the target, under
/// the camera, the keys and the captions, on every path of the compositor; nothing at all without a layer that shows. Over
/// frames made here, 1280 × 720 (a point is 2/3 of a pixel) unless said otherwise.

private let size = SIMD2(1280, 720)
private let whole = Rect(x: 0, y: 0, width: 1280, height: 720)
/// The focus, about the output's centre.
private let focus = Rect(x: 400, y: 200, width: 480, height: 320)
private let centre = SIMD2(640.0, 360.0)
private let gradientStart: SIMD4<Float> = [0.25, 0.35, 0.55, 1], gradientEnd: SIMD4<Float> = [0.65, 0.45, 0.25, 1]

/// The calm zoom `mode` of the focus at `amount`, with a circle of 200 px and 2× in the loupe.
private func calm(_ mode: ZoomMode, amount: Double = 1, focus: Rect = focus, loupe: LoupeLayer? = nil) -> CalmZoomLayer {
    CalmZoomLayer(
        mode: mode, amount: amount, focus: focus,
        loupe: mode == .loupe ? loupe ?? LoupeLayer(radius: 200, shape: .circle, magnification: 2) : nil)
}

/// A frame of `outputSize` with the screen over all of it, on a gradient, and the calm zoom `layer`.
private func frame(_ layer: CalmZoomLayer?, outputSize: SIMD2<Int> = size, screen: Bool = true) -> RenderFrame {
    let rect = Rect(x: 0, y: 0, width: Double(outputSize.x), height: Double(outputSize.y))
    return RenderFrame(
        outputSize: outputSize, gradientStart: gradientStart, gradientEnd: gradientEnd, gradientAngleDegrees: 30,
        screen: screen ? ScreenLayer(trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 0) : nil, calmZoom: layer)
}

/// A camera in the bottom-right corner.
private let cameraLayer = CameraLayer(
    trackID: cameraID, sourceTime: base, rect: Rect(x: 1000, y: 480, width: 240, height: 180), cornerRadius: 16)

/// A compositor of the default device with the textures its frames are drawn with: `StageDrawing`'s smooth screen (what a
/// pixel shows says where it is), a black and white checkerboard of 2 px squares as big as the output, a camera and
/// Toma's arrow.
private final class CalmDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let smooth: any MTLTexture
    let checker: any MTLTexture
    let camera: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        smooth = try StageDrawing.screenTexture(device: device)
        camera = try StageDrawing.screenTexture(device: device, width: 64, height: 48)
        cursor = try CursorSprite.makeTexture(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        checker = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 255, count: size.x * size.y * 4)
        for y in 0..<size.y {
            for x in 0..<size.x where (x / 2 + y / 2) % 2 == 1 {
                let i = (y * size.x + x) * 4
                (bytes[i], bytes[i + 1], bytes[i + 2]) = (0, 0, 0)
            }
        }
        checker.replace(region: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size.x * 4)
    }

    /// `frame` drawn into a new target of its output size over `screen` (the smooth one by default), as BGRA bytes, with
    /// what was drawn counted in `counts`.
    func draw(_ frame: RenderFrame, screen: (any MTLTexture)? = nil, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen ?? smooth, camera: camera, cursor: cursor, into: target, commandBuffer: commandBuffer,
            counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        return StageDrawing.bytes(of: target)
    }

    func draw(_ frame: RenderFrame, screen: (any MTLTexture)? = nil) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, screen: screen, counts: &counts)
    }

    var textures: CalmZoomTextures { compositor.layers.calmZoom.textures }
}

/// Pixel (`x`, `y`) of an image of `width`, its four channels as integers.
private func at(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int = size.x) -> SIMD4<Double> {
    let p = pixel(bytes, width: width, x: x, y: y)
    return SIMD4(Double(p.x), Double(p.y), Double(p.z), Double(p.w))
}

/// Whether `a` and `b` are within `tolerance` in every channel.
private func near(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ tolerance: Double) -> Bool {
    (0..<4).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
}

/// `p`'s colour times `k`, its alpha as it is.
private func darker(_ p: SIMD4<Double>, _ k: Double) -> SIMD4<Double> {
    SIMD4(p.x * k, p.y * k, p.z * k, p.w)
}

/// The image `bytes` of `width` read bilinearly at `q` (output pixels, the centre of pixel (0, 0) at (0.5, 0.5)).
private func bilinear(_ bytes: [UInt8], at q: SIMD2<Double>, width: Int = size.x) -> SIMD4<Double> {
    let p = q - 0.5, x0 = Int(p.x.rounded(.down)), y0 = Int(p.y.rounded(.down))
    let fx = p.x - Double(x0), fy = p.y - Double(y0)
    func texel(_ x: Int, _ y: Int) -> SIMD4<Double> { at(bytes, min(max(x, 0), width - 1), min(max(y, 0), size.y - 1), width: width) }
    let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
    let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
    return top * (1 - fy) + bottom * fy
}

/// The signed distance from pixel (`x`, `y`)'s centre to the focus `rect` with corners of `corner` (negative inside).
private func distance(_ x: Int, _ y: Int, to rect: Rect, corner: Double) -> Double {
    let half = SIMD2(rect.width, rect.height) / 2
    return CalmZoomLook.roundedRectDistance(
        SIMD2(Double(x) + 0.5, Double(y) + 0.5) - (SIMD2(rect.x, rect.y) + half), halfSize: half,
        radius: min(corner, min(half.x, half.y)))
}

/// Every pixel of an image of `outputSize`, with `stride` between those taken.
private func pixels(of outputSize: SIMD2<Int> = size, stride step: Int = 1) -> [(x: Int, y: Int)] {
    stride(from: 0, to: outputSize.y, by: step).flatMap { y in stride(from: 0, to: outputSize.x, by: step).map { (x: $0, y: y) } }
}

/// The smallest rect of pixels where `a` and `b` differ by more than 8 in a channel.
private func differingBounds(_ a: [UInt8], _ b: [UInt8]) -> (low: SIMD2<Int>, high: SIMD2<Int>)? {
    var low = SIMD2(Int.max, Int.max), high = SIMD2(Int.min, Int.min)
    for (x, y) in pixels() where !near(at(a, x, y), at(b, x, y), 8) {
        low = pointwiseMin(low, SIMD2(x, y))
        high = pointwiseMax(high, SIMD2(x, y))
    }
    return low.x == .max ? nil : (low, high)
}

/// The three modes drawn by the compositor.
@Suite struct CalmZoomDrawTests {
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func nothingAtZeroAmountOrWithoutALayer() throws {
        let drawer = try CalmDrawer()
        var blurred = frame(nil)
        blurred.subframes = [
            StageSubframe(stage: StageTransform(depth: 1, center: centre)),
            StageSubframe(stage: StageTransform(depth: 1.05, center: centre)),
        ]
        var card = frame(nil)
        card.card = CardPlacement(
            rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12,
            content: StageTransform(depth: 1.5, center: [400, 300]), mix: 1)
        card.backgroundTransform = .identity(outputSize: size)
        let unseen: [CalmZoomLayer?] = [
            nil, CalmZoomLayer(), calm(.classic), calm(.highlight, amount: 0), calm(.dim, amount: 0), calm(.loupe, amount: 0),
            calm(.dim, amount: .nan), calm(.highlight, amount: -1), CalmZoomLayer(mode: .loupe, amount: 1, focus: focus),
            calm(.loupe, loupe: LoupeLayer(radius: 0, shape: .circle, magnification: 2)),
            calm(.dim, focus: Rect(x: .nan, y: 0, width: 10, height: 10)),
        ]
        for base in [frame(nil), blurred, card] {
            var plainCounts = DrawCounts()
            let plain = try drawer.draw(base, counts: &plainCounts)
            #expect(plainCounts.stageOverlaySteps == 1 && plainCounts.calmZooms == 0)
            for layer in unseen {
                var drawn = base
                drawn.calmZoom = layer
                var counts = DrawCounts()
                #expect(try drawer.draw(drawn, counts: &counts) == plain, "\(String(describing: layer))")
                #expect(counts == plainCounts, "\(String(describing: layer)): \(counts)")
            }
        }
        #expect(drawer.textures.count.made == 0)
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func highlightDarkensOutsideAndRingsTheFocus() throws {
        let drawer = try CalmDrawer()
        let plain = try drawer.draw(frame(nil))
        var counts = DrawCounts()
        let lit = try drawer.draw(frame(calm(.highlight)), counts: &counts)
        #expect(counts.renderPasses == 1 && counts.calmZooms == 1 && counts.calmZoomSamples == 0, "\(counts)")
        let pt = 2.0 / 3, corner = 12 * pt, ring = 3 * pt
        var inside = 0, outside = 0
        for (x, y) in pixels(stride: 3) {
            let d = distance(x, y, to: focus, corner: corner)
            if d <= -1 {
                #expect(at(lit, x, y) == at(plain, x, y), "inside at (\(x), \(y))")
                inside += 1
            } else if d > ring + 6 * 6 * pt {
                #expect(
                    near(at(lit, x, y), darker(at(plain, x, y), 0.8), 1),
                    "outside at (\(x), \(y)): \(at(lit, x, y)) \(at(plain, x, y))")
                outside += 1
            }
        }
        #expect(inside > 10_000 && outside > 10_000)
        // On the ring, just outside the focus's edges, nearly white; past it, the glow fades into the darkened rest.
        for (x, y) in [(880, 360), (399, 360), (640, 199), (640, 520)] {
            let p = at(lit, x, y)
            #expect(p.x >= 230 && p.y >= 230 && p.z >= 230, "ring at (\(x), \(y)): \(p)")
        }
        let glow = (883...900).map { at(lit, $0, 360).y - 0.8 * at(plain, $0, 360).y }
        #expect(glow.first! > 20 && glow.last! < 3 && zip(glow, glow.dropFirst()).allSatisfy { $1 <= $0 + 1 }, "\(glow)")
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func dimDarkensAndBlursOutsideOnly() throws {
        let drawer = try CalmDrawer()
        let plain = try drawer.draw(frame(nil), screen: drawer.checker)
        var counts = DrawCounts()
        let dimmed = try drawer.draw(frame(calm(.dim)), screen: drawer.checker, counts: &counts)
        #expect(counts.renderPasses == 2 && counts.calmZooms == 1 && counts.calmZoomSamples == 1, "\(counts)")
        let pt = 2.0 / 3, corner = 12 * pt, transition = 24 * pt
        // The checkerboard averages to 127.5: outside, 40 % of it.
        let average = SIMD4(0.4 * 127.5, 0.4 * 127.5, 0.4 * 127.5, 255)
        var inside = 0, outside = 0
        for (x, y) in pixels(stride: 3) {
            let d = distance(x, y, to: focus, corner: corner)
            if d <= -0.5 {
                #expect(at(dimmed, x, y) == at(plain, x, y), "inside at (\(x), \(y))")
                inside += 1
            } else if d >= transition, x >= 24, x < size.x - 24, y >= 24, y < size.y - 24 {
                // (Not by the output's edges, where the blur reads the edge's squares again.)
                #expect(near(at(dimmed, x, y), average, 3), "outside at (\(x), \(y)): \(at(dimmed, x, y))")
                outside += 1
            }
        }
        #expect(inside > 10_000 && outside > 10_000)
        // Across the 24 pt from the focus's right edge outward, how much of the dimmed picture each pixel is grows from 0 to 1
        // without a jump.
        let weights = (880..<(880 + Int(transition) + 2)).map { x -> Double in
            let sharp = at(plain, x, 360).y, shown = at(dimmed, x, 360).y
            return sharp > 127 ? (sharp - shown) / (sharp - average.y) : shown / average.y
        }
        #expect(weights.first! < 0.05 && weights.last! > 0.95, "\(weights)")
        #expect(zip(weights, weights.dropFirst()).allSatisfy { $1 >= $0 - 0.04 && $1 - $0 <= 0.15 }, "\(weights)")
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func loupeShowsWhatIsUnderMagnified() throws {
        let drawer = try CalmDrawer()
        let plain = try drawer.draw(frame(nil))
        var counts = DrawCounts()
        let lensed = try drawer.draw(frame(calm(.loupe)), counts: &counts)
        #expect(counts.renderPasses == 2 && counts.calmZooms == 1 && counts.calmZoomSamples == 1, "\(counts)")
        let r = 200.0, pt = 2.0 / 3
        var under = 0, beyond = 0
        for (x, y) in pixels(stride: 5) {
            let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5), d = simd_length(p - centre)
            if d < 0.8 * r {
                let expected = bilinear(plain, at: centre + (p - centre) / 2)
                #expect(near(at(lensed, x, y), expected, 2), "under at (\(x), \(y)): \(at(lensed, x, y)) \(expected)")
                under += 1
            } else if d > r + 4 * pt + 3 * 12 * pt + 2 {
                #expect(at(lensed, x, y) == at(plain, x, y), "beyond at (\(x), \(y))")
                beyond += 1
            }
        }
        #expect(under > 2500 && beyond > 20_000)
        // The ring on its edge, lighter; its shadow under it, darker.
        #expect(at(lensed, 640, 160).y > at(plain, 640, 160).y + 40)
        #expect(at(lensed, 640, 360 + 203 + 3).y < at(plain, 640, 360 + 203 + 3).y - 5)

        // The cursor and a click under the lens come out twice as large.
        var clicked = frame(calm(.loupe))
        clicked.cursor = CursorLayer(hotspot: centre + SIMD2(20, 10), height: 30)
        var bare = clicked
        bare.calmZoom = nil
        let cursorAlone = try #require(differingBounds(try drawer.draw(bare), plain))
        let cursorLensed = try #require(differingBounds(try drawer.draw(clicked), lensed))
        let aloneSize = SIMD2<Double>(cursorAlone.high &- cursorAlone.low &+ 1)
        let lensedSize = SIMD2<Double>(cursorLensed.high &- cursorLensed.low &+ 1)
        #expect(simd_length(lensedSize - 2 * aloneSize) <= 4, "\(aloneSize) \(lensedSize)")
        let aloneOrigin = SIMD2<Double>(cursorAlone.low), lensedOrigin = SIMD2<Double>(cursorLensed.low)
        #expect(simd_length(lensedOrigin - (centre + 2 * (aloneOrigin - centre))) <= 3, "\(aloneOrigin) \(lensedOrigin)")
        var rippled = frame(calm(.loupe))
        rippled.clickEffects = [ClickEffectLayer(kind: .ripple, center: centre, radius: 25, thickness: 4, opacity: 1)]
        let ripple = try drawer.draw(rippled)
        for (x, y) in [(640 + 50, 360), (640 - 50, 360), (640, 360 + 50)] {
            let p = at(ripple, x, y)
            #expect(p.x >= 235 && p.y >= 235 && p.z >= 235, "ring at (\(x), \(y)): \(p)")
        }
        #expect(near(at(ripple, 640 + 25, 360), at(lensed, 640 + 25, 360), 2))
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func loupeAtTheEdgeReadsTheEdge() throws {
        let drawer = try CalmDrawer()
        let flat: SIMD4<Float> = [0.2, 0.6, 0.9, 1]
        let colour = SIMD4(0.9 * 255, 0.6 * 255, 0.2 * 255, 255)
        let lenses = [(SIMD2(10.0, 360.0), 1.0), (SIMD2(640.0, 10.0), 1.0), (SIMD2(1275.0, 715.0), 1.25), (SIMD2(-10.0, 300.0), 1.0)]
        for (c, magnification) in lenses {
            let lens = CalmZoomLayer(
                mode: .loupe, amount: 1, focus: Rect(x: c.x - 100, y: c.y - 50, width: 200, height: 100),
                loupe: LoupeLayer(radius: 120, shape: .roundedRect, magnification: magnification))
            let drawn = RenderFrame(outputSize: size, gradientStart: flat, gradientEnd: flat, gradientAngleDegrees: 0, calmZoom: lens)
            let bytes = try drawer.draw(drawn)
            var checked = 0
            for (x, y) in pixels(stride: 2) {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let d = CalmZoomLook.roundedRectDistance(p - c, halfSize: SIMD2(180, 120), radius: 30)
                guard d < -2 else { continue }
                #expect(near(at(bytes, x, y), colour, 1), "\(c): (\(x), \(y)) \(at(bytes, x, y))")
                checked += 1
            }
            #expect(checked > 2000, "\(c)")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func effectsScaleWithAmount() throws {
        let drawer = try CalmDrawer()
        let plain = try drawer.draw(frame(nil))
        let half = try drawer.draw(frame(calm(.highlight, amount: 0.5)))
        for (x, y) in [(40, 40), (1200, 650), (100, 600), (1000, 100)] {
            #expect(near(at(half, x, y), darker(at(plain, x, y), 0.9), 1), "(\(x), \(y))")
        }
        let lens = try drawer.draw(frame(calm(.loupe))), halfLens = try drawer.draw(frame(calm(.loupe, amount: 0.5)))
        for (x, y) in [(640, 360), (700, 300), (560, 420), (640, 250)] {
            #expect(near(at(halfLens, x, y), (at(plain, x, y) + at(lens, x, y)) / 2, 1), "(\(x), \(y))")
        }
        let dim = try drawer.draw(frame(calm(.dim)), screen: drawer.checker)
        let halfDim = try drawer.draw(frame(calm(.dim, amount: 0.5)), screen: drawer.checker)
        let checker = try drawer.draw(frame(nil), screen: drawer.checker)
        for (x, y) in [(40, 40), (1200, 650), (101, 600), (1000, 101)] {
            #expect(near(at(halfDim, x, y), (at(checker, x, y) + at(dim, x, y)) / 2, 1), "(\(x), \(y))")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func effectsInTheMotionBlurPass() throws {
        let drawer = try CalmDrawer()
        var samples = frame(nil)
        samples.camera = cameraLayer
        samples.cursorSamples = [CursorLayer(hotspot: [300, 300], height: 30), CursorLayer(hotspot: [312, 306], height: 30)]
        var subframes = frame(nil)
        subframes.camera = cameraLayer
        subframes.subframes = [
            StageSubframe(stage: StageTransform(depth: 1, center: centre)),
            StageSubframe(stage: StageTransform(depth: 1.02, center: centre)),
        ]
        var card = subframes
        card.card = CardPlacement(
            rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12, content: .identity(outputSize: size), mix: 1)
        card.backgroundTransform = .identity(outputSize: size)
        for base in [samples, subframes, card] {
            let plain = try drawer.draw(base)
            for mode in [ZoomMode.highlight, .dim, .loupe] {
                var drawn = base
                drawn.calmZoom = calm(mode)
                var counts = DrawCounts()
                let bytes = try drawer.draw(drawn, counts: &counts)
                let sampled = mode != .highlight
                #expect(counts.renderPasses == (sampled ? 2 : 1) && counts.calmZoomSamples == (sampled ? 1 : 0), "\(mode): \(counts)")
                #expect(counts.calmZooms == 1 && counts.cameras == 1 && counts.overlaySteps == 1, "\(mode): \(counts)")
                // The camera drawn after the effect, as without it.
                for (x, y) in pixels(stride: 4) where x >= 1010 && x < 1230 && y >= 490 && y < 650 {
                    #expect(at(bytes, x, y) == at(plain, x, y), "\(mode): the camera at (\(x), \(y))")
                }
                // And the effect drawn, far from the focus and the camera.
                #expect(at(bytes, 40, 600) != at(plain, 40, 600) || mode == .loupe, "\(mode)")
                #expect(at(bytes, 640, 160) != at(plain, 640, 160) || mode != .loupe, "\(mode)")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cameraKeysAndCaptionsGoOverTheEffect() throws {
        let drawer = try CalmDrawer()
        let capHeight = KeyOverlayPlacement.capHeight(.medium, outputSize: size)
        let content = KeyOverlayContent.keys(["⌘", "C"])
        let box = KeyOverlayMetrics.size(of: content, capHeight: capHeight)
        let keyRect = KeyOverlayPlacement.rect(
            boxSize: box, keys: KeyOverlayPlan(mode: .all, position: .top, size: .medium), captions: .legacy, outputSize: size)
        let lines = ["Toma lo que se ve"]
        let placed = try #require(CaptionScene.placement(of: lines, style: .default, language: "es-MX", outputSize: size))
        let caption = CaptionLayer(
            lines: lines, highlight: nil, style: .default, language: "es-MX", fontSize: placed.fontSize, box: placed.box)
        var over = frame(nil)
        over.camera = cameraLayer
        over.keys = KeyOverlayLayer(items: [KeyOverlayLayer.Item(content: content, rect: keyRect, capHeight: capHeight, opacity: 1)])
        over.captions = caption
        // What the camera, the keys and the captions cover opaquely: the same over two other stages.
        var other = over
        (other.screen, other.gradientStart, other.gradientEnd) = (nil, [0.9, 0.1, 0.4, 1], [0.1, 0.8, 0.3, 1])
        let plain = try drawer.draw(over), otherPlain = try drawer.draw(other)
        let small = Rect(x: 100, y: 250, width: 300, height: 200)
        for mode in [ZoomMode.dim, .highlight, .loupe] {
            var drawn = over
            drawn.calmZoom = calm(mode, focus: small, loupe: LoupeLayer(radius: 150, shape: .circle, magnification: 2))
            let bytes = try drawer.draw(drawn)
            for (name, rect) in [("camera", cameraLayer.rect), ("keys", keyRect), ("captions", placed.box)] {
                var opaque = 0
                for (x, y) in pixels() where Double(x) >= rect.x && Double(x) < rect.x + rect.width && Double(y) >= rect.y
                    && Double(y) < rect.y + rect.height && at(plain, x, y) == at(otherPlain, x, y)
                {
                    #expect(at(bytes, x, y) == at(plain, x, y), "\(mode): \(name) at (\(x), \(y))")
                    opaque += 1
                }
                #expect(opaque > 50, "\(mode): \(name) \(opaque)")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aCardCutsTheHoleToTheCard() throws {
        let drawer = try CalmDrawer()
        let content = StageTransform(depth: 1.5, center: [400, 300])
        var card = frame(nil)
        card.card = CardPlacement(rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12, content: content, mix: 1)
        card.backgroundTransform = .identity(outputSize: size)
        let plain = try drawer.draw(card)
        // The focus of the stage, drawn by the card's content at (490, 285) to (790, 435): past the card's right edge.
        let stageFocus = Rect(x: 300, y: 250, width: 200, height: 100)
        let drawnFocus = content.outputRect(ofStage: stageFocus, outputSize: size)
        #expect(drawnFocus == Rect(x: 490, y: 285, width: 300, height: 150))
        var lit = card
        lit.calmZoom = calm(.highlight, focus: stageFocus)
        var counts = DrawCounts()
        let bytes = try drawer.draw(lit, counts: &counts)
        #expect(counts.renderPasses == 1 && counts.calmZooms == 1)
        // In the focus and the card, as it is; in the focus past the card, and outside both, darkened.
        for (x, y) in [(500, 300), (600, 360), (690, 420)] {
            #expect(at(bytes, x, y) == at(plain, x, y), "hole at (\(x), \(y))")
        }
        for (x, y) in [(720, 300), (760, 400), (300, 600), (50, 50), (600, 200)] {
            #expect(near(at(bytes, x, y), darker(at(plain, x, y), 0.8), 1), "darkened at (\(x), \(y))")
        }
        // The ring along the focus's top edge in the card, none past it.
        let ring = at(bytes, 600, 284)
        #expect(ring.x >= 230 && ring.y >= 230 && ring.z >= 230, "\(ring)")
        #expect(near(at(bytes, 750, 284), darker(at(plain, 750, 284), 0.8), 1))

        // Dim, the same way, in its own pass.
        var dimmed = card
        dimmed.calmZoom = calm(.dim, focus: stageFocus)
        let dim = try drawer.draw(dimmed)
        for (x, y) in [(500, 300), (600, 360), (690, 420)] {
            #expect(at(dim, x, y) == at(plain, x, y), "dim's hole at (\(x), \(y))")
        }
        #expect(at(dim, 760, 360).y < at(plain, 760, 360).y * 0.6 + 6)
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func drawingTwiceGivesTheSameBytes() throws {
        let drawer = try CalmDrawer()
        // With how many textures made in all: none for Highlight, three for Dim (its copy and its blur's two), one for the lens.
        for (mode, made) in [(ZoomMode.highlight, 0), (.dim, 3), (.loupe, 4)] {
            let drawn = frame(calm(mode))
            let first = try drawer.draw(drawn)
            #expect(drawer.textures.count.made == made, "\(mode): \(drawer.textures.count)")
            // Once the GPU is done with the frame, its textures are handed back for the next one.
            let deadline = Date().addingTimeInterval(5)
            while drawer.textures.count.free < drawer.textures.count.made, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let second = try drawer.draw(drawn)
            #expect(first == second, "\(mode)")
            #expect(drawer.textures.count.made == made, "\(mode): \(drawer.textures.count)")
        }
        // A rounded lens and Dim in another size: the same twice too.
        let other = SIMD2(1920, 1080)
        let lens = CalmZoomLayer(
            mode: .loupe, amount: 0.7, focus: Rect(x: 800, y: 400, width: 300, height: 200),
            loupe: LoupeLayer(radius: 300, shape: .roundedRect, magnification: 3.5))
        #expect(try drawer.draw(frame(lens, outputSize: other)) == drawer.draw(frame(lens, outputSize: other)))
        let dim = frame(calm(.dim, amount: 0.3), outputSize: other)
        #expect(try drawer.draw(dim) == drawer.draw(dim))
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aTextureMetalCannotMakeFailsTheFrame() throws {
        let drawer = try CalmDrawer()
        drawer.textures.failsForTests = true
        defer { drawer.textures.failsForTests = false }
        var samples = frame(nil)
        samples.cursorSamples = [CursorLayer(hotspot: [300, 300], height: 30), CursorLayer(hotspot: [312, 306], height: 30)]
        var card = frame(nil)
        card.card = CardPlacement(
            rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12, content: .identity(outputSize: size), mix: 1)
        card.backgroundTransform = .identity(outputSize: size)
        for base in [frame(nil), samples, card] {
            for mode in [ZoomMode.dim, .loupe] {
                var drawn = base
                drawn.calmZoom = calm(mode)
                drawn.camera = cameraLayer
                let target = try StageDrawing.target(device: drawer.device, size: size)
                let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
                var failed = false
                do {
                    try drawer.compositor.encode(
                        drawn, screen: drawer.smooth, camera: drawer.camera, cursor: drawer.cursor, into: target,
                        commandBuffer: commandBuffer)
                } catch RenderError.metalResourceUnavailable {
                    failed = true
                }
                #expect(failed, "\(mode)")
                // Its pass ended once: what was encoded completes.
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                #expect(commandBuffer.status == .completed, "\(mode)")
            }
        }
        // Highlight needs none, and draws.
        #expect(try drawer.draw(frame(calm(.highlight))) != drawer.draw(frame(nil)))
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aMovingLensKeepsOneCopy() throws {
        let drawer = try CalmDrawer()
        // The largest lens, 2×, following a cursor down the whole output a fraction of a pixel off each time; and one wider
        // than a portrait output, its copy cut to it.
        let lenses = [
            (size, LoupeLayer(radius: 0.4 * 720, shape: .circle, magnification: 2)),
            (SIMD2(720, 1280), LoupeLayer(radius: 0.4 * 720, shape: .roundedRect, magnification: 2)),
        ]
        for (outputSize, lens) in lenses {
            let before = drawer.textures.count.made
            let width = Double(outputSize.x), height = Double(outputSize.y)
            for i in 0..<60 {
                let c = SIMD2(0.47 * width + 0.37 * Double(i), 13.3 + Double(i) * (height - 26.6) / 59)
                let layer = CalmZoomLayer(
                    mode: .loupe, amount: 1, focus: Rect(x: c.x - 100, y: c.y - 50, width: 200, height: 100), loupe: lens)
                _ = try drawer.draw(frame(layer, outputSize: outputSize))
                // Once the GPU is done with the frame, its copy is handed back for the next one.
                let deadline = Date().addingTimeInterval(5)
                while drawer.textures.count.free < drawer.textures.count.made, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            }
            #expect(drawer.textures.count.made == before + 1, "\(outputSize): \(drawer.textures.count)")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aCommandBufferThatTakesNoMorePassesFailsTheFrame() throws {
        let drawer = try CalmDrawer()
        let refusals = drawer.compositor.layers.calmZoom.refusals
        defer { refusals.forTests = nil }
        var samples = frame(nil)
        samples.cursorSamples = [CursorLayer(hotspot: [300, 300], height: 30), CursorLayer(hotspot: [312, 306], height: 30)]
        var card = frame(nil)
        card.card = CardPlacement(
            rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12, content: .identity(outputSize: size), mix: 1)
        card.backgroundTransform = .identity(outputSize: size)
        // Dim asks for a blit, two blur passes and the pass into the target; the loupe for a blit and that pass. Each refused
        // in turn, with the pass into the target given again after it or not.
        for (mode, passes) in [(ZoomMode.dim, 4), (.loupe, 2)] {
            for after in 0..<passes {
                for reopens in [false, true] {
                    refusals.forTests = CalmZoomRefusals.Plan(after: after, reopens: reopens)
                    for base in [frame(nil), samples, card] {
                        var drawn = base
                        drawn.calmZoom = calm(mode)
                        drawn.camera = cameraLayer
                        let target = try StageDrawing.target(device: drawer.device, size: size)
                        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
                        var failed = false
                        do {
                            try drawer.compositor.encode(
                                drawn, screen: drawer.smooth, camera: drawer.camera, cursor: drawer.cursor, into: target,
                                commandBuffer: commandBuffer)
                        } catch RenderError.metalResourceUnavailable {
                            failed = true
                        }
                        #expect(failed, "\(mode) after \(after), reopens \(reopens)")
                        // Every pass ended once, none left open: what was encoded completes.
                        commandBuffer.commit()
                        commandBuffer.waitUntilCompleted()
                        #expect(commandBuffer.status == .completed, "\(mode) after \(after), reopens \(reopens)")
                    }
                }
            }
        }
        refusals.forTests = nil
        #expect(try drawer.draw(frame(calm(.dim))) != drawer.draw(frame(nil)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func loupeCostsAtMostOneAndAHalfMillisecondsAt4K() throws {
        let size4K = SIMD2(3840, 2160)
        let drawer = try CalmDrawer()
        let screen = try StageDrawing.screenTexture(device: drawer.device, width: 1920, height: 1080)
        let target = try StageDrawing.target(device: drawer.device, size: size4K)
        let focus4K = Rect(x: 1440, y: 810, width: 960, height: 540)
        /// The median over 60 frames of what the GPU took to draw each of `layers`, drawn in turn.
        func medians(_ layers: [CalmZoomLayer?]) throws -> [Double] {
            var times = Array(repeating: [Double](), count: layers.count)
            for round in 0..<65 {
                for (i, layer) in layers.enumerated() {
                    let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
                    try drawer.compositor.encode(
                        frame(layer, outputSize: size4K), screen: screen, camera: nil, cursor: drawer.cursor, into: target,
                        commandBuffer: commandBuffer)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    if round >= 5 { times[i].append(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) }
                }
            }
            return times.map { $0.sorted()[$0.count / 2] }
        }
        let lens = CalmZoomLayer(
            mode: .loupe, amount: 1, focus: focus4K, loupe: LoupeLayer(radius: 0.16 * 2160, shape: .circle, magnification: 2))
        let largest = CalmZoomLayer(
            mode: .loupe, amount: 1, focus: focus4K, loupe: LoupeLayer(radius: 0.4 * 2160, shape: .roundedRect, magnification: 4))
        let dim = CalmZoomLayer(mode: .dim, amount: 1, focus: focus4K)
        let highlight = CalmZoomLayer(mode: .highlight, amount: 1, focus: focus4K)
        let m = try medians([nil, lens, largest, dim, highlight])
        let ms = m.map { ($0 - m[0]) * 1000 }
        print(String(
            format: "Calm zoom at 4K, GPU ms per frame over none (%.3f ms): loupe 0.16 circle %.3f, "
                + "loupe 0.4 rounded rectangle %.3f, dim %.3f, highlight %.3f",
            m[0] * 1000, ms[1], ms[2], ms[3], ms[4]))
        #expect(ms[1] <= 1.5 && ms[2] <= 1.5, "\(ms)")
    }
}
