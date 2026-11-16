// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Testing

// The zoom camera over the stage (design §7.4): the whole stage drawn through its transform, at the output's size.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(1280, 720)

/// What the zoom and blur tests share: frames drawn by a compositor of the default device over textures made here.
enum StageDrawing {
    /// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
    /// opens its files, which blocks (`offThePool` in DocumentRenderTests).
    static func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result(catching: body)) }.start()
        }
    }

    /// A `.bgra8Unorm` texture of `width` × `height` that changes smoothly everywhere: red from left to right, green
    /// from top to bottom, and blue the other way round, opaque. Where it is drawn shows by its colour.
    static func screenTexture(device: any MTLDevice, width: Int = 640, height: Int = 360) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let red = UInt8(255 * x / max(width - 1, 1)), green = UInt8(255 * y / max(height - 1, 1))
                (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (255 - red / 2 - green / 2, green, red, 255)
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// A `.bgra8Unorm` target of `size` that the CPU can read.
    static func target(device: any MTLDevice, size: SIMD2<Int>) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// The bytes of `target`, without row padding.
    static func bytes(of target: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return bytes
    }

    /// A compositor of the default device, with Toma's arrow and the screen texture drawn into `frame`.
    final class Drawer {
        let device: any MTLDevice
        let compositor: Compositor
        let queue: any MTLCommandQueue
        let screen: any MTLTexture
        let cursor: any MTLTexture

        init() throws {
            device = try #require(MTLCreateSystemDefaultDevice())
            compositor = try Compositor(device: device)
            queue = try #require(device.makeCommandQueue())
            screen = try StageDrawing.screenTexture(device: device)
            cursor = try CursorSprite.makeTexture(device: device)
        }

        /// `frame` drawn into a new target of its output size (or `targetSize`), as BGRA bytes, with what was drawn
        /// counted in `counts`.
        func draw(_ frame: RenderFrame, targetSize: SIMD2<Int>? = nil, counts: inout DrawCounts) throws -> [UInt8] {
            let target = try StageDrawing.target(device: device, size: targetSize ?? frame.outputSize)
            let commandBuffer = try #require(queue.makeCommandBuffer())
            try compositor.encode(
                frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer, counts: &counts)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            return StageDrawing.bytes(of: target)
        }

        func draw(_ frame: RenderFrame, targetSize: SIMD2<Int>? = nil) throws -> [UInt8] {
            var counts = DrawCounts()
            return try draw(frame, targetSize: targetSize, counts: &counts)
        }
    }

    /// The largest difference between two images of the same size, in any channel.
    static func largestDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    static func event(_ seconds: Double, _ kind: InputEvent.Kind) -> InputEvent {
        InputEvent(t: base.adding(seconds: seconds), kind: kind)
    }

    /// A zoom block of the take from `from` to `to` seconds of it.
    static func zoom(
        _ number: Int, from: Double, to: Double, depth: Double, focus: ZoomFocus = .fixed(x: 0.5, y: 0.5), instant: Bool = false
    ) -> ZoomRegion {
        ZoomRegion(
            id: String(format: "z-%08x", number), take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to),
            origin: .user, depth: depth, focus: focus, instant: instant)
    }

    /// A take of `seconds` on display 1 (`globalFrame`), without files.
    static func bareTake(seconds: Double = 3, globalFrame: Rect = Rect(x: 0, y: 0, width: 640, height: 360)) -> TakeRecord {
        makeTake(tracks: [
            displayTrack(globalFrame: globalFrame, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
        ])
    }
}

