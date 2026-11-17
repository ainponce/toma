// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)` and `forcedPath`, `DrawCounts` and the compositor's counting `encode`.
@testable import Render
import SyntheticCapture
import Testing

// The camera layouts in the render (1c design §5.1 to §5.3, §14.2 and §14.4; plan decision 13): Bubble, Screen only,
// Split, Camera only and Camera full screen, and the transitions between them, drawn in one composition. Over a take
// whose screen is pure blue and whose camera is pure green, on a background of one grey: what a pixel shows says which
// it is.

private let layoutScreen = Rect(x: 0, y: 0, width: 640, height: 360)
/// The background of every document here: one colour, the same under every pixel.
private let backdrop = RGBA(0.25, 0.25, 0.25, 1)
private let size = SIMD2(640, 360)

/// `sample` painted one colour (BGRA as a little-endian word).
private func painting(_ sample: CMSampleBuffer, _ bgra: UInt32) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
            .update(repeating: bgra, count: CVPixelBufferGetWidth(pixelBuffer))
    }
    return sample
}

@Sendable private func paintingBlue(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    painting(sample, 0xFF00_00FF)  // BGRA (255, 0, 0, 255)
}

@Sendable private func paintingGreen(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    painting(sample, 0xFF00_FF00)  // BGRA (0, 255, 0, 255)
}

/// A take of `seconds`: a blue screen, and a camera from `cameraStart` seconds on, green, or `SampleFactory`'s frames
/// (each its own colour) without `green`, whose segment ends for `cameraEnd`.
private func layoutProject(
    in dir: URL, seconds: Double = 4, cameraStart: Double = 0, green: Bool = true, cameraEnd: SegmentEndReason? = .stopped
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: layoutScreen),
        segments: [VideoSegmentSpec(start: base, seconds: seconds, transform: paintingBlue)])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource,
        segments: [VideoSegmentSpec(
            start: base.adding(seconds: cameraStart), seconds: seconds - cameraStart, endReason: cameraEnd,
            transform: green ? paintingGreen : nil)])
    return try builder.write()
}

/// A take of `seconds` with a screen and a camera, without files: for what the evaluator works out.
private func layoutTake(seconds: Double = 10) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: layoutScreen, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: seconds))]),
    ])
}

/// A block of `kind` over source seconds `[from, to)` of the take: a Bubble one with the default style, a split one with
/// the camera second and its automatic part.
private func block(_ number: Int, _ kind: LayoutKind, from: Double, to: Double, instant: Bool = false) -> LayoutBlock {
    LayoutBlock(
        id: "l-0000000\(number)", take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), kind: kind,
        instant: instant, bubble: kind == .bubble ? BubbleLayout(style: CameraStyle(shape: .circle, size: 0.3, anchor: .topLeading)) : nil,
        split: kind == .split ? SplitLayout() : nil)
}

/// The legacy document of `take` on `backdrop`, with `blocks` and `change` made to it.
private func document(
    of take: TakeRecord, _ blocks: [LayoutBlock] = [], _ change: (inout EditDocument) -> Void = { _ in }
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.style.background = .color(backdrop)
    document.camera.layouts = blocks
    change(&document)
    return document
}

/// The evaluator of `document` at `outputSize`, every frame on the path `path` (by the document's layouts when `nil`).
private func evaluator(
    _ take: TakeRecord, _ document: EditDocument, outputSize: SIMD2<Int> = size, path: FrameEvaluator.Path? = nil
) -> FrameEvaluator {
    var evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: outputSize)
    evaluator.forcedPath = path
    return evaluator
}

/// The bytes of `document`'s frames at `times` in an output of `outputSize`, drawn from the take's video, every frame on
/// the path `path` (by the document's layouts when `nil`).
private func render(
    _ project: LoadedProject, _ document: EditDocument, at times: [Double], outputSize: SIMD2<Int> = size,
    path: FrameEvaluator.Path? = nil
) async throws -> [[UInt8]] {
    let renderer = try FrameRenderer(project: project, document: document, outputSize: outputSize)
    var scene = renderer.scene
    scene.forcedPath = path
    renderer.setScene(scene)
    return try await offThePool { try times.map { try renderer.renderBytes(at: $0) } }
}

/// Whether pixel (`x`, `y`) touches `rect` (output pixels).
private func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
    let left = Double(x), top = Double(y)
    return left + 1 > rect.x && left < rect.x + rect.width && top + 1 > rect.y && top < rect.y + rect.height
}

