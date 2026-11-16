// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for the engine's hooks, `FrameRenderer.reader(for:)`, `TrackFrameReader.openedReaderCount` and the
// prefetcher.
@testable import Render
import Synchronization
import SyntheticCapture
import Testing

// The preview off the main thread (design §7.8): the main thread only asks, a queue of the engine's own decodes, draws
// and presents, the latest request wins, a pause is the export's frame, a scrub shows the key frame at or before the
// instant, and the size changes without opening a decoder again.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)

/// A take of one display, 640 × 360 at 30 fps from `base` (4 s in one segment unless `segments` says otherwise; a key
/// frame every second at most, as the recorder writes them), with the cursor moving over it.
private func project(in dir: URL, segments: [VideoSegmentSpec]? = nil) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame),
        segments: segments ?? [VideoSegmentSpec(start: base, seconds: 4)])
    try builder.addEvents(cursorEvents(from: base, seconds: 4, across: screenFrame))
    return try builder.write()
}

/// The presentation times of the sync samples (key frames) of the video track of the movie at `url`, read from the
/// samples themselves (`kCMSampleAttachmentKey_NotSync`), without decoding.
private func syncSeconds(of url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    return try await readTrack(track, of: asset, outputSettings: nil, into: [Double]()) { keys, sample in
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync, CMSampleBufferGetNumSamples(sample) > 0 { keys.append(sample.presentationTimeStamp.seconds) }
    }
}

/// Output seconds of frame `n` at `rate` frames per second.
private func seconds(ofFrame n: Int, rate: Int) -> Double {
    Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9
}

/// An engine for `renderer` with a layer of `drawable` pixels, and what it draws, gathered from its callbacks.
private final class Watched: @unchecked Sendable {
    let engine: PreviewEngine
    let layer = CAMetalLayer()
    private let lock = NSLock()
    private var drawnFrames: [PreviewEngine.DrawnFrame] = []
    private var presentedFrames: [(seconds: Double, late: Bool)] = []

    init(_ renderer: FrameRenderer, drawable: SIMD2<Int> = [640, 360]) {
        CATransaction.begin()
        layer.drawableSize = CGSize(width: drawable.x, height: drawable.y)
        CATransaction.commit()
        engine = PreviewEngine(renderer: renderer, layer: layer)
        engine.onPresented = { [self] seconds, late in lock.withLock { presentedFrames.append((seconds, late)) } }
        engine.hooks.onDrawn = { [self] frame in lock.withLock { drawnFrames.append(frame) } }
    }

    var drawn: [PreviewEngine.DrawnFrame] { lock.withLock { drawnFrames } }
    var presented: [(seconds: Double, late: Bool)] { lock.withLock { presentedFrames } }

    /// Waits until `count` frames are drawn, or 30 s; returns the last one.
    @discardableResult
    func waitForDrawn(_ count: Int) async throws -> PreviewEngine.DrawnFrame {
        #expect(await eventually(timeout: .seconds(30)) { self.drawn.count >= count }, "\(count) frames drawn")
        return try #require(drawn.last)
    }
}

/// A gate a hook waits at until the test opens it for good (or 60 s pass, so nothing is left hanging).
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = 0
    private var isOpen = false

    var hasWaiter: Bool { condition.withLock { waiting > 0 } }

    func wait() {
        condition.withLock {
            waiting += 1
            let deadline = Date().addingTimeInterval(60)
            while !isOpen, condition.wait(until: deadline) {}
        }
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }
}

/// A renderer of the legacy document of `project` at `size`, drawing `rate` frames per second.
private func legacyRenderer(_ project: LoadedProject, _ size: SIMD2<Int>, rate: Int) throws -> FrameRenderer {
    try FrameRenderer(project: project, document: .legacy(for: project), outputSize: size, frameRate: rate)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func latestRequestWins() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [640, 360], rate: 30)
        let watched = Watched(renderer)
        let gate = Gate()
        let first = Mutex(true)
        // The renderer is held up while it draws the first frame.
        watched.engine.hooks.beforeDrawing = { _ in
            if first.withLock({ defer { $0 = false }; return $0 }) { gate.wait() }
        }
        watched.engine.request(.paused(frame: 0))
        #expect(await eventually { gate.hasWaiter })
        for n in 1...10 { watched.engine.request(.paused(frame: n)) }
        gate.open()
        try await watched.waitForDrawn(2)
        // Nothing else comes: a request asked now is drawn right after them, in order.
        watched.engine.request(.paused(frame: 20))
        try await watched.waitForDrawn(3)
        #expect(watched.drawn.map(\.request) == [.paused(frame: 0), .paused(frame: 10), .paused(frame: 20)])
        #expect(watched.presented.map(\.seconds) == [0, seconds(ofFrame: 10, rate: 30), seconds(ofFrame: 20, rate: 30)])
    }
}

