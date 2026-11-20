// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
// @testable for `ProjectPackage.isValidTrackID`.
@testable import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for the annotations' drawing, `FrameRenderer`'s readers, resources and drawing by frame, the compositor's
// counting `encode`, and the preview engine's hooks.
@testable import Render
import Synchronization
import SyntheticCapture
import Testing
import UniformTypeIdentifiers

// Images and clips over the video (phase 3 design §5.4 and §12, steps 5 and 7; plan 3a, Task A7 and decisions 4 and 13): an
// image of `assets/` decoded once per process with its alpha (`OverlayImageCache`) and uploaded with mipmaps, a clip's
// frames read by readers of their own (`asset:<path>#overlay…`) through the renderer's readers and prefetchers, each fitted
// into or filling its box with its corners and shadow, popped, turned and faded; a file that cannot be read draws nothing;
// the preview draws what the export draws.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
/// The clip's pattern: its frame `i` is `SampleFactory`'s frame `23 + i`.
private let clipPattern = 23

/// The output second of frame `n` of the grid of `rate`.
private func seconds(_ n: Int, rate: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9 }

/// An sRGB PNG of `width × height` at `url`, transparent but for what `draw` paints (in a context with y down, the top
/// row first, and its alpha premultiplied).
private func writePNG(_ url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// Fills `rect` of `context` with `color` (sRGB, straight alpha).
private func fill(_ context: CGContext, _ rect: CGRect, _ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
    context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
    context.fill(rect)
}

/// A take of one display, 640 × 360 at 30 fps for 4 s from `base` with the cursor moving over it, with an image of 100 ×
/// 100 imported into its package (transparent, with an opaque green square from 25 to 75 and a red band at half alpha
/// along its top 10 rows) and a clip of 2 s of 640 × 360 (pattern `clipPattern`); the paths the document names them by.
private func overlayProject(in dir: URL) async throws -> (project: LoadedProject, image: String, clip: String) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 4)])
    try builder.addEvents(cursorEvents(from: base, seconds: 4, across: screenFrame))
    let project = try builder.write()
    let png = dir.appending(path: "logo.png")
    try writePNG(png, width: 100, height: 100) { context in
        fill(context, CGRect(x: 25, y: 25, width: 50, height: 50), 0, 1, 0)
        fill(context, CGRect(x: 0, y: 0, width: 100, height: 10), 1, 0, 0, 0.5)
    }
    let movie = try await offThePool {
        try MediaFixtures.clip(in: dir, seconds: 2, size: [640, 360], pattern: clipPattern)
    }
    let image = try await MediaFixtures.imported(png, into: project, as: .image)
    let clip = try await MediaFixtures.imported(movie, into: project, as: .video)
    return (project, image, clip)
}

/// An annotation of the output over `[from, to)` s of `kind` in `rect`, coming in and going away at once.
private func overlay(
    _ id: Int, _ kind: AnnotationKind, _ rect: NormalizedRect, from: Double, to: Double, layer: Int = 0, rotation: Double = 0
) -> Annotation {
    Annotation(
        id: String(format: "a-%08x", id), anchor: .output(start: TimeMap.outputNanoseconds(seconds: from), end: TimeMap.outputNanoseconds(seconds: to)),
        layer: layer, kind: kind, rect: rect, rotation: rotation, enter: .none, exit: .none)
}

/// The legacy document of `project` with `annotations`.
private func document(_ project: LoadedProject, _ annotations: [Annotation]) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.annotations = AnnotationPlan(items: annotations)
    return document
}

