// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `PrivacyScene`, `FrameEvaluator.frame(at:)`, `DrawCounts`, the compositor's counting `encode` and its
// copies that fail.
@testable import Render
import SyntheticCapture
import Testing

// `privacy-1` (phase 2 design §7.1, plan 2c decision 3): the privacy blocks of a document drawn in the screen's shader,
// in fractions of the crop as it is drawn, so they follow the zoom, a change's cut and the motion blur; blurred from the
// copy with mipmaps, pixelated in cells of at least 8 texels or filled, with hard edges, failing closed. The GPU's work
// runs off the cooperative pool and hands back what it drew: the checks are made in the test's task.

private let wholeFrame = Rect(x: 0, y: 0, width: 1, height: 1)

/// A block of the take from `from` to `to` seconds of it.
private func block(
    _ number: Int, from: Double = 0, to: Double = 3, _ effect: PrivacyEffect = .blur, strength: Double = 0.6,
    color: RGBA = RGBA(0, 0, 0, 1), rect: NormalizedRect, keys: [RectKey] = [], take: String = takeID
) -> PrivacyBlock {
    PrivacyBlock(
        id: String(format: "p-%08x", number), take: take, start: base.adding(seconds: from), end: base.adding(seconds: to),
        effect: effect, strength: strength, color: color, rect: rect, keys: keys)
}

/// The legacy document of `take` with `blocks`.
private func document(_ take: TakeRecord, _ events: [InputEvent] = [], blocks: [PrivacyBlock]) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.privacy = PrivacyPlan(blocks: blocks)
    return document
}

private func rect(_ r: NormalizedRect) -> Rect { Rect(x: r.x, y: r.y, width: r.width, height: r.height) }

/// Whether `a` and `b` are the same rect within `tolerance`.
private func close(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-12) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

// MARK: - The scene

@Test func scenesRegionsFollowTheBlockAndItsKeys() throws {
    let take = StageDrawing.bareTake()
    let a = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), b = NormalizedRect(x: 0.5, y: 0.4, width: 0.2, height: 0.4)
    let keyed = block(
        1, from: 0.5, to: 2.5, .pixelate, strength: 0.3, color: RGBA(1, 0.5, 0, 1), rect: a,
        keys: [RectKey(t: base.adding(seconds: 2), rect: b), RectKey(t: base.adding(seconds: 1), rect: a)])
    let still = block(2, from: 0, to: 3, .fill, strength: 0.9, color: RGBA(0.2, 0.4, 0.6, 1), rect: b)
    let scene = PrivacyScene(document: document(take, blocks: [keyed, still]), take: take, events: [])
    for seconds in [0.7, 1.0, 1.5, 1.75, 2.2] {
        let t = base.adding(seconds: seconds)
        let regions = scene.regions(atSource: t, trackID: trackID)
        try #require(regions.count == 2, "at \(seconds) s")
        #expect(close(regions[0].rect, rect(PrivacyGeometry.rect(of: keyed, atSource: t))), "at \(seconds) s")
        #expect(regions[0].effect == .pixelate && regions[0].strength == 0.3 && regions[0].color == SIMD4(1, 0.5, 0, 1))
        #expect(regions[1] == PrivacyRegion(rect: rect(b), effect: .fill, strength: 0.9, color: SIMD4(0.2, 0.4, 0.6, 1)))
    }
    // Held before the first key and after the last, linear between them.
    #expect(close(try #require(scene.regions(atSource: base.adding(seconds: 0.7), trackID: trackID).first).rect, rect(a)))
    #expect(close(try #require(scene.regions(atSource: base.adding(seconds: 2.2), trackID: trackID).first).rect, rect(b)))
    let middle = try #require(scene.regions(atSource: base.adding(seconds: 1.5), trackID: trackID).first).rect
    #expect(close(middle, Rect(x: 0.3, y: 0.3, width: 0.25, height: 0.3), 1e-12), "\(middle)")
    // Its source range is `[start, end)`; a track that is not one of the take's screens has none.
    #expect(scene.regions(atSource: base.adding(seconds: 0.4), trackID: trackID).count == 1)
    #expect(scene.regions(atSource: base.adding(seconds: 2.5), trackID: trackID).count == 1)
    #expect(scene.regions(atSource: base.adding(seconds: 1), trackID: "camera").isEmpty)
    // Out of the content, and of no size, it is clamped into it, at least `PrivacyGeometry.minimumSide`; a strength that
    // is not a number hides the most.
    let outside = block(3, .blur, strength: .nan, rect: NormalizedRect(x: 0.9, y: -0.2, width: 0.4, height: 0))
    let clamped = PrivacyScene(document: document(take, blocks: [outside]), take: take, events: [])
        .regions(atSource: base.adding(seconds: 1), trackID: trackID)
    #expect(clamped == [PrivacyRegion(
        rect: Rect(x: 0.6, y: 0, width: 0.4, height: PrivacyGeometry.minimumSide), effect: .blur, strength: 1, color: SIMD4(0, 0, 0, 1))])
}

@Test func aBlockInACutOrOfAnotherTakeIsNotShown() throws {
    let take = StageDrawing.bareTake()
    var doc = document(take, blocks: [
        // Inside the cut, of another take, and across the cut.
        block(1, from: 1.2, to: 1.8, .fill, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
        block(2, from: 0, to: 3, .fill, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), take: "take-002"),
        block(3, from: 0.8, to: 2.2, .blur, rect: NormalizedRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3)),
    ])
    doc.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
    ]
    let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: [1280, 720])
    for n in 0..<120 {
        let t = Double(n) / 60
        let screen = try #require(evaluator.frame(at: t).screen)
        // Block 3 shows on both sides of the cut, until 0.2 s of output after it; neither of the others ever does.
        let shown = t >= 0.8 && t < 1.2
        #expect(screen.privacy.map(\.effect) == (shown ? [.blur] : []), "at \(t) s")
    }
    let other = PrivacyScene(document: doc, take: take, events: [])
    #expect(other.regions(atSource: base.adding(seconds: 1.5), trackID: trackID).map(\.effect) == [.fill, .blur])
    #expect(other.regions(atSource: base.adding(seconds: 0.5), trackID: trackID).isEmpty)
}

