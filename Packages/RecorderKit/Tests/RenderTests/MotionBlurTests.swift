// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Testing

// The motion blur of the zoom camera and of the cursor (design §7.2, §7.4 and §7.5): subsamples at output times,
// averaged in one render pass, with the click effects drawn once after them.

private let size = SIMD2(1280, 720)
private let frame60 = TimeMap.frameTime(1, frameRate: 60)

private func at(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// A cursor moving fast across display 1 (640 × 360 pt) for `seconds`: 1440 pt per second along x, back and forth.
private func fastCursor(seconds: Double = 3) -> [InputEvent] {
    (0..<Int(seconds * 120)).map { i in
        let phase = Double(i % 40) / 40
        let x = 20 + 600 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
        return StageDrawing.event(Double(i) / 120, .cursor(x: x, y: 180 + 100 * sin(Double(i) / 30)))
    }
}

/// The legacy document of `take` with the camera's shutter `zoomBlur` and the cursor's `cursorBlur`, and `regions`.
private func document(
    _ take: TakeRecord, _ events: [InputEvent], regions: [ZoomRegion], zoomBlur: Double = 1, cursorBlur: Double = 0
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.zoom.regions = regions
    document.zoom.motionBlur = zoomBlur
    document.cursor.motionBlur = cursorBlur
    return document
}

/// A block from 0.5 s to 2.5 s, 2.5 deep, at the top-left of the screen: the camera moves fast as it enters it.
private let movingZoom = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 2.5, focus: .fixed(x: 0.25, y: 0.3))]

@Test func sampleCountRule() {
    #expect(MotionBlurPlan.sampleCount(travelPixels: 0) == 1)
    #expect(MotionBlurPlan.sampleCount(travelPixels: 1.5) == 1)
    #expect(MotionBlurPlan.sampleCount(travelPixels: 1.6) == 2)
    #expect(MotionBlurPlan.sampleCount(travelPixels: 3.1) == 3)
    #expect(MotionBlurPlan.sampleCount(travelPixels: 100) == 16)
    #expect(MotionBlurPlan.sampleCount(travelPixels: .infinity) == 16)
    #expect(MotionBlurPlan.sampleCount(travelPixels: .nan) == 1)
    #expect(MotionBlurPlan.sampleCount(travelPixels: -4) == 1)
}

@Test func shutterZeroIsOff() {
    let t: Int64 = 1_000_000_000
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0, frameDuration: frame60, count: 16) == [t])
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: .nan, frameDuration: frame60, count: 16) == [t])
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 1) == [t])
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: 0, count: 4) == [t])
    // Half a frame of 1/60 s in three: its ends and `t`.
    #expect(MotionBlurPlan.sampleTimes(at: t, shutter: 0.5, frameDuration: frame60, count: 3) == [t - 4_166_667, t, t + 4_166_667])
    // A whole frame in five, read up to 1.
    let five = MotionBlurPlan.sampleTimes(at: t, shutter: 3, frameDuration: frame60, count: 5)
    #expect(five == [t - 8_333_334, t - 4_166_667, t, t + 4_166_667, t + 8_333_334], "\(five)")
}

