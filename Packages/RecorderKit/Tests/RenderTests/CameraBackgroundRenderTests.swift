// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `FrameRenderer.videos(of:)`, `reader(for:)`, `CameraLookTextures`,
// `DrawCounts`, the compositor's `cameraFill` and `TrackFrameReader.askedTimes`.
@testable import Render
import SyntheticCapture
import Testing

// The camera's background drawn (plan 2b task I10, phase 2 design §6.1, `personMask-1`): the person's mask read like the
// camera at its own source instant, bilinear and through `smoothstep(0.35, 0.65)`; Blurred, the camera's own frame
// blurred behind the person inside its shape; Removed, the person alone over the scene in a Bubble and over the project's
// background in a card. A mask that is not there draws the camera as it is, never an error. Over textures with a
// compositor of its own (`CameraPictureDrawer`), and through the renderer from video: a take's camera and a mask written
// as the analysis caches keep one (`CameraPictureFixtures.writeMask`).

private let isMetal = MetalCondition.isAvailable || MetalCondition.isRequired
private let camera = (width: 640, height: 360)
private let mask = (width: 320, height: 180)

/// The person's camera and mask (`CameraPictureFixtures`) as textures of those sizes.
private func personTextures(
    _ device: any MTLDevice, camera size: (width: Int, height: Int) = camera, mask maskSize: (width: Int, height: Int) = mask
) throws -> (camera: SentTexture, mask: SentTexture) {
    (
        SentTexture(try CameraPictureFixtures.texture(device, width: size.width, height: size.height) {
            CameraPictureFixtures.person($0, $1, width: size.width, height: size.height)
        }),
        SentTexture(try CameraPictureFixtures.maskTexture(device, width: maskSize.width, height: maskSize.height) {
            CameraPictureFixtures.personMask($0, $1, width: maskSize.width, height: maskSize.height)
        })
    )
}

/// Where the centre of output pixel (`x`, `y`) falls in the camera's frame (fractions of it), for `layer` filled with
/// `fill` (`Compositor.cameraFill`), not mirrored.
private func frameUV(_ x: Int, _ y: Int, _ layer: CameraLayer, _ fill: (origin: SIMD2<Float>, size: SIMD2<Float>)) -> SIMD2<Double> {
    let inRect = SIMD2((Double(x) + 0.5 - layer.rect.x) / layer.rect.width, (Double(y) + 0.5 - layer.rect.y) / layer.rect.height)
    return SIMD2<Double>(fill.origin) + inRect * SIMD2<Double>(fill.size)
}

/// How far the camera's point `uv` is outside the person, in fractions of the frame's height (negative inside).
private func personDistance(_ uv: SIMD2<Double>) -> Double {
    CameraPictureFixtures.personDistance(u: uv.x, v: uv.y, aspect: Double(camera.width) / Double(camera.height))
}

/// Whether `p`, at the camera's point `uv` on the person, is the person's own colour there (skin, hair, shirt), or a
/// blend of two of them where they meet (at 0.27 and 0.72 of the frame's height).
private func isPerson(_ p: SIMD4<UInt8>, at uv: SIMD2<Double>) -> Bool {
    if abs(uv.y - 0.27) < 0.01 || abs(uv.y - 0.72) < 0.01 { return true }
    return [CameraPictureFixtures.skin, CameraPictureFixtures.hair, CameraPictureFixtures.shirt].contains { Picture.difference(p, $0) <= 3 }
}

private func isBackdrop(_ p: SIMD4<UInt8>) -> Bool { Picture.difference(p, [64, 64, 64, 255]) <= 0 }

