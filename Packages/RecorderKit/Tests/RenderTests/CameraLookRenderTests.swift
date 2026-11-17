// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `DrawCounts` and the compositor's counting `encode`.
@testable import Render
import SyntheticCapture
import Testing

// The camera's look (1c design §14.3): its picture mirrored, its border inside its edge and its shadow under it, all
// measured against the output's short side, and the bubble measured against the short side too (§5.2). With the legacy
// values (not mirrored, no border, no shadow, the height), the frame, its bytes and what the compositor draws are 1b's.
// Over a take of a blue screen and a camera whose left half is red and right half green.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
/// The background of every document here: one colour, the same under every pixel.
private let backdrop = RGBA(0.25, 0.25, 0.25, 1)

/// `sample` painted with `bgra(x)` across each row (a `VideoSegmentSpec.transform`).
private func painting(_ sample: CMSampleBuffer, _ bgra: (_ x: Int, _ width: Int) -> UInt32) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for x in 0..<width { row[x] = bgra(x, width) }
    }
    return sample
}

/// Pure blue.
@Sendable private func paintingBlue(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    painting(sample) { _, _ in 0xFF00_00FF }  // BGRA (255, 0, 0, 255)
}

/// The left half pure red, the right half pure green.
@Sendable private func paintingRedAndGreen(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    painting(sample) { x, width in x < width / 2 ? 0xFFFF_0000 : 0xFF00_FF00 }  // BGRA (0, 0, 255, 255), (0, 255, 0, 255)
}

/// A take of one second: a blue screen, and a camera red on its left half and green on its right half.
private func cameraProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame),
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: paintingBlue)])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource,
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: paintingRedAndGreen)])
    return try builder.write()
}

/// A take of 10 s with a screen and a camera, without files: for what the evaluator works out.
private func cameraTake() -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil, segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 10))]),
    ])
}

/// The legacy document of `take` on `backdrop`, with `change` made to its camera.
private func document(of take: TakeRecord, _ change: (inout CameraPlan) -> Void = { _ in }) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.style.background = .color(backdrop)
    change(&document.camera)
    return document
}

/// The frame of `document` at 0.5 s in an output of `size`.
private func frame(_ take: TakeRecord, _ document: EditDocument, size: SIMD2<Int>) -> RenderFrame {
    FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: 0.5)
}

/// The bytes of `document`'s frame at 0.5 s in an output of `size`, drawn from the take's video.
private func render(_ project: LoadedProject, _ document: EditDocument, size: SIMD2<Int>) async throws -> [UInt8] {
    let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
    return try await offThePool { try renderer.renderBytes(at: 0.5) }
}

/// Whether pixel (`x`, `y`) touches `rect` (output pixels).
private func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
    let left = Double(x), top = Double(y)
    return left + 1 > rect.x && left < rect.x + rect.width && top + 1 > rect.y && top < rect.y + rect.height
}

/// How far the centre of pixel (`x`, `y`) is from `centre`.
private func distance(_ x: Int, _ y: Int, from centre: SIMD2<Double>) -> Double {
    let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
    return (d * d).sum().squareRoot()
}

private func isRed(_ p: SIMD4<UInt8>) -> Bool { p.z > 180 && p.y < 80 && p.x < 80 }
private func isGreen(_ p: SIMD4<UInt8>) -> Bool { p.y > 150 && p.z < 80 && p.x < 80 }

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

