// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
@testable import Export
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Synchronization
import SyntheticCapture
import Testing

// The export of an edited project (design §5.6, §7.9 and §10.1): the copy of the document it was given, every size of
// the export sheet, nothing of what was cut, its own frame grid, nothing written into a project, and a pipeline that
// draws ahead and gives the bytes of drawing one frame at a time, which are the preview's.

private let display2ID = "display-2"
private let cameraID = "camera"
private let display2Source = TrackSource(
    name: "Synthetic Display 2", displayID: 2, globalFrame: Rect(x: 640, y: 0, width: 480, height: 480), pixelScale: 1)
private let cameraSource = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// Clip `number` of the take over the source seconds `[from, to)` from `base`, at `speed`.
private func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: String(format: "c-%08x", number), take: takeID, start: at(from), end: at(to), speed: speed)
}

/// Cursor samples every 1/120 s for `seconds`, going back and forth across display 1 and down it.
private func cursorEvents(seconds: Double) -> [InputEvent] {
    (0..<Int(seconds * 120)).map { i in
        let phase = Double(i % 120) / 120
        let x = 40 + 560 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
        return InputEvent(t: at(Double(i) / 120), kind: .cursor(x: x, y: 60 + 60 * Double(i) / 120))
    }
}

/// A take of 4 s: display 1 (640 × 360 pt) and display 2 (480 × 480 pt), each with a segment, a 4:3 camera, the
/// microphone, the cursor moving and a click at 0.8 s.
private func twoScreenTake(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Edited")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 4)])
    try await builder.addVideoTrack(
        id: display2ID, source: display2Source, segments: [VideoSegmentSpec(start: base, seconds: 4, width: 480, height: 480)])
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource, segments: [VideoSegmentSpec(start: base, seconds: 4, width: 640, height: 480)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 4)])
    try builder.addEvents(cursorEvents(seconds: 4))
    try builder.addEvents([
        InputEvent(t: at(0.8), kind: .mouseDown(.left, x: 300, y: 150)), InputEvent(t: at(0.9), kind: .mouseUp(.left, x: 300, y: 150)),
    ])
    return try builder.write()
}

/// The edit of `twoScreenTake`: two clips with a cut between them, the second at 2× (2.25 s of output), a change to
/// display 2 inside it with the spring, the wallpaper, a shadow, the macOS window frame, a zoom block with a motion blur
/// of a whole frame, the smoothed cursor with its own and the ripples, and the camera.
private func edit(of project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.frameRate = 60
    document.sequence = [clip(1, from: 0, to: 1.5), clip(2, from: 2, to: 3.5, speed: 2)]
    document.screens.changes = [ScreenChange(id: "p-00000001", take: takeID, t: at(2.6), track: display2ID, origin: .user)]
    document.style.background = .wallpaper("aurora-1")
    document.style.shadow = 0.5
    document.style.frame = .macWindow(appearance: .dark, title: "Edited", buttons: true)
    document.style.geometryTransition = .spring
    document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
    document.cursor.motionBlur = 1
    document.cursor.clickEffect = "ripple-1"
    document.zoom.motionBlur = 1
    document.zoom.regions = [
        ZoomRegion(id: "z-00000001", take: takeID, start: at(0.3), end: at(1.3), origin: .user, depth: 2, focus: .follow, instant: false),
    ]
    document.camera.show = true
    return document
}

/// What a test's frame sink saw: each frame's index, the SHA-256 of its bytes, and the queue it was appended from;
/// the bytes of the frames in `keep`.
private final class SeenFrames: Sendable {
    struct Frame: Equatable, Sendable {
        var index: Int
        var hash: String
        var queue: String
    }

    private let keep: Set<Int>
    private let seen = Mutex<(frames: [Frame], bytes: [Int: [UInt8]])>(([], [:]))

    init(keeping keep: Set<Int> = []) {
        self.keep = keep
    }

    var frames: [Frame] { seen.withLock { $0.frames } }
    var bytes: [Int: [UInt8]] { seen.withLock { $0.bytes } }

