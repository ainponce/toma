// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for `FrameRenderer.reader(for:)`, `TrackFrameReader.recordsAsks`, the engine's hooks and `DecodeAhead`.
@testable import Render
import Synchronization
import SyntheticCapture
import Testing

// Reading the videos by the layouts (1c design §14.4): a screen or a camera that a layout hides is not decoded, and the
// one a block border is about to show starts decoding 1 s of output before it (`DecodeAhead`), so the transition skips no
// frame. The bytes (the preview is the export) are `LayoutExportParityTests`'s, in the export's tests.

private let parityScreen = Rect(x: 0, y: 0, width: 640, height: 360)
private let paritySize = SIMD2(640, 360)

/// A take of `seconds` from `base`: the screen and a camera, both `SampleFactory`'s frames (each its own colour, so a
/// pixel says which frame it is), 640 × 360 at 30 fps, with the cursor moving over the screen.
private func parityProject(in dir: URL, seconds: Double) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: parityScreen), segments: [VideoSegmentSpec(start: base, seconds: seconds)])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource, segments: [VideoSegmentSpec(start: base, seconds: seconds)])
    try builder.addEvents(cursorEvents(from: base, seconds: seconds, across: parityScreen))
    return try builder.write()
}

/// A block of `kind` over source seconds `[from, to)`.
private func block(_ number: Int, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
    LayoutBlock(
        id: "l-0000000\(number)", take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), kind: kind,
        instant: false, bubble: kind == .bubble ? BubbleLayout(style: CameraStyle(shape: .circle, size: 0.3, anchor: .topLeading)) : nil,
        split: kind == .split ? SplitLayout() : nil)
}

/// The legacy document of `project` at `rate` frames per second, with `blocks`.
private func document(of project: LoadedProject, rate: Int, _ blocks: [LayoutBlock]) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.frameRate = rate
    document.camera.layouts = blocks
    return document
}

private func seconds(ofFrame n: Int, rate: Int) -> Double {
    Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9
}

/// Seconds of `time` after the take's start.
private func source(_ time: HostTime) -> Double { time.seconds(since: base) }

/// Draws frames `0..<count` of `renderer`'s scene as the export does (`render(at:into:completion:)`: queued one after the
/// other, each decoded ahead through the prefetchers), waiting for each.
private func exportFrames(_ renderer: FrameRenderer, count: Int) async throws {
    let rate = renderer.frameRate
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    let target = PixelBufferHolder(try #require(created))
    for n in 0..<count {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            renderer.render(at: seconds(ofFrame: n, rate: rate), into: target.pixelBuffer) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }
}

private final class PixelBufferHolder: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func hiddenScreenIsNotDecoded() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await parityProject(in: dir, seconds: 10)
        // Camera full screen settled from 2 s (its block starts 1.5 s before, the transition's length) to its end at 6 s;
        // Screen only from 7 s to the end, settled from 8.5 s.
        let document = document(of: project, rate: 30, [block(1, .cameraFull, from: 0.5, to: 6), block(2, .screenOnly, from: 7, to: 10)])
        let layouts = LayoutTimeline(
            document: document, take: project.take, timeMap: TimeMap(sequence: document.sequence), cameraReadable: true)
        #expect(stride(from: 2.0, to: 6.0, by: 0.01).allSatisfy { layouts.screenOpacity(atOutput: Int64($0 * 1e9)) == 0 })

        let renderer = try FrameRenderer(project: project, document: document, outputSize: paritySize)
        let screen = try #require(renderer.reader(for: trackID)), camera = try #require(renderer.reader(for: cameraID))
        screen.recordsAsks = true
        camera.recordsAsks = true
        try await exportFrames(renderer, count: 300)

        let screenAsks = screen.askedTimes.map(source), cameraAsks = camera.askedTimes.map(source)
        // Not a frame of the screen while Camera full screen hides it: what is asked next is the frame that the border at 6 s
        // shows first, decoded ahead.
        #expect(!screenAsks.contains { (2.1..<4.9).contains($0) }, "\(screenAsks.filter { (2.1..<4.9).contains($0) })")
        #expect(!screenAsks.contains { (2.1..<6.0).contains($0) })
        // It is read where it is seen, before and after.
        #expect(screenAsks.contains { $0 < 0.6 } && screenAsks.contains { $0 > 6 })
        // Nor the camera while Screen only hides it.
        #expect(!cameraAsks.contains { $0 >= 8.6 }, "\(cameraAsks.filter { $0 >= 8.6 })")
        #expect(cameraAsks.contains { (3..<6).contains($0) })
        // Frame by frame (the preview's pause and `renderBytes`), the same.
        let frameByFrame = try FrameRenderer(project: project, document: document, outputSize: paritySize)
        let hidden = try #require(frameByFrame.reader(for: trackID))
        hidden.recordsAsks = true
        _ = try await offThePool { try [2.2, 3.0, 4.5, 5.9].map { try frameByFrame.renderBytes(at: $0) } }
        #expect(hidden.askedTimes.isEmpty)
    }
}

