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

/// Exports a take as an MP4: H.264 High video tagged Rec.709 and, as one AAC track, the microphone mixed with system
/// audio.
///
/// Frame `i` is the frame `FrameRenderer` draws of the edit document at output time `TimeMap.frameTime(i, frameRate:)`,
/// the same drawing the preview shows; the video lasts the document's output (`TimeMap.frameCount(frameRate:)` frames;
/// for the legacy document, the screen's timeline, or an audio track's when it was recorded longer). The audio is the
/// document's mix (`EditedMix`, the one the preview plays), as long as those frames last: every microphone and system
/// audio track through the clips, each placed by host time by its own clock, at its gain, with the click sounds; a take
/// without any audio track or click sound exports without audio.
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
    public let document: EditDocument
    public let settings: ExportSettings

    public init(project: LoadedProject, document: EditDocument, settings: ExportSettings) {
        self.project = project
        self.document = document
        self.settings = settings
    }

    /// The export of the legacy document (`EditDocument.legacy(for:)`): what phase 0 and 1a export.
    public convenience init(project: LoadedProject, settings: ExportSettings = .init()) {
        self.init(project: project, document: .legacy(for: project), settings: settings)
    }

    /// Writes the MP4 to `destination`, replacing a file already there only once the export is complete,
    /// and returns what it had to leave out: microphone or system audio that could not be read is silence, and
    /// screen or camera video that could not be decoded shows the frame before it.
    ///
    /// Rendering and encoding run on a queue of their own, never on the caller's thread or the main thread.
    /// `progress` is called one call at a time, in order, never on the main thread (hop to the main actor
    /// to show the values): from the export's queue while frames are encoded, with values from 0 that never
    /// go down and stay below 1, then once more with exactly 1 from the task running the export, once the
    /// file is in place. Cancel that task to stop: the export ends between two frames and throws
    /// `ExportError.cancelled`. One export at a time per destination: they would share the partial file.
    /// - Throws: `ExportError` (`destinationNotAllowed` before anything is written, `noDisplayTrack`,
    ///   `writerFailed`, `cancelled`), or the `RenderError` of a frame that could not be drawn.
    @concurrent @discardableResult
    public func export(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportSummary {
        guard !Task.isCancelled else { throw ExportError.cancelled }
        // From here on only the canonical URL is used, so what is written is what was checked.
        guard let destination = Self.canonicalDestination(destination, project: project.package) else {
            throw ExportError.destinationNotAllowed
        }
        guard ScreenChoice.screenTrack(in: project.take, events: project.events)?.segments.isEmpty == false else {
            throw ExportError.noDisplayTrack
        }
        let fps = settings.framesPerSecond
        guard fps > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(fps)") }

        let renderer = try FrameRenderer(project: project, document: document, outputSize: settings.outputSize)
        let frameCount = TimeMap(sequence: document.sequence).frameCount(frameRate: fps)
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: fps)
        let audio = mix.hasSound ? try AudioMix(mix: mix) : nil
        guard !Task.isCancelled else { throw ExportError.cancelled }

        let partial = URL(fileURLWithPath: destination.path + ".partial.mp4")
        try Self.removeStalePartial(partial)
        let summary: ExportSummary
        do {
            let session = try ExportSession(
                url: partial, settings: settings, renderer: renderer, frameCount: frameCount, audio: audio)
            try await withTaskCancellationHandler {
                try await session.run(progress: progress)
            } onCancel: {
                session.cancel()
            }
            try Self.fullSync(partial)
            guard !Task.isCancelled else { throw ExportError.cancelled }
            try Self.move(partial, to: destination)
            summary = ExportSummary(
                missingAudio: session.missingAudio.sorted { ($0.start, $0.end, $0.track) < ($1.start, $1.end, $1.track) },
                missingVideo: renderer.missingVideo)
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
        return summary
    }

    /// The samples the AAC encoder gets when the legacy document of `project` is exported at `framesPerSecond`: what
    /// `mixSamples(of:document:framesPerSecond:)` gives for it. The golden mix (`goldenMixMatches`) holds them.
    static func mixSamples(of project: LoadedProject, framesPerSecond: Int = 60) async throws -> [Float] {
        try await mixSamples(of: project, document: .legacy(for: project), framesPerSecond: framesPerSecond)
    }

    /// The samples the AAC encoder gets when `document` of `project` is exported at `framesPerSecond`: every block of its
    /// mix (`AudioMix`), one after the other, interleaved Float32, over the frames of video rounded to 48 kHz; empty when
    /// the export has no audio.
    /// - Throws: what `export` throws before it writes anything (`noDisplayTrack`, `writerFailed` for a frame rate
    ///   that is not positive), or what reading or mixing the audio throws.
    static func mixSamples(of project: LoadedProject, document: EditDocument, framesPerSecond: Int) async throws -> [Float] {
        guard ScreenChoice.screenTrack(in: project.take, events: project.events)?.segments.isEmpty == false else {
            throw ExportError.noDisplayTrack
        }
        guard framesPerSecond > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(framesPerSecond)") }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: framesPerSecond)
        guard mix.hasSound else { return [] }
        // Mixing decodes: off the cooperative pool, as the export's own queue does it.
        return try await offTheCooperativePool {
            let audio = try AudioMix(mix: mix)
            var samples: [Float] = []
            samples.reserveCapacity(Int(audio.totalFrames) * audio.channels)
            while let block = try audio.nextBlock() {
                guard let data = CMSampleBufferGetDataBuffer(block) else { throw ExportError.writerFailed("an audio block without data") }
                let byteCount = CMBlockBufferGetDataLength(data)
                var floats = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                let status = floats.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw ExportError.writerFailed("cannot read an audio block (OSStatus \(status))") }
                samples += floats
            }
            return samples
        }
    }

    // MARK: - Destination

    /// The file an export may write for `destination`, made canonical once so that every later use (the
    /// checks, the partial file next to it, the move into place) names the same file: `realpath(3)` of its
    /// folder, which must exist, plus its name. A `..` after a symlink is resolved the way the kernel
    /// resolves it, never lexically.
    ///
    /// `nil`, refused, for a name that is empty, `.` or `..`; a destination that exists and is not a regular
    /// file (a folder, a symlink, a device); and one inside a `*.toma` package or inside the project's
    /// package, on the canonical path or on the path as given.
    static func canonicalDestination(_ destination: URL, project: ProjectPackage) -> URL? {
        guard destination.isFileURL else { return nil }
        let path = destination.path as NSString
        let name = path.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { return nil }
        guard let folder = realpath(path.deletingLastPathComponent.isEmpty ? "." : path.deletingLastPathComponent, nil) else {
            return nil
        }
        let canonical = URL(fileURLWithPath: String(cString: folder), isDirectory: true).appendingPathComponent(name, isDirectory: false)
        free(folder)
        var info = stat()
        if lstat(canonical.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        } else if errno != ENOENT {
            return nil
        }
        let packageRoots = [project.url.standardizedFileURL.pathComponents, resolved(project.url)].map(lowercased)
        for components in [canonical.pathComponents, URL(fileURLWithPath: destination.path).pathComponents].map(lowercased) {
            if components.dropLast().contains(where: { ($0 as NSString).pathExtension == ProjectPackage.fileExtension.lowercased() }) {
                return nil
            }
            if packageRoots.contains(where: { components.count > $0.count && components.starts(with: $0) }) { return nil }
        }
        return canonical
    }

    private static func lowercased(_ components: [String]) -> [String] {
        components.map { $0.lowercased() }
    }

    /// The path components of an existing `url` with every symlink resolved; as given if it cannot be.
    private static func resolved(_ url: URL) -> [String] {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL.pathComponents }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).pathComponents
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

    /// Puts the finished export at `destination` (canonical): `replaceItemAt` over a regular file (one step,
    /// never remove-then-move), `rename(2)` when nothing is there. Anything else there now, such as a
    /// symlink that appeared since the export began, is refused.
    private static func move(_ partial: URL, to destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ExportError.destinationNotAllowed }
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } catch {
                throw ExportError.writerFailed("cannot replace \(destination.path): \(error)")
            }
        } else {
            guard errno == ENOENT else { throw posixFailure("cannot look at \(destination.path)") }
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
    private let audio: AudioMix?
    private let renderer: FrameRenderer
    private let settings: ExportSettings
    private let frameCount: Int
    private let queue = DispatchQueue(label: "dev.toma.MP4Exporter", qos: .userInitiated)
    private let cancelled = Atomic(false)

    /// Creates the writer of `url` (the file appears when writing starts) and its inputs.
    init(url: URL, settings: ExportSettings, renderer: FrameRenderer, frameCount: Int, audio: AudioMix?) throws {
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

        if let audio {
            let aac: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioTrackTimeline.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVChannelLayoutKey: AudioMix.channelLayoutData(channels: audio.channels),
                AVEncoderBitRateKey: MP4Exporter.audioBitRate,
                // Constant: the default strategy spends far less than asked on a quiet or simple signal.
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            ]
            guard writer.canApply(outputSettings: aac, forMediaType: .audio) else {
                throw ExportError.writerFailed("AAC cannot encode \(audio.channels) channel(s) at 48 kHz, 160 kbps")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac, sourceFormatHint: audio.formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerFailed("the writer takes no audio input") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        self.writer = writer
        self.videoInput = videoInput
        self.audio = audio
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

    /// The audio spans left silent; read once `run` has returned.
    var missingAudio: [MissingAudio] { audio?.missingAudio ?? [] }

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
            if !audioDone, let audioInput, let audio, audioInput.isReadyForMoreMediaData {
                if let block = try audio.nextBlock() {
                    try waitUntilReady(audioInput)
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
    /// The renderer draws it at `TimeMap.frameTime(frame, frameRate: fps)`: in seconds, which the renderer rounds back to
    /// those nanoseconds exactly (they are far below 2⁵¹).
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
        try renderer.render(at: Double(TimeMap.frameTime(frame, frameRate: fps)) / 1e9, into: pixelBuffer)
        try waitUntilReady(videoInput)  // drawing took time: the writer may have failed meanwhile
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
            throw failure()
        }
    }

    /// Returns once `input` takes data, checked right before an append: appending to an input that is not
    /// ready, or after the writer stopped writing, raises an Objective-C exception, which would end the
    /// process. Throws the writer's failure, `cancelled`, or `writerFailed` after `stallTimeout`.
    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        let deadline = HostTime.now().adding(seconds: MP4Exporter.stallTimeout)
        while true {
            guard writer.status == .writing else { throw failure() }
            if input.isReadyForMoreMediaData { return }
            if cancelled.load(ordering: .relaxed) { throw ExportError.cancelled }
            guard HostTime.now() < deadline else {
                throw ExportError.writerFailed("the writer took no data for \(Int(MP4Exporter.stallTimeout)) s")
            }
            usleep(1_000)
        }
    }

    /// The writer's error as `writerFailed`.
    private func failure() -> ExportError {
        .writerFailed(writer.error.map { String(describing: $0) } ?? "the writer stopped (status \(writer.status.rawValue))")
    }
}