@MainActor
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func mainThreadNeverWaits() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [640, 360], rate: 30)
        let watched = Watched(renderer)
        let gate = Gate()
        defer { gate.open() }
        // The engine's queue is held up for good while it draws.
        watched.engine.hooks.beforeDrawing = { _ in gate.wait() }
        let clock = ContinuousClock()
        var longest = Duration.zero
        watched.engine.request(.paused(frame: 0))
        #expect(await eventually { gate.hasWaiter })
        let paths = MotionPaths(take: project.take, events: project.events, document: .legacy(for: project))
        let other = renderer.makeScene(document: .legacy(for: project), paths: paths, outputSize: [1280, 720])
        for k in 0..<200 {
            let request: PreviewRequest = switch k % 3 {
            case 0: .playing(seconds: Double(k) / 60)
            case 1: .scrubbing(seconds: Double(k) / 70)
            default: .paused(frame: k % 120)
            }
            longest = max(longest, clock.measure { watched.engine.request(request) })
            if k % 50 == 0 { longest = max(longest, clock.measure { watched.engine.setScene(other) }) }
        }
        #expect(longest < .milliseconds(1), "the longest request took \(longest)")
        #expect(watched.drawn.isEmpty)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func pausedFrameIsTheExportFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let size = SIMD2(1280, 720)
        let renderer = try legacyRenderer(project, size, rate: 60)
        let watched = Watched(renderer)
        watched.engine.request(.paused(frame: 42))
        let drawn = try await watched.waitForDrawn(1)
        #expect(drawn.frame.outputSize == size && !drawn.late)
        #expect(watched.presented.map(\.seconds) == [seconds(ofFrame: 42, rate: 60)])
        let shown = try await watched.engine.drawnBytes()
        let exported = try await offThePool { try renderer.renderBytes(at: seconds(ofFrame: 42, rate: 60)) }
        #expect(shown.count == size.x * size.y * 4)
        #expect(shown == exported)
        // Frame 42 at 60 fps is 0.7 s: frame 21 of the 30 fps source.
        #expect(frameIndex(of: try #require(drawn.videos[trackID])) == 21)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func sceneSwapRedrawsTheSamePausedFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let size = SIMD2(1280, 720)
        let renderer = try legacyRenderer(project, size, rate: 60)
        let watched = Watched(renderer)
        watched.engine.request(.paused(frame: 42))
        try await watched.waitForDrawn(1)
        let before = try await watched.engine.drawnBytes()

        var document = EditDocument.legacy(for: project)
        document.style.padding = 0.2
        let paths = MotionPaths(take: project.take, events: project.events, document: document)
        watched.engine.setScene(renderer.makeScene(document: document, paths: paths, outputSize: size))
        let redrawn = try await watched.waitForDrawn(2)
        #expect(redrawn.request == .paused(frame: 42))
        #expect(watched.presented.map(\.seconds) == [seconds(ofFrame: 42, rate: 60), seconds(ofFrame: 42, rate: 60)])
        let after = try await watched.engine.drawnBytes()
        // The new margin, as the export draws it: the renderer's scene is the new one.
        #expect(after != before)
        #expect(after == (try await offThePool { try renderer.renderBytes(at: seconds(ofFrame: 42, rate: 60)) }))
        #expect(redrawn.frame.screen?.rect != watched.drawn[0].frame.screen?.rect)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func sizeChangeDoesNotReopenReaders() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [1920, 1080], rate: 60)
        let watched = Watched(renderer, drawable: [960, 540])
        watched.engine.request(.paused(frame: 42))
        try await watched.waitForDrawn(1)
        let firstPause = try await watched.engine.drawnBytes()
        let reader = try #require(renderer.reader(for: trackID))
        let opened = reader.openedReaderCount
        #expect(opened == 1)

        // Playing at 1280 × 720 from the next frame: the same reader reads on.
        watched.engine.hooks.playbackSize = [1280, 720]
        for n in 43...50 {
            watched.engine.request(.playing(seconds: seconds(ofFrame: n, rate: 60)))
            try await watched.waitForDrawn(n - 41)
        }
        #expect(watched.drawn.dropFirst().allSatisfy { $0.frame.outputSize == SIMD2(1280, 720) })
        // And back to the pause, at the export's size.
        watched.engine.request(.paused(frame: 42))
        let paused = try await watched.waitForDrawn(10)
        #expect(paused.request == .paused(frame: 42) && paused.frame.outputSize == SIMD2(1920, 1080))
        #expect(try await watched.engine.drawnBytes() == firstPause)
        #expect(reader.openedReaderCount == opened)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func scrubbingShowsTheKeyFrameAtOrBefore() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [1280, 720], rate: 30)
        let watched = Watched(renderer)
        // What the scrubbed frames read, without the exact frames decoded ahead for a release.
        watched.engine.hooks.decodesExactFramesWhileScrubbing = false
        watched.engine.request(.paused(frame: 0))
        try await watched.waitForDrawn(1)
        let reader = try #require(renderer.reader(for: trackID))
        let opened = reader.openedReaderCount
        // The key frames the encoder wrote, about one a second, as the file says.
        let segment = try #require(project.take.track(trackID)?.segments.first)
        let keys = try await syncSeconds(of: project.package.fileURL(segment.file))
        let key = try #require(keys.last { $0 <= 2.7 }), next = try #require(keys.first { $0 > 2.7 })
        #expect(key >= 1.5 && next <= 3.5, "key frames at \(keys)")

        watched.engine.request(.scrubbing(seconds: 2.7))
        let scrubbed = try await watched.waitForDrawn(2)
        // The screen is the key frame at or before 2.7 s, the cursor that of 2.7 s.
        #expect(frameIndex(of: try #require(scrubbed.videos[trackID])) == Int((key * 30).rounded()))
        let exact = try renderer.frame(of: renderer.scene, at: 2.7)
        #expect(scrubbed.frame.cursor != nil && scrubbed.frame.cursor == exact.cursor)
        #expect(scrubbed.frame.screen?.sourceTime == base.adding(seconds: 2.7))
        // Without another AVAssetReader: one key frame decoded on its own.
        #expect(reader.openedReaderCount == opened)
        let prefetcher = try #require(try renderer.prefetcher(for: trackID))
        #expect(prefetcher.keyFramesDecoded == 1)

        // Another instant before the next key frame decodes nothing; past it, that key frame shows.
        watched.engine.request(.scrubbing(seconds: (2.7 + next) / 2))
        #expect(frameIndex(of: try #require(try await watched.waitForDrawn(3).videos[trackID])) == Int((key * 30).rounded()))
        #expect(prefetcher.keyFramesDecoded == 1)
        watched.engine.request(.scrubbing(seconds: next + 0.1))
        let past = frameIndex(of: try #require(try await watched.waitForDrawn(4).videos[trackID]))
        // (The palette has 64 colours.)
        #expect(past == Int((next * 30).rounded()) % 64, "key frames at \(keys)")
        #expect(prefetcher.keyFramesDecoded == 2)
        #expect(reader.openedReaderCount == opened)

        // Released: the exact frame.
        watched.engine.request(.paused(frame: 96))
        let released = frameIndex(of: try #require(try await watched.waitForDrawn(5).videos[trackID]))
        #expect(released == 96 % 64)
    }
}