@Test(.enabled(if: isMetal))
func blurredMixesByTheMask() async throws {
    let drawer = try CameraPictureDrawer()
    // A checkerboard of 20 px squares, and a mask white on its left half: sharp on the left, blurred on the right.
    let a = CameraPictureFixtures.checkerA, b = CameraPictureFixtures.checkerB
    let checker = SentTexture(try CameraPictureFixtures.texture(drawer.device, width: camera.width, height: camera.height) { x, y in
        (x / 20 + y / 20) % 2 == 0 ? a : b
    })
    let left = SentTexture(try CameraPictureFixtures.maskTexture(drawer.device, width: mask.width, height: mask.height) { x, _ in
        x < mask.width / 2 ? 255 : 0
    })
    let blurred = pictureDocument { document in
        document.camera.layout = CameraLayout(kind: .cameraFull)
        document.camera.background = .blurred
    }
    let frame = pictureFrame(blurred, analysis: pictureMasks())
    let layer = try #require(frame.camera)
    #expect(layer.background?.mode == .blurred && frame.coveredByCamera)
    #expect(layer.rect == Rect(x: 0, y: 0, width: 640, height: 360))
    let drawn = try await offThePool { try drawer.draw(frame, camera: checker, mask: left) }
    #expect(drawn.counts.cameraLooks == 1 && drawn.counts.cameraBackgrounds == 1, "\(drawn.counts)")
    /// The share of `xs` (every row) that is one of the board's two colours, and how much the colour changes from a
    /// pixel to the next, on average.
    func look(_ xs: Range<Int>) -> (board: Double, change: Double) {
        var board = 0, change = 0, count = 0
        for y in 0..<pictureSize.y {
            for x in xs {
                let p = pixel(drawn.bytes, width: pictureSize.x, x: x, y: y)
                if Picture.difference(p, a) <= 1 || Picture.difference(p, b) <= 1 { board += 1 }
                change += Picture.difference(p, pixel(drawn.bytes, width: pictureSize.x, x: x + 1, y: y))
                count += 1
            }
        }
        return (Double(board) / Double(count), Double(change) / Double(count))
    }
    let sharp = look(0..<300), soft = look(340..<639)
    #expect(sharp.board > 0.999, "\(sharp)")
    #expect(soft.board < 0.2 && soft.change * 4 < sharp.change, "\(soft) against \(sharp)")

    // Without its mask, the camera's original, as in phase 1.
    let original = pictureFrame(pictureDocument { $0.camera.layout = CameraLayout(kind: .cameraFull) })
    let (without, expected) = try await offThePool {
        (try drawer.draw(frame, camera: checker), try drawer.draw(original, camera: checker, look: false))
    }
    #expect(without.counts.cameraBackgrounds == 0 && without.counts.cameraLooks == 0)
    #expect(without.bytes == expected.bytes)
}

@Test(.enabled(if: isMetal))
func removedBubbleShowsTheSceneThroughThePerson() async throws {
    let drawer = try CameraPictureDrawer()
    let textures = try personTextures(drawer.device)
    // A circle with a border and a shadow: removed, the person over the scene in its rect, without either.
    let removed = pictureDocument { document in
        document.camera.initial[takeID] = CameraStyle(shape: .circle, size: 0.6, anchor: .bottom)
        document.camera.border = CameraBorder(width: 0.6, color: RGBA(1, 0, 0, 1))
        document.camera.shadow = 0.8
        document.camera.background = .removed
    }
    let frame = pictureFrame(removed, analysis: pictureMasks())
    let layer = try #require(frame.camera)
    #expect(layer.background?.overScene == true && layer.cornerRadius == 0 && layer.border == nil && layer.shadow == nil)
    var cameraless = frame
    cameraless.camera = nil
    let scene = cameraless
    let (drawn, under) = try await offThePool {
        (try drawer.draw(frame, camera: textures.camera, mask: textures.mask), try drawer.draw(scene, camera: nil))
    }
    #expect(drawn.counts.cameraBackgrounds == 1 && drawn.counts.cameraShadows == 0 && drawn.counts.cameraBorders == 0)
    let fill = drawer.compositor.cameraFill(layer, texture: textures.camera.texture)
    var throughScene = 0, person = 0, outsideTheCircle = 0
    var wrong: [String] = []
    for y in 0..<pictureSize.y {
        for x in 0..<pictureSize.x {
            let p = pixel(drawn.bytes, width: pictureSize.x, x: x, y: y)
            guard Picture.isInside(x, y, layer.rect, by: 1) else {
                // Outside the rect, the scene.
                if !Picture.touches(x, y, layer.rect), p != pixel(under.bytes, width: pictureSize.x, x: x, y: y) {
                    wrong.append("off (\(x), \(y))")
                }
                continue
            }
            let uv = frameUV(x, y, layer, fill), d = personDistance(uv)
            if d > 0.02 {
                // Off the person: the scene, every byte.
                throughScene += 1
                if p != pixel(under.bytes, width: pictureSize.x, x: x, y: y) { wrong.append("scene (\(x), \(y)): \(p)") }
            } else if d < -0.02 {
                person += 1
                if !isPerson(p, at: uv) { wrong.append("person (\(x), \(y)): \(p)") }
                if !Picture.isInsideCircle(x, y, layer.rect, by: 1) { outsideTheCircle += 1 }
            }
        }
    }
    #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(4))")
    #expect(throughScene > 10_000 && person > 10_000, "\(throughScene), \(person)")
    // The shoulders run past the circle the bubble would have: no shape.
    #expect(outsideTheCircle > 200, "\(outsideTheCircle)")
}

