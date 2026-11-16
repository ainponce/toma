// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import MetalKit
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
import Recording
@testable import Render
import SyntheticCapture
import Testing

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// A take of one 3 s display segment from `base`, with the cursor moving over it the whole time.
private func movingCursorProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
    try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
    return try builder.write()
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    return try #require(created)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func renderIsDeterministic() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await movingCursorProject(in: dir)
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, outputSize: size)
        let first = try renderer.renderBytes(at: 1.0)
        let second = try renderer.renderBytes(at: 1.0)
        #expect(first.count == 1280 * 720 * 4)
        #expect(first == second)
        // A second renderer, which decodes the frame with its own reader, draws the same bytes.
        #expect(try FrameRenderer(project: project, outputSize: size).renderBytes(at: 1.0) == first)
        // And it is the frame at 1 s, with the cursor drawn.
        let evaluator = FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: size)
        let frame = evaluator.frame(at: 1.0)
        let rect = try #require(frame.screen?.rect)
        let center = pixel(first, width: size.x, x: Int(rect.x + rect.width / 2), y: Int(rect.y + rect.height * 0.75))
        #expect(SampleFactory.frameIndex(nearestTo: center) == 30)
        let cursor = try #require(frame.cursor)
        let body = pixel(first, width: size.x, x: Int(cursor.hotspot.x + 0.15 * cursor.height), y: Int(cursor.hotspot.y + 0.45 * cursor.height))
        #expect(body.x < 40 && body.y < 40 && body.z < 40)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewAndExportPathsMatchBitForBit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await movingCursorProject(in: dir)
        let renderer = try FrameRenderer(project: project, outputSize: [1280, 720])
        let preview = PreviewRenderer(renderer: renderer)
        let pixelBuffer = try makePixelBuffer(width: 1280, height: 720)
        var previous: [UInt8]?
        for t in [0, 0.5, 1.7] {
            try renderer.render(at: t, into: pixelBuffer)
            let exported = packedBytes(of: pixelBuffer)
            let previewed = try preview.snapshot(at: t)
            #expect(exported.count == 1280 * 720 * 4)
            #expect(exported == previewed, "at \(t) s")
            #expect(exported != previous, "frames at different times differ")
            previous = exported
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewAndExportMatchWithCameraAndArea() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        var source = displaySource(globalFrame: screenFrame)
        source.captureArea = Rect(x: 80, y: 45, width: 480, height: 270)
        try await builder.addVideoTrack(id: trackID, source: source, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        // A 4:3 camera, filling the circle.
        try await builder.addVideoTrack(
            id: cameraID, kind: .camera, source: cameraSource,
            segments: [VideoSegmentSpec(start: base, seconds: 3, width: 640, height: 480)])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
        try builder.addEvents([InputEvent(
            t: base.adding(seconds: 1.5), kind: .cameraStyle(CameraStyle(shape: .landscape, size: CameraStyle.large, anchor: .top)))])
        let project = try builder.write()
        let renderer = try FrameRenderer(project: project, outputSize: [1280, 720])
        let preview = PreviewRenderer(renderer: renderer)
        let pixelBuffer = try makePixelBuffer(width: 1280, height: 720)
        let evaluator = FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: [1280, 720])
        var previous: [UInt8]?
        for t in [0, 0.5, 1.7] {
            let frame = evaluator.frame(at: t)
            #expect(frame.camera != nil && frame.screen?.crop != Rect(x: 0, y: 0, width: 1, height: 1), "at \(t) s")
            try renderer.render(at: t, into: pixelBuffer)
            let exported = packedBytes(of: pixelBuffer)
            #expect(exported == (try preview.snapshot(at: t)), "at \(t) s")
            #expect(exported != previous, "frames at different times differ")
            previous = exported
            // The camera is drawn: the centre of its rect is the camera's frame of that time.
            let camera = try #require(frame.camera)
            let centre = pixel(exported, width: 1280, x: Int(camera.rect.x + camera.rect.width / 2), y: Int(camera.rect.y + camera.rect.height / 2))
            #expect(SampleFactory.frameIndex(nearestTo: centre) == Int(t * 30) % 64, "at \(t) s")
        }
        #expect(renderer.missingVideo.isEmpty)
    }
}

