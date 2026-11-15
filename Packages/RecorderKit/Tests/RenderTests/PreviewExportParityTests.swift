// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import MetalKit
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
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

/// The take of `previewAndExportPathsMatchBitForBit` as the phase 0 recorder left it: a version 1 package, the
/// display's `displayGeometry` logged as the take starts (its `globalFrame`), the moving cursor and a microphone.
private func phaseZeroProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, formatVersion: 1)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
    try await builder.addAudioTrack(
        id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
        segments: [AudioSegmentSpec(start: base, seconds: 3)])
    try builder.addEvents([
        InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: screenFrame, scale: 1)),
    ])
    try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
    let project = try builder.write()
    #expect(project.manifest.formatVersion == 1)
    return project
}

/// A project of version 1 draws the same bytes from one version of the render to the next. It runs only with
/// `TOMA_GOLDEN_FILE` set: the frames at 0, 0.5 and 1.7 s, one after the other, must equal that file byte for byte.
/// With `TOMA_GOLDEN_RECORD=1` as well, it writes them to that file instead (run it so on the code to compare
/// against), and never over a file already there. Without the file and without the switch it fails: it never
/// passes without comparing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_FILE"] != nil))
func goldenFramesMatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_FILE"]))
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let exists = FileManager.default.fileExists(atPath: url.path)
    if recording {
        try #require(!exists, "\(url.path) is already there: remove it to record the golden frames again")
    } else {
        try #require(
            exists, "No golden frames at \(url.path): record them first, with TOMA_GOLDEN_RECORD=1, on the code to compare against")
    }
    try await withTemporaryDirectory { dir in
        let renderer = try FrameRenderer(project: try await phaseZeroProject(in: dir), outputSize: [1280, 720])
        var bytes: [UInt8] = []
        for t in [0, 0.5, 1.7] { bytes += try renderer.renderBytes(at: t) }
        if recording {
            try Data(bytes).write(to: url, options: .withoutOverwriting)
            return
        }
        let golden = [UInt8](try Data(contentsOf: url))
        try #require(golden.count == bytes.count, "\(golden.count) bytes in \(url.path), \(bytes.count) drawn")
        let differing = golden.indices.filter { golden[$0] != bytes[$0] }
        #expect(differing.isEmpty, "\(differing.count) bytes differ, the first at \(differing.first ?? 0)")
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