/// Draws frames with a compositor of its own over a blue screen and a camera red on its left half and green on its
/// right half (textures, not video), counting what it draws. It checks nothing itself: it runs off the cooperative pool.
private struct Drawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let camera: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestSupportError.missing("Metal")
        }
        self.device = device
        self.queue = queue
        compositor = try Compositor(device: device)
        screen = try texture(device, width: 64, height: 36) { _, _ in [255, 0, 0, 255] }
        camera = try texture(device, width: 64, height: 36) { x, _ in x < 32 ? [0, 0, 255, 255] : [0, 255, 0, 255] }
        cursor = try CursorSprite.makeTexture(device: device)
    }

    /// `frame` as BGRA bytes, and what was drawn.
    func draw(_ frame: RenderFrame) throws -> (bytes: [UInt8], counts: DrawCounts) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw TestSupportError.missing("Metal objects")
        }
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, camera: camera, cursor: cursor, into: target, commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
        target.getBytes(
            &bytes, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y),
            mipmapLevel: 0)
        return (bytes, counts)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func mirrorIsTheVideoFlipped() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cameraProject(in: dir)
        // A circle of 0.25 at the middle of the bottom of a 1536 × 1024 output: 256 px of side from x 640, centred on the
        // boundary between pixels 767 and 768, so pixel x of the rect mirrors onto pixel 1535 − x. What is under it (the
        // blue screen's bottom edge, the background) is the same on both sides.
        let size = SIMD2(1536, 1024)
        let style = CameraStyle(shape: .circle, size: 0.25, anchor: .bottom)
        let plain = document(of: project.take) { $0.initial[takeID] = style }
        let mirrored = document(of: project.take) { camera in
            camera.initial[takeID] = style
            camera.mirror = true
        }
        let layer = try #require(frame(project.take, mirrored, size: size).camera)
        #expect(layer.mirror)
        #expect(layer.rect.x == 640 && layer.rect.width == 256 && layer.rect.height == 256)
        // The bubble's place does not change, only the picture in it.
        var unmirrored = layer
        unmirrored.mirror = false
        #expect(frame(project.take, plain, size: size).camera == unmirrored)

        let a = try await render(project, plain, size: size)
        let b = try await render(project, mirrored, size: size)
        func at(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
        // The left half of the bubble is green and the right half red; without the mirror, the other way round.
        let row = Int(layer.rect.y + layer.rect.height / 2)
        #expect(isGreen(at(b, 700, row)) && isRed(at(a, 700, row)), "\(at(b, 700, row)), \(at(a, 700, row))")
        #expect(isRed(at(b, 836, row)) && isGreen(at(a, 836, row)), "\(at(b, 836, row)), \(at(a, 836, row))")
        // Inside the rect, the mirrored frame is the plain one flipped about the rect's centre, byte for byte; outside it, the
        // plain one.
        var different: [String] = []
        for y in 0..<size.y {
            for x in 0..<size.x {
                let expected = touches(x, y, layer.rect) ? at(a, 1535 - x, y) : at(a, x, y)
                if at(b, x, y) != expected { different.append("(\(x), \(y)): \(at(b, x, y)) for \(expected)") }
            }
        }
        #expect(different.isEmpty, "\(different.count) pixels: \(different.prefix(4))")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func legacyLookDrawsNothingNew() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cameraProject(in: dir)
        let size = SIMD2(1280, 720)
        let legacy = document(of: project.take)
        let legacyFrame = frame(project.take, legacy, size: size)
        // The camera layer of 1b: its four fields, and the others at the values that draw nothing new.
        let camera = try #require(legacyFrame.camera)
        #expect(
            camera == CameraLayer(trackID: cameraID, sourceTime: camera.sourceTime, rect: camera.rect, cornerRadius: camera.cornerRadius))
        #expect(!camera.mirror && camera.opacity == 1 && camera.border == nil && camera.shadow == nil)
        let drawer = try Drawer()
        let drawn = try await offThePool { try drawer.draw(legacyFrame) }
        #expect(drawn.counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cameras: 1), "\(drawn.counts)")
        let bytes = try await render(project, legacy, size: size)

        // The legacy values said again (and a border of no width in another colour), the values read as them (below 0, not
        // a number), and the short side in a wide output, which is its height: the same frame, the same drawings, the same
        // bytes.
        let same: [(String, (inout CameraPlan) -> Void)] = [
            ("the legacy values", { camera in
                camera.mirror = false
                camera.border = CameraBorder(width: 0, color: RGBA(1, 0, 0, 1))
                camera.shadow = 0
                camera.sizeReference = .height
            }),
            ("below 0", { camera in
                camera.border.width = -0.5
                camera.shadow = -0.5
            }),
            ("not a number", { camera in
                camera.border.width = .nan
                camera.shadow = .nan
            }),
            ("the short side of a wide output", { $0.sizeReference = .shortSide }),
        ]
        for (name, change) in same {
            let edited = document(of: project.take, change)
            let editedFrame = frame(project.take, edited, size: size)
            #expect(editedFrame == legacyFrame, "\(name)")
            #expect(try await offThePool { try drawer.draw(editedFrame) }.counts == drawn.counts, "\(name)")
            #expect(try await render(project, edited, size: size) == bytes, "\(name)")
        }

        // The look adds drawings to the one pass, never a pass.
        let styled = frame(project.take, document(of: project.take) { camera in
            camera.mirror = true
            camera.border.width = 0.5
            camera.shadow = 0.4
        }, size: size)
        let styledCounts = try await offThePool { try drawer.draw(styled) }.counts
        #expect(styledCounts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: 1, cameras: 1, cameraShadows: 1, cameraBorders: 1))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func borderIsAnInnerStroke() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cameraProject(in: dir)
        let size = SIMD2(1920, 1080)
        let plain = document(of: project.take)
        let white = document(of: project.take) { $0.border = CameraBorder(width: 0.5, color: RGBA(1, 1, 1, 1)) }
        let layer = try #require(frame(project.take, white, size: size).camera)
        let border = try #require(layer.border)
        // 0.5 × 0.012 × 1080.
        #expect(abs(border.width - 6.48) <= 1e-9, "\(border.width)")
        #expect(border.color == SIMD4(1, 1, 1, 1))
        // The camera's rect does not change.
        var unbordered = layer
        unbordered.border = nil
        #expect(frame(project.take, plain, size: size).camera == unbordered)

        let a = try await render(project, plain, size: size)
        let b = try await render(project, white, size: size)
        func at(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
        let centre = SIMD2(layer.rect.x, layer.rect.y) + SIMD2(layer.rect.width, layer.rect.height) / 2
        let radius = layer.rect.width / 2
        var stroke = 0
        var wrong: [String] = []
        for y in Int(layer.rect.y) - 3...Int(layer.rect.y + layer.rect.height) + 3 {
            for x in Int(layer.rect.x) - 3..<size.x {
                let d = distance(x, y, from: centre)
                if d >= radius + 1 || d <= radius - border.width - 1 {
                    // Outside, what is under the camera (the background or the screen); well inside, the picture.
                    if at(b, x, y) != at(a, x, y) { wrong.append("(\(x), \(y)) at \(d): \(at(b, x, y)), not \(at(a, x, y))") }
                } else if d >= radius - border.width + 1 && d <= radius - 1 {
                    stroke += 1
                    if at(b, x, y) != [255, 255, 255, 255] { wrong.append("(\(x), \(y)) at \(d) not white: \(at(b, x, y))") }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(4))")
        // A ring 4.48 px wide around a circle of 129.6 px: about 3 500 pixels.
        #expect(stroke > 3_000, "\(stroke)")

        // A border of a colour that is not opaque blends over the picture, not over what is under the camera.
        let halfRed = document(of: project.take) { $0.border = CameraBorder(width: 0.5, color: RGBA(1, 0, 0, 0.5)) }
        let c = try await render(project, halfRed, size: size)
        let x = Int(centre.x), y = Int(layer.rect.y + 3)
        let picture = at(a, x, y)
        let expected = SIMD4<Float>(Float(picture.x) / 2, Float(picture.y) / 2, Float(picture.z) / 2 + 127.5, 255)
        #expect(isClose(at(c, x, y), expected, tolerance: 1), "\(at(c, x, y)), not \(expected)")
    }
}

@Test func shadowFollowsTheShortSideFormula() throws {
    let take = cameraTake()
    let size = SIMD2(1080, 1920)
    #expect(frame(take, document(of: take), size: size).camera?.shadow == nil)

    let shadowed = try #require(frame(take, document(of: take) { $0.shadow = 0.4 }, size: size).camera)
    let shadow = try #require(shadowed.shadow)
    // k = 0.4, s = 1080: opacity 0.55·k, σ (0.004 + 0.016·k)·s, down by 0.010·k·s.
    #expect(abs(shadow.opacity - 0.22) <= 1e-9, "\(shadow.opacity)")
    #expect(abs(shadow.sigma - 11.232) <= 1e-9, "\(shadow.sigma)")
    #expect(abs(shadow.offsetY - 4.32) <= 1e-9, "\(shadow.offsetY)")
    // Cast by the camera, with its corners.
    #expect(shadow.rect == shadowed.rect && shadow.cornerRadius == shadowed.cornerRadius)

    // The slider's ends: 1 at most; nothing at 0, below it or not a number.
    let full = try #require(frame(take, document(of: take) { $0.shadow = 3 }, size: size).camera?.shadow)
    #expect(abs(full.opacity - 0.55) <= 1e-9 && abs(full.sigma - 0.02 * 1080) <= 1e-9 && abs(full.offsetY - 0.01 * 1080) <= 1e-9)
    for value in [0, -0.5, .nan] {
        #expect(frame(take, document(of: take) { $0.shadow = value }, size: size).camera?.shadow == nil, "\(value)")
    }
}

@Test func shortSideBubbleMeasuresTheSameInEveryAspect() async throws {
    let take = cameraTake()
    let shortSide = document(of: take) { $0.sizeReference = .shortSide }
    let wide = try #require(frame(take, shortSide, size: SIMD2(1920, 1080)).camera)
    let tall = try #require(frame(take, shortSide, size: SIMD2(1080, 1920)).camera)
    // A Medium circle: 0.24 × 1080 in both, at 0.032 × 1080 from the bottom right corner.
    #expect(abs(wide.rect.width - 259.2) <= 1e-9 && abs(tall.rect.width - 259.2) <= 1e-9)
    #expect(tall.rect.width == wide.rect.width && tall.rect.height == wide.rect.height)
    #expect(tall.cornerRadius == wide.cornerRadius)
    #expect(abs(tall.rect.x - (1080 - 259.2 - 34.56)) <= 1e-9 && abs(tall.rect.y - (1920 - 259.2 - 34.56)) <= 1e-9)
    // A wide output measures the same against both.
    #expect(wide == frame(take, document(of: take), size: SIMD2(1920, 1080)).camera)
}

@Test func heightReferenceKeepsTodaysBubble() async throws {
    let take = cameraTake()
    let size = SIMD2(1080, 1920)
    let layer = try #require(frame(take, document(of: take) { $0.sizeReference = .height }, size: size).camera)
    // 1b's bubble, against the height: 0.24 × 1920 = 460.8 px of side.
    let today = CameraStyle.default.frame(in: Rect(x: 0, y: 0, width: 1080, height: 1920))
    #expect(layer.rect == today.rect && layer.cornerRadius == today.cornerRadius)
    #expect(abs(layer.rect.width - 460.8) <= 1e-9)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func shadowIsDrawnUnderTheCamera() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await cameraProject(in: dir)
        // In 9:16 the bubble at the bottom right is over the background, below the screen.
        let size = SIMD2(1080, 1920)
        let plain = document(of: project.take)
        let shadowed = document(of: project.take) { $0.shadow = 0.4 }
        let layer = try #require(frame(project.take, shadowed, size: size).camera)
        let shadow = try #require(layer.shadow)
        let a = try await render(project, plain, size: size)
        let b = try await render(project, shadowed, size: size)
        func at(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
        let centre = SIMD2(layer.rect.x, layer.rect.y) + SIMD2(layer.rect.width, layer.rect.height) / 2
        let radius = layer.rect.width / 2
        let reach = 3 * shadow.sigma + 1
        var wrong: [String] = []
        var darker = 0
        for y in Int(layer.rect.y - reach) - 2..<size.y {
            for x in Int(layer.rect.x - reach) - 2..<size.x {
                let d = distance(x, y, from: centre), shown = at(b, x, y)
                if d <= radius - 1 {
                    // Under the camera it does not show: the camera covers it.
                    if shown != at(a, x, y) { wrong.append("(\(x), \(y)) inside: \(shown), not \(at(a, x, y))") }
                } else if d >= radius + 1 {
                    // Around it, the background darkened by the shadow's alpha (`ShadowMath`, the GPU's arithmetic on the CPU).
                    let alpha = Float(ShadowMath.alpha(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5), shadow))
                    let under = at(a, x, y)
                    let kept = 1 - alpha
                    let expected = SIMD4<Float>(Float(under.x) * kept, Float(under.y) * kept, Float(under.z) * kept, 255)
                    if !isClose(shown, expected, tolerance: 1) { wrong.append("(\(x), \(y)) around: \(shown), not \(expected)") }
                    if shown.x < under.x { darker += 1 }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(4))")
        #expect(darker > 2_000, "\(darker)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func opacityBlendsTheCameraWithItsLook() async throws {
    let size = SIMD2(640, 360)
    let rect = Rect(x: 400, y: 160, width: 160, height: 160)
    let camera = CameraLayer(
        trackID: cameraID, sourceTime: base, rect: rect, cornerRadius: 80, mirror: true,
        border: CameraBorderLayer(width: 6, color: SIMD4(1, 1, 1, 1)),
        shadow: ShadowLayer(rect: rect, cornerRadius: 80, opacity: 0.5, sigma: 6, offsetY: 3))
    // A light background, the blue screen above y 320 and the circle from y 160 to 320, its shadow below it on the background.
    let below = RenderFrame(
        outputSize: size, gradientStart: SIMD4(0.8, 0.8, 0.8, 1), gradientEnd: SIMD4(0.8, 0.8, 0.8, 1), gradientAngleDegrees: 0,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 40, y: 40, width: 560, height: 280), cornerRadius: 0))
    func with(_ opacity: Double, blurred: Bool = false) -> RenderFrame {
        var frame = below
        frame.camera = camera
        frame.camera?.opacity = opacity
        // Two subsamples of the stage at rest: the motion blur's pass, which draws the camera into its target.
        if blurred { frame.subframes = Array(repeating: StageSubframe(stage: .identity(outputSize: size)), count: 2) }
        return frame
    }
    let drawer = try Drawer()
    let frames = [below, with(1), with(0.5), with(0), with(.nan), with(1, blurred: true), with(0.5, blurred: true)]
    let drawn = try await offThePool { try frames.map { try drawer.draw($0) } }
    let (none, opaque, half, hidden, notANumber) = (drawn[0], drawn[1], drawn[2], drawn[3], drawn[4])
    let (blurredOpaque, blurredHalf) = (drawn[5], drawn[6])
    func at(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
    func float(_ p: SIMD4<UInt8>) -> SIMD4<Float> { SIMD4(Float(p.x), Float(p.y), Float(p.z), Float(p.w)) }
    // Hidden, or not a number: nothing of it, its shadow included.
    #expect(hidden.bytes == none.bytes && notANumber.bytes == none.bytes)
    #expect(hidden.counts.cameras == 0 && hidden.counts.cameraShadows == 0)
    // Mirrored: the left of the circle green, the right red; inside the border, white.
    #expect(isGreen(at(opaque.bytes, 440, 240)) && isRed(at(opaque.bytes, 520, 240)))
    #expect(at(opaque.bytes, 480, 162) == [255, 255, 255, 255])
    // At half: the camera, its border and its shadow over what is under them, by half.
    for (x, y) in [(440, 240), (520, 240), (480, 162)] {
        let mixed = (float(at(opaque.bytes, x, y)) + float(at(none.bytes, x, y))) / 2
        #expect(isClose(at(half.bytes, x, y), mixed, tolerance: 1), "(\(x), \(y)): \(at(half.bytes, x, y)), not \(mixed)")
    }
    // The shadow, under the bottom of the circle: half as dark.
    let underneath = (x: 480, y: 324)
    let full = Float(at(none.bytes, underneath.x, underneath.y).x) - Float(at(opaque.bytes, underneath.x, underneath.y).x)
    let halved = Float(at(none.bytes, underneath.x, underneath.y).x) - Float(at(half.bytes, underneath.x, underneath.y).x)
    #expect(full > 6 && abs(halved - full / 2) <= 1, "\(full), \(halved)")
    // The motion blur's pass draws the same camera: inside it the same bytes, at half within a level of the direct pass.
    #expect(blurredOpaque.counts.accumulations == 2 && blurredOpaque.counts.cameras == 1 && blurredOpaque.counts.cameraBorders == 1)
    #expect(blurredOpaque.counts.cameraShadows == 1 && blurredOpaque.counts.renderPasses == 1)
    for (x, y) in [(440, 240), (520, 240), (480, 162)] {
        #expect(at(blurredOpaque.bytes, x, y) == at(opaque.bytes, x, y), "(\(x), \(y))")
        #expect(isClose(at(blurredHalf.bytes, x, y), float(at(half.bytes, x, y)), tolerance: 1), "(\(x), \(y))")
    }
    #expect(isClose(at(blurredOpaque.bytes, underneath.x, underneath.y), float(at(opaque.bytes, underneath.x, underneath.y)), tolerance: 1))
}
