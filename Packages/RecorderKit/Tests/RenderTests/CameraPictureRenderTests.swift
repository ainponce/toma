// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreMedia
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `CameraLookResources`, `CameraLookTextures`, `DrawCounts` and the
// compositor's counting `encode` and `cameraFill`.
@testable import Render
import SyntheticCapture
import Testing

// The camera's framing and colour drawn (plan 2b task I10, phase 2 design §6.2 and §6.3): the framing's crop of the
// frame, the mirror after it, the looks' LUTs (`cameraLook-1`) and the user's `.cube` mixed by their intensity, on the
// camera alone. Frames worked out by the evaluator from documents, drawn by a compositor of its own over textures (a
// screen, and a camera of `CameraPictureFixtures`), and through the renderer from a take's video for the `.cube`s.

let pictureScreen = Rect(x: 0, y: 0, width: 640, height: 360)
let pictureSize = SIMD2(640, 360)
/// The background of every document here: one colour, the same under every pixel.
let pictureBackdrop = RGBA(0.25, 0.25, 0.25, 1)
let pictureSegment = CameraSegment(take: takeID, track: cameraID, segment: 1)

/// A take of 10 s with a screen and a camera, without files: for what the evaluator works out.
func pictureTake() -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: pictureScreen, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: 10))]),
    ])
}

/// The legacy document of `take` on `pictureBackdrop`, with `change` made to it.
func pictureDocument(_ take: TakeRecord = pictureTake(), _ change: (inout EditDocument) -> Void = { _ in }) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: [])
    document.style.background = .color(pictureBackdrop)
    change(&document)
    return document
}

/// The analysis with a mask for the camera's first segment at `url` (a file that need not be there: the drawer is handed
/// its texture).
func pictureMasks(_ url: URL = URL(fileURLWithPath: "/caches/masks/seg-0001-personMask-1.mov")) -> AnalysisInputs {
    var analysis = AnalysisInputs()
    analysis.personMasks[pictureSegment] = url
    return analysis
}

/// The frame of `document` over `take` at `seconds` in an output of `size`, with `analysis`.
func pictureFrame(
    _ document: EditDocument, take: TakeRecord = pictureTake(), size: SIMD2<Int> = pictureSize, analysis: AnalysisInputs = .none,
    at seconds: Double = 2
) -> RenderFrame {
    FrameEvaluator(take: take, events: [], document: document, outputSize: size, analysis: analysis).frame(at: seconds)
}

/// Draws frames with a compositor of its own over a screen texture and a camera texture given for each frame, with what
/// the renderer's `CameraLookResources` makes for the camera's look (its LUTs, from `package`) and a mask texture given,
/// counting what it draws. It checks nothing itself: it runs off the cooperative pool.
struct CameraPictureDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let cursor: any MTLTexture
    let resources: CameraLookResources

    init(package: ProjectPackage = ProjectPackage(url: URL(fileURLWithPath: "/nowhere/Fixture.toma"))) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestSupportError.missing("Metal")
        }
        self.device = device
        self.queue = queue
        compositor = try Compositor(device: device)
        screen = try CameraPictureFixtures.texture(device, width: 64, height: 36) { _, _ in [255, 0, 0, 255] }
        cursor = try CursorSprite.makeTexture(device: device)
        resources = CameraLookResources(device: device, package: package)
    }

    /// `frame` drawn with `camera` and, for its look, the LUT the resources give and `mask`, as BGRA bytes, with what was
    /// drawn and how long the GPU took (seconds). With `look` false, without anything for the look (`cameraLook` nil).
    func draw(
        _ frame: RenderFrame, camera: SentTexture?, mask: SentTexture? = nil, look: Bool = true, bytes: Bool = true
    ) throws -> (bytes: [UInt8], counts: DrawCounts, gpuSeconds: Double) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw TestSupportError.missing("Metal objects")
        }
        var textures: CameraLookTextures?
        if look {
            textures = try resources.textures(for: frame, decoded: { _, _ in nil }, commandBuffer: commandBuffer)
            if let mask {
                textures = textures ?? CameraLookTextures()
                textures?.mask = mask.texture
            }
        }
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, camera: camera?.texture, cursor: cursor, cameraLook: textures, into: target,
            commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        let gpu = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        guard bytes else { return ([], counts, gpu) }
        var read = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
        target.getBytes(
            &read, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y),
            mipmapLevel: 0)
        return (read, counts, gpu)
    }
}