@Test func stageTransformIsTheDesignsFormula() {
    let transform = StageTransform(depth: 2, center: [640, 360])
    // The output's corner shows the stage point (W/4, H/4), its centre the centre.
    #expect(transform.outputPoint(ofStage: [320, 180], outputSize: size) == [0, 0])
    #expect(transform.outputPoint(ofStage: [960, 540], outputSize: size) == [1280, 720])
    #expect(StageTransform.identity(outputSize: size) == StageTransform(depth: 1, center: [640, 360]))
    #expect(StageTransform.identity(outputSize: size).outputPoint(ofStage: [123, 45], outputSize: size) == [123, 45])
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func depthOneIsNoZoom() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 2)])
        try builder.addEvents(cursorEvents(from: base, seconds: 2, across: screenFrame))
        let project = try builder.write()
        let plain = EditDocument.legacy(for: project)
        let none = try FrameRenderer(project: project, document: plain, outputSize: size)
        // A block of depth 1 over the whole take, fixed and following, with and without the camera's blur.
        for (focus, blur) in [(ZoomFocus.fixed(x: 0.2, y: 0.8), 0.0), (.follow, 1.0)] {
            var document = plain
            document.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 2, depth: 1, focus: focus)]
            document.zoom.motionBlur = blur
            let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            #expect([0.0, 0.5, 1.25, 1.9].allSatisfy {
                let frame = evaluator.frame(at: $0)
                return frame.stage == nil && frame.subframes.isEmpty
            })
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            for t in [0.0, 0.5, 1.25, 1.9] {
                let zoomed = try await StageDrawing.offThePool { try renderer.renderBytes(at: t) }
                let unzoomed = try await StageDrawing.offThePool { try none.renderBytes(at: t) }
                #expect(zoomed == unzoomed, "\(focus) at \(t)")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func zoomTransformsTheWholeStage() throws {
    let take = StageDrawing.bareTake()
    let events: [InputEvent] = []
    var document = EditDocument.legacy(take: take, events: events)
    // 2× fixed at the centre, there from the start.
    document.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 2, instant: true)]
    let frame = FrameEvaluator(take: take, events: events, document: document, outputSize: size).frame(at: 1)
    let stage = try #require(frame.stage)
    #expect(stage.depth == 2)
    #expect(abs(stage.center.x - 640) < 1e-6 && abs(stage.center.y - 360) < 1e-6, "\(stage)")
    let corner = stage.outputPoint(ofStage: [320, 180], outputSize: size)
    #expect(abs(corner.x) < 1e-6 && abs(corner.y) < 1e-6)
    // The whole stage is drawn through it, the background and the screen: the output's corners show the stage's points
    // (W/4, H/4) and (3W/4, 3H/4), its centre the stage's centre.
    let drawer = try StageDrawing.Drawer()
    var unzoomedFrame = frame
    unzoomedFrame.stage = nil
    let zoomed = try drawer.draw(frame), unzoomed = try drawer.draw(unzoomedFrame)
    for (out, at) in [((0, 0), (320, 180)), ((1279, 719), (959, 539)), ((640, 360), (640, 360)), ((100, 600), (370, 480))] {
        let a = pixel(zoomed, width: size.x, x: out.0, y: out.1), b = pixel(unzoomed, width: size.x, x: at.0, y: at.1)
        #expect(isClose(a, SIMD4<Float>(b), tolerance: 3), "output \(out): \(a), stage \(at): \(b)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func theCursorAndTheEffectsGrowWithTheStage() throws {
    let black = SIMD4<Float>(0, 0, 0, 1)
    let cursor = CursorLayer(hotspot: [700, 380], height: 40)
    let ripple = ClickEffectLayer(kind: .ripple, center: [600, 300], radius: 30, thickness: 6, opacity: 1)
    let stage = StageTransform(depth: 2, center: [640, 360])
    let drawer = try StageDrawing.Drawer()
    // The cursor through the stage is the cursor of twice the height at the transformed hotspot.
    let zoomedCursor = RenderFrame(
        outputSize: size, gradientStart: black, gradientEnd: black, gradientAngleDegrees: 0, cursor: cursor, stage: stage)
    let scaledCursor = RenderFrame(
        outputSize: size, gradientStart: black, gradientEnd: black, gradientAngleDegrees: 0,
        cursor: CursorLayer(hotspot: stage.outputPoint(ofStage: cursor.hotspot, outputSize: size), height: 80))
    #expect(try drawer.draw(zoomedCursor) == drawer.draw(scaledCursor))
    // The ring through the stage: twice as far out and twice as thick, about the transformed click.
    let zoomedRipple = RenderFrame(
        outputSize: size, gradientStart: black, gradientEnd: black, gradientAngleDegrees: 0, clickEffects: [ripple], stage: stage)
    let bytes = try drawer.draw(zoomedRipple)
    let center = stage.outputPoint(ofStage: ripple.center, outputSize: size)
    let y = Int(center.y)
    // White across 12 px about 60 px out, hollow inside, black beyond.
    for dx in [-65, -55, 55, 65] {
        #expect(pixel(bytes, width: size.x, x: Int(center.x) + dx, y: y) == [255, 255, 255, 255], "\(dx)")
    }
    #expect(pixel(bytes, width: size.x, x: Int(center.x), y: y) == [0, 0, 0, 255])
    #expect(pixel(bytes, width: size.x, x: Int(center.x) + 75, y: y) == [0, 0, 0, 255])
}