@MainActor
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func stuckTrackLoadNeverBlocksTheCaller() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir, segments: [
            VideoSegmentSpec(start: base, seconds: 2), VideoSegmentSpec(start: base.adding(seconds: 2), seconds: 2),
        ])
        let renderer = try legacyRenderer(project, [640, 360], rate: 30)
        let watched = Watched(renderer)
        watched.engine.request(.paused(frame: 30))
        try await watched.waitForDrawn(1)
        let shown = try await watched.engine.drawnBytes()

        // The second segment's track never loads (until the test lets it go).
        let gate = Gate()
        defer { gate.open() }
        let reader = try #require(renderer.reader(for: trackID))
        reader.trackLoader = { asset in
            guard asset.url.lastPathComponent == "seg-0002.mov" else { return TrackFrameReader.loadFirstVideoTrack(of: asset) }
            gate.wait()
            return .timedOut
        }
        reader.timeoutBackoff = 3600
        let clock = ContinuousClock()
        var longest = clock.measure { watched.engine.request(.paused(frame: 90)) }
        #expect(await eventually { gate.hasWaiter })
        // The engine's queue is stuck on it: the next requests return at once all the same.
        for request in [PreviewRequest.scrubbing(seconds: 3.5), .playing(seconds: 3), .paused(frame: 100)] {
            longest = max(longest, clock.measure { watched.engine.request(request) })
        }
        #expect(longest < .milliseconds(1), "the longest request took \(longest)")
        // The frame shown stays: the queue is held in the load, so nothing else can be drawn.
        #expect(gate.hasWaiter && watched.drawn.count == 1)
        gate.open()
        // Let go, the frame being drawn is, then the latest request: the frame before the gap, as the export shows it.
        let latest = try await watched.waitForDrawn(3)
        #expect(watched.drawn.map(\.request) == [.paused(frame: 30), .paused(frame: 90), .paused(frame: 100)])
        #expect(frameIndex(of: try #require(latest.videos[trackID])) == 59)
        #expect(try await watched.engine.drawnBytes() != shown)
    }
}

