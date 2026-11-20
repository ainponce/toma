// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Metal
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for the engine's hooks, `drawnBytes()` and `encodeShown`.
@testable import Render
import Synchronization
import SyntheticCapture
import Testing

// The preview of a codec with alpha (milestone 4c, design §7.1, plan 4c Task X1): while `showsAlpha`, the engine draws
// the export's transparent frame into its texture and shows it over a checkerboard in the drawable alone.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(640, 360)

/// A take of one display, 640 × 360 at 30 fps for 2 s from `base`, with the cursor moving over it.
private func project(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 2)])
    try builder.addEvents(cursorEvents(from: base, seconds: 2, across: screenFrame))
    return try builder.write()
}

/// The legacy document of `project` on one colour, with round corners, a shadow and a window frame.
private func document(_ project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.style.background = .color(RGBA(0.1, 0.8, 0.3, 1))
    document.style.cornerRadius = 0.04
    document.style.shadow = 0.6
    document.style.frame = .macWindow(appearance: .light, title: "Toma", buttons: true)
    return document
}

private func seconds(ofFrame n: Int, rate: Int) -> Double {
    Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9
}

/// What the engine's callbacks take first, so ThreadSanitizer sees them ordered after what the test wrote (as
/// `PreviewEngineTests` does).
private let published = Mutex(())

/// An engine for `renderer` with a layer of the output's size, and the frames it drew.
private final class Watched: @unchecked Sendable {
    let engine: PreviewEngine
    let layer = CAMetalLayer()
    private let lock = NSLock()
    private var drawnFrames: [PreviewEngine.DrawnFrame] = []

    init(_ renderer: FrameRenderer) {
        CATransaction.begin()
        layer.drawableSize = CGSize(width: size.x, height: size.y)
        CATransaction.commit()
        engine = PreviewEngine(renderer: renderer, layer: layer)
        engine.hooks.onDrawn = { [self] frame in
            published.withLock { _ in }
            lock.withLock { drawnFrames.append(frame) }
        }
        published.withLock { _ in }
    }

    var drawn: [PreviewEngine.DrawnFrame] { lock.withLock { drawnFrames } }

    /// Waits until `count` frames are drawn, or 30 s; returns the last one.
    @discardableResult
    func waitForDrawn(_ count: Int) async throws -> PreviewEngine.DrawnFrame {
        #expect(await eventually(timeout: .seconds(30)) { self.drawn.count >= count }, "\(count) frames drawn")
        return try #require(drawn.last)
    }
}