@Test func aDeepZoomNeverShowsTheBackgroundBesideTheWindow() throws {
    // A square window with the macOS frame in a 1280 × 720 output: its bar is at its 18 px floor here, not in
    // `StagePoints`' 1080 px reference, so the stage units place the window a few pixels off this output's.
    let window = "window-1"
    let take = makeTake(tracks: [
        displayTrack(
            id: window, kind: .window, globalFrame: Rect(x: 100, y: 100, width: 600, height: 600),
            segments: [segment(track: window, start: base, end: base.adding(seconds: 3))]),
    ])
    let events = [StageDrawing.event(0, .cursor(x: 400, y: 500))]
    /// The axes on which the crop of `depth` about `center` shows background beside `rect`, by more than `slack` px:
    /// leaves it where the crop fits in it, or does not cover it where it does not (design §7.4).
    func background(center: SIMD2<Double>, depth: Double, beside rect: Rect, slack: Double) -> [Int] {
        let half = SIMD2<Double>(size) / depth / 2
        return (0..<2).filter { axis in
            let low = axis == 0 ? rect.x : rect.y, high = low + (axis == 0 ? rect.width : rect.height)
            let fits = 2 * half[axis] <= high - low
            let start = center[axis] - half[axis], end = center[axis] + half[axis]
            return fits ? start < low - slack || end > high + slack : start > low + slack || end < high - slack
        }
    }
    var unplacedViolations = 0
    for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
        var document = EditDocument.legacy(take: take, events: events)
        document.style.frame = .macWindow(appearance: .light, title: "", buttons: true)
        document.style.padding = 0.12
        document.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 4, focus: .fixed(x: x, y: y), instant: true)]
        let paths = MotionPaths(take: take, events: events, document: document)
        let frame = FrameEvaluator(take: take, events: events, document: document, outputSize: size, paths: paths).frame(at: 1)
        let rect = try #require(frame.windowFrame?.rect)
        let stage = try #require(frame.stage)
        #expect(stage.depth == 4)
        #expect(background(center: stage.center, depth: stage.depth, beside: rect, slack: 1e-9).isEmpty, "(\(x), \(y)): \(stage)")
        // Without placing it again at this size, the path's centre would show some, beside some corner.
        let state = paths.zoom.state(atOutput: 1_000_000_000)
        let unplaced = state.center / paths.stage.stageSize * SIMD2<Double>(size)
        unplacedViolations += background(center: unplaced, depth: state.depth, beside: rect, slack: 0.25).count
    }
    #expect(unplacedViolations > 0)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aWallpaperIsPlacedOnATargetOfAnotherSize() throws {
    // The frame's positions are in pixels of its output size and map onto the whole target: so does its wallpaper.
    let preset = try #require(WallpaperPreset.all.first)
    let small = SIMD2(320, 180)
    let frame = RenderFrame(
        outputSize: small, gradientStart: .zero, gradientEnd: .zero, gradientAngleDegrees: 0, background: .wallpaper(preset))
    let drawer = try StageDrawing.Drawer()
    let alone = try drawer.draw(frame)
    let twice = try drawer.draw(frame, targetSize: small &* 2)
    var zoomedFrame = frame
    zoomedFrame.stage = StageTransform(depth: 2, center: [80, 45])
    let zoomed = try drawer.draw(zoomedFrame, targetSize: small &* 2)
    // At each pixel of the small one, the big one's 2 × 2 pixels average to the same colour (the grain, of the target's
    // pixels, averages out); zoomed in on the top-left quarter, the big one's pixel at twice a position shows the small
    // one's at half of it.
    var worst = 0, worstZoomed = 0
    for y in stride(from: 4, to: small.y - 4, by: 7) {
        for x in stride(from: 4, to: small.x - 4, by: 7) {
            let expected = SIMD4<Int>(truncatingIfNeeded: pixel(alone, width: small.x, x: x, y: y))
            var sum = SIMD4<Int>.zero
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                sum &+= SIMD4<Int>(truncatingIfNeeded: pixel(twice, width: small.x * 2, x: 2 * x + dx, y: 2 * y + dy))
            }
            let average = sum / 4
            worst = max(worst, (average &- expected).max(), (expected &- average).max())
            let quarter = SIMD4<Int>(truncatingIfNeeded: pixel(alone, width: small.x, x: x / 2, y: y / 2))
            let shown = SIMD4<Int>(truncatingIfNeeded: pixel(zoomed, width: small.x * 2, x: 2 * x, y: 2 * y))
            worstZoomed = max(worstZoomed, (shown &- quarter).max(), (quarter &- shown).max())
        }
    }
    #expect(worst <= 8, "\(worst)")
    #expect(worstZoomed <= 12, "\(worstZoomed)")
}