@Test func moreThanEightKeepSevenAndCoverTheRest() throws {
    let take = StageDrawing.bareTake()
    let blocks = (0..<10).map { (k: Int) -> PrivacyBlock in
        let n = Double(k), effect: PrivacyEffect = k % 3 == 0 ? .fill : .pixelate
        let rect = NormalizedRect(x: 0.05 + 0.08 * n, y: 0.1 + 0.05 * Double(k % 4), width: 0.06, height: 0.1 + 0.02 * n)
        return block(k + 1, effect, strength: 0.1 * n, rect: rect)
    }
    let scene = PrivacyScene(document: document(take, blocks: blocks), take: take, events: [])
    let regions = scene.regions(atSource: base.adding(seconds: 1), trackID: trackID)
    try #require(regions.count == PrivacyRegion.maxPerFrame)
    for k in 0..<7 {
        #expect(regions[k].rect == rect(blocks[k].rect) && regions[k].effect == blocks[k].effect, "region \(k)")
    }
    // The eighth holds blocks 8, 9 and 10, blurred at the full strength: what it holds is never shown.
    let last = regions[7]
    #expect(last.effect == .blur && last.strength == 1)
    for k in 7..<10 {
        let r = blocks[k].rect
        #expect(r.x >= last.rect.x && r.y >= last.rect.y, "block \(k + 1)")
        #expect(r.x + r.width <= last.rect.x + last.rect.width + 1e-12 && r.y + r.height <= last.rect.y + last.rect.height + 1e-12)
    }
    let left = blocks[7...].map { $0.rect.x }.min()!, right = blocks[7...].map { $0.rect.x + $0.rect.width }.max()!
    #expect(abs(last.rect.x - left) < 1e-12 && abs(last.rect.x + last.rect.width - right) < 1e-12)
    // Eight are drawn as they are.
    #expect(PrivacyScene(document: document(take, blocks: Array(blocks.prefix(8))), take: take, events: [])
        .regions(atSource: base.adding(seconds: 1), trackID: trackID).map(\.effect) == blocks.prefix(8).map(\.effect))
}

@Test func regionsGoInTheDrawnCrop() throws {
    // Display 1 in Area mode, which goes from 16:9 to 1:1 at 1.5 s, with the spring: at 1.6 s the area's crop is cut to
    // the rect's shape on its way.
    let display = Rect(x: 0, y: 0, width: 640, height: 360)
    let take = makeTake(tracks: [
        displayTrack(
            globalFrame: display, captureArea: Rect(x: 40, y: 20, width: 560, height: 320),
            segments: [segment(start: base, end: base.adding(seconds: 4))]),
    ])
    let events = [InputEvent(
        t: base.adding(seconds: 1.5), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 480, height: 480), scale: 1))]
    let hidden = NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)
    var spring = document(take, events, blocks: [block(1, from: 0, to: 4, .fill, rect: hidden)])
    spring.style.geometryTransition = .spring
    var jump = spring
    jump.style.geometryTransition = .none
    let moving = FrameEvaluator(take: take, events: events, document: spring, outputSize: [1920, 1080])
    let settled = FrameEvaluator(take: take, events: events, document: jump, outputSize: [1920, 1080])
    /// The region of `layer` in fractions of the whole frame.
    func inFrame(_ layer: ScreenLayer) throws -> Rect {
        let region = try #require(layer.privacy.first).rect, crop = layer.crop
        return Rect(
            x: crop.x + region.x * crop.width, y: crop.y + region.y * crop.height, width: region.width * crop.width,
            height: region.height * crop.height)
    }
    for t in [0.5, 1.55, 1.6, 1.8, 3.5] {
        let cut = try #require(moving.frame(at: t).screen), rest = try #require(settled.frame(at: t).screen)
        if t > 1.5 && t < 2 { #expect(cut.crop != rest.crop, "at \(t) s the change cuts the crop") }
        // The same content of the frame as at rest, whatever the crop drawn.
        let drawn = try inFrame(cut), resting = try inFrame(rest)
        #expect(close(drawn, resting, 1e-12), "at \(t) s: \(drawn) against \(resting)")
    }
    // At rest, the region is the block's rect in the area: the area's crop is the crop drawn.
    let rest = try #require(settled.frame(at: 0.5).screen)
    #expect(close(try #require(rest.privacy.first).rect, rect(hidden)))
}

@Test func anyRegionMakesTheLayerMipmapped() throws {
    let take = StageDrawing.bareTake()
    let legacy = EditDocument.legacy(take: take, events: [])
    #expect(legacy.style.screenSampling == .bilinear)
    let size = SIMD2(1280, 720)
    let plain = FrameEvaluator(take: take, events: [], document: legacy, outputSize: size)
    let filled = FrameEvaluator(
        take: take, events: [],
        document: document(take, blocks: [block(1, from: 1, to: 2, .fill, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))]),
        outputSize: size)
    for t in [0.5, 1.5, 2.5] {
        var with = try #require(filled.frame(at: t).screen)
        let without = try #require(plain.frame(at: t).screen)
        if t == 1.5 {
            #expect(with.mipmapped && with.privacy.count == 1)
            with.mipmapped = false
            with.privacy = []
        }
        // Without a region, the layer is the one without blocks.
        #expect(with == without, "at \(t) s")
    }
}