    /// The sink to export with.
    var sink: MP4Exporter.FrameSink {
        { [self] index, pixelBuffer in
            let bytes = packedBytes(of: pixelBuffer)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let queue = String(cString: __dispatch_queue_get_label(nil))
            seen.withLock { seen in
                seen.frames.append(Frame(index: index, hash: hash, queue: queue))
                if keep.contains(index) { seen.bytes[index] = bytes }
            }
        }
    }
}

/// Exports `document` of `project` with `settings` to `dir/<name>.mp4`, its frames seen by `seen`; returns the MP4.
@discardableResult
private func export(
    _ project: LoadedProject, _ document: EditDocument, settings: ExportSettings, to dir: URL, name: String = "out",
    seen: SeenFrames? = nil
) async throws -> URL {
    let destination = dir.appending(path: "\(name).mp4")
    try await MP4Exporter(project: project, document: document, settings: settings, frameSink: seen?.sink)
        .export(to: destination) { _ in }
    return destination
}

/// The output seconds of frame `n` at `fps`.
private func frameSeconds(_ n: Int, _ fps: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: fps)) / 1e9 }

// MARK: - The document

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportUsesItsCopyOfTheDocument() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = [clip(1, from: 0, to: 1), clip(2, from: 1, to: 2), clip(3, from: 2, to: 3)]
        let exporter = MP4Exporter(
            project: project, document: document, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30))
        // Edited after the export was made: a clip deleted. The export keeps the document it was given.
        document.sequence.remove(at: 1)
        let destination = dir.appending(path: "out.mp4")
        try await exporter.export(to: destination) { _ in }
        let frames = try await readVideoFrames(of: destination, into: 0) { count, _ in count += 1 }
        #expect(frames == 90, "\(frames) frames for the 3 s of the copy")
        let video = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        #expect(abs(try await video.load(.timeRange).duration.seconds - 3) <= 1.0 / 30 + 1e-6)
    }
}

/// A take that recorded nothing (no segment of a screen, an audio track or the camera) has clips of no time: no document
/// of it exports, the legacy one or another, and nothing is written.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aTakeThatRecordedNothingIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        let recorded = try builder.write()
        // Its tracks without a segment, and no track at all.
        var noSegments = recorded
        noSegments.take.tracks = recorded.take.tracks.map { track in
            var track = track
            track.segments = []
            return track
        }
        var noTracks = recorded
        noTracks.take.tracks = []
        let destination = dir.appending(path: "out.mp4")
        for var project in [noSegments, noTracks] {
            project.events = []
            let legacy = EditDocument.legacy(for: project)
            #expect(TimeMap(sequence: legacy.sequence).duration == 0)
            var edited = legacy
            edited.audio.limiter = true  // not the legacy document, which a take without a screen exports
            for document in [legacy, edited] {
                await #expect(throws: ExportError.nothingToExport) {
                    try await MP4Exporter(
                        project: project, document: document, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30)
                    ).export(to: destination) { _ in }
                }
                await #expect(throws: ExportError.nothingToExport) {
                    try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try partialFiles(in: dir).isEmpty)
    }
}

