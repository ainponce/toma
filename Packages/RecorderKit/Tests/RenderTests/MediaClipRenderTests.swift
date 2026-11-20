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
// @testable for the clip's scene and drawing, `FrameRenderer`'s readers, frames and drawing by frame, and the preview
// engine's hooks.
@testable import Render
import Synchronization
import SyntheticCapture
import Testing

/// An imported clip in the sequence (phase 3 design §5.4 and §12, step 2; plan 3a, Task A9 and decision 12): drawn where
/// the screens are, fitted into the room inside the margin with the style's corners and shadow, its file's frame at
/// `start + round(offset × v)` held to `[start, end − 1]`, read by its own reader (`AssetFrameReader`, `asset:<path>`)
/// through the renderer's readers and prefetchers, upright as a player shows it; a file that is gone or is a link leaves
/// the background alone, and the preview draws what the export draws.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
/// The clip's pattern: its frame `i` is `SampleFactory`'s frame `41 + i`, so its frame 15 (0.5 s) is teal (0, 224, 200),
/// far from the background's colours.
private let clipPattern = 41

/// The output second of frame `n` of the grid of `rate`.
private func seconds(_ n: Int, rate: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9 }

/// A take of one display, 640 × 360 at 30 fps for 4 s from `base` with the cursor moving over it, and a clip of the user's
/// own (`MediaFixtures.clip`: 2 s of `clipSize` at 30 fps, pattern `clipPattern`, turned by `transform`) imported into its
/// package as the editor imports one; the path the document names the clip by.
private func mediaProject(
    in dir: URL, clipSize: SIMD2<Int> = [640, 360], transform: CGAffineTransform = .identity
) async throws -> (project: LoadedProject, asset: String) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 4)])
    try builder.addEvents(cursorEvents(from: base, seconds: 4, across: screenFrame))
    let project = try builder.write()
    let clip = try await offThePool {
        try MediaFixtures.clip(in: dir, seconds: 2, size: clipSize, pattern: clipPattern, transform: transform)
    }
    return (project, try await MediaFixtures.imported(clip, into: project, as: .video))
}

/// The legacy document of `project` (a clip of its 4 s) with `media` in the sequence at 2 s of the take, `[take 0–2 s]
/// [media] [take 2–4 s]` (more of them, each at its second of the take, with `more`), a margin of 0.1, corners of 0.03 and
/// a shadow of 0.5.
private func mediaDocument(_ project: LoadedProject, _ media: MediaClip, more: [(at: Double, MediaClip)] = []) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    let take = document.sequence[0]
    let points = ([(at: 2.0, media)] + more).sorted { $0.at < $1.at }
    var sequence: [Clip] = []
    var from = take.start
    for (k, (at, clip)) in points.enumerated() {
        let point = take.start.adding(seconds: at)
        var piece = take
        (piece.id, piece.start, piece.end) = ("c-" + String(format: "%08x", 2 * k + 1), from, point)
        sequence.append(piece)
        sequence.append(Clip(
            id: "c-" + String(format: "%08x", 2 * k + 2), take: take.take, start: point, end: point, speed: 1,
            content: .media(clip)))
        from = point
    }
    var last = take
    (last.id, last.start) = ("c-" + String(format: "%08x", 2 * points.count + 1), from)
    sequence.append(last)
    document.sequence = sequence
    document.style.padding = 0.1
    document.style.cornerRadius = 0.03
    document.style.shadow = 0.5
    return document
}

/// The bytes of `frame` (one of `renderer`'s scene) drawn without its imported clip: the background alone.
private func backgroundBytes(of frame: RenderFrame, _ renderer: FrameRenderer) async throws -> [UInt8] {
    var plain = frame
    plain.media = nil
    let alone = plain
    return try await offThePool {
        try renderer.renderOffscreen(size: alone.outputSize) { target, commandBuffer in
            try renderer.encode(alone, into: target, commandBuffer: commandBuffer) { _, _ in nil }
        }
    }
}

/// Draws frames `frames` of `renderer`'s scene along the grid of `rate`, in order, as the export does
/// (`render(at:into:completion:)`, each decoded ahead through the prefetchers), waiting for each; the bytes of the last.
private func exportBytes(_ renderer: FrameRenderer, frames: ClosedRange<Int>, rate: Int) async throws -> [UInt8] {
    try await exportFrames(renderer, frames: frames, keeping: [frames.upperBound], rate: rate)[frames.upperBound] ?? []
}

/// `exportBytes`, with the bytes of each frame of `keeping`.
private func exportFrames(
    _ renderer: FrameRenderer, frames: ClosedRange<Int>, keeping: Set<Int>, rate: Int
) async throws -> [Int: [UInt8]] {
    let target = MediaPixelBuffer(try pixelBuffer(of: renderer.outputSize))
    var kept: [Int: [UInt8]] = [:]
    for n in frames {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            renderer.render(at: seconds(n, rate: rate), into: target.pixelBuffer) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
        if keeping.contains(n) { kept[n] = packedBytes(of: target.pixelBuffer) }
    }
    return kept
}

/// A BGRA pixel buffer of `size`, IOSurface-backed, as the export draws into.
private func pixelBuffer(of size: SIMD2<Int>) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    return try #require(created)
}

/// A take of 4 s as `mediaProject` makes it, with `count` clips of the user's own imported into it, each `seconds` long
/// at 320 × 180 with a pattern of its own (`5 × i`); the paths, in order.
private func manyClipsProject(in dir: URL, count: Int, seconds: Double) async throws -> (project: LoadedProject, assets: [String]) {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 4)])
    let project = try builder.write()
    var assets: [String] = []
    for i in 0..<count {
        let clip = try await offThePool { try MediaFixtures.clip(in: dir, seconds: seconds, size: [320, 180], pattern: 5 * i) }
        assets.append(try await MediaFixtures.imported(clip, into: project, as: .video))
    }
    return (project, assets)
}