@Test(.enabled(if: isMetal))
func removedCardShowsTheBackground() async throws {
    let drawer = try CameraPictureDrawer()
    let textures = try personTextures(drawer.device)
    for kind in [LayoutKind.cameraOnly, .split, .cameraFull] {
        let removed = pictureDocument { document in
            document.camera.layout = CameraLayout(kind: kind, split: kind == .split ? SplitLayout() : nil)
            document.camera.border = CameraBorder(width: 0.6, color: RGBA(1, 0, 0, 1))
            document.camera.shadow = 0.8
            document.camera.background = .removed
        }
        let frame = pictureFrame(removed, analysis: pictureMasks())
        let layer = try #require(frame.camera, "\(kind)")
        #expect(layer.background?.overScene == false && layer.shadow == nil && !frame.coveredByCamera, "\(kind)")
        var cameraless = frame
        cameraless.camera = nil
        let under = cameraless
        let (drawn, scene) = try await offThePool {
            (try drawer.draw(frame, camera: textures.camera, mask: textures.mask), try drawer.draw(under, camera: nil))
        }
        #expect(drawn.counts.cameraBackgrounds == 1 && drawn.counts.cameraShadows == 0, "\(kind): \(drawn.counts)")
        let fill = drawer.compositor.cameraFill(layer, texture: textures.camera.texture)
        let border = layer.border?.width ?? 0
        var background = 0, person = 0
        var wrong: [String] = []
        for y in 0..<pictureSize.y {
            for x in 0..<pictureSize.x where Picture.isInside(x, y, layer.rect, by: border + 2) {
                let p = pixel(drawn.bytes, width: pictureSize.x, x: x, y: y)
                let uv = frameUV(x, y, layer, fill), d = personDistance(uv)
                if d > 0.02 {
                    // Off the person, what is under the card: the project's background.
                    background += 1
                    if p != pixel(scene.bytes, width: pictureSize.x, x: x, y: y) || !isBackdrop(p) {
                        wrong.append("background (\(x), \(y)): \(p)")
                    }
                } else if d < -0.02 {
                    person += 1
                    if !isPerson(p, at: uv) { wrong.append("person (\(x), \(y)): \(p)") }
                }
            }
        }
        #expect(wrong.isEmpty, "\(kind): \(wrong.count), \(wrong.prefix(4))")
        #expect(background > 2_000 && person > 2_000, "\(kind): \(background), \(person)")
        // The card keeps its border (Camera full screen has none): red across it, in the middle of each side.
        if border >= 2 {
            let r = layer.rect, inset = border / 2
            let sides = [
                (Int(r.x + inset), Int(r.y + r.height / 2)), (Int(r.x + r.width - inset), Int(r.y + r.height / 2)),
                (Int(r.x + r.width / 2), Int(r.y + inset)), (Int(r.x + r.width / 2), Int(r.y + r.height - inset)),
            ]
            for (x, y) in sides {
                let p = pixel(drawn.bytes, width: pictureSize.x, x: x, y: y)
                #expect(Picture.difference(p, [0, 0, 255, 255]) <= 2, "\(kind): the border at (\(x), \(y)) is \(p)")
            }
        } else {
            #expect(kind == .cameraFull, "\(kind): a border of \(border)")
        }
    }
}

// MARK: - Through the renderer, from video