/// A texture handed to a drawer off the cooperative pool (textures are not `Sendable`); nothing writes into it after it
/// is made.
struct SentTexture: @unchecked Sendable {
    let texture: any MTLTexture

    init(_ texture: any MTLTexture) {
        self.texture = texture
    }
}

/// What the tests of the camera's picture share to look at what is drawn.
enum Picture {
    /// Whether pixel (`x`, `y`) touches `rect` (output pixels).
    static func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
        let left = Double(x), top = Double(y)
        return left + 1 > rect.x && left < rect.x + rect.width && top + 1 > rect.y && top < rect.y + rect.height
    }

    /// Whether pixel (`x`, `y`) is inside `rect` by `margin` pixels or more on every side.
    static func isInside(_ x: Int, _ y: Int, _ rect: Rect, by margin: Double) -> Bool {
        let left = Double(x), top = Double(y)
        return left >= rect.x + margin && left + 1 <= rect.x + rect.width - margin && top >= rect.y + margin
            && top + 1 <= rect.y + rect.height - margin
    }

    /// Whether the centre of pixel (`x`, `y`) is inside the circle of `rect` (a square) by `margin` pixels.
    static func isInsideCircle(_ x: Int, _ y: Int, _ rect: Rect, by margin: Double) -> Bool {
        let d = SIMD2(Double(x) + 0.5 - (rect.x + rect.width / 2), Double(y) + 0.5 - (rect.y + rect.height / 2))
        return (d * d).sum().squareRoot() <= rect.width / 2 - margin
    }

    /// The largest difference between the channels of two BGRA pixels.
    static func difference(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>) -> Int {
        (0..<4).map { abs(Int(a[$0]) - Int(b[$0])) }.max() ?? 0
    }

    /// `rgb` (0 to 1) as an opaque BGRA pixel, rounded.
    static func bgra(_ rgb: SIMD3<Float>) -> SIMD4<UInt8> {
        func byte(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return SIMD4(byte(rgb.z), byte(rgb.y), byte(rgb.x), 255)
    }
}

private let isMetal = MetalCondition.isAvailable || MetalCondition.isRequired
private let quadrantCamera = (width: 640, height: 360)

private func framing(_ mode: CameraFramingMode, x: Double = 0.5, y: Double = 0.5, zoom: Double) -> CameraFraming {
    CameraFraming(mode: mode, center: NormalizedPoint(x: x, y: y), zoom: zoom)
}

/// A circle bubble of a third of the output's height in its middle, at the bottom.
private func bubbleDocument(_ change: (inout EditDocument) -> Void = { _ in }) -> EditDocument {
    pictureDocument { document in
        document.camera.initial[takeID] = CameraStyle(shape: .circle, size: 0.45, anchor: .bottom)
        change(&document)
    }
}

