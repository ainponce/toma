// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `DrawCounts` and the compositor's counting `encode`.
@testable import Render
import SyntheticCapture
import Testing

// The transparent background of the codecs with alpha (milestone 4c, design §7.1, plan 4c Task X1): nothing behind the
// stage, everything else over it with its premultiplied alpha, the motion blur's subsamples and a card's frame starting
// from nothing, Highlight and Dim darkening the stage drawn and not the void; and, with any other codec, the same calls
// and bytes as ever. Over frames of 640 × 360 with padding, round corners, a shadow and a macOS window frame.

private let size = SIMD2(640, 360)
private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
/// The background of the documents here, which nothing else draws: where the opaque frame shows it, it is the void.
private let backdrop = RGBA(0.1, 0.8, 0.3, 1)
private let hash = "0123456789abcdef0123456789abcdef"

// MARK: - Fixtures

/// `sample` painted pure blue.
@Sendable private func paintingBlue(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFF00_00FF, count: width)  // BGRA (255, 0, 0, 255)
    }
    return sample
}

/// A take of one second of a blue screen, 640 × 360.
private func screenProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame),
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: paintingBlue)])
    return try builder.write()
}

/// `document` on `backdrop`, with round corners, a shadow and a light macOS window frame.
private func styled(_ document: EditDocument, background: Background = .color(backdrop), blur: Double = 0) -> EditDocument {
    var document = document
    document.style.background = background
    document.style.backgroundBlur = blur
    document.style.cornerRadius = 0.04
    document.style.shadow = 0.6
    document.style.frame = .macWindow(appearance: .light, title: "Toma", buttons: true)
    return document
}

/// An opaque PNG of one colour.
private func plainPNG(_ rgb: SIMD3<UInt8>, width: Int = 64, height: Int = 36) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(srgbRed: CGFloat(rgb.x) / 255, green: CGFloat(rgb.y) / 255, blue: CGFloat(rgb.z) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A cursor moving fast across display 1 (640 × 360 pt) for `seconds`: 1440 pt per second along x, back and forth.
private func fastCursor(seconds: Double = 3) -> [InputEvent] {
    (0..<Int(seconds * 120)).map { i in
        let phase = Double(i % 40) / 40
        let x = 20 + 600 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
        return StageDrawing.event(Double(i) / 120, .cursor(x: x, y: 180 + 100 * sin(Double(i) / 30)))
    }
}

/// A take of `seconds` on display 1 with a camera, without files.
private func cardTake(seconds: Double = 6) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: seconds))]),
    ])
}

/// The frame at `seconds` of `document` of `take`, with nothing behind its stage when `transparent`.
private func frame(
    _ take: TakeRecord, _ document: EditDocument, events: [InputEvent] = [], at seconds: Double, transparent: Bool
) -> RenderFrame {
    var scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
    scene.transparentBackground = transparent
    return scene.frame(at: seconds)
}

/// The calm zoom `mode` about the middle of `frame`'s screen, a fifth of it across; the loupe's lens, 60 px, about
/// (30, 180), in the padding left of the screen.
private func calm(_ mode: ZoomMode, over frame: RenderFrame) -> RenderFrame {
    var calm = frame
    if mode == .loupe {
        calm.calmZoom = CalmZoomLayer(
            mode: .loupe, amount: 1, focus: Rect(x: 20, y: 170, width: 20, height: 20),
            loupe: LoupeLayer(radius: 60, shape: .circle, magnification: 2))
    } else if let screen = frame.screen?.rect {
        calm.calmZoom = CalmZoomLayer(
            mode: mode, amount: 1,
            focus: Rect(x: screen.x + 0.4 * screen.width, y: screen.y + 0.4 * screen.height, width: 0.2 * screen.width,
                        height: 0.2 * screen.height))
    }
    return calm
}