/// A take of `seconds` of a blue screen, and a camera of `segments` (from, seconds) painted with `paint` (`SampleFactory`'s
/// numbered frames when `nil`), with each segment's mask written where the analysis caches keep them, of `value` (frame
/// `n` of the track, pixel (`x`, `y`) of a `mask`-sized frame): the project, and the analysis that hands the masks over.
private func maskedProject(
    in dir: URL, seconds: Double = 3, segments: [(from: Double, seconds: Double)] = [(0, 3)],
    paint: (@Sendable (_ frame: Int, CMSampleBuffer) -> CMSampleBuffer)? = nil,
    value: @escaping @Sendable (_ frame: Int, _ x: Int, _ y: Int) -> UInt8
) async throws -> (project: LoadedProject, analysis: AnalysisInputs, masks: [URL]) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: pictureScreen),
        segments: [VideoSegmentSpec(start: base, seconds: seconds, transform: { _, sample in
            CameraPictureFixtures.painting(sample) { _, _, _, _ in CameraPictureFixtures.blue }
        })])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource,
        segments: segments.map { VideoSegmentSpec(start: base.adding(seconds: $0.from), seconds: $0.seconds, transform: paint) })
    let project = try builder.write()
    var analysis = AnalysisInputs()
    var urls: [URL] = []
    var first = 0
    for (k, s) in segments.enumerated() {
        let url = dir.appendingPathComponent("caches/masks/\(takeID)/\(cameraID)/seg-000\(k + 1)-personMask-1.mov")
        try await CameraPictureFixtures.writeMask(
            to: url, scratch: dir.appendingPathComponent("scratch"), start: base.adding(seconds: s.from), seconds: s.seconds,
            width: mask.width, height: mask.height, firstFrame: first, value: value)
        first += Int((s.seconds * 30).rounded())
        analysis.personMasks[CameraSegment(take: takeID, track: cameraID, segment: k + 1)] = url
        urls.append(url)
    }
    return (project, analysis, urls)
}

/// The person's camera frame (`CameraPictureFixtures.person`), painted into every frame.
private let personFrame = CameraPictureFixtures.bytes(width: camera.width, height: camera.height) {
    CameraPictureFixtures.person($0, $1, width: camera.width, height: camera.height)
}

@Sendable private func paintingThePerson(_ frame: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    CameraPictureFixtures.copying(sample, bytes: personFrame)
}

@Sendable private func personMaskValue(_ frame: Int, _ x: Int, _ y: Int) -> UInt8 {
    CameraPictureFixtures.personMask(x, y, width: mask.width, height: mask.height)
}

/// A pixel buffer the export draws into, handed to the renderer's queues.
private final class ExportTarget: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(size: SIMD2<Int>) throws {
        var created: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let created else { throw TestSupportError.failed("no pixel buffer: \(status)") }
        pixelBuffer = created
    }
}

/// `renderer`'s frame at `t` drawn as the export draws it (`render(at:into:completion:)`), as its bytes.
private func exported(_ renderer: FrameRenderer, at t: Double) async throws -> [UInt8] {
    let target = try ExportTarget(size: renderer.outputSize)
    let error: (any Error)? = await withCheckedContinuation { continuation in
        renderer.render(at: t, into: target.pixelBuffer) { continuation.resume(returning: $0) }
    }
    if let error { throw error }
    return packedBytes(of: target.pixelBuffer)
}

/// Output seconds of frame `n` of a grid of 30 fps.
private func gridTime(_ n: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9 }

@Test(.enabled(if: isMetal), .timeLimit(.minutes(5)))
func maskIsReadAtTheCameraTime() async throws {
    try await withTemporaryDirectory { dir in
        // Two camera segments, 0 to 1 s and 1.3 to 2.5 s, of `SampleFactory`'s numbered frames (the second's from 30),
        // each with its mask: white from the left over (n % 8 + 1) / 9 of the frame for frame n, black after. Removed in
        // Camera full screen, the camera shows up to there and the background after it: where tells the mask's frame.
        let (project, analysis, _) = try await maskedProject(
            in: dir, seconds: 2.5, segments: [(0, 1), (1.3, 1.2)],
            value: { n, x, _ in x * 9 < mask.width * (n % 8 + 1) ? 255 : 0 })
        let removed = pictureDocument(project.take) { document in
            document.camera.layout = CameraLayout(kind: .cameraFull)
            document.camera.background = .removed
        }
        let renderer = try FrameRenderer(project: project, document: removed, outputSize: pictureSize, analysis: analysis)
        // Forward, into the gap between the segments (the first one's last frame held), on, and back.
        let times = [0.517, 0.95, 1.15, 1.817, 0.317, 2.317, 1.45, 0.05, 1.317]
        var seen: [Int] = []
        for t in times {
            let frame = renderer.scene.frame(at: t)
            let layer = try #require(frame.camera, "\(t) s")
            #expect(layer.background?.mode == .removed, "\(t) s")
            let bytes = try await offThePool { try renderer.renderBytes(at: t) }
            let row = 200
            let shown = SampleFactory.frameIndex(nearestTo: pixel(bytes, width: pictureSize.x, x: 20, y: row))
            let source = layer.sourceTime.seconds(since: base)
            let expected = source < 1 ? Int(source * 30) : source < 1.3 ? 29 : 30 + Int((source - 1.3) * 30)
            #expect(shown == expected % 64, "\(t) s: camera frame \(shown), not \(expected)")
            let edge = try #require((0..<pictureSize.x).first { isBackdrop(pixel(bytes, width: pictureSize.x, x: $0, y: row)) }, "\(t) s")
            let maskFrame = Int((Double(edge) * 9 / Double(pictureSize.x)).rounded()) - 1
            #expect(maskFrame == shown % 8, "\(t) s: the mask of frame \(maskFrame) (mod 8), over camera frame \(shown)")
            seen.append(shown % 8)
        }
        // The times show several frames of the mask, not one held.
        #expect(Set(seen).count >= 5, "\(seen)")
        #expect(renderer.missingVideo.isEmpty)
    }
}

