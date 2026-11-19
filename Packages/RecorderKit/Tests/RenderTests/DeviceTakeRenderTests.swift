// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `DeviceFrameFit`, `TrackFrameReader.media(at:)`, `KeyFrameDecoder` and `FrameEvaluator.frame(at:)`.
@testable import Render
import SyntheticCapture
import Testing

// A take of an iPhone or iPad turned while it recorded (phase 2 design §7.6, plan 2c decision 18): its `device` track goes
// on in a segment of another size, and every frame of it is read fitted whole into the size of the first segment, centred,
// with black around it; the geometry stays the first segment's, and the preview, the scrub and the export read the same.

private let deviceID = "device"

/// The `source` of a `device` track whose first segment is `width` × `height` pixels.
private func deviceSource(width: Int, height: Int) -> TrackSource {
    TrackSource(
        name: "Synthetic iPhone", deviceUniqueID: "synthetic-device",
        globalFrame: Rect(x: 0, y: 0, width: Double(width), height: Double(height)), pixelScale: 1)
}

/// A take of a device that records `first` (width, height) for `seconds` and then, turned, `first` the other way round for
/// `seconds` more, each frame through `transform`; its package is of version 4, as a device's take is.
private func turnedTake(
    in dir: URL, first: SIMD2<Int>, seconds: Double = 1, framesPerSecond: Int = 10,
    transform: (@Sendable (Int, CMSampleBuffer) -> CMSampleBuffer)? = nil
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, formatVersion: 4)
    try await builder.addVideoTrack(id: deviceID, kind: .device, source: deviceSource(width: first.x, height: first.y), segments: [
        VideoSegmentSpec(
            start: base, seconds: seconds, framesPerSecond: framesPerSecond, width: first.x, height: first.y,
            endReason: .formatChanged, transform: transform),
        VideoSegmentSpec(
            start: base.adding(seconds: seconds), seconds: seconds, framesPerSecond: framesPerSecond, width: first.y,
            height: first.x, transform: transform),
    ])
    return try builder.write()
}

/// The corners' colours, as BGRA: red at the top left, green at the top right, yellow at the bottom left and orange at the
/// bottom right, all far from the palette's blue (200) and from black.
private let corners: [SIMD4<UInt8>] = [[0, 0, 255, 255], [0, 255, 0, 255], [0, 255, 255, 255], [0, 128, 255, 255]]

/// The side of a corner's square, in pixels of the frame.
private let cornerSide = 64

/// `sample` with a square of `cornerSide` at each corner of its frame painted its colour (`corners`), so where the frame's
/// corners land can be seen at any size.
@Sendable private func paintingTheCorners(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    paintCorners(CMSampleBufferGetImageBuffer(sample)!)
    return sample
}

private func paintCorners(_ pixelBuffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    let origins = [(0, 0), (width - cornerSide, 0), (0, height - cornerSide), (width - cornerSide, height - cornerSide)]
    for ((x0, y0), color) in zip(origins, corners) {
        let packed = UInt32(color.x) | UInt32(color.y) << 8 | UInt32(color.z) << 16 | UInt32(color.w) << 24
        for y in y0..<(y0 + cornerSide) {
            base.advanced(by: y * rowBytes + x0 * 4).assumingMemoryBound(to: UInt32.self).update(repeating: packed, count: cornerSide)
        }
    }
}

/// Frames read off the cooperative pool, handed back to the test: nothing else uses them meanwhile.
private struct Read: @unchecked Sendable {
    var frames: [CVPixelBuffer?]
}

/// The frames `reader` gives at `seconds` from `base`, one after the other, off the cooperative pool.
private func frames(_ reader: TrackFrameReader, at seconds: [Double]) async throws -> [CVPixelBuffer?] {
    try await offThePool { Read(frames: seconds.map { reader.pixelBuffer(at: base.adding(seconds: $0)) }) }.frames
}