@Test(.enabled(if: isMetal))
func framingShowsThePartAroundTheCenter() async throws {
    let drawer = try CameraPictureDrawer()
    let camera = SentTexture(try CameraPictureFixtures.texture(drawer.device, width: quadrantCamera.width, height: quadrantCamera.height) {
        CameraPictureFixtures.quadrant($0, $1, width: quadrantCamera.width, height: quadrantCamera.height)
    })
    // At 2× around the middle of each quadrant, the bubble shows that quadrant alone.
    let quadrants: [(String, x: Double, y: Double, color: SIMD4<UInt8>)] = [
        ("top left", 0.25, 0.25, CameraPictureFixtures.red), ("top right", 0.75, 0.25, CameraPictureFixtures.green),
        ("bottom left", 0.25, 0.75, CameraPictureFixtures.blue), ("bottom right", 0.75, 0.75, CameraPictureFixtures.white),
    ]
    for (name, x, y, color) in quadrants {
        let frame = pictureFrame(bubbleDocument { $0.camera.framing = framing(.manual, x: x, y: y, zoom: 2) })
        let layer = try #require(frame.camera)
        #expect(layer.look?.framing == CameraFramingLayer(center: SIMD2(x, y), zoom: 2), "\(name)")
        let drawn = try await offThePool { try drawer.draw(frame, camera: camera) }
        // The framing alone is the camera's own drawing: no pipeline of its look.
        #expect(drawn.counts.cameras == 1 && drawn.counts.cameraLooks == 0, "\(name): \(drawn.counts)")
        var wrong: [String] = []
        for py in 0..<pictureSize.y {
            for px in 0..<pictureSize.x where Picture.isInsideCircle(px, py, layer.rect, by: 1.5) {
                let p = pixel(drawn.bytes, width: pictureSize.x, x: px, y: py)
                if Picture.difference(p, color) > 1 { wrong.append("(\(px), \(py)): \(p)") }
            }
        }
        #expect(wrong.isEmpty, "\(name): \(wrong.count) pixels, \(wrong.prefix(4))")
    }
    // Centred at 1× it is the centred fill of phase 1: the four quadrants meet in the bubble's middle.
    let centred = pictureFrame(bubbleDocument())
    let layer = try #require(centred.camera)
    #expect(layer.look == nil)
    let drawn = try await offThePool { try drawer.draw(centred, camera: camera) }
    let middle = SIMD2(Int(layer.rect.x + layer.rect.width / 2), Int(layer.rect.y + layer.rect.height / 2))
    let around = [
        (-8, -8, CameraPictureFixtures.red), (8, -8, CameraPictureFixtures.green), (-8, 8, CameraPictureFixtures.blue),
        (8, 8, CameraPictureFixtures.white),
    ]
    for (dx, dy, color) in around {
        let p = pixel(drawn.bytes, width: pictureSize.x, x: middle.x + dx, y: middle.y + dy)
        #expect(Picture.difference(p, color) <= 1, "(\(dx), \(dy)) from the middle: \(p)")
    }
}

@Test(.enabled(if: isMetal))
func framingNeverShowsOutsideTheFrame() async throws {
    let drawer = try CameraPictureDrawer()
    // A frame with a ring of 4 magenta pixels around the quadrants: a crop past its edge would fill with it.
    let (width, height) = quadrantCamera
    let magenta: SIMD4<UInt8> = [255, 0, 255, 255]
    let camera = SentTexture(try CameraPictureFixtures.texture(drawer.device, width: width, height: height) { x, y in
        x < 4 || y < 4 || x >= width - 4 || y >= height - 4 ? magenta : CameraPictureFixtures.quadrant(x, y, width: width, height: height)
    })
    // The crop stays inside the frame for any centre and zoom, in every shape.
    for shape in [CameraShape.circle, .landscape, .portrait] {
        for (x, y) in [(0.0, 0.0), (1, 1), (0, 1), (-0.5, 0.5), (0.5, 2), (Double.nan, 0.3)] {
            for zoom in [1.0, 1.4, 2.5, 4] {
                let frame = pictureFrame(pictureDocument { document in
                    document.camera.initial[takeID] = CameraStyle(shape: shape, size: 0.45, anchor: .bottom)
                    document.camera.framing = framing(.manual, x: x, y: y, zoom: zoom)
                })
                let layer = try #require(frame.camera)
                let fill = drawer.compositor.cameraFill(layer, texture: camera.texture)
                let end = fill.origin + fill.size
                #expect(
                    fill.origin.min() >= 0 && end.max() <= 1 + 1e-6 && fill.size.min() > 0,
                    "\(shape) at (\(x), \(y)) ×\(zoom): \(fill)")
                if zoom > 1 {
                    // Not stretched: the crop's aspect in pixels is the rect's.
                    let aspect = Double(fill.size.x) * Double(width) / (Double(fill.size.y) * Double(height))
                    #expect(abs(aspect - layer.rect.width / layer.rect.height) < 1e-3, "\(shape) at (\(x), \(y)) ×\(zoom)")
                }
            }
        }
    }
    // Drawn at the corner at 2.5×: the corner's red, with at most the ring's few pixels along the bubble's edge.
    let frame = pictureFrame(bubbleDocument { $0.camera.framing = framing(.manual, x: 0, y: 0, zoom: 2.5) })
    let layer = try #require(frame.camera)
    let drawn = try await offThePool { try drawer.draw(frame, camera: camera) }
    var inside = 0, ring = 0, other: [String] = []
    for py in 0..<pictureSize.y {
        for px in 0..<pictureSize.x where Picture.isInsideCircle(px, py, layer.rect, by: 1.5) {
            inside += 1
            let p = pixel(drawn.bytes, width: pictureSize.x, x: px, y: py)
            if Picture.difference(p, CameraPictureFixtures.red) <= 1 { continue }
            // Red and the ring's magenta, blended along the crop's edge.
            if p.z >= 254 && p.y <= 1 { ring += 1 } else { other.append("(\(px), \(py)): \(p)") }
        }
    }
    #expect(other.isEmpty, "\(other.count): \(other.prefix(4))")
    // The ring is 4 / 640 of the frame's width, of a crop 0.225 of it: under 3 % of the bubble's width, along two of its
    // sides. Centred at the corner past the frame, half the bubble would be magenta.
    #expect(Double(ring) < 0.06 * Double(inside), "\(ring) of \(inside)")
}