/// A second caller of a prefetcher (Task 30's review): asking for another instant while the first one waits slows the
/// first one down, but never leaves it waiting for good; nor a third, waiting on a queue of its own (the preview's
/// pause).
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func secondCallerNeverLeavesTheFirstWaiting() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [640, 360], rate: 30)
        let reader = try #require(renderer.reader(for: trackID))
        let gate = Gate()
        defer { gate.open() }
        reader.trackLoader = { asset in
            gate.wait()
            return TrackFrameReader.loadFirstVideoTrack(of: asset)
        }
        let prefetcher = try FramePrefetcher(reader: reader, device: renderer.device)
        let first = Task { try await prefetcher.frame(atSource: base.adding(seconds: 0.5)) }
        #expect(await eventually { gate.hasWaiter })
        // The first instant is being decoded (its track loading) when another one is asked for.
        let second = Task { try await prefetcher.frame(atSource: base.adding(seconds: 1.5)) }
        let done = Mutex<[Int]>([])
        #expect(await eventually { prefetcher.pending.scheduled == 2 })
        prefetcher.frame(atSource: base.adding(seconds: 2.5)) { result in
            let index = (try? result.get()).flatMap { $0 }.map { frameIndex(of: $0.pixelBuffer) } ?? -1
            done.withLock { $0.append(index) }
        }
        #expect(prefetcher.pending.scheduled == 3)
        gate.open()
        for task in [first, second] {
            Task {
                let index = (try? await task.value).map { frameIndex(of: $0.pixelBuffer) } ?? -1
                done.withLock { $0.append(index) }
            }
        }
        #expect(await eventually(timeout: .seconds(20)) { done.withLock { $0.count == 3 } }, "every caller gets its frame")
        // Frames 15, 45 and 75 (the palette has 64 colours).
        #expect(done.withLock { $0.sorted() } == [11, 15, 45])
    }
}

/// A frame drawn without a video it shows is an error, not a frame without its screen (Task 30's review); a track the
/// take does not have still shows nothing, as drawing frame by frame does.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func frameWithoutItsDecodedVideoIsAnError() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let size = SIMD2(640, 360)
        let renderer = try legacyRenderer(project, size, rate: 30)
        let frame = try renderer.frame(of: renderer.scene, at: 1)
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
        let pixelBuffer = try #require(created)
        #expect(throws: RenderError.frameNotDecoded(track: trackID, sourceTime: base.adding(seconds: 1))) {
            try renderer.draw(frame, decoded: [:], into: pixelBuffer) { _ in }
        }
        var elsewhere = frame
        elsewhere.screen?.trackID = "display-9"
        let drawn = Mutex(false)
        try renderer.draw(elsewhere, decoded: [:], into: pixelBuffer) { error in drawn.withLock { $0 = error == nil } }
        #expect(await eventually { drawn.withLock { $0 } })
    }
}