/// Draws what the engine shows while playing, from its hook.
private final class PlayedFrames: Sendable {
    private let frames = Mutex<[PreviewEngine.DrawnFrame]>([])

    func append(_ frame: PreviewEngine.DrawnFrame) { frames.withLock { $0.append(frame) } }
    var all: [PreviewEngine.DrawnFrame] { frames.withLock { $0 } }
    var count: Int { frames.withLock { $0.count } }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func trackNeededAfterABorderIsDecodedAhead() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await parityProject(in: dir, seconds: 7)
        // Camera full screen from the first instant (settled already on the first frame) to 5 s, then the project's Bubble:
        // the screen is not seen before 5 s, and fades in from there.
        let document = document(of: project, rate: 30, [block(1, .cameraFull, from: 0, to: 5)])
        let renderer = try FrameRenderer(project: project, document: document, outputSize: paritySize, frameRate: 30)
        let screen = try #require(renderer.reader(for: trackID))
        screen.recordsAsks = true
        let layer = CAMetalLayer()
        CATransaction.begin()
        layer.drawableSize = CGSize(width: 640, height: 360)
        CATransaction.commit()
        let engine = PreviewEngine(renderer: renderer, layer: layer)
        let played = PlayedFrames()
        engine.hooks.onDrawn = { played.append($0) }

        /// Plays frame `n`, as a display link does at 30 Hz: asked once the one before is drawn, a frame's time after it.
        func play(_ n: Int) async throws {
            let before = played.count
            engine.request(.playing(seconds: seconds(ofFrame: n, rate: 30)))
            #expect(await eventually(timeout: .seconds(30)) { played.count > before }, "frame \(n) drawn")
            try await Task.sleep(for: .milliseconds(33))
        }
        // Up to 4.067 s, before 4.1 s.
        for n in 0...122 { try await play(n) }
        #expect(screen.askedTimes.allSatisfy { source($0) >= 5 }, "nothing of the screen before the border")
        // The frame the border shows first is being decoded already, a second of output before it.
        #expect(
            await eventually(timeout: .seconds(10)) { screen.askedTimes.contains { source($0) > 5 && source($0) < 5.05 } },
            "the screen's first frame after the border, asked before 4.1 s")

        for n in 123...195 { try await play(n) }
        let transition = played.all.filter { if case let .playing(t) = $0.request { t >= 5 && t < 6.5 } else { false } }
        #expect(transition.count == 45)
        // No frame skipped, and each shows the screen's own frame from the first after the border on.
        #expect(transition.allSatisfy { !$0.late }, "\(transition.filter(\.late).map(\.request))")
        for frame in transition {
            guard case let .playing(t) = frame.request, t > 5.01 else { continue }
            let shown = try #require(frame.videos[trackID], "the screen at \(t) s")
            #expect(frameIndex(of: shown) == Int((t * 30).rounded()) % 64, "at \(t) s")
        }
    }
}

// MARK: - What is decoded ahead

/// (track, source second) pairs as videos of a frame, for `DecodeAhead`.
private func keys(_ pairs: [(String, Double)]) -> [DecodedKey] {
    pairs.map { DecodedKey(trackID: $0.0, time: base.adding(seconds: $0.1)) }
}

