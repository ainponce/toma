// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Metal
import ProjectFormat
import Render
import Synchronization
import os

/// The options of a GIF export (1c design §7.1, plan decision 21): parameters of the export, never edits of the document.
public struct GIFSettings: Equatable, Sendable {
    /// The longer side of the GIF, in pixels, as the export sheet offers it.
    public static let longSides = [480, 640, 800, 1080, 1280, 1920]
    /// The frames per second the sheet offers: each a whole number of steps of the 600 Hz grid, and at least 2
    /// hundredths of a second apart, the shortest delay browsers honour.
    public static let framesPerSecond = [10, 15, 20, 25, 30]

    public var longSide: Int
    public var fps: Int
    public var quality: GIFQuality
    /// The ordered dither, at the quality's strength; without it, each pixel takes the nearest colour.
    public var dither: Bool
    /// Plays in a loop forever (the NETSCAPE2.0 extension); otherwise once.
    public var loops: Bool
    /// What `GIFExporter.export(to:progress:)` draws.
    public var range: ExportRange

    public init(
        longSide: Int = 800, fps: Int = 15, quality: GIFQuality = .balanced, dither: Bool = true, loops: Bool = true,
        range: ExportRange
    ) {
        self.longSide = longSide
        self.fps = fps
        self.quality = quality
        self.dither = dither
        self.loops = loops
        self.range = range
    }

    /// The GIF's size for a document of `aspect`: `longSide` on the longer side and the shorter one in proportion,
    /// rounded to an even number of pixels (1080 in 9:16 is 608 × 1080); a square's sides are both `longSide`.
    ///
    /// The other aspects: 4:5, 4:3 and 3:4 have `longSide` on the longer side and the other in proportion; `auto` is the
    /// same from `contentRatio` (16:9 without it), of the take of the document's first clip (phase 3 design §9,
    /// `StageLayout.contentRatio(project:document:)`: the project's own without clips; none for a take the package does
    /// not have), the rule the preview and the MP4 size by too.
    public func outputSize(project: LoadedProject, document: EditDocument) -> SIMD2<Int> {
        outputSize(aspect: document.aspect, contentRatio: StageLayout.contentRatio(project: project, document: document))
    }

    public func outputSize(aspect: Aspect, contentRatio: Double? = nil) -> SIMD2<Int> {
        let shortSide = max(2, Int((Double(longSide) * 9 / 16 / 2).rounded()) * 2)
        switch aspect {
        case .landscape: return SIMD2(longSide, shortSide)
        case .portrait: return SIMD2(shortSide, longSide)
        case .square: return SIMD2(longSide, longSide)
        case .fourByFive, .fourByThree, .threeByFour, .auto:
            let ratio = aspect.ratio(contentRatio: contentRatio)
            let wide = ratio >= 1
            let other = max(2, Int((Double(longSide) * (wide ? 1 / ratio : ratio) / 2).rounded()) * 2)
            return wide ? SIMD2(longSide, other) : SIMD2(other, longSide)
        }
    }

    /// The dither's strength the mapping gets: the quality's, or 0 without dither.
    var ditherStrength: Float { dither ? quality.ditherStrength : 0 }
}

public enum GIFExportError: Error, Equatable, Sendable {
    /// The task running the export was cancelled. Nothing was left behind.
    case cancelled
    /// The range lasts less than a frame at the GIF's frames per second (`(end − start) × fps < 10⁹` ns). Nothing was
    /// written.
    case rangeShorterThanAFrame
    /// The disk is full (`ENOSPC`, or the user's quota, `EDQUOT`). The partial file was removed.
    case diskFull
    /// Writing the GIF failed with this error. The partial file was removed.
    case write(POSIXErrorCode)
}

/// What an export wrote.
public struct GIFExportSummary: Equatable, Sendable {
    /// The size of the GIF.
    public var bytes: Int64
    /// The frames of the range, each drawn.
    public var frames: Int
    /// The images in the GIF: a frame that changes nothing is not written (its delay goes to the image before it), and a
    /// delay too long for one image is carried by a one-pixel transparent one (`GIFComposer`).
    public var writtenFrames: Int