// MARK: - Preview and export

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewSnapshotEqualsTheExportFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await twoScreenTake(in: dir)
        var document = edit(of: project)
        // The wallpaper's grain (±2 % a pixel) is noise H.264 smooths away at the export's bitrates: an 8 × 8 window of
        // the wallpaper alone decodes at an SSIM of about 0.88 (with the default padding, a frame at rest about 0.94). A
        // thin padding keeps the wallpaper in view, around the window and under the zoom, without it ruling the SSIM.
        document.style.padding = 0.01
        let size = SIMD2(640, 360)
        let last = TimeMap(sequence: document.sequence).frameCount(frameRate: 60) - 1
        #expect(last == 134)
        let compared = [0, 37, last]
        let seen = SeenFrames(keeping: Set(compared))
        let destination = try await export(
            project, document, settings: ExportSettings(outputSize: size, framesPerSecond: 60, quality: .high), to: dir, seen: seen)

        let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, document: document, outputSize: size))
        let snapshots = try await offThePool { try compared.map { try preview.snapshot(at: frameSeconds($0, 60)) } }
        let drawn = seen.bytes
        for (n, snapshot) in zip(compared, snapshots) {
            let exported = try #require(drawn[n], "frame \(n) was not drawn")
            #expect(snapshot == exported, "frame \(n): the preview's snapshot is the frame the export draws")
            let decoded = try await videoFrame(of: destination, nearest: frameSeconds(n, 60))
            #expect(abs(decoded.time - frameSeconds(n, 60)) < 0.001)
            let ssim = ssimLuma(decoded.bytes, exported, width: size.x, height: size.y)
            #expect(ssim >= 0.98, "frame \(n): SSIM \(ssim)")
        }
        // What was compared is the edit: the change of screen and the zoom are drawn.
        let evaluator = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
        #expect(evaluator.frame(at: frameSeconds(37, 60)).subframes.count > 1, "frame 37 is blurred by the moving zoom")
        #expect(evaluator.frame(at: frameSeconds(last, 60)).screen?.trackID == display2ID)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func pipelinedExportGivesTheSameFramesAsSerial() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await twoScreenTake(in: dir)
        let document = edit(of: project)
        var serial = ExportSettings(outputSize: [480, 270], framesPerSecond: 60)
        serial.framesInFlight = 1
        let pipelined = ExportSettings(outputSize: [480, 270], framesPerSecond: 60)
        #expect(pipelined.framesInFlight == 3)
        let one = SeenFrames(), three = SeenFrames()
        try await export(project, document, settings: serial, to: dir, name: "serial", seen: one)
        try await export(project, document, settings: pipelined, to: dir, name: "pipelined", seen: three)

        let count = TimeMap(sequence: document.sequence).frameCount(frameRate: 60)
        #expect(three.frames.map(\.index) == Array(0..<count), "every frame, in frame order")
        #expect(three.frames == one.frames, "the bytes of drawing one frame at a time")
        #expect(Set(three.frames.map(\.queue)) == [MP4Exporter.queueLabel], "every frame appended from the export's queue")
        #expect(Set(one.frames.map(\.hash)).count > count / 2, "the frames move")
    }
}

/// The frame rate of the export is the renderer's: its motion blur's shutter is a fraction of the export's frame.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportDrawsWithItsOwnFrameRate() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await twoScreenTake(in: dir)
        let document = edit(of: project)
        let size = SIMD2(480, 270)
        // 0.5 s: frame 15 at 30 fps, 30 at 60, while the zoom camera moves.
        let at30 = SeenFrames(keeping: [15]), at60 = SeenFrames(keeping: [30])
        for (rate, seen) in [(30, at30), (60, at60)] {
            try await export(project, document, settings: ExportSettings(outputSize: size, framesPerSecond: rate), to: dir, name: "\(rate)", seen: seen)
        }
        let drawn = try await offThePool {
            try [30, 60].map { rate in
                try FrameRenderer(project: project, document: document, outputSize: size, frameRate: rate).renderBytes(at: 0.5)
            }
        }
        #expect(drawn[0] != drawn[1], "the shutter differs at 30 and at 60 fps")
        #expect(at30.bytes[15] == drawn[0], "exported at 30 fps, frame 15 is drawn with a 30 fps shutter")
        #expect(at60.bytes[30] == drawn[1], "exported at 60 fps, frame 30 is drawn with a 60 fps shutter")
    }
}

