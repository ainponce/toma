// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

// How the screen's frames are sampled (design §7.3): bilinear as today, or trilinear from mipmaps made for every frame,
// which does not alias a screen drawn much smaller than recorded, up to the edges of an area's crop.

/// A `.bgra8Unorm` checkerboard of 1 px squares, black and white, white at (0, 0).
private func checkerboard(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
            bytes += [value, value, value, 255]
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// A `.bgra8Unorm` texture of `frame`'s output size, to draw into and read back.
private func target(for frame: RenderFrame, device: any MTLDevice) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func bytes(of target: any MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
    target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
    return bytes
}

/// `frame` drawn over `screen` by `compositor`, as BGRA bytes.
private func draw(_ frame: RenderFrame, screen: any MTLTexture, compositor: Compositor, device: any MTLDevice) throws -> [UInt8] {
    let cursor = try CursorSprite.makeTexture(device: device)
    let target = try target(for: frame, device: device)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    return bytes(of: target)
}

/// A frame of `size` over black showing `crop` of the screen in `rect`, square, sampled with mipmaps or bilinear.
private func screenFrame(size: SIMD2<Int>, rect: Rect, crop: Rect = Rect(x: 0, y: 0, width: 1, height: 1), mipmapped: Bool) -> RenderFrame {
    RenderFrame(
        outputSize: size, gradientStart: [0, 0, 0, 1], gradientEnd: [0, 0, 0, 1], gradientAngleDegrees: 0,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 0, crop: crop, mipmapped: mipmapped))
}

/// The grey of the pixels of `bytes` at `points` (all three channels are one for a grey checkerboard).
private func greys(_ bytes: [UInt8], width: Int, _ points: [SIMD2<Int>]) -> [Int] {
    points.map { Int(pixel(bytes, width: width, x: $0.x, y: $0.y).y) }
}

@Test func screenSamplingComesFromTheStyle() throws {
    let display = Rect(x: 0, y: 0, width: 640, height: 360)
    let take = makeTake(tracks: [displayTrack(globalFrame: display, segments: [segment(start: base, end: base.adding(seconds: 1))])])
    var document = EditDocument.legacy(take: take, events: [])
    func screen() throws -> ScreenLayer {
        try #require(FrameEvaluator(take: take, events: [], document: document, outputSize: [1280, 720]).frame(at: 0.5).screen)
    }
    #expect(try screen().mipmapped == false)
    let bilinear = try screen()
    document.style.screenSampling = .mipmapped
    var expected = bilinear
    expected.mipmapped = true
    #expect(try screen() == expected)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedSamplingDoesNotAlias() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let size = SIMD2(320, 180)
    // 740 × 370 drawn into 200 × 100: 1/3.7 of its size. At exactly 1/4 a bilinear sample falls between four texels and
    // averages them to grey too.
    let rect = Rect(x: 60, y: 40, width: 200, height: 100)
    let board = try checkerboard(device, width: 740, height: 370)
    // Inside the rect, away from its antialiased edge.
    let inside = (41..<139).flatMap { y in (61..<259).map { SIMD2($0, y) } }

    func drawn(mipmapped: Bool) throws -> [Int] {
        let frame = screenFrame(size: size, rect: rect, mipmapped: mipmapped)
        return greys(try draw(frame, screen: board, compositor: compositor, device: device), width: size.x, inside)
    }
    let mipmapped = try drawn(mipmapped: true)
    #expect(mipmapped.allSatisfy { abs($0 - 127) <= 8 }, "mipmapped from \(mipmapped.min()!) to \(mipmapped.max()!)")
    let bilinear = try drawn(mipmapped: false)
    #expect(bilinear.contains { $0 < 60 || $0 > 195 }, "bilinear from \(bilinear.min()!) to \(bilinear.max()!)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedEdgesOfTheCropUseTheRightLevel() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let size = SIMD2(320, 180)
    // The left half of a 740 × 370 board, 370 × 370, into 100 × 100: 1/3.7. The rect's columns are 61...160 and its rows
    // 41...140, so its first and last columns and rows share their 2 × 2 quads of pixels with the antialiased edge
    // outside it, where the coordinates are clamped to the crop.
    let rect = Rect(x: 61, y: 41, width: 100, height: 100)
    let board = try checkerboard(device, width: 740, height: 370)
    let frame = screenFrame(size: size, rect: rect, crop: Rect(x: 0, y: 0, width: 0.5, height: 1), mipmapped: true)
    let drawn = try draw(frame, screen: board, compositor: compositor, device: device)
    let lastColumn = greys(drawn, width: size.x, (41...140).map { SIMD2(160, $0) })
    let firstColumn = greys(drawn, width: size.x, (41...140).map { SIMD2(61, $0) })
    let lastRow = greys(drawn, width: size.x, (61...160).map { SIMD2($0, 140) })
    let centre = greys(drawn, width: size.x, (90...110).map { SIMD2($0, 90) })
    for (name, values) in [("last column", lastColumn), ("first column", firstColumn), ("last row", lastRow), ("centre", centre)] {
        #expect(values.allSatisfy { abs($0 - 127) <= 8 }, "\(name) from \(values.min()!) to \(values.max()!)")
    }

    // The GPU picks the level from the faster of the two directions, so along a column the rows' change alone would pick
    // it right. Drawn 1/3.7 across but 1:1 down, only the change across picks it: from the clamped coordinates, the last
    // and first columns would read the full-size level and show the squares.
    let narrowSize = SIMD2(320, 400)
    let narrow = Rect(x: 61, y: 15, width: 100, height: 370)
    let across = try draw(
        screenFrame(size: narrowSize, rect: narrow, crop: Rect(x: 0, y: 0, width: 0.5, height: 1), mipmapped: true), screen: board,
        compositor: compositor, device: device)
    for (name, x) in [("last column", 160), ("first column", 61), ("centre", 110)] {
        let values = greys(across, width: narrowSize.x, (16...383).map { SIMD2(x, $0) })
        #expect(values.allSatisfy { abs($0 - 127) <= 8 }, "1/3.7 across, \(name) from \(values.min()!) to \(values.max()!)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedFramesInFlightGiveTheSameBytes() throws {
    // Several frames encoded before the GPU finishes any: each has a copy of its own, and a copy is used again only
    // once the frame it was made for is done. Every frame of the same screen is the same bytes.
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let size = SIMD2(320, 180)
    let frame = screenFrame(size: size, rect: Rect(x: 60, y: 40, width: 200, height: 100), mipmapped: true)
    let board = try checkerboard(device, width: 740, height: 370)
    let other = try checkerboard(device, width: 370, height: 185)
    let cursor = try CursorSprite.makeTexture(device: device)
    let queue = try #require(device.makeCommandQueue())
    let expected = try draw(frame, screen: board, compositor: compositor, device: device)
    for round in 0..<3 {
        var targets: [any MTLTexture] = []
        var buffers: [any MTLCommandBuffer] = []
        for i in 0..<6 {
            let target = try target(for: frame, device: device)
            let commandBuffer = try #require(queue.makeCommandBuffer())
            // A frame of another size between them: its copies are of its own size.
            compositor.encode(
                frame, screen: i == 3 ? other : board, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            targets.append(target)
            buffers.append(commandBuffer)
        }
        for (i, commandBuffer) in buffers.enumerated() {
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            if i != 3 { #expect(bytes(of: targets[i]) == expected, "round \(round), frame \(i)") }
        }
    }
}
