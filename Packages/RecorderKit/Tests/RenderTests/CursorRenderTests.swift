// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

// The drawn cursor (design §7.5): the recorded images or Toma's cursors, placed by their hotspot, sized from the
// recorded height, with the cursor path's position, opacity and press.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(1280, 720)
/// The background of these frames: a colour that is neither red nor any of a cursor's.
private let backgroundColor = RGBA(0.2, 0.4, 0.6, 1)
private let red: SIMD4<Float> = [0, 0, 255, 255]

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// opens its files, which blocks (`offThePool` in DocumentRenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// A PNG of `width` × `height` pixels of opaque red.
private func redPNG(width: Int, height: Int) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A take of one second on display 1 (`screenFrame`) whose video file is missing, so no screen is drawn and nothing
/// is decoded: the cursor is all there is over the background. The pointer is at the display's centre from the start,
/// and `images` adds the take's cursor images.
private func cursorProject(in dir: URL, images: (TakeBuilder) throws -> Void = { _ in }) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: screenFrame), segments: [])
    try builder.addEmptySegment(
        track: trackID, index: 1, start: base, end: base.adding(seconds: 1), endReason: .stopped, file: .absent)
    try builder.addEvents([InputEvent(t: base, kind: .cursor(x: 320, y: 180))])
    try images(builder)
    return try builder.write()
}

/// The legacy document of `project` over a plain background, with the cursor in `style`.
private func document(_ project: LoadedProject, style: CursorLook) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.style.background = .color(backgroundColor)
    document.cursor.style = style
    return document
}

private func evaluate(_ project: LoadedProject, _ document: EditDocument, at t: Double = 0.5) -> RenderFrame {
    FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size).frame(at: t)
}

/// The frame at `t` of `document`, as BGRA bytes.
private func render(_ project: LoadedProject, _ document: EditDocument, at t: Double = 0.5) async throws -> [UInt8] {
    let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
    return try await offThePool { try renderer.renderBytes(at: t) }
}

/// `frame` drawn by a compositor of the default device with `cursor` as its cursor's texture and no screen, as BGRA bytes.
private func composite(_ frame: RenderFrame, cursor: (any MTLDevice) throws -> any MTLTexture) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: descriptor))
    let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    compositor.encode(frame, screen: nil, camera: nil, cursor: try cursor(device), into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
    target.getBytes(
        &bytes, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y),
        mipmapLevel: 0)
    return bytes
}