/// A bare take's legacy document in the macOS frame with a title, zoomed in on its centre by `regions`.
private func titledDocument(_ take: TakeRecord, regions: [ZoomRegion]) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.style.frame = .macWindow(appearance: .light, title: "Toma — a title long enough to read", buttons: true)
    document.zoom.regions = regions
    return document
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func theTitleIsDrawnAgainAtTheZoomedSize() throws {
    let take = StageDrawing.bareTake()
    // At the window's top, where the bar is.
    let document = titledDocument(
        take, regions: [StageDrawing.zoom(1, from: 1, to: 3, depth: 2, focus: .fixed(x: 0.5, y: 0), instant: true)])
    let evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: size)
    let rest = evaluator.frame(at: 0.5), zoomed = evaluator.frame(at: 2)
    let window = try #require(rest.windowFrame)
    #expect(zoomed.windowFrame == window && zoomed.stage?.depth == 2)
    #expect(TitleTexture.scale(for: rest) == 1 && TitleTexture.scale(for: zoomed) == 2)
    let titles = TitleTexture(device: try #require(MTLCreateSystemDefaultDevice()))
    // At rest, one texel per pixel of the bar.
    let atRest = try #require(try titles.texture(for: window, scale: 1))
    #expect(SIMD2(atRest.width, atRest.height) == window.barPixels.size)
    // At depth 2, at least as many texels as the bar is drawn pixels across and down.
    let sharp = try #require(try titles.texture(for: window, scale: TitleTexture.scale(for: zoomed)))
    #expect(Double(sharp.width) >= window.rect.width * 2 && Double(sharp.height) >= window.barHeight * 2, "\(sharp.width)×\(sharp.height)")
    // Both are kept: the one at rest again draws nothing.
    #expect(titles.drawCount == 2)
    #expect(try titles.texture(for: window, scale: 1) === atRest && titles.drawCount == 2)
    // Drawn through the stage, the title is on the zoomed bar: what it changes is inside the bar as drawn.
    let drawer = try StageDrawing.Drawer()
    func draw(title: (any MTLTexture)?) throws -> [UInt8] {
        let target = try StageDrawing.target(device: drawer.device, size: size)
        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
        try drawer.compositor.encode(
            zoomed, screen: drawer.screen, camera: nil, cursor: drawer.cursor, windowTitle: title, into: target,
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return StageDrawing.bytes(of: target)
    }
    let with = try draw(title: sharp), without = try draw(title: nil)
    let bar = try #require(zoomed.stage).outputRect(
        ofStage: Rect(x: window.rect.x, y: window.rect.y, width: window.rect.width, height: window.barHeight), outputSize: size)
    var changed = 0, outside = 0
    for y in 0..<size.y {
        for x in 0..<size.x where pixel(with, width: size.x, x: x, y: y) != pixel(without, width: size.x, x: x, y: y) {
            changed += 1
            let inside = Double(x) >= bar.x - 1 && Double(x) < bar.x + bar.width + 1 && Double(y) >= bar.y - 1
                && Double(y) < bar.y + bar.height + 1
            if !inside { outside += 1 }
        }
    }
    #expect(changed > 100 && outside == 0, "\(changed) changed, \(outside) outside the bar")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aMovingZoomDrawsTheTitleAFewTimes() throws {
    let take = StageDrawing.bareTake(seconds: 4)
    // A zoom to depth 3 with the spring, blurred: every frame of the way in, at 60 fps.
    var document = titledDocument(take, regions: [StageDrawing.zoom(1, from: 0.5, to: 4, depth: 3)])
    document.zoom.motionBlur = 1
    let evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: size)
    let titles = TitleTexture(device: try #require(MTLCreateSystemDefaultDevice()))
    var scales: Set<Double> = []
    for n in 0..<180 {
        let frame = evaluator.frame(at: Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9)
        let window = try #require(frame.windowFrame)
        let scale = TitleTexture.scale(for: frame)
        scales.insert(scale)
        let texture = try #require(try titles.texture(for: window, scale: scale))
        // Never fewer texels than the deepest subsample draws the bar.
        let depth = frame.subframes.map(\.stage.depth).reduce(frame.stage?.depth ?? 1, max)
        #expect(Double(texture.width) >= window.rect.width * depth, "frame \(n)")
    }
    // ⌈log√2 3⌉ + 1 = 5 at most: 1, √2, 2, 2√2 and 4.
    #expect(titles.drawCount <= Int((2 * log2(3.0)).rounded(.up)) + 1 && titles.drawCount == scales.count, "\(scales.sorted())")
    #expect(scales.count > 2)
}