    public init(bytes: Int64, frames: Int, writtenFrames: Int) {
        self.bytes = bytes
        self.frames = frames
        self.writtenFrames = writtenFrames
    }
}

/// Exports a range of an edited take as an animated GIF with Toma's own encoder, gifQuant-1 (1c design §7.2).
///
/// Frame `n` is what `FrameRenderer` draws of the document at `range.frameTime(n, fps:)`, at the GIF's size: the drawing
/// the preview and the MP4 show, with the motion blur's shutter of a frame of the *project* (`document.frameRate`), not
/// of the GIF, so a frame of the GIF is the one the editor shows there. Each frame goes through a bounded pipeline, up to
/// `framesInFlight` of them at once whatever the duration, so memory does not grow with it:
///
/// 1. drawn on a queue of the export's own, in frame order (`FrameRenderer.encode(at:into:commandBuffer:)`: the renderer
///    decodes the screen and the camera there, synchronously, never on Swift's cooperative pool, reading forward), and
///    its histogram counted on the GPU in the same command buffer. Not with `render(at:into:completion:)`, which decodes
///    ahead along the grid of the renderer's frame rate, the project's: the GIF's frames are every few frames of it, or
///    off it, and each would drop what was decoded ahead and could send the decoder back to a keyframe;
/// 2. in frame order: from the second frame on, mapped to the previous frame's palette and, when
///    `PaletteBuilder.shouldReuse` says the error is too large, to a new palette built from its histogram, mapped again;
///    the first frame always gets a new one. While frames need new palettes, those of the frames drawn ahead are built
///    in parallel as soon as they are drawn, and this chain, one frame after another, only waits for them when it needs
///    them (a palette is a function of its histogram alone: the same bytes);
/// 3. composed with the frames before it (`GIFComposer`: transparent where the canvas shows the same colour, cropped to
///    what changed, an unchanged frame folded into the one before);
/// 4. coded (LZW) in parallel, as many images at once as the performance cores but one, each with the minimum code size
///    of its palette and the transparent index every palette leaves free (plan decision 16), and written in order.
///
/// The same project, settings and Mac give the same bytes. It exports the document it was given, a copy: what is edited
/// while it runs changes nothing in it.
///
/// The export never writes into a project and never touches the destination until the GIF is complete (1c design §7.4):
/// it writes `<destination>.partial.gif` next to it (removing first one left there by an export that died), syncs it
/// with `F_FULLFSYNC` and `rename`s it into place, replacing a file there in one step. If it fails or is cancelled, the
/// partial file is removed and the destination is as it was.
public final class GIFExporter: Sendable {
    /// The name of the encoder's algorithm, frozen with its look (1c design §7.2): only in the log and in tests.
    static let algorithm = "gifQuant-1"
    /// Frames at once between being queued to be drawn and being quantized: the one being quantized and those drawn
    /// ahead of it.
    static let framesInFlight = 6
    /// The label of the export's queue, where frames are drawn.
    static let queueLabel = "dev.toma.GIFExporter"

    static let logger = Logger(subsystem: "dev.toma.Toma", category: "GIFExporter")

    public let project: LoadedProject
    public let document: EditDocument
    public let settings: GIFSettings
    /// What the frames read of the project's analysis caches (phase 2 design §10): `.none` in phase 1.
    public let analysis: AnalysisInputs
    /// For tests: told each frame's palette, in frame order, and whether it was built for that frame (or is the one
    /// before, reused).
    let paletteSink: PaletteSink?

    typealias PaletteSink = @Sendable (_ frame: Int, _ palette: GIFPalette, _ isNew: Bool) -> Void

    /// The GIF of `document` with `settings`, its frames reading `analysis` of the caches.
    public convenience init(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, analysis: AnalysisInputs = .none
    ) {
        self.init(project: project, document: document, settings: settings, paletteSink: nil, analysis: analysis)
    }

    init(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, paletteSink: PaletteSink?,
        analysis: AnalysisInputs = .none
    ) {
        precondition(settings.fps > 0 && settings.longSide > 0, "a GIF of \(settings.longSide) px at \(settings.fps) fps")
        self.project = project
        self.document = document
        self.settings = settings
        self.analysis = analysis
        self.paletteSink = paletteSink
    }