@Test func decodeAheadSchedulesInOrderAndTheFirstFrameOfATrackThatComes() throws {
    // A screen ("s") on frames 0–3 and from 30 on, a camera ("c") on every frame: frame j shows the screen's second j and the
    // camera's j.
    func videos(_ j: Int) -> [DecodedKey] {
        keys((j <= 3 || j >= 30 ? [("s", Double(j))] : []) + [("c", Double(j))])
    }
    var ahead = DecodeAhead(near: 2, far: 10)
    var looked: [Int] = []
    func advance(_ index: Int, first: Int = 0) -> [DecodedKey] {
        ahead.advance(to: index, last: 40, first: first) { j in
            looked.append(j)
            return videos(j)
        }
    }
    // The next frames as they come.
    #expect(advance(0) == keys([("s", 0), ("c", 0), ("s", 1), ("c", 1), ("s", 2), ("c", 2)]))
    #expect(looked == Array(0...10))
    #expect(advance(1) == keys([("s", 3), ("c", 3)]))
    #expect(ahead.scheduledThrough == 3)
    // Frame 30 comes within 10 frames once frame 20 is drawn, and nothing of the screen is scheduled after 3: its first
    // frame then, at once, and not again when its turn comes.
    for index in 2..<20 { _ = advance(index) }
    #expect(advance(20) == keys([("c", 22), ("s", 30)]))
    for index in 21..<28 { _ = advance(index) }
    #expect(advance(28) == keys([("c", 30)]))
    #expect(advance(29) == keys([("s", 31), ("c", 31)]))
    #expect(looked == Array(0...39), "each frame looked at once, in order")
    // Drawn frame by frame, the caller asking for each on its own: the frames after it.
    ahead.reset()
    looked = []
    #expect(advance(5, first: 1) == keys([("c", 6), ("c", 7)]))
    #expect(looked == Array(5...15))
}

@Test func decodeAheadNeverPutsAFrameBeforeOneScheduled() {
    // The screen on 0–1, again on 8–9 within the far window while its frames 0–1 are scheduled, and from 15 on.
    func videos(_ j: Int) -> [DecodedKey] {
        [0, 1, 8, 9].contains(j) || j >= 15 ? keys([("s", Double(j))]) : []
    }
    var ahead = DecodeAhead(near: 1, far: 10)
    var scheduled: [Double] = []
    for index in 0...20 {
        scheduled += ahead.advance(to: index, last: 30, first: 1, videos: videos).map { source($0.time) }
    }
    // In the order of the grid, each once: the reader is asked what drawing frame by frame asks, in that order.
    #expect(scheduled == scheduled.sorted() && Set(scheduled).count == scheduled.count, "\(scheduled)")
    #expect(scheduled == [1, 8, 9, 15, 16, 17, 18, 19, 20, 21])
    // A jump starts over.
    ahead.reset()
    #expect(ahead.advance(to: 5, last: 30, first: 1, videos: videos) == keys([("s", 8)]))
}

// MARK: - The window title in a transition (bench)

/// A layout transition moves the window frame's rect on every frame, so its title is drawn again by CoreText on each one
/// (`TitleTexture`: a title's texture depends on its rect). Measures that at 4K: the frames of a Bubble-to-Split and a
/// Split-to-Camera-full transition at 60 fps with the macOS window frame and a title, each title's texture asked for as
/// `FrameRenderer` asks for it. Run by an agent, with `TOMA_BENCH=1`, in release; printed and recorded in
/// docs/performance.md, not asserted.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && MetalCondition.isAvailable))
func windowTitleRedrawInATransition() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let take = makeTake(tracks: [
        displayTrack(globalFrame: parityScreen, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 10))]),
    ])
    var document = EditDocument.legacy(take: take, events: [])
    document.frameRate = 60
    document.style.frame = .macWindow(appearance: .dark, title: "Toma — benchmark", buttons: true)
    document.camera.layouts = [block(1, .split, from: 2, to: 5), block(2, .cameraFull, from: 5, to: 8)]
    let evaluator = FrameEvaluator(take: take, events: [], document: document, outputSize: [3840, 2160])
    let clock = ContinuousClock()
    for (name, from) in [("Bubble to Split", 2.0), ("Split to Camera full screen", 5.0)] {
        let titles = TitleTexture(device: device)
        var times: [Double] = []
        for n in 0..<90 {
            let frame = evaluator.frame(at: from + Double(n) / 60)
            guard let source = TitleTexture.source(for: frame) else { continue }
            let before = titles.drawCount
            let took = try clock.measure { _ = try titles.texture(for: source, scale: TitleTexture.scale(for: frame)) }
            if titles.drawCount > before {
                times.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1e3)
            }
        }
        let sorted = times.sorted()
        print(String(
            format: "window title, %@ at 3840 × 2160: %d of 90 frames drew it again, %.3f ms each (median), %.3f ms at most, "
                + "%.1f ms in all",
            name, times.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2], sorted.last ?? 0, times.reduce(0, +)))
    }
}
