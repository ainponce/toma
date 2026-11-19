// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `DrawCounts`, the compositor's counting `encode` and `CursorSprite`.
@testable import Render
import SyntheticCapture
import Testing

// The device frames (phase 2 design §6.7, `deviceFrame-1`): an iPhone, an iPad or a MacBook around the screen, dark or
// light, drawn with our own vectors, the zoom moving them with the screen, a card holding them whole.

private let portraitScreen = Rect(x: 0, y: 0, width: 390, height: 844)
private let backdrop = RGBA(0.2, 0.4, 0.6, 1)
private let backdropBGRA: SIMD4<Float> = [153, 102, 51, 255]

/// The BGRA colour of `hex` (`0xRRGGBB`), 0...255.
private func bgra(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4(Float(hex & 0xFF), Float((hex >> 8) & 0xFF), Float((hex >> 16) & 0xFF), 255)
}

/// A take of `seconds` on a display of `globalFrame`, with a camera when `camera`, without files.
private func deviceTake(globalFrame: Rect = portraitScreen, seconds: Double = 3, camera: Bool = false) -> TakeRecord {
    var tracks = [displayTrack(globalFrame: globalFrame, segments: [segment(start: base, end: base.adding(seconds: seconds))])]
    if camera {
        tracks.append(displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: seconds))]))
    }
    return makeTake(tracks: tracks)
}

/// The legacy document of `take` on `backdrop` with a `model` device of `finish`, and `change` made to it.
private func deviceDocument(
    _ take: TakeRecord, _ model: DeviceModel, _ finish: FrameAppearance = .dark, _ change: (inout EditDocument) -> Void = { _ in }
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.style.background = .color(backdrop)
    document.style.frame = .device(DeviceFrame(model: model, finish: finish))
    change(&document)
    return document
}

private func evaluated(_ take: TakeRecord, _ document: EditDocument, size: SIMD2<Int>, at t: Double = 1) -> RenderFrame {
    FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: t)
}

/// A compositor with a screen of one colour (or `screen`), and Toma's arrow.
private final class DeviceDrawer {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let cursor: any MTLTexture

    init(screen bgra: SIMD4<UInt8> = [255, 255, 255, 255], width: Int = 390, height: Int = 844) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8]((0..<width * height).flatMap { _ in [bgra.x, bgra.y, bgra.z, bgra.w] })
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        screen = texture
        cursor = try CursorSprite.makeTexture(device: device)
    }

    init(screen texture: any MTLTexture, device: any MTLDevice) throws {
        self.device = device
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        screen = texture
        cursor = try CursorSprite.makeTexture(device: device)
    }

    func draw(_ frame: RenderFrame, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return StageDrawing.bytes(of: target)
    }

    func draw(_ frame: RenderFrame) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, counts: &counts)
    }
}

private func at(_ bytes: [UInt8], _ size: SIMD2<Int>, _ point: SIMD2<Double>) -> SIMD4<UInt8> {
    pixel(bytes, width: size.x, x: Int(point.x), y: Int(point.y))
}

private func isClose(_ a: Rect, _ b: Rect, tolerance: Double = 1e-9) -> Bool {
    [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) <= tolerance }
}

/// How much darker than the backdrop a pixel is, in its darkest channel.
private func darkness(_ p: SIMD4<UInt8>) -> Float {
    max(backdropBGRA.x - Float(p.x), backdropBGRA.y - Float(p.y), backdropBGRA.z - Float(p.z))
}

@Test func theZoomKeepsToTheDevice() throws {
    let take = deviceTake()
    let host = base.adding(seconds: 1)
    for model in DeviceModel.allCases {
        let document = deviceDocument(take, model)
        let stage = StagePoints(take: take, events: [], document: document)
        let view = try #require(stage.shownScreen(at: host)?.view)
        let region = try #require(view.region)
        let rects = try #require(StageLayout.deviceRects(
            contentAspect: region.width / region.height, padding: document.style.padding, outputSize: stage.stageSize, model: model))
        // In stage units, the zoom keeps to the device's bounds and the cursor is placed on its screen.
        #expect(stage.screenRect(at: host) == rects.bounds, "\(model)")
        #expect(stage.rects(of: view).screen == rects.screen, "\(model)")
        // The render places the same device at its own size.
        let size = SIMD2(1280, 720)
        let layer = try #require(evaluated(take, document, size: size).deviceFrame, "\(model)")
        func pixels(_ r: Rect) -> Rect { Rect(x: r.x * 720, y: r.y * 720, width: r.width * 720, height: r.height * 720) }
        #expect(isClose(layer.rects.bounds, pixels(rects.bounds), tolerance: 1e-6), "\(model)")
        #expect(isClose(layer.rects.screen, pixels(rects.screen), tolerance: 1e-6), "\(model)")
    }
    // Following the cursor, the screen has no frame: it is placed as without one.
    var following = deviceDocument(take, .iPhone)
    following.style.reframe = .followCursor
    var none = following
    none.style.frame = .none
    let stage = StagePoints(take: take, events: [], document: following)
    #expect(stage.screenRect(at: host) == StagePoints(take: take, events: [], document: none).screenRect(at: host))
}