    /// Writes the GIF of `settings.range` to `destination`, replacing a file already there only once the GIF is complete,
    /// and returns its size and frame counts.
    ///
    /// Runs off the caller's actor; frames are drawn on a queue of the export's own, never on the main thread.
    /// `progress` is called one call at a time, in order, never on the main thread (hop to the main actor to show the
    /// values), with values from 0 that never go down and stay below 1 as frames are done, then once more with exactly 1
    /// once the file is in place. Cancel the task running the export to stop: it ends between two frames and throws
    /// `GIFExportError.cancelled`. One export at a time per destination: they would share the partial file.
    /// - Throws: `GIFExportError` (before anything is written: `rangeShorterThanAFrame`; then `diskFull`, `write`,
    ///   `cancelled`), `ExportError.destinationNotAllowed` for a destination that is a folder, a symlink or inside a
    ///   project package (as the MP4's), or the `RenderError` of a frame that could not be drawn or quantized on the GPU.
    @concurrent @discardableResult
    public func export(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> GIFExportSummary {
        guard !Task.isCancelled else { throw GIFExportError.cancelled }
        guard settings.range.lastsAFrame(fps: settings.fps) else { throw GIFExportError.rangeShorterThanAFrame }
        // From here on only the canonical URL is used, so what is written is what was checked.
        guard let destination = MP4Exporter.canonicalDestination(destination, project: project.package) else {
            throw ExportError.destinationNotAllowed
        }
        let encoder = try GIFEncoding(
            project: project, document: document, settings: settings, range: settings.range, paletteSink: paletteSink,
            analysis: analysis)
        guard !Task.isCancelled else { throw GIFExportError.cancelled }

        let partial = URL(fileURLWithPath: destination.path + ".partial.gif")
        let summary: GIFExportSummary
        var fd: Int32 = -1
        do {
            try Self.removeStalePartial(partial)
            fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw Self.writeError(errno) }
            let written = try await encoder.run(into: fd, loops: settings.loops, progress: progress)
            try DurableFile.fullSync(fd)
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Self.writeError(errno) }
            let closed = close(fd)
            fd = -1
            guard closed == 0 else { throw Self.writeError(errno) }
            guard !Task.isCancelled else { throw GIFExportError.cancelled }
            try Self.move(partial, to: destination)
            summary = GIFExportSummary(bytes: Int64(info.st_size), frames: written.frames, writtenFrames: written.images)
        } catch {
            if fd >= 0 { close(fd) }
            if unlink(partial.path) != 0 {
                let code = errno
                if code != ENOENT {
                    Self.logger.error("Cannot remove \(partial.path, privacy: .public): \(String(cString: strerror(code)), privacy: .public)")
                }
            }
            throw Self.exportError(error)
        }
        do {
            try DurableFile.syncDirectory(destination.deletingLastPathComponent())
        } catch {
            // The GIF is in place; only its durability across a power loss right now is in doubt.
            Self.logger.error("Cannot sync the folder of \(destination.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        progress(1)
        return summary
    }

    /// The GIF of `range` with the other settings, in memory and nowhere else: the bytes `export(to:progress:)` writes for
    /// that range (the export sheet's estimate and preview, 1c design §7.3). Cancel the task running it to stop.
    /// - Throws: `GIFExportError.rangeShorterThanAFrame` or `.cancelled`, or the `RenderError` of a frame that could not
    ///   be drawn or quantized on the GPU.
    @concurrent
    public func encodeInMemory(range: ExportRange) async throws -> Data {
        try await encodeInMemory(range: range, renderer: nil)
    }

    /// The renderer a run draws with, for `encodeInMemory(range:renderer:)` to reuse across several runs.
    func makeRenderer() throws -> FrameRenderer {
        try GIFEncoding.makeRenderer(
            project: project, document: document, size: settings.outputSize(project: project, document: document),
            analysis: analysis)
    }

    /// `encodeInMemory(range:)` drawing with `renderer` (from `makeRenderer()`) instead of a new one: the same bytes. One
    /// run at a time per renderer.
    @concurrent
    func encodeInMemory(range: ExportRange, renderer: FrameRenderer?) async throws -> Data {
        guard !Task.isCancelled else { throw GIFExportError.cancelled }
        guard range.lastsAFrame(fps: settings.fps) else { throw GIFExportError.rangeShorterThanAFrame }
        do {
            let encoder = try GIFEncoding(
                project: project, document: document, settings: settings, range: range, paletteSink: paletteSink, renderer: renderer,
                analysis: analysis)
            let pipe = try MemoryPipe()
            do {
                _ = try await encoder.run(into: pipe.writeEnd, loops: settings.loops, progress: nil)
            } catch {
                await pipe.abandon()
                throw error
            }
            return try await pipe.finish()
        } catch {
            throw Self.exportError(error)
        }
    }

    // MARK: - Files

    /// Removes what an export that died left at `partial`; never a folder.
    private static func removeStalePartial(_ partial: URL) throws {
        var info = stat()
        guard lstat(partial.path, &info) == 0 else {
            guard errno == ENOENT else { throw writeError(errno) }
            return
        }
        guard info.st_mode & S_IFMT != S_IFDIR else { throw GIFExportError.write(.EISDIR) }
        guard unlink(partial.path) == 0 else { throw writeError(errno) }
    }

    /// Puts the finished GIF at `destination` (canonical) with `rename(2)`: one step, over a regular file there too.
    /// Anything else there now, such as a symlink that appeared since the export began, is refused.
    private static func move(_ partial: URL, to destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ExportError.destinationNotAllowed }
        } else if errno != ENOENT {
            throw writeError(errno)
        }
        guard rename(partial.path, destination.path) == 0 else { throw writeError(errno) }
    }

    /// The error of a file operation that failed with `code`: a full disk, or which.
    static func writeError(_ code: Int32) -> GIFExportError {
        writeError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func writeError(_ code: POSIXErrorCode) -> GIFExportError {
        code == .ENOSPC || code == .EDQUOT ? .diskFull : .write(code)
    }

    /// `error` as the export reports it: the writer's and the file system's failures and a cancellation as
    /// `GIFExportError`; anything else (a `RenderError`, `ExportError.destinationNotAllowed`) as it is.
    private static func exportError(_ error: any Error) -> any Error {
        switch error {
        case GIFWriterError.writeFailed(let code): writeError(code)
        case let error as POSIXError: writeError(error.code)
        case is CancellationError: GIFExportError.cancelled
        default: error
        }
    }
}