/// A window that moves to a display of another scale goes on in a segment of other pixel dimensions, while the
/// manifest keeps the `pixelScale` of the start: each segment fills the window whatever its size.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func windowSegmentsAtAnotherScaleFillTheWindow() async throws {
    try await withTemporaryDirectory { dir in
        let window = "window-7"
        let frame = Rect(x: 100, y: 100, width: 640, height: 360)
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: window, kind: .window,
            source: TrackSource(name: "Synthetic Window", globalFrame: frame, pixelScale: 1, windowID: 7, bundleIdentifier: "dev.toma.tests"),
            segments: [
                VideoSegmentSpec(start: base, seconds: 1, endReason: .formatChanged, transform: paintingTheBottomRightQuarterGreen),
                VideoSegmentSpec(start: base.adding(seconds: 1), seconds: 1, width: 1280, height: 720, transform: paintingTheBottomRightQuarterGreen),
            ])
        try builder.addEvents([InputEvent(t: base, kind: .windowGeometry(track: window, frame: frame, onScreen: true))])
        let project = try builder.write()
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, outputSize: size)
        let rect = try #require(
            FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: size).frame(at: 0).screen?.rect)
        for (t, index) in [(0.5, 15), (1.5, 45)] {
            let bytes = try renderer.renderBytes(at: t)
            func at(_ u: Double, _ v: Double) -> SIMD4<UInt8> {
                pixel(bytes, width: size.x, x: Int(rect.x + u * rect.width), y: Int(rect.y + v * rect.height))
            }
            // The green quarter is the bottom-right quarter of the window, at either size.
            for (u, v) in [(0.75, 0.75), (0.52, 0.52), (0.98, 0.98)] {
                #expect(isClose(at(u, v), [0, 255, 0, 255], tolerance: 24), "(\(u), \(v)) at \(t) s: \(at(u, v))")
            }
            for (u, v) in [(0.25, 0.75), (0.75, 0.25), (0.48, 0.48)] {
                #expect(SampleFactory.frameIndex(nearestTo: at(u, v)) == index, "(\(u), \(v)) at \(t) s: \(at(u, v))")
            }
        }
        #expect(renderer.missingVideo.isEmpty)
    }
}

/// Projects of version 1 and 2 without edits draw the same bytes from one version of the render to the next (plan
/// decision 3). It runs only with `TOMA_GOLDEN_FILE` set (`make golden`): the frames of every case of `GoldenProjects`
/// that has times, drawn by `FrameRenderer` at 1280 × 720 at those times, one after the other in the order of the
/// cases, must equal that file byte for byte. With `TOMA_GOLDEN_RECORD=1` as well (`make golden-record`, only from Task
/// 1's commit), it writes them to that file instead, once every check passed, and never over a file already there.
/// Without the file and without the switch it fails: it never passes without comparing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_FILE"] != nil))
func goldenFramesMatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_FILE"]))
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let exists = FileManager.default.fileExists(atPath: url.path)
    if recording {
        try #require(!exists, "\(url.path) is already there: golden frames are never recorded over others")
    } else {
        try #require(
            exists, """
                No golden frames at \(url.path): they are recorded with `make golden-record` from Task 1's commit, never \
                from later code (plan decision 3)
                """)
    }
    let size = SIMD2(1280, 720)
    var bytes: [UInt8] = []
    // The case and the time of each frame in `bytes`.
    var frames: [(name: String, time: Double)] = []
    // Every check is a `#require`: when recording, nothing is written unless they all passed.
    try await withTemporaryDirectory { dir in
        for golden in GoldenProjects.cases where !golden.times.isEmpty {
            let project = try await GoldenProjects.make(golden.name, in: dir, videoEncoder: GoldenProjects.goldenFramesEncoder)
            try #require(project.manifest.formatVersion == (golden.name == "phaseZero" ? 1 : 2), "\(golden.name) is a v1 or v2 project")
            let renderer = try FrameRenderer(project: project, outputSize: size)
            try #require(
                renderer.duration >= 3 && golden.times.allSatisfy { $0 < renderer.duration },
                "\(golden.name) lasts \(renderer.duration) s, its times are \(golden.times)")
            for t in golden.times {
                bytes += try renderer.renderBytes(at: t)
                frames.append((golden.name, t))
            }
            try #require(renderer.missingVideo.isEmpty, "\(golden.name): \(renderer.missingVideo)")
        }
    }
    if recording {
        try Data(bytes).write(to: url, options: .withoutOverwriting)
        return
    }
    let golden = try Data(contentsOf: url)
    try #require(golden.count == bytes.count, "\(golden.count) bytes in \(url.path), \(bytes.count) drawn")
    guard golden != Data(bytes) else { return }
    let first = try #require(golden.indices.first { golden[$0] != bytes[$0] })
    let frameBytes = size.x * size.y * 4
    let frame = frames[first / frameBytes]
    let differing = zip(golden, bytes).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    Issue.record("""
        \(differing) bytes differ, the first in \(frame.name) at \(frame.time) s (byte \(first % frameBytes) of its frame): \
        the render of a v1 or v2 project changed. Never record the golden frames again from this code, only from Task 1's \
        commit when the system changed (plan decision 3)
        """)
}