@Test func noBlocksKeepsTheLegacyCalls() async throws {
    // Frames on every path of the compositor: the stage, the zoom camera's motion blur, a change of screen's crossfade
    // and the Split's card. Blocks of another take, or in a cut, leave each the frame without blocks and draw nothing
    // new; the golden documents' frames are checked the same way by `RenderSeamsTests`.
    let take = makeTake(tracks: [
        displayTrack(globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), segments: [segment(start: base, end: base.adding(seconds: 3))]),
        displayTrack(
            id: "display-2", displayID: 2, globalFrame: Rect(x: 640, y: 0, width: 480, height: 480),
            segments: [segment(track: "display-2", start: base, end: base.adding(seconds: 3))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 3))]),
    ])
    var plain = EditDocument.legacy(take: take, events: [])
    plain.zoom.regions = [StageDrawing.zoom(1, from: 0.2, to: 1.2, depth: 2.5, focus: .fixed(x: 0.3, y: 0.3))]
    plain.zoom.motionBlur = 1
    plain.style.geometryTransition = .spring
    plain.screens.changes = [ScreenChange(id: "p-00000101", take: takeID, t: base.adding(seconds: 1.5), track: "display-2", origin: .user)]
    plain.camera.layouts = [LayoutBlock(
        id: "l-00000001", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), kind: .split, instant: false,
        bubble: nil, split: SplitLayout())]
    var others = plain
    others.privacy = PrivacyPlan(blocks: [
        block(1, from: 0, to: 3, .fill, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1), take: "take-002"),
        block(2, from: 2.95, to: 3, .blur, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
    ])
    others.sequence = [Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 2.9), speed: 1)]
    plain.sequence = others.sequence
    let size = SIMD2(1280, 720)
    let without = FrameEvaluator(take: take, events: [], document: plain, outputSize: size)
    let with = FrameEvaluator(take: take, events: [], document: others, outputSize: size)
    let times = [0.1, 0.3, 0.5, 1.55, 1.6, 2.1, 2.5, 2.85]
    let frames = times.map { with.frame(at: $0) }
    #expect(frames == times.map { without.frame(at: $0) })
    #expect(frames.contains { !$0.subframes.isEmpty } && frames.contains { $0.previousScreen != nil } && frames.contains(where: \.isCardMode))
    guard MetalCondition.isAvailable || MetalCondition.isRequired else { return }
    let counts = try await offThePool {
        let drawer = try PrivacyDrawer()
        return try frames.map { try drawer.counts(of: $0) }
    }
    #expect(counts.allSatisfy { $0.privacyScreens == 0 && $0.screens > 0 }, "\(counts)")
}

@Test func uniformsAreTheShadersAndFailClosed() {
    let regions = [
        PrivacyRegion(rect: Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), effect: .pixelate, strength: 0.25, color: [0.5, 0.25, 1, 0.5]),
        PrivacyRegion(rect: Rect(x: .nan, y: 0.2, width: 0.3, height: .infinity), effect: .blur, strength: .nan, color: [.nan, 2, -1, 1]),
    ]
    let values = PrivacyUniforms.values(of: regions)
    #expect(values.count * MemoryLayout<SIMD4<Float>>.stride == PrivacyUniforms.length && PrivacyUniforms.length == 400)
    #expect(values.withUnsafeBytes { $0.load(as: UInt32.self) } == 2)
    #expect(Array(values[1...3]) == [[0.1, 0.2, 0.3, 0.4], [0.5, 0.25, 1, 1], [1, 0.25, 0, 0]])
    // A rect that is not finite covers the whole layer, at the most strength; a colour is read from 0 to 1, opaque.
    #expect(Array(values[4...6]) == [[0, 0, 1, 1], [0, 1, 0, 1], [0, 1, 0, 0]])
    #expect(values[7...].allSatisfy { $0 == .zero })
}

// MARK: - Drawing

/// A compositor of the default device, with Toma's arrow, to draw frames over screen textures with.
private struct PrivacyDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let cursor: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        cursor = try CursorSprite.makeTexture(device: device)
    }

    /// `frame` drawn over `screen` (the screen being left too) into a new target of its output size, as BGRA bytes.
    func draw(_ frame: RenderFrame, screen: any MTLTexture) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, screen: screen, counts: &counts)
    }

    func draw(_ frame: RenderFrame, screen: any MTLTexture, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen, previousScreen: screen, camera: screen, cursor: cursor, into: target, commandBuffer: commandBuffer,
            counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        return StageDrawing.bytes(of: target)
    }

    /// What drawing `frame` over a 640 × 360 gradient drew.
    func counts(of frame: RenderFrame) throws -> DrawCounts {
        var counts = DrawCounts()
        _ = try draw(frame, screen: try StageDrawing.screenTexture(device: device), counts: &counts)
        return counts
    }

    /// A `.bgra8Unorm` texture whose pixel at (`x`, `y`) is `bgra(x, y)`.
    func texture(width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> SIMD4<UInt8>) throws -> any MTLTexture {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = bgra(x, y)
                bytes += [p.x, p.y, p.z, p.w]
            }
        }
        return try texture(width: width, height: height, bytes: bytes)
    }

    func texture(width: Int, height: Int, bytes: [UInt8]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// A black and white checkerboard of `square` px squares, white at (0, 0).
    func checkerboard(width: Int = 640, height: Int = 360, square: Int) throws -> any MTLTexture {
        try texture(width: width, height: height) { x, y in
            let value: UInt8 = (x / square + y / square) % 2 == 0 ? 255 : 0
            return [value, value, value, 255]
        }
    }

    /// Black text of `lines` on white, set with CoreText in `box` (pixels, from the top left).
    func text(_ lines: [String], in box: CGRect, width: Int = 640, height: Int = 360) throws -> any MTLTexture {
        try texture(width: width, height: height, bytes: textBytes(lines, in: box, width: width, height: height))
    }
}