/// The BGRA pixel at (`x`, `y`) of `pixelBuffer`.
private func pixel(of pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> SIMD4<UInt8> {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pixelBuffer)!
        .advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4).assumingMemoryBound(to: UInt8.self)
    return SIMD4(p[0], p[1], p[2], p[3])
}

/// Whether every channel of `a` is within `tolerance` of `b`.
private func near(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>, tolerance: Int = 48) -> Bool {
    (0..<4).allSatisfy { abs(Int(a[$0]) - Int(b[$0])) <= tolerance }
}

/// Checks a frame of `size` that shows a frame of `recorded` with its corners painted (`paintingTheCorners`): the content
/// fitted whole at `placed`, its four corners where they belong, and exact black everywhere else.
private func expectFitted(
    _ buffer: CVPixelBuffer, size: SIMD2<Int>, recorded: SIMD2<Int>, tolerance: Int = 48, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(CVPixelBufferGetWidth(buffer) == size.x && CVPixelBufferGetHeight(buffer) == size.y, sourceLocation: sourceLocation)
    #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, sourceLocation: sourceLocation)
    let placed = DeviceFrameFit.placement(of: recorded, in: size)
    let (o, s) = (placed.origin, placed.size)
    // The corner squares, scaled, from their middle.
    let inset = cornerSide * s.x / recorded.x / 2
    let points = [(o.x + inset, o.y + inset), (o.x + s.x - 1 - inset, o.y + inset), (o.x + inset, o.y + s.y - 1 - inset),
                  (o.x + s.x - 1 - inset, o.y + s.y - 1 - inset)]
    for ((x, y), color) in zip(points, corners) {
        let found = pixel(of: buffer, x: x, y: y)
        #expect(near(found, color, tolerance: tolerance), "corner at (\(x), \(y)): \(found)", sourceLocation: sourceLocation)
    }
    // The middle shows the frame (the palette's blue), not black.
    #expect(pixel(of: buffer, x: o.x + s.x / 2, y: o.y + s.y / 2).x >= 150, sourceLocation: sourceLocation)
    // Around the content, video black, untouched.
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var notBlack = 0, outside = 0
    for y in 0..<size.y {
        for x in 0..<size.x where !(o.x..<(o.x + s.x)).contains(x) || !(o.y..<(o.y + s.y)).contains(y) {
            outside += 1
            let p = bytes.advanced(by: y * rowBytes + x * 4)
            if (p[0], p[1], p[2], p[3]) != (0, 0, 0, 255) { notBlack += 1 }
        }
    }
    #expect(notBlack == 0, "\(notBlack) of \(outside) pixels around the content are not black", sourceLocation: sourceLocation)
    #expect((outside > 0) == (s != size), sourceLocation: sourceLocation)
}

@Suite struct DeviceTakeRenderTests {
    @Test func theFitIsWholeAndCentred() {
        // 1920 × 1080 in 1080 × 1920: 0.5625 ×, 1080 × 608 (607.5 rounded) from y 656.
        let turned = DeviceFrameFit.placement(of: [1920, 1080], in: [1080, 1920])
        #expect(turned.origin == [0, 656] && turned.size == [1080, 608])
        // The other way round: 1080 × 1920 in 1920 × 1080, 608 × 1080 from x 656.
        let back = DeviceFrameFit.placement(of: [1080, 1920], in: [1920, 1080])
        #expect(back.origin == [656, 0] && back.size == [608, 1080])
        // The same size, untouched; a smaller one is scaled up.
        #expect(DeviceFrameFit.placement(of: [390, 844], in: [390, 844]) == (origin: [0, 0], size: [390, 844]))
        #expect(DeviceFrameFit.placement(of: [195, 422], in: [390, 844]) == (origin: [0, 0], size: [390, 844]))
    }