@Test func spansGiveThePathsBits() {
    let take = StageDrawing.bareTake()
    var events = fastCursor()
    events.append(StageDrawing.event(1.2, .mouseDown(.left, x: 300, y: 200)))
    events.append(StageDrawing.event(1.3, .mouseUp(.left, x: 300, y: 200)))
    events.sort { $0.t < $1.t }
    var smooth = document(take, events, regions: [
        StageDrawing.zoom(1, from: 0.4, to: 1.4, depth: 2, focus: .follow),
        StageDrawing.zoom(2, from: 1.6, to: 2.6, depth: 3, focus: .fixed(x: 0.8, y: 0.2)),
    ])
    for smoothing in [CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.16)), .off] {
        smooth.cursor.smoothing = smoothing
        let paths = MotionPaths(take: take, events: events, document: smooth)
        for centre in [0.0, 0.31, 0.5 + 1 / 60, 0.999, 1.2, 1.61, 2.95, 3.0] {
            let t = at(centre), h = frame60 / 2
            let zoom = paths.zoom.span(from: t - h, through: t + h), cursor = paths.cursor.span(from: t - h, through: t + h)
            // On and off the grid, inside the span; and out of it, which is worked out on its own.
            for τ in stride(from: t - h, through: t + h, by: 371_113) + [t, t - h - 50_000_000, t + 90_000_000, -5, at(5)] {
                #expect(zoom.state(atOutput: τ) == paths.zoom.state(atOutput: τ), "zoom at \(τ)")
                #expect(cursor.sample(atOutput: τ) == paths.cursor.sample(atOutput: τ), "\(smoothing) at \(τ)")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func oneSampleIsNoBlur() async throws {
    let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 2)])
        try builder.addEvents([StageDrawing.event(0, .cursor(x: 300, y: 200))])
        let project = try builder.write()
        // The camera still inside a block (cut in): with a shutter of half a frame it moves under 1.5 px, so one sample.
        var still = EditDocument.legacy(for: project)
        still.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 2, depth: 2, focus: .fixed(x: 0.3, y: 0.6), instant: true)]
        var blurred = still
        blurred.zoom.motionBlur = 0.5
        let evaluator = FrameEvaluator(take: project.take, events: project.events, document: blurred, outputSize: size)
        #expect([0.1, 1.0, 1.9].allSatisfy {
            let frame = evaluator.frame(at: $0)
            return frame.stage?.depth == 2 && frame.subframes.isEmpty && frame.cursorSamples.isEmpty
        })
        let sharp = try FrameRenderer(project: project, document: still, outputSize: size)
        let blur = try FrameRenderer(project: project, document: blurred, outputSize: size)
        for t in [0.1, 1.0, 1.9] {
            let a = try await offThePool { try sharp.renderBytes(at: t) }
            let b = try await offThePool { try blur.renderBytes(at: t) }
            #expect(a == b, "at \(t)")
        }
    }
}

