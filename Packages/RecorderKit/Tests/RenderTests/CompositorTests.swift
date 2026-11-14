// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// A `.bgra8Unorm` texture of one colour, given as BGRA bytes.
private func solidTexture(_ device: any MTLDevice, width: Int, height: Int, bgra: SIMD4<UInt8>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let bytes = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { i, _ in bgra[i % 4] }
    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

private func draw(_ frame: RenderFrame, screen: (any MTLTexture)?, device: any MTLDevice) throws -> [UInt8] {
    let compositor = try Compositor(device: device)
    let cursor = try CursorSprite.makeTexture(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: descriptor))
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    compositor.encode(frame, screen: screen, cursor: cursor, into: target, commandBuffer: commandBuffer)
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
    let red = try solidTexture(device, width: 64, height: 36, bgra: [0, 0, 255, 255])
    let bytes = try draw(frame, screen: red, device: device)
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