    @Test func aFrameOfTheFirstSizeIsLeftAsItIs() throws {
        let sample = SampleFactory.videoSample(width: 108, height: 192, pts: base, frameIndex: 3)
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        var pool: CVPixelBufferPool?
        #expect(DeviceFrameFit.fitted(buffer, into: [108, 192], pool: &pool) === buffer)
        #expect(pool == nil)
    }

    @Test func aTurnedFrameIsFittedExactly() throws {
        let sample = SampleFactory.videoSample(width: 1920, height: 1080, pts: base, frameIndex: 9)
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        paintCorners(buffer)
        var pool: CVPixelBufferPool?
        let fitted = try #require(DeviceFrameFit.fitted(buffer, into: [1080, 1920], pool: &pool))
        #expect(CVPixelBufferGetIOSurface(fitted) != nil)
        expectFitted(fitted, size: [1080, 1920], recorded: [1920, 1080], tolerance: 2)
        // From the same pool, the next one.
        let again = try #require(DeviceFrameFit.fitted(buffer, into: [1080, 1920], pool: &pool))
        #expect(again !== fitted && packedBytes(of: again) == packedBytes(of: fitted))
    }

    @Test func onlyADeviceTrackIsFitted() {
        let frame = Rect(x: 0, y: 0, width: 1179, height: 2556)
        let device = TrackRecord(id: deviceID, kind: .device, source: deviceSource(width: 1179, height: 2556), segments: [])
        #expect(DeviceFrameFit.referenceSize(of: device) == [1179, 2556])
        for kind in [TrackKind.display, .window, .camera] {
            #expect(DeviceFrameFit.referenceSize(of: TrackRecord(id: "t", kind: kind, source: displaySource(globalFrame: frame), segments: [])) == nil)
        }
        // A device that never told its size: read as recorded.
        let untold = TrackRecord(id: deviceID, kind: .device, source: TrackSource(name: "iPhone", deviceUniqueID: "x"), segments: [])
        #expect(DeviceFrameFit.referenceSize(of: untold) == nil)
    }