// MARK: - The pipeline

/// One run of the encoder over a range: its renderer and quantizer, made for it.
private final class GIFEncoding: @unchecked Sendable {
    private let renderer: FrameRenderer
    private let quantizer: GIFQuantizer
    /// Where frames are drawn and their histograms counted.
    private let drawCommands: any MTLCommandQueue
    /// Where frames are mapped to their palettes: not behind the frames drawn ahead.
    private let mapCommands: any MTLCommandQueue
    /// Where the renderer draws, decoding synchronously: one frame at a time, in frame order. Each frame drains its own
    /// autorelease pool: the queue is never idle while frames are queued, and the decoded frames AVFoundation autoreleases
    /// would otherwise pile up until it is (1.3 GB instead of 270 MB in `bench-gif --synthetic`).
    private let drawQueue = DispatchQueue(label: GIFExporter.queueLabel, qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let size: SIMD2<Int>
    private let range: ExportRange
    private let settings: GIFSettings
    private let paletteSink: GIFExporter.PaletteSink?
    /// Set when the run stops early: frames queued to be drawn are not.
    private let stopped = Atomic(false)

    init(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, range: ExportRange,
        paletteSink: GIFExporter.PaletteSink?, renderer: FrameRenderer? = nil, analysis: AnalysisInputs = .none
    ) throws {
        size = settings.outputSize(project: project, document: document)
        // A passed renderer draws with its own analysis: `analysis` would be ignored, so the two must agree.
        precondition(renderer.map { $0.analysis == analysis } ?? true, "GIFExporter: renderer.analysis differs from analysis")
        let drawing = try renderer ?? Self.makeRenderer(project: project, document: document, size: size, analysis: analysis)
        self.renderer = drawing
        quantizer = try GIFQuantizer(device: drawing.device)
        guard let drawCommands = drawing.device.makeCommandQueue(), let mapCommands = drawing.device.makeCommandQueue() else {
            throw RenderError.metalResourceUnavailable("GIF command queue")
        }
        self.drawCommands = drawCommands
        self.mapCommands = mapCommands
        self.range = range
        self.settings = settings
        self.paletteSink = paletteSink
    }

    /// The motion blur's shutter is a fraction of a frame of the project, not of the GIF (1c design §7.2).
    static func makeRenderer(
        project: LoadedProject, document: EditDocument, size: SIMD2<Int>, analysis: AnalysisInputs = .none
    ) throws -> FrameRenderer {
        try FrameRenderer(project: project, document: document, outputSize: size, frameRate: document.frameRate, analysis: analysis)
    }

    /// Images coded at once at most: the performance cores but one (1c design §7.2, step 6), at least one.
    static let codingLimit: Int = {
        var cores: Int32 = 0
        var length = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &length, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return max(1, Int(cores) - 1)
    }()

    /// Writes the GIF of the range to `fd` (header, every image, trailer) and returns how many frames it drew and how many
    /// images it wrote. On an error or a cancellation it stops between two frames, after waiting for every frame it had
    /// queued and every palette it was building (so nothing of the run is left working), and throws.
    func run(
        into fd: Int32, loops: Bool, progress: (@Sendable (Double) -> Void)?
    ) async throws -> (frames: Int, images: Int) {
        let fps = settings.fps
        let count = range.frameCount(fps: fps)
        let delays = GIFDelays.delays(frameCount: count, fps: fps)
        GIFExporter.logger.info("""
            GIF \(self.size.x, privacy: .public) × \(self.size.y, privacy: .public) at \(fps, privacy: .public) fps, \
            \(self.settings.quality.rawValue, privacy: .public) quality, dither \(self.settings.dither, privacy: .public), \
            \(count, privacy: .public) frames, with \(GIFExporter.algorithm, privacy: .public)
            """)
        var writer = try GIFWriter(fileDescriptor: fd, width: size.x, height: size.y, loops: loops)
        let targets = try (0..<min(GIFExporter.framesInFlight, count)).map { _ in FrameTarget(texture: try makeTarget()) }

        // Frames queued to be drawn and not taken yet, by frame.
        var drawing: [Int: Promise<DrawnFrame>] = [:]
        // New palettes being built ahead from the histograms of frames not taken yet, by frame; and those of frames taken,
        // used or not, waited for before the run ends (the oldest once there are more than the frames in flight).
        var building: [Int: Task<GIFPalette, any Error>] = [:]
        var built: [Task<GIFPalette, any Error>] = []
        do {
            let images = try await withThrowingTaskGroup(of: (Int, GIFImageBlock).self) { coding in
                var composer = GIFComposer(width: size.x, height: size.y)
                var previous: GIFPalette?
                var builtLast = false
                var queued = 0
                var coded: [Int: GIFImageBlock] = [:]
                var submitted = 0
                var written = 0
                for n in 0..<count {
                    while queued < count, queued < n + GIFExporter.framesInFlight {
                        drawing[queued] = draw(queued, into: targets[queued % targets.count])
                        queued += 1
                    }
                    // While frames need new palettes (things move), those of the frames drawn ahead are built at once, in
                    // parallel, in case they need one too: off the chain of palettes, which is one frame after another.
                    if builtLast {
                        for k in n..<queued where building[k] == nil {
                            building[k] = buildPalette(of: drawing[k]!)
                        }
                    }
                    let frame = try await drawing.removeValue(forKey: n)!.value
                    if Task.isCancelled { throw GIFExportError.cancelled }
                    let ahead = building.removeValue(forKey: n)
                    if let ahead { built.append(ahead) }
                    if built.count > GIFExporter.framesInFlight { _ = try? await built.removeFirst().value }
                    let quantized = try await quantize(frame, frame: n, previous: previous, building: ahead, delay: delays[n])
                    builtLast = quantized.palette != previous
                    previous = quantized.palette
                    if let composed = composer.add(quantized) {
                        let index = submitted
                        coding.addTask { (index, try Self.image(of: composed)) }
                        submitted += 1
                    }
                    // In order, the images coded so far; and wait for the oldest while too many are being coded.
                    while let image = coded.removeValue(forKey: written) {
                        try writer.write(image)
                        written += 1
                    }
                    while submitted - written > Self.codingLimit {
                        guard let (index, image) = try await coding.next() else { break }
                        coded[index] = image
                        while let image = coded.removeValue(forKey: written) {
                            try writer.write(image)
                            written += 1
                        }
                    }
                    progress?(Double(n + 1) / Double(count + 1))
                }
                if let last = composer.finish() {
                    let index = submitted
                    coding.addTask { (index, try Self.image(of: last)) }
                    submitted += 1
                }
                while written < submitted {
                    if let image = coded.removeValue(forKey: written) {
                        try writer.write(image)
                        written += 1
                    } else if let (index, image) = try await coding.next() {
                        coded[index] = image
                    } else {
                        break
                    }
                }
                return written
            }
            for palette in built { _ = try? await palette.value }
            try writer.finish()
            return (count, images)
        } catch {
            stopped.store(true, ordering: .relaxed)
            for frame in drawing.values { _ = try? await frame.value }
            for palette in building.values { _ = try? await palette.value }
            for palette in built { _ = try? await palette.value }
            throw error
        }
    }

    /// The new palette of the frame `drawn` will be, built as soon as it is drawn, alongside the run.
    private func buildPalette(of drawn: Promise<DrawnFrame>) -> Task<GIFPalette, any Error> {
        let quality = settings.quality
        return Task {
            PaletteBuilder.build(try await drawn.value.histogram.result(), quality: quality)
        }
    }

    /// A texture a frame is drawn into and read from by the quantizer, on the GPU only.
    private func makeTarget() throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("GIF frame of \(size.x) × \(size.y)")
        }
        return texture
    }

    /// Queues frame `n` to be drawn into `target`, with its histogram counted in the same command buffer, and returns
    /// what it will be once the GPU is done. Frames are drawn on `drawQueue` in the order queued; once the run stopped,
    /// a frame not begun yet is not drawn (`GIFExportError.cancelled`).
    private func draw(_ n: Int, into target: FrameTarget) -> Promise<DrawnFrame> {
        let promise = Promise<DrawnFrame>()
        let seconds = Double(range.frameTime(n, fps: settings.fps)) / 1e9
        drawQueue.async { [self] in
            guard !stopped.load(ordering: .relaxed) else {
                promise.fulfill(.failure(GIFExportError.cancelled))
                return
            }
            do {
                guard let commandBuffer = drawCommands.makeCommandBuffer() else {
                    throw RenderError.metalResourceUnavailable("command buffer")
                }
                try renderer.encode(at: seconds, into: target.texture, commandBuffer: commandBuffer)
                let histogram = try quantizer.histogram(of: target.texture, into: commandBuffer)
                let drawn = DrawnFrame(target: target, histogram: histogram)
                commandBuffer.addCompletedHandler { commandBuffer in
                    promise.fulfill(commandBuffer.status == .completed ? .success(drawn) : .failure(Self.gpuFailure(commandBuffer)))
                }
                commandBuffer.commit()
            } catch {
                promise.fulfill(.failure(error))
            }
        }
        return promise
    }

    /// Frame `index`, drawn, mapped to a palette: to `previous` while it fits (`PaletteBuilder.shouldReuse`), otherwise
    /// to a new one built from its histogram (by `building`, when it was started ahead: the same palette).
    private func quantize(
        _ drawn: DrawnFrame, frame index: Int, previous: GIFPalette?, building: Task<GIFPalette, any Error>?, delay: Int
    ) async throws -> QuantizedFrame {
        if let previous {
            let mapped = try await map(drawn.target.texture, to: previous)
            if PaletteBuilder.shouldReuse(mapped.error(), quality: settings.quality) {
                paletteSink?(index, previous, false)
                return QuantizedFrame(width: size.x, height: size.y, indices: mapped.indices(), palette: previous, delay: delay)
            }
        }
        let palette = if let building {
            try await building.value
        } else {
            PaletteBuilder.build(drawn.histogram.result(), quality: settings.quality)
        }
        paletteSink?(index, palette, true)
        let mapped = try await map(drawn.target.texture, to: palette)
        return QuantizedFrame(width: size.x, height: size.y, indices: mapped.indices(), palette: palette, delay: delay)
    }

    /// `texture` mapped to `palette` on the GPU, waited for without holding a thread.
    private func map(_ texture: any MTLTexture, to palette: GIFPalette) async throws -> MapPass {
        guard let commandBuffer = mapCommands.makeCommandBuffer() else {
            throw RenderError.metalResourceUnavailable("command buffer")
        }
        let pass = try quantizer.map(texture, palette: palette, dither: settings.ditherStrength, into: commandBuffer)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { commandBuffer in
                if commandBuffer.status == .completed {
                    done.resume()
                } else {
                    done.resume(throwing: Self.gpuFailure(commandBuffer))
                }
            }
            commandBuffer.commit()
        }
        return pass
    }

    /// A composed frame as the image the writer writes: its indices coded with the minimum code size of its colours and
    /// the transparent index that every palette leaves free after them (plan decision 16), on the first frame too.
    private static func image(of frame: ComposedFrame) throws -> GIFImageBlock {
        let codeSize = LZWEncoder.minimumCodeSize(colors: frame.palette.count + 1)
        let data = try frame.indices.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: codeSize) }
        return GIFImageBlock(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height, palette: frame.palette,
            transparentIndex: frame.transparentIndex, delay: frame.delay, minimumCodeSize: codeSize, data: data)
    }

    /// `RenderError.gpuFailed` with what `commandBuffer` says went wrong.
    private static func gpuFailure(_ commandBuffer: any MTLCommandBuffer) -> RenderError {
        .gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)")
    }
}

