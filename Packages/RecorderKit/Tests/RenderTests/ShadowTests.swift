// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`.
@testable import Render
import SyntheticCapture
import Testing

// The shadow under the screen, or under the window with a frame (design §7.3): its values from the slider, nothing at
// 0, and the analytic shape the GPU draws against its formula on the CPU (`ShadowMath`).

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let white = RGBA(1, 1, 1, 1)

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// decodes, which blocks (`offThePool` in DocumentRenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// `sample` painted pure blue.
@Sendable private func paintingBlue(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFF00_00FF, count: width)  // BGRA (255, 0, 0, 255)
    }
    return sample
}

/// A take of one second of a blue screen.
private func screenProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame),
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: paintingBlue)])
    return try builder.write()
}

/// A `.bgra8Unorm` texture of one colour, given as BGRA bytes.
private func solidTexture(_ device: any MTLDevice, width: Int, height: Int, bgra: SIMD4<UInt8>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw TestSupportError.missing("texture") }
    let bytes = [UInt8]((0..<width * height).flatMap { _ in [bgra.x, bgra.y, bgra.z, bgra.w] })
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// Whether pixel (`x`, `y`) touches `rect` (output pixels).
private func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
    let left = Double(x), top = Double(y)
    return left + 1 > rect.x && left < rect.x + rect.width && top + 1 > rect.y && top < rect.y + rect.height
}

/// `frame` drawn by a compositor of its own over `screen`, as BGRA bytes; throws if the GPU does not complete it. It
/// checks nothing itself: it runs off the cooperative pool, away from the test's task.
private func draw(_ frame: RenderFrame, screen: (any MTLTexture)?, device: any MTLDevice) throws -> [UInt8] {
    let compositor = try Compositor(device: device)
    let cursor = try CursorSprite.makeTexture(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer()
    else { throw TestSupportError.missing("Metal objects") }
    try compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
    var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
    target.getBytes(
        &bytes, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y), mipmapLevel: 0)
    return bytes
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func shadowZeroDrawsNothing() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let size = SIMD2(640, 360)
        func document(shadow: Double) -> EditDocument {
            var document = EditDocument.legacy(for: project)
            document.style.background = .color(white)
            document.style.shadow = shadow
            return document
        }
        func frame(shadow: Double) -> RenderFrame {
            FrameEvaluator(take: project.take, events: project.events, document: document(shadow: shadow), outputSize: size).frame(at: 0.5)
        }
        func render(shadow: Double) async throws -> [UInt8] {
            let renderer = try FrameRenderer(project: project, document: document(shadow: shadow), outputSize: size)
            return try await offThePool { try renderer.renderBytes(at: 0.5) }
        }
        let shadowed = frame(shadow: 0.6)
        let layer = try #require(shadowed.shadow)
        let none = try await render(shadow: 0)
        // At 0 (and below it, or not a number, read as 0) there is no shadow layer, and the frame is otherwise the same.
        for shadow in [0, -0.5, .nan] {
            var expected = shadowed
            expected.shadow = nil
            #expect(frame(shadow: shadow) == expected, "shadow \(shadow)")
            #expect(try await render(shadow: shadow) == none, "shadow \(shadow)")
        }
        // A shadow changes only the pixels within its reach (3σ around its box), and some of them: the bytes without it
        // are those of the frame the shadow is drawn under.
        let drawn = try await render(shadow: 0.6)
        let reach = 3 * layer.sigma + 1
        let box = Rect(
            x: layer.rect.x - reach, y: layer.rect.y + layer.offsetY - reach, width: layer.rect.width + 2 * reach,
            height: layer.rect.height + 2 * reach)
        var changed = 0
        for y in 0..<size.y {
            for x in 0..<size.x {
                let inReach = touches(x, y, box)
                let same = pixel(drawn, width: size.x, x: x, y: y) == pixel(none, width: size.x, x: x, y: y)
                if !inReach { #expect(same, "(\(x), \(y)) out of the shadow's reach") }
                if !same { changed += 1 }
            }
        }
        #expect(changed > 1000)
    }
}

