// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `Compositor.encodeWallpaper(_:tileSize:into:commandBuffer:)`, which draws a wallpaper alone, in tiles.
@testable import Render
import SyntheticCapture
import Testing

// The stage's background from the document: a gradient, a colour, or one of Toma's procedural wallpapers.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// decodes, which blocks (`offThePool` in DocumentRenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// A take of one second of the synthetic screen.
private func screenProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 1)])
    return try builder.write()
}

/// The frame at 0.5 s of `project`'s legacy document with `background`, `size` big, as BGRA bytes.
private func render(_ project: LoadedProject, background: Background, size: SIMD2<Int>) async throws -> [UInt8] {
    var document = EditDocument.legacy(for: project)
    document.style.background = background
    let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
    return try await offThePool { try renderer.renderBytes(at: 0.5) }
}

/// A `.bgra8Unorm` target `size` big that can be read back.
private func makeTarget(_ device: any MTLDevice, size: SIMD2<Int>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

/// Encodes with `encode` into a new target `size` big, waits for the GPU and returns its BGRA bytes.
private func drawn(
    _ device: any MTLDevice, size: SIMD2<Int>, _ encode: (any MTLTexture, any MTLCommandBuffer) throws -> Void
) throws -> [UInt8] {
    let target = try makeTarget(device, size: size)
    let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    try encode(target, commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
    target.getBytes(&bytes, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
    return bytes
}

/// `background` drawn alone by the compositor, `size` big, as BGRA bytes.
private func drawn(_ background: BackgroundLayer, size: SIMD2<Int>, compositor: Compositor, device: any MTLDevice) throws -> [UInt8] {
    let style = StyleV0()
    let frame = RenderFrame(
        outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
        gradientAngleDegrees: style.gradientAngleDegrees, background: background)
    let cursor = try CursorSprite.makeTexture(device: device)
    return try drawn(device, size: size) { target, commandBuffer in
        compositor.encode(frame, screen: nil, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
    }
}

/// The mean difference of the red, green and blue bytes of two BGRA images of the same size.
private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total = 0, count = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        for channel in 0..<3 {
            total += abs(Int(a[i + channel]) - Int(b[i + channel]))
            count += 1
        }
    }
    return Double(total) / Double(count)
}

@Test func presetListsFollowTheDesign() {
    #expect(WallpaperPreset.all.map(\.id) == [
        "aurora-1", "dune-1", "lake-1", "ember-1", "mist-1", "forest-1", "lavender-1", "midnight-1", "coral-1", "ice-1",
        "graphite-1", "sand-1",
    ])
    for preset in WallpaperPreset.all {
        #expect((4...6).contains(preset.points.count), "\(preset.id)")
        #expect(preset.colors.count == preset.points.count, "\(preset.id)")
        #expect(preset.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }, "\(preset.id)")
        #expect(preset.colors.allSatisfy { $0.w == 1 && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 && $0.z >= 0 && $0.z <= 1 }, "\(preset.id)")
        #expect(WallpaperPreset.preset(id: preset.id) == preset)
    }
    #expect(WallpaperPreset.preset(id: "aurora-9") == nil)

    let gradients = GradientPresets.all
    #expect(gradients.count == 10)
    #expect(Set(gradients.map(\.id)).count == 10)
    #expect(gradients.allSatisfy { $0.id.hasSuffix("-1") })
    let classic = gradients[0]
    #expect(classic.id == "toma-classic-1")
    #expect(Background.gradient(start: classic.start, end: classic.end, angle: classic.angle) == .tomaClassic)
}