// MARK: - Sizes and frame rates

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func everyExportSizeEncodes() async throws {
    try await withTemporaryDirectory { dir in
        for aspect in [Aspect.landscape, .portrait, .square] {
            for resolution in ExportResolution.allCases {
                let settings = ExportSettings(aspect: aspect, resolution: resolution, framesPerSecond: 60, quality: .high)
                let video = MP4Exporter.videoSettings(settings)
                #expect(video[AVVideoEncoderSpecificationKey] == nil, "no encoder is required")
                let url = dir.appending(path: "\(aspect.rawValue.replacingOccurrences(of: ":", with: "x"))-\(resolution.rawValue).mp4")
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: video)
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: settings.outputSize.x,
                    kCVPixelBufferHeightKey as String: settings.outputSize.y,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
                writer.add(input)
                #expect(writer.startWriting(), "\(settings.outputSize)")
                writer.startSession(atSourceTime: .zero)
                let pool = try #require(adaptor.pixelBufferPool)
                for frame in 0..<12 {
                    var created: CVPixelBuffer?
                    #expect(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess)
                    let pixelBuffer = try #require(created)
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0, CVPixelBufferGetDataSize(pixelBuffer))  // black
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                    #expect(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 60)))
                }
                input.markAsFinished()
                await writer.finishWriting()
                #expect(writer.status == .completed, "\(settings.outputSize): \(String(describing: writer.error))")
                let decoded = try await readVideoFrames(of: url, into: [SIMD2<Int>]()) { $0.append(SIMD2($1.width, $1.height)) }
                #expect(decoded == Array(repeating: settings.outputSize, count: 12), "\(settings.outputSize)")
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func otherFrameRateUsesItsOwnGrid() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        #expect(document.frameRate == 60)
        // 1.9 s of output: 114 frames at 60 fps, 57 at 30.
        document.sequence = [clip(1, from: 0, to: 0.7), clip(2, from: 1.5, to: 2.7)]
        let seen = SeenFrames()
        let destination = try await export(
            project, document, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30), to: dir, seen: seen)
        #expect(seen.frames.map(\.index) == Array(0..<57))
        let times = try await readVideoFrames(of: destination, into: [Double]()) { $0.append($1.time) }
        #expect(times.count == 57)
        #expect(times.enumerated().allSatisfy { abs($0.element - Double($0.offset) / 30) < 1e-6 }, "\(times)")
    }
}

// MARK: - What is cut

/// `sample` painted pure red when it is one of the frames of the second second (30 to 59 at 30 fps).
@Sendable private func paintingTheSecondSecondRed(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard (30..<60).contains(frameIndex) else { return sample }
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFFFF_0000, count: width)  // BGRA (0, 0, 255, 255)
    }
    return sample
}

/// How many pixels of packed BGRA `bytes` are red.
private func redPixels(_ bytes: [UInt8]) -> Int {
    stride(from: 0, to: bytes.count, by: 4).count { bytes[$0 + 2] > 200 && bytes[$0 + 1] < 60 && bytes[$0] < 60 }
}

/// How much of `samples` (48 kHz) is a sine of `frequency` Hz at any phase: 1 for that sine alone, near 0 for anything
/// orthogonal to it.
private func correlation(_ samples: [Float], frequency: Double) -> Double {
    var s = 0.0, c = 0.0, energy = 0.0
    for (n, x) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(n) / 48_000
        s += Double(x) * sin(phase)
        c += Double(x) * cos(phase)
        energy += Double(x) * Double(x)
    }
    return (s * s + c * c).squareRoot() / (energy * Double(samples.count) / 2).squareRoot()
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func nothingCutReachesTheExport() async throws {
    try await withTemporaryDirectory { dir in
        // The second second, cut, is the only one red, the only one with a 1 kHz tone and the only one with a click.
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: displayID, source: displaySource,
            segments: [VideoSegmentSpec(start: base, seconds: 3, transform: paintingTheSecondSecondRed)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [
            AudioSegmentSpec(start: base, seconds: 1), AudioSegmentSpec(start: at(1), seconds: 1, frequency: 1000),
            AudioSegmentSpec(start: at(2), seconds: 1),
        ])
        try builder.addEvents(cursorEvents(seconds: 3))
        try builder.addEvents([
            InputEvent(t: at(1.5), kind: .mouseDown(.left, x: 300, y: 150)), InputEvent(t: at(1.6), kind: .mouseUp(.left, x: 300, y: 150)),
        ])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.sequence = [clip(1, from: 0, to: 1), clip(2, from: 2, to: 3)]
        document.cursor.clickEffect = "ripple-1"
        document.cursor.clickSound = "soft-1"
        var withoutClicks = document
        withoutClicks.cursor.clickEffect = "none"
        withoutClicks.cursor.clickSound = "none"
        let settings = ExportSettings(outputSize: [480, 270], framesPerSecond: 30)

        let seen = SeenFrames(), plain = SeenFrames()
        let destination = try await export(project, document, settings: settings, to: dir, seen: seen)
        try await export(project, withoutClicks, settings: settings, to: dir, name: "plain", seen: plain)
        // No red frame.
        let red = try await readVideoFrames(of: destination, into: [Int]()) { red, frame in
            if redPixels(frame.bytes) > 0 { red.append(Int((frame.time * 30).rounded())) }
        }
        #expect(red.isEmpty, "red in frames \(red)")
        let uncut = try await offThePool { redPixels(try FrameRenderer(project: project, outputSize: [480, 270]).renderBytes(at: 1.5)) }
        #expect(uncut > 1000, "uncut, the second second is red")
        // No 1 kHz.
        let (_, samples) = try await decodedAudio(of: destination)
        #expect(samples.count > 48_000)
        let tone = correlation(samples, frequency: 1000)
        #expect(tone < 0.01, "correlation with 1 kHz: \(tone)")
        // No effect and no sound of the click: the same frames and the same mix as without click effects or sounds.
        #expect(seen.frames.map(\.hash) == plain.frames.map(\.hash))
        let mixed = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)
        let silent = try await MP4Exporter.mixSamples(of: project, document: withoutClicks, framesPerSecond: 30)
        #expect(mixed.map(\.bitPattern) == silent.map(\.bitPattern))
    }
}