/// BGRA bytes of black text of `lines` on white, set with CoreText in `box` (pixels, from the top left).
private func textBytes(_ lines: [String], in box: CGRect, width: Int, height: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    try bytes.withUnsafeMutableBytes { raw in
        let context = try #require(CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: info))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, box.height / CGFloat(lines.count) * 0.8, nil)
        for (k, line) in lines.enumerated() {
            let attributed = NSAttributedString(
                string: line, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // CoreGraphics' origin is at the bottom left.
            let baseline = CGFloat(height) - box.minY - box.height / CGFloat(lines.count) * (CGFloat(k) + 0.8)
            context.textPosition = CGPoint(x: box.minX, y: baseline)
            CTLineDraw(ctLine, context)
        }
    }
    return bytes
}

/// The luma of the BGRA pixel (0 to 255).
private func luma(_ p: SIMD4<UInt8>) -> Double {
    0.2126 * Double(p.z) + 0.7152 * Double(p.y) + 0.0722 * Double(p.x)
}

/// The pixels of `bytes` (`width` wide) whose centres are inside `rect` (output pixels), less `inset` on every side.
private func pixels(in rect: Rect, inset: Double = 0, width: Int, height: Int) -> [SIMD2<Int>] {
    let x0 = max(Int((rect.x + inset - 0.5).rounded(.up)), 0), x1 = min(Int((rect.x + rect.width - inset - 0.5).rounded(.up)), width)
    let y0 = max(Int((rect.y + inset - 0.5).rounded(.up)), 0), y1 = min(Int((rect.y + rect.height - inset - 0.5).rounded(.up)), height)
    guard x0 < x1, y0 < y1 else { return [] }
    return (y0..<y1).flatMap { y in (x0..<x1).map { SIMD2($0, y) } }
}

/// How far the luma of `points` goes from its mean, at most.
private func lumaDeviation(_ bytes: [UInt8], width: Int, _ points: [SIMD2<Int>]) -> Double {
    let values = points.map { luma(pixel(bytes, width: width, x: $0.x, y: $0.y)) }
    let mean = values.reduce(0, +) / Double(values.count)
    return values.map { abs($0 - mean) }.max() ?? 0
}

/// The largest change of luma between two pixels next to each other, across or down, among `points` (a rect's).
private func steepestStep(_ bytes: [UInt8], width: Int, _ points: [SIMD2<Int>]) -> Double {
    let inside = Set(points.map { $0.y * width + $0.x })
    var steepest = 0.0
    for p in points {
        let here = luma(pixel(bytes, width: width, x: p.x, y: p.y))
        for next in [SIMD2(p.x + 1, p.y), SIMD2(p.x, p.y + 1)] where inside.contains(next.y * width + next.x) {
            steepest = max(steepest, abs(here - luma(pixel(bytes, width: width, x: next.x, y: next.y))))
        }
    }
    return steepest
}

/// A frame of `size` over black showing the screen square in `rect`, sampled with mipmaps, with `privacy`.
private func screenFrame(
    size: SIMD2<Int>, rect: Rect, crop: Rect = wholeFrame, mipmapped: Bool = true, privacy: [PrivacyRegion] = []
) -> RenderFrame {
    RenderFrame(
        outputSize: size, gradientStart: [0, 0, 0, 1], gradientEnd: [0, 0, 0, 1], gradientAngleDegrees: 0,
        screen: ScreenLayer(
            trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 0, crop: crop, mipmapped: mipmapped, privacy: privacy))
}

/// `pixels` of a 640 × 360 screen drawn at 1:1 into a 640 × 360 output, as a region's rect.
private func region(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
    Rect(x: x / 640, y: y / 360, width: width / 640, height: height / 360)
}

private let size360 = SIMD2(640, 360)
private let full360 = Rect(x: 0, y: 0, width: 640, height: 360)

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurLeavesNoDetail() async throws {
    // A checkerboard of 2 px squares under a block of 400 × 80 px, drawn 1:1.
    let hidden = region(120, 140, 400, 80)
    let inside = pixels(in: Rect(x: 120, y: 140, width: 400, height: 80), width: 640, height: 360)
    let (weakest, middle, sharp) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let board = try drawer.checkerboard(square: 2)
        func drawn(_ strength: Double?) throws -> [UInt8] {
            let privacy = strength.map { [PrivacyRegion(rect: hidden, effect: .blur, strength: $0, color: SIMD4(0, 0, 0, 1))] } ?? []
            return try drawer.draw(screenFrame(size: size360, rect: full360, privacy: privacy), screen: board)
        }
        return (try drawn(0), try drawn(0.6), try drawn(nil))
    }
    #expect(lumaDeviation(sharp, width: 640, inside) > 100)
    let deviations = (lumaDeviation(weakest, width: 640, inside), lumaDeviation(middle, width: 640, inside))
    #expect(deviations.0 <= 2 && deviations.1 <= 1, "\(deviations)")
    // Text, even at the weakest strength: nothing of its strokes is left.
    let box = CGRect(x: 130, y: 150, width: 380, height: 60)
    let (blurred, plain) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let text = try drawer.text(["4242 4242 4242 4242"], in: box)
        let privacy = [PrivacyRegion(rect: hidden, effect: .blur, strength: 0, color: SIMD4(0, 0, 0, 1))]
        return (
            try drawer.draw(screenFrame(size: size360, rect: full360, privacy: privacy), screen: text),
            try drawer.draw(screenFrame(size: size360, rect: full360), screen: text))
    }
    let steps = (steepestStep(blurred, width: 640, inside), steepestStep(plain, width: 640, inside))
    #expect(steps.1 > 150 && steps.0 <= 12, "\(steps)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func pixelateCellsAreFlatAndAtLeastEightPixels() async throws {
    // A gradient that changes from every pixel to the next, drawn 1:1; the regions' corners on pixels.
    // 400 × 240: cells of 240 / 12 = 20 px; 96 × 48: 48 / 12 = 4, so the 8 px of the minimum.
    let cases: [(rect: Rect, pixels: Rect, cell: Int)] = [
        (region(100, 60, 400, 240), Rect(x: 100, y: 60, width: 400, height: 240), 20),
        (region(40, 30, 96, 48), Rect(x: 40, y: 30, width: 96, height: 48), 8),
    ]
    let drawn = try await offThePool {
        let drawer = try PrivacyDrawer()
        let screen = try StageDrawing.screenTexture(device: drawer.device)
        return try cases.map { c in
            try drawer.draw(
                screenFrame(size: size360, rect: full360, privacy: [PrivacyRegion(rect: c.rect, effect: .pixelate, strength: 0.6, color: .zero)]),
                screen: screen)
        }
    }
    for (c, bytes) in zip(cases, drawn) {
        let x0 = Int(c.pixels.x), y0 = Int(c.pixels.y), w = Int(c.pixels.width), h = Int(c.pixels.height)
        var cellColours: [[SIMD4<UInt8>]] = []
        for cy in stride(from: 0, to: h, by: c.cell) {
            var row: [SIMD4<UInt8>] = []
            for cx in stride(from: 0, to: w, by: c.cell) {
                let first = pixel(bytes, width: 640, x: x0 + cx, y: y0 + cy)
                let flat = (cy..<min(cy + c.cell, h)).allSatisfy { y in
                    (cx..<min(cx + c.cell, w)).allSatisfy { x in pixel(bytes, width: 640, x: x0 + x, y: y0 + y) == first }
                }
                #expect(flat, "cell (\(cx), \(cy)) of \(c.cell) px is flat")
                row.append(first)
            }
            cellColours.append(row)
        }
        // Each cell is its own colour: no cell is smaller than `cell`.
        for row in cellColours { #expect(zip(row, row.dropFirst()).allSatisfy { $0 != $1 }, "\(c.cell) px across") }
        for (a, b) in zip(cellColours, cellColours.dropFirst()) { #expect(zip(a, b).allSatisfy { $0 != $1 }, "\(c.cell) px down") }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func fillIsExactlyTheColor() async throws {
    let rect = Rect(x: 100.3, y: 50.6, width: 200.4, height: 120.2)
    let hidden = region(rect.x, rect.y, rect.width, rect.height)
    // Its alpha is not read: a fill is opaque.
    let bytes = try await offThePool {
        let drawer = try PrivacyDrawer()
        let text = try drawer.text(["sk_live_1234567890abcdef"], in: CGRect(x: 90, y: 60, width: 240, height: 80))
        return try drawer.draw(
            screenFrame(size: size360, rect: full360, privacy: [PrivacyRegion(rect: hidden, effect: .fill, strength: 0, color: [1, 0, 0, 0.3])]),
            screen: text)
    }
    let inside = pixels(in: rect, width: 640, height: 360)
    #expect(inside.count == 201 * 120)
    #expect(inside.allSatisfy { pixel(bytes, width: 640, x: $0.x, y: $0.y) == SIMD4(0, 0, 255, 255) })
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func edgesAreHard() async throws {
    // A region with its edges between pixels' centres, on a 1 px checkerboard drawn 1:1: the pixels just outside are
    // those without the block, byte for byte; those just inside, changed, with each effect.
    let rect = Rect(x: 101.4, y: 61.7, width: 200.2, height: 80.5)
    let hidden = region(rect.x, rect.y, rect.width, rect.height)
    let effects: [PrivacyEffect] = [.blur, .pixelate, .fill]
    let (without, with) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let board = try drawer.checkerboard(square: 1)
        let without = try drawer.draw(screenFrame(size: size360, rect: full360), screen: board)
        let with = try effects.map { effect in
            try drawer.draw(
                screenFrame(size: size360, rect: full360, privacy: [PrivacyRegion(rect: hidden, effect: effect, strength: 0.6, color: [0.5, 0.25, 1, 1])]),
                screen: board)
        }
        return (without, with)
    }
    // The pixels whose centres are inside: columns 101 to 301, rows 62 to 141.
    let inside = Set(pixels(in: rect, width: 640, height: 360).map { $0.y * 640 + $0.x })
    #expect(inside.count == 201 * 80)
    #expect(inside.contains(62 * 640 + 101) && !inside.contains(62 * 640 + 100) && inside.contains(141 * 640 + 301))
    #expect(!inside.contains(142 * 640 + 301) && !inside.contains(62 * 640 + 302) && !inside.contains(61 * 640 + 101))
    for (effect, bytes) in zip(effects, with) {
        var changedInside = 0, sameOutside = 0
        for y in 0..<360 {
            for x in 0..<640 {
                let a = pixel(bytes, width: 640, x: x, y: y), b = pixel(without, width: 640, x: x, y: y)
                if inside.contains(y * 640 + x) {
                    if a != b { changedInside += 1 }
                } else if a == b {
                    sameOutside += 1
                }
            }
        }
        #expect(changedInside == inside.count, "\(effect): \(inside.count - changedInside) pixels inside unchanged")
        #expect(sameOutside == 640 * 360 - inside.count, "\(effect): \(640 * 360 - inside.count - sameOutside) pixels outside changed")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func edgesAreHardThroughAZoomAndAtTheCropsEdge() async throws {
    // Drawn 1.7 times as large through the zoom camera, a fill red: inside exactly red, outside as without it. The rect's
    // edges between the pixels' centres, checked.
    let size = SIMD2(1280, 720)
    let screenRect = Rect(x: 160.7, y: 90.2, width: 960, height: 540)
    let stage = StageTransform(depth: 1.7, center: [610.3, 351.9])
    let hidden = Rect(x: 0.31, y: 0.27, width: 0.22, height: 0.33)
    var frame = screenFrame(size: size, rect: screenRect, privacy: [PrivacyRegion(rect: hidden, effect: .fill, strength: 1, color: [1, 0, 0, 1])])
    frame.stage = stage
    var unblocked = frame
    unblocked.screen?.privacy = []
    let (blocked, plain) = (frame, unblocked)
    let drawnRect = stage.outputRect(ofStage: screenRect, outputSize: size)
    let edges = [
        drawnRect.x + hidden.x * drawnRect.width, drawnRect.x + (hidden.x + hidden.width) * drawnRect.width,
        drawnRect.y + hidden.y * drawnRect.height, drawnRect.y + (hidden.y + hidden.height) * drawnRect.height,
    ]
    try #require(edges.allSatisfy { abs(($0 - 0.5) - ($0 - 0.5).rounded()) > 0.02 }, "\(edges)")
    let output = Rect(x: edges[0], y: edges[2], width: edges[1] - edges[0], height: edges[3] - edges[2])
    let inside = Set(pixels(in: output, width: size.x, height: size.y).map { $0.y * size.x + $0.x })
    // At the crop's edge the antialiased edge drawn past the screen's rect is in the region too: a region along the
    // left edge, over the checkerboard, is drawn as the red screen is, its edge too.
    let edgeRegion = Rect(x: 0, y: 0.2, width: 0.1, height: 0.5)
    let leftEdge = screenFrame(
        size: size, rect: screenRect, privacy: [PrivacyRegion(rect: edgeRegion, effect: .fill, strength: 1, color: [1, 0, 0, 1])])
    let (zoomed, unzoomed, edged, red) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let board = try drawer.checkerboard(square: 1)
        let solid = try drawer.texture(width: 640, height: 360) { _, _ in [0, 0, 255, 255] }
        var redScreen = leftEdge
        redScreen.screen?.privacy = []
        return (
            try drawer.draw(blocked, screen: board), try drawer.draw(plain, screen: board), try drawer.draw(leftEdge, screen: board),
            try drawer.draw(redScreen, screen: solid))
    }
    var wrong = 0
    for y in 0..<size.y {
        for x in 0..<size.x {
            let a = pixel(zoomed, width: size.x, x: x, y: y)
            if inside.contains(y * size.x + x) ? a != SIMD4(0, 0, 255, 255) : a != pixel(unzoomed, width: size.x, x: x, y: y) {
                wrong += 1
            }
        }
    }
    #expect(wrong == 0, "\(wrong) pixels")
    // The column of the screen's left edge, 160, partly covered, and the one inside it, in the region's rows.
    let rows = pixels(in: Rect(x: 160, y: screenRect.y + 0.2 * screenRect.height, width: 2, height: 0.5 * screenRect.height),
                      width: size.x, height: size.y)
    #expect(rows.count > 500)
    #expect(rows.allSatisfy { pixel(edged, width: size.x, x: $0.x, y: $0.y) == pixel(red, width: size.x, x: $0.x, y: $0.y) })
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func theBlockFollowsTheZoomAndMotionBlur() async throws {
    // Text under a blurred block of a 640 × 360 screen, zoomed in to 4× fast, with the camera's motion blur: in every
    // subframe, and in their average, nothing of its strokes is drawn where the block goes, wherever the zoom takes it.
    let take = StageDrawing.bareTake()
    let box = CGRect(x: 250, y: 150, width: 140, height: 50)
    let hidden = NormalizedRect(x: 240.0 / 640, y: 140.0 / 360, width: 160.0 / 640, height: 70.0 / 360)
    var doc = document(take, blocks: [block(1, .blur, strength: 0.6, rect: hidden)])
    doc.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 4, focus: .fixed(x: 0.5, y: 0.5))]
    doc.zoom.motionBlur = 1
    let size = SIMD2(1280, 720)
    let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: size)
    let times = (36..<120).map { Double($0) / 60 }
    let moving = try #require(times.lazy.map { evaluator.frame(at: $0) }.first { $0.subframes.count >= 4 && ($0.stage?.depth ?? 1) > 2 })
    let settled = evaluator.frame(at: 2.2)
    try #require(abs((settled.stage?.depth ?? 1) - 4) < 1e-3 && settled.subframes.isEmpty, "\(String(describing: settled.stage))")
    let screen = try #require(moving.screen)
    #expect(screen.privacy.count == 1 && close(screen.privacy[0].rect, rect(hidden)))
    /// Each subframe of `moving` alone, `moving` itself and the frame at rest at 4×, with and without the block.
    let frames: [RenderFrame] = moving.subframes.map { subframe in
        var alone = moving
        (alone.stage, alone.subframes, alone.cursor) = (subframe.stage, [], nil)
        return alone
    } + [moving, settled]
    let (blurred, plain) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let text = try drawer.text(["an@gmail.com"], in: box)
        let blurred = try frames.map { try drawer.draw($0, screen: text) }
        let plain = try frames.map { frame in
            var sharp = frame
            sharp.screen?.privacy = []
            return try drawer.draw(sharp, screen: text)
        }
        return (blurred, plain)
    }
    /// Where the block is drawn through `stage`, in output pixels.
    func drawnRegion(through stage: StageTransform?) -> Rect {
        let drawn = Compositor.moving(stage, outputSize: size)?.drawn(screen, outputSize: size) ?? screen
        let r = screen.privacy[0].rect
        return Rect(
            x: drawn.rect.x + r.x * drawn.rect.width, y: drawn.rect.y + r.y * drawn.rect.height, width: r.width * drawn.rect.width,
            height: r.height * drawn.rect.height)
    }
    /// The part of `rects` that is in all of them.
    func common(_ rects: [Rect]) -> Rect {
        let left = rects.map(\.x).max()!, top = rects.map(\.y).max()!
        let right = rects.map { $0.x + $0.width }.min()!, bottom = rects.map { $0.y + $0.height }.min()!
        return Rect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }
    for (k, frame) in frames.enumerated() {
        // The average's: where the block is in every subframe, away from the hard edges each draws elsewhere.
        let output = frame.subframes.isEmpty
            ? drawnRegion(through: frame.stage) : common(frame.subframes.map { drawnRegion(through: $0.stage) })
        let inside = pixels(in: output, inset: 1, width: size.x, height: size.y)
        try #require(inside.count > 10_000, "frame \(k): \(inside.count) pixels")
        // The text's strokes, 4 times as large, go from black to white in a few pixels; blurred, nothing steeper than a
        // tenth of that is left.
        let steps = (steepestStep(blurred[k], width: size.x, inside), steepestStep(plain[k], width: size.x, inside))
        #expect(steps.1 > 30 && steps.0 <= 8, "frame \(k) of \(frames.count): \(steps)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func drawnScreenIsWhereTheRegionsAreDrawn() async throws {
    // Through a zoom on the stage, and in the Split's card with the zoom inside it: a fill over the middle of the content
    // is drawn at its fractions of `drawnScreen`'s rect, what the editor's rect of a block is placed by.
    let take = makeTake(tracks: [
        displayTrack(globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), segments: [segment(start: base, end: base.adding(seconds: 3))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 3))]),
    ])
    let hidden = NormalizedRect(x: 0.4, y: 0.35, width: 0.2, height: 0.3)
    var onTheStage = document(take, blocks: [block(1, .fill, color: RGBA(1, 0, 0, 1), rect: hidden)])
    onTheStage.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 1.6, focus: .fixed(x: 0.45, y: 0.5), instant: true)]
    var inACard = onTheStage
    inACard.camera.layouts = [LayoutBlock(
        id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 3), kind: .split, instant: true, bubble: nil,
        split: SplitLayout())]
    let size = SIMD2(1280, 720)
    let frames = [onTheStage, inACard].map { FrameEvaluator(take: take, events: [], document: $0, outputSize: size).frame(at: 1.5) }
    try #require(frames[0].stage != nil && !frames[0].isCardMode && frames[1].card != nil)
    let drawn = try await offThePool {
        let drawer = try PrivacyDrawer()
        let screen = try StageDrawing.screenTexture(device: drawer.device)
        return try frames.map { try drawer.draw($0, screen: screen) }
    }
    for (frame, bytes) in zip(frames, drawn) {
        let screen = try #require(frame.drawnScreen)
        let output = Rect(
            x: screen.rect.x + hidden.x * screen.rect.width, y: screen.rect.y + hidden.y * screen.rect.height,
            width: hidden.width * screen.rect.width, height: hidden.height * screen.rect.height)
        let red = SIMD4<UInt8>(0, 0, 255, 255)
        let inside = pixels(in: output, inset: 1, width: size.x, height: size.y)
        let around = Set(pixels(in: Rect(x: output.x - 3, y: output.y - 3, width: output.width + 6, height: output.height + 6),
                                width: size.x, height: size.y).map { $0.y * size.x + $0.x })
            .subtracting(pixels(in: Rect(x: output.x - 1, y: output.y - 1, width: output.width + 2, height: output.height + 2),
                                width: size.x, height: size.y).map { $0.y * size.x + $0.x })
        #expect(inside.count > 10_000 && inside.allSatisfy { pixel(bytes, width: size.x, x: $0.x, y: $0.y) == red }, "card: \(frame.isCardMode)")
        #expect(!around.isEmpty && around.allSatisfy { pixel(bytes, width: size.x, x: $0 % size.x, y: $0 / size.x) != red })
    }
}