@Test func theFinishKeepsThePaths() {
    let take = deviceTake()
    let dark = deviceDocument(take, .iPhone, .dark)
    let paths = MotionPaths(take: take, events: [], document: dark)
    #expect(paths.areThePaths(of: deviceDocument(take, .iPhone, .light)))
    #expect(!paths.areThePaths(of: deviceDocument(take, .iPad, .dark)))
    var none = dark
    none.style.frame = .none
    #expect(!MotionPaths(take: take, events: [], document: none).areThePaths(of: dark))
    var following = dark
    following.style.reframe = .followCursor
    #expect(!paths.areThePaths(of: following))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func deviceFrameDrawsItsParts() throws {
    let take = deviceTake()
    let size = SIMD2(2560, 1440)
    let drawer = try DeviceDrawer()
    for (finish, band) in [(FrameAppearance.dark, bgra(0x2C2C2E)), (.light, bgra(0xD9D9DE))] {
        let frame = evaluated(take, deviceDocument(take, .iPhone, finish), size: size)
        let rects = try #require(frame.deviceFrame?.rects)
        #expect(frame.screen?.cornerRadius == rects.screenCornerRadius)
        let bytes = try drawer.draw(frame)
        let body = rects.body, middle = body.y + body.height / 2
        // The band along the body's edge, the black bezel inside it, the buttons in the band's colour.
        #expect(isClose(at(bytes, size, [body.x + rects.bandWidth / 2, middle]), band, tolerance: 1), "\(finish)")
        let bezel = (rects.screen.x - body.x) - rects.bandWidth
        #expect(isClose(at(bytes, size, [body.x + rects.bandWidth + bezel / 2, middle]), [0, 0, 0, 255], tolerance: 1), "\(finish)")
        for button in rects.buttons {
            #expect(isClose(at(bytes, size, [button.x + button.width / 2, button.y + button.height / 2]), band, tolerance: 1), "\(finish)")
        }
        // The black island over the white screen, and the screen inside the device.
        let island = try #require(rects.cutout)
        #expect(isClose(at(bytes, size, [island.x + island.width / 2, island.y + island.height / 2]), [0, 0, 0, 255], tolerance: 1))
        #expect(at(bytes, size, [island.x + island.width / 2, island.y + island.height + 4]) == [255, 255, 255, 255])
        let screen = rects.screen
        #expect(at(bytes, size, [screen.x + screen.width / 2, screen.y + screen.height / 2]) == [255, 255, 255, 255])
        #expect(at(bytes, size, [screen.x + 1, screen.y + screen.height / 2]) == [255, 255, 255, 255])
        // Outside it, the background.
        #expect(isClose(at(bytes, size, [rects.bounds.x - 3, middle]), backdropBGRA, tolerance: 1))
        #expect(isClose(at(bytes, size, [body.x + 2, body.y + 2]), backdropBGRA, tolerance: 1), "the body's corner is round")
    }
    // The iPad's and the MacBook's parts.
    for (model, band, bezelColor) in [(DeviceModel.iPad, bgra(0x2C2C2E), bgra(0x000000)), (.macBook, bgra(0x2E2F33), bgra(0x0A0A0A))] {
        let frame = evaluated(take, deviceDocument(take, model, .dark), size: size)
        let rects = try #require(frame.deviceFrame?.rects)
        let bytes = try drawer.draw(frame)
        let body = rects.body, middle = body.y + body.height / 2
        #expect(isClose(at(bytes, size, [body.x + rects.bandWidth / 2, middle]), band, tolerance: 1), "\(model)")
        let bezel = (rects.screen.x - body.x) - rects.bandWidth
        #expect(isClose(at(bytes, size, [body.x + rects.bandWidth + bezel / 2, middle]), bezelColor, tolerance: 1), "\(model)")
        if let base = rects.base {
            #expect(isClose(at(bytes, size, [base.x + base.width * 0.25, base.y + base.height / 2]), band, tolerance: 1))
            let notch = try #require(rects.cutout)
            #expect(isClose(at(bytes, size, [notch.x + notch.width / 2, notch.y + notch.height / 2]), bezelColor, tolerance: 1))
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cutoutIsOverTheCursorAndUnderTheClickEffects() throws {
    let take = deviceTake()
    let size = SIMD2(2560, 1440)
    let drawer = try DeviceDrawer()
    let plain = evaluated(take, deviceDocument(take, .iPhone), size: size)
    let island = try #require(plain.deviceFrame?.rects.cutout)
    let centre = SIMD2(island.x + island.width / 2, island.y + island.height / 2)
    var withCursor = plain
    withCursor.cursor = CursorLayer(hotspot: centre, height: island.height)
    var counts = DrawCounts()
    let without = try drawer.draw(plain), with = try drawer.draw(withCursor, counts: &counts)
    #expect(counts.cursors == 1 && counts.deviceOverlays == 1 && counts.deviceFrames == 1)
    // The cursor is drawn, below the island, and not seen inside it.
    #expect(without != with)
    let inside = (Int(island.y + 3)..<Int(island.y + island.height - 3)).allSatisfy { y in
        (Int(centre.x)..<Int(centre.x + island.height / 2)).allSatisfy { x in
            pixel(with, width: size.x, x: x, y: y) == pixel(without, width: size.x, x: x, y: y)
        }
    }
    #expect(inside)
    // A click's circle is drawn over the island.
    var clicked = withCursor
    clicked.clickEffects = [ClickEffectLayer(kind: .circle, center: centre, radius: island.height / 3, thickness: 0, opacity: 1)]
    #expect(at(try drawer.draw(clicked), size, centre) == [255, 255, 255, 255])
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func shadowFollowsTheBody() throws {
    let take = deviceTake()
    let size = SIMD2(2560, 1440)
    let drawer = try DeviceDrawer()
    for model in DeviceModel.allCases {
        let document = deviceDocument(take, model) { $0.style.shadow = 0.6 }
        let frame = evaluated(take, document, size: size)
        let layer = try #require(frame.deviceFrame)
        let shadow = try #require(frame.shadow)
        let rects = layer.rects
        // The style's shadow, cast by the body with its corners (the MacBook's lid); the base casts its own.
        #expect(shadow.rect == rects.body && shadow.cornerRadius == rects.bodyCornerRadius, "\(model)")
        #expect(shadow.opacity == 0.55 * 0.6, "\(model)")
        #expect((layer.baseShadow != nil) == (model == .macBook), "\(model)")
        let bytes = try drawer.draw(frame)
        let body = rects.body, middle = body.y + body.height / 2
        // Beside the body, the shadow; at the corner of the iPhone's bounding box, far from its round corner, much less.
        let beside = darkness(at(bytes, size, [body.x - 2, middle]))
        #expect(beside > 4, "\(model): \(beside)")
        if model == .iPhone {
            let corner = darkness(at(bytes, size, [body.x + 1, body.y + 1]))
            #expect(corner < beside / 2, "\(beside), \(corner)")
        }
        if let base = rects.base, let baseShadow = layer.baseShadow {
            #expect(baseShadow.rect == base && baseShadow.sigma == shadow.sigma && baseShadow.offsetY == shadow.offsetY)
            // Under the base, its own shadow over the lid's.
            var withoutIt = frame
            withoutIt.deviceFrame?.baseShadow = nil
            let under: SIMD2<Double> = [base.x + base.width / 2, base.y + base.height + baseShadow.offsetY]
            let darker = darkness(at(bytes, size, under)) - darkness(at(try drawer.draw(withoutIt), size, under))
            #expect(darker > 4, "\(darker)")
        }
    }
    // Without the style's shadow, none.
    let none = evaluated(take, deviceDocument(take, .macBook), size: size)
    #expect(none.shadow == nil && none.deviceFrame?.baseShadow == nil)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func zoomMovesTheDeviceWithTheScreen() throws {
    let take = deviceTake()
    let size = SIMD2(2560, 1440)
    let drawer = try DeviceDrawer()
    // 2× fixed at the screen's centre, there from the start.
    let document = deviceDocument(take, .iPhone) { $0.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 2, instant: true)] }
    let zoomed = evaluated(take, document, size: size)
    let stage = try #require(zoomed.stage)
    var unzoomedFrame = zoomed
    unzoomedFrame.stage = nil
    let rects = try #require(zoomed.deviceFrame?.rects)
    let island = try #require(rects.cutout)
    let zoomedBytes = try drawer.draw(zoomed), unzoomedBytes = try drawer.draw(unzoomedFrame)
    // The band, the bezel, the island and a button, where the stage's transform takes them.
    let body = rects.body, middle = body.y + body.height / 2
    let probes: [SIMD2<Double>] = [
        [body.x + rects.bandWidth / 2, middle], [body.x + rects.bandWidth + 4, middle],
        [island.x + island.width / 2, island.y + island.height / 2],
        [rects.buttons[3].x + rects.buttons[3].width / 2, rects.buttons[3].y + rects.buttons[3].height / 2],
    ]
    for probe in probes {
        let drawn = stage.outputPoint(ofStage: probe, outputSize: size)
        guard drawn.x >= 0, drawn.y >= 0, drawn.x < Double(size.x), drawn.y < Double(size.y) else { continue }
        #expect(isClose(at(zoomedBytes, size, drawn), SIMD4<Float>(at(unzoomedBytes, size, probe)), tolerance: 2), "\(probe)")
    }

    // A deep zoom at the edge of an iPad's screen keeps to the device: no background beside it.
    let wide = deviceTake(globalFrame: Rect(x: 0, y: 0, width: 1024, height: 768))
    let edge = deviceDocument(wide, .iPad) {
        $0.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 3, focus: .fixed(x: 0, y: 0.5), instant: true)]
    }
    let deep = evaluated(wide, edge, size: size)
    let deepBytes = try drawer.draw(deep)
    for y in [size.y / 4, size.y / 2, 3 * size.y / 4] {
        #expect(!isClose(pixel(deepBytes, width: size.x, x: 0, y: y), backdropBGRA, tolerance: 6), "\(y)")
        #expect(!isClose(pixel(deepBytes, width: size.x, x: size.x - 1, y: y), backdropBGRA, tolerance: 6), "\(y)")
    }
}

