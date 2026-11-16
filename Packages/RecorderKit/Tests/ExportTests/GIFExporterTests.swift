// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import Testing

// The GIF export (1c design §7.2 and §7.4, gifQuant-1): the project's frames drawn by the renderer the MP4 uses, at their
// times, quantized and composed by the GIF's own pieces, written whole or not at all, and the same bytes every time.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// Cursor samples every 1/120 s for `seconds`, going back and forth across display 1 and down it.
private func cursorEvents(seconds: Double) -> [InputEvent] {
    (0..<Int(seconds * 120)).map { i in
        let phase = Double(i % 120) / 120
        let x = 40 + 560 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
        return InputEvent(t: at(Double(i) / 120), kind: .cursor(x: x, y: 60 + 60 * Double(i) / 120))
    }
}

/// A take of `seconds` of display 1 (640 × 360 at 30 fps, a moving square over a colour of its frame) with the cursor
/// moving.
private func movingTake(in dir: URL, seconds: Double = 2) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "GIF")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: seconds)])
    try builder.addEvents(cursorEvents(seconds: seconds))
    return try builder.write()
}

/// A take of `seconds` of display 1 whose every frame is noise.
private func noisyTake(in dir: URL, seconds: Double = 1) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Noise")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [
        VideoSegmentSpec(start: base, seconds: seconds) { index, sample in
            noiseVideoSample(width: 640, height: 360, pts: sample.presentationTimeStamp, seed: UInt64(index + 1))
        },
    ])
    return try builder.write()
}

/// The take's edit at 60 fps on the aurora wallpaper (gradients that the dither works on), with the smoothed cursor.
private func edit(of project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.frameRate = 60
    document.style.background = .wallpaper("aurora-1")
    document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
    return document
}

private func whole(_ document: EditDocument) -> ExportRange { .whole(TimeMap(sequence: document.sequence)) }

/// Runs `body` on a thread of its own: drawing decodes, which blocks in `copyNextSampleBuffer`, and many tests blocking
/// Swift's cooperative pool at once hang the run.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// The canvas a viewer shows at each of the `count` frames of a GIF at `fps`: its images (`GIFTestDecoder.frames`), each
/// for as many frames as its delay covers, since the composer folds a frame that changes nothing into the one before.
private func canvasesByFrame(_ data: Data, count: Int, fps: Int) -> [[SIMD3<UInt8>]] {
    let delays = GIFDelays.delays(frameCount: count, fps: fps)
    var canvases: [[SIMD3<UInt8>]] = []
    for (canvas, delay) in GIFTestDecoder.frames(data) {
        var covered = 0
        while covered < delay, canvases.count < count {
            covered += delays[canvases.count]
            canvases.append(canvas)
        }
        #expect(covered == delay, "an image's delay is the sum of the delays of the frames it shows")
    }
    return canvases
}

/// The canvas of each frame of `range` as gifQuant-1 makes it, worked out here one frame at a time: the frame
/// `FrameRenderer.renderBytes` draws at `range.frameTime(n, fps:)` at the GIF's size (with the motion blur's shutter of a
/// frame at `renderFrameRate`, the document's when `nil`), its histogram counted on the CPU, and the GPU's mapping with
/// the previous frame's palette while `PaletteBuilder.shouldReuse` says so, or else with a new one built from it; each
/// pixel the colour of its index. With each frame, whether its palette is new.
private func referenceFrames(
    _ project: LoadedProject, _ document: EditDocument, settings: GIFSettings, range: ExportRange, renderFrameRate: Int? = nil
) async throws -> [(canvas: [SIMD3<UInt8>], newPalette: Bool)] {
    try await offThePool {
        let size = settings.outputSize(aspect: document.aspect)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: renderFrameRate)
        let device = renderer.device
        let quantizer = try GIFQuantizer(device: device)
        let queue = try #require(device.makeCommandQueue())
        let dither = settings.dither ? settings.quality.ditherStrength : 0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        func mapped(to palette: GIFPalette) throws -> MapPass {
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let pass = try quantizer.map(texture, palette: palette, dither: dither, into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            try #require(commandBuffer.status == .completed)
            return pass
        }
        var previous: GIFPalette?
        var frames: [(canvas: [SIMD3<UInt8>], newPalette: Bool)] = []
        for n in 0..<range.frameCount(fps: settings.fps) {
            let bytes = try renderer.renderBytes(at: Double(range.frameTime(n, fps: settings.fps)) / 1e9)
            bytes.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size.x * 4)
            }
            var palette: GIFPalette
            var pass: MapPass
            var built = false
            if let previous, case let reused = try mapped(to: previous),
                PaletteBuilder.shouldReuse(reused.error(), quality: settings.quality) {
                (palette, pass) = (previous, reused)
            } else {
                let histogram = bytes.withUnsafeBytes {
                    ColorHistogram(bgra: $0, width: size.x, height: size.y, bytesPerRow: size.x * 4)
                }
                palette = PaletteBuilder.build(histogram, quality: settings.quality)
                pass = try mapped(to: palette)
                built = true
            }
            frames.append((pass.indices().map { palette.colors[Int($0)] }, built))
            previous = palette
        }
        return frames
    }
}

