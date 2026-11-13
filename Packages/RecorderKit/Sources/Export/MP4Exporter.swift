// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ProjectFormat
import Render
import Synchronization
import os

/// Exports a take as an MP4: H.264 High video tagged Rec.709 and the microphone as AAC.
///
/// Frame `i` is the frame `FrameRenderer` draws at output time `i / framesPerSecond`, the same drawing
/// the preview shows; the video lasts the take's screen, rounded to whole frames. The microphone is placed
/// by host time on the same timeline (`MicrophoneTimeline`); a take without one exports without audio.
///
/// The export never writes into a project and never touches the destination until it is complete: it
/// writes `<destination>.partial.mp4` next to it and moves that into place at the end, replacing an
/// existing file in one step. If it fails or is cancelled, the partial file is removed and the
/// destination is as it was.
public final class MP4Exporter: Sendable {
    /// AAC bitrate, in bits per second.
    static let audioBitRate = 160_000
    /// An export whose writer takes no data for this long fails instead of waiting forever.
    static let stallTimeout = 30.0

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    public let project: LoadedProject
    public let settings: ExportSettings

    public init(project: LoadedProject, settings: ExportSettings = .init()) {
        self.project = project
        self.settings = settings
    }

    /// Writes the MP4 to `destination`, replacing a file already there only once the export is complete.
    ///
    /// Rendering and encoding run on a queue of their own, never on the caller's thread. `progress` gets
    /// values from 0 that never go down, on that queue (hop to the main actor to show them); the last one
    /// is exactly 1, once the file is in place. Cancel the calling task to stop: the export ends between
    /// two frames and throws `ExportError.cancelled`.
    /// - Throws: `ExportError` (`destinationNotAllowed` before anything is written, `noDisplayTrack`,
    ///   `writerFailed`, `cancelled`), or the `RenderError` of a frame that could not be drawn.
    @concurrent
    public func export(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !Task.isCancelled else { throw ExportError.cancelled }
        guard Self.isAllowedDestination(destination, project: project.package) else { throw ExportError.destinationNotAllowed }
        guard let screen = project.take.tracks.first(where: { $0.kind == .display }), !screen.segments.isEmpty else {
            throw ExportError.noDisplayTrack
        }
        let fps = settings.framesPerSecond
        guard fps > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(fps)") }

        let renderer = try FrameRenderer(project: project, outputSize: settings.outputSize)
        let frameCount = max(1, Int((renderer.duration * Double(fps)).rounded()))
        let timelineStart = FrameEvaluator(
            take: project.take, events: project.events, style: StyleV0(), outputSize: settings.outputSize
        ).timelineStart
        let audioFrames = Int64((Double(frameCount) / Double(fps) * MicrophoneTimeline.sampleRate).rounded())
        let microphone = try await MicrophoneTimeline.load(project, timelineStart: timelineStart, totalFrames: audioFrames)
        guard !Task.isCancelled else { throw ExportError.cancelled }

        let partial = URL(fileURLWithPath: destination.path + ".partial.mp4")
        try Self.removeStalePartial(partial)
        do {
            let session = try ExportSession(
                url: partial, settings: settings, renderer: renderer, frameCount: frameCount, microphone: microphone)
            try await withTaskCancellationHandler {
                try await session.run(progress: progress)
            } onCancel: {
                session.cancel()
            }
            try Self.fullSync(partial)
            guard !Task.isCancelled else { throw ExportError.cancelled }
            try Self.move(partial, to: destination)
        } catch {
            if unlink(partial.path) != 0 {
                let code = errno
                if code != ENOENT {
                    Self.logger.error("Cannot remove \(partial.path, privacy: .public): \(String(cString: strerror(code)), privacy: .public)")
                }
            }
            throw error
        }
        do {
            try DurableFile.syncDirectory(destination.deletingLastPathComponent())
        } catch {
            // The export is in place; only its durability across a power loss right now is in doubt.
            Self.logger.error("Cannot sync the folder of \(destination.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        progress(1)
    }

    // MARK: - Destination

    /// Whether an export may write `destination`: not a folder (nor a symlink to one), and neither the
    /// path as given nor the path with every symlink resolved inside a `*.toma` package or inside the
    /// project's package.
    static func isAllowedDestination(_ destination: URL, project: ProjectPackage) -> Bool {
        guard destination.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }
        let packages = [project.url.standardizedFileURL.pathComponents, resolvingSymlinks(project.url)].map(lowercased)
        for components in [destination.standardizedFileURL.pathComponents, resolvingSymlinks(destination)].map(lowercased) {
            let ancestors = components.dropLast()
            if ancestors.contains(where: { ($0 as NSString).pathExtension == ProjectPackage.fileExtension.lowercased() }) {
                return false
            }
            if packages.contains(where: { components.count > $0.count && components.starts(with: $0) }) { return false }
        }
        return true
    }

    private static func lowercased(_ components: [String]) -> [String] {
        components.map { $0.lowercased() }
    }

    /// The path components of `url` with every symlink resolved: `realpath(3)` of its deepest existing
    /// ancestor (itself if it exists), followed by the components that do not exist yet.
    private static func resolvingSymlinks(_ url: URL) -> [String] {
        var existing = url.standardizedFileURL.pathComponents
        var missing: [String] = []
        while !existing.isEmpty {
            if let resolved = realpath(NSString.path(withComponents: existing), nil) {
                defer { free(resolved) }
                return URL(fileURLWithPath: String(cString: resolved)).pathComponents + missing.reversed()
            }
            missing.append(existing.removeLast())
        }
        return url.standardizedFileURL.pathComponents
    }

    /// Removes what an export that died left at `partial`; never a folder.
    private static func removeStalePartial(_ partial: URL) throws {
        var info = stat()
        guard lstat(partial.path, &info) == 0 else {
            guard errno == ENOENT else { throw posixFailure("cannot look at \(partial.path)") }
            return
        }
        guard info.st_mode & S_IFMT != S_IFDIR else {
            throw ExportError.writerFailed("\(partial.path) is a folder, where the export writes its partial file")
        }
        guard unlink(partial.path) == 0 else { throw posixFailure("cannot remove the old \(partial.path)") }
    }

    private static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure("cannot open \(url.path)") }
        defer { close(fd) }
        do {
            try DurableFile.fullSync(fd)
        } catch {
            throw ExportError.writerFailed("cannot sync \(url.path): \(error)")
        }
    }

    /// Puts the finished export at `destination`: `replaceItemAt` over an existing file (one step, never
    /// remove-then-move), `rename(2)` otherwise.
    private static func move(_ partial: URL, to destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } catch {
                throw ExportError.writerFailed("cannot replace \(destination.path): \(error)")
            }
        } else {
            guard rename(partial.path, destination.path) == 0 else {
                throw posixFailure("cannot move the export to \(destination.path)")
            }
        }
    }

    private static func posixFailure(_ what: String) -> ExportError {
        .writerFailed("\(what): \(String(cString: strerror(errno)))")
    }
}