/// The legacy document of `project` with `assets`' clips one after the other at 1 s of the take, each the first
/// `seconds` of its file: `[take 0–1 s] [clip 0] … [clip n − 1] [take 1–4 s]`.
private func manyClipsDocument(_ project: LoadedProject, _ assets: [String], seconds: Double) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    let take = document.sequence[0], point = take.start.adding(seconds: 1)
    var before = take, after = take
    (before.id, before.end) = ("c-00000001", point)
    (after.id, after.start) = ("c-" + String(format: "%08x", assets.count + 2), point)
    let clips = assets.enumerated().map { i, asset in
        Clip(
            id: "c-" + String(format: "%08x", i + 2), take: take.take, start: point, end: point, speed: 1,
            content: .media(MediaClip(asset: asset, start: 0, end: Int64((seconds * 1e9).rounded()))))
    }
    document.sequence = [before] + clips + [after]
    return document
}

private final class MediaPixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// The frames a preview engine drew, from its hook.
private final class EngineFrames: Sendable {
    private let frames = Mutex<[PreviewEngine.DrawnFrame]>([])

    func append(_ frame: PreviewEngine.DrawnFrame) { frames.withLock { $0.append(frame) } }
    var all: [PreviewEngine.DrawnFrame] { frames.withLock { $0 } }
    var count: Int { frames.withLock { $0.count } }
}

/// A preview engine of `renderer` drawing into a layer of its own, and what it drew.
private func engine(_ renderer: FrameRenderer) -> (PreviewEngine, EngineFrames) {
    let layer = CAMetalLayer()
    CATransaction.begin()
    layer.drawableSize = CGSize(width: renderer.outputSize.x, height: renderer.outputSize.y)
    CATransaction.commit()
    let engine = PreviewEngine(renderer: renderer, layer: layer)
    let drawn = EngineFrames()
    engine.hooks.onDrawn = { drawn.append($0) }
    engine.hooks.playbackSize = renderer.outputSize
    return (engine, drawn)
}

/// Whether `pixel` (BGRA) is within `tolerance` of the palette colour of `SampleFactory`'s frame `index` in every channel.
private func isFrame(_ pixel: SIMD4<UInt8>, _ index: Int, tolerance: Int = 24) -> Bool {
    let color = SampleFactory.color(forFrame: index)
    let bgr = SIMD3(Int(pixel.x), Int(pixel.y), Int(pixel.z)), expected = SIMD3(Int(color.z), Int(color.y), Int(color.x))
    let difference = bgr &- expected
    return max(abs(difference.x), abs(difference.y), abs(difference.z)) <= tolerance
}

/// Whether `a` and `b` are the same rect but for the rounding of the last bits.
private func isNear(_ a: Rect?, _ b: Rect) -> Bool {
    guard let a else { return false }
    return [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1e-9 }
}

extension Rect {
    fileprivate var midX: Double { x + width / 2 }
    fileprivate var midY: Double { y + height / 2 }
    fileprivate var maxX: Double { x + width }
    fileprivate var maxY: Double { y + height }
}

/// The sum of a BGRA pixel's colour channels.
private func brightness(_ pixel: SIMD4<UInt8>) -> Int { Int(pixel.x) + Int(pixel.y) + Int(pixel.z) }