// MARK: - Projects of versions 1 and 2

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportingALegacyPackageWritesNothingInIt() async throws {
    try await withTemporaryDirectory { dir in
        for name in ["phaseZero", "windowMoving"] {
            let project = try await GoldenProjects.make(name, in: dir)
            #expect(project.manifest.formatVersion == (name == "phaseZero" ? 1 : 2))
            let before = try treeHash(project.package.url)
            let settings = ExportSettings(aspect: .landscape, resolution: .p720, framesPerSecond: 30, quality: .high)
            let destination = dir.appending(path: "\(name).mp4")
            try await MP4Exporter(project: project, settings: settings).export(to: destination) { _ in }
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(try treeHash(project.package.url) == before, "\(name): nothing written into the package")
            let names = try FileManager.default.contentsOfDirectory(atPath: project.package.url.path)
            #expect(!names.contains("edit.lock") && !names.contains("edit.json") && !names.contains("edit-log.jsonl"), "\(names)")
        }
    }
}

// MARK: - The renderer's pipeline

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess)
    return try #require(created)
}

/// What `FrameRenderer.render(at:into:completion:)` called its completion with, and how many times.
private final class Completions: Sendable {
    private let errors = Mutex<[String?]>([])
    var calls: [String?] { errors.withLock { $0 } }

    func handler(_ done: @escaping @Sendable () -> Void) -> @Sendable ((any Error)?) -> Void {
        { [self] error in
            errors.withLock { $0.append(error.map { String(describing: $0) }) }
            done()
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func queuedFramesAreTheFramesDrawnNowAndFailOnce() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await twoScreenTake(in: dir)
        let document = edit(of: project)
        let size = SIMD2(320, 180)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 60)
        #expect(renderer.frameRate == 60)
        // Ten frames of the grid, then one off it, then one too small to draw into: queued, each completed once.
        let times = (40..<50).map { frameSeconds($0, 60) } + [1.234_567, frameSeconds(60, 60)]
        let buffers = try times.indices.map { try makePixelBuffer(width: $0 == times.count - 1 ? 160 : size.x, height: size.y) }
        let completions = Completions()
        let done = DispatchSemaphore(value: 0)
        for (time, buffer) in zip(times, buffers) {
            renderer.render(at: time, into: buffer, completion: completions.handler { done.signal() })
        }
        try await offThePool { for _ in times { done.wait() } }
        let calls = completions.calls
        #expect(calls.count == times.count)
        #expect(calls.dropLast().allSatisfy { $0 == nil }, "\(calls)")
        #expect(calls.last??.contains("targetSizeMismatch") == true, "\(String(describing: calls.last))")
        // The bytes drawn are those drawn frame by frame, decoding as it draws.
        let direct = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 60)
        let expected = try await offThePool { try times.dropLast().map { try direct.renderBytes(at: $0) } }
        for (index, bytes) in expected.enumerated() {
            #expect(packedBytes(of: buffers[index]) == bytes, "at \(times[index]) s")
        }
    }
}