/// One export's writer and the loop that feeds it. The loop runs on `queue`; `cancel()` may come from any
/// thread. Everything else is touched by the loop only, or by `run` before and after it.
private final class ExportSession: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let microphone: MicrophoneTimeline?
    private let renderer: FrameRenderer
    private let settings: ExportSettings
    private let frameCount: Int
    private let queue = DispatchQueue(label: "dev.toma.MP4Exporter", qos: .userInitiated)
    private let cancelled = Atomic(false)

    /// Creates the writer of `url` (the file appears when writing starts) and its inputs.
    init(url: URL, settings: ExportSettings, renderer: FrameRenderer, frameCount: Int, microphone: MicrophoneTimeline?) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ExportError.writerFailed("cannot create the writer: \(error)")
        }

        let video = Self.videoSettings(settings)
        guard writer.canApply(outputSettings: video, forMediaType: .video) else {
            throw ExportError.writerFailed("H.264 cannot encode \(settings.outputSize.x)×\(settings.outputSize.y) at \(settings.framesPerSecond) fps")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed("the writer takes no video input") }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputSize.x,
            kCVPixelBufferHeightKey as String: settings.outputSize.y,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        if let microphone {
            let audio: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MicrophoneTimeline.sampleRate,
                AVNumberOfChannelsKey: microphone.channels,
                AVChannelLayoutKey: MicrophoneTimeline.channelLayoutData(channels: microphone.channels),
                AVEncoderBitRateKey: MP4Exporter.audioBitRate,
            ]
            guard writer.canApply(outputSettings: audio, forMediaType: .audio) else {
                throw ExportError.writerFailed("AAC cannot encode \(microphone.channels) channel(s) at 48 kHz, 160 kbps")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio, sourceFormatHint: microphone.formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerFailed("the writer takes no audio input") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        self.writer = writer
        self.videoInput = videoInput
        self.microphone = microphone
        self.renderer = renderer
        self.settings = settings
        self.frameCount = frameCount
    }

    static func videoSettings(_ settings: ExportSettings) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.outputSize.x,
            AVVideoHeightKey: settings.outputSize.y,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
            ],
        ]
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Encodes every frame and the audio, then finishes the file. On failure or cancellation the writer is
    /// cancelled (this is the export's own partial file, never recorded data) and the error rethrown.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        try self.encode(progress: progress)
                        done.resume()
                    } catch {
                        done.resume(throwing: error)
                    }
                }
            }
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(settings.framesPerSecond)))
            await writer.finishWriting()
            guard writer.status == .completed else { throw failure() }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// The loop: feeds whichever input takes data, polling while neither does. The writer interleaves the
    /// two tracks by holding back the input that is ahead (`isReadyForMoreMediaData`), so an input that
    /// takes data is always fed: holding one back here too could leave both waiting for each other.
    private func encode(progress: @Sendable (Double) -> Void) throws {
        guard writer.startWriting() else { throw failure() }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed("the writer has no pixel buffer pool") }
        var frame = 0
        var videoDone = false
        var audioDone = audioInput == nil
        var idleSince: HostTime?
        while !(videoDone && audioDone) {
            if cancelled.load(ordering: .relaxed) { throw ExportError.cancelled }
            var fed = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let limit = settings.failAfterFrames, frame >= limit {
                    throw ExportError.writerFailed("failing after \(limit) frames, as the settings ask")
                }
                try append(frame: frame, from: pool)
                frame += 1
                progress(Double(frame) / Double(frameCount + 1))
                if frame == frameCount {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                fed = true
            }
            if !audioDone, let audioInput, let microphone, audioInput.isReadyForMoreMediaData {
                if let block = try microphone.nextBlock() {
                    guard audioInput.append(block) else { throw failure() }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                fed = true
            }
            if fed {
                idleSince = nil
                continue
            }
            if writer.status != .writing { throw failure() }
            let now = HostTime.now()
            if let since = idleSince, now.seconds(since: since) > MP4Exporter.stallTimeout {
                throw ExportError.writerFailed("the writer took no data for \(Int(MP4Exporter.stallTimeout)) s")
            }
            idleSince = idleSince ?? now
            usleep(1_000)
        }
    }

    /// Draws frame `frame` into a buffer of the writer's pool and appends it at `frame / fps`.
    private func append(frame: Int, from pool: CVPixelBufferPool) throws {
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw ExportError.writerFailed("no pixel buffer from the pool (CVReturn \(status))")
        }
        // The frame's values are encoded as they are: tagged as what the file says, nothing converts them.
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let fps = settings.framesPerSecond
        try renderer.render(at: Double(frame) / Double(fps), into: pixelBuffer)
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
            throw failure()
        }
    }

    /// The writer's error as `writerFailed`.
    private func failure() -> ExportError {
        .writerFailed(writer.error.map { String(describing: $0) } ?? "the writer stopped (status \(writer.status.rawValue))")
    }
}