@Test(.enabled(if: isMetal))
func mirrorFlipsAfterTheFraming() async throws {
    let drawer = try CameraPictureDrawer()
    let (width, height) = quadrantCamera
    let camera = SentTexture(try CameraPictureFixtures.texture(drawer.device, width: width, height: height) {
        CameraPictureFixtures.quadrant($0, $1, width: width, height: height)
    })
    // At 2× around (0.45, 0.25): the crop runs from 0.309 to 0.591 of the frame's width, red to its left of 0.5 and green
    // to its right, so red fills 68 % of the bubble from its left. Mirrored, the same crop flipped: green on the left 32 %.
    // A mirror before the crop would crop the flipped frame there instead, and show green on the left 68 %.
    let plain = pictureFrame(bubbleDocument { $0.camera.framing = framing(.manual, x: 0.45, y: 0.25, zoom: 2) })
    let mirrored = pictureFrame(bubbleDocument { document in
        document.camera.framing = framing(.manual, x: 0.45, y: 0.25, zoom: 2)
        document.camera.mirror = true
    })
    let layer = try #require(plain.camera)
    #expect(mirrored.camera?.rect == layer.rect)
    let (a, b) = try await offThePool { (try drawer.draw(plain, camera: camera).bytes, try drawer.draw(mirrored, camera: camera).bytes) }
    let row = Int(layer.rect.y + layer.rect.height / 2)
    /// Where along the row the colour turns from what it is at the bubble's left, as a fraction of the bubble's width.
    func turn(_ bytes: [UInt8], from: SIMD4<UInt8>, to: SIMD4<UInt8>) -> Double? {
        let left = Int(layer.rect.x) + 2, right = Int(layer.rect.x + layer.rect.width) - 2
        guard Picture.difference(pixel(bytes, width: pictureSize.x, x: left, y: row), from) <= 1 else { return nil }
        for x in left...right where Picture.difference(pixel(bytes, width: pictureSize.x, x: x, y: row), to) <= 1 {
            return (Double(x) - layer.rect.x) / layer.rect.width
        }
        return nil
    }
    let plainTurn = try #require(turn(a, from: CameraPictureFixtures.red, to: CameraPictureFixtures.green))
    let mirroredTurn = try #require(turn(b, from: CameraPictureFixtures.green, to: CameraPictureFixtures.red))
    let crop = (x: 0.45 - 0.5625 / 4, width: 0.5625 / 2)
    #expect(abs(plainTurn - (0.5 - crop.x) / crop.width) < 0.02, "\(plainTurn)")
    #expect(abs(mirroredTurn - (1 - (0.5 - crop.x) / crop.width)) < 0.02, "\(mirroredTurn)")
}