/// A block of `kind` over the whole take.
private func block(_ kind: LayoutKind) -> LayoutBlock {
    LayoutBlock(
        id: "l-00000001", take: takeID, start: base, end: base.adding(seconds: 3), kind: kind, instant: true, bubble: nil,
        split: kind == .split ? SplitLayout() : nil)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func deviceOnACardFitsTheCard() throws {
    let take = deviceTake(camera: true)
    let size = SIMD2(1920, 1080)
    let output = SIMD2(Double(size.x), Double(size.y))
    for model in DeviceModel.allCases {
        let document = deviceDocument(take, model) { $0.camera.layouts = [block(.split)] }
        let split = evaluated(take, document, size: size, at: 1.5)
        let layer = try #require(split.deviceFrame, "\(model)")
        // The screen's card is the device's bounds: of their aspect, where the split puts it.
        let layouts = LayoutTimeline(
            document: document, take: take, timeMap: TimeMap(sequence: document.sequence), cameraReadable: true)
        let bounds = layer.rects.bounds
        let geometry = layouts.geometry(atOutput: 1_500_000_000, LayoutInputs(
            output: output, padding: document.style.padding, cornerRadius: document.style.cornerRadius,
            screenAspect: bounds.width / bounds.height, sizeReference: document.camera.sizeReference))
        #expect(isClose(bounds, geometry.screen.rect, tolerance: 1e-6), "\(model): \(bounds) is not \(geometry.screen.rect)")
        // The card cuts the content to the device's screen, with its corners.
        let card = try #require(split.card)
        #expect(isClose(card.rect, layer.rects.screen, tolerance: 1e-6) && card.cornerRadius == layer.rects.screenCornerRadius)
        var counts = DrawCounts()
        let bytes = try DeviceDrawer().draw(split, counts: &counts)
        #expect(counts.deviceFrames == 1 && counts.deviceOverlays == (model == .iPad ? 0 : 1), "\(model)")
        let body = layer.rects.body
        #expect(!isClose(at(bytes, size, [body.x + layer.rects.bandWidth / 2, body.y + body.height / 2]), backdropBGRA, tolerance: 6))
    }
    // Camera only: nothing of the device.
    let cameraOnly = evaluated(take, deviceDocument(take, .iPhone) { $0.camera.layouts = [block(.cameraOnly)] }, size: size, at: 1.5)
    #expect(cameraOnly.deviceFrame == nil)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func followTheCursorDrawsNoDevice() throws {
    let take = deviceTake()
    let document = deviceDocument(take, .iPhone) { $0.style.reframe = .followCursor }
    let followed = evaluated(take, document, size: SIMD2(1280, 720))
    #expect(followed.deviceFrame == nil)
    var counts = DrawCounts()
    _ = try DeviceDrawer().draw(followed, counts: &counts)
    #expect(counts.deviceFrames == 0 && counts.deviceOverlays == 0)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func fadingGroupHidesItsOwnBody() throws {
    // The screen's group at half its opacity is the whole device at half: the bezel under the screen never shows
    // through it, as the window's bar does not.
    let take = deviceTake()
    let size = SIMD2(1280, 720)
    var half = evaluated(take, deviceDocument(take, .iPhone), size: size)
    half.screenOpacity = 0.5
    half.screen?.opacity = 0.5
    half.deviceFrame?.opacity = 0.5
    let rects = try #require(half.deviceFrame?.rects)
    let bytes = try DeviceDrawer().draw(half)
    let screen = rects.screen
    // The white screen at half over the background, as without the device under it.
    let expected = (SIMD4<Float>(255, 255, 255, 255) + backdropBGRA) / 2
    #expect(isClose(at(bytes, size, [screen.x + screen.width / 2, screen.y + screen.height / 2]), expected, tolerance: 2))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewEqualsExportWithADevice() async throws {
    try await withTemporaryDirectory { dir in
        let screen = Rect(x: 0, y: 0, width: 640, height: 360)
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: screen), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screen))
        let project = try builder.write()
        for model in [DeviceModel.iPhone, .macBook] {
            var document = EditDocument.legacy(for: project)
            document.style.frame = .device(DeviceFrame(model: model, finish: .light))
            document.style.shadow = 0.5
            // A zoom that moves from 0.5 s to 1.5 s, with the camera's and the cursor's blur.
            document.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 2.2, focus: .follow)]
            document.zoom.motionBlur = 1
            document.cursor.motionBlur = 1
            let size = SIMD2(960, 540)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            #expect(evaluator.frame(at: 0.7).deviceFrame != nil && !evaluator.frame(at: 0.7).subframes.isEmpty, "\(model)")
            for t in [0.2, 0.7, 2.0] {
                let preview = try await offThePool { try renderer.renderBytes(at: t) }
                let export = try await exportedBytes(renderer, at: t)
                #expect(preview == export, "\(model) at \(t)")
            }
        }
    }
}