/// A camera's frame over every pixel.
private func coveredByCamera(transparent: Bool) -> RenderFrame {
    RenderFrame(
        outputSize: size, gradientStart: [0.2, 0.3, 0.4, 1], gradientEnd: [0.6, 0.5, 0.4, 1], gradientAngleDegrees: 0,
        camera: CameraLayer(
            trackID: cameraID, sourceTime: base, rect: Rect(x: 0, y: 0, width: 640, height: 360), cornerRadius: 0),
        background: transparent ? .transparent : .gradient, coveredByCamera: true)
}

/// A title card without texts over the background alone: its veil (`fill` `nil`) or its colour.
private func titleCard(fill: RGBA?, transparent: Bool) -> RenderFrame {
    RenderFrame(
        outputSize: size, gradientStart: [0.2, 0.3, 0.4, 1], gradientEnd: [0.6, 0.5, 0.4, 1], gradientAngleDegrees: 0,
        background: transparent ? .transparent : .gradient,
        titleCard: TitleCardLayer(title: "", style: .centered, fill: fill, scrim: fill == nil ? 0.35 : 0))
}

/// Every kind of frame drawn here, by name: the stage still and under each motion blur, in a card with its own, with
/// each calm zoom, the camera over every pixel, and title cards.
private func frames(transparent: Bool) -> [(name: String, frame: RenderFrame)] {
    let take = StageDrawing.bareTake()
    let plain = styled(EditDocument.legacy(take: take, events: []))
    var zoomBlur = plain
    zoomBlur.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 1.5, focus: .fixed(x: 0.25, y: 0.3))]
    zoomBlur.zoom.motionBlur = 1
    let events = fastCursor()
    var cursorBlur = styled(EditDocument.legacy(take: take, events: events))
    cursorBlur.cursor.motionBlur = 1
    let cards = cardTake()
    var card = styled(EditDocument.legacy(take: cards, events: []))
    card.camera.show = true
    card.camera.layout = CameraLayout(kind: .split)
    card.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 2.5, focus: .fixed(x: 0.25, y: 0.3))]
    card.zoom.motionBlur = 1
    card.cursor.motionBlur = 0
    let still = frame(take, plain, at: 0.2, transparent: transparent)
    return [
        ("plain", still),
        ("zoomBlur", frame(take, zoomBlur, at: 0.7, transparent: transparent)),
        ("cursorBlur", frame(take, cursorBlur, events: events, at: 1.0, transparent: transparent)),
        ("cardBlur", frame(cards, card, at: 0.7, transparent: transparent)),
        ("highlight", calm(.highlight, over: still)),
        ("dim", calm(.dim, over: still)),
        ("loupe", calm(.loupe, over: still)),
        ("camera", coveredByCamera(transparent: transparent)),
        ("veil", titleCard(fill: nil, transparent: transparent)),
        ("filled", titleCard(fill: RGBA(0.2, 0.4, 0.6, 1), transparent: transparent)),
    ]
}

/// A compositor of the default device with `StageDrawing`'s smooth screen and a camera of it, and Toma's arrow.
private final class AlphaDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let camera: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        screen = try StageDrawing.screenTexture(device: device)
        camera = try StageDrawing.screenTexture(device: device, width: 64, height: 48)
        cursor = try CursorSprite.makeTexture(device: device)
    }

    /// `frame` drawn into a new target of its output size, as BGRA bytes, with what was drawn counted in `counts`.
    func draw(_ frame: RenderFrame, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen, camera: camera, cursor: cursor, into: target, commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        return StageDrawing.bytes(of: target)
    }

    func draw(_ frame: RenderFrame) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, counts: &counts)
    }
}

/// The pixels where `opaque` shows the background `backdrop` and nothing over it: the void of the transparent frame.
private func void(of opaque: [UInt8]) -> [(x: Int, y: Int)] {
    let colour = SIMD4<UInt8>(
        UInt8((backdrop.b * 255).rounded()), UInt8((backdrop.g * 255).rounded()), UInt8((backdrop.r * 255).rounded()), 255)
    return (0..<size.x * size.y).compactMap { i in
        let p = pixel(opaque, width: size.x, x: i % size.x, y: i / size.x)
        return p == colour ? (i % size.x, i / size.x) : nil
    }
}