    @Test func firstSegmentIsReadAsRecorded() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await turnedTake(in: dir, first: [180, 320])
            let track = try #require(project.take.track(deviceID))
            // The same segments read as a display's: what the files hold, as decoded.
            let asRecorded = TrackRecord(id: deviceID, kind: .display, source: track.source, segments: track.segments)
            let reader = TrackFrameReader(package: project.package, track: track)
            let plain = TrackFrameReader(package: project.package, track: asRecorded)
            let frame = try #require(try await frames(reader, at: [0.55])[0])
            let recorded = try #require(try await frames(plain, at: [0.55])[0])
            #expect(CVPixelBufferGetWidth(frame) == 180 && CVPixelBufferGetHeight(frame) == 320)
            #expect(frameIndex(of: frame) == 5)
            #expect(packedBytes(of: frame) == packedBytes(of: recorded))
            // The turned segment, as the file holds it, is the other way round.
            let turned = try #require(try await frames(plain, at: [1.55])[0])
            #expect(CVPixelBufferGetWidth(turned) == 320)
        }
    }

    @Test func rotatedSegmentIsFittedNotCropped() async throws {
        try await withTemporaryDirectory { dir in
            // 1080 × 1920 turned to 1920 × 1080 at 2 s: the frame at 3 s is 1080 × 1920, with black above and below and the four
            // corners of the content in sight.
            let project = try await turnedTake(in: dir, first: [1080, 1920], seconds: 2, framesPerSecond: 5, transform: paintingTheCorners)
            let track = try #require(project.take.track(deviceID))
            #expect(track.segments.map(\.endReason) == [.formatChanged, .stopped])
            let reader = TrackFrameReader(package: project.package, track: track)
            let read = try await frames(reader, at: [1, 3, 3.01])
            let turned = try #require(read[1])
            expectFitted(turned, size: [1080, 1920], recorded: [1920, 1080])
            // The first segment fills the frame: its corners at the frame's.
            expectFitted(try #require(read[0]), size: [1080, 1920], recorded: [1080, 1920])
            // The same frame asked for again is the same buffer: nothing is fitted twice, and a texture made of it is kept.
            #expect(read[2] === turned)
            #expect(reader.gaps.isEmpty)
        }
    }

    @Test func theGeometryIsTheFirstSegments() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await turnedTake(in: dir, first: [180, 320])
            var document = EditDocument.legacy(for: project)
            document.style.frame = .device(DeviceFrame(model: .iPhone, finish: .dark))
            let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: [1280, 720])
            let before = evaluator.frame(at: 0.5), after = evaluator.frame(at: 1.5)
            // The screen is placed, framed and cropped the same in both segments.
            #expect(before.screen?.rect == after.screen?.rect)
            #expect(before.deviceFrame?.rects == after.deviceFrame?.rects && before.deviceFrame != nil)
            #expect(before.screen?.crop == after.screen?.crop)
        }
    }

    @Test func aManualZoomWorksWithoutACursor() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await turnedTake(in: dir, first: [180, 320])
            #expect(project.events.allSatisfy { if case .segmentStarted = $0.kind { true } else { false } })
            var document = EditDocument.legacy(for: project)
            document.style.frame = .device(DeviceFrame(model: .iPhone, finish: .dark))
            document.cursor.show = false
            document.zoom.regions = [StageDrawing.zoom(1, from: 0.2, to: 1.8, depth: 2, focus: .follow)]
            let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: [1280, 720])
            let zoomed = evaluator.frame(at: 1.2)
            // In, over the screen, where it was: there is no cursor to follow.
            #expect(try #require(zoomed.stage?.depth) > 1.5)
            #expect(zoomed.cursor == nil)
            let center = try #require(zoomed.stage?.center), screen = try #require(evaluator.frame(at: 0.05).screen?.rect)
            #expect(center.x > screen.x && center.x < screen.x + screen.width && center.y > screen.y && center.y < screen.y + screen.height)
            #expect(evaluator.frame(at: 0.05).stage.map { $0.depth < 1.01 } ?? true)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func previewIsTheExportForARotatedTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await turnedTake(in: dir, first: [360, 640], transform: paintingTheCorners)
            var document = EditDocument.legacy(for: project)
            document.style.frame = .device(DeviceFrame(model: .iPhone, finish: .dark))
            document.style.screenSampling = .mipmapped
            document.zoom.regions = [StageDrawing.zoom(1, from: 1.2, to: 1.9, depth: 2, focus: .fixed(x: 0.5, y: 0.3))]
            let size = SIMD2(1280, 720)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let preview = PreviewRenderer(renderer: renderer)
            for t in [0.5, 1.3, 1.7] {
                let (exported, previewed) = try await offThePool { () -> ([UInt8], [UInt8]) in
                    var created: CVPixelBuffer?
                    let attributes = [
                        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
                    ] as CFDictionary
                    let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
                    guard status == kCVReturnSuccess, let pixelBuffer = created else { throw TestSupportError.failed("no pixel buffer") }
                    try renderer.render(at: t, into: pixelBuffer)
                    return (packedBytes(of: pixelBuffer), try preview.snapshot(at: t))
                }
                #expect(exported.count == size.x * size.y * 4)
                #expect(exported == previewed, "at \(t) s")
            }

            // Scrubbing shows the key frame of the turned segment fitted too.
            let track = try #require(project.take.track(deviceID))
            let reader = TrackFrameReader(package: project.package, track: track)
            let device = try #require(MTLCreateSystemDefaultDevice())
            let (width, height) = try await offThePool { () -> (Int, Int) in
                let decoder = try KeyFrameDecoder(device: device)
                let t = base.adding(seconds: 1.5)
                guard let media = reader.media(at: t), let frame = decoder.keyFrame(at: t, of: media) else {
                    throw TestSupportError.failed("no key frame")
                }
                return (frame.texture.width, frame.texture.height)
            }
            #expect(width == 360 && height == 640)
        }
    }
}