private func isBlue(_ p: SIMD4<UInt8>) -> Bool { p.x > 180 && p.y < 80 && p.z < 80 }
private func isGreen(_ p: SIMD4<UInt8>) -> Bool { p.y > 180 && p.x < 80 && p.z < 80 }
private func isBackdrop(_ p: SIMD4<UInt8>) -> Bool { [p.x, p.y, p.z].allSatisfy { abs(Int($0) - 64) <= 3 } }

/// Every (x, y) of an output of `outputSize`.
private func pixels(_ outputSize: SIMD2<Int>) -> [(x: Int, y: Int)] {
    (0..<outputSize.y).flatMap { y in (0..<outputSize.x).map { (x: $0, y: y) } }
}

/// Whether every number of `a` is within `tolerance` of `b`'s.
private func isClose(_ a: Rect, _ b: Rect, tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

/// Whether `a` is strictly between `from` and `to` in each number that differs between them.
private func isBetween(_ a: Rect, _ from: Rect, _ to: Rect) -> Bool {
    zip([a.x, a.y, a.width, a.height], zip([from.x, from.y, from.width, from.height], [to.x, to.y, to.width, to.height]))
        .allSatisfy { value, ends in ends.0 == ends.1 || (min(ends.0, ends.1) < value && value < max(ends.0, ends.1)) }
}

/// A `.bgra8Unorm` texture of one colour.
private func texture(_ device: any MTLDevice, width: Int, height: Int, bgra: SIMD4<UInt8>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw TestSupportError.missing("texture") }
    let bytes = (0..<width * height).flatMap { _ in [bgra.x, bgra.y, bgra.z, bgra.w] }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// Draws frames with a compositor of its own over a blue screen and a green camera (textures, not video), counting what
/// it draws. It checks nothing itself: it runs off the cooperative pool.
private struct Drawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let camera: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestSupportError.missing("Metal")
        }
        self.device = device
        self.queue = queue
        compositor = try Compositor(device: device)
        screen = try texture(device, width: 64, height: 36, bgra: [255, 0, 0, 255])
        camera = try texture(device, width: 64, height: 36, bgra: [0, 255, 0, 255])
        cursor = try CursorSprite.makeTexture(device: device)
    }

    /// `frame` as BGRA bytes, and what was drawn; without a camera texture with `cameraless`.
    func draw(_ frame: RenderFrame, cameraless: Bool = false) throws -> (bytes: [UInt8], counts: DrawCounts) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw TestSupportError.missing("Metal objects")
        }
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, camera: cameraless ? nil : camera, cursor: cursor, into: target, commandBuffer: commandBuffer,
            counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
        target.getBytes(
            &bytes, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y),
            mipmapLevel: 0)
        return (bytes, counts)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cameraFullSettledShowsOnlyTheCamera() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await layoutProject(in: dir)
        // Everything under it that a frame can draw: the screen's shadow and window frame, and the camera's border and
        // shadow, which Camera full screen weighs at 0.
        let full = document(of: project.take, [block(1, .cameraFull, from: 0, to: 4)]) { document in
            document.style.shadow = 0.6
            document.style.frame = .macWindow(appearance: .light, title: "", buttons: true)
            document.camera.border = CameraBorder(width: 0.8, color: RGBA(1, 0, 0, 1))
            document.camera.shadow = 0.8
        }
        let frame = evaluator(project.take, full).frame(at: 0.5)
        let camera = try #require(frame.camera)
        #expect(camera.rect == Rect(x: 0, y: 0, width: 640, height: 360) && camera.cornerRadius == 0 && camera.opacity == 1)
        #expect(camera.border == nil && camera.shadow == nil)
        #expect(frame.coveredByCamera)
        #expect(frame.screen == nil && frame.windowFrame == nil && frame.shadow == nil && frame.cursor == nil)

        let bytes = try await render(project, full, at: [0.5, 2, 3.9])
        for (index, shown) in bytes.enumerated() {
            var wrong: [String] = []
            for (x, y) in pixels(size) {
                let p = pixel(shown, width: size.x, x: x, y: y)
                if !isGreen(p) || isBlue(p) || isBackdrop(p) { wrong.append("(\(x), \(y)): \(p)") }
            }
            #expect(wrong.isEmpty, "frame \(index): \(wrong.count) pixels, \(wrong.prefix(4))")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cameraFullDrawsNothingBelow() async throws {
    let take = layoutTake()
    let full = document(of: take, [block(1, .cameraFull, from: 0, to: 10)]) { document in
        document.style.shadow = 0.6
        document.style.frame = .macWindow(appearance: .dark, title: "", buttons: true)
    }
    let covered = evaluator(take, full).frame(at: 2)
    #expect(covered.coveredByCamera)
    // The test's flag: the same frame with what is under the camera drawn (the background, the screen being hidden), and
    // with the whole stage of 1b's path under it (the screen, its shadow and its window frame).
    var below = covered
    below.coveredByCamera = false
    var stage = evaluator(take, full, path: .legacy).frame(at: 2)
    #expect(stage.screen != nil && stage.windowFrame != nil && stage.shadow != nil)
    stage.camera = covered.camera

    let drawer = try Drawer()
    let frames = [covered, below, stage]
    let drawn = try await offThePool { try frames.map { try drawer.draw($0) } }
    #expect(drawn[0].counts == DrawCounts(renderPasses: 1, cameras: 1), "\(drawn[0].counts)")
    #expect(drawn[1].counts == DrawCounts(renderPasses: 1, backgrounds: 1, cameras: 1), "\(drawn[1].counts)")
    #expect(drawn[2].counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cameras: 1), "\(drawn[2].counts)")
    #expect(drawn[0].bytes == drawn[1].bytes)
    #expect(drawn[0].bytes == drawn[2].bytes)

    // Without a camera frame to draw, what is under it is drawn: never a black frame.
    let cameraless = try await offThePool { try drawer.draw(covered, cameraless: true) }
    #expect(cameraless.counts == DrawCounts(renderPasses: 1, backgrounds: 1))
    #expect(isBackdrop(pixel(cameraless.bytes, width: size.x, x: 320, y: 180)))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func screenOnlySettledShowsNoCamera() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await layoutProject(in: dir)
        let screenOnly = document(of: project.take) { $0.camera.layout = CameraLayout(kind: .screenOnly) }
        let frame = evaluator(project.take, screenOnly).frame(at: 0.5)
        #expect(frame.camera == nil)
        // The screen where the Bubble layout has it, as 1b does.
        let legacy = evaluator(project.take, document(of: project.take)).frame(at: 0.5)
        let screen = try #require(frame.screen), legacyScreen = try #require(legacy.screen)
        #expect(isClose(screen.rect, legacyScreen.rect) && screen.opacity == 1)
        #expect(legacy.camera != nil)

        let bytes = try await render(project, screenOnly, at: [0.5, 2])
        for shown in bytes {
            let green = pixels(size).filter { isGreen(pixel(shown, width: size.x, x: $0.x, y: $0.y)) }
            let blue = pixels(size).filter { isBlue(pixel(shown, width: size.x, x: $0.x, y: $0.y)) }
            #expect(green.isEmpty, "\(green.count) green pixels: \(green.prefix(4))")
            #expect(blue.count > 100_000, "\(blue.count)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func splitKeepsEachInItsCard() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await layoutProject(in: dir)
        for (name, outputSize) in [("side by side", size), ("one above the other", SIMD2(360, 640))] {
            let split = document(of: project.take) { $0.camera.layout = CameraLayout(kind: .split, split: SplitLayout()) }
            let frame = evaluator(project.take, split, outputSize: outputSize).frame(at: 0.5)
            let output = SIMD2(Double(outputSize.x), Double(outputSize.y))
            let cards = CameraLayoutGeometry.geometry(
                kind: .split, split: SplitLayout(), bubble: nil, output: output, padding: split.style.padding,
                cornerRadius: split.style.cornerRadius, screenAspect: 16.0 / 9)
            let screen = try #require(frame.screen), camera = try #require(frame.camera)
            #expect(isClose(screen.rect, cards.screen.rect, tolerance: 1e-6), "\(name): \(screen.rect), not \(cards.screen.rect)")
            #expect(screen.cornerRadius == cards.screen.cornerRadius && screen.opacity == 1, "\(name)")
            #expect(camera.rect == cards.camera.rect && camera.cornerRadius == cards.camera.cornerRadius, "\(name)")
            #expect(camera.opacity == 1 && camera.sourceTime == screen.sourceTime, "\(name)")

            let shown = try #require(try await render(project, split, at: [0.5], outputSize: outputSize).first)
            var blue = 0, green = 0
            var wrong: [String] = []
            for (x, y) in pixels(outputSize) {
                let p = pixel(shown, width: outputSize.x, x: x, y: y)
                if isBlue(p) {
                    blue += 1
                    if !touches(x, y, screen.rect) { wrong.append("blue (\(x), \(y))") }
                } else if isGreen(p) {
                    green += 1
                    if !touches(x, y, camera.rect) { wrong.append("green (\(x), \(y))") }
                }
            }
            #expect(wrong.isEmpty, "\(name): \(wrong.count), \(wrong.prefix(4))")
            // Each card is full of its own: all its pixels but the antialiased edge.
            let screenArea = (screen.rect.width - 2) * (screen.rect.height - 2)
            let cameraArea = (camera.rect.width - 2) * (camera.rect.height - 2)
            #expect(Double(blue) > screenArea * 0.98 && Double(green) > cameraArea * 0.98, "\(name): \(blue), \(green)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func transitionIsOneComposition() async throws {
    let take = layoutTake()
    // Bubble, then a split from 2 s on: the transition runs from 2 s to 3.5 s.
    let doc = document(of: take, [block(1, .split, from: 2, to: 10)])
    let scene = evaluator(take, doc)
    let bubble = try #require(scene.frame(at: 1.9).camera), bubbleScreen = try #require(scene.frame(at: 1.9).screen)
    let split = try #require(scene.frame(at: 4).camera), splitScreen = try #require(scene.frame(at: 4).screen)
    let drawer = try Drawer()
    for time in [2.05, 2.15, 2.3, 2.5] {
        let frame = scene.frame(at: time)
        // One composition with the numbers blended: the screen and the camera each once, on their way.
        let camera = try #require(frame.camera), screen = try #require(frame.screen)
        #expect(isBetween(camera.rect, bubble.rect, split.rect), "\(time): \(camera.rect)")
        #expect(isBetween(screen.rect, bubbleScreen.rect, splitScreen.rect), "\(time): \(screen.rect)")
        let counts = try await offThePool { try drawer.draw(frame) }.counts
        #expect(counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cameras: 1), "\(time): \(counts)")
    }

    // Bubble, then Camera only from 2 s on: the screen fades out as one group while the camera grows into its card.
    let cameraOnly = evaluator(take, document(of: take, [block(1, .cameraOnly, from: 2, to: 10)]) { $0.style.shadow = 0.5 })
    for time in [2.1, 2.3] {
        let frame = cameraOnly.frame(at: time)
        let screen = try #require(frame.screen), group = try #require(frame.screenOpacity), shadow = try #require(frame.shadow)
        #expect(group > 0 && group < 1 && screen.opacity == group, "\(time): \(group)")
        #expect(shadow.rect == screen.rect && shadow.cornerRadius == screen.cornerRadius, "\(time)")
        #expect(isBetween(try #require(frame.camera).rect, bubble.rect, try #require(cameraOnly.frame(at: 4).camera).rect))
        let counts = try await offThePool { try drawer.draw(frame) }.counts
        #expect(counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cameras: 1), "\(time): \(counts)")
    }
    #expect(cameraOnly.frame(at: 4).screen == nil && cameraOnly.frame(at: 4).screenOpacity == 0)
}

@Test func zoomGoesToRestInTheCards() throws {
    let take = layoutTake()
    // A 2× zoom off the centre over the whole take, and a split from 2 s on.
    let doc = document(of: take, [block(1, .split, from: 2, to: 10)]) { document in
        document.zoom.regions = [ZoomRegion(
            id: "z-00000001", take: takeID, start: base, end: base.adding(seconds: 10), origin: .user, depth: 2,
            focus: .fixed(x: 0.3, y: 0.3), instant: true)]
    }
    let scene = evaluator(take, doc)
    // Over the whole stage in the Bubble, as 1b's path draws it.
    let zoomed = try #require(scene.frame(at: 1.5).stage)
    #expect(zoomed == evaluator(take, doc, path: .legacy).frame(at: 1.5).stage && zoomed.depth == 2)
    // On its way to rest through the transition, and at rest in the split.
    let between = try #require(scene.frame(at: 2.2).stage)
    #expect(between.depth > 1 && between.depth < 2, "\(between.depth)")
    #expect(scene.frame(at: 4).stage == nil)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cameraOnlyBeforeTheFirstCameraFrameShowsIt() async throws {
    try await withTemporaryDirectory { dir in
        // The camera starts 0.5 s into the take, with `SampleFactory`'s frames: frame 0 is its own colour.
        let project = try await layoutProject(in: dir, cameraStart: 0.5, green: false)
        let first = base.adding(seconds: 0.5)
        for kind in [LayoutKind.cameraOnly, .cameraFull] {
            let doc = document(of: project.take, [block(1, kind, from: 0, to: 4)])
            let frame = evaluator(project.take, doc).frame(at: 0.2)
            let camera = try #require(frame.camera, "\(kind)")
            #expect(camera.sourceTime == first && camera.opacity == 1, "\(kind)")
            // Nothing of the screen is drawn, nor decoded.
            #expect(frame.screen == nil && frame.previousScreen == nil && frame.shadow == nil && frame.cursor == nil, "\(kind)")
            let shown = try #require(try await render(project, doc, at: [0.2]).first)
            // Away from the moving white square along the frame's top row.
            let x = Int(camera.rect.x + camera.rect.width / 2), y = Int(camera.rect.y + camera.rect.height * 0.75)
            let centre = pixel(shown, width: size.x, x: x, y: y)
            #expect(SampleFactory.frameIndex(nearestTo: centre) == 0, "\(kind): \(centre)")
        }
        // The Bubble is still not drawn before it: the take's, and a Bubble block's.
        #expect(evaluator(project.take, document(of: project.take)).frame(at: 0.2).camera == nil)
        let bubbleBlock = document(of: project.take, [block(1, .bubble, from: 0, to: 4)])
        #expect(evaluator(project.take, bubbleBlock).frame(at: 0.2).camera == nil)
        #expect(evaluator(project.take, bubbleBlock).frame(at: 0.7).camera?.sourceTime == base.adding(seconds: 0.7))
    }
}

@Test func blockInACutChangesNoFrame() {
    let take = layoutTake()
    // Source 3 s to 5 s cut, and a Camera full screen block from 3.5 s to 4.5 s in it, which no output instant shows.
    let clips = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 3), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 5), end: base.adding(seconds: 10), speed: 1),
    ]
    let hidden = block(9, .cameraFull, from: 3.5, to: 4.5)
    // Without other blocks (1b's path), and with a split after the cut (the layouts' path).
    for others in [[], [block(1, .split, from: 7, to: 9)]] {
        let without = document(of: take, others) { $0.sequence = clips }
        let with = document(of: take, others + [hidden]) { $0.sequence = clips }
        let a = evaluator(take, without), b = evaluator(take, with)
        var differing: [Int] = []
        for n in 0..<Int(a.duration * 30) where a.frame(at: Double(n) / 30) != b.frame(at: Double(n) / 30) { differing.append(n) }
        #expect(differing.isEmpty, "\(others.count) other blocks: frames \(differing.prefix(8))")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func trivialDocumentTakesThe1bPath() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await layoutProject(in: dir)
        // No blocks and the project's layout Bubble, with the rest of the look on: a window frame, a shadow, the camera's.
        let trivial = document(of: project.take) { document in
            document.style.shadow = 0.5
            document.style.frame = .macWindow(appearance: .light, title: "", buttons: true)
            document.camera.mirror = true
            document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1))
            document.camera.shadow = 0.5
            document.camera.sizeReference = .shortSide
        }
        let times = [0.0, 0.5, 2, 3.9]
        let scene = evaluator(project.take, trivial), legacy = evaluator(project.take, trivial, path: .legacy)
        let general = evaluator(project.take, trivial, path: .layouts)
        for time in times {
            #expect(scene.frame(at: time) == legacy.frame(at: time), "\(time)")
            // The layouts' path draws the same picture another way: the test tells them apart.
            #expect(scene.frame(at: time) != general.frame(at: time), "\(time)")
        }
        #expect(try await render(project, trivial, at: times) == render(project, trivial, at: times, path: .legacy))
    }
}