@Test(.enabled(if: isMetal))
func naturalCenteredIsTheLegacyBytes() async throws {
    let drawer = try CameraPictureDrawer()
    let camera = SentTexture(try CameraPictureFixtures.texture(drawer.device, width: 320, height: 180) {
        CameraPictureFixtures.person($0, $1, width: 320, height: 180)
    })
    let mask = SentTexture(try CameraPictureFixtures.maskTexture(drawer.device, width: 160, height: 90) {
        CameraPictureFixtures.personMask($0, $1, width: 160, height: 90)
    })
    let styled: (inout EditDocument) -> Void = { document in
        document.camera.mirror = true
        document.camera.border = CameraBorder(width: 0.5, color: RGBA(1, 0, 0, 1))
        document.camera.shadow = 0.6
    }
    for (name, change) in [("plain", { (_: inout EditDocument) in }), ("styled", styled)] {
        let legacy = pictureFrame(pictureDocument(pictureTake(), change), analysis: pictureMasks())
        let expected = try await offThePool { try drawer.draw(legacy, camera: camera, look: false) }
        // Natural at any intensity, centred at 1×, Original: no look, no background; and handed a LUT and a mask, the
        // same bytes and the same drawings.
        for intensity in [1.0, 0.5, 0] {
            let natural = pictureFrame(
                pictureDocument { document in
                    change(&document)
                    document.camera.framing = framing(.center, x: 0.2, zoom: 1)
                    document.camera.look = CameraColor(preset: .natural, lut: nil, intensity: intensity)
                }, analysis: pictureMasks())
            #expect(natural == legacy, "\(name) at \(intensity)")
            let drawn = try await offThePool { try drawer.draw(natural, camera: camera, mask: mask) }
            #expect(drawn.counts == expected.counts && drawn.counts.cameraLooks == 0, "\(name) at \(intensity): \(drawn.counts)")
            #expect(drawn.bytes == expected.bytes, "\(name) at \(intensity)")
        }
        // A look at intensity 0 is Natural too.
        let none = pictureFrame(pictureDocument { document in
            change(&document)
            document.camera.look = CameraColor(preset: .vivid, lut: nil, intensity: 0)
        })
        #expect(none == legacy, "\(name), Vivid at 0")
    }
}

/// A flat camera of `rgb` (bytes), 64 × 36.
private func flatCamera(_ device: any MTLDevice, _ rgb: SIMD3<UInt8>) throws -> SentTexture {
    SentTexture(try CameraPictureFixtures.texture(device, width: 64, height: 36) { _, _ in [rgb.z, rgb.y, rgb.x, 255] })
}

/// The colour at the middle of `frame`'s camera, drawn with `camera`.
private func cameraMiddle(_ drawer: CameraPictureDrawer, _ frame: RenderFrame, camera: SentTexture) async throws -> SIMD4<UInt8> {
    let layer = try #require(frame.camera)
    let bytes = try await offThePool { try drawer.draw(frame, camera: camera).bytes }
    let middle = (x: Int(layer.rect.x + layer.rect.width / 2), y: Int(layer.rect.y + layer.rect.height / 2))
    return pixel(bytes, width: frame.outputSize.x, x: middle.x, y: middle.y)
}

@Test(.enabled(if: isMetal))
func warmIsTheLUTMath() async throws {
    let drawer = try CameraPictureDrawer()
    // Flat grays, and a few colours, through each look made in code: the LUT's trilinear read of 33³ points is the look's
    // math within one step of 8 bits.
    let colours: [SIMD3<UInt8>] = [[0, 0, 0], [64, 64, 64], [128, 128, 128], [200, 200, 200], [255, 255, 255]]
    let tinted: [SIMD3<UInt8>] = [[200, 120, 60], [40, 90, 160]]
    for preset in [CameraColorPreset.warm, .cool, .vivid, .soft, .mono] {
        let frame = pictureFrame(bubbleDocument { $0.camera.look = CameraColor(preset: preset, lut: nil, intensity: 1) })
        #expect(frame.camera?.look?.lut == .preset(preset))
        for rgb in colours + tinted {
            let camera = try flatCamera(drawer.device, rgb)
            let shown = try await cameraMiddle(drawer, frame, camera: camera)
            let expected = Picture.bgra(CameraLooks.apply(preset, to: SIMD3<Float>(rgb) / 255))
            let tolerance = colours.contains(rgb) ? 1 : 2
            #expect(Picture.difference(shown, expected) <= tolerance, "\(preset) of \(rgb): \(shown), not \(expected)")
        }
    }
}