// MARK: - The render

/// A take of a 640 × 360 display for 2 s whose frames are a checkerboard of 8 px squares.
private func checkerboardProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: Rect(x: 0, y: 0, width: 640, height: 360)),
        segments: [VideoSegmentSpec(start: base, seconds: 2, transform: paintingACheckerboard)])
    return try builder.write()
}

/// `sample` with its whole frame a black and white checkerboard of 8 px squares.
@Sendable private func paintingACheckerboard(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<height {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for x in 0..<width { row[x] = (x / 8 + y / 8) % 2 == 0 ? 0xFFFF_FFFF : 0xFF00_0000 }
    }
    return sample
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aBilinearLegacyDocumentStillBlurs() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await checkerboardProject(in: dir)
        var document = EditDocument.legacy(for: project)
        #expect(document.style.screenSampling == .bilinear)
        let hidden = NormalizedRect(x: 0.25, y: 0.3, width: 0.5, height: 0.3)
        document.privacy = PrivacyPlan(blocks: [block(1, from: 0, to: 2, .blur, strength: 0.6, rect: hidden)])
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let plain = try FrameRenderer(project: project, outputSize: size)
        let screen = try #require(FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            .frame(at: 1).screen)
        #expect(screen.mipmapped)
        let (blurred, sharp) = try await offThePool { (try renderer.renderBytes(at: 1), try plain.renderBytes(at: 1)) }
        let output = Rect(
            x: screen.rect.x + hidden.x * screen.rect.width, y: screen.rect.y + hidden.y * screen.rect.height,
            width: hidden.width * screen.rect.width, height: hidden.height * screen.rect.height)
        let inside = pixels(in: output, width: size.x, height: size.y)
        let deviations = (lumaDeviation(blurred, width: size.x, inside), lumaDeviation(sharp, width: size.x, inside))
        #expect(deviations.1 > 100 && deviations.0 <= 3, "\(deviations)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aMissingMipmapCopyFillsBlack() async throws {
    // Metal cannot make the copy with mipmaps: the screen is drawn from its frame, and every region black, whatever its
    // effect; a screen without regions that asks for the copy fails, as ever.
    let rects = [region(40, 40, 160, 60), region(260, 40, 160, 60), region(440, 200, 160, 100)]
    let effects: [PrivacyEffect] = [.blur, .pixelate, .fill]
    let privacy = zip(rects, effects).map { PrivacyRegion(rect: $0, effect: $1, strength: 0.6, color: [1, 0, 0, 1]) }
    let (failed, bilinear, plainFailed, copies) = try await offThePool {
        let drawer = try PrivacyDrawer()
        let text = try drawer.text(["an@gmail.com  4242 4242", "sk_live_1234567890"], in: CGRect(x: 30, y: 30, width: 580, height: 280))
        drawer.compositor.makeScreenCopiesFail(true)
        let failed = try drawer.draw(screenFrame(size: size360, rect: full360, privacy: privacy), screen: text)
        let bilinear = try drawer.draw(screenFrame(size: size360, rect: full360, mipmapped: false), screen: text)
        var plainFailed = false
        do { _ = try drawer.draw(screenFrame(size: size360, rect: full360), screen: text) } catch RenderError.metalResourceUnavailable {
            plainFailed = true
        }
        drawer.compositor.makeScreenCopiesFail(false)
        return (failed, bilinear, plainFailed, drawer.compositor.mipmappedCopiesCount.made)
    }
    #expect(plainFailed && copies == 0)
    let inside = Set(rects.flatMap { r in
        pixels(in: Rect(x: r.x * 640, y: r.y * 360, width: r.width * 640, height: r.height * 360), width: 640, height: 360)
    }.map { $0.y * 640 + $0.x })
    var wrong = 0
    for y in 0..<360 {
        for x in 0..<640 {
            let a = pixel(failed, width: 640, x: x, y: y)
            if inside.contains(y * 640 + x) ? a != SIMD4(0, 0, 0, 255) : a != pixel(bilinear, width: 640, x: x, y: y) { wrong += 1 }
        }
    }
    #expect(wrong == 0, "\(wrong) pixels")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewIsTheExportWithPrivacy() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await checkerboardProject(in: dir)
        var document = EditDocument.legacy(for: project)
        document.privacy = PrivacyPlan(blocks: [
            block(1, from: 0, to: 2, .blur, strength: 0.6, rect: NormalizedRect(x: 0.05, y: 0.1, width: 0.4, height: 0.3)),
            block(2, from: 0.3, to: 2, .pixelate, rect: NormalizedRect(x: 0.5, y: 0.1, width: 0.4, height: 0.4), keys: [
                RectKey(t: base.adding(seconds: 0.5), rect: NormalizedRect(x: 0.5, y: 0.1, width: 0.4, height: 0.4)),
                RectKey(t: base.adding(seconds: 1.5), rect: NormalizedRect(x: 0.3, y: 0.5, width: 0.3, height: 0.3)),
            ]),
            block(3, from: 0, to: 1.5, .fill, color: RGBA(0.1, 0.7, 0.3, 1), rect: NormalizedRect(x: 0.1, y: 0.6, width: 0.3, height: 0.3)),
        ])
        document.zoom.regions = [StageDrawing.zoom(1, from: 0.6, to: 1.8, depth: 2, focus: .fixed(x: 0.4, y: 0.4))]
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let preview = PreviewRenderer(renderer: renderer)
        let plain = try FrameRenderer(project: project, outputSize: size)
        for t in [0.2, 0.9, 1.4] {
            let (exported, previewed, unblocked) = try await offThePool { () -> ([UInt8], [UInt8], [UInt8]) in
                var created: CVPixelBuffer?
                let attributes = [
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
                ] as CFDictionary
                let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
                guard status == kCVReturnSuccess, let pixelBuffer = created else { throw TestSupportError.failed("no pixel buffer") }
                try renderer.render(at: t, into: pixelBuffer)
                return (packedBytes(of: pixelBuffer), try preview.snapshot(at: t), try plain.renderBytes(at: t))
            }
            #expect(exported.count == size.x * size.y * 4)
            #expect(exported == previewed, "at \(t) s")
            #expect(exported != unblocked, "at \(t) s the blocks are drawn")
        }
    }
}