/// Makes video writers as VideoToolbox does while the media engine takes no more hardware encoder sessions (other
/// processes hold them), for the first `busyWriters` writers asked for: one free to use any encoder writes with the
/// software encoder, one that must use the hardware encoder cannot be made. The writers after those are
/// `TakeBuilder`'s own.
private final class BusyMediaEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var busyWriters: Int
    private var counts = (fellBack: 0, refused: 0)
    var fellBack: Int { lock.withLock { counts.fellBack } }
    var refused: Int { lock.withLock { counts.refused } }

    init(busyWriters: Int) {
        self.busyWriters = busyWriters
    }

    func makeWriter(url: URL, framesPerSecond: Int, encoder: VideoEncoderChoice) throws -> FragmentedTrackWriter {
        let busy = lock.withLock { () -> Bool in
            guard busyWriters > 0 else { return false }
            busyWriters -= 1
            return true
        }
        let media = TrackMedia.video(framesPerSecond: framesPerSecond)
        guard busy, encoder != .softwareOnly else {
            return try FragmentedTrackWriter(url: url, media: media, realTime: false, videoEncoder: encoder)
        }
        if encoder == .hardwareOnly {
            lock.withLock { counts.refused += 1 }
            throw WriterError.appendFailed("the media engine takes no more hardware encoder sessions")
        }
        lock.withLock { counts.fellBack += 1 }
        return try FragmentedTrackWriter(url: url, media: media, realTime: false, videoEncoder: .softwareOnly)
    }
}

/// What made `make golden` fail now and then with "bytes differ" while other checkouts ran their tests: the cases'
/// video is written again on every run, and while the media engine takes no more hardware encoder sessions,
/// VideoToolbox writes it with its software encoder, whose bitstream decodes to other pixels. The golden frames are
/// drawn from the hardware encoder's video whatever the media engine is doing (`GoldenProjects.goldenFramesEncoder`):
/// `phaseZero` written while the engine is busy for its first video writer draws the frames of `phaseZero` written
/// while it is free. Not in CI: a virtual machine need not have a hardware HEVC encoder.
@Test(.enabled(if: MetalCondition.isAvailable && !MetalCondition.isRequired))
func goldenFramesAreDrawnFromTheHardwareEncodersVideo() async throws {
    try await withTemporaryDirectory { dir in
        let size = SIMD2(1280, 720)
        let times = try #require(GoldenProjects.cases.first { $0.name == "phaseZero" }).times
        func make(in name: String, makeVideoWriter: TakeBuilder.VideoWriterFactory? = nil) async throws -> [[UInt8]] {
            let folder = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let project = try await GoldenProjects.make(
                "phaseZero", in: folder, videoEncoder: GoldenProjects.goldenFramesEncoder, makeVideoWriter: makeVideoWriter)
            let renderer = try FrameRenderer(project: project, outputSize: size)
            return try await goldenOffThePool { try times.map { try renderer.renderBytes(at: $0) } }
        }
        let free = try await make(in: "free")
        let engine = BusyMediaEngine(busyWriters: 1)
        let busy = try await make(in: "busy", makeVideoWriter: engine.makeWriter)
        #expect(engine.fellBack + engine.refused == 1)
        #expect(engine.fellBack == 0, "\(engine.fellBack) segment written by the software encoder")
        for (k, t) in times.enumerated() {
            let differing = zip(busy[k], free[k]).filter { $0 != $1 }.count
            #expect(differing == 0, "\(differing) bytes of the frame at \(t) s differ")
        }
    }
}