@Test(.enabled(if: isMetal))
func intensityMixes() async throws {
    let drawer = try CameraPictureDrawer()
    for rgb: SIMD3<UInt8> in [[128, 128, 128], [200, 120, 60]] {
        let camera = try flatCamera(drawer.device, rgb)
        let original = SIMD3<Float>(rgb) / 255
        for intensity in [0.25, 0.5, 0.75] {
            let frame = pictureFrame(bubbleDocument { $0.camera.look = CameraColor(preset: .vivid, lut: nil, intensity: intensity) })
            let shown = try await cameraMiddle(drawer, frame, camera: camera)
            let graded = CameraLooks.apply(.vivid, to: original)
            let expected = Picture.bgra(original + (graded - original) * Float(intensity))
            #expect(Picture.difference(shown, expected) <= 1, "\(rgb) at \(intensity): \(shown), not \(expected)")
        }
    }
}

@Test(.enabled(if: isMetal))
func theScreenKeepsItsColors() async throws {
    let drawer = try CameraPictureDrawer()
    let camera = try flatCamera(drawer.device, [128, 100, 80])
    let plain = pictureFrame(bubbleDocument())
    let vivid = pictureFrame(bubbleDocument { $0.camera.look = CameraColor(preset: .vivid, lut: nil, intensity: 1) })
    let layer = try #require(vivid.camera)
    let (a, b) = try await offThePool {
        (try drawer.draw(plain, camera: camera), try drawer.draw(vivid, camera: camera))
    }
    #expect(b.counts.cameraLooks == 1 && a.counts.cameraLooks == 0)
    var changed = 0, outside: [String] = []
    for y in 0..<pictureSize.y {
        for x in 0..<pictureSize.x {
            let p = pixel(a.bytes, width: pictureSize.x, x: x, y: y), q = pixel(b.bytes, width: pictureSize.x, x: x, y: y)
            guard p != q else { continue }
            if Picture.touches(x, y, layer.rect) { changed += 1 } else { outside.append("(\(x), \(y))") }
        }
    }
    // Only the camera changes: the screen, its shadow and the background keep every byte.
    #expect(outside.isEmpty, "\(outside.count): \(outside.prefix(4))")
    #expect(Double(changed) > 0.7 * layer.rect.width * layer.rect.height, "\(changed)")
}

// MARK: - The user's `.cube`, through the renderer

/// A take of one second: a blue screen and a camera of one colour, (60, 120, 200).
private func flatCameraProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: pictureScreen),
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: { _, sample in
            CameraPictureFixtures.painting(sample) { _, _, _, _ in CameraPictureFixtures.blue }
        })])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource,
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: { _, sample in
            CameraPictureFixtures.painting(sample) { _, _, _, _ in [200, 120, 60, 255] }
        })])
    return try builder.write()
}

/// The bytes of `document`'s frame at 0.5 s and the middle of its camera, drawn by `renderer` (made for it when `nil`).
private func rendered(
    _ project: LoadedProject, _ document: EditDocument, renderer: FrameRenderer? = nil
) async throws -> (bytes: [UInt8], middle: SIMD4<UInt8>) {
    let renderer = try renderer ?? FrameRenderer(project: project, document: document, outputSize: pictureSize)
    let bytes = try await offThePool { try renderer.renderBytes(at: 0.5) }
    let layer = try #require(renderer.scene.frame(at: 0.5).camera)
    let middle = (x: Int(layer.rect.x + layer.rect.width / 2), y: Int(layer.rect.y + layer.rect.height / 2))
    return (bytes, pixel(bytes, width: pictureSize.x, x: middle.x, y: middle.y))
}

/// An inverting `.cube` of 2³ (exact under trilinear filtering), over a domain of 0 to 1 or wider.
private func invertingCube(domain: (min: Double, max: Double) = (0, 1)) -> String {
    CameraPictureFixtures.cube(size: 2, domain: domain) { SIMD3(repeating: 1) - $0 }
}