/// A texture frames are drawn into, one at a time: handed to the draw queue for a frame and back to the run once the GPU
/// is done with it, never used by both at once.
private struct FrameTarget: @unchecked Sendable {
    let texture: any MTLTexture
}

/// A frame drawn into its target with its histogram, handed from Metal's completion thread to the run once, and read
/// only there after the GPU finished it.
private struct DrawnFrame: @unchecked Sendable {
    let target: FrameTarget
    let histogram: HistogramPass
}

/// A value that arrives later, from another thread, for tasks to wait for without holding a thread.
private final class Promise<Value: Sendable>: Sendable {
    private enum State {
        case waiting([CheckedContinuation<Value, any Error>])
        case fulfilled(Result<Value, any Error>)
    }

    private let state = Mutex(State.waiting([]))

    /// Sets the value, or the error, once; a later call does nothing.
    func fulfill(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
            guard case .waiting(let waiters) = state else { return [] }
            state = .fulfilled(result)
            return waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    /// Waits for the value.
    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    switch state {
                    case .fulfilled(let result):
                        return result
                    case .waiting(let waiters):
                        state = .waiting(waiters + [continuation])
                        return nil
                    }
                }
                if let result { continuation.resume(with: result) }
            }
        }
    }
}

/// A pipe a thread of its own drains into memory: the file descriptor an in-memory GIF is written to.
private final class MemoryPipe: Sendable {
    let writeEnd: Int32
    private let writeEndOpen = Atomic(true)
    private let collected = Promise<Data>()

    init() throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw GIFExporter.writeError(errno) }
        let readEnd = ends[0]
        writeEnd = ends[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        // A write after the reader is gone fails with EPIPE instead of killing the process.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        let collected = collected
        Thread {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var failure: Int32?
            while true {
                let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
                if n > 0 {
                    data.append(contentsOf: buffer[..<n])
                } else if n == 0 {
                    break
                } else if errno != EINTR {
                    failure = errno
                    break
                }
            }
            close(readEnd)
            collected.fulfill(failure.map { .failure(GIFExporter.writeError($0)) } ?? .success(data))
        }.start()
    }

    /// Closes the write end and returns everything written to it.
    func finish() async throws -> Data {
        closeWriteEnd()
        return try await collected.value
    }

    /// Closes the write end and waits for the reader to be done, dropping what was written.
    func abandon() async {
        closeWriteEnd()
        _ = try? await collected.value
    }

    private func closeWriteEnd() {
        if writeEndOpen.exchange(false, ordering: .relaxed) { close(writeEnd) }
    }
}