/// The smallest box holding every pixel of `bytes` (`width` wide) within 3 of `color`: its first and last column and
/// row; `nil` when none is.
private func box(of color: SIMD4<Float>, in bytes: [UInt8], width: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
    var xs: [Int] = [], ys: [Int] = []
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let p = SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        guard isClose(p, color, tolerance: 3) else { continue }
        xs.append(i / 4 % width)
        ys.append(i / 4 / width)
    }
    guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
    return (x0...x1, y0...y1)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func recordedImageIsPlacedByItsHotspot() async throws {
    try await withTemporaryDirectory { dir in
        // 24 × 32 pt drawn at 2×, not the recorder's usual 4×: its size comes from its points.
        var hash = ""
        let project = try await cursorProject(in: dir) { builder in
            hash = try builder.addCursorImage(redPNG(width: 48, height: 64), hotspot: [0.5, 0.5], size: [24, 32], at: base)
        }
        let system = document(project, style: .system)
        let frame = evaluate(project, system)
        let layer = try #require(frame.cursor)
        let rect = try #require(frame.screen).rect
        #expect(layer.image == .recorded(hash: hash))
        #expect(layer.hotspotFraction == [0.5, 0.5] && layer.aspect == 0.75)
        #expect(layer.height == 32 * rect.height / 360)
        // The pointer is at the display's centre: the screen's.
        #expect(layer.hotspot == SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2))

        let bytes = try await render(project, system)
        let point = pixel(bytes, width: size.x, x: Int(layer.hotspot.x), y: Int(layer.hotspot.y))
        #expect(isClose(point, red, tolerance: 3), "\(point)")
        // The red is the image's 0.75 h × h, centred on the pointer.
        let drawn = try #require(box(of: red, in: bytes, width: size.x))
        let width = Double(drawn.x.count), height = Double(drawn.y.count)
        #expect(abs(width - 0.75 * layer.height) <= 1.5 && abs(height - layer.height) <= 1.5, "\(width) × \(height)")
        let centre = SIMD2(
            Double(drawn.x.lowerBound + drawn.x.upperBound + 1) / 2, Double(drawn.y.lowerBound + drawn.y.upperBound + 1) / 2)
        #expect(abs(centre.x - layer.hotspot.x) <= 1 && abs(centre.y - layer.hotspot.y) <= 1, "\(centre) vs \(layer.hotspot)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func missingOrUnreadableImageFallsBackToTheArrow() async throws {
    try await withTemporaryDirectory { dir in
        let png = try redPNG(width: 96, height: 128)
        var hash = ""
        // An image of the arrow's kind: in Toma's style, `.toma(.arrow)` is drawn for it.
        let project = try await cursorProject(in: dir) { builder in
            hash = try builder.addCursorImage(png, hotspot: [0.5, 0.5], size: [24, 32], kind: .arrow, at: base)
        }
        let toma = document(project, style: .toma)
        let system = document(project, style: .system)
        #expect(evaluate(project, toma).cursor?.image == .toma(.arrow))
        let arrow = try await render(project, toma)
        // While the image can be read, the system style draws it, not the arrow.
        #expect(try await render(project, system) != arrow)

        let url = project.package.cursorImageURL(take: takeID, hash: hash)
        // Damaged.
        try Data(repeating: 0x5A, count: 512).write(to: url)
        #expect(try await render(project, system) == arrow)
        // A link to a readable image: never followed (only the package's safe reader opens cursor images).
        try FileManager.default.removeItem(at: url)
        let elsewhere = dir.appendingPathComponent("elsewhere.png")
        try png.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        #expect(try await render(project, system) == arrow)
        // Deleted.
        try FileManager.default.removeItem(at: url)
        #expect(try await render(project, system) == arrow)

        // What the renderer draws for it: the arrow's frame, in place of the image's.
        let fallback = FrameEvaluator(take: project.take, events: project.events, document: system, outputSize: size)
            .frame(at: 0.5) { _ in false }
        #expect(fallback.cursor == evaluate(project, toma).cursor)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func tomaStyleDrawsTheTomaCursorOfTheRecordedKind() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cursorProject(in: dir) { builder in
            try builder.addCursorImage(redPNG(width: 36, height: 72), hotspot: [0.5, 0.5], size: [9, 18], kind: .iBeam, at: base)
        }
        let toma = document(project, style: .toma)
        let frame = evaluate(project, toma)
        let layer = try #require(frame.cursor)
        let rect = try #require(frame.screen).rect
        #expect(layer.image == .toma(.iBeam))
        #expect(layer.hotspotFraction == CursorSprite.hotspot(of: .iBeam) && layer.aspect == CursorSprite.aspect(of: .iBeam))
        // Toma's cursors are 24 pt tall, whatever the recorded one was.
        #expect(layer.height == 24 * rect.height / 360)

        let bytes = try await render(project, toma)
        #expect(try bytes == composite(frame) { try CursorSprite.makeTexture(device: $0, kind: .iBeam) })
        #expect(box(of: red, in: bytes, width: size.x) == nil)
        // The system style draws the recorded image instead.
        #expect(box(of: red, in: try await render(project, document(project, style: .system)), width: size.x) != nil)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func everyTomaCursorKindDraws() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    var drawn: [[UInt8]] = []
    for kind in CursorKind.allCases {
        let texture = try CursorSprite.makeTexture(device: device, kind: kind)
        #expect(texture.height == 128 && texture.pixelFormat == .bgra8Unorm && texture.mipmapLevelCount > 1, "\(kind)")
        #expect(Double(texture.width) / Double(texture.height) == CursorSprite.aspect(of: kind), "\(kind)")
        let hotspot = CursorSprite.hotspot(of: kind)
        #expect((0...1).contains(hotspot.x) && (0...1).contains(hotspot.y), "\(kind): \(hotspot)")
        for level in 0..<texture.mipmapLevelCount {
            let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level)
            // Something is drawn, premultiplied (no channel above alpha), and not all of it: a shape, not a block.
            let alphas = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
            #expect(alphas.contains { $0 > 0 }, "\(kind) level \(level)")
            if level == 0 {
                #expect(alphas.contains(0), "\(kind)")
                #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                    max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) <= bytes[$0 + 3]
                }, "\(kind)")
                drawn.append(bytes)
            }
        }
    }
    // Nine shapes, all different.
    #expect(Set(drawn).count == CursorKind.allCases.count)
    // The arrow is today's, every level of it.
    let today = try CursorSprite.makeTexture(device: device)
    let arrow = try CursorSprite.makeTexture(device: device, kind: .arrow)
    #expect(CursorSprite.hotspot(of: .arrow) == CursorSprite.hotspot && CursorSprite.aspect(of: .arrow) == CursorSprite.aspect)
    #expect(today.mipmapLevelCount == arrow.mipmapLevelCount)
    for level in 0..<today.mipmapLevelCount {
        let width = max(1, today.width >> level), height = max(1, today.height >> level)
        var a = [UInt8](repeating: 0, count: width * height * 4), b = a
        today.getBytes(&a, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level)
        arrow.getBytes(&b, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level)
        #expect(a == b, "level \(level)")
    }
}