/// A take of one 2 s segment of display 1, at 30 fps, in the package `name`, and its reader.
private func readerOfOneSegment(in dir: URL, name: String = "Fixture") async throws -> TrackFrameReader {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 2)])
    let project = try builder.write()
    return TrackFrameReader(package: project.package, track: try #require(project.take.track(displayID)))
}

/// Waits until `prefetcher` holds `decoded` frames decoded, or 10 s.
private func waitUntil(_ prefetcher: FramePrefetcher, decoded: Int) async throws {
    let deadline = Date().addingTimeInterval(10)
    while prefetcher.pending.decoded < decoded, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func prefetcherDecodesAheadWithinItsBounds() async throws {
    try await withTemporaryDirectory { dir in
        let device = try #require(MTLCreateSystemDefaultDevice())
        let times = (0..<20).map { at(Double($0) / 30) }
        // Eight frames ahead at most.
        let prefetcher = try FramePrefetcher(reader: try await readerOfOneSegment(in: dir), device: device)
        for time in times { prefetcher.schedule(time) }
        try await waitUntil(prefetcher, decoded: 8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(prefetcher.pending == (scheduled: 20, decoded: 8))
        for (k, time) in times.prefix(3).enumerated() {
            let frame = try #require(try await prefetcher.frame(atSource: time))
            #expect(frameIndex(of: frame.pixelBuffer) == k)
        }
        try await waitUntil(prefetcher, decoded: 8)
        #expect(prefetcher.pending == (scheduled: 17, decoded: 8))
        // Skipped instants go; one not scheduled starts again from it.
        #expect(frameIndex(of: try #require(try await prefetcher.frame(atSource: times[10])).pixelBuffer) == 10)
        #expect(prefetcher.pending.scheduled == 9)
        #expect(frameIndex(of: try #require(try await prefetcher.frame(atSource: at(1.5))).pixelBuffer) == 45)
        #expect(prefetcher.pending.scheduled == 0)

        // And no more than its bytes: room for three frames of 640 × 360 and a half (rows may be padded a little).
        let bytes = 640 * 4 * 360
        let small = try FramePrefetcher(
            reader: try await readerOfOneSegment(in: dir, name: "Small"), device: device, maxBytes: 3 * bytes + bytes / 2)
        for time in times { small.schedule(time) }
        try await waitUntil(small, decoded: 3)
        try await Task.sleep(for: .milliseconds(200))
        #expect(small.pending == (scheduled: 20, decoded: 3))
        #expect(frameIndex(of: try #require(try await small.frame(atSource: times[0])).pixelBuffer) == 0)
        try await waitUntil(small, decoded: 3)
        #expect(small.pending == (scheduled: 19, decoded: 3))
    }
}

@MainActor
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func stuckTrackLoadNeverReachesTheCaller() async throws {
    try await withTemporaryDirectory { dir in
        let reader = try await readerOfOneSegment(in: dir)
        let loading = DispatchSemaphore(value: 0)
        reader.trackLoader = { @Sendable asset in
            _ = loading.wait(timeout: .now() + 60)  // the load hangs until the test lets it go on
            return TrackFrameReader.loadFirstVideoTrack(of: asset)
        }
        defer { loading.signal() }  // never left hanging, even if the test stops early
        let prefetcher = try FramePrefetcher(reader: reader, device: try #require(MTLCreateSystemDefaultDevice()))
        let asked = Date()
        let frame = Task { try await prefetcher.frame(atSource: at(0.5)) }
        // The main thread goes on while the load hangs (it would for 60 s).
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(Date().timeIntervalSince(asked) < 10)
        #expect(prefetcher.pending == (scheduled: 1, decoded: 0), "still loading")
        loading.signal()
        #expect(frameIndex(of: try #require(try await frame.value).pixelBuffer) == 15)
    }
}

/// The palette index of a decoded frame, read near its bottom-right corner, away from the moving white square.
private func frameIndex(of pixelBuffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let x = CVPixelBufferGetWidth(pixelBuffer) - 8
    let y = CVPixelBufferGetHeight(pixelBuffer) - 8
    let p = CVPixelBufferGetBaseAddress(pixelBuffer)!
        .advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4)
        .assumingMemoryBound(to: UInt8.self)
    return SampleFactory.frameIndex(nearestTo: SIMD4(p[0], p[1], p[2], p[3]))
}