/// Fills the volume at `folder` with a file named `filler` until about `leaving` bytes are free.
private func fill(_ folder: URL, leaving: Int) throws {
    var info = statfs()
    try #require(statfs(folder.path, &info) == 0)
    var remaining = Int(info.f_bavail) * Int(info.f_bsize) - leaving
    let fd = open(folder.appending(path: "filler").path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    try #require(fd >= 0)
    defer { close(fd) }
    let chunk = [UInt8](repeating: 0x2A, count: 1 << 20)
    while remaining > 0 {
        let count = min(remaining, chunk.count)
        let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, count) }
        guard written > 0 else { break }
        remaining -= written
    }
    fsync(fd)
}

@Suite struct GIFExporterTests {
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func twoExportsGiveTheSameBytes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir)
            let document = edit(of: project)
            let settings = GIFSettings(longSide: 480, range: whole(document))
            let exporter = GIFExporter(project: project, document: document, settings: settings)
            let first = try await exporter.export(to: dir.appending(path: "first.gif")) { _ in }
            let second = try await exporter.export(to: dir.appending(path: "second.gif")) { _ in }
            let bytes = try Data(contentsOf: dir.appending(path: "first.gif"))
            #expect(bytes == (try Data(contentsOf: dir.appending(path: "second.gif"))), "gifQuant-1 is deterministic")
            #expect(first == second)
            #expect(first.frames == 30 && first.bytes == Int64(bytes.count))
            #expect(try await exporter.encodeInMemory(range: settings.range) == bytes, "in memory, the same GIF")
            let images = GIFTestDecoder.frames(bytes)
            #expect(images.count == first.writtenFrames && images.count > 1)
            #expect(images.map(\.delay).reduce(0, +) == 200, "the delays add up to the 2 s")
            #expect(try partialFiles(in: dir).isEmpty)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func framesAreTheProjectFramesAtTheirTimes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir)
            let document = edit(of: project)
            // Between marks that are not on the GIF's grid: frame n at 0.25 s + round(n / 15 × 10⁹) ns, those before 1.75 s.
            let range = ExportRange(start: 250_000_000, end: 1_750_000_000)
            #expect(range.frameCount(fps: 15) == 23)
            #expect(range.frameTime(1, fps: 15) == 316_666_667)
            let settings = GIFSettings(longSide: 480, range: range)
            #expect(settings.outputSize(aspect: document.aspect) == [480, 270])
            let destination = dir.appending(path: "range.gif")
            let palettes = Mutex<[Bool]>([])
            let summary = try await GIFExporter(project: project, document: document, settings: settings) { _, _, isNew in
                palettes.withLock { $0.append(isNew) }
            }.export(to: destination) { _ in }
            #expect(summary.frames == 23)
            let shown = canvasesByFrame(try Data(contentsOf: destination), count: 23, fps: 15)
            let expected = try await referenceFrames(project, document, settings: settings, range: range)
            #expect(shown.count == 23)
            for n in 0..<min(shown.count, expected.count) {
                #expect(shown[n] == expected[n].canvas, "frame \(n) is the project's frame at its time, quantized")
            }
            #expect(Set(expected.map { $0.canvas.hashValue }).count > 10, "the frames move")
            // Both ways of step 3 are taken, as the reference takes them: a palette kept, and one built again later on;
            // and a new palette right after another, which the export built ahead, alongside the frame before.
            let newPalettes = expected.map(\.newPalette)
            #expect(palettes.withLock { $0 } == newPalettes)
            #expect(newPalettes.contains(false) && newPalettes.dropFirst().contains(true), "\(newPalettes)")
            #expect(zip(newPalettes, newPalettes.dropFirst()).contains { $0 && $1 }, "\(newPalettes)")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func blurShutterIsAProjectFrame() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir)
            var document = edit(of: project)
            document.cursor.motionBlur = 0.5
            document.zoom.motionBlur = 0.5
            document.zoom.regions = [
                ZoomRegion(id: "z-00000001", take: takeID, start: at(0.2), end: at(1.4), origin: .user, depth: 2, focus: .follow, instant: false),
            ]
            let range = ExportRange(start: 0, end: 1_000_000_000)
            let settings = GIFSettings(longSide: 480, range: range)
            let data = try await GIFExporter(project: project, document: document, settings: settings).encodeInMemory(range: range)
            let shown = canvasesByFrame(data, count: 15, fps: 15)
            let projectShutter = try await referenceFrames(project, document, settings: settings, range: range).map(\.canvas)
            let gifShutter = try await referenceFrames(project, document, settings: settings, range: range, renderFrameRate: 15)
                .map(\.canvas)
            #expect(shown == projectShutter, "every frame is drawn with the shutter of a frame of the project, 1/60 s × 0.5")
            #expect(shown != gifShutter, "and not with one of a frame of the GIF, 1/15 s × 0.5")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func cancelLeavesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir)
            let document = edit(of: project)
            let destination = dir.appending(path: "out.gif")
            let progress = Mutex<[Double]>([])
            let exporter = GIFExporter(project: project, document: document, settings: GIFSettings(longSide: 480, range: whole(document)))
            await #expect(throws: GIFExportError.cancelled) {
                try await exporter.export(to: destination) { value in
                    progress.withLock { $0.append(value) }
                    // A third of the way in, the task running the export (the one calling this) is cancelled.
                    if value > 1.0 / 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try partialFiles(in: dir).isEmpty)
            let values = progress.withLock { $0 }
            #expect(values.contains { $0 > 1.0 / 3 } && values.allSatisfy { $0 < 0.6 }, "\(values)")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func stalePartialIsRemovedByTheNextExport() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 1)
            let document = edit(of: project)
            let destination = dir.appending(path: "out.gif")
            let stale = URL(fileURLWithPath: destination.path + ".partial.gif")
            try Data("left by an export that was killed".utf8).write(to: stale)
            let progress = Mutex<[Double]>([])
            let summary = try await GIFExporter(project: project, document: document, settings: GIFSettings(longSide: 480, range: whole(document)))
                .export(to: destination) { value in progress.withLock { $0.append(value) } }
            #expect(try partialFiles(in: dir).isEmpty)
            let data = try Data(contentsOf: destination)
            #expect(data.prefix(6) == Data("GIF89a".utf8))
            #expect(GIFTestDecoder.frames(data).count == summary.writtenFrames)
            let values = progress.withLock { $0 }
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } && values.last == 1, "\(values)")
            #expect(values.dropLast().allSatisfy { $0 < 1 })
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func diskFullRemovesThePartial() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await noisyTake(in: dir)
            let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .hfsPlus, in: dir)
            defer { try? disk.detach(force: true) }
            let folder = disk.mountPoint.appending(path: "Exports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            // Room for the header and a frame or two of noise, not for 15.
            try fill(disk.mountPoint, leaving: 256 << 10)
            var document = EditDocument.legacy(for: project)
            document.style.padding = 0
            let exporter = GIFExporter(project: project, document: document, settings: GIFSettings(longSide: 480, range: whole(document)))
            await #expect(throws: GIFExportError.diskFull) {
                try await exporter.export(to: folder.appending(path: "noise.gif")) { _ in }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "nothing in the folder")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func oneFrameRangeWritesOneFrame() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 1)
            let document = edit(of: project)
            // (end − start) × fps = 1 000 000 005 ns: one frame, the next one (at 66 666 667 ns) is not before the end.
            let range = ExportRange(start: 500_000_000, end: 566_666_667)
            #expect(range.frameCount(fps: 15) == 1)
            let destination = dir.appending(path: "one.gif")
            let summary = try await GIFExporter(project: project, document: document, settings: GIFSettings(longSide: 480, range: range))
                .export(to: destination) { _ in }
            #expect(summary.frames == 1 && summary.writtenFrames == 1)
            let images = GIFTestDecoder.frames(try Data(contentsOf: destination))
            #expect(images.count == 1)
            #expect(images.first?.delay == 7, "round(100 / 15)")
        }
    }

    @Test func rangeShorterThanAFrameIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await movingTake(in: dir, seconds: 1)
            let document = edit(of: project)
            let short = ExportRange(start: 0, end: 10_000_000)
            #expect(short.frameCount(fps: 15) == 1, "a frame falls before its end, but it lasts less than one")
            let exporter = GIFExporter(project: project, document: document, settings: GIFSettings(range: short))
            let destination = dir.appending(path: "short.gif")
            await #expect(throws: GIFExportError.rangeShorterThanAFrame) { try await exporter.export(to: destination) { _ in } }
            await #expect(throws: GIFExportError.rangeShorterThanAFrame) { try await exporter.encodeInMemory(range: short) }
            // One nanosecond short of a frame at 15 fps, and an empty range.
            for range in [ExportRange(start: 0, end: 66_666_666), ExportRange(start: 400_000_000, end: 400_000_000)] {
                await #expect(throws: GIFExportError.rangeShorterThanAFrame) { try await exporter.encodeInMemory(range: range) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".gif") }.isEmpty)
            // Nor is a GIF ever written into a project, as an MP4 is not.
            let packageFiles = try snapshot(of: project.package.url)
            let inside = GIFExporter(project: project, document: document, settings: GIFSettings(range: whole(document)))
            await #expect(throws: ExportError.destinationNotAllowed) {
                try await inside.export(to: project.package.url.appending(path: "inside.gif")) { _ in }
            }
            #expect(try snapshot(of: project.package.url) == packageFiles)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
    func noisyCameraRefreshesThePaletteWithinBounds() async throws {
        try await withTemporaryDirectory { dir in
            // The full-screen camera with noise in every frame: until the render draws the camera layouts (Tasks 10 and
            // 11), a screen of noise filling the output gives the palette the same pixels.
            let project = try await noisyTake(in: dir)
            var document = EditDocument.legacy(for: project)
            document.style.padding = 0
            document.style.cornerRadius = 0
            let palettes = Mutex<[(frame: Int, colors: Int, isNew: Bool)]>([])
            let exporter = GIFExporter(
                project: project, document: document, settings: GIFSettings(longSide: 480, range: whole(document))
            ) { frame, palette, isNew in
                palettes.withLock { $0.append((frame, palette.colors.count, isNew)) }
            }
            let destination = dir.appending(path: "noise.gif")
            let summary = try await exporter.export(to: destination) { _ in }
            let seen = palettes.withLock { $0 }
            #expect(seen.map(\.frame) == Array(0..<15), "one palette per frame, in order")
            #expect(seen.allSatisfy { $0.isNew }, "noise never fits the previous palette")
            #expect(seen.allSatisfy { (1...255).contains($0.colors) }, "\(seen.map(\.colors))")
            let images = GIFTestDecoder.frames(try Data(contentsOf: destination))
            #expect(images.count == 15 && summary.writtenFrames == 15)
            #expect(images.map(\.delay).reduce(0, +) == 100)
        }
    }

    @Test func oddSizesAreEven() {
        let range = ExportRange(start: 0, end: 1_000_000_000)
        #expect(GIFSettings(longSide: 1080, range: range).outputSize(aspect: .portrait) == [608, 1080])
        #expect(GIFSettings(longSide: 480, range: range).outputSize(aspect: .square) == [480, 480])
        #expect(GIFSettings(longSide: 800, range: range).outputSize(aspect: .landscape) == [800, 450])
        for longSide in GIFSettings.longSides {
            for aspect in [Aspect.landscape, .portrait, .square] {
                let size = GIFSettings(longSide: longSide, range: range).outputSize(aspect: aspect)
                #expect(size.x % 2 == 0 && size.y % 2 == 0 && max(size.x, size.y) == longSide, "\(longSide) \(aspect)")
            }
        }
        let settings = GIFSettings(range: range)
        #expect(settings.longSide == 800 && settings.fps == 15 && settings.quality == .balanced && settings.dither && settings.loops)
        #expect(GIFSettings.framesPerSecond == [10, 15, 20, 25, 30])
        #expect(ExportRange.whole(TimeMap(sequence: [])) == ExportRange(start: 0, end: 0))
    }
}
