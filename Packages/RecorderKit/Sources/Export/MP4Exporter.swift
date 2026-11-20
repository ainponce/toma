// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ProjectFormat
import Render
import Synchronization
import VideoToolbox
import os

/// Exports a take as a video: H.264 High video tagged Rec.709 and, as one AAC track, the microphone mixed with system
/// audio, in an MP4; or, by `ExportSettings.codec` (phase 2 design §6.8), HEVC Main 8-bit (`hvc1`) with that AAC in an
/// MP4, or ProRes 422 or 422 HQ with the mix as 24-bit integer LPCM at 48 kHz in a QuickTime movie. The codec changes how
/// the frames and the mix are encoded, never what they are: every codec is given the same pixels and the same samples.
///
/// Frame `i` is the frame `FrameRenderer` draws of the edit document at output time `TimeMap.frameTime(i, frameRate:)`,
/// the same drawing the preview shows (the renderer's motion blur in frames of the export's rate); the video lasts the
/// document's output (`TimeMap.frameCount(frameRate:)` frames;
/// for the legacy document, the screen's timeline, or an audio track's when it was recorded longer). The audio is the
/// document's mix (`EditedMix`, the one the preview plays), as long as those frames last: every microphone and system
/// audio track through the clips, each placed by host time by its own clock, at its gain, with the click sounds; a take
/// without any audio track or click sound exports without audio.
///
/// A take whose screen recorded no segment exports its background, its camera and its audio for as long as the
/// document's sequence lasts (design §7.6), unless the document is the legacy one (`EditDocument.legacy(for:)`), which
/// refuses it as phase 0 and 1a do (`ExportError.noDisplayTrack`).
///
/// It exports the document it was given, a copy: what is edited while it runs changes nothing in it (design §5.6).
///
/// With chapters (`ExportSettings.chapters`, phase 3 plan 3d decision 5), the file also has a chapter track
/// (`ChapterTrack`), after the video and the audio, tied to the video as its chapter list and disabled; the export of a
/// range has the chapters of that range (`Chapters.within`). It changes no frame and no sample. Without chapters, the file
/// has the tracks it had before phase 3.
///
/// Given a range of the output (`ExportRange`, 1c design §7.1), it exports that part alone: frame `n` is the one drawn
/// at `range.frameTime(n, fps:)`, for the frames `range.frameCount(fps:)` counts before its end (the range cut to the
/// video first: from 0 to where the whole export's last frame ends), and the audio is the mix's frames from
/// `round(start × 48 000 / 10⁹)` on, as long as those frames last (`EditedMix.frames(of:frameCount:framesPerSecond:)`):
/// the same samples the whole video plays there, with no fade of its own at the range's edges. The summary lists what
/// was left out within the range, in seconds of its MP4. Without a range, or with the whole output
/// (`ExportRange.whole`), it is the export of 1b, frame for frame and sample for sample.
///
/// The frames go through a pipeline (design §7.9): up to `ExportSettings.framesInFlight` of them drawn at once
/// (`FrameRenderer.render(at:into:completion:)`, which decodes ahead along the export's frame grid), while the writer
/// encodes the ones before them. Each is appended to the writer on the export's queue, in frame order, once the GPU
/// finished it: the same bytes as drawing one frame at a time.
///
/// The export never writes into a project and never touches the destination until it is complete: it
/// writes `<destination>.partial.<ext>` next to it, with the codec's extension (`ExportCodec.fileExtension`: `mp4`, or
/// `mov` for ProRes), and moves that into place at the end, replacing an existing file in one step. If it fails or is
/// cancelled, the partial file is removed and the destination is as it was.
public final class MP4Exporter: Sendable {
    /// AAC bitrate, in bits per second.
    static let audioBitRate = 160_000
    /// The label of the export's queue: it queues the frames to be drawn and feeds the writer.
    static let queueLabel = "dev.toma.MP4Exporter"
    /// An export whose writer takes no data for this long fails instead of waiting forever.
    static let stallTimeout = 30.0

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    public let project: LoadedProject
    public let document: EditDocument
    public let settings: ExportSettings
    /// The part of the output it exports: all of it when `nil`.
    public let range: ExportRange?
    /// What the frames and the mix read of the project's analysis caches (phase 2 design §10): `.none` in phase 1.
    public let analysis: AnalysisInputs
    /// Makes again the files of the music the mix could not open (`EditedMix.unopenedMusic`: macOS emptied a cache
    /// between the export's preparation and the export), which the export waits for once before it writes anything, and
    /// makes the music again with (plan 3c; `MusicAnalysis.remaking(for:)`). Without, such music is silent.
    public let remakeMusic: MusicRemaking?
    /// For tests: sees each frame's pixel buffer on the export's queue, in frame order, right before it is appended.
    let frameSink: FrameSink?