@Test func bubbleIsMeasuredAgainstTheDocumentsReference() throws {
    let take = layoutTake()
    let tall = SIMD2(1080, 1920)
    let region = Rect(x: 0, y: 0, width: 1080, height: 1920)
    // A new project in 9:16, which a split block later makes go through the layouts' path; the take's bubble is
    // measured against the short side, as the render of 1b's path measures it.
    let doc = document(of: take, [block(1, .split, from: 5, to: 8)]) { $0.camera.sizeReference = .shortSide }
    let scene = evaluator(take, doc, outputSize: tall)
    let camera = try #require(scene.frame(at: 1).camera)
    let shortSide = CameraStyle.default.frame(in: region, reference: .shortSide)
    #expect(camera.rect == shortSide.rect && camera.cornerRadius == shortSide.cornerRadius, "\(camera.rect)")
    #expect(camera.rect != CameraStyle.default.frame(in: region, reference: .height).rect)
    #expect(camera == evaluator(take, doc, outputSize: tall, path: .legacy).frame(at: 1).camera)
    // A Bubble block's own style, against the same reference.
    let own = document(of: take, [block(1, .bubble, from: 0, to: 8)]) { $0.camera.sizeReference = .shortSide }
    let ownCamera = try #require(evaluator(take, own, outputSize: tall).frame(at: 1).camera)
    let ownStyle = CameraStyle(shape: .circle, size: 0.3, anchor: .topLeading).frame(in: region, reference: .shortSide)
    #expect(ownCamera.rect == ownStyle.rect && ownCamera.cornerRadius == ownStyle.cornerRadius, "\(ownCamera.rect)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func unreadableCameraShowsTheScreen() async throws {
    try await withTemporaryDirectory { dir in
        // Crash recovery found nothing in the camera's only segment (plan decision 40): Camera only is seen as Screen only.
        let project = try await layoutProject(in: dir, cameraEnd: .empty)
        let doc = document(of: project.take, [block(1, .cameraOnly, from: 0, to: 4)])
        let renderer = try FrameRenderer(project: project, document: doc, outputSize: size)
        let frame = try renderer.frame(of: renderer.scene, at: 1)
        #expect(frame.camera == nil)
        let screen = try #require(frame.screen)
        #expect(screen.opacity == 1)
        #expect(isClose(screen.rect, try #require(evaluator(project.take, document(of: project.take)).frame(at: 1).screen).rect))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func screenGroupFadesAsOne() async throws {
    // A window frame with its bar (and its round top corners over the screen's, as around a recorded window), the screen
    // under it and the shadow under both: at half, the group over the background by half, never a ghost of the shadow or
    // the bar through the screen.
    let window = WindowFrameLayer(
        rect: Rect(x: 100, y: 40, width: 440, height: 280), barHeight: 30, appearance: .light, title: "", buttons: true,
        cornerRadius: 24, bottomCornerRadius: 24, screenTopCornerRadius: 24)
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 100, y: 70, width: 440, height: 250), cornerRadius: 24)
    let shadow = ShadowLayer(rect: window.rect, cornerRadius: 24, opacity: 0.55, sigma: 10, offsetY: 6)
    let background = RenderFrame(
        outputSize: size, gradientStart: SIMD4(0.8, 0.8, 0.8, 1), gradientEnd: SIMD4(0.8, 0.8, 0.8, 1), gradientAngleDegrees: 0)
    func group(_ opacity: Double?) -> RenderFrame {
        var frame = background
        frame.windowFrame = window
        frame.shadow = shadow
        frame.screen = screen
        frame.screen?.opacity = opacity ?? 1
        frame.screenOpacity = opacity
        return frame
    }
    let drawer = try Drawer()
    let frames = [background, group(nil), group(1), group(0.5)]
    let drawn = try await offThePool { try frames.map { try drawer.draw($0) } }
    let (none, legacy, opaque, half) = (drawn[0].bytes, drawn[1].bytes, drawn[2].bytes, drawn[3].bytes)
    func float(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD4<Float> {
        let p = pixel(bytes, width: size.x, x: x, y: y)
        return SIMD4(Float(p.x), Float(p.y), Float(p.z), Float(p.w))
    }
    var wrong: [String] = []
    for (x, y) in pixels(size) {
        // At 1, 1b's picture; at half, the group and the background by half.
        if !isClose(pixel(opaque, width: size.x, x: x, y: y), float(legacy, x, y), tolerance: 1) { wrong.append("opaque (\(x), \(y))") }
        let mixed = (float(opaque, x, y) + float(none, x, y)) / 2
        if !isClose(pixel(half, width: size.x, x: x, y: y), mixed, tolerance: 1) {
            wrong.append("half (\(x), \(y)): \(pixel(half, width: size.x, x: x, y: y)), not \(mixed)")
        }
    }
    #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(4))")
    // The bar, the screen and the shadow are all there.
    #expect(isBlue(pixel(opaque, width: size.x, x: 320, y: 200)) && pixel(opaque, width: size.x, x: 320, y: 50) == [236, 236, 236, 255])
    #expect(pixel(opaque, width: size.x, x: 320, y: 326).x < pixel(none, width: size.x, x: 320, y: 326).x)
}