/// What depends on the size is kept for the last two sizes drawn, so the preview going from one size to the other and
/// back blurs nothing again (Task 21's review); and a background image that could not be read is looked for again with
/// a new scene, not on every frame.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func twoSizesKeepTheirBackgroundsAndAMissingImageIsLookedForAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        var blurred = EditDocument.legacy(for: project)
        blurred.style.background = .wallpaper("aurora-1")
        blurred.style.backgroundBlur = 0.5
        let renderer = try FrameRenderer(project: project, document: blurred, outputSize: [1280, 720], frameRate: 30)
        let large = renderer.scene, small = large.resized(to: [640, 360])
        #expect(small.outputSize == SIMD2(640, 360) && small.duration == large.duration && small.frameRate == 30)
        let blurs = try await offThePool { () -> Int in
            for scene in [large, small, large, small, large] {
                _ = try renderer.renderOffscreen(size: scene.outputSize) { target, commandBuffer in
                    try renderer.encode(scene: scene, at: 0.5, into: target, commandBuffer: commandBuffer)
                }
            }
            return renderer.backgroundImages.blurCount
        }
        #expect(blurs == 2)

        // An image that is not there yet: the classic gradient, which stays until a new scene.
        let file = "assets/0123456789abcdef0123456789abcdef.png"
        var pictured = EditDocument.legacy(for: project)
        pictured.style.background = .image(file: file)
        let withImage = try FrameRenderer(project: project, document: pictured, outputSize: [640, 360], frameRate: 30)
        let missing = try await offThePool { try withImage.renderBytes(at: 0.5) }
        let url = project.package.fileURL(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try redImage().write(to: url)
        #expect(try await offThePool { try withImage.renderBytes(at: 0.6) } == (try await offThePool { try withImage.renderBytes(at: 0.6) }))
        let before = try await offThePool { try withImage.renderBytes(at: 0.5) }
        #expect(before == missing)
        withImage.setScene(withImage.scene)
        let after = try await offThePool { try withImage.renderBytes(at: 0.5) }
        #expect(after != missing)
        // Red at the stage's top-left corner, outside the screen.
        let corner = pixel(after, width: 640, x: 2, y: 2)
        #expect(corner.z > 200 && corner.y < 60 && corner.x < 60, "\(corner)")
    }
}

/// A red PNG of 64 × 36.
private func redImage() throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// While scrubbing, the exact frame nearest the playhead is decoded in the background, so the pause asked for at the
/// release finds it decoded: no reader is opened then, and it is the export's frame.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func releaseFindsTheExactFrameDecodedWhileScrubbing() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [1280, 720], rate: 30)
        let watched = Watched(renderer)
        watched.engine.request(.paused(frame: 0))
        try await watched.waitForDrawn(1)
        for (k, seconds) in [1.0, 2.0, 2.5, 2.7].enumerated() {
            watched.engine.request(.scrubbing(seconds: seconds))
            try await watched.waitForDrawn(k + 2)
        }
        // The frame nearest 2.7 s (81), and the one before it, decoded ahead.
        let prefetcher = try #require(try renderer.prefetcher(for: trackID))
        #expect(await eventually(timeout: .seconds(20)) { prefetcher.pending.decoded == 2 })
        let reader = try #require(renderer.reader(for: trackID))
        let opened = reader.openedReaderCount
        watched.engine.request(.paused(frame: 81))
        let released = try await watched.waitForDrawn(6)
        #expect(released.request == .paused(frame: 81))
        #expect(reader.openedReaderCount == opened)
        #expect(frameIndex(of: try #require(released.videos[trackID])) == 81 % 64)
        #expect(try await watched.engine.drawnBytes() == (try await offThePool { try renderer.renderBytes(at: seconds(ofFrame: 81, rate: 30)) }))
    }
}