    /// What a test's `frameSink` is given: the frame's index and the pixel buffer drawn for it.
    typealias FrameSink = @Sendable (_ frame: Int, _ pixelBuffer: CVPixelBuffer) -> Void

    /// Makes the files of the music of `sources` again and gives each one's, by source (one it cannot read left out).
    public typealias MusicRemaking = @Sendable (_ sources: [String]) async throws -> [String: URL]

    /// The export of `range` of `document`'s output, of all of it when `nil`, reading `analysis` of the caches, with the
    /// music `remakeMusic` makes again if the mix finds its file gone.
    public convenience init(
        project: LoadedProject, document: EditDocument, settings: ExportSettings, range: ExportRange? = nil,
        analysis: AnalysisInputs = .none, remakeMusic: MusicRemaking? = nil
    ) {
        self.init(
            project: project, document: document, settings: settings, range: range, frameSink: nil, analysis: analysis,
            remakeMusic: remakeMusic)
    }

    init(
        project: LoadedProject, document: EditDocument, settings: ExportSettings, range: ExportRange? = nil, frameSink: FrameSink?,
        analysis: AnalysisInputs = .none, remakeMusic: MusicRemaking? = nil
    ) {
        self.project = project
        self.document = document
        self.settings = settings
        self.range = range
        self.frameSink = frameSink
        self.analysis = analysis
        self.remakeMusic = remakeMusic
    }

    /// The export of the legacy document (`EditDocument.legacy(for:)`): what phase 0 and 1a export.
    public convenience init(project: LoadedProject, settings: ExportSettings = .init()) {
        self.init(project: project, document: .legacy(for: project), settings: settings)
    }