/// A `.bgra8Unorm` texture of `width` × `height` that the CPU reads and writes, with `bgra(x, y)` at each pixel.
private func texture(
    _ device: any MTLDevice, width: Int, height: Int, usage: MTLTextureUsage, _ bgra: (Int, Int) -> SIMD4<UInt8>
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = usage
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = bgra(x, y), i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (p.x, p.y, p.z, p.w)
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
struct PreviewEngineAlphaTests {
    @Test func previewEqualsTheTransparentRender() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await project(in: dir)
            let renderer = try FrameRenderer(project: project, document: document(project), outputSize: size, frameRate: 30)
            let clear = try FrameRenderer(
                project: project, document: document(project), outputSize: size, frameRate: 30, transparentBackground: true)
            let opaque = try FrameRenderer(project: project, document: document(project), outputSize: size, frameRate: 30)
            let watched = Watched(renderer)
            watched.engine.showsAlpha = true
            #expect(watched.engine.showsAlpha)
            watched.engine.request(.paused(frame: 21))
            let drawn = try await watched.waitForDrawn(1)
            #expect(drawn.frame.background == .transparent)
            let shown = try await watched.engine.drawnBytes()
            let expected = try await offThePool { try clear.renderBytes(at: seconds(ofFrame: 21, rate: 30)) }
            #expect(shown == expected)
            // The engine's texture has the export's bytes: nothing at the padding, no checkerboard.
            #expect(pixel(shown, width: size.x, x: 8, y: 8) == .zero)
            watched.engine.showsAlpha = false
            let again = try await watched.waitForDrawn(2)
            #expect(again.frame.background != .transparent && again.request == .paused(frame: 21))
            let opaqueBytes = try await offThePool { try opaque.renderBytes(at: seconds(ofFrame: 21, rate: 30)) }
            #expect(try await watched.engine.drawnBytes() == opaqueBytes)
        }
    }

    @Test func checkerboardOnlyInTheDrawable() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await project(in: dir)
            let renderer = try FrameRenderer(project: project, document: document(project), outputSize: size, frameRate: 30)
            let engine = PreviewEngine(renderer: renderer, layer: CAMetalLayer())
            let device = renderer.device
            // 64 × 32: nothing on the left half, opaque red on the right.
            let source = try texture(device, width: 64, height: 32, usage: .shaderRead) { x, _ in x < 32 ? .zero : [0, 0, 255, 255] }
            let greys = (
                UInt8((PreviewEngine.checkerGreys.0 * 255).rounded()), UInt8((PreviewEngine.checkerGreys.1 * 255).rounded()))
            #expect(PreviewEngine.checkerSquare == 16 && greys == (51, 71))
            func shown(overCheckerboard: Bool) throws -> [UInt8] {
                let drawable = try texture(device, width: 64, height: 32, usage: [.renderTarget, .shaderRead]) { _, _ in [1, 2, 3, 4] }
                let queue = try #require(device.makeCommandQueue())
                let commandBuffer = try #require(queue.makeCommandBuffer())
                try engine.encodeShown(source, into: drawable, overCheckerboard: overCheckerboard, commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                #expect(commandBuffer.status == .completed)
                return StageDrawing.bytes(of: drawable)
            }
            let checkered = try shown(overCheckerboard: true)
            let plain = try shown(overCheckerboard: false)
            for y in 0..<32 {
                for x in 0..<64 {
                    let even = (x / 16 + y / 16) % 2 == 0
                    let grey = even ? greys.0 : greys.1
                    let expected: SIMD4<UInt8> = x < 32 ? [grey, grey, grey, 255] : [0, 0, 255, 255]
                    #expect(pixel(checkered, width: 64, x: x, y: y) == expected, "checkerboard at (\(x), \(y))")
                    let reduced: SIMD4<UInt8> = x < 32 ? .zero : [0, 0, 255, 255]
                    #expect(pixel(plain, width: 64, x: x, y: y) == reduced, "reduction at (\(x), \(y))")
                }
            }
        }
    }

    @Test func togglingShowsAlphaRedrawsTheLastRequest() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await project(in: dir)
            let renderer = try FrameRenderer(project: project, document: document(project), outputSize: size, frameRate: 30)
            let watched = Watched(renderer)
            // Nothing asked yet: nothing drawn.
            watched.engine.showsAlpha = true
            watched.engine.showsAlpha = false
            watched.engine.request(.paused(frame: 12))
            let first = try await watched.waitForDrawn(1)
            #expect(first.frame.background != .transparent)
            // Set to what it is: nothing drawn again.
            watched.engine.showsAlpha = false
            watched.engine.showsAlpha = true
            let second = try await watched.waitForDrawn(2)
            #expect(second.request == .paused(frame: 12) && second.frame.background == .transparent)
            // From another thread.
            let engine = watched.engine
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    engine.showsAlpha = false
                    continuation.resume()
                }
            }
            let third = try await watched.waitForDrawn(3)
            #expect(third.request == .paused(frame: 12) && third.frame.background != .transparent)
            // A new scene, opaque as every scene the app makes, is drawn with it.
            watched.engine.showsAlpha = true
            try await watched.waitForDrawn(4)
            let scene = FrameEvaluator(
                take: project.take, events: project.events, document: document(project), outputSize: size, frameRate: 30)
            #expect(!scene.transparentBackground)
            watched.engine.setScene(scene)
            let fifth = try await watched.waitForDrawn(5)
            #expect(fifth.frame.background == .transparent)
            try await Task.sleep(for: .milliseconds(300))
            #expect(watched.drawn.count == 5)
        }
    }
}