// MARK: - Bench

/// The GPU's time for frames of a 4K screen with 8 blurred blocks at 0.6 over it, while a zoom moves in, drawn at 1080p
/// and at 4K, with and without the camera's motion blur, against the same frames without the blocks. Run by an agent,
/// with `TOMA_BENCH=1`, in release; printed and recorded in docs/performance.md ("Medidas del agente, fase 2"), not
/// asserted but for the 16.7 ms of a 60 fps preview at 1080p.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && MetalCondition.isAvailable))
func privacyPreviewBench() async throws {
    let take = makeTake(tracks: [
        displayTrack(
            globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080), pixelScale: 2,
            segments: [segment(start: base, end: base.adding(seconds: 6))]),
    ])
    let blocks = (0..<8).map { k in
        block(k + 1, from: 0, to: 6, .blur, strength: 0.6, rect: NormalizedRect(
            x: 0.03 + 0.24 * Double(k % 4), y: 0.1 + 0.45 * Double(k / 4), width: 0.2, height: 0.3))
    }
    func frames(output: SIMD2<Int>, blocks: [PrivacyBlock], motionBlur: Double) -> [RenderFrame] {
        var doc = document(take, blocks: blocks)
        doc.frameRate = 60
        doc.style.screenSampling = .mipmapped
        doc.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 5, depth: 2, focus: .fixed(x: 0.4, y: 0.45))]
        doc.zoom.motionBlur = motionBlur
        let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: output, frameRate: 60)
        return (30..<(30 + 8 + 120)).map { evaluator.frame(at: Double(TimeMap.frameTime($0, frameRate: 60)) / 1e9) }
    }
    for output in [SIMD2(1920, 1080), SIMD2(3840, 2160)] {
        for motionBlur in [0.0, 1.0] {
            var line: [String] = []
            for (name, drawn) in [("8 blocks", blocks), ("none", [])] {
                let measured = frames(output: output, blocks: drawn, motionBlur: motionBlur)
                #expect(drawn.isEmpty || measured.allSatisfy { $0.screen?.privacy.count == 8 })
                let times = try await offThePool { try gpuTimes(of: measured, output: output) }
                line.append(String(format: "%@ GPU p50 %.2f ms, p95 %.2f ms, max %.2f ms", name, times.p50 * 1000, times.p95 * 1000, times.max * 1000))
                if output.x == 1920, motionBlur == 0, !drawn.isEmpty { #expect(times.p95 <= 0.0167, "p95 \(times.p95 * 1000) ms") }
            }
            print("privacyPreviewBench \(output.x) × \(output.y), motion blur \(motionBlur): " + line.joined(separator: "; "))
        }
    }
}

/// The GPU's time of each of `frames` drawn one after the other at `output` over a 4K screen, after eight to warm up: the
/// median, the 95th percentile and the largest, in seconds.
private func gpuTimes(of frames: [RenderFrame], output: SIMD2<Int>) throws -> (p50: Double, p95: Double, max: Double) {
    let drawer = try PrivacyDrawer()
    let screen = try drawer.text(
        (0..<24).map { "line \($0): an@gmail.com 4242 4242 4242 4242 sk_live_1234567890abcdef" },
        in: CGRect(x: 40, y: 40, width: 3760, height: 2080), width: 3840, height: 2160)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: output.x, height: output.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let target = try #require(drawer.device.makeTexture(descriptor: descriptor))
    var times: [Double] = []
    for (index, frame) in frames.enumerated() {
        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
        try drawer.compositor.encode(frame, screen: screen, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        if index >= 8 { times.append(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) }
    }
    let sorted = times.sorted()
    return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1], sorted.last ?? 0)
}