/// A revision that changes nothing the motion paths read keeps them (an hour of take takes about 100 ms to build): they
/// are the ones it would build; one that changes what they read builds them again.
@Test func pathsAreKeptForAnEditTheyDoNotRead() throws {
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 4))])])
    let events = cursorEvents(from: base, seconds: 4, across: screenFrame)
    var document = EditDocument.legacy(take: take, events: events)
    document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
    document.zoom.regions = [ZoomRegion(
        id: "z-00000001", take: takeID, start: base.adding(seconds: 1), end: base.adding(seconds: 2.5), origin: .user, depth: 2,
        focus: .follow, instant: false)]
    let paths = MotionPaths(take: take, events: events, document: document)

    var styled = document
    styled.style.background = .color(RGBA(0.1, 0.2, 0.3, 1))
    styled.style.shadow = 0.9
    styled.style.cornerRadius = 0.03
    styled.style.backgroundBlur = 0.4
    styled.style.screenSampling = .mipmapped
    #expect(paths.areThePaths(of: styled))
    let rebuilt = MotionPaths(take: take, events: events, document: styled)
    for k in 0..<400 {
        let τ = Int64(k) * 10_000_000
        #expect(paths.cursor.sample(atOutput: τ) == rebuilt.cursor.sample(atOutput: τ))
        #expect(paths.zoom.state(atOutput: τ) == rebuilt.zoom.state(atOutput: τ))
    }

    var padded = document
    padded.style.padding += 0.02
    var zoomed = document
    zoomed.zoom.regions[0].depth = 3
    var cut = document
    cut.sequence[0].end = base.adding(seconds: 3)
    var cursor = document
    cursor.cursor.smoothing = .off
    var camera = document
    camera.camera.show.toggle()
    var portrait = document
    portrait.aspect = .portrait
    var framed = document
    framed.style.frame = .macWindow(appearance: .light, title: "Toma", buttons: true)
    var screens = document
    screens.screens.changes = [ScreenChange(id: "p-00000001", take: takeID, t: base.adding(seconds: 2), track: trackID, origin: .user)]
    for edited in [padded, zoomed, cut, cursor, camera, portrait, framed, screens] { #expect(!paths.areThePaths(of: edited)) }
}

/// While playing, `latest(atSource:)` never waits: before anything is decoded it has nothing, and a frame not decoded in
/// time leaves the frame decoded before it.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func latestNeverWaitsAndLeavesTheFrameBefore() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [640, 360], rate: 30)
        let reader = try #require(renderer.reader(for: trackID))
        let gate = Gate()
        defer { gate.open() }
        reader.trackLoader = { asset in
            gate.wait()
            return TrackFrameReader.loadFirstVideoTrack(of: asset)
        }
        let prefetcher = try FramePrefetcher(reader: reader, device: renderer.device)
        let half = base.adding(seconds: 0.5), two = base.adding(seconds: 2)
        prefetcher.schedule(half)
        #expect(await eventually { gate.hasWaiter })
        // Being decoded (the track still loading): nothing yet, at once.
        #expect(try prefetcher.latest(atSource: half) == nil)
        gate.open()
        #expect(await eventually { prefetcher.pending.decoded == 1 })
        #expect(frameIndex(of: try #require(try prefetcher.latest(atSource: half)).pixelBuffer) == 15)
        // Two seconds was never scheduled: the frame before it stays, while it is decoded.
        #expect(frameIndex(of: try #require(try prefetcher.latest(atSource: two)).pixelBuffer) == 15)
        #expect(await eventually { prefetcher.pending.decoded == 1 })
        #expect(frameIndex(of: try #require(try prefetcher.latest(atSource: two)).pixelBuffer) == 60)
    }
}