/// A take of `seconds` on display 1, 640 × 360 pt, without files.
private func bareTake(seconds: Double = 2) -> TakeRecord {
    makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: seconds))])])
}

private func cursorImage(_ t: Double, size: SIMD2<Double>, kind: CursorKind? = nil) -> InputEvent {
    InputEvent(
        t: base.adding(seconds: t),
        kind: .cursorImage(hash: "00112233445566778899aabbccddeeff", hotspot: [0.25, 0.5], size: size, kind: kind))
}

@Test func sizeFollowsScaleAndTheRecordedHeight() {
    let take = bareTake()
    let events = [InputEvent(t: base, kind: .cursor(x: 320, y: 180)), cursorImage(0.5, size: [24, 32])]
    var document = EditDocument.legacy(take: take, events: events)
    // No padding in an output half the display's size: R.height / region.height is 0.5.
    document.style.padding = 0
    document.cursor.scale = 1.5
    document.cursor.style = .system
    func layer(at t: Double, _ document: EditDocument) -> CursorLayer? {
        FrameEvaluator(take: take, events: events, document: document, outputSize: [320, 180]).frame(at: t).cursor
    }
    let recorded = layer(at: 1, document)
    #expect(recorded?.height == 24)
    #expect(recorded?.image == .recorded(hash: "00112233445566778899aabbccddeeff"))
    #expect(recorded?.hotspotFraction == [0.25, 0.5] && recorded?.aspect == 0.75)
    // Before the first image, the arrow: 24 pt × 1.5 × 0.5.
    #expect(layer(at: 0.25, document) == CursorLayer(hotspot: [160, 90], height: 18))
    // In Toma's style, an image without a kind is drawn as recorded; with one, Toma's cursor of that kind, 24 pt.
    document.cursor.style = .toma
    #expect(layer(at: 1, document) == recorded)
    let iBeam = [events[0], cursorImage(0.5, size: [24, 32], kind: .iBeam)]
    let toma = FrameEvaluator(take: take, events: iBeam, document: document, outputSize: [320, 180]).frame(at: 1).cursor
    #expect(toma == CursorLayer(
        hotspot: [160, 90], height: 18, image: .toma(.iBeam), hotspotFraction: CursorSprite.hotspot(of: .iBeam),
        aspect: CursorSprite.aspect(of: .iBeam)))
    // An image of no usable size is drawn as one that cannot be read: the arrow.
    for unusable in [SIMD2<Double>(24, 0), [0, 32], [.nan, 32], [24, .infinity]] {
        document.cursor.style = .system
        let events = [events[0], cursorImage(0.5, size: unusable)]
        let frame = FrameEvaluator(take: take, events: events, document: document, outputSize: [320, 180]).frame(at: 1)
        #expect(frame.cursor == CursorLayer(hotspot: [160, 90], height: 18), "\(unusable)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func hiddenCursorDrawsNothing() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cursorProject(in: dir)
        var hiding = document(project, style: .toma)
        hiding.cursor.hideWhenIdle = true
        hiding.cursor.idleDelay = 0.1
        var none = hiding
        none.cursor.show = false
        // Still since output 0: hidden from 0.1 s on, faded out by 0.4 s.
        #expect(evaluate(project, hiding, at: 0.8).cursor?.opacity == 0)
        #expect(try await render(project, hiding, at: 0.8) == render(project, none, at: 0.8))
        // Before then it is drawn.
        #expect(evaluate(project, hiding, at: 0.05).cursor?.opacity == 1)
        #expect(try await render(project, hiding, at: 0.05) != render(project, none, at: 0.05))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func opacityAndThePressAreDrawnAroundTheHotspot() throws {
    let full = CursorLayer(
        hotspot: [100, 80], height: 64, image: .recorded(hash: "00112233445566778899aabbccddeeff"), hotspotFraction: [0.5, 0.5],
        aspect: 0.5)
    func draw(_ layer: CursorLayer) throws -> [UInt8] {
        let frame = RenderFrame(
            outputSize: [200, 160], gradientStart: [0, 0, 0, 1], gradientEnd: [0, 0, 0, 1], gradientAngleDegrees: 0,
            cursor: layer)
        return try composite(frame) { device in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let bytes = [UInt8]((0..<64).flatMap { _ in [0, 0, 255, 255] as [UInt8] })
            texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 32)
            return texture
        }
    }
    // Whole: 32 × 64 around (100, 80).
    let whole = try #require(box(of: red, in: try draw(full), width: 200))
    #expect(whole.x == 84...115 && whole.y == 48...111)
    // Pressed to half: 16 × 32 around the same point.
    var pressed = full
    pressed.clickScale = 0.5
    let half = try #require(box(of: red, in: try draw(pressed), width: 200))
    #expect(half.x == 92...107 && half.y == 64...95)
    // At half opacity, half the red over the black.
    var faded = full
    faded.opacity = 0.5
    #expect(isClose(pixel(try draw(faded), width: 200, x: 100, y: 80), [0, 0, 127.5, 255], tolerance: 1))
    // Hidden, or of no size: nothing.
    var hidden = full
    hidden.opacity = 0
    var flat = full
    flat.clickScale = 0
    var nothing = full
    nothing.height = 0
    let background = try draw(nothing)
    #expect(try draw(hidden) == background && draw(flat) == background)
    #expect(box(of: red, in: background, width: 200) == nil)
}