/// `renderer`'s frame at `t` drawn as the export draws it (`render(at:into:completion:)`), as its bytes.
private func exportedBytes(_ renderer: FrameRenderer, at t: Double) async throws -> [UInt8] {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    let target = DevicePixelBuffer(try #require(created))
    let error: (any Error)? = await withCheckedContinuation { continuation in
        renderer.render(at: t, into: target.pixelBuffer) { continuation.resume(returning: $0) }
    }
    if let error { throw error }
    return packedBytes(of: target.pixelBuffer)
}

private final class DevicePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

// MARK: - Pictures to look at

/// Where `deviceFrameShots` writes its PNGs: `TOMA_DEVICE_SHOTS`, a folder. Only on demand.
private let shotsFolder = ProcessInfo.processInfo.environment["TOMA_DEVICE_SHOTS"]

/// A screen to look at: a soft gradient with a white bar at the top (where the island and the notch are) and a few cards.
private func showcaseScreen(device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bar = Double(height) * 0.06, short = Double(min(width, height))
    for y in 0..<height {
        for x in 0..<width {
            let u = Double(x) / Double(width), v = Double(y) / Double(height)
            var (r, g, b) = (0.36 + 0.4 * u, 0.30 + 0.25 * v, 0.85 - 0.3 * u)
            if Double(y) < bar { (r, g, b) = (1, 1, 1) }
            // Two cards.
            for card in 0..<2 {
                let top = bar + short * 0.06 + Double(card) * (short * 0.36)
                let left = short * 0.06, right = Double(width) - short * 0.06
                if Double(y) > top, Double(y) < top + short * 0.3, Double(x) > left, Double(x) < right { (r, g, b) = (0.97, 0.97, 0.99) }
            }
            let i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (UInt8(b * 255), UInt8(g * 255), UInt8(r * 255), 255)
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// Writes BGRA `bytes` of `size` (or its part `crop`) as a PNG at `url`.
private func writePNG(_ bytes: [UInt8], size: SIMD2<Int>, crop: Rect? = nil, to url: URL) throws {
    let data = CFDataCreate(nil, bytes, bytes.count)!
    let provider = try #require(CGDataProvider(data: data))
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    var image = try #require(CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent))
    if let crop {
        image = try #require(image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).integral))
    }
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test(.enabled(if: shotsFolder != nil && (MetalCondition.isAvailable || MetalCondition.isRequired)))
func deviceFrameShots() throws {
    let folder = URL(fileURLWithPath: try #require(shotsFolder))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let contents: [(name: String, frame: Rect)] = [
        ("portrait", Rect(x: 0, y: 0, width: 1179, height: 2556)), ("landscape", Rect(x: 0, y: 0, width: 1728, height: 1080)),
    ]
    for content in contents {
        let drawer = try DeviceDrawer(
            screen: showcaseScreen(device: device, width: Int(content.frame.width), height: Int(content.frame.height)), device: device)
        let take = deviceTake(globalFrame: content.frame)
        for model in DeviceModel.allCases {
            for finish in [FrameAppearance.dark, .light] {
                for (size, zoomed) in [(SIMD2(3840, 2160), false), (SIMD2(1080, 1920), false), (SIMD2(1920, 1080), false), (SIMD2(3840, 2160), true)] {
                    var document = EditDocument.legacy(take: take, events: [])
                    document.style.frame = .device(DeviceFrame(model: model, finish: finish))
                    document.style.shadow = 0.6
                    if finish == .light { document.style.background = .color(RGBA(0.93, 0.93, 0.95, 1)) }
                    if zoomed {
                        document.zoom.regions = [StageDrawing.zoom(1, from: 0, to: 3, depth: 2.5, focus: .fixed(x: 0.2, y: 0.1), instant: true)]
                    }
                    let frame = evaluated(take, document, size: size)
                    let bytes = try drawer.draw(frame)
                    let name = "\(model)-\(finish)-\(content.name)-\(size.x)x\(size.y)\(zoomed ? "-zoom" : "")"
                    try writePNG(bytes, size: size, to: folder.appendingPathComponent("\(name).png"))
                    guard size.x == 3840, !zoomed, let rects = frame.deviceFrame?.rects else { continue }
                    // At full size: the top-left corner, the cutout, the buttons and the base.
                    let body = rects.body, side = max(body.width, body.height) * 0.22
                    try writePNG(
                        bytes, size: size, crop: Rect(x: body.x - 40, y: body.y - 40, width: side, height: side),
                        to: folder.appendingPathComponent("\(name)-corner.png"))
                    if let cutout = rects.cutout {
                        let reach = max(cutout.width, cutout.height) * 0.75
                        try writePNG(
                            bytes, size: size,
                            crop: Rect(
                                x: cutout.x + cutout.width / 2 - reach, y: cutout.y + cutout.height / 2 - reach / 2,
                                width: 2 * reach, height: reach), to: folder.appendingPathComponent("\(name)-cutout.png"))
                    }
                    if let base = rects.base {
                        try writePNG(
                            bytes, size: size,
                            crop: Rect(x: base.x - 40, y: base.y - 200, width: base.width * 0.6, height: 400),
                            to: folder.appendingPathComponent("\(name)-base.png"))
                    }
                    if let first = rects.buttons.first {
                        let span = rects.buttons.map { $0.y + $0.height }.max()! - first.y
                        try writePNG(
                            bytes, size: size,
                            crop: Rect(x: first.x - 60, y: first.y - 60, width: max(span, 300) * 0.6, height: span + 120),
                            to: folder.appendingPathComponent("\(name)-buttons.png"))
                    }
                }
            }
        }
    }
}