@Suite struct MediaClipRenderTests {
    /// The clip of 640 × 360 at 2.5 s of a 1080p output with a margin of 0.1 (its 0.5 s): fitted whole into the room inside
    /// the margin (192, 192, 1536 × 696), 1237.3 × 696 and centred; its file's frame 15 fills it, nothing of it outside,
    /// the background as without it beyond the shadow's reach and darker just under it, its corners rounded by 0.03 × W.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func mediaClipDrawsItsFileFrameInTheRoom() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let size = SIMD2(1920, 1080)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let frame = try renderer.frame(of: renderer.scene, at: 2.5)
            let layer = try #require(frame.media)
            #expect(layer == MediaClipLayer(
                asset: asset, fileTime: 500_000_000, room: Rect(x: 192, y: 192, width: 1536, height: 696), cornerRadius: 0.03 * 1920,
                shadow: 0.5))
            // Where the screens are, without them, nor the cursor, the camera, a zoom or a window frame.
            #expect(frame.screen == nil && frame.cursor == nil && frame.camera == nil && frame.stage == nil)
            #expect(frame.windowFrame == nil && frame.shadow == nil && frame.subframes.isEmpty && frame.clickEffects.isEmpty)
            #expect(renderer.videos(of: frame) == [DecodedKey(trackID: "asset:" + asset, time: HostTime(nanoseconds: 500_000_000))])

            let drawn = try await offThePool { try renderer.renderBytes(at: 2.5) }
            let background = try await backgroundBytes(of: frame, renderer)
            let width = 696.0 * 16 / 9
            let rect = Rect(x: 192 + (1536 - width) / 2, y: 192, width: width, height: 696)
            #expect(isNear(layer.rect(fitting: [640, 360]), rect))
            func at(_ x: Double, _ y: Double, in bytes: [UInt8]? = nil) -> SIMD4<UInt8> {
                pixel(bytes ?? drawn, width: size.x, x: Int(x.rounded(.down)), y: Int(y.rounded(.down)))
            }
            let shown = (clipPattern + 15) % 64
            // The file's frame at 0.5 s fills the rect, to 4 px of its edges (away from its square, along its top).
            for (x, y) in [
                (rect.midX, rect.midY), (rect.x + 4, rect.midY), (rect.maxX - 5, rect.midY), (rect.midX, rect.maxY - 5),
                (rect.x + 30, rect.y + 40),
            ] {
                #expect(isFrame(at(x, y), shown), "at (\(x), \(y)): \(at(x, y))")
            }
            // Nothing of it outside: 4 px beyond its sides, the background darkened by the shadow at most.
            for (x, y) in [(rect.x - 4, rect.midY), (rect.maxX + 4, rect.midY), (rect.midX, rect.y - 4), (rect.x + 2, rect.y + 2)] {
                #expect(!isFrame(at(x, y), shown, tolerance: 60), "at (\(x), \(y)): \(at(x, y))")
                #expect(brightness(at(x, y)) <= brightness(at(x, y, in: background)) + 3, "at (\(x), \(y))")
            }
            // Beyond the shadow's reach (3σ = 69 px and a pixel), the background exactly; just under it, darker.
            for (x, y) in [(rect.x - 80, rect.midY), (rect.maxX + 80, rect.midY), (100.0, 100.0), (1800.0, 1000.0)] {
                #expect(at(x, y) == at(x, y, in: background), "at (\(x), \(y))")
            }
            #expect(brightness(at(rect.midX, rect.maxY + 8)) < brightness(at(rect.midX, rect.maxY + 8, in: background)) - 15)
            #expect(drawn != background)
        }
    }

    /// A clip of the file from 0.5 s to 3.5 s at 1.5× lasts 2 s; at 1 s into it the file's 2 s shows, and its last instant
    /// is held at the clip's `end − 1`; a speed out of its range is clamped as a clip's. The take's frames show none.
    @Test func fileTimeFollowsSpeedAndTrim() {
        let take = StageDrawing.bareTake(seconds: 4)
        var document = EditDocument.legacy(take: take, events: [])
        let asset = "assets/0123456789abcdef0123456789abcdef.mov"
        let point = base.adding(seconds: 2)
        func sequence(_ media: MediaClip) -> [Clip] {
            [
                Clip(id: "c-00000001", take: takeID, start: base, end: point, speed: 1),
                Clip(id: "c-00000002", take: takeID, start: point, end: point, speed: 1, content: .media(media)),
                Clip(id: "c-00000003", take: takeID, start: point, end: base.adding(seconds: 4), speed: 1),
            ]
        }
        document.sequence = sequence(MediaClip(asset: asset, start: 500_000_000, end: 3_500_000_000, speed: 1.5))
        document.style.padding = 0.1
        let scene = FrameEvaluator(take: take, events: [], document: document, outputSize: [640, 360])
        #expect(scene.timeMap.clipOutputStarts == [0, 2_000_000_000, 4_000_000_000] && scene.timeMap.duration == 6_000_000_000)
        #expect(scene.frame(at: 2).media?.fileTime == 500_000_000)
        #expect(scene.frame(at: 3).media?.fileTime == 2_000_000_000)
        let last = scene.clipFrame(atOutput: 4_000_000_000 - 1) { _, _ in true }
        #expect(last.media?.fileTime == Int64(3_499_999_999))
        #expect(scene.frame(at: 3).media?.room == Rect(x: 64, y: 64, width: 512, height: 232))
        #expect(scene.resized(to: [1280, 720]).frame(at: 3).media?.room == Rect(x: 128, y: 128, width: 1024, height: 464))
        for t in [0.0, 1.0, 1.999, 4.0, 5.5] {
            #expect(scene.frame(at: t).media == nil, "\(t) s")
        }
        // Held to `[start, end − 1]` whatever the rounding: 10 ns at 0.3× last 33 ns, and 32 × 0.3 rounds to 10.
        let short = MediaClip(asset: asset, start: 0, end: 10, speed: 0.3)
        #expect(MediaClipScene.fileTime(of: short, atOffset: 0) == 0)
        #expect(MediaClipScene.fileTime(of: short, atOffset: 31) == 9 && MediaClipScene.fileTime(of: short, atOffset: 32) == 9)
        // 40× is read as 16×, as a clip's speed.
        document.sequence = sequence(MediaClip(asset: asset, start: 0, end: 32_000_000_000, speed: 40))
        let fast = FrameEvaluator(take: take, events: [], document: document, outputSize: [640, 360])
        #expect(fast.timeMap.clipOutputStarts[2] == 4_000_000_000)
        #expect(fast.frame(at: 2.5).media?.fileTime == 8_000_000_000)
        // A clip that lasts nothing is never shown.
        document.sequence = sequence(MediaClip(asset: asset, start: 5, end: 5))
        let empty = FrameEvaluator(take: take, events: [], document: document, outputSize: [640, 360])
        #expect((0..<40).allSatisfy { empty.frame(at: Double($0) / 10).media == nil })
    }

    /// The clip's file deleted, or a link to a copy of it outside the package in its place: the frame of the clip is the
    /// background alone, frame by frame and as the export draws it, without an error, and no reader is made for it.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aMissingOrLinkedClipDrawsTheBackground() async throws {
        for linked in [false, true] {
            try await withTemporaryDirectory { dir in
                let (project, asset) = try await mediaProject(in: dir)
                let file = project.package.fileURL(asset)
                if linked {
                    let outside = dir.appending(path: "outside.mov")
                    try FileManager.default.moveItem(at: file, to: outside)
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
                } else {
                    try FileManager.default.removeItem(at: file)
                }
                let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
                let size = SIMD2(640, 360)
                let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 30)
                let frame = try renderer.frame(of: renderer.scene, at: 2.5)
                #expect(frame.media != nil)
                let background = try await backgroundBytes(of: frame, renderer)
                let drawn = try await offThePool { try renderer.renderBytes(at: 2.5) }
                #expect(drawn == background, "linked: \(linked)")
                let exported = try await exportBytes(renderer, frames: 70...75, rate: 30)
                #expect(exported == background, "linked: \(linked)")
                #expect(renderer.mediaReader(for: AssetFrameReader.readerID(of: asset)) == nil)
                #expect(renderer.mediaResources.readerCount == 0)
                // The take's frames are drawn as ever.
                #expect(try await offThePool { try renderer.renderBytes(at: 1) } != background)
            }
        }
    }

    /// A clip's reader id is `asset:` and its path, which no track of a take can have (its ids are letters, digits and
    /// `-`), and gives its path back; any other id, a track's or a person's mask's, gives none.
    @Test func readerIDIsNoTrackID() {
        let asset = "assets/0123456789abcdef0123456789abcdef.mov"
        let id = AssetFrameReader.readerID(of: asset)
        #expect(id == "asset:" + asset)
        #expect(!ProjectPackage.isValidTrackID(id))
        #expect(AssetFrameReader.asset(ofReaderID: id) == asset)
        for other in ["display-1", "camera", "asset", "asset-1", "asset-assets", "personMask:0-personMask-1.mov", "asset:", ""] {
            #expect(AssetFrameReader.asset(ofReaderID: other) == nil, "\(other)")
        }
        for track in ["display-1", "camera-1", "window-3", "asset", "a"] where ProjectPackage.isValidTrackID(track) {
            #expect(!track.hasPrefix("asset:"))
        }
    }

    /// Two clips of one file (its 0–1 s at 2 s of the take, its 1–2 s at 3 s): one reader for both, made the first time and
    /// kept, which shows each its own frames, frame by frame and as the export draws them.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func oneReaderAcrossClipsOfOneAsset() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let document = mediaDocument(
                project, MediaClip(asset: asset, start: 0, end: 1_000_000_000),
                more: [(3, MediaClip(asset: asset, start: 1_000_000_000, end: 2_000_000_000))])
            #expect(TimeMap(sequence: document.sequence).duration == 6_000_000_000)
            let size = SIMD2(640, 360)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 30)
            let id = AssetFrameReader.readerID(of: asset)
            #expect(renderer.mediaResources.readerCount == 0)
            let reader = try #require(renderer.reader(for: id))
            #expect(renderer.reader(for: id) === reader && renderer.mediaReader(for: id) === reader)
            // Clip 1 at 2.5 s shows the file's 0.5 s; clip 2 at 4.5 s (3 s of the take, after 1 s of it), the file's 1.5 s.
            let (first, second) = try await offThePool { (try renderer.renderBytes(at: 2.5), try renderer.renderBytes(at: 4.5)) }
            let center = (size.x / 2, size.y / 2)
            #expect(isFrame(pixel(first, width: size.x, x: center.0, y: center.1), (clipPattern + 15) % 64))
            #expect(isFrame(pixel(second, width: size.x, x: center.0, y: center.1), (clipPattern + 45) % 64))
            let exported = try await exportBytes(renderer, frames: 60...135, rate: 30)
            #expect(exported == second)
            #expect(renderer.mediaResources.readerCount == 1 && renderer.reader(for: id) === reader)
        }
    }

    /// A clip at 1.5× (its file's 0.75 s at 2.5 s): the preview paused on it and playing up to it (an engine of its own),
    /// the export along the grid over the border into it, and the frame drawn alone, all the same bytes.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func previewEqualsExportWithAMediaClip() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000, speed: 1.5))
            let size = SIMD2(640, 360), rate = 30, n = 75
            #expect(seconds(n, rate: rate) == 2.5)
            func renderer() throws -> FrameRenderer {
                try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            }
            let export = try renderer()
            #expect(try export.frame(of: export.scene, at: 2.5).media?.fileTime == 750_000_000)
            let exported = try await exportBytes(export, frames: 54...n, rate: rate)
            let alone = try await offThePool { try export.renderBytes(at: 2.5) }
            #expect(exported == alone)
            #expect(isFrame(pixel(alone, width: size.x, x: size.x / 2, y: size.y / 2), (clipPattern + 22) % 64))

            // Paused.
            let (paused, pausedFrames) = engine(try renderer())
            paused.request(.paused(frame: n))
            #expect(await eventually(timeout: .seconds(30)) { pausedFrames.count >= 1 })
            #expect(try await paused.drawnBytes() == exported)

            // Playing from 2 s, one frame after the other as a display link asks for them.
            let (playing, played) = engine(try renderer())
            for k in 60...n {
                let before = played.count
                playing.request(.playing(seconds: seconds(k, rate: rate)))
                #expect(await eventually(timeout: .seconds(30)) { played.count > before }, "frame \(k) drawn")
                try await Task.sleep(for: .milliseconds(40))
            }
            let last = try #require(played.all.last)
            #expect(last.request == .playing(seconds: 2.5) && !last.late && last.frame.outputSize == size)
            #expect(try await playing.drawnBytes() == exported)
        }
    }

    /// Without clips in the sequence (the legacy document): no frame names a clip's video, no reader is made for one,
    /// and the compositor draws none; no id of a track or of a mask reaches the clips' readers. With one but without its
    /// frame, the compositor draws nothing of it either.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func legacyOpensNoMediaReader() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let size = SIMD2(640, 360)
            let renderer = try FrameRenderer(project: project, document: .legacy(for: project), outputSize: size, frameRate: 30)
            _ = try await exportBytes(renderer, frames: 0...40, rate: 30)
            _ = try await offThePool { try [0.5, 2.5, 3.9].map { try renderer.renderBytes(at: $0) } }
            let drawer = try MediaDrawer()
            for n in stride(from: 0, to: 120, by: 7) {
                let frame = try renderer.frame(of: renderer.scene, at: seconds(n, rate: 30))
                #expect(frame.media == nil && renderer.mediaVideos(of: frame).isEmpty, "frame \(n)")
                #expect(!renderer.videos(of: frame).contains { $0.trackID.hasPrefix("asset:") }, "frame \(n)")
                #expect(try drawer.counts(of: frame, texture: drawer.clip).mediaClips == 0, "frame \(n)")
            }
            #expect(renderer.mediaResources.readerCount == 0)
            let absent = "asset:assets/0123456789abcdef0123456789abcdef.mov"
            for id in [trackID, "camera", "personMask:0-personMask-1.mov", asset, "asset:", absent] {
                #expect(renderer.mediaReader(for: id) == nil, "\(id)")
            }
            #expect(renderer.mediaResources.readerCount == 0)
            // A clip's frame without its file's frame: nothing of it.
            var frame = RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
            frame.media = MediaClipLayer(
                asset: asset, fileTime: 0, room: Rect(x: 64, y: 64, width: 512, height: 232), cornerRadius: 19.2, shadow: 0.5)
            #expect(try drawer.counts(of: frame, texture: nil).mediaClips == 0)
            #expect(try drawer.counts(of: frame, texture: drawer.clip).mediaClips == 1)
        }
    }

    /// A title card right after a clip (`[take 0–2 s] [the file's 0–1 s] [a card of 1 s] [take 2–4 s]`), with each of its
    /// backgrounds: over its first 0.3 s it fades against the clip's last instant held (the file's `end − 1`), the clip
    /// faded to `1 − p` with its shadow (at 0.15 s, half: `TitleCardScene.faded`), and then over the background alone; a
    /// blurred frame, without a screen in that frame, is the same as the project's background. Nothing of the clip's under
    /// the card once it is in, and none over the card's own clip.
    @Test func cardFadesAgainstAMediaClip() {
        let take = StageDrawing.bareTake(seconds: 4)
        let asset = "assets/0123456789abcdef0123456789abcdef.mov"
        let point = base.adding(seconds: 2)
        for background in [TitleCardBackground.stage, .color(RGBA(0, 0, 0, 0.5)), .blurredFrame] {
            var document = EditDocument.legacy(take: take, events: [])
            document.sequence = [
                Clip(id: "c-00000001", take: takeID, start: base, end: point, speed: 1),
                Clip(
                    id: "c-00000002", take: takeID, start: point, end: point, speed: 1,
                    content: .media(MediaClip(asset: asset, start: 0, end: 1_000_000_000))),
                Clip(
                    id: "c-00000003", take: takeID, start: point, end: point, speed: 1,
                    content: .card(TitleCard(title: "Toma", style: .centered, background: background), duration: 1_000_000_000)),
                Clip(id: "c-00000004", take: takeID, start: point, end: base.adding(seconds: 4), speed: 1),
            ]
            let scene = FrameEvaluator(take: take, events: [], document: document, outputSize: [640, 360])
            #expect(scene.timeMap.clipOutputStarts == [0, 2_000_000_000, 3_000_000_000, 4_000_000_000])
            let clip = scene.frame(at: 2.5).media
            #expect(clip?.opacity == 1)
            let half = scene.frame(at: 3.15)
            #expect(half.titleCard?.opacity == 0.5, "\(background)")
            #expect(half.media?.opacity == 0.5 && half.media?.fileTime == 999_999_999, "\(background)")
            #expect(half.media?.room == clip?.room && half.media?.asset == asset, "\(background)")
            #expect(scene.frame(at: 3.0).media?.opacity == 1, "\(background)")
            for t in [3.3, 3.5, 3.9] {
                #expect(scene.frame(at: t).media == nil && scene.frame(at: t).titleCard != nil, "\(background) at \(t) s")
            }
        }
        // `faded` alone: the clip at `f`, `blurred` never shows one.
        var frame = RenderFrame(outputSize: [640, 360], gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
        frame.media = MediaClipLayer(asset: asset, fileTime: 5, room: Rect(x: 64, y: 64, width: 512, height: 232), cornerRadius: 0, shadow: 0)
        #expect(TitleCardScene.faded(frame, keeping: 0.25).media?.opacity == 0.25)
        #expect(TitleCardScene.faded(frame, keeping: 1).media?.opacity == 1)
        frame.screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 0, y: 0, width: 640, height: 360), cornerRadius: 0)
        #expect(TitleCardScene.blurred(frame, 0.5)?.media == nil)
    }

    /// The clip at an opacity, its shadow with it (as under a card fading against it): in the clip, the clip at 1 and the
    /// background mixed half and half at 0.5; under its bottom edge, half the darkening of its shadow; at 0, nothing drawn.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func fadedClipIsDrawnAtItsOpacity() throws {
        let drawer = try MediaDrawer()
        let size = SIMD2(640, 360)
        var frame = RenderFrame(
            outputSize: size, gradientStart: SIMD4(0.2, 0.3, 0.8, 1), gradientEnd: SIMD4(0.9, 0.6, 0.2, 1), gradientAngleDegrees: 30)
        let room = Rect(x: 64, y: 64, width: 512, height: 232)
        frame.media = MediaClipLayer(asset: "assets/0123456789abcdef0123456789abcdef.mov", fileTime: 0, room: room, cornerRadius: 19.2, shadow: 1)
        func drawn(_ opacity: Double?) throws -> (counts: DrawCounts, bytes: [UInt8]) {
            var faded = frame
            if let opacity { faded.media?.opacity = opacity } else { faded.media = nil }
            return try drawer.draw(faded, texture: drawer.clip)
        }
        let (whole, half, none, plain) = (try drawn(1), try drawn(0.5), try drawn(0), try drawn(nil))
        #expect(whole.counts.mediaClips == 1 && half.counts.mediaClips == 1 && none.counts.mediaClips == 0)
        #expect(none.bytes == plain.bytes)
        // The 320 × 180 clip fills the room's height: 412.4 × 232, centred.
        let rect = try #require(frame.media?.rect(fitting: [320, 180]))
        func at(_ bytes: [UInt8], _ x: Double, _ y: Double) -> SIMD4<Float> {
            SIMD4<Float>(pixel(bytes, width: size.x, x: Int(x), y: Int(y)))
        }
        for (x, y) in [(rect.midX, rect.midY), (rect.x + 40, rect.y + 60), (rect.maxX - 40, rect.maxY - 60)] {
            let mixed = (at(whole.bytes, x, y) + at(plain.bytes, x, y)) / 2
            let difference = at(half.bytes, x, y) - mixed
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) <= 1.5, "at (\(x), \(y))")
        }
        // Under the bottom edge, the shadow alone: half as dark.
        let (x, y) = (rect.midX, rect.maxY + 6)
        let darkening = at(plain.bytes, x, y) - at(whole.bytes, x, y), halfDarkening = at(plain.bytes, x, y) - at(half.bytes, x, y)
        #expect(darkening.x + darkening.y + darkening.z > 30)
        #expect(abs((halfDarkening.x + halfDarkening.y + halfDarkening.z) * 2 - (darkening.x + darkening.y + darkening.z)) <= 6)
    }

    /// Eight files, 0.3 s of each one after the other from 1 s: as the export draws on, the readers of the clips that
    /// neither its frame nor the next second shows are let go (their `AVAssetReader`s closed), so at 2 s only those of
    /// clips 3 to 6 are kept and none past 3.4 s; each frame still shows its file's. The preview playing over them too.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func readersOutsideTheWindowAreLetGo() async throws {
        try await withTemporaryDirectory { dir in
            let (project, assets) = try await manyClipsProject(in: dir, count: 8, seconds: 0.3)
            let document = manyClipsDocument(project, assets, seconds: 0.3)
            let size = SIMD2(320, 180), rate = 30
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            let ids = assets.map(AssetFrameReader.readerID(of:))
            let first = try #require(renderer.reader(for: ids[0]))
            // At 2 s (frame 60), the next second shows clips 3 (1.9–2.2 s) to 6 (2.8–3.1 s).
            let frames = try await exportFrames(renderer, frames: 0...60, keeping: [42, 60], rate: rate)
            #expect(Set(ids.filter { renderer.mediaResources.existingReader(for: $0) != nil }) == Set(ids[3...6]))
            #expect(await eventually { !first.isOpen })
            // Clip 1 at 1.4 s (its 0.1 s, frame 3), clip 3 at 2 s (its 0.1 s, frame 3).
            let center = (size.x / 2, size.y / 2)
            #expect(isFrame(pixel(try #require(frames[42]), width: size.x, x: center.0, y: center.1), 5 * 1 + 3))
            #expect(isFrame(pixel(try #require(frames[60]), width: size.x, x: center.0, y: center.1), 5 * 3 + 3))
            // Past 3.4 s none is kept, and none open.
            let kept = ids.compactMap { renderer.mediaResources.existingReader(for: $0) }
            _ = try await exportFrames(renderer, frames: 61...105, keeping: [], rate: rate)
            #expect(renderer.mediaResources.readerCount == 0)
            #expect(await eventually { kept.allSatisfy { !$0.isOpen } })
            #expect(renderer.mediaResources.gate.mostAtOnce <= MediaClipResources.decodesAtOnce)

            // Frame by frame: the clips a frame does not show go.
            let alone = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            _ = try await offThePool { (try alone.renderBytes(at: 1.15), try alone.renderBytes(at: 2.05)) }
            #expect(alone.mediaResources.readerCount == 1 && alone.mediaResources.existingReader(for: ids[3]) != nil)

            // The preview playing from 0.5 s to 3.67 s, frame after frame: at 2 s, the readers of clips 3 to 6; at the end,
            // none.
            let previewed = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            let (playing, played) = engine(previewed)
            for k in 15...110 {
                let before = played.count
                playing.request(.playing(seconds: seconds(k, rate: rate)))
                #expect(await eventually(timeout: .seconds(30)) { played.count > before }, "frame \(k) drawn")
                if k == 60 {
                    #expect(try #require(played.all.last).frame.media?.asset == assets[3])
                    #expect(Set(ids.filter { previewed.mediaResources.existingReader(for: $0) != nil }).isSubset(of: Set(ids[3...6])))
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(played.all.contains { $0.videos[ids[4]] != nil })
            #expect(previewed.mediaResources.readerCount == 0)
        }
    }

    /// Sixteen files of 0.1 s one after the other: the second before them asks for the first frame of each at once, and
    /// no more than two of the renderer's clips open or decode at a time; every clip still shows its own frames, as the
    /// export draws them and frame by frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func decodingIsBoundedWithManyFiles() async throws {
        try await withTemporaryDirectory { dir in
            let count = 16
            let (project, assets) = try await manyClipsProject(in: dir, count: count, seconds: 0.1)
            let document = manyClipsDocument(project, assets, seconds: 0.1)
            #expect(TimeMap(sequence: document.sequence).duration == 5_600_000_000)
            let size = SIMD2(320, 180), rate = 30
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            // Clip i shows from frame 30 + 3i; its second frame (its 0.0333 s) at frame 31 + 3i.
            let middles = Set((0..<count).map { 31 + 3 * $0 })
            let frames = try await exportFrames(renderer, frames: 0...(30 + 3 * count), keeping: middles, rate: rate)
            let gate = renderer.mediaResources.gate
            #expect(gate.mostAtOnce >= 1 && gate.mostAtOnce <= MediaClipResources.decodesAtOnce, "\(gate.mostAtOnce)")
            let center = (size.x / 2, size.y / 2)
            for i in 0..<count {
                let bytes = try #require(frames[31 + 3 * i])
                #expect(isFrame(pixel(bytes, width: size.x, x: center.0, y: center.1), 5 * i + 1), "clip \(i)")
            }
            let alone = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            let drawn = try await offThePool { try [0, 7, 15].map { try alone.renderBytes(at: seconds(31 + 3 * $0, rate: rate)) } }
            #expect(drawn == [0, 7, 15].map { frames[31 + 3 * $0] ?? [] })
            #expect(alone.mediaResources.gate.mostAtOnce == 1)
        }
    }

    /// A file AVFoundation cannot open at first (not a movie), the movie put in its place afterwards: the clip draws the
    /// background and is listed as missing video while its reader gave no frame; `retryInterval` after, a new reader reads
    /// the movie, frame by frame, as the export draws and in a pause of the preview.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func aFailedReaderIsTriedAgain() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let file = project.package.fileURL(asset), movie = dir.appending(path: "movie.mov")
            try FileManager.default.moveItem(at: file, to: movie)
            try Data(repeating: 7, count: 4096).write(to: file)
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let size = SIMD2(640, 360), rate = 30
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            let pausedRenderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
            let (paused, pausedFrames) = engine(pausedRenderer)
            let frame = try renderer.frame(of: renderer.scene, at: 2.5)
            let background = try await backgroundBytes(of: frame, renderer)
            #expect(try await offThePool { try renderer.renderBytes(at: 2.5) } == background)
            #expect(try await exportBytes(renderer, frames: 70...75, rate: rate) == background)
            paused.request(.paused(frame: 75))
            #expect(await eventually(timeout: .seconds(30)) { pausedFrames.count >= 1 })
            #expect(try await paused.drawnBytes() == background)
            let id = AssetFrameReader.readerID(of: asset)
            #expect(renderer.mediaResources.existingReader(for: id)?.unusableSince != nil)
            let missing = renderer.missingVideo
            #expect(missing.count == 1 && missing.first?.track == id && missing.first?.file == asset)
            #expect(missing.first?.start == 2 && missing.first?.end == 4)
            if case .cannotOpen? = missing.first?.reason {} else { Issue.record("\(String(describing: missing.first?.reason))") }

            // The movie in place: read again once `retryInterval` passes (made 0 here).
            _ = try FileManager.default.replaceItemAt(file, withItemAt: movie)
            renderer.mediaResources.retryInterval = 0
            let shown = (clipPattern + 15) % 64
            let drawn = try await offThePool { try renderer.renderBytes(at: 2.5) }
            #expect(isFrame(pixel(drawn, width: size.x, x: size.x / 2, y: size.y / 2), shown))
            #expect(try await exportBytes(renderer, frames: 70...75, rate: rate) == drawn)
            #expect(renderer.missingVideo.isEmpty)
            // The preview's pause asks again for a clip it found no frame of.
            pausedRenderer.mediaResources.retryInterval = 0
            let before = pausedFrames.count
            paused.request(.paused(frame: 75))
            #expect(await eventually(timeout: .seconds(30)) { pausedFrames.count > before })
            #expect(try await paused.drawnBytes() == drawn)
        }
    }

    /// A clip whose file is gone is missing video, whole, before a frame is drawn; and a frame prepared while it was gone
    /// draws the background without an error when the file is back by the time it is drawn: no reader is made then.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aMissingClipIsListedAndNoReaderIsMadeWhileDrawing() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir)
            let file = project.package.fileURL(asset), aside = dir.appending(path: "aside.mov")
            try FileManager.default.moveItem(at: file, to: aside)
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let size = SIMD2(640, 360)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 30)
            let id = AssetFrameReader.readerID(of: asset)
            #expect(renderer.missingVideo == [MissingVideo(track: id, file: asset, start: 2, end: 4, reason: .fileMissing)])
            let frame = try renderer.frame(of: renderer.scene, at: 2.5)
            #expect(renderer.reader(for: id) == nil)
            try FileManager.default.moveItem(at: aside, to: file)
            let background = try await backgroundBytes(of: frame, renderer)
            let target = MediaPixelBuffer(try pixelBuffer(of: size))
            let error: (any Error)? = try await withCheckedThrowingContinuation { continuation in
                do {
                    try renderer.draw(frame, decoded: [:], into: target.pixelBuffer) { continuation.resume(returning: $0) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #expect(error == nil)
            #expect(packedBytes(of: target.pixelBuffer) == background)
            #expect(renderer.mediaResources.readerCount == 0)
            #expect(renderer.missingVideo.isEmpty)
        }
    }

    /// A style that samples the screens with mipmaps samples the clip from a copy with its mipmaps (a 1280 × 720 clip drawn
    /// a third its size), the same bytes frame by frame and as the export draws it; bilinear without, no copy made.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func mipmappedClipIsSampledFromItsMipmaps() async throws {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir, clipSize: [1280, 720])
            var document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let size = SIMD2(640, 360), rate = 30
            func draw(_ sampling: ScreenSampling) async throws -> (renderer: FrameRenderer, bytes: [UInt8], exported: [UInt8]) {
                document.style.screenSampling = sampling
                let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate)
                #expect(try renderer.frame(of: renderer.scene, at: 2.5).media?.mipmapped == (sampling == .mipmapped))
                let bytes = try await offThePool { try renderer.renderBytes(at: 2.5) }
                return (renderer, bytes, try await exportBytes(renderer, frames: 70...75, rate: rate))
            }
            let mipmapped = try await draw(.mipmapped), bilinear = try await draw(.bilinear)
            #expect(mipmapped.bytes == mipmapped.exported && bilinear.bytes == bilinear.exported)
            #expect(mipmapped.renderer.mediaResources.mipmappedCopies.count.made >= 1)
            #expect(bilinear.renderer.mediaResources.mipmappedCopies.count.made == 0)
            #expect(mipmapped.bytes != bilinear.bytes)
            #expect(isFrame(pixel(mipmapped.bytes, width: size.x, x: size.x / 2, y: size.y / 2), (clipPattern + 15) % 64))
        }
    }

    /// A phone's clip shot upright, encoded on its side (640 × 360 with a quarter turn): drawn upright, 360 × 640 in the
    /// room (391.5 × 696 at 1080p), with what is along the top of its encoded frame (the moving square, at its frame 18 in
    /// the middle of that row) down its right side.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func turnedClipIsDrawnUpright() async throws {
        try await withTemporaryDirectory { dir in
            let quarter = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
            let (project, asset) = try await mediaProject(in: dir, transform: quarter)
            // Its frame 18 (0.6 s) shows at 2.61 s.
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let size = SIMD2(1920, 1080)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let frame = try renderer.frame(of: renderer.scene, at: 2.61)
            let drawn = try await offThePool { try renderer.renderBytes(at: 2.61) }
            let background = try await backgroundBytes(of: frame, renderer)
            let width = 696.0 * 9 / 16
            let rect = Rect(x: (1920 - width) / 2, y: 192, width: width, height: 696)
            #expect(isNear(frame.media?.rect(fitting: MediaOrientation(quarter).uprightSize(of: [640, 360])), rect))
            func at(_ x: Double, _ y: Double, in bytes: [UInt8]? = nil) -> SIMD4<UInt8> {
                pixel(bytes ?? drawn, width: size.x, x: Int(x.rounded(.down)), y: Int(y.rounded(.down)))
            }
            #expect(renderer.mediaResources.orientation(of: asset) == MediaOrientation(quarter))
            let shown = (clipPattern + 18) % 64
            #expect(isFrame(at(rect.midX, rect.midY), shown), "\(at(rect.midX, rect.midY))")
            #expect(isFrame(at(rect.x + 30, rect.y + 100), shown) && isFrame(at(rect.midX, rect.y + 6), shown))
            // Upright, it is narrower than the room: beside it, the background (a clip on its side would cover it).
            #expect(at(rect.x - 120, rect.midY) == at(rect.x - 120, rect.midY, in: background))
            #expect(at(rect.maxX + 120, rect.midY) == at(rect.maxX + 120, rect.midY, in: background))
            // The square: (320…336, 0…16) of the encoded frame, so down its right side, about its middle.
            let scale = 696.0 / 640
            let square = at(rect.maxX - 8 * scale, rect.y + 328 * scale)
            #expect(min(square.x, square.y, square.z) > 200, "\(square)")
            #expect(!isFrame(square, shown))
            #expect(isFrame(at(rect.maxX - 8 * scale, rect.y + 200 * scale), shown))
        }
    }

    /// The upright picture of each of a video track's preferred transforms: a quarter turn either way, a half turn, a
    /// mirror, scaled or moved; any other is drawn as decoded.
    @Test func orientationOfTheTransforms() {
        let upright = MediaOrientation.upright
        #expect(MediaOrientation(.identity) == upright)
        #expect(upright.origin == .zero && upright.across == [1, 0] && upright.down == [0, 1])
        #expect(upright.uprightSize(of: [640, 360]) == [640, 360])
        // A quarter turn clockwise (a phone's upright clip): the picture's top-left is the frame's bottom-left, its width
        // up the frame's left side.
        let quarter = MediaOrientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        #expect(quarter.origin == [0, 1] && quarter.across == [0, -1] && quarter.down == [1, 0])
        #expect(quarter.uprightSize(of: [1920, 1080]) == [1080, 1920])
        // The same turn without its move, or scaled, is the same picture.
        #expect(MediaOrientation(CGAffineTransform(rotationAngle: .pi / 2)) == quarter)
        #expect(MediaOrientation(CGAffineTransform(a: 0, b: 2, c: -2, d: 0, tx: 0, ty: 0)) == quarter)
        // The other way.
        let back = MediaOrientation(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920))
        #expect(back.origin == [1, 0] && back.across == [0, 1] && back.down == [-1, 0])
        let half = MediaOrientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080))
        #expect(half.origin == [1, 1] && half.across == [-1, 0] && half.down == [0, -1] && half.uprightSize(of: [4, 3]) == [4, 3])
        let mirrored = MediaOrientation(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0))
        #expect(mirrored.origin == [1, 0] && mirrored.across == [-1, 0] && mirrored.down == [0, 1])
        // Each maps the picture's corners onto the frame's.
        for orientation in [upright, quarter, back, half, mirrored] {
            let corners = [SIMD2<Float>(0, 0), [1, 0], [0, 1], [1, 1]].map {
                orientation.origin + $0.x * orientation.across + $0.y * orientation.down
            }
            #expect(Set(corners.map { [$0.x, $0.y] }) == [[0, 0], [1, 0], [0, 1], [1, 1]])
        }
        for other in [
            CGAffineTransform(rotationAngle: .pi / 4), CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0),
            CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0), CGAffineTransform(a: 1, b: 0.5, c: 0, d: 1, tx: 0, ty: 0),
        ] {
            #expect(MediaOrientation(other) == upright, "\(other)")
        }
    }
}