/// `void` less what is within `margin` pixels of anything else, along both axes.
private func deepVoid(of opaque: [UInt8], margin: Int) -> [(x: Int, y: Int)] {
    var isVoid = [Bool](repeating: false, count: size.x * size.y)
    for p in void(of: opaque) { isVoid[p.y * size.x + p.x] = true }
    func eroded(_ mask: [Bool], along horizontal: Bool) -> [Bool] {
        (0..<size.x * size.y).map { i in
            let x = i % size.x, y = i / size.x
            return (-margin...margin).allSatisfy { d in
                let (u, v) = horizontal ? (x + d, y) : (x, y + d)
                guard u >= 0, u < size.x, v >= 0, v < size.y else { return true }
                return mask[v * size.x + u]
            }
        }
    }
    let deep = eroded(eroded(isVoid, along: true), along: false)
    return (0..<size.x * size.y).compactMap { deep[$0] ? ($0 % size.x, $0 / size.x) : nil }
}

private func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Int { Int(bytes[(y * size.x + x) * 4 + 3]) }

/// Whether pixel (`x`, `y`) of `bytes` holds nothing, but for the last level of a shadow's tail (black at alpha 1 / 255),
/// which over the opaque background rounds back to it: `void` finds it there.
private func holdsNothing(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Bool {
    let p = pixel(bytes, width: size.x, x: x, y: y)
    return p.x == 0 && p.y == 0 && p.z == 0 && p.w <= 1
}

/// Whether `a` and `b` are within `tolerance` in every channel.
private func near(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>, _ tolerance: Int) -> Bool {
    (0..<4).allSatisfy { abs(Int(a[$0]) - Int(b[$0])) <= tolerance }
}

// MARK: - Tests

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
struct AlphaRenderTests {
    @Test func voidIsTransparentAndTheScreenOpaque() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await screenProject(in: dir)
            let document = styled(EditDocument.legacy(for: project))
            let opaque = try FrameRenderer(project: project, document: document, outputSize: size)
            let clear = try FrameRenderer(project: project, document: document, outputSize: size, transparentBackground: true)
            let drawn = clear.scene.frame(at: 0.5)
            #expect(drawn.background == .transparent && opaque.scene.frame(at: 0.5).background != .transparent)
            let screen = try #require(drawn.screen?.rect)
            #expect(drawn.shadow != nil && drawn.windowFrame != nil)
            let a = try await offThePool { try opaque.renderBytes(at: 0.5) }
            let b = try await offThePool { try clear.renderBytes(at: 0.5) }
            // The padding is nothing.
            #expect(pixel(b, width: size.x, x: 8, y: 8) == .zero)
            let bad = void(of: a).filter { !holdsNothing(b, $0.x, $0.y) }
            #expect(bad.isEmpty, "\(bad.count) \(bad.prefix(8).map { ($0, pixel(b, width: size.x, x: $0.x, y: $0.y)) })")
            // The screen, opaque, as it is in the opaque frame: away from its round corners and edges, every pixel.
            let inset = 0.04 * Double(size.y) + 2
            for y in Int(screen.y + inset)..<Int(screen.y + screen.height - inset) {
                for x in Int(screen.x + inset)..<Int(screen.x + screen.width - inset) {
                    let p = pixel(b, width: size.x, x: x, y: y)
                    guard p.w == 255, p == pixel(a, width: size.x, x: x, y: y) else {
                        Issue.record("screen at (\(x), \(y)): \(p), opaque \(pixel(a, width: size.x, x: x, y: y))")
                        return
                    }
                }
            }
            // Under its bottom edge, the shadow: black, partly there.
            let below = Int((screen.y + screen.height).rounded(.up)) + 2
            let shadow = pixel(b, width: size.x, x: Int(screen.x + screen.width / 2), y: below)
            #expect(shadow.w > 0 && shadow.w < 255 && shadow.x == 0 && shadow.y == 0 && shadow.z == 0, "\(shadow)")
        }
    }

    @Test func everyBackgroundKindIsLeftOut() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await screenProject(in: dir)
            let file = "assets/\(hash).png"
            let url = project.package.url.appendingPathComponent(file, isDirectory: false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plainPNG([200, 40, 90]).write(to: url)
            let kinds: [(Background, Double)] = [
                (.gradient(start: RGBA(0.9, 0.2, 0.1, 1), end: RGBA(0.1, 0.3, 0.9, 1), angle: 30), 0), (.color(backdrop), 0),
                (.wallpaper("aurora-1"), 0), (.wallpaper("aurora-1"), 0.5), (.image(file: file), 0),
            ]
            var drawn: [[UInt8]] = []
            for (background, blur) in kinds {
                let document = styled(EditDocument.legacy(for: project), background: background, blur: blur)
                let opaque = try FrameRenderer(project: project, document: document, outputSize: size)
                let clear = try FrameRenderer(project: project, document: document, outputSize: size, transparentBackground: true)
                let a = try await offThePool { try opaque.renderBytes(at: 0.5) }
                let b = try await offThePool { try clear.renderBytes(at: 0.5) }
                #expect(pixel(a, width: size.x, x: 8, y: 8).w == 255 && pixel(a, width: size.x, x: 8, y: 8) != .zero, "\(background)")
                #expect(pixel(b, width: size.x, x: 8, y: 8) == .zero, "\(background)")
                drawn.append(b)
            }
            // Nothing of any of them is drawn: the same bytes with each.
            #expect(drawn.allSatisfy { $0 == drawn[0] })
        }
    }

    @Test func motionBlurLeavesTheVoidClear() throws {
        let drawer = try AlphaDrawer()
        let opaque = try #require(frames(transparent: false).first { $0.name == "zoomBlur" }?.frame)
        let frame = try #require(frames(transparent: true).first { $0.name == "zoomBlur" }?.frame)
        let count = frame.subframes.count
        #expect(count > 1 && frame.cursorSamples.isEmpty && frame.background == .transparent)
        var counts = DrawCounts()
        let blurred = try drawer.draw(frame, counts: &counts)
        #expect(counts.transparentFills == count && counts.backgrounds == count && counts.accumulations == count, "\(counts)")
        let void = void(of: try drawer.draw(opaque))
        #expect(void.count > 1000 && void.contains { $0 == (8, 8) })
        #expect(void.allSatisfy { holdsNothing(blurred, $0.x, $0.y) })
        #expect(pixel(blurred, width: size.x, x: 8, y: 8) == .zero)
        // Each pixel's alpha is the average of its subsamples' alphas, drawn one by one.
        var sum = [Int](repeating: 0, count: size.x * size.y)
        for subframe in frame.subframes {
            var one = frame
            one.subframes = [subframe]
            let drawn = try drawer.draw(one)
            for i in sum.indices { sum[i] += Int(drawn[4 * i + 3]) }
        }
        let off = sum.indices.filter { abs(Double(sum[$0]) / Double(count) - Double(blurred[4 * $0 + 3])) > 1 }
        #expect(off.isEmpty, "\(off.prefix(5).map { ($0 % size.x, $0 / size.x) })")
    }

    @Test func cursorSamplesLeaveTheVoidClear() throws {
        let drawer = try AlphaDrawer()
        let opaque = try #require(frames(transparent: false).first { $0.name == "cursorBlur" }?.frame)
        let frame = try #require(frames(transparent: true).first { $0.name == "cursorBlur" }?.frame)
        #expect(frame.cursorSamples.count > 1 && frame.subframes.isEmpty)
        var counts = DrawCounts()
        let blurred = try drawer.draw(frame, counts: &counts)
        #expect(counts.transparentFills == 1 && counts.cursors == frame.cursorSamples.count, "\(counts)")
        let void = void(of: try drawer.draw(opaque))
        #expect(void.count > 1000 && pixel(blurred, width: size.x, x: 8, y: 8) == .zero)
        let bad = void.filter { !holdsNothing(blurred, $0.x, $0.y) }
        #expect(bad.isEmpty, "\(bad.count) \(bad.prefix(8).map { ($0, pixel(blurred, width: size.x, x: $0.x, y: $0.y)) })")
    }

    @Test func cardBlurLeavesTheVoidClear() throws {
        let drawer = try AlphaDrawer()
        let opaque = try #require(frames(transparent: false).first { $0.name == "cardBlur" }?.frame)
        let frame = try #require(frames(transparent: true).first { $0.name == "cardBlur" }?.frame)
        let card = try #require(frame.card)
        #expect(frame.subframes.count > 1)
        var counts = DrawCounts()
        let blurred = try drawer.draw(frame, counts: &counts)
        // The card's frame drawn once over the last subsample's content, which it leaves nothing of.
        #expect(counts.transparentFills == 1 && counts.accumulations == frame.subframes.count, "\(counts)")
        let void = void(of: try drawer.draw(opaque))
        #expect(void.count > 1000 && pixel(blurred, width: size.x, x: 8, y: 8) == .zero)
        // The content covers its cut to the card in every subsample, so each pixel's alpha is the sharp card's but for
        // the sum's half precision at the card's edge: none of the last content is left under the frame, at the edge
        // either.
        var sharp = frame
        sharp.subframes = []
        let once = try drawer.draw(sharp)
        let off = (0..<size.x * size.y).filter { abs(Int(blurred[4 * $0 + 3]) - Int(once[4 * $0 + 3])) > 2 }
        #expect(off.isEmpty, "\(off.count) \(off.prefix(5).map { ($0 % size.x, $0 / size.x) })")
        let left = void.filter { !holdsNothing(blurred, $0.x, $0.y) }
        let shown = left.prefix(8).map { ($0, pixel(blurred, width: size.x, x: $0.x, y: $0.y)) }
        #expect(left.isEmpty, "\(left.count) \(shown) outside the card \(card.rect)")
    }

    @Test func coveredByCameraAndTitleCards() throws {
        let drawer = try AlphaDrawer()
        var counts = DrawCounts()
        let camera = try drawer.draw(coveredByCamera(transparent: true), counts: &counts)
        #expect(counts.cameras == 1 && counts.transparentFills == 0 && counts.renderPasses == 1, "\(counts)")
        #expect((0..<size.x * size.y).allSatisfy { camera[4 * $0 + 3] == 255 })
        // A veil without a fill: black at the veil's alpha over nothing.
        let veil = try drawer.draw(titleCard(fill: nil, transparent: true))
        let scrim = UInt8((0.35 * 255).rounded())
        #expect(near(pixel(veil, width: size.x, x: 8, y: 8), [0, 0, 0, scrim], 1), "\(pixel(veil, width: size.x, x: 8, y: 8))")
        #expect(near(pixel(veil, width: size.x, x: 320, y: 180), [0, 0, 0, scrim], 1))
        // An opaque fill: opaque.
        let filled = try drawer.draw(titleCard(fill: RGBA(0.2, 0.4, 0.6, 1), transparent: true))
        #expect((0..<size.x * size.y).allSatisfy { filled[4 * $0 + 3] == 255 })
        #expect(near(pixel(filled, width: size.x, x: 8, y: 8), [153, 102, 51, 255], 1))
    }

    @Test func calmZoomDarkensTheStageNotTheVoid() throws {
        let drawer = try AlphaDrawer()
        let opaqueFrames = frames(transparent: false), clearFrames = frames(transparent: true)
        func pair(_ name: String) throws -> (opaque: [UInt8], clear: [UInt8]) {
            let opaque = try #require(opaqueFrames.first { $0.name == name }?.frame)
            let clear = try #require(clearFrames.first { $0.name == name }?.frame)
            return (try drawer.draw(opaque), try drawer.draw(clear))
        }
        let still = try #require(clearFrames.first { $0.name == "plain" }?.frame)
        let screen = try #require(still.screen?.rect)
        let plain = try pair("plain")
        // The void 12 px from anything drawn: beyond Dim's blur and Highlight's glow.
        let deep = deepVoid(of: plain.opaque, margin: 12)
        #expect(deep.count > 1000)
        // Inside the screen, outside the focus and 30 px from the screen's edge: the stage, as darkened over the
        // opaque frame.
        let stage = [
            (Int(screen.x) + 30, Int(screen.y) + 30), (Int(screen.x + screen.width) - 30, Int(screen.y + screen.height) - 30),
        ]
        for mode in ["highlight", "dim"] {
            let drawn = try pair(mode)
            let lit = deep.filter { alpha(drawn.clear, $0.x, $0.y) > 1 }
            #expect(lit.isEmpty, "\(mode): \(lit.prefix(5))")
            for (x, y) in stage {
                let a = pixel(drawn.opaque, width: size.x, x: x, y: y), b = pixel(drawn.clear, width: size.x, x: x, y: y)
                #expect(near(a, b, 1), "\(mode) at (\(x), \(y)): \(b), opaque \(a)")
                #expect(a != pixel(plain.opaque, width: size.x, x: x, y: y), "\(mode) darkens (\(x), \(y))")
            }
        }
        // The loupe as it is: over the void, its lens and its ring are drawn.
        let loupe = try pair("loupe")
        #expect(alpha(plain.clear, 30, 180) == 0)
        #expect(alpha(loupe.clear, 30, 180) > 0 && alpha(loupe.clear, 30, 121) > 0)
    }

    @Test func opaqueFramesDrawTheSameCalls() async throws {
        let drawer = try AlphaDrawer()
        // What each frame drew before milestone 4c (recorded from fase-4-5 cd71b32): the same calls with any other codec.
        let before: [String: DrawCounts] = legacyCounts
        for (name, frame) in frames(transparent: false) {
            #expect(frame.background != .transparent, "\(name)")
            var counts = DrawCounts()
            _ = try drawer.draw(frame, counts: &counts)
            #expect(counts.transparentFills == 0, "\(name)")
            #expect(counts == before[name], "\(name): \(counts)")
        }
        // A renderer without the argument is one with it `false`: the same frames and bytes.
        try await withTemporaryDirectory { dir in
            let project = try await screenProject(in: dir)
            let document = styled(EditDocument.legacy(for: project))
            let plain = try FrameRenderer(project: project, document: document, outputSize: size)
            let opaque = try FrameRenderer(project: project, document: document, outputSize: size, transparentBackground: false)
            #expect(plain.scene.frame(at: 0.5) == opaque.scene.frame(at: 0.5))
            let a = try await offThePool { try plain.renderBytes(at: 0.5) }
            let b = try await offThePool { try opaque.renderBytes(at: 0.5) }
            #expect(a == b)
        }
    }
}