@Test func thePressAndThePositionComeFromTheCursorPath() throws {
    let take = bareTake()
    let events = [
        InputEvent(t: base, kind: .cursor(x: 100, y: 100)),
        InputEvent(t: base.adding(seconds: 0.4), kind: .cursor(x: 500, y: 300)),
        InputEvent(t: base.adding(seconds: 0.5), kind: .mouseDown(.left, x: 500, y: 300)),
    ]
    var document = EditDocument.legacy(take: take, events: events)
    document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
    let paths = MotionPaths(take: take, events: events, document: document)
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: size, paths: paths)
    // The same frames as an evaluator that builds the paths itself.
    let built = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
    for t in stride(from: 0.0, to: 2, by: 0.05) {
        #expect(evaluator.frame(at: t) == built.frame(at: t), "\(t)")
    }
    for t in [0.2, 0.45, 0.51, 1.5] {
        let frame = evaluator.frame(at: t)
        let rect = try #require(frame.screen).rect
        let sample = try #require(paths.cursor.sample(atOutput: TimeMap.outputNanoseconds(seconds: t)))
        let layer = try #require(frame.cursor)
        let expected = SIMD2(rect.x, rect.y) + (sample.position - SIMD2(screenFrame.x, screenFrame.y))
            / SIMD2(screenFrame.width, screenFrame.height) * SIMD2(rect.width, rect.height)
        #expect(layer.hotspot == expected, "\(t)")
        #expect(layer.clickScale == sample.clickScale && layer.opacity == sample.opacity, "\(t)")
    }
    // Pressed a second ago: shrunk to 0.85.
    #expect(abs(try #require(evaluator.frame(at: 1.5).cursor).clickScale - 0.85) < 1e-3)
    // Without smoothing it never shrinks.
    document.cursor.smoothing = .off
    let off = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
    #expect(off.frame(at: 1.5).cursor?.clickScale == 1)
}

@Test func theScreenShownIsTheStagesRule() {
    let displays: [(String, UInt32, Rect)] = [
        ("display-1", 1, Rect(x: 0, y: 0, width: 640, height: 360)), ("display-2", 2, Rect(x: 640, y: 0, width: 800, height: 600)),
    ]
    let take = makeTake(tracks: displays.map { id, displayID, frame in
        displayTrack(
            id: id, displayID: displayID, globalFrame: frame,
            segments: [segment(track: id, start: base, end: base.adding(seconds: 3))])
    })
    let events = [
        InputEvent(t: base, kind: .cursor(x: 320, y: 180)), InputEvent(t: base.adding(seconds: 1.2), kind: .cursor(x: 900, y: 300)),
    ]
    var document = EditDocument.legacy(take: take, events: events)
    document.screens = ScreenPlan(
        initial: [takeID: "display-1"],
        changes: [
            ScreenChange(id: "p-00000002", take: takeID, t: base.adding(seconds: 2), track: "display-1", origin: .user),
            ScreenChange(id: "p-00000001", take: takeID, t: base.adding(seconds: 1), track: "display-2", origin: .user),
            ScreenChange(id: "p-00000003", take: takeID, t: base.adding(seconds: 2.5), track: "camera", origin: .user),
        ])
    let paths = MotionPaths(take: take, events: events, document: document)
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: size, paths: paths)
    #expect(paths.stage.screenTrackIDs == ["display-1", "display-2"])
    for t in stride(from: 0.0, to: 3, by: 0.1) {
        let frame = evaluator.frame(at: t)
        let source = base.adding(seconds: t)
        #expect(frame.screen?.trackID == paths.stage.shownScreen(at: source)?.track, "\(t)")
        #expect(frame.screen?.crop == paths.stage.shownScreen(at: source)?.view.crop, "\(t)")
    }
    #expect(evaluator.frame(at: 1.5).screen?.trackID == "display-2")
    #expect(evaluator.frame(at: 2.7).screen == nil)
}