@Test(.enabled(if: isMetal), .timeLimit(.minutes(5)))
func withoutTheMaskTheCameraIsOriginal() async throws {
    try await withTemporaryDirectory { dir in
        let (project, analysis, masks) = try await maskedProject(in: dir, paint: paintingThePerson, value: personMaskValue)
        let blurred = pictureDocument(project.take) { document in
            document.camera.initial[takeID] = CameraStyle(shape: .circle, size: 0.5, anchor: .bottom)
            document.camera.background = .blurred
        }
        var original = blurred
        original.camera.background = .original
        let renderer = try FrameRenderer(project: project, document: blurred, outputSize: pictureSize, analysis: analysis)
        let plain = try FrameRenderer(project: project, document: original, outputSize: pictureSize)
        let first = try await offThePool { (try renderer.renderBytes(at: 0.5), try plain.renderBytes(at: 0.5)) }
        #expect(first.0 != first.1, "the mask is drawn while it is there")
        let exportedFirst = try await exported(renderer, at: gridTime(20))
        #expect(exportedFirst != (try await offThePool { try plain.renderBytes(at: gridTime(20)) }))

        // macOS empties the caches: from the next frame on, the camera as it is, through both ways to draw.
        try FileManager.default.removeItem(at: masks[0])
        for t in [1.0, 0.2, 2.5] {
            let (drawn, expected) = try await offThePool { (try renderer.renderBytes(at: t), try plain.renderBytes(at: t)) }
            #expect(drawn == expected, "\(t) s")
        }
        for n in [21, 22, 40] {
            let drawn = try await exported(renderer, at: gridTime(n))
            #expect(drawn == (try await offThePool { try plain.renderBytes(at: gridTime(n)) }), "frame \(n)")
        }
        // What is there instead of the file is no mask either: a folder, a link to one.
        try FileManager.default.createDirectory(at: masks[0], withIntermediateDirectories: false)
        #expect(try await offThePool { try renderer.renderBytes(at: 1.2) } == (try await offThePool { try plain.renderBytes(at: 1.2) }))
        // A mask is never a missing video.
        #expect(renderer.missingVideo.isEmpty)

        // A renderer whose mask was never there draws the original from its first frame.
        let never = try FrameRenderer(project: project, document: blurred, outputSize: pictureSize, analysis: analysis)
        #expect(try await offThePool { try never.renderBytes(at: 0.7) } == (try await offThePool { try plain.renderBytes(at: 0.7) }))
        #expect(try await exported(never, at: gridTime(5)) == (try await offThePool { try plain.renderBytes(at: gridTime(5)) }))
        #expect(never.missingVideo.isEmpty)
    }
}