/// `DrawCounts` of each of `frames(transparent: false)` before milestone 4c, recorded from fase-4-5 cd71b32.
private let legacyCounts: [String: DrawCounts] = [
    "plain": DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, overlaySteps: 1, stageOverlaySteps: 1),
    "zoomBlur": DrawCounts(renderPasses: 1, backgrounds: 6, screens: 6, accumulations: 6, overlaySteps: 1, stageOverlaySteps: 1),
    "cursorBlur": DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cursors: 2, overlaySteps: 1, stageOverlaySteps: 1),
    "cardBlur": DrawCounts(
        renderPasses: 1, backgrounds: 1, screens: 16, accumulations: 16, cameras: 1, overlaySteps: 1, stageOverlaySteps: 1),
    "highlight": DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, overlaySteps: 1, calmZooms: 1, stageOverlaySteps: 1),
    "dim": DrawCounts(
        renderPasses: 2, backgrounds: 1, screens: 1, overlaySteps: 1, calmZooms: 1, stageOverlaySteps: 1, calmZoomSamples: 1),
    "loupe": DrawCounts(
        renderPasses: 2, backgrounds: 1, screens: 1, overlaySteps: 1, calmZooms: 1, stageOverlaySteps: 1, calmZoomSamples: 1),
    "camera": DrawCounts(renderPasses: 1, cameras: 1, overlaySteps: 1),
    "veil": DrawCounts(renderPasses: 1, backgrounds: 1, overlaySteps: 1, titleCards: 1, stageOverlaySteps: 1),
    "filled": DrawCounts(renderPasses: 1, backgrounds: 1, overlaySteps: 1, titleCards: 1, stageOverlaySteps: 1),
]