/// Draws frames `frames` of `renderer`'s scene along the grid of `rate`, in order, as the export does
/// (`render(at:into:completion:)`, each decoded ahead through the prefetchers), waiting for each; the bytes of the last.
private func exportBytes(_ renderer: FrameRenderer, frames: ClosedRange<Int>, rate: Int) async throws -> [UInt8] {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    let target = OverlayPixelBuffer(try #require(created))
    for n in frames {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            renderer.render(at: seconds(n, rate: rate), into: target.pixelBuffer) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }
    return packedBytes(of: target.pixelBuffer)
}

private final class OverlayPixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// The frames a preview engine drew, from its hook.
private final class DrawnFrames: Sendable {
    private let frames = Mutex<[PreviewEngine.DrawnFrame]>([])

    func append(_ frame: PreviewEngine.DrawnFrame) { frames.withLock { $0.append(frame) } }
    var all: [PreviewEngine.DrawnFrame] { frames.withLock { $0 } }
    var count: Int { frames.withLock { $0.count } }
}

/// A preview engine of `renderer` drawing into a layer of its own at the renderer's size, and what it drew.
private func engine(_ renderer: FrameRenderer) -> (PreviewEngine, DrawnFrames) {
    let layer = CAMetalLayer()
    CATransaction.begin()
    layer.drawableSize = CGSize(width: renderer.outputSize.x, height: renderer.outputSize.y)
    CATransaction.commit()
    let engine = PreviewEngine(renderer: renderer, layer: layer)
    let drawn = DrawnFrames()
    engine.hooks.onDrawn = { drawn.append($0) }
    engine.hooks.playbackSize = renderer.outputSize
    return (engine, drawn)
}

/// Pixel (`x`, `y`) of `bytes` (BGRA, `width` wide) as integers.
private func at(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int = 640) -> SIMD4<Int> {
    let p = pixel(bytes, width: width, x: x, y: y)
    return SIMD4(Int(p.x), Int(p.y), Int(p.z), Int(p.w))
}

/// Whether `a` and `b` are within `tolerance` in every channel.
private func near(_ a: SIMD4<Int>, _ b: SIMD4<Int>, _ tolerance: Int = 2) -> Bool {
    let d = a &- b
    return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= tolerance
}

/// Whether `pixel` (BGRA) is within `tolerance` of the palette colour of `SampleFactory`'s frame `index`.
private func isFrame(_ pixel: SIMD4<Int>, _ index: Int, tolerance: Int = 24) -> Bool {
    let color = SampleFactory.color(forFrame: index)
    return near(SIMD4(pixel.x, pixel.y, pixel.z, 255), SIMD4(Int(color.z), Int(color.y), Int(color.x), 255), tolerance)
}

/// The sum of a BGRA pixel's colour channels.
private func brightness(_ p: SIMD4<Int>) -> Int { p.x + p.y + p.z }

/// A `.rgba8Unorm` texture with mipmaps (as `OverlayImageTextures` uploads an image) of `width × height`, each pixel
/// `color(x, y)` (RGBA, premultiplied).
private func pictureTexture(
    device: any MTLDevice, width: Int, height: Int, color: (Int, Int) -> SIMD4<UInt8>
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let c = color(x, y), i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (c.x, c.y, c.z, c.w)
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let blit = try #require(commandBuffer.makeBlitCommandEncoder())
    blit.generateMipmaps(for: texture)
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return texture
}

@Suite struct OverlayMediaRenderTests {
    /// A 2:1 image (red on its left half, blue on its right) in a square box of 240 px at (200, 50) of a 640 × 360 output:
    /// fitted, it is 240 × 120 in the box's middle and leaves the bands above and below it as without it (transparent);
    /// filling it, it covers the box, its middle half shown (red on the box's left half, blue on its right). Nothing of it
    /// outside the box. With corners of 0.5 (a circle, half the box's shorter side) a fill's corners are what was under
    /// it, and its middle the image.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func imageFitAndFill() throws {
        let drawer = try StageDrawing.Drawer()
        let picture = try pictureTexture(device: drawer.device, width: 200, height: 100) { x, _ in
            x < 100 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
        let size = SIMD2(640, 360)
        let output = Rect(x: 0, y: 0, width: 640, height: 360)
        let box = Rect(x: 200, y: 50, width: 240, height: 240)
        let asset = "assets/0123456789abcdef0123456789abcdef.png"
        func draw(_ image: ImageAnnotation?) throws -> [UInt8] {
            var frame = RenderFrame(
                outputSize: size, gradientStart: [0.2, 0.3, 0.4, 1], gradientEnd: [0.6, 0.5, 0.3, 1], gradientAngleDegrees: 30,
                screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: output, cornerRadius: 0))
            if let image {
                frame.outputAnnotations = [AnnotationLayer(
                    id: "a-00000001", content: .image(image), rect: box, space: output, unit: 360, rotation: 0, opacity: 1, scale: 1,
                    drawn: 1)]
            }
            let target = try StageDrawing.target(device: drawer.device, size: size)
            let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
            var counts = DrawCounts()
            try drawer.compositor.encode(
                frame, screen: drawer.screen, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer,
                counts: &counts, layerTextures: LayerTextures(media: nil, annotations: AnnotationTextures(images: [asset: picture])))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(counts.outputAnnotations == (image == nil ? 0 : 1))
            return StageDrawing.bytes(of: target)
        }
        let without = try draw(nil)
        let red = SIMD4(0, 0, 255, 255), blue = SIMD4(255, 0, 0, 255)

        let fitted = try draw(ImageAnnotation(asset: asset, fit: .fit))
        // The picture: 240 × 120 from y 110 to 230.
        for (x, y, color) in [(205, 115, red), (300, 170, red), (330, 170, blue), (435, 225, blue)] {
            #expect(near(at(fitted, x, y), color), "fit at (\(x), \(y)): \(at(fitted, x, y))")
        }
        // The bands of the box above and below it, and outside the box: as without it.
        for (x, y) in [(205, 55), (320, 100), (320, 240), (435, 285), (195, 170), (445, 170), (320, 45), (320, 295)] {
            #expect(at(fitted, x, y) == at(without, x, y), "fit at (\(x), \(y))")
        }

        let filled = try draw(ImageAnnotation(asset: asset, fit: .fill))
        for (x, y, color) in [(201, 51, red), (310, 170, red), (330, 170, blue), (438, 288, blue), (201, 288, red), (438, 51, blue)] {
            #expect(near(at(filled, x, y), color), "fill at (\(x), \(y)): \(at(filled, x, y))")
        }
        for (x, y) in [(198, 170), (442, 170), (320, 48), (320, 292)] {
            #expect(at(filled, x, y) == at(without, x, y), "fill at (\(x), \(y))")
        }

        let round = try draw(ImageAnnotation(asset: asset, fit: .fill, corner: 0.5))
        for (x, y) in [(202, 52), (437, 52), (202, 287), (437, 287)] {
            #expect(at(round, x, y) == at(without, x, y), "round at (\(x), \(y))")
        }
        #expect(near(at(round, 250, 170), red) && near(at(round, 390, 170), blue))
    }

    /// A transparent PNG with an opaque green square and a red band at half alpha, over the video with its shadow: where
    /// it is transparent, the frame is exactly as without it, its shadow too (none under its own box); the square is
    /// green; the band is red over what was there; below its box, the shadow darkens the frame; decoded once.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func transparentPNGStaysTransparent() async throws {
        try await withTemporaryDirectory { dir in
            let (project, image, _) = try await overlayProject(in: dir)
            // A box of 200 × 200 at (160, 80): two pixels of the output a pixel of the image.
            let rect = NormalizedRect(x: 0.25, y: 80.0 / 360, width: 200.0 / 640, height: 200.0 / 360)
            let annotations = [overlay(1, .image(ImageAnnotation(asset: image, fit: .fit, shadow: true)), rect, from: 0, to: 4)]
            let renderer = try FrameRenderer(project: project, document: document(project, annotations), outputSize: [640, 360])
            let legacy = try FrameRenderer(project: project, outputSize: [640, 360])
            let (drawn, without) = try await offThePool { (try renderer.renderBytes(at: 1), try legacy.renderBytes(at: 1)) }
            // Transparent: inside the box, away from the square and the band, and at its corners.
            for (x, y) in [(170, 150), (200, 250), (350, 150), (162, 278), (357, 278), (300, 120)] {
                #expect(at(drawn, x, y) == at(without, x, y), "at (\(x), \(y))")
            }
            // The square.
            for (x, y) in [(212, 132), (260, 180), (307, 227)] {
                #expect(near(at(drawn, x, y), [0, 255, 0, 255]), "at (\(x), \(y)): \(at(drawn, x, y))")
            }
            // The band: half red over the frame.
            for (x, y) in [(200, 84), (300, 95)] {
                let (over, under) = (at(drawn, x, y), at(without, x, y))
                #expect(abs(over.z - (255 + under.z) / 2) <= 3 && abs(over.y - under.y / 2) <= 3, "at (\(x), \(y)): \(over) over \(under)")
            }
            // Its shadow, under the box (0.01 × 200 down, σ 4 px): darker just below it, as without it far from it.
            #expect(brightness(at(drawn, 260, 284)) < brightness(at(without, 260, 284)) - 10)
            #expect(at(drawn, 260, 300) == at(without, 260, 300) && at(drawn, 140, 180) == at(without, 140, 180))
            #expect(OverlayImageCache.shared.decodeCount(of: image, in: project.package) == 1)
            #expect(renderer.annotationResources.images.uploadCount == 1)
        }
    }

    /// A clip over the video from 0.5 s to 2.5 s of the output, its file from 0: at 1 s its file's 0.5 s shows (frame 15),
    /// at 2 s its 1.5 s (frame 45), fitted into its box; read by the readers of the clips over the video
    /// (`asset:<path>#overlay`), never the sequence's; none before 0.5 s. The export draws the same frames.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func clipOverlayShowsItsFileFrames() async throws {
        try await withTemporaryDirectory { dir in
            let (project, _, clip) = try await overlayProject(in: dir)
            let rect = NormalizedRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)
            let annotations = [overlay(1, .clip(ClipAnnotation(asset: clip, start: 0, end: 2_000_000_000, corner: 0.05, shadow: true)), rect, from: 0.5, to: 2.5)]
            let renderer = try FrameRenderer(
                project: project, document: document(project, annotations), outputSize: [640, 360], frameRate: 30)
            let id = FrameRenderer.overlayReaderID(of: clip, lane: 0)
            #expect(id == "asset:" + clip + "#overlay" && AssetFrameReader.asset(ofReaderID: id) == clip)
            #expect(!ProjectPackage.isValidTrackID(id))
            let early = try renderer.frame(of: renderer.scene, at: 0.4)
            #expect(!renderer.videos(of: early).contains { $0.trackID.hasPrefix("asset:") })
            let frame = try renderer.frame(of: renderer.scene, at: 1)
            #expect(renderer.videos(of: frame).filter { $0.trackID.hasPrefix("asset:") }
                == [DecodedKey(trackID: id, time: HostTime(nanoseconds: 500_000_000))])
            let (first, second) = try await offThePool { (try renderer.renderBytes(at: 1), try renderer.renderBytes(at: 2)) }
            // The box: (320, 180) 256 × 144, the clip's proportion.
            for (x, y) in [(448, 252), (330, 300), (566, 200)] {
                #expect(isFrame(at(first, x, y), (clipPattern + 15) % 64), "1 s at (\(x), \(y)): \(at(first, x, y))")
                #expect(isFrame(at(second, x, y), (clipPattern + 45) % 64), "2 s at (\(x), \(y)): \(at(second, x, y))")
            }
            let exported = try await exportBytes(renderer, frames: 0...60, rate: 30)
            #expect(exported == second)
            #expect(renderer.mediaResources.readerCount == 1 && renderer.reader(for: id) != nil)
            #expect(renderer.reader(for: AssetFrameReader.readerID(of: clip))?.openedReaderCount ?? 0 == 0)
        }
    }

    /// One reader of a file for its clips over the video: two clips of it one after the other share it. A file in the
    /// sequence and over the video at another instant at once is read by two (the sequence's and the overlays'), and two
    /// clips over the video of one file at different instants at once by two lanes: each reader read forward, opened once,
    /// never back and forth.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func oneReaderPerAsset() async throws {
        try await withTemporaryDirectory { dir in
            let (project, _, clip) = try await overlayProject(in: dir)
            let rect = NormalizedRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3)
            let other = NormalizedRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
            func clipKind(from start: Double) -> AnnotationKind {
                .clip(ClipAnnotation(asset: clip, start: TimeMap.outputNanoseconds(seconds: start), end: 2_000_000_000))
            }
            // One after the other, the second where the first ends (its file's 0–1 s, then its 1–2 s): one reader for both,
            // read on from one into the other, while the second is shown.
            let sequential = try FrameRenderer(
                project: project,
                document: document(project, [
                    overlay(1, clipKind(from: 0), rect, from: 0.2, to: 1.2), overlay(2, clipKind(from: 1), other, from: 1.2, to: 2.2),
                ]), outputSize: [640, 360], frameRate: 30)
            let lane = FrameRenderer.overlayReaderID(of: clip, lane: 0)
            for n in stride(from: 0, through: 60, by: 3) {
                let ids = Set(sequential.videos(of: try sequential.frame(of: sequential.scene, at: seconds(n, rate: 30))).map(\.trackID))
                #expect(ids.filter { $0.hasPrefix("asset:") }.isSubset(of: [lane]), "frame \(n): \(ids)")
            }
            _ = try await exportBytes(sequential, frames: 0...60, rate: 30)
            #expect(sequential.mediaResources.readerCount == 1)
            #expect(sequential.reader(for: lane)?.openedReaderCount == 1)

            // In the sequence at 2 s of the take (its file's 0–2 s, output 2–4 s), and over it from 2 s, its file from 0.5 s
            // (until 3.5 s): at 3 s the sequence shows the file's 1 s, the overlay its 1.5 s. And a second clip over the
            // video from 2.5 s, its file from 0, at once with the first (its lane 2).
            var both = document(project, [
                overlay(1, clipKind(from: 0.5), rect, from: 2, to: 4), overlay(2, clipKind(from: 0), other, from: 2.5, to: 4),
            ])
            let take = both.sequence[0]
            let point = take.start.adding(seconds: 2)
            var head = take, tail = take
            (head.id, head.end) = ("c-00000001", point)
            (tail.id, tail.start) = ("c-00000003", point)
            both.sequence = [
                head,
                Clip(
                    id: "c-00000002", take: take.take, start: point, end: point, speed: 1,
                    content: .media(MediaClip(asset: clip, start: 0, end: 2_000_000_000))),
                tail,
            ]
            let renderer = try FrameRenderer(project: project, document: both, outputSize: [640, 360], frameRate: 30)
            let frame = try renderer.frame(of: renderer.scene, at: 3)
            let lane2 = FrameRenderer.overlayReaderID(of: clip, lane: 1)
            #expect(Set(renderer.videos(of: frame).filter { $0.trackID.hasPrefix("asset:") }) == [
                DecodedKey(trackID: AssetFrameReader.readerID(of: clip), time: HostTime(nanoseconds: 1_000_000_000)),
                DecodedKey(trackID: lane, time: HostTime(nanoseconds: 1_500_000_000)),
                DecodedKey(trackID: lane2, time: HostTime(nanoseconds: 500_000_000)),
            ])
            // Up to 3 s, and the frames decoded ahead of it: before the first clip over the video ends (3.5 s), when the second
            // takes its lane.
            let exported = try await exportBytes(renderer, frames: 55...90, rate: 30)
            #expect(renderer.mediaResources.readerCount == 3)
            for id in [AssetFrameReader.readerID(of: clip), lane, lane2] {
                let reader = try #require(renderer.reader(for: id), "\(id)")
                #expect(reader.openedReaderCount == 1, "\(id): \(reader.openedReaderCount)")
            }
            let fresh = try FrameRenderer(project: project, document: both, outputSize: [640, 360], frameRate: 30)
            let alone = try await offThePool { try fresh.renderBytes(at: seconds(90, rate: 30)) }
            #expect(alone == exported)
        }
    }

    /// The image's file deleted, the clip's a link to a copy outside the package, and an image named outside `assets/`:
    /// the frame is the take's as without them, frame by frame and as the export draws it, without an error; nothing is
    /// uploaded nor read for them, and a text with them is drawn as ever.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aMissingImageOrClipDrawsNothing() async throws {
        try await withTemporaryDirectory { dir in
            let (project, image, clip) = try await overlayProject(in: dir)
            try FileManager.default.removeItem(at: project.package.fileURL(image))
            let file = project.package.fileURL(clip), outside = dir.appending(path: "outside.mov")
            try FileManager.default.moveItem(at: file, to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
            let annotations = [
                overlay(1, .image(ImageAnnotation(asset: image, fit: .fill, shadow: true)), rect, from: 0, to: 4),
                overlay(2, .clip(ClipAnnotation(asset: clip, start: 0, end: 2_000_000_000, shadow: true)), rect, from: 0, to: 4),
                overlay(3, .image(ImageAnnotation(asset: "takes/take-001/manifest.png", fit: .fit)), rect, from: 0, to: 4),
            ]
            let renderer = try FrameRenderer(
                project: project, document: document(project, annotations), outputSize: [640, 360], frameRate: 30)
            let legacy = try FrameRenderer(project: project, document: .legacy(for: project), outputSize: [640, 360], frameRate: 30)
            for t in [0.5, 1.5] {
                let (drawn, without) = try await offThePool { (try renderer.renderBytes(at: t), try legacy.renderBytes(at: t)) }
                #expect(drawn == without, "at \(t) s")
            }
            let exported = try await exportBytes(renderer, frames: 30...45, rate: 30)
            let legacyExported = try await offThePool { try legacy.renderBytes(at: 1.5) }
            #expect(exported == legacyExported)
            #expect(renderer.mediaResources.readerCount == 0)
            #expect(renderer.annotationResources.images.uploadCount == 0)
            // A text with them is drawn.
            var text = annotations
            text.append(overlay(4, .text(TextAnnotation(string: "Hello", preset: .label)), rect, from: 0, to: 4, layer: 1))
            let withText = try FrameRenderer(project: project, document: document(project, text), outputSize: [640, 360])
            let (texted, plain) = try await offThePool { (try withText.renderBytes(at: 1), try legacy.renderBytes(at: 1)) }
            #expect(texted != plain)
        }
    }

    /// An image and a clip over the video, rotated, with corners and shadows, at half opacity, and an image stuck to the
    /// recording through a zoom: the preview paused on a frame, the export along the grid up to it and the frame drawn
    /// alone, the same bytes; the image decoded once for the preview's renderer and the export's.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func previewEqualsExportWithOverlays() async throws {
        try await withTemporaryDirectory { dir in
            let (project, image, clip) = try await overlayProject(in: dir)
            var annotations = [
                overlay(1, .clip(ClipAnnotation(asset: clip, start: 250_000_000, end: 2_000_000_000, corner: 0.1, shadow: true)),
                        NormalizedRect(x: 0.45, y: 0.4, width: 0.4, height: 0.4), from: 0.5, to: 2.5, rotation: -6),
                overlay(2, .image(ImageAnnotation(asset: image, fit: .fill, corner: 0.2, shadow: true)),
                        NormalizedRect(x: 0.1, y: 0.1, width: 0.25, height: 0.3), from: 0, to: 4, layer: 1, rotation: 12),
            ]
            annotations[1].opacity = 0.5
            annotations.append(Annotation(
                id: "a-00000003", anchor: .content(take: project.take.id, start: base, end: base.adding(seconds: 4)), layer: 0,
                kind: .image(ImageAnnotation(asset: image, fit: .fit)), rect: NormalizedRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)))
            var edited = document(project, annotations)
            edited.zoom.regions = [StageDrawing.zoom(1, from: 1, to: 3, depth: 1.6, focus: .fixed(x: 0.6, y: 0.3))]
            let size = SIMD2(640, 360), rate = 30, n = 60
            func renderer() throws -> FrameRenderer {
                try FrameRenderer(project: project, document: edited, outputSize: size, frameRate: rate)
            }
            let export = try renderer()
            let frame = try export.frame(of: export.scene, at: seconds(n, rate: rate))
            #expect(frame.outputAnnotations.count == 2 && frame.contentAnnotations.count == 1)
            let exported = try await exportBytes(export, frames: 40...n, rate: rate)
            let alone = try await offThePool { try export.renderBytes(at: seconds(n, rate: rate)) }
            #expect(exported == alone)
            let legacy = try FrameRenderer(project: project, document: .legacy(for: project), outputSize: size, frameRate: rate)
            let plain = try await offThePool { try legacy.renderBytes(at: seconds(n, rate: rate)) }
            #expect(alone != plain)

            let (paused, pausedFrames) = engine(try renderer())
            paused.request(.paused(frame: n))
            #expect(await eventually(timeout: .seconds(30)) { pausedFrames.count >= 1 })
            #expect(try await paused.drawnBytes() == exported)
            #expect(OverlayImageCache.shared.decodeCount(of: image, in: project.package) == 1)
        }
    }

    /// An image coming in at 1 s: the frames before it hand it over (`RenderFrame.annotationsAhead`), and it is decoded and
    /// uploaded in the background, so the frame it comes in uploads nothing; the same bytes as one made in its frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func imagesComingInAreUploadedAhead() async throws {
        try await withTemporaryDirectory { dir in
            let (project, image, _) = try await overlayProject(in: dir)
            let annotations = [
                overlay(1, .image(ImageAnnotation(asset: image, fit: .fit)), NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5), from: 1, to: 3),
            ]
            let renderer = try FrameRenderer(project: project, document: document(project, annotations), outputSize: [640, 360], frameRate: 30)
            let before = try renderer.frame(of: renderer.scene, at: 0.8)
            #expect(before.outputAnnotations.isEmpty && before.annotationsAhead.contains { $0.layer.id == "a-00000001" })
            _ = try await offThePool { try renderer.renderBytes(at: 0.8) }
            renderer.annotationResources.images.waitUntilPrepared()
            #expect(renderer.annotationResources.images.uploadCount == 1)
            let shown = try await offThePool { try renderer.renderBytes(at: 1.2) }
            #expect(renderer.annotationResources.images.uploadCount == 1)
            let fresh = try FrameRenderer(project: project, document: document(project, annotations), outputSize: [640, 360], frameRate: 30)
            let made = try await offThePool { try fresh.renderBytes(at: 1.2) }
            #expect(made == shown)
        }
    }

    /// The preview at 1080p with ten annotations, two images and a clip among them (phase 3 design §15): a take of 1920 ×
    /// 1080, seven annotations drawn as bitmaps (five stuck to the recording, two of the output), two images (a photo of
    /// 1600 × 1200 with its shadow and a transparent PNG) and a clip of 1280 × 720 over it; 120 frames at 60 fps played by
    /// the preview engine at the export's size, one request every 1/60 s, and drawn in order as the export does; against
    /// the same without annotations.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .timeLimit(.minutes(10)))
    func annotationsPreviewBench() async throws {
        try await withTemporaryDirectory { dir in
            let whole = Rect(x: 0, y: 0, width: 1920, height: 1080)
            let builder = try TakeBuilder(in: dir)
            try await builder.addVideoTrack(
                id: trackID, source: displaySource(globalFrame: whole),
                segments: [VideoSegmentSpec(start: base, seconds: 4, width: 1920, height: 1080)])
            try builder.addEvents(cursorEvents(from: base, seconds: 4, across: whole))
            let project = try builder.write()
            let photo = dir.appending(path: "photo.png"), logo = dir.appending(path: "logo.png")
            try writePNG(photo, width: 1600, height: 1200) { context in
                for k in 0..<12 {
                    fill(context, CGRect(x: 0, y: k * 100, width: 1600, height: 100), Double(k) / 12, 0.4, 1 - Double(k) / 12)
                }
            }
            try writePNG(logo, width: 800, height: 800) { context in
                context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1))
                context.fillEllipse(in: CGRect(x: 100, y: 100, width: 600, height: 600))
            }
            let movie = try await offThePool { try MediaFixtures.clip(in: dir, seconds: 4, size: [1280, 720], pattern: 5) }
            let photoAsset = try await MediaFixtures.imported(photo, into: project, as: .image)
            let logoAsset = try await MediaFixtures.imported(logo, into: project, as: .image)
            let clipAsset = try await MediaFixtures.imported(movie, into: project, as: .video)

            let stuck = AnnotationAnchor.content(take: project.take.id, start: base, end: base.adding(seconds: 4))
            let over = AnnotationAnchor.output(start: 0, end: TimeMap.outputNanoseconds(seconds: 4))
            let callout = CalloutAnnotation(
                text: TextAnnotation(string: "Click here", preset: .label, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1)),
                target: NormalizedPoint(x: 0.6, y: 0.5))
            let items: [(AnnotationAnchor, AnnotationKind, NormalizedRect)] = [
                (stuck, .text(TextAnnotation(string: "Step one: open the settings", preset: .plain)), NormalizedRect(x: 0.05, y: 0.06, width: 0.4, height: 0.1)),
                (stuck, .text(TextAnnotation(string: "New", preset: .label)), NormalizedRect(x: 0.5, y: 0.06, width: 0.1, height: 0.1)),
                (stuck, .arrow(ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.6), to: NormalizedPoint(x: 0.45, y: 0.4), curve: 0.3, head: .filled)),
                 NormalizedRect(x: 0, y: 0, width: 1, height: 1)),
                (stuck, .callout(callout), NormalizedRect(x: 0.65, y: 0.15, width: 0.2, height: 0.1)),
                (stuck, .step(StepAnnotation()), NormalizedRect(x: 0.46, y: 0.44, width: 0.07, height: 0.07)),
                (over, .text(TextAnnotation(string: "Ana Pérez\nProduct design", preset: .lowerThird)), NormalizedRect(x: 0.05, y: 0.78, width: 0.3, height: 0.1)),
                (over, .shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(1, 1, 0, 0.2))), NormalizedRect(x: 0.55, y: 0.45, width: 0.25, height: 0.25)),
                (over, .image(ImageAnnotation(asset: photoAsset, fit: .fill, corner: 0.05, shadow: true)), NormalizedRect(x: 0.7, y: 0.05, width: 0.25, height: 0.3)),
                (over, .image(ImageAnnotation(asset: logoAsset, fit: .fit)), NormalizedRect(x: 0.4, y: 0.7, width: 0.12, height: 0.2)),
                (over, .clip(ClipAnnotation(asset: clipAsset, start: 0, end: 4_000_000_000, corner: 0.03, shadow: true)),
                 NormalizedRect(x: 0.62, y: 0.6, width: 0.33, height: 0.33)),
            ]
            let annotations = items.enumerated().map { k, item in
                Annotation(id: String(format: "a-%08x", k + 1), anchor: item.0, layer: k, kind: item.1, rect: item.2)
            }
            #expect(annotations.count == 10)
            let edited = document(project, annotations)
            let size = SIMD2(1920, 1080), rate = 60, frames = 120

            /// 120 frames played by an engine, one request every 1/60 s: how many were drawn, how many late, and the
            /// median and the 95th percentile of their duration (from the start of their work to the GPU's end), ms.
            func play(_ document: EditDocument) async throws -> (drawn: Int, late: Int, median: Double, p95: Double) {
                let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
                let (engine, drawn) = engine(renderer)
                // The first frame (images decoded, readers opened), as after a jump: not measured.
                engine.request(.playing(seconds: 0))
                #expect(await eventually(timeout: .seconds(30)) { drawn.count >= 1 })
                let start = drawn.count
                let clock = ContinuousClock()
                let began = clock.now
                for k in 1...frames {
                    engine.request(.playing(seconds: seconds(k, rate: rate)))
                    try await Task.sleep(until: began + .microseconds(Int64(k) * 1_000_000 / Int64(rate)), clock: clock)
                }
                try await Task.sleep(for: .milliseconds(200))
                let measured = Array(drawn.all.dropFirst(start))
                let durations = measured.map { $0.duration * 1000 }.sorted()
                engine.request(.paused(frame: 0))
                return (
                    measured.count, measured.filter(\.late).count, durations.isEmpty ? 0 : durations[durations.count / 2],
                    durations.isEmpty ? 0 : durations[min(durations.count - 1, durations.count * 95 / 100)]
                )
            }
            /// 120 frames drawn in order as the export does, in s.
            func export(_ document: EditDocument) async throws -> Double {
                let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
                _ = try await exportBytes(renderer, frames: 0...0, rate: rate)
                let started = ContinuousClock.now
                _ = try await exportBytes(renderer, frames: 1...frames, rate: rate)
                let elapsed = ContinuousClock.now - started
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }
            let legacy = EditDocument.legacy(for: project)
            // The process's first playback (the decoders' sessions, the shaders), not measured.
            _ = try await play(legacy)
            let none = try await play(legacy), ten = try await play(edited)
            let exportNone = try await export(legacy), exportTen = try await export(edited)
            print(String(
                format: "Preview at 1080p, 120 frames at 60 fps (drawn, late, median / p95 ms): none %d, %d, %.2f / %.2f; "
                    + "ten annotations with two images and a clip %d, %d, %.2f / %.2f. Export of 120 frames: none %.2f s (%.0f fps), "
                    + "ten %.2f s (%.0f fps)",
                none.drawn, none.late, none.median, none.p95, ten.drawn, ten.late, ten.median, ten.p95, exportNone,
                Double(frames) / exportNone, exportTen, Double(frames) / exportTen))
            #expect(ten.p95 < 1000.0 / 60, "\(ten)")
        }
    }
}
