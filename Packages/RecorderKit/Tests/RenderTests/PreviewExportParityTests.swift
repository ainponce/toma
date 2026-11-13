// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import MetalKit
import ProjectFormat
import QuartzCore
@testable import Render
import SyntheticCapture
import Testing

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// A take of one 3 s display segment from `base`, with the cursor moving over it the whole time.
private func movingCursorProject(in dir: URL) async throws -> LoadedProject {
    let package = try makePackage(in: dir)
    let seg = try await writeSegment(in: package, index: 1, start: base, seconds: 3)
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [seg])])
    return makeProject(package, take: take, events: cursorEvents(from: base, seconds: 3, across: screenFrame))
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

@Test(.enabled(if: metalAvailable))
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

@Test(.enabled(if: metalAvailable))
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

@Test(.enabled(if: metalAvailable))
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

@Test(.enabled(if: metalAvailable))
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
@Test(.enabled(if: metalAvailable))
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