@Test func documentBackgroundReachesTheFrame() throws {
    let take = makeTake(tracks: [])
    func background(_ background: Background) -> RenderFrame {
        var document = EditDocument.legacy(take: take, events: [])
        document.style.background = background
        return FrameEvaluator(take: take, events: [], document: document, outputSize: [320, 180]).frame(at: 0)
    }
    let classic = background(.tomaClassic)
    #expect(classic.background == .gradient)
    #expect(background(.color(RGBA(0.2, 0.4, 0.6, 1))).background == .color([0.2, 0.4, 0.6, 1]))
    let lake = try #require(WallpaperPreset.preset(id: "lake-1"))
    #expect(background(.wallpaper("lake-1")).background == .wallpaper(lake))
    // A wallpaper this version does not have is Toma classic.
    #expect(background(.wallpaper("aurora-9")) == classic)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func colorFillsTheBackground() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let size = SIMD2(320, 180)
        let bytes = try await render(project, background: .color(RGBA(0.2, 0.4, 0.6, 1)), size: size)
        // In the margin, around the screen.
        for (x, y) in [(0, 0), (4, 90), (160, 4), (315, 175), (319, 179)] {
            #expect(isClose(pixel(bytes, width: size.x, x: x, y: y), [153, 102, 51, 255], tolerance: 1), "at (\(x), \(y))")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func wallpaperIsTheSameInTwoTileSizes() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let preset = try #require(WallpaperPreset.preset(id: "aurora-1"))
    let size = SIMD2(320, 180)
    func tiled(_ tileSize: Int?) throws -> [UInt8] {
        try drawn(device, size: size) { target, commandBuffer in
            compositor.encodeWallpaper(preset, tileSize: tileSize, into: target, commandBuffer: commandBuffer)
        }
    }
    let whole = try tiled(nil)
    #expect(try tiled(64) == whole)
    #expect(try tiled(100) == whole)
    // The single quad is what a frame with that wallpaper draws.
    #expect(try drawn(.wallpaper(preset), size: size, compositor: compositor, device: device) == whole)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func everyWallpaperIsDistinctAndOpaque() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let size = SIMD2(64, 36)
    let images = try WallpaperPreset.all.map { try drawn(.wallpaper($0), size: size, compositor: compositor, device: device) }
    #expect(images.count == 12)
    for (preset, bytes) in zip(WallpaperPreset.all, images) {
        #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }, "\(preset.id)")
    }
    for i in images.indices {
        for j in images.indices where j > i {
            let difference = meanDifference(images[i], images[j])
            #expect(difference > 10, "\(WallpaperPreset.all[i].id) and \(WallpaperPreset.all[j].id): \(difference)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func grainStaysWithinTwoPercent() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let color = SIMD4<Float>(0.4, 0.6, 0.2, 1)
    let preset = WallpaperPreset(id: "test-1", points: [[0.2, 0.3], [0.8, 0.7]], colors: [color, color])
    let size = SIMD2(320, 180)
    let bytes = try drawn(.wallpaper(preset), size: size, compositor: compositor, device: device)
    let expected = SIMD4(color.z, color.y, color.x, color.w) * 255
    var largest: Float = 0
    for y in 0..<size.y {
        for x in 0..<size.x {
            let p = pixel(bytes, width: size.x, x: x, y: y)
            #expect(isClose(p, expected, tolerance: 6), "at (\(x), \(y)): \(p)")
            largest = max(largest, abs(Float(p.x) - expected.x), abs(Float(p.y) - expected.y), abs(Float(p.z) - expected.z))
        }
    }
    // There is a grain.
    #expect(largest >= 4)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func unknownWallpaperFallsBackToTheClassicGradient() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let size = SIMD2(320, 180)
        let unknown = try await render(project, background: .wallpaper("aurora-9"), size: size)
        #expect(unknown == (try await render(project, background: .tomaClassic, size: size)))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func customGradientAngle() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let size = SIMD2(320, 180)
        let red = RGBA(1, 0, 0, 1), blue = RGBA(0, 0, 1, 1)
        let bytes = try await render(project, background: .gradient(start: red, end: blue, angle: 90), size: size)
        // At 90° it goes to the right: red on the left, blue on the right, the same from top to bottom.
        for y in [0, 90, 179] {
            let left = pixel(bytes, width: size.x, x: 0, y: y), right = pixel(bytes, width: size.x, x: 319, y: y)
            #expect(left.z >= 250 && left.x <= 5 && left.y == 0, "left at \(y): \(left)")
            #expect(right.x >= 250 && right.z <= 5 && right.y == 0, "right at \(y): \(right)")
            for x in [0, 10, 309, 319] {
                let expected = expectedBackground(x: x, y: y, size: size, start: [1, 0, 0, 1], end: [0, 0, 1, 1], angleDegrees: 90)
                #expect(isClose(pixel(bytes, width: size.x, x: x, y: y), expected), "at (\(x), \(y))")
            }
        }
    }
}