@Test func blurSamplesNeverReadTheCut() throws {
    let take = StageDrawing.bareTake()
    // The source from 1 s to 2 s is cut; the camera enters a block at 0.85 s of the source and is still moving at the
    // cut, on both sides of it.
    var cut = document(take, [], regions: [StageDrawing.zoom(1, from: 0.85, to: 2.9, depth: 3, focus: .fixed(x: 0.2, y: 0.2))])
    cut.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
    ]
    let paths = MotionPaths(take: take, events: [], document: cut)
    let evaluator = FrameEvaluator(take: take, events: [], document: cut, outputSize: size, paths: paths, frameRate: 60)
    var straddled = false, naiveInTheCut = false
    for n in 57...63 {
        let t = TimeMap.frameTime(n, frameRate: 60)
        let frame = evaluator.frame(at: Double(t) / 1e9)
        #expect(frame.subframes.count > 1, "frame \(n)")
        let times = MotionBlurPlan.sampleTimes(at: t, shutter: 1, frameDuration: frame60, count: frame.subframes.count)
        for (j, τ) in times.enumerated() {
            // Every subsample is the camera at an output time, whose source is kept.
            #expect(frame.subframes[j].stage.depth == paths.zoom.state(atOutput: τ).depth, "frame \(n), sample \(j)")
            let shown = try #require(paths.timeMap.source(atOutput: τ))
            let clip = cut.sequence[shown.clip]
            #expect(shown.source >= clip.start && shown.source < clip.end, "frame \(n), sample \(j)")
            if τ < at(1) && times.contains(where: { $0 >= at(1) }) { straddled = true }
            // Moving the source time of `t` by the same amount would read the cut.
            let source = try #require(paths.timeMap.source(atOutput: t)).source
            let naive = source.adding(seconds: Double(τ - t) / 1e9)
            if naive >= base.adding(seconds: 1) && naive < base.adding(seconds: 2) { naiveInTheCut = true }
        }
        #expect(Set(frame.subframes.map(\.stage.depth)).count == frame.subframes.count, "frame \(n): the camera moves")
    }
    #expect(straddled && naiveInTheCut)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func stillCameraDrawsTheStageOnce() throws {
    let take = StageDrawing.bareTake()
    let events = fastCursor()
    // The camera still at 2× from the start, both shutters a whole frame, the cursor fast.
    let doc = document(
        take, events, regions: [StageDrawing.zoom(1, from: 0, to: 3, depth: 2, focus: .fixed(x: 0.5, y: 0.5), instant: true)],
        cursorBlur: 1)
    let frame = FrameEvaluator(take: take, events: events, document: doc, outputSize: size).frame(at: 1.1)
    #expect(frame.subframes.isEmpty)
    #expect(frame.stage?.depth == 2)
    let samples = frame.cursorSamples.count
    #expect(samples == 16, "\(samples)")
    #expect(Set(frame.cursorSamples.map(\.hotspot)).count == samples)
    let drawer = try StageDrawing.Drawer()
    var counts = DrawCounts()
    let blurred = try drawer.draw(frame, counts: &counts)
    #expect(counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cursors: samples, clickEffects: 0, accumulations: 0))
    // The same cursor every time: the frame drawn without its samples, within one level.
    var same = frame
    same.cursorSamples = Array(repeating: try #require(frame.cursor), count: samples)
    var direct = frame
    direct.cursorSamples = []
    #expect(StageDrawing.largestDifference(try drawer.draw(same), try drawer.draw(direct)) <= 1)
    #expect(blurred != (try drawer.draw(direct)))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func effectsAreDrawnOnceWithTheStageAtT() throws {
    let take = StageDrawing.bareTake()
    let events = [
        StageDrawing.event(0, .cursor(x: 200, y: 120)),
        StageDrawing.event(0.6, .mouseDown(.left, x: 200, y: 120)), StageDrawing.event(0.65, .mouseUp(.left, x: 200, y: 120)),
    ]
    var doc = document(take, events, regions: movingZoom)
    doc.cursor.clickEffect = "ripple-1"
    let frame = FrameEvaluator(take: take, events: events, document: doc, outputSize: size).frame(at: 0.7)
    #expect(frame.subframes.count == 16)
    #expect(frame.clickEffects.count == 1)
    let drawer = try StageDrawing.Drawer()
    var counts = DrawCounts()
    let whole = try drawer.draw(frame, counts: &counts)
    #expect(counts.clickEffects == 1 && counts.accumulations == 16 && counts.renderPasses == 1, "\(counts)")
    // Its pixels: the frame resolved without it, then the effect alone drawn over that through the stage at `t`.
    var withoutEffects = frame
    withoutEffects.clickEffects = []
    let target = try StageDrawing.target(device: drawer.device, size: size)
    let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
    var ignored = DrawCounts()
    try drawer.compositor.encode(
        withoutEffects, screen: drawer.screen, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer,
        counts: &ignored)
    drawer.compositor.encodeClickEffects(of: frame, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    #expect(StageDrawing.bytes(of: target) == whole)
    #expect(try drawer.draw(withoutEffects) != whole)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func subsamplesAccumulateInOnePass() throws {
    let take = StageDrawing.bareTake()
    let events = fastCursor()
    let frame = FrameEvaluator(
        take: take, events: events, document: document(take, events, regions: movingZoom, cursorBlur: 1), outputSize: size
    ).frame(at: 0.7)
    #expect(frame.subframes.count == 16)
    // Each subframe with its own camera and cursor.
    #expect(Set(frame.subframes.map(\.stage.center)).count == 16)
    #expect(Set(frame.subframes.compactMap(\.cursor?.hotspot)).count == 16)
    let drawer = try StageDrawing.Drawer()
    var counts = DrawCounts()
    let blurred = try drawer.draw(frame, counts: &counts)
    #expect(counts == DrawCounts(renderPasses: 1, backgrounds: 16, screens: 16, cursors: 16, clickEffects: 0, accumulations: 16))
    // Twice, the same bytes.
    #expect(try drawer.draw(frame) == blurred)
    // 16 equal subsamples: the frame drawn once through that stage, within one level.
    var equal = frame
    equal.subframes = Array(repeating: StageSubframe(stage: try #require(frame.stage), cursor: frame.cursor), count: 16)
    var once = frame
    once.subframes = []
    let direct = try drawer.draw(once)
    #expect(StageDrawing.largestDifference(try drawer.draw(equal), direct) <= 1)
    #expect(StageDrawing.largestDifference(blurred, direct) > 1)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func whatTheScreenHidesIsNotDrawnAndNothingShows() throws {
    // A recorded window in the macOS frame, its screen's top corners round over the bar, with a shadow, over the
    // wallpaper: the subsamples draw neither under the window's opaque inside, which gives the same pixels.
    let window = "window-1"
    let take = makeTake(tracks: [
        displayTrack(
            id: window, kind: .window, globalFrame: Rect(x: 100, y: 100, width: 800, height: 500),
            segments: [segment(track: window, start: base, end: base.adding(seconds: 3))]),
    ])
    var doc = document(take, [], regions: movingZoom)
    doc.style.background = .wallpaper("aurora-1")
    doc.style.shadow = 1
    doc.style.cornerRadius = 0.03
    doc.style.frame = .macWindow(appearance: .dark, title: "", buttons: true)
    let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: size)
    let drawer = try StageDrawing.Drawer()
    for t in [0.52, 0.7, 2] {
        let frame = evaluator.frame(at: t)
        #expect(try #require(frame.windowFrame).screenTopCornerRadius > 0)
        // The camera at rest, entering, and in.
        for stage in [StageTransform.identity(outputSize: size), frame.stage ?? .identity(outputSize: size)] {
            var equal = frame
            equal.subframes = Array(repeating: StageSubframe(stage: stage, cursor: nil), count: 16)
            var direct = equal
            direct.subframes = []
            direct.stage = stage
            let a = try drawer.draw(equal), b = try drawer.draw(direct)
            #expect(StageDrawing.largestDifference(a, b) <= 1, "at \(t), \(stage)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aSharpWallpaperUnderTheBlurIsReadFromItsMesh() throws {
    let take = StageDrawing.bareTake()
    var doc = document(take, [], regions: movingZoom)
    doc.style.background = .wallpaper("aurora-1")
    let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: size)
    let moving = evaluator.frame(at: 0.7), still = evaluator.frame(at: 0.2)
    #expect(moving.subframes.count == 16 && still.subframes.isEmpty)
    let drawer = try StageDrawing.Drawer()
    try withTemporaryDirectory { dir in
        let images = try BackgroundImages(
            device: drawer.device, library: drawer.compositor.library, package: ProjectPackage(url: dir.appendingPathComponent("A.toma")))
        // Only the subsamples read the mesh, drawn once for the size.
        let mesh = try #require(try FrameRenderer.backgroundTexture(of: moving, images: images, outputSize: size))
        #expect(SIMD2(mesh.width, mesh.height) == size)
        #expect(try FrameRenderer.backgroundTexture(of: evaluator.frame(at: 0.75), images: images, outputSize: size) === mesh)
        #expect(try FrameRenderer.backgroundTexture(of: still, images: images, outputSize: size) == nil)
        // Through it, 16 equal subsamples of the stage are those of the shader's wallpaper, drawn directly, within 2 levels.
        var equal = moving
        equal.subframes = Array(repeating: StageSubframe(stage: try #require(moving.stage), cursor: nil), count: 16)
        equal.cursor = nil
        var direct = equal
        direct.subframes = []
        let target = try StageDrawing.target(device: drawer.device, size: size)
        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
        try drawer.compositor.encode(
            equal, screen: drawer.screen, camera: nil, cursor: drawer.cursor, backgroundImage: mesh, into: target,
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(StageDrawing.largestDifference(StageDrawing.bytes(of: target), try drawer.draw(direct)) <= 2)
    }
}

/// The GPU time of each of `frames` drawn at `output` one after the other after eight to warm up, with a 4K screen, Toma's
/// arrow, and the window's title and the background's texture as `FrameRenderer` gives them: the median, the 95th
/// percentile and the largest, in seconds, and whether every frame completed.
private func gpuTimes(
    of frames: [RenderFrame], output: SIMD2<Int>
) async throws -> (p50: Double, p95: Double, max: Double, count: Int, completed: Bool) {
    try await withTemporaryDirectory { dir in try await offThePool {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compositor = try Compositor(device: device)
        let images = try BackgroundImages(
            device: device, library: compositor.library, package: ProjectPackage(url: dir.appendingPathComponent("Bench.toma")))
        let queue = try #require(device.makeCommandQueue())
        let screen = try StageDrawing.screenTexture(device: device, width: 3840, height: 2160)
        let cursor = try CursorSprite.makeTexture(device: device)
        let titles = TitleTexture(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: output.x, height: output.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        var times: [Double] = [], completed = true
        for (index, frame) in frames.enumerated() {
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let background = try FrameRenderer.backgroundTexture(of: frame, images: images, outputSize: output)
            let title = try frame.windowFrame.flatMap { try titles.texture(for: $0, scale: TitleTexture.scale(for: frame)) }
            try compositor.encode(
                frame, screen: screen, camera: nil, cursor: cursor, backgroundImage: background, windowTitle: title, into: target,
                commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            completed = completed && commandBuffer.status == .completed
            if index >= 8 { times.append(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) }
        }
        let sorted = times.sorted()
        return (
            sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1], sorted.last ?? 0, sorted.count,
            completed)
    } }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func sixteenSubsamplesAt4KFitTheFrameBudget() async throws {
    let output = SIMD2(3840, 2160)
    // A 4K screen (1920 × 1080 pt at 2×), the wallpaper, a shadow, the macOS frame with a title, mipmaps and a fast
    // cursor, with both shutters a whole frame.
    let take = makeTake(tracks: [
        displayTrack(
            globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080), pixelScale: 2,
            segments: [segment(start: base, end: base.adding(seconds: 6))]),
    ])
    let events = (0..<720).map { i in
        let a = Double(i) / 120 * 2 * .pi
        return StageDrawing.event(Double(i) / 120, .cursor(x: 960 + 700 * cos(3 * a), y: 540 + 400 * sin(2 * a)))
    }
    func frames(_ regions: [ZoomRegion], from first: Int) -> [RenderFrame] {
        var doc = document(take, events, regions: regions, cursorBlur: 1)
        doc.style.background = .wallpaper("aurora-1")
        doc.style.shadow = 0.6
        doc.style.frame = .macWindow(appearance: .dark, title: "Toma — benchmark", buttons: true)
        doc.style.screenSampling = .mipmapped
        doc.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
        let evaluator = FrameEvaluator(take: take, events: events, document: doc, outputSize: output, frameRate: 60)
        return (first..<(first + 8 + 120)).map { evaluator.frame(at: Double(TimeMap.frameTime($0, frameRate: 60)) / 1e9) }
    }
    // A camera that never stops: blocks of 0.25 s between two far points, 3 deep; 16 subsamples in every frame.
    let moving = frames((0..<20).map { k in
        let from = 0.5 + Double(k) * 0.25
        return StageDrawing.zoom(
            k + 1, from: from, to: from + 0.25, depth: 3, focus: k % 2 == 0 ? .fixed(x: 0.2, y: 0.25) : .fixed(x: 0.8, y: 0.75))
    }, from: 90)
    #expect(moving.allSatisfy { $0.subframes.count == 16 }, "\(moving.map(\.subframes.count))")
    #expect(moving.allSatisfy { $0.subframes.contains { $0.cursor != nil } })
    // Entering a zoom from rest: the stage barely zoomed, the wallpaper and the shadow around the window in view.
    let entering = frames([StageDrawing.zoom(1, from: 0.5, to: 5, depth: 2)], from: 30)
    #expect(entering.prefix(40).allSatisfy { $0.subframes.count == 16 }, "\(entering.map(\.subframes.count))")
    for (name, measured) in [("moving camera", moving), ("entering a zoom", entering)] {
        let times = try await gpuTimes(of: measured, output: output)
        print(String(
            format: "sixteenSubsamplesAt4KFitTheFrameBudget, %@: %d frames, GPU p50 %.2f ms, p95 %.2f ms, max %.2f ms", name,
            times.count, times.p50 * 1000, times.p95 * 1000, times.max * 1000))
        #expect(times.completed && times.count == 120)
        #expect(times.p95 <= 0.0167, "\(name): p95 \(times.p95 * 1000) ms")
    }
}

/// `rects` as `[x, y, width, height]` each, to compare.
private func values(_ rects: [MTLScissorRect]) -> [[Int]] {
    rects.map { [$0.x, $0.y, $0.width, $0.height] }
}

@Test func scissorBandsAreTheTargetButTheWholePixelsOfTheHole() {
    let output = SIMD2(200, 100)
    // A hole between pixels: only those wholly inside it are left out.
    let hole = Rect(x: 10.5, y: 20.25, width: 100.5, height: 50.5)
    #expect(values(Compositor.scissorBands(around: hole, outputSize: output, targetSize: output))
        == [[0, 0, 200, 21], [0, 70, 200, 30], [0, 21, 11, 49], [111, 21, 89, 49]])
    // A target twice the output: the hole in its pixels.
    #expect(values(Compositor.scissorBands(around: hole, outputSize: output, targetSize: output &* 2))
        == [[0, 0, 400, 41], [0, 141, 400, 59], [0, 41, 21, 100], [222, 41, 178, 100]])
    // Partly off the target: only the bands left inside it.
    #expect(values(Compositor.scissorBands(
        around: Rect(x: -20, y: -10, width: 100, height: 60), outputSize: output, targetSize: output))
        == [[0, 50, 200, 50], [80, 0, 120, 50]])
    // No whole pixel in it: all of the target. Over all of it: nothing.
    #expect(values(Compositor.scissorBands(
        around: Rect(x: 10.2, y: 10.2, width: 0.5, height: 0.5), outputSize: output, targetSize: output)) == [[0, 0, 200, 100]])
    #expect(Compositor.scissorBands(around: Rect(x: -5, y: -5, width: 300, height: 300), outputSize: output, targetSize: output)
        .isEmpty)
}