/// The compositor alone, drawing frames with the textures of a screen, a cursor and an imported clip of its own.
private struct MediaDrawer {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let cursor: any MTLTexture
    let clip: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        screen = try StageDrawing.screenTexture(device: device)
        cursor = try CursorSprite.makeTexture(device: device)
        clip = try StageDrawing.screenTexture(device: device, width: 320, height: 180)
    }

    /// What drawing `frame` drew, its imported clip with `texture`.
    func counts(of frame: RenderFrame, texture: (any MTLTexture)?) throws -> DrawCounts {
        try draw(frame, texture: texture).counts
    }

    /// Draws `frame`, its imported clip with `texture`: what it drew, and the bytes.
    func draw(_ frame: RenderFrame, texture: (any MTLTexture)?) throws -> (counts: DrawCounts, bytes: [UInt8]) {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        var counts = DrawCounts()
        let layers = LayerTextures(media: texture.map { MediaClipTextures(frame: $0, orientation: .upright) }, annotations: nil)
        try compositor.encode(
            frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer, counts: &counts,
            layerTextures: layers)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return (counts, StageDrawing.bytes(of: target))
    }
}

// MARK: - Pictures to look at

/// Where `mediaClipShots` writes its PNGs: `TOMA_MEDIA_SHOTS`, a folder. Only on demand.
private let shotsFolder = ProcessInfo.processInfo.environment["TOMA_MEDIA_SHOTS"]

/// Writes BGRA `bytes` of `size` as a PNG at `url`.
private func writePNG(_ bytes: [UInt8], size: SIMD2<Int>, to url: URL) throws {
    let data = try #require(CFDataCreate(nil, bytes, bytes.count))
    let provider = try #require(CGDataProvider(data: data))
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    let image = try #require(CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// The clip on its side and turned, at 1080p, at 2.5 s: `landscape.png`, `upright.png`.
@Test(.enabled(if: (MetalCondition.isAvailable || MetalCondition.isRequired) && shotsFolder != nil))
func mediaClipShots() async throws {
    let folder = URL(fileURLWithPath: try #require(shotsFolder), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, transform) in [("landscape", CGAffineTransform.identity), ("upright", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))] {
        try await withTemporaryDirectory { dir in
            let (project, asset) = try await mediaProject(in: dir, transform: transform)
            let document = mediaDocument(project, MediaClip(asset: asset, start: 0, end: 2_000_000_000))
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [1920, 1080])
            let bytes = try await offThePool { try renderer.renderBytes(at: 2.5) }
            try writePNG(bytes, size: [1920, 1080], to: folder.appending(path: "\(name).png"))
        }
    }
}
