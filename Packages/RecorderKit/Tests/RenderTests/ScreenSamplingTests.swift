// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)` and `Compositor.mipmappedCopiesCount`.
@testable import Render
import Testing

// How the screen's frames are sampled (design §7.3): bilinear as today, or trilinear from mipmaps made for every frame,
// which does not alias a screen drawn much smaller than recorded, up to the edges of an area's crop, and shows nothing
// from outside an Area. The GPU's work runs off the cooperative pool and hands back what it drew: the checks are made in
// the test's task.

/// The system's Metal device.
private func metalDevice() throws -> any MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else { throw TestSupportError.missing("Metal device") }
    return device
}

/// A `.bgra8Unorm` texture whose pixel at (`x`, `y`) is `bgra(x, y)`.
private func texture(
    _ device: any MTLDevice, width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> SIMD4<UInt8>
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw TestSupportError.missing("texture") }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = bgra(x, y)
            bytes += [pixel.x, pixel.y, pixel.z, pixel.w]
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// A `.bgra8Unorm` checkerboard of 1 px squares, black and white, white at (0, 0).
private func checkerboard(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
    try texture(device, width: width, height: height) { x, y in
        let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
        return [value, value, value, 255]
    }
}

/// A `.bgra8Unorm` texture of `frame`'s output size, to draw into and read back.
private func target(for frame: RenderFrame, device: any MTLDevice) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { throw TestSupportError.missing("target") }
    return target
}

private func bytes(of target: any MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
    target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
    return bytes
}

/// `frame` drawn over `screen` by `compositor`, as BGRA bytes; throws if the GPU does not complete it.
private func draw(_ frame: RenderFrame, screen: any MTLTexture, compositor: Compositor, device: any MTLDevice) throws -> [UInt8] {
    let cursor = try CursorSprite.makeTexture(device: device)
    let target = try target(for: frame, device: device)
    guard let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
        throw TestSupportError.missing("command buffer")
    }
    try compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
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
func mipmappedSamplingDoesNotAlias() async throws {
    let size = SIMD2(320, 180)
    // 740 × 370 drawn into 200 × 100: 1/3.7 of its size. At exactly 1/4 a bilinear sample falls between four texels and
    // averages them to grey too.
    let rect = Rect(x: 60, y: 40, width: 200, height: 100)
    // Inside the rect, away from its antialiased edge.
    let inside = (41..<139).flatMap { y in (61..<259).map { SIMD2($0, y) } }
    let (mipmapped, bilinear) = try await offThePool {
        let device = try metalDevice()
        let compositor = try Compositor(device: device)
        let board = try checkerboard(device, width: 740, height: 370)
        func drawn(mipmapped: Bool) throws -> [Int] {
            let frame = screenFrame(size: size, rect: rect, mipmapped: mipmapped)
            return greys(try draw(frame, screen: board, compositor: compositor, device: device), width: size.x, inside)
        }
        return (try drawn(mipmapped: true), try drawn(mipmapped: false))
    }
    #expect(mipmapped.allSatisfy { abs($0 - 127) <= 8 }, "mipmapped from \(mipmapped.min()!) to \(mipmapped.max()!)")
    #expect(bilinear.contains { $0 < 60 || $0 > 195 }, "bilinear from \(bilinear.min()!) to \(bilinear.max()!)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedEdgesOfTheCropUseTheRightLevel() async throws {
    let size = SIMD2(320, 180)
    // The left half of a 740 × 370 board, 370 × 370, into 100 × 100: 1/3.7. The rect's columns are 61...160 and its rows
    // 41...140, so its first and last columns and rows share their 2 × 2 quads of pixels with the antialiased edge
    // outside it, where the coordinates are clamped to the crop.
    let rect = Rect(x: 61, y: 41, width: 100, height: 100)
    let crop = Rect(x: 0, y: 0, width: 0.5, height: 1)
    // The GPU picks the level from the faster of the two directions, so along a column the rows' change alone would pick
    // it right. Drawn 1/3.7 across but 1:1 down, only the change across picks it: from the clamped coordinates, the last
    // and first columns would read the full-size level and show the squares.
    let narrowSize = SIMD2(320, 400)
    let narrow = Rect(x: 61, y: 15, width: 100, height: 370)
    let (drawn, across) = try await offThePool {
        let device = try metalDevice()
        let compositor = try Compositor(device: device)
        let board = try checkerboard(device, width: 740, height: 370)
        return (
            try draw(
                screenFrame(size: size, rect: rect, crop: crop, mipmapped: true), screen: board, compositor: compositor,
                device: device),
            try draw(
                screenFrame(size: narrowSize, rect: narrow, crop: crop, mipmapped: true), screen: board, compositor: compositor,
                device: device))
    }
    let lastColumn = greys(drawn, width: size.x, (41...140).map { SIMD2(160, $0) })
    let firstColumn = greys(drawn, width: size.x, (41...140).map { SIMD2(61, $0) })
    let lastRow = greys(drawn, width: size.x, (61...160).map { SIMD2($0, 140) })
    let centre = greys(drawn, width: size.x, (90...110).map { SIMD2($0, 90) })
    for (name, values) in [("last column", lastColumn), ("first column", firstColumn), ("last row", lastRow), ("centre", centre)] {
        #expect(values.allSatisfy { abs($0 - 127) <= 8 }, "\(name) from \(values.min()!) to \(values.max()!)")
    }
    for (name, x) in [("last column", 160), ("first column", 61), ("centre", 110)] {
        let values = greys(across, width: narrowSize.x, (16...383).map { SIMD2(x, $0) })
        #expect(values.allSatisfy { abs($0 - 127) <= 8 }, "1/3.7 across, \(name) from \(values.min()!) to \(values.max()!)")
    }
}