@Test func shadowValuesFromTheSlider() throws {
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 1))])])
    var document = EditDocument.legacy(take: take, events: [])
    let size = SIMD2(1920, 1080)
    func frame() -> RenderFrame { FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: 0.5) }
    #expect(frame().shadow == nil)

    document.style.shadow = 0.6
    let shadowed = frame()
    let shadow = try #require(shadowed.shadow)
    let screen = try #require(shadowed.screen)
    #expect(abs(shadow.opacity - 0.33) <= 1e-9)
    #expect(abs(shadow.sigma - 26.112) <= 1e-9)
    #expect(abs(shadow.offsetY - 11.52) <= 1e-9)
    // Under the screen, with its corners.
    #expect(shadow.rect == screen.rect && shadow.cornerRadius == screen.cornerRadius)

    // The slider's ends: 1 at most.
    document.style.shadow = 3
    let full = try #require(frame().shadow)
    #expect(abs(full.opacity - 0.55) <= 1e-9 && abs(full.sigma - 0.02 * 1920) <= 1e-9 && abs(full.offsetY - 0.01 * 1920) <= 1e-9)

    // With the macOS window frame, under the whole window, bar included, with its corners.
    document.style.shadow = 0.6
    document.style.frame = .macWindow(appearance: .light, title: "", buttons: true)
    let framed = frame()
    let window = try #require(framed.windowFrame)
    let underWindow = try #require(framed.shadow)
    #expect(underWindow.rect == window.rect && underWindow.cornerRadius == window.cornerRadius)
    #expect(underWindow.opacity == shadow.opacity && underWindow.sigma == shadow.sigma && underWindow.offsetY == shadow.offsetY)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func shadowMatchesItsCPUFormula() async throws {
    let size = SIMD2(320, 180)
    let rect = Rect(x: 70.3, y: 40.6, width: 180, height: 90)
    // s = 1 at 320 px: σ 6.4, 3.2 down, 0.55.
    let layer = ShadowLayer(rect: rect, cornerRadius: 14, opacity: 0.55, sigma: 6.4, offsetY: 3.2)
    let frame = RenderFrame(
        outputSize: size, gradientStart: .one, gradientEnd: .one, gradientAngleDegrees: 0,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 14), background: .color(.one), shadow: layer)
    let bytes = try await offThePool {
        guard let device = MTLCreateSystemDefaultDevice() else { throw TestSupportError.missing("Metal device") }
        return try draw(frame, screen: try solidTexture(device, width: 64, height: 32, bgra: [255, 0, 0, 255]), device: device)
    }

    // Over white, a pixel is 255 × (1 − α) in every channel: its alpha is what it lost. The pixels of the shadow's reach
    // outside the screen and its antialiased edge, 200 of them spread evenly.
    let reach = 3 * layer.sigma + 1
    // The screen and its antialiased edge.
    let edged = Rect(x: rect.x - 1, y: rect.y - 1, width: rect.width + 2, height: rect.height + 2)
    var outside: [SIMD2<Int>] = []
    for y in Int((rect.y + layer.offsetY - reach).rounded(.down))...Int((rect.y + rect.height + layer.offsetY + reach).rounded(.up)) {
        for x in Int((rect.x - reach).rounded(.down))...Int((rect.x + rect.width + reach).rounded(.up)) {
            if !touches(x, y, edged), (0..<size.x).contains(x), (0..<size.y).contains(y) { outside.append(SIMD2(x, y)) }
        }
    }
    let points = stride(from: 0, to: outside.count, by: outside.count / 200).prefix(200).map { outside[$0] }
    #expect(points.count == 200)
    var darkest = 0.0
    for point in points {
        let p = pixel(bytes, width: size.x, x: point.x, y: point.y)
        #expect(p.x == p.y && p.y == p.z && p.w == 255, "\(point): \(p)")
        let gpu = 255 - Double(p.y)
        let cpu = ShadowMath.alpha(at: SIMD2(Double(point.x) + 0.5, Double(point.y) + 0.5), layer) * 255
        #expect(abs(gpu - cpu) <= 1, "\(point): GPU \(gpu), CPU \(cpu)")
        darkest = max(darkest, cpu)
    }
    // The points see the shadow, darkest under the screen's bottom edge, where it is moved to.
    #expect(darkest > 0.25 * 255)
    let below = ShadowMath.alpha(at: SIMD2(rect.x + rect.width / 2, rect.y + rect.height + 2), layer)
    let above = ShadowMath.alpha(at: SIMD2(rect.x + rect.width / 2, rect.y - 2), layer)
    #expect(below > above && below > 0.3 && below < 0.55)
    // Far from the box, nothing; deep inside it, the opacity (the y integral's 4 samples sum to 0.9985 of it).
    #expect(ShadowMath.alpha(at: SIMD2(rect.x - 4 * layer.sigma, rect.y + 40), layer) < 0.001)
    #expect(abs(ShadowMath.alpha(at: SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2 + layer.offsetY), layer) - 0.55) < 0.002)
}

@Test func erfApproximationIsWithinItsBound() {
    var worst = 0.0
    for i in 0...10_000 {
        let x = Float(-4 + 8 * Double(i) / 10_000)
        worst = max(worst, abs(Double(ShadowMath.erf(x)) - Foundation.erf(Double(x))))
    }
    // 1.5e-7 of the formula, plus Float's rounding.
    #expect(worst <= 1e-6, "worst error \(worst)")
    #expect(ShadowMath.erf(-1) == -ShadowMath.erf(1))
    #expect(abs(ShadowMath.erf(0)) <= 1e-6)
    #expect(ShadowMath.ySamples == 4)
}