    /// Writes the video to `destination`, replacing a file already there only once the export is complete,
    /// and returns what it had to leave out: microphone or system audio that could not be read is silence, and
    /// screen or camera video that could not be decoded shows the frame before it.
    ///
    /// Rendering and encoding run on a queue of their own, never on the caller's thread or the main thread, holding one
    /// of the process's decoding slots (`DecodingSlots.shared`): with every slot taken, the export waits for one.
    /// `progress` is called one call at a time, in order, never on the main thread (hop to the main actor
    /// to show the values): from the export's queue while frames are encoded, with values from 0 that never
    /// go down and stay below 1, then once more with exactly 1 from the task running the export, once the
    /// file is in place. Cancel that task to stop: the export ends between two frames and throws
    /// `ExportError.cancelled`. One export at a time per destination: they would share the partial file.
    /// - Throws: `ExportError` (before anything is written: `destinationNotAllowed`, `unsupportedCodec` for a codec with alpha until 4c, `nothingToExport` for a document
    ///   that lasts no time or a range that lasts less than a frame of the video, `noDisplayTrack` for the legacy
    ///   document of a take without screen segments; then `writerFailed`, `cancelled`), or the `RenderError` of a frame
    ///   that could not be drawn.
    @concurrent @discardableResult
    public func export(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportSummary {
        guard !Task.isCancelled else { throw ExportError.cancelled }
        // From here on only the canonical URL is used, so what is written is what was checked.
        guard let destination = Self.canonicalDestination(destination, project: project.package) else {
            throw ExportError.destinationNotAllowed
        }
        // The transparent codecs wait for milestone 4c: nothing is written.
        guard !settings.codec.hasAlpha else { throw ExportError.unsupportedCodec }
        if let refusal = Self.refusal(of: document, of: project) { throw refusal }
        let fps = settings.framesPerSecond
        guard fps > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(fps)") }

        let timeMap = TimeMap(sequence: document.sequence)
        let part = try Self.part(of: range, in: timeMap, framesPerSecond: fps)
        let frameCount = part?.frameCount(fps: fps) ?? timeMap.frameCount(frameRate: fps)

        let renderer = try FrameRenderer(
            project: project, document: document, outputSize: settings.outputSize, frameRate: fps, analysis: analysis)
        let mix = try await Self.remadeMusic(
            of: try await EditedMix.make(project: project, document: document, framesPerSecond: fps, analysis: analysis),
            analysis: analysis, remake: remakeMusic)
        let audioFrames = Self.audioFrames(of: part, frameCount: frameCount, framesPerSecond: fps, mix: mix)
        let audio = mix.hasSound ? try AudioMix(mix: mix, frames: audioFrames) : nil
        guard !Task.isCancelled else { throw ExportError.cancelled }

        let chapters = part.map { Chapters.within(settings.chapters, range: $0.start..<$0.end) } ?? settings.chapters

        let partial = URL(fileURLWithPath: destination.path + ".partial." + settings.codec.fileExtension)
        try Self.removeStalePartial(partial)
        let summary: ExportSummary
        do {
            let session = try ExportSession(
                url: partial, settings: settings, renderer: renderer, start: part?.start ?? 0, frameCount: frameCount, audio: audio,
                chapters: chapters, frameSink: frameSink)
            try await withTaskCancellationHandler {
                try await session.run(progress: progress)
            } onCancel: {
                session.cancel()
            }
            try Self.fullSync(partial)
            guard !Task.isCancelled else { throw ExportError.cancelled }
            try Self.move(partial, to: destination)
            var missingAudio = session.missingAudio, missingVideo = renderer.missingVideo
            if let part {
                let seconds = { (frames: Int64) in Double(frames) / AudioTrackTimeline.sampleRate }
                missingAudio = Self.within(seconds(audioFrames.lowerBound)...seconds(audioFrames.upperBound), missingAudio)
                let end = part.start + TimeMap.frameTime(frameCount, frameRate: fps)
                missingVideo = Self.within((Double(part.start) / 1e9)...(Double(end) / 1e9), missingVideo)
            }
            summary = ExportSummary(
                missingAudio: missingAudio.sorted { ($0.start, $0.end, $0.track) < ($1.start, $1.end, $1.track) },
                missingVideo: missingVideo)
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

    /// The samples the AAC encoder gets when `range` of `document` of `project` (all of it when `nil`) is exported at
    /// `framesPerSecond`, reading `analysis` of the caches: every block of its mix (`AudioMix`), one after the other,
    /// interleaved Float32, over the frames of video rounded to 48 kHz; empty when the export has no audio.
    /// - Throws: what `export` throws before it writes anything (`nothingToExport`, `noDisplayTrack`, `writerFailed`
    ///   for a frame rate that is not positive), or what reading or mixing the audio throws.
    static func mixSamples(
        of project: LoadedProject, document: EditDocument, framesPerSecond: Int, range: ExportRange? = nil,
        analysis: AnalysisInputs = .none, remakeMusic: MusicRemaking? = nil
    ) async throws -> [Float] {
        if let refusal = refusal(of: document, of: project) { throw refusal }
        guard framesPerSecond > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(framesPerSecond)") }
        let timeMap = TimeMap(sequence: document.sequence)
        let part = try part(of: range, in: timeMap, framesPerSecond: framesPerSecond)
        let frameCount = part?.frameCount(fps: framesPerSecond) ?? timeMap.frameCount(frameRate: framesPerSecond)
        let mix = try await remadeMusic(
            of: try await EditedMix.make(project: project, document: document, framesPerSecond: framesPerSecond, analysis: analysis),
            analysis: analysis, remake: remakeMusic)
        guard mix.hasSound else { return [] }
        let frames = audioFrames(of: part, frameCount: frameCount, framesPerSecond: framesPerSecond, mix: mix)
        // Mixing decodes: off the cooperative pool, as the export's own queue does it.
        return try await offTheCooperativePool {
            let audio = try AudioMix(mix: mix, frames: frames)
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

    /// `mix`, made with `analysis`, with its music made again once if it could not open the file of a source
    /// (`EditedMix.unopenedMusic`, a cache macOS emptied since the export's preparation): `remake` makes those files
    /// again and the mix plays them (`EditedMix.with(analysis:)`); still gone, or without `remake`, that music is silent.
    /// - Throws: what `remake` throws (a file that could not be written); `ExportError.cancelled` if it was cancelled.
    static func remadeMusic(of mix: EditedMix, analysis: AnalysisInputs, remake: MusicRemaking?) async throws -> EditedMix {
        let unopened = mix.unopenedMusic
        guard !unopened.isEmpty, let remake else { return mix }
        logger.info("The music of \(unopened.joined(separator: ", "), privacy: .public) was gone: made again before the export")
        let files: [String: URL]
        do {
            files = try await remake(unopened)
        } catch is CancellationError {
            throw ExportError.cancelled
        }
        guard !Task.isCancelled else { throw ExportError.cancelled }
        var remade = analysis
        remade.musicFiles.merge(files) { _, new in new }
        return await mix.with(analysis: remade)
    }

    /// Why `document` of `project` cannot be exported, or `nil` when it can: `nothingToExport` when its clips last no
    /// time (a take that recorded nothing at all falls back to an empty span); otherwise, when the screen of some take the
    /// document shows (`LoadedProject.takesShown(by:)`, `ScreenChoice`) recorded a segment, and without one for any
    /// document but the legacy one, which refuses it as phase 0 and 1a do (`noDisplayTrack`).
    private static func refusal(of document: EditDocument, of project: LoadedProject) -> ExportError? {
        guard TimeMap(sequence: document.sequence).duration > 0 else { return .nothingToExport }
        let screenRecorded = project.takesShown(by: document).contains { shown in
            ScreenChoice.screenTrack(in: shown.take, events: shown.events)?.segments.isEmpty == false
        }
        return screenRecorded || document != .legacy(for: project) ? nil : .noDisplayTrack
    }

    /// The part of the output that the export of `range` draws at `fps`, for a document whose output is `timeMap`: `nil`
    /// for all of it, which `range` is when `nil` or `ExportRange.whole(timeMap)` (the export of 1b:
    /// `TimeMap.frameCount(frameRate:)` frames from 0, one at least); otherwise the range cut to the video, from 0 to where
    /// the whole export's last frame ends (`TimeMap.exportEnd(duration:frameRate:)`, where the export sheet cuts it too
    /// before checking it), so a range up to the end of the video ends with it.
    /// - Throws: `ExportError.nothingToExport` when what is left of the range lasts less than a frame at `fps`
    ///   (`ExportRange.lastsAFrame(fps:)`, the rule the GIF refuses it by).
    private static func part(of range: ExportRange?, in timeMap: TimeMap, framesPerSecond fps: Int) throws -> ExportRange? {
        guard let range, range != .whole(timeMap) else { return nil }
        let videoEnd = TimeMap.exportEnd(duration: timeMap.duration, frameRate: fps)
        let part = ExportRange(start: max(range.start, 0), end: min(range.end, videoEnd))
        guard part.lastsAFrame(fps: fps) else { throw ExportError.nothingToExport }
        return part
    }

    /// The output frames of `mix` that the export of `part` (all of it when `nil`) plays with `frameCount` frames at `fps`.
    private static func audioFrames(of part: ExportRange?, frameCount: Int, framesPerSecond fps: Int, mix: EditedMix) -> Range<Int64> {
        part.map { EditedMix.frames(of: $0, frameCount: frameCount, framesPerSecond: fps) } ?? 0..<mix.totalFrames
    }

    /// The spans of `missing` that overlap `window` (output seconds of the whole video), cut to it, in seconds from its
    /// start. A span that only touches it is left out; one of no length (a single instant) is kept where that instant
    /// is in it.
    private static func within<Span: LeftOutSpan>(_ window: ClosedRange<Double>, _ missing: [Span]) -> [Span] {
        missing.compactMap { span in
            let from = max(span.start, window.lowerBound), to = min(span.end, window.upperBound)
            guard span.start < span.end ? from < to : window.contains(span.start) else { return nil }
            var part = span
            part.start = from - window.lowerBound
            part.end = to - window.lowerBound
            return part
        }
    }

    /// The video settings of `settings`'s codec, tagged Rec.709, whichever encoder VideoToolbox picks (the hardware one
    /// is not required, so every size of the export sheet encodes):
    /// - H.264: High profile, CABAC, at `averageBitRate`, as phase 1 exported;
    /// - HEVC: Main profile (8-bit) at the level the encoder picks, at `videoBitRate` (0.6 × H.264's);
    /// - ProRes 422 and 422 HQ: without a bitrate, which ProRes does not have.
    static func videoSettings(_ settings: ExportSettings) -> [String: Any] {
        let colors: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let codecType: AVVideoCodecType
        let compression: [String: Any]?
        switch settings.codec {
        case .h264:
            codecType = .h264
            compression = [
                AVVideoAverageBitRateKey: settings.averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
            ]
        case .hevc:
            codecType = .hevc
            compression = [
                AVVideoAverageBitRateKey: settings.hevcBitRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
            ]
        case .proRes422:
            codecType = .proRes422
            compression = nil
        case .proRes422HQ:
            codecType = .proRes422HQ
            compression = nil
        case .hevcAlpha:
            codecType = .hevcWithAlpha
            compression = [
                AVVideoAverageBitRateKey: settings.hevcBitRate,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
            ]
        case .proRes4444:
            codecType = .proRes4444
            compression = nil
        }
        var video: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: settings.outputSize.x,
            AVVideoHeightKey: settings.outputSize.y,
            AVVideoColorPropertiesKey: colors,
        ]
        if let compression { video[AVVideoCompressionPropertiesKey] = compression }
        return video
    }

    /// The audio settings of `settings`'s codec for a mix of `channels` channels (1 or 2) at 48 kHz: AAC at 160 kbps,
    /// constant, for H.264 and HEVC, as phase 1 exported; for ProRes, 24-bit integer LPCM, little-endian and interleaved
    /// (phase 2 design §6.8).
    static func audioSettings(_ settings: ExportSettings, channels: Int) -> [String: Any] {
        var audio: [String: Any] = [
            AVSampleRateKey: AudioTrackTimeline.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: AudioMix.channelLayoutData(channels: channels),
        ]
        if settings.codec.isProRes {
            audio[AVFormatIDKey] = kAudioFormatLinearPCM
            audio[AVLinearPCMBitDepthKey] = 24
            audio[AVLinearPCMIsFloatKey] = false
            audio[AVLinearPCMIsBigEndianKey] = false
            audio[AVLinearPCMIsNonInterleaved] = false
        } else {
            audio[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audio[AVEncoderBitRateKey] = audioBitRate
            // Constant: the default strategy spends far less than asked on a quiet or simple signal.
            audio[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        }
        return audio
    }

    /// What the audio of `settings`'s codec is, for its errors: "AAC at 160 kbps" or "24-bit LPCM".
    static func audioName(_ settings: ExportSettings) -> String {
        settings.codec.isProRes ? "24-bit LPCM" : "AAC at \(audioBitRate / 1000) kbps"
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
            if ExportError.isDiskFull(error) { throw ExportError.diskFull }
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
                if ExportError.isDiskFull(error) { throw ExportError.diskFull }
                throw ExportError.writerFailed("cannot replace \(destination.path): \(error)")
            }
        } else {
            guard errno == ENOENT else { throw posixFailure("cannot look at \(destination.path)") }
            guard rename(partial.path, destination.path) == 0 else {
                throw posixFailure("cannot move the export to \(destination.path)")
            }
        }
    }

    /// The failure of a call that set `errno`: `diskFull` for `ENOSPC` and `EDQUOT`.
    private static func posixFailure(_ what: String) -> ExportError {
        if errno == ENOSPC || errno == EDQUOT { return .diskFull }
        return .writerFailed("\(what): \(String(cString: strerror(errno)))")
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
    /// The chapter track's input and its samples, in order: `nil` and none without chapters.
    private let chapterInput: AVAssetWriterInput?
    private let chapterSamples: [CMSampleBuffer]
    private let renderer: FrameRenderer
    private let settings: ExportSettings
    /// The output time of frame 0, in nanoseconds: the start of the range exported, 0 for the whole video.
    private let start: Int64
    private let frameCount: Int
    private let frameSink: MP4Exporter.FrameSink?
    private let queue = DispatchQueue(label: MP4Exporter.queueLabel, qos: .userInitiated)
    private let cancelled = Atomic(false)
    /// Signalled each time a frame drawn ahead is done, to wake the loop.
    private let frameDrawn = DispatchSemaphore(value: 0)

    /// Creates the writer of `url` (the file appears when writing starts) and its inputs: the video, the audio when there
    /// is `audio`, and the chapter track when `chapters` (starts in ns from frame 0) give it a sample.
    init(
        url: URL, settings: ExportSettings, renderer: FrameRenderer, start: Int64, frameCount: Int, audio: AudioMix?,
        chapters: [Chapter], frameSink: MP4Exporter.FrameSink?
    ) throws {
        let codec = settings.codec
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        } catch {
            throw ExportError.writerFailed("cannot create the \(codec.name) writer: \(error)")
        }

        let video = MP4Exporter.videoSettings(settings)
        guard writer.canApply(outputSettings: video, forMediaType: .video) else {
            throw ExportError.writerFailed("\(codec.name) cannot encode \(settings.outputSize.x)×\(settings.outputSize.y) at \(settings.framesPerSecond) fps")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed("the \(codec.name) writer takes no video input") }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputSize.x,
            kCVPixelBufferHeightKey as String: settings.outputSize.y,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        if let audio {
            let encoded = MP4Exporter.audioSettings(settings, channels: audio.channels)
            guard writer.canApply(outputSettings: encoded, forMediaType: .audio) else {
                throw ExportError.writerFailed(
                    "\(MP4Exporter.audioName(settings)) cannot encode \(audio.channels) channel(s) at 48 kHz for \(codec.name)")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoded, sourceFormatHint: audio.formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerFailed("the \(codec.name) writer takes no audio input") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        let duration = TimeMap.frameTime(frameCount, frameRate: settings.framesPerSecond)
        let format = chapters.isEmpty ? nil : try ChapterTrack.formatDescription(for: codec.fileType)
        let samples = try format.map { try ChapterTrack.samples(chapters, duration: duration, format: $0) } ?? []
        if let format, !samples.isEmpty {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            input.mediaTimeScale = ChapterTrack.timescale
            if let tag = settings.chapterLanguage, let language = Locale.Language(identifier: tag).languageCode?.identifier(.alpha3) {
                input.languageCode = language
            }
            guard writer.canAdd(input) else { throw ExportError.writerFailed("the \(codec.name) writer takes no chapter track") }
            writer.add(input)
            let chapterList = AVAssetTrack.AssociationType.chapterList.rawValue
            guard videoInput.canAddTrackAssociation(withTrackOf: input, type: chapterList) else {
                throw ExportError.writerFailed("the \(codec.name) writer cannot tie the chapter track to the video")
            }
            videoInput.addTrackAssociation(withTrackOf: input, type: chapterList)
            chapterInput = input
            chapterSamples = samples
        } else {
            chapterInput = nil
            chapterSamples = []
        }
        self.writer = writer
        self.videoInput = videoInput
        self.audio = audio
        self.renderer = renderer
        self.settings = settings
        self.start = start
        self.frameCount = frameCount
        self.frameSink = frameSink
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
            // The loop pulls the mix's readers, and the video's through the renderer: it holds one of the process's
            // decoding slots while it runs (`DecodingSlots`).
            do {
                try await DecodingSlots.shared.withSlot {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                        self.queue.async {
                            do {
                                try self.encode(progress: progress)
                                done.resume()
                            } catch {
                                done.resume(throwing: error)
                            }
                        }
                    }
                }
            } catch is CancellationError {
                throw ExportError.cancelled  // while it waited for a slot, before writing anything
            }
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(settings.framesPerSecond)))
            await writer.finishWriting()
            guard writer.status == .completed else { throw failure() }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// The loop: feeds whichever input takes data, polling while none does (woken early when a frame is drawn). The
    /// writer interleaves the tracks by holding back the input that is ahead (`isReadyForMoreMediaData`), so an input
    /// that takes data is always fed: holding one back here too could leave them waiting for each other. The chapter
    /// track, when there is one, is fed as the audio is, a sample at a time, and marked finished with its last.
    ///
    /// Video: up to `framesInFlight` frames are queued to be drawn (`FrameRenderer.render(at:into:completion:)`), and the
    /// oldest goes to the writer once it is drawn; drawing one fails the export. With `framesInFlight` 1, each frame is
    /// drawn and waited for in turn.
    private func encode(progress: @Sendable (Double) -> Void) throws {
        guard writer.startWriting() else { throw failure() }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed("the writer has no pixel buffer pool") }
        var queued = 0  // frames queued to be drawn
        var appended = 0
        var drawing: [DrawnFrame] = []  // queued and not appended yet, in frame order
        var videoDone = false
        var audioDone = audioInput == nil
        var chaptersAppended = 0
        var chaptersDone = chapterInput == nil
        var idleSince: HostTime?
        while !(videoDone && audioDone && chaptersDone) {
            if cancelled.load(ordering: .relaxed) { throw ExportError.cancelled }
            var fed = false
            let appendedBefore = appended
            if !videoDone, settings.framesInFlight <= 1 {
                if videoInput.isReadyForMoreMediaData {
                    let pixelBuffer = try makePixelBuffer(from: pool)
                    try failIfAsked(appended)
                    try renderer.render(at: time(ofFrame: appended), into: pixelBuffer)
                    try append(pixelBuffer, frame: appended)
                    appended += 1
                    fed = true
                }
            } else if !videoDone {
                if let oldest = drawing.first, let drawn = oldest.result {
                    try drawn.get()
                    if videoInput.isReadyForMoreMediaData {
                        try failIfAsked(appended)
                        try append(oldest.pixelBuffer, frame: oldest.index)
                        drawing.removeFirst()
                        appended += 1
                        fed = true
                    }
                }
                while queued < frameCount, drawing.count < settings.framesInFlight {
                    let frame = DrawnFrame(index: queued, pixelBuffer: try makePixelBuffer(from: pool))
                    // The handler only notes it: the frame is appended from this queue.
                    renderer.render(at: time(ofFrame: queued), into: frame.pixelBuffer) { [frameDrawn] error in
                        frame.finish(error)
                        frameDrawn.signal()
                    }
                    drawing.append(frame)
                    queued += 1
                    fed = true
                }
            }
            if appended > appendedBefore {
                progress(Double(appended) / Double(frameCount + 1))
                if appended == frameCount {
                    videoInput.markAsFinished()
                    videoDone = true
                }
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
            if !chaptersDone, let chapterInput, chapterInput.isReadyForMoreMediaData {
                try waitUntilReady(chapterInput)
                guard chapterInput.append(chapterSamples[chaptersAppended]) else { throw failure() }
                chaptersAppended += 1
                if chaptersAppended == chapterSamples.count {
                    chapterInput.markAsFinished()
                    chaptersDone = true
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
            _ = frameDrawn.wait(timeout: .now() + .milliseconds(1))
        }
    }

    /// The output seconds of frame `frame`: `start + TimeMap.frameTime(frame, frameRate: fps)` (`ExportRange.frameTime`),
    /// which the renderer rounds back to those nanoseconds exactly (they are far below 2⁵¹). Off the grid of the
    /// export's frame rate (a range that starts between its frames), the renderer decodes each frame's when it is asked
    /// for, not ahead (`FrameRenderer.render(at:into:completion:)`): the same bytes.
    private func time(ofFrame frame: Int) -> Double {
        Double(start + TimeMap.frameTime(frame, frameRate: settings.framesPerSecond)) / 1e9
    }

    /// A buffer of the writer's pool for a frame, tagged as what the file says: the frame's values are encoded as they
    /// are, nothing converts them.
    private func makePixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw ExportError.writerFailed("no pixel buffer from the pool (CVReturn \(status))")
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pixelBuffer
    }

    /// Throws as the writer would once `appended` frames are encoded, if the settings ask for it (`failAfterFrames`).
    private func failIfAsked(_ appended: Int) throws {
        if let limit = settings.failAfterFrames, appended >= limit {
            throw ExportError.writerFailed("failing after \(limit) frames, as the settings ask")
        }
    }

    /// Appends `pixelBuffer`, drawn, as frame `frame` at `frame / fps`, once the writer takes it.
    private func append(_ pixelBuffer: CVPixelBuffer, frame: Int) throws {
        try waitUntilReady(videoInput)  // drawing took time: the writer may have failed meanwhile
        frameSink?(frame, pixelBuffer)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(settings.framesPerSecond))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else { throw failure() }
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

    /// The writer's error as `writerFailed`, naming the codec, or `diskFull` when that is what it says.
    private func failure() -> ExportError {
        if let error = writer.error, ExportError.isDiskFull(error) { return .diskFull }
        let codec = settings.codec.name
        return .writerFailed(
            writer.error.map { "the \(codec) writer failed: \(String(describing: $0))" }
                ?? "the \(codec) writer stopped (status \(writer.status.rawValue))")
    }
}

/// A frame queued to be drawn ahead into a buffer of the writer's pool: how drawing it ended, once it did, is set from
/// the renderer's completion, on another thread.
private final class DrawnFrame: @unchecked Sendable {
    let index: Int
    let pixelBuffer: CVPixelBuffer
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?

    init(index: Int, pixelBuffer: CVPixelBuffer) {
        self.index = index
        self.pixelBuffer = pixelBuffer
    }

    /// `nil` while it is being drawn; then whether it was.
    var result: Result<Void, any Error>? { lock.withLock { outcome } }

    func finish(_ error: (any Error)?) {
        lock.withLock { outcome = error.map { .failure($0) } ?? .success(()) }
    }
}

/// A span of the export's summary: what was left out, from `start` to `end` in output seconds.
private protocol LeftOutSpan {
    var start: Double { get set }
    var end: Double { get set }
}

extension MissingAudio: LeftOutSpan {}
extension MissingVideo: LeftOutSpan {}

extension ExportError {
    /// Whether `error` says the disk is full: AVFoundation's `diskFull`, `ENOSPC` or `EDQUOT`, Foundation's out of
    /// space, or an error whose underlying error says so.
    static func isDiskFull(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case AVFoundationErrorDomain where error.code == AVError.Code.diskFull.rawValue: return true
        case NSPOSIXErrorDomain where error.code == Int(ENOSPC) || error.code == Int(EDQUOT): return true
        case NSCocoaErrorDomain where error.code == NSFileWriteOutOfSpaceError: return true
        default: break
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isDiskFull) ?? false
    }
}