/// Runs `body` on a thread of its own: decoding blocks, and must not hold a Swift concurrency thread.
private func goldenOffThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// Plan ruling R3: a golden frame sees a cursor sample from before `timelineStart`. The cursor of `windowMoving` starts
/// 0.045 s before its segment, off the 1/120 s grid, and its frame at 0 is drawn from the sample 3.3 ms before the take:
/// without the samples before the take that frame has no cursor, so a render that dropped them would change its bytes.
@Test func goldenFramesSeeTheCursorBeforeTheTake() async throws {
    try await withTemporaryDirectory { dir in
        #expect(GoldenProjects.cases.first { $0.name == "windowMoving" }?.times.first == 0)
        let project = try await GoldenProjects.make("windowMoving", in: dir)
        #expect(project.manifest.formatVersion == 2)
        func evaluator(_ events: [InputEvent]) -> FrameEvaluator {
            FrameEvaluator(take: project.take, events: events, style: StyleV0(), outputSize: [1280, 720])
        }
        let start = evaluator(project.events).timelineStart
        func isEarlyCursor(_ event: InputEvent) -> Bool {
            if case .cursor = event.kind { event.t < start } else { false }
        }
        let early = project.events.filter(isEarlyCursor)
        #expect(early.count == 6 && early.allSatisfy { $0.t.seconds(since: start) > -0.05 })
        #expect(evaluator(project.events).frame(at: 0).cursor != nil)
        #expect(evaluator(project.events.filter { !isEarlyCursor($0) }).frame(at: 0).cursor == nil)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rendererRefusesTargetsOfAnotherSizeOrFormat() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await movingCursorProject(in: dir)
        let renderer = try FrameRenderer(project: project, outputSize: [320, 180])
        #expect(throws: RenderError.targetSizeMismatch(expected: [320, 180], actual: [640, 360])) {
            try renderer.render(at: 0, into: try makePixelBuffer(width: 640, height: 360))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 320, height: 180, mipmapped: false)
        descriptor.usage = .renderTarget
        let srgb = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(renderer.device.makeCommandQueue()?.makeCommandBuffer())
        #expect(throws: RenderError.unsupportedPixelFormat) {
            try renderer.encode(at: 0, into: srgb, commandBuffer: commandBuffer)
        }
        #expect(throws: RenderError.invalidOutputSize([0, 180])) {
            _ = try FrameRenderer(project: project, outputSize: [0, 180])
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewPlaybackStaysWithinTheTimeline() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await movingCursorProject(in: dir)
        let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, outputSize: [320, 180]))
        #expect(preview.currentTime == 0 && preview.isPlaying == false)
        preview.currentTime = 10
        #expect(preview.currentTime == 3)
        preview.currentTime = -1
        #expect(preview.currentTime == 0)
        preview.isPlaying = true
        #expect(preview.isPlaying)
    }
}

@MainActor
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func configureSetsUpAViewForThePreview() async throws {
    // Not `withTemporaryDirectory`: its body is not main-actor isolated, and views are.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RenderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let project = try await movingCursorProject(in: dir)
    let renderer = try FrameRenderer(project: project, outputSize: [1280, 720])
    let preview = PreviewRenderer(renderer: renderer)
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: nil)
    preview.configure(view)
    #expect(view.device === renderer.device)
    #expect(view.colorPixelFormat == .bgra8Unorm)
    #expect(view.autoResizeDrawable == false)
    #expect(view.drawableSize == CGSize(width: 1280, height: 720))
    #expect(view.framebufferOnly)
    #expect(view.delegate === preview)
    let layer = try #require(view.layer as? CAMetalLayer)
    #expect(layer.colorspace?.name == CGColorSpace.itur_709)
    #expect(layer.pixelFormat == .bgra8Unorm)

    // A drawable of another size is not drawn, and logged once rather than on every frame.
    view.drawableSize = CGSize(width: 640, height: 360)
    preview.draw(in: view)
    preview.draw(in: view)
    #expect(preview.reportedErrorCount == 1)
    let mismatch = RenderError.targetSizeMismatch(expected: [1280, 720], actual: [640, 360])
    #expect(preview.reportOnce(mismatch, "again") == false)
}