@Test(.enabled(if: isMetal))
func customCubeIsRead() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await flatCameraProject(in: dir)
        let path = try CameraPictureFixtures.writeCube(invertingCube(), in: project.package)
        let natural = try await rendered(project, pictureDocument(project.take))
        let custom = pictureDocument(project.take) { $0.camera.look = CameraColor(preset: .custom, lut: path, intensity: 1) }
        let inverted = try await rendered(project, custom)
        let expected = SIMD4<UInt8>(255 - natural.middle.x, 255 - natural.middle.y, 255 - natural.middle.z, 255)
        #expect(Picture.difference(inverted.middle, expected) <= 1, "\(inverted.middle), not \(expected)")
        // Half of it: the middle gray, whatever the colour.
        let half = pictureDocument(project.take) { $0.camera.look = CameraColor(preset: .custom, lut: path, intensity: 0.5) }
        let mixed = try await rendered(project, half)
        #expect(Picture.difference(mixed.middle, [128, 128, 128, 255]) <= 1, "\(mixed.middle)")
        // The screen is the same.
        #expect(pixel(inverted.bytes, width: pictureSize.x, x: 20, y: 20) == pixel(natural.bytes, width: pictureSize.x, x: 20, y: 20))

        // A `.cube` of a domain wider than 0…1: a colour c is read at (c + 1) / 3, so the table's inversion gives
        // 1 − (c + 1) / 3.
        let wide = try CameraPictureFixtures.writeCube(
            invertingCube(domain: (-1, 2)), in: project.package, name: "fedcba9876543210fedcba9876543210")
        let widened = try await rendered(
            project, pictureDocument(project.take) { $0.camera.look = CameraColor(preset: .custom, lut: wide, intensity: 1) })
        let c = SIMD3<Float>(Float(natural.middle.z), Float(natural.middle.y), Float(natural.middle.x)) / 255
        let expectedWide = Picture.bgra(SIMD3(repeating: 1) - (c + 1) / 3)
        #expect(Picture.difference(widened.middle, expectedWide) <= 1, "\(widened.middle), not \(expectedWide)")
    }
}

@Test(.enabled(if: isMetal))
func unreadableCubeDrawsNatural() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await flatCameraProject(in: dir)
        let natural = try await rendered(project, pictureDocument(project.take))
        let path = "assets/0123456789abcdef0123456789abcdef.cube"
        let custom = pictureDocument(project.take) { $0.camera.look = CameraColor(preset: .custom, lut: path, intensity: 1) }
        #expect(pictureFrame(custom, take: project.take, at: 0.5).camera?.look?.lut == .file(path))
        // Not there: Natural, without an error.
        let renderer = try FrameRenderer(project: project, document: custom, outputSize: pictureSize)
        #expect(try await rendered(project, custom, renderer: renderer).bytes == natural.bytes)
        // A file that is no `.cube` (a 1D one, a picture, a link), or one where no `.cube` lives: Natural.
        let oneD = "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"
        try CameraPictureFixtures.writeCube(oneD, in: project.package)
        let fresh = try FrameRenderer(project: project, document: custom, outputSize: pictureSize)
        #expect(try await rendered(project, custom, renderer: fresh).bytes == natural.bytes)
        try FileManager.default.removeItem(at: project.package.fileURL(path))
        let elsewhere = dir.appendingPathComponent("elsewhere.cube")
        try Data(invertingCube().utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: project.package.fileURL(path), withDestinationURL: elsewhere)
        let linked = try FrameRenderer(project: project, document: custom, outputSize: pictureSize)
        #expect(try await rendered(project, custom, renderer: linked).bytes == natural.bytes)
        let outside = pictureDocument(project.take) { $0.camera.look = CameraColor(preset: .custom, lut: "elsewhere.cube", intensity: 1) }
        try Data(invertingCube().utf8).write(to: project.package.fileURL("elsewhere.cube"))
        #expect(try await rendered(project, outside).bytes == natural.bytes)

        // Once there, the renderer that found it unreadable reads it after a new scene (`setScene`), not before.
        try FileManager.default.removeItem(at: project.package.fileURL(path))
        try CameraPictureFixtures.writeCube(invertingCube(), in: project.package)
        let stillUnread = try await rendered(project, custom, renderer: renderer)
        #expect(stillUnread.bytes == natural.bytes, "\(stillUnread.middle), \(natural.middle)")
        renderer.setScene(renderer.scene)
        let inverted = try await rendered(project, custom, renderer: renderer)
        let invertedNatural = SIMD4<UInt8>(255 - natural.middle.x, 255 - natural.middle.y, 255 - natural.middle.z, 255)
        #expect(Picture.difference(inverted.middle, invertedNatural) <= 1)
        // And once read, it stays: deleting the file changes nothing for the renderer.
        try FileManager.default.removeItem(at: project.package.fileURL(path))
        renderer.setScene(renderer.scene)
        #expect(try await rendered(project, custom, renderer: renderer).bytes == inverted.bytes)
    }
}