@Test(.enabled(if: isMetal), .timeLimit(.minutes(5)))
func maskIsDecodedAhead() async throws {
    try await withTemporaryDirectory { dir in
        let (project, analysis, _) = try await maskedProject(in: dir, paint: paintingThePerson, value: personMaskValue)
        let blurred = pictureDocument(project.take) { $0.camera.background = .blurred }
        let renderer = try FrameRenderer(
            project: project, document: blurred, outputSize: pictureSize, frameRate: 30, analysis: analysis)
        let frame = renderer.scene.frame(at: 0)
        let keys = renderer.videos(of: frame)
        let maskKey = try #require(keys.last)
        #expect(keys.count == 3 && maskKey.trackID.hasPrefix("personMask:"), "\(keys)")
        #expect(maskKey.time == frame.camera?.sourceTime)
        let reader = try #require(renderer.reader(for: maskKey.trackID))
        reader.recordsAsks = true
        let sync = try FrameRenderer(project: project, document: blurred, outputSize: pictureSize, frameRate: 30, analysis: analysis)
        // The export's way: each frame queued, its camera and its mask decoded ahead by their prefetchers.
        let drawn = try await exported(renderer, at: gridTime(0))
        #expect(drawn == (try await offThePool { try sync.renderBytes(at: gridTime(0)) }))
        let ahead = base.adding(seconds: 5.0 / 30)
        #expect(await eventually(timeout: .seconds(10)) { reader.askedTimes.contains { $0 >= ahead } }, "\(reader.askedTimes)")
        for n in 1..<12 {
            let drawn = try await exported(renderer, at: gridTime(n))
            #expect(drawn == (try await offThePool { try sync.renderBytes(at: gridTime(n)) }), "frame \(n)")
        }
        // Asked in order, as drawing frame by frame asks.
        let asked = reader.askedTimes
        #expect(asked == asked.sorted(), "\(asked)")
        #expect(renderer.missingVideo.isEmpty)
    }
}

@Test(.enabled(if: isMetal), .timeLimit(.minutes(5)))
func previewEqualsExportWithMaskAndLook() async throws {
    try await withTemporaryDirectory { dir in
        var (project, analysis, _) = try await maskedProject(in: dir, paint: paintingThePerson, value: personMaskValue)
        // A face that moves from the left to the right over the segment's 3 s.
        let samples = (0..<30).map { i in
            CameraFaceSample(
                t: base.adding(seconds: Double(i) / 10),
                face: NormalizedRect(x: 0.2 + 0.4 * Double(i) / 30, y: 0.2, width: 0.2, height: 0.35))
        }
        analysis.faceTracks[pictureSegment] = CameraFaceTrack(algorithm: CameraFaceTrack.id, frameSize: [640, 360], samples: samples)
        let document = pictureDocument(project.take) { document in
            document.camera.initial[takeID] = CameraStyle(shape: .circle, size: 0.5, anchor: .bottomTrailing)
            document.camera.background = .blurred
            document.camera.look = CameraColor(preset: .warm, lut: nil, intensity: 0.8)
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: CameraFraming.faceZoom)
            document.camera.mirror = true
        }
        let export = try FrameRenderer(project: project, document: document, outputSize: pictureSize, frameRate: 30, analysis: analysis)
        let shown = try FrameRenderer(project: project, document: document, outputSize: pictureSize, frameRate: 30, analysis: analysis)
        let preview = PreviewRenderer(renderer: shown)
        var previous: [UInt8]?
        for n in 30..<38 {
            let t = gridTime(n)
            let layer = try #require(export.scene.frame(at: t).camera)
            #expect(layer.look?.lut == .preset(.warm) && layer.look?.framing != nil && layer.background?.mode == .blurred)
            let exportBytes = try await exported(export, at: t)
            let (bytes, snapshot) = try await offThePool { (try shown.renderBytes(at: t), try preview.snapshot(at: t)) }
            #expect(exportBytes == bytes && exportBytes == snapshot, "frame \(n)")
            #expect(exportBytes != previous, "frame \(n) is another frame")
            previous = exportBytes
        }
        #expect(export.missingVideo.isEmpty)
    }
}

// MARK: - Cost