/// What `mipmappedFramesInFlightGiveTheSameBytes` saw in one round.
private struct InFlightRound: Sendable {
    /// The copies the six frames made, encoded before any was committed.
    var made: Int
    /// Whether each frame drew what it draws alone.
    var matches: [Bool]
    /// The copies free once every frame's completion was called.
    var free: Int
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedFramesInFlightGiveTheSameBytes() async throws {
    // Frames encoded before the GPU finishes any each get a copy of their own: six frames of six screens, one of another
    // size, encoded before any is committed, make six copies, and each draws its own screen, as it does alone. Once they
    // are done, the next six use those copies again.
    let rounds = try await offThePool { () throws -> [InFlightRound] in
        let device = try metalDevice()
        let compositor = try Compositor(device: device)
        let reference = try Compositor(device: device)
        let frame = screenFrame(size: SIMD2(320, 180), rect: Rect(x: 60, y: 40, width: 200, height: 100), mipmapped: true)
        let screens = try (0..<6).map { i in
            let colour = SIMD4<UInt8>(UInt8(40 * i), UInt8(255 - 40 * i), UInt8(i % 2 * 255), 255)
            return try texture(device, width: i == 3 ? 370 : 740, height: i == 3 ? 185 : 370) { _, _ in colour }
        }
        let expected = try screens.map { try draw(frame, screen: $0, compositor: reference, device: device) }
        let cursor = try CursorSprite.makeTexture(device: device)
        guard let queue = device.makeCommandQueue() else { throw TestSupportError.missing("command queue") }
        return try (0..<2).map { _ in
            let before = compositor.mipmappedCopiesCount.made
            var targets: [any MTLTexture] = []
            var buffers: [any MTLCommandBuffer] = []
            for screen in screens {
                let target = try target(for: frame, device: device)
                guard let commandBuffer = queue.makeCommandBuffer() else { throw TestSupportError.missing("command buffer") }
                try compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
                targets.append(target)
                buffers.append(commandBuffer)
            }
            let made = compositor.mipmappedCopiesCount.made - before
            buffers.forEach { $0.commit() }
            let matches = buffers.indices.map { i in
                buffers[i].waitUntilCompleted()
                return buffers[i].status == .completed && bytes(of: targets[i]) == expected[i]
            }
            // Each comes back when its completion is called, which can be after `waitUntilCompleted` returns.
            let deadline = Date().addingTimeInterval(5)
            while compositor.mipmappedCopiesCount.free < 6, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            return InFlightRound(made: made, matches: matches, free: compositor.mipmappedCopiesCount.free)
        }
    }
    // None is done while they are encoded, as none is committed: a copy each, new in the first round, used again in the
    // second.
    #expect(rounds.map(\.made) == [6, 0])
    #expect(rounds.allSatisfy { $0.matches == Array(repeating: true, count: 6) }, "\(rounds.map(\.matches))")
    #expect(rounds.map(\.free) == [6, 6])
}

/// What `mipmappedCopiesOfOldSizesAreLetGo` saw after each frame.
private struct CopiesAfterFrame: Sendable, Equatable {
    var made: Int
    var free: Int
    var freeSizes: Int
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedCopiesOfOldSizesAreLetGo() async throws {
    // A crop of another size in every frame, as while a change of geometry moves it: only the copies of the last two
    // sizes stay, the others' memory goes (Task 27's review: up to six copies of about 45 MB at 4K stayed). A size asked
    // for again after that makes a new copy.
    let seen = try await offThePool { () throws -> [CopiesAfterFrame] in
        let device = try metalDevice()
        let compositor = try Compositor(device: device)
        let screen = try texture(device, width: 740, height: 370) { _, _ in SIMD4<UInt8>(40, 200, 90, 255) }
        let cursor = try CursorSprite.makeTexture(device: device)
        guard let queue = device.makeCommandQueue() else { throw TestSupportError.missing("command queue") }
        return try [0.9, 0.8, 0.7, 0.6, 0.9].enumerated().map { k, width in
            let frame = screenFrame(
                size: SIMD2(320, 180), rect: Rect(x: 60, y: 40, width: 200 * width, height: 100),
                crop: Rect(x: 0, y: 0, width: width, height: 1), mipmapped: true)
            let target = try target(for: frame, device: device)
            guard let commandBuffer = queue.makeCommandBuffer() else { throw TestSupportError.missing("command buffer") }
            try compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            // The copy comes back when the frame's completion is called, which can be after `waitUntilCompleted`.
            let deadline = Date().addingTimeInterval(5)
            while compositor.mipmappedCopiesCount.free < min(k + 1, 2), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let count = compositor.mipmappedCopiesCount
            return CopiesAfterFrame(made: count.made, free: count.free, freeSizes: compositor.mipmappedCopiesFreeSizes)
        }
    }
    #expect(seen.map(\.made) == [1, 2, 3, 4, 5])
    #expect(seen.map(\.free) == [1, 2, 2, 2, 2])
    #expect(seen.map(\.freeSizes) == [1, 2, 2, 2, 2])
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mipmappedAreaShowsNothingOutsideIt() async throws {
    // An Area's crop of a 400 × 300 frame, its borders on no pixel and no power of two: blue in the pixels wholly inside
    // it, red in those wholly outside, green in those its borders cut. Drawn over black at several scales and fractional
    // positions. With mipmaps, rounded inward to whole pixels, no output pixel has any red or green, not even blended at
    // the edge; bilinear, as in 1a, no red (it reads half a texel inside the crop, so the pixels it cuts blend in).
    let crop = Rect(x: 66.4 / 400, y: 37.3 / 300, width: 201.7 / 400, height: 150.2 / 300)
    let found = try await offThePool { () throws -> [String] in
        let device = try metalDevice()
        let compositor = try Compositor(device: device)
        // Wholly inside: columns 67...267 and rows 38...186; cut: column 66 and 268, rows 37 and 187.
        let frame = try texture(device, width: 400, height: 300) { x, y in
            if (67..<268).contains(x), (38..<187).contains(y) { return [255, 0, 0, 255] }
            if (66...268).contains(x), (37...187).contains(y) { return [0, 255, 0, 255] }
            return [0, 0, 255, 255]
        }
        let size = SIMD2(320, 240)
        var found: [String] = []
        for scale: Double in [1, 1 / 1.5, 1 / 3, 1 / 3.7, 1 / 7, 1 / 8] {
            for offset: Double in [0, 0.25, 0.5] {
                let rect = Rect(x: 40 + offset, y: 20 + offset, width: 201.7 * scale, height: 150.2 * scale)
                for mipmapped in [true, false] {
                    let bytes = try draw(
                        screenFrame(size: size, rect: rect, crop: crop, mipmapped: mipmapped), screen: frame, compositor: compositor,
                        device: device)
                    let red = stride(from: 2, to: bytes.count, by: 4).map { bytes[$0] }.max()!
                    let green = stride(from: 1, to: bytes.count, by: 4).map { bytes[$0] }.max()!
                    let blue = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }.max()!
                    let name = "\(mipmapped ? "mipmapped" : "bilinear") at \(rect)"
                    if red > 1 { found.append("\(name): red \(red)") }
                    if mipmapped, green > 1 { found.append("\(name): green \(green)") }
                    // The Area is drawn.
                    if blue < 250 { found.append("\(name): blue only \(blue)") }
                }
            }
        }
        return found
    }
    #expect(found.isEmpty, "\(found)")
}
