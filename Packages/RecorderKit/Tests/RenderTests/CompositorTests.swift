// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// A `.bgra8Unorm` texture whose pixel at (`x`, `y`) is `bgra(x, y)`.
private func texture(
    _ device: any MTLDevice, width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> SIMD4<UInt8>
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = bgra(x, y)
            bytes += [pixel.x, pixel.y, pixel.z, pixel.w]
        }
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// A `.bgra8Unorm` texture of one colour, given as BGRA bytes.
private func solidTexture(_ device: any MTLDevice, width: Int, height: Int, bgra: SIMD4<UInt8>) throws -> any MTLTexture {
    try texture(device, width: width, height: height) { _, _ in bgra }
}

private let red: SIMD4<UInt8> = [0, 0, 255, 255]
private let green: SIMD4<UInt8> = [0, 255, 0, 255]
private let blue: SIMD4<UInt8> = [255, 0, 0, 255]

private func float(_ pixel: SIMD4<UInt8>) -> SIMD4<Float> {
    SIMD4(Float(pixel.x), Float(pixel.y), Float(pixel.z), Float(pixel.w))
}

private func draw(
    _ frame: RenderFrame, screen: (any MTLTexture)?, camera: (any MTLTexture)? = nil, device: any MTLDevice
) throws -> [UInt8] {
    let compositor = try Compositor(device: device)
    let cursor = try CursorSprite.makeTexture(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: descriptor))
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    try compositor.encode(frame, screen: screen, camera: camera, cursor: cursor, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
    target.getBytes(
        &bytes, bytesPerRow: frame.outputSize.x * 4,
        from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y), mipmapLevel: 0)
    return bytes
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func compositorDrawsBackgroundScreenAndCursor() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let style = StyleV0()
    let size = SIMD2(320, 180)
    let rect = Rect(x: 40, y: 30, width: 240, height: 120)
    let cursor = CursorLayer(hotspot: [200, 100], height: 40)
    let frame = RenderFrame(
        outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
        gradientAngleDegrees: style.gradientAngleDegrees,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 12),
        cursor: cursor)
    let screen = try solidTexture(device, width: 64, height: 36, bgra: red)
    let bytes = try draw(frame, screen: screen, device: device)
    func at(_ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
    func background(_ x: Int, _ y: Int) -> SIMD4<Float> {
        expectedBackground(
            x: x, y: y, size: size, start: style.gradientStart, end: style.gradientEnd,
            angleDegrees: style.gradientAngleDegrees)
    }

    // Background, in both corners of the gradient.
    #expect(isClose(at(2, 2), background(2, 2)))
    #expect(isClose(at(317, 177), background(317, 177)))
    #expect(isClose(at(160, 10), background(160, 10)))
    // The screen fills its rect…
    #expect(isClose(at(160, 90), [0, 0, 255, 255]))
    #expect(isClose(at(41, 90), [0, 0, 255, 255]))
    #expect(isClose(at(160, 31), [0, 0, 255, 255]))
    // …except its rounded corners, and nothing outside it.
    #expect(isClose(at(40, 30), background(40, 30)))
    #expect(isClose(at(279, 149), background(279, 149)))
    #expect(isClose(at(38, 90), background(38, 90)))
    // The cursor: a dark arrow body below and right of its tip, transparent beside it.
    let body = at(Int(cursor.hotspot.x + 0.15 * cursor.height), Int(cursor.hotspot.y + 0.45 * cursor.height))
    #expect(body.x < 40 && body.y < 40 && body.z < 40 && body.w == 255)
    #expect(isClose(at(Int(cursor.hotspot.x + 0.6 * cursor.height), Int(cursor.hotspot.y + 0.2 * cursor.height)), [0, 0, 255, 255]))
    // Everything is opaque.
    #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func compositorWithoutScreenOrCursorDrawsOnlyTheBackground() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let style = StyleV0()
    let size = SIMD2(64, 36)
    let withLayers = RenderFrame(
        outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
        gradientAngleDegrees: style.gradientAngleDegrees,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 8, y: 8, width: 48, height: 20), cornerRadius: 2))
    var bare = withLayers
    bare.screen = nil
    // A screen layer without a texture (no frame yet) draws like no screen layer at all.
    let noTexture = try draw(withLayers, screen: nil, device: device)
    let background = try draw(bare, screen: nil, device: device)
    #expect(noTexture == background)
    for (x, y) in [(0, 0), (32, 18), (63, 35)] {
        let expected = expectedBackground(
            x: x, y: y, size: size, start: style.gradientStart, end: style.gradientEnd,
            angleDegrees: style.gradientAngleDegrees)
        #expect(isClose(pixel(background, width: size.x, x: x, y: y), expected))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cursorSpriteIsAPremultipliedArrowWithItsTipAtTheOrigin() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try CursorSprite.makeTexture(device: device)
    #expect(texture.width == 96 && texture.height == 128)
    #expect(texture.pixelFormat == .bgra8Unorm)
    #expect(CursorSprite.hotspot == [0, 0])
    #expect(CursorSprite.aspect == 0.75)
    var bytes = [UInt8](repeating: 0, count: 96 * 128 * 4)
    texture.getBytes(&bytes, bytesPerRow: 96 * 4, from: MTLRegionMake2D(0, 0, 96, 128), mipmapLevel: 0)
    // Premultiplied: no channel above alpha.
    #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy { max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) <= bytes[$0 + 3] })
    // Opaque near the tip, transparent in the far corners.
    #expect(pixel(bytes, width: 96, x: 6, y: 8).w == 255)
    #expect(pixel(bytes, width: 96, x: 95, y: 0).w == 0)
    #expect(pixel(bytes, width: 96, x: 95, y: 127).w == 0)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func compositorDrawsOnlyTheCropOfTheScreen() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let style = StyleV0()
    let size = SIMD2(320, 180)
    let rect = Rect(x: 40, y: 30, width: 240, height: 120)
    // 100×100: red on the left half, blue on the right half, and green in the bottom row.
    let screen = try texture(device, width: 100, height: 100) { x, y in y == 99 ? green : x < 50 ? red : blue }
    let frame = RenderFrame(
        outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
        gradientAngleDegrees: style.gradientAngleDegrees,
        screen: ScreenLayer(
            trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 0, crop: Rect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
    let bytes = try draw(frame, screen: screen, device: device)
    // The top-right quarter of the frame fills the whole rect: blue, to its edges, without the red half on its left
    // nor the green row below it, not even blended in by the filter or the antialiased edge.
    for y in 30..<150 {
        for x in 40..<280 {
            #expect(isClose(pixel(bytes, width: size.x, x: x, y: y), float(blue)), "at (\(x), \(y))")
        }
    }
    let gradient = try draw(
        RenderFrame(
            outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
            gradientAngleDegrees: style.gradientAngleDegrees),
        screen: screen, device: device)
    // Its antialiased edge, outside the rect, blends only that blue into the background.
    for y in 29...150 {
        for x in [39, 280] {
            let edge = pixel(bytes, width: size.x, x: x, y: y), under = pixel(gradient, width: size.x, x: x, y: y)
            #expect(Int(edge.z) <= Int(under.z) + 1 && Int(edge.y) <= Int(under.y) + 1, "red or green at (\(x), \(y)): \(edge)")
        }
    }
    for x in 39...280 {
        for y in [29, 150] {
            let edge = pixel(bytes, width: size.x, x: x, y: y), under = pixel(gradient, width: size.x, x: x, y: y)
            #expect(Int(edge.z) <= Int(under.z) + 1 && Int(edge.y) <= Int(under.y) + 1, "red or green at (\(x), \(y)): \(edge)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func compositorDrawsTheCameraAspectFilledInACircle() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let style = StyleV0()
    let size = SIMD2(320, 180)
    let rect = Rect(x: 160, y: 40, width: 120, height: 120)
    let centre = SIMD2(220.0, 100.0)
    var below = RenderFrame(
        outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
        gradientAngleDegrees: style.gradientAngleDegrees,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 20, y: 20, width: 280, height: 140), cornerRadius: 0),
        cursor: CursorLayer(hotspot: [200, 70], height: 40))
    var frame = below
    frame.camera = CameraLayer(trackID: cameraID, sourceTime: base, rect: rect, cornerRadius: 60)
    below.camera = nil
    let screen = try solidTexture(device, width: 64, height: 36, bgra: red)
    // 400×300, 4:3: green stripes of 50 px on the left and on the right, blue between them. Filling a square, the
    // middle 300 px show.
    let camera = try texture(device, width: 400, height: 300) { x, _ in x < 50 || x >= 350 ? green : blue }
    let bytes = try draw(frame, screen: screen, camera: camera, device: device)
    let under = try draw(below, screen: screen, device: device)
    func at(_ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }

    #expect(isClose(at(220, 100), float(blue)))
    var inside = 0
    for y in 40..<160 {
        for x in 160..<280 {
            let distance = ((SIMD2(Double(x), Double(y)) + 0.5 - centre) * (SIMD2(Double(x), Double(y)) + 0.5 - centre)).sum().squareRoot()
            guard distance <= 59 else { continue }
            inside += 1
            let p = at(x, y)
            #expect(p.y < 128, "green at (\(x), \(y)): \(p)")
            #expect(isClose(p, float(blue)), "at (\(x), \(y)): \(p)")
        }
    }
    #expect(inside > 10_000)
    // The camera is over the cursor, which it hides (the arrow's body is inside the circle)…
    let body = pixel(under, width: size.x, x: 206, y: 88)
    #expect(body.x < 40 && body.y < 40 && body.z < 40)
    #expect(isClose(at(206, 88), float(blue)))
    // …and outside the circle, in the corners of its rect and around it, what is below shows unchanged.
    for (x, y) in [(161, 41), (278, 41), (161, 158), (278, 158), (159, 100), (281, 100), (220, 38), (220, 162)] {
        #expect(at(x, y) == pixel(under, width: size.x, x: x, y: y), "at (\(x), \(y))")
    }
}