@Test func theOpaqueInsideIsTheRoundedRectInsetByItsCorners() {
    let screen = ScreenLayer(
        trackID: trackID, sourceTime: base, rect: Rect(x: 100, y: 50, width: 400, height: 300), cornerRadius: 20)
    // The screen alone: inset by its corners and a pixel.
    #expect(Compositor.opaqueInterior(screen: screen, window: nil) == Rect(x: 121, y: 71, width: 358, height: 258))
    // In a window it fills under the bar: the window's rect, inset by its rounder corners (the bottom ones) and a pixel.
    let window = WindowFrameLayer(
        rect: Rect(x: 100, y: 30, width: 400, height: 320), barHeight: 20, appearance: .dark, title: "", buttons: true,
        cornerRadius: 10, bottomCornerRadius: 24)
    #expect(Compositor.opaqueInterior(screen: screen, window: window) == Rect(x: 125, y: 55, width: 350, height: 270))
    // A screen that does not fill the window under its bar: nothing is taken as opaque.
    var narrow = screen
    narrow.rect.width -= 10
    #expect(Compositor.opaqueInterior(screen: narrow, window: window) == nil)
    var short = screen
    short.rect.height -= 10
    #expect(Compositor.opaqueInterior(screen: short, window: window) == nil)
    // Too small for its corners, of no size, no screen; corners that are not a number count as none.
    var small = screen
    small.rect = Rect(x: 0, y: 0, width: 30, height: 30)
    #expect(Compositor.opaqueInterior(screen: small, window: nil) == nil)
    small.rect.width = 0
    #expect(Compositor.opaqueInterior(screen: small, window: nil) == nil)
    #expect(Compositor.opaqueInterior(screen: nil, window: window) == nil)
    var odd = screen
    odd.cornerRadius = .nan
    #expect(Compositor.opaqueInterior(screen: odd, window: nil) == Rect(x: 101, y: 51, width: 398, height: 298))
}