/// `resized(to:)` is the scene a new evaluator at that size gives, frame for frame: the background's blur, the window
/// frame and a change of shape under way, at both sizes.
@Test func resizedIsTheSceneAtThatSize() {
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 4))])])
    var events = cursorEvents(from: base, seconds: 4, across: screenFrame)
    events.append(InputEvent(
        t: base.adding(seconds: 2), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 480, height: 480), scale: 1)))
    var document = EditDocument.legacy(take: take, events: events)
    document.style.background = .wallpaper("aurora-1")
    document.style.backgroundBlur = 0.5
    document.style.shadow = 0.6
    document.style.frame = .macWindow(appearance: .dark, title: "Toma", buttons: true)
    document.style.geometryTransition = .spring
    document.cursor.motionBlur = 1
    let paths = MotionPaths(take: take, events: events, document: document)
    let large = FrameEvaluator(take: take, events: events, document: document, outputSize: [1920, 1080], paths: paths, frameRate: 60)
    let small = FrameEvaluator(take: take, events: events, document: document, outputSize: [1280, 720], paths: paths, frameRate: 60)
    let resizedDown = large.resized(to: [1280, 720]), resizedUp = small.resized(to: [1920, 1080])
    #expect(resizedDown.outputSize == SIMD2(1280, 720) && resizedDown.frameRate == 60 && resizedDown.duration == small.duration)
    for k in 0..<80 {
        let t = Double(k) / 20
        #expect(resizedDown.frame(at: t) == small.frame(at: t), "down at \(t) s")
        #expect(resizedUp.frame(at: t) == large.frame(at: t), "up at \(t) s")
    }
}

/// A background image whose texture Metal could not make throws the same error on every frame, without decoding or
/// uploading it again, until a new scene tries it again (Task 21's review).
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func aFailedUploadIsNotTriedAgainUntilANewScene() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let file = "assets/fedcba9876543210fedcba9876543210.png"
        let url = project.package.fileURL(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try redImage().write(to: url)
        var pictured = EditDocument.legacy(for: project)
        pictured.style.background = .image(file: file)
        let renderer = try FrameRenderer(project: project, document: pictured, outputSize: [640, 360], frameRate: 30)
        let failure = RenderError.metalResourceUnavailable("background image texture (test)")
        renderer.backgroundImages.uploadFailure = failure
        let failures = try await offThePool { () -> [RenderError?] in
            (0..<3).map { k in
                do {
                    _ = try renderer.renderBytes(at: 0.5 + Double(k) / 10)
                    return nil
                } catch {
                    return error as? RenderError
                }
            }
        }
        #expect(failures == [failure, failure, failure])
        #expect(renderer.backgroundImages.uploadCount == 1)
        #expect(BackgroundImages.decodeCount(of: .asset(file), in: project.package) == 1)
        // A new scene tries it again: now it uploads, and the image is drawn.
        renderer.backgroundImages.uploadFailure = nil
        renderer.setScene(renderer.scene)
        let drawn = try await offThePool { try renderer.renderBytes(at: 0.5) }
        #expect(renderer.backgroundImages.uploadCount == 2)
        let corner = pixel(drawn, width: 640, x: 2, y: 2)
        #expect(corner.z > 200 && corner.y < 60 && corner.x < 60, "\(corner)")
    }
}

/// A new scene while scrubbing drops what the prefetchers decoded ahead (`FrameRenderer.setScene(_:)`): the scrub drawn
/// again with it schedules the exact frames near the playhead again.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func aNewSceneWhileScrubbingDecodesTheExactFramesAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await project(in: dir)
        let renderer = try legacyRenderer(project, [1280, 720], rate: 30)
        let watched = Watched(renderer)
        watched.engine.request(.scrubbing(seconds: 2.7))
        try await watched.waitForDrawn(1)
        let prefetcher = try #require(try renderer.prefetcher(for: trackID))
        #expect(await eventually(timeout: .seconds(20)) { prefetcher.pending.decoded == 2 })

        var document = EditDocument.legacy(for: project)
        document.style.padding = 0.2
        let paths = MotionPaths(take: project.take, events: project.events, document: document)
        watched.engine.setScene(renderer.makeScene(document: document, paths: paths, outputSize: [1280, 720]))
        let redrawn = try await watched.waitForDrawn(2)
        #expect(redrawn.request == .scrubbing(seconds: 2.7))
        // (Scheduled after the frame is presented: waited for, not read at once.)
        #expect(await eventually(timeout: .seconds(20)) { prefetcher.pending.decoded == 2 })
    }
}