@Test(.enabled(if: isMetal && ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func cameraPictureCostAt1080p() async throws {
    let drawer = try CameraPictureDrawer()
    // A camera of 1080p and a mask of 512 × 288 (Vision's balanced size, rounded to evens), into a 4K output and a 1080p
    // one: Camera full screen (the camera over every pixel) and a Bubble, Original against Blurred with Warm (the mask, the
    // LUT and the blur's mipmaps, all of it).
    let textures = try personTextures(drawer.device, camera: (1920, 1080), mask: (512, 288))
    var rows: [String] = []
    for size in [SIMD2(3840, 2160), SIMD2(1920, 1080)] {
        for (name, layout) in [("Camera full screen", CameraLayout(kind: .cameraFull)), ("Bubble", CameraLayout.bubble)] {
            let original = pictureFrame(pictureDocument { $0.camera.layout = layout }, size: size)
            let looked = pictureFrame(
                pictureDocument { document in
                    document.camera.layout = layout
                    document.camera.background = .blurred
                    document.camera.look = CameraColor(preset: .warm, lut: nil, intensity: 1)
                }, size: size, analysis: pictureMasks())
            @Sendable func p95(_ frame: RenderFrame, look: Bool) throws -> Double {
                var times: [Double] = []
                for i in 0..<130 {
                    let drawn = try drawer.draw(frame, camera: textures.camera, mask: look ? textures.mask : nil, look: look, bytes: false)
                    if i >= 10 { times.append(drawn.gpuSeconds) }
                }
                times.sort()
                return times[Int(Double(times.count) * 0.95)] * 1000
            }
            let (before, after) = try await offThePool { (try p95(original, look: false), try p95(looked, look: true)) }
            rows.append(String(format: "%d × %d, %@: %.2f ms → %.2f ms", size.x, size.y, name, before, after))
        }
    }
    print("cameraPictureCostAt1080p (p95 of GPU time, 120 frames): " + rows.joined(separator: "; "))
}

// MARK: - Pictures to look at

/// Where `cameraPictureShots` writes its PNGs: `TOMA_CAMERA_SHOTS`, a folder. Only on demand.
private let shotsFolder = ProcessInfo.processInfo.environment["TOMA_CAMERA_SHOTS"]

/// Writes BGRA `bytes` of `size` (or its part `crop`) as a PNG at `url`.
private func writePNG(_ bytes: [UInt8], size: SIMD2<Int>, crop: CGRect? = nil, to url: URL) throws {
    let data = try #require(CFDataCreate(nil, bytes, bytes.count))
    let provider = try #require(CGDataProvider(data: data))
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    var image = try #require(CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent))
    if let crop { image = try #require(image.cropping(to: crop.integral)) }
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test(.enabled(if: isMetal && shotsFolder != nil))
func cameraPictureShots() async throws {
    let folder = URL(fileURLWithPath: try #require(shotsFolder), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let drawer = try CameraPictureDrawer()
    let textures = try personTextures(drawer.device, camera: (1920, 1080), mask: (512, 288))
    let size = SIMD2(3840, 2160)
    let layouts: [(String, CameraLayout)] = [
        ("bubble", .bubble), ("split", CameraLayout(kind: .split, split: SplitLayout())), ("cameraFull", CameraLayout(kind: .cameraFull)),
    ]
    for (layoutName, layout) in layouts {
        for background in CameraBackground.allCases {
            let document = pictureDocument { document in
                document.style.background = .gradient(start: RGBA(0.35, 0.2, 0.6, 1), end: RGBA(0.1, 0.5, 0.7, 1), angle: 135)
                document.camera.layout = layout
                document.camera.initial[takeID] = CameraStyle(shape: .circle, size: 0.45, anchor: .bottomTrailing)
                document.camera.border = CameraBorder(width: 0.3, color: RGBA(1, 1, 1, 1))
                document.camera.shadow = 0.5
                document.camera.background = background
                document.camera.look = CameraColor(preset: .warm, lut: nil, intensity: 1)
            }
            let frame = pictureFrame(document, size: size, analysis: pictureMasks())
            let layer = try #require(frame.camera)
            let drawn = try await offThePool { try drawer.draw(frame, camera: textures.camera, mask: textures.mask) }
            let name = "\(layoutName)-\(background.rawValue)"
            try writePNG(drawn.bytes, size: size, to: folder.appendingPathComponent("\(name).png"))
            // 1:1 around the left edge of the head, where the mask cuts most.
            let fill = drawer.compositor.cameraFill(layer, texture: textures.camera.texture)
            let aspect = 16.0 / 9
            let head = SIMD2((aspect / 2 - 0.17) / aspect, 0.37)
            let x = layer.rect.x + (head.x - Double(fill.origin.x)) / Double(fill.size.x) * layer.rect.width
            let y = layer.rect.y + (head.y - Double(fill.origin.y)) / Double(fill.size.y) * layer.rect.height
            try writePNG(
                drawn.bytes, size: size, crop: CGRect(x: x - 200, y: y - 200, width: 400, height: 400),
                to: folder.appendingPathComponent("\(name)-edge.png"))
        }
    }
}
