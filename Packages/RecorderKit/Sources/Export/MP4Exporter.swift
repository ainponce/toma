// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ProjectFormat
import Render
import Accelerate
import Synchronization
import VideoToolbox
import os

/// Exports a take as a video: H.264 High video tagged Rec.709 and, as one AAC track, the microphone mixed with system
/// audio, in an MP4; or, by `ExportSettings.codec` (phase 2 design §6.8), HEVC Main 8-bit (`hvc1`) with that AAC in an
/// MP4, or ProRes 422 or 422 HQ with the mix as 24-bit integer LPCM at 48 kHz in a QuickTime movie. The codec changes how
/// the frames and the mix are encoded, never what they are: every codec is given the same pixels and the same samples.
///
/// The codecs with alpha (`ExportCodec.hasAlpha`, phases 4 and 5 design §7.1, plan 4c decision 5), HEVC with alpha with
/// that AAC and ProRes 4444 with that LPCM, both in a QuickTime movie, are given the transparent render instead
/// (`FrameRenderer(…, transparentBackground: true)`, the preview's with its checkerboard): nothing where the stage's
/// background was, everything else as drawn, with the alpha premultiplied as the compositor draws it, unconverted, and the
/// buffers and the encoder told so (`kCVImageBufferAlphaChannelModeKey`, `kVTCompressionPropertyKey_AlphaChannelMode`).
/// ProRes 4444 is given each frame widened to 16-bit RGBA, exactly (`widen(_:into:)`), so what is opaque in the frame is
/// opaque in the file. Any other codec gets the frames, the buffers' attachments and the writer's settings it got before
/// 4c.
///
/// With `ExportSettings.editorMetadata`, the export of the whole video also writes the files for external editors next to
/// it (`ExternalEditorExport.sidecarURLs(of:)`, design §7.2, plan 4c decision 8): the bytes `ExternalEditorExport.write`
/// makes of the finished video, worked out from what the export knows of it (its size, frame rate, frames, audio and
/// alpha, and its URL as given) once it is encoded and before it is moved into place, and written, each atomically, once
/// it is there. Their places are checked as the destination's before anything is written, and files of their names
/// already there are never replaced unless `ExportSettings.replacesEditorFiles` says so (`ExportError.editorFilesExist`).
/// The export of a range ignores it.
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
/// `mov` for ProRes and the codecs with alpha), and moves that into place at the end, replacing an existing file in one
/// step. If it fails or is cancelled, the partial file is removed and the destination is as it was.
public final class MP4Exporter: Sendable {
    /// AAC bitrate, in bits per second.
    static let audioBitRate = 160_000
    /// The label of the export's queue: it queues the frames to be drawn and feeds the writer.
    static let queueLabel = "dev.toma.MP4Exporter"
    /// The label of the queue that samples the frames for the files for editors.
    static let sidecarQueueLabel = "dev.toma.MP4Exporter.editorFiles"
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
    /// For tests: called on the thread that samples the frames for the files for editors, each time it looks at whether
    /// the export was cancelled (`EditorTimeline.cancelCheckEvery`), right before it looks.
    let whileSampling: (@Sendable () -> Void)?

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
        analysis: AnalysisInputs = .none, remakeMusic: MusicRemaking? = nil, whileSampling: (@Sendable () -> Void)? = nil
    ) {
        self.project = project
        self.document = document
        self.settings = settings
        self.range = range
        self.frameSink = frameSink
        self.analysis = analysis
        self.remakeMusic = remakeMusic
        self.whileSampling = whileSampling
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
    ///
    /// With the files for editors (`ExportSettings.editorMetadata`, the whole video), the frames are sampled for them once
    /// the video is encoded (progress stays below 1 meanwhile; cancelling stops it between two frames, leaving nothing),
    /// and they are written once the video is in place: a failure writing them (a full disk) throws with the video
    /// already there, and neither file. Files of their names already there are replaced only with
    /// `ExportSettings.replacesEditorFiles`; otherwise the export throws `editorFilesExist`, before it writes anything and
    /// again, should one appear meanwhile, right before the video is moved into place.
    /// - Throws: `ExportError` (before anything is written: `destinationNotAllowed`, also for files for editors that
    ///   could not go next to the video, `editorFilesExist`, `nothingToExport` for a document
    ///   that lasts no time or a range that lasts less than a frame of the video, `noDisplayTrack` for the legacy
    ///   document of a take without screen segments; then `writerFailed`, `cancelled`, `diskFull`), or the `RenderError` of
    ///   a frame that could not be drawn.
    @concurrent @discardableResult
    public func export(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportSummary {
        guard !Task.isCancelled else { throw ExportError.cancelled }
        // The files for editors name the video as the caller does, as `ExternalEditorExport.write` does.
        let video = destination
        // From here on only the canonical URL is used, so what is written is what was checked.
        guard let destination = Self.canonicalDestination(destination, project: project.package) else {
            throw ExportError.destinationNotAllowed
        }
        if let refusal = Self.refusal(of: document, of: project) { throw refusal }
        let fps = settings.framesPerSecond
        guard fps > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(fps)") }

        let timeMap = TimeMap(sequence: document.sequence)
        let part = try Self.part(of: range, in: timeMap, framesPerSecond: fps)
        let frameCount = part?.frameCount(fps: fps) ?? timeMap.frameCount(frameRate: fps)

        // The files for editors describe the whole video alone (plan 4c decision 8).
        var sidecars: (fcpxml: URL, metadata: URL)?
        if settings.editorMetadata, part == nil {
            guard let places = Self.sidecars(of: destination, project: project.package) else { throw ExportError.destinationNotAllowed }
            try Self.refuseToReplace(places, unless: settings.replacesEditorFiles)
            sidecars = places
        }

        let renderer = try FrameRenderer(
            project: project, document: document, outputSize: settings.outputSize, frameRate: fps, analysis: analysis,
            transparentBackground: settings.transparent)
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
        var editorFiles: (fcpxml: Data, metadata: Data)?
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
            if sidecars != nil {
                // Before the video is in place: what costs time and can fail is done while it can still be undone.
                editorFiles = try await self.editorFiles(of: VideoFacts(
                    url: video, size: settings.outputSize, frameRate: fps, frameCount: frameCount,
                    audioChannels: audio?.channels, hasAlpha: settings.codec.hasAlpha))
                guard !Task.isCancelled else { throw ExportError.cancelled }
            }
            // Again, right before anything is in place: one may have appeared while the video was encoded.
            if let sidecars { try Self.refuseToReplace(sidecars, unless: settings.replacesEditorFiles) }
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
        if let sidecars, let editorFiles {
            try ExternalEditorExport.store(editorFiles, fcpxml: sidecars.fcpxml, metadata: sidecars.metadata)
        }
        progress(1)
        return summary
    }

    /// Where the files for external editors of the video at `destination` (canonical) go
    /// (`ExternalEditorExport.sidecarURLs(of:)`), each checked as the destination is (`canonicalDestination`); `nil`,
    /// refused, for one that could not be written there or that is the video itself (compared without case, as APFS
    /// usually does).
    private static func sidecars(of destination: URL, project: ProjectPackage) -> (fcpxml: URL, metadata: URL)? {
        let named = ExternalEditorExport.sidecarURLs(of: destination)
        guard let fcpxml = canonicalDestination(named.fcpxml, project: project),
              let metadata = canonicalDestination(named.metadata, project: project)
        else { return nil }
        let paths = [destination, fcpxml, metadata].map { $0.path.lowercased() }
        return Set(paths).count == paths.count ? (fcpxml, metadata) : nil
    }

    /// Throws `ExportError.editorFilesExist` naming those of `sidecars` already there, unless `replacing`.
    private static func refuseToReplace(_ sidecars: (fcpxml: URL, metadata: URL), unless replacing: Bool) throws {
        guard !replacing else { return }
        let there = [sidecars.fcpxml, sidecars.metadata].filter { url in
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        if !there.isEmpty { throw ExportError.editorFilesExist(there) }
    }

    /// The bytes of the files for external editors of the video `video` describes (`ExternalEditorExport.files`), made
    /// on a queue of their own: they sample every frame, which never holds the caller's thread nor one of Swift's
    /// cooperative pool. Cancelling the task stops the sampling between two frames.
    /// - Throws: `ExportError.cancelled` once cancelled, or what `ExternalEditorExport.files` throws.
    private func editorFiles(of video: VideoFacts) async throws -> (fcpxml: Data, metadata: Data) {
        let cancellation = CancellationFlag()
        let (project, document, settings, whileSampling) = (project, document, settings, whileSampling)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: Self.sidecarQueueLabel, qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try ExternalEditorExport.files(project: project, document: document, video: video, settings: settings) {
                            whileSampling?()
                            return cancellation.isCancelled
                        }
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
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
    /// - ProRes 422 and 422 HQ: without a bitrate, which ProRes does not have;
    /// - HEVC with alpha: its colour at HEVC's bitrate (`hevcBitRate`), its alpha premultiplied, as the compositor draws it,
    ///   and nearly lossless (`TargetQualityForAlpha` 1, so its edges have no steps; plan 4c decision 5);
    /// - ProRes 4444: as ProRes 422, its alpha kept (`PreserveAlphaChannel`, on by default) and premultiplied, as the
    ///   buffers say (`makePixelBuffer`), which are given to it in 16 bits (`sourcePixelFormat(of:)`).
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
                kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha as String,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0,
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

    /// The pixel format the writer of `codec` is given: the BGRA every frame is drawn in, but for ProRes 4444, which is
    /// given it widened to 16-bit RGBA (`widen(_:into:)`): its encoder widens an 8-bit alpha by × 256, so 255 would be
    /// 65 280 in the file, never quite opaque.
    static func sourcePixelFormat(of codec: ExportCodec) -> OSType {
        codec == .proRes4444 ? kCVPixelFormatType_64RGBALE : kCVPixelFormatType_32BGRA
    }

    /// Copies `drawn`, BGRA, into `wide`, 16-bit RGBA of the same size (`kCVPixelFormatType_64RGBALE`), each value
    /// × 257 (65 535 / 255, exactly), with `drawn`'s attachments: the same pixels, 0 still 0 and 255 now 65 535.
    /// - Throws: `ExportError.writerFailed` for buffers of other formats or sizes, or one vImage cannot convert.
    static func widen(_ drawn: CVPixelBuffer, into wide: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(drawn), height = CVPixelBufferGetHeight(drawn)
        guard CVPixelBufferGetPixelFormatType(drawn) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(wide) == kCVPixelFormatType_64RGBALE,
              CVPixelBufferGetWidth(wide) == width, CVPixelBufferGetHeight(wide) == height
        else { throw ExportError.writerFailed("cannot widen a frame of another format or size to 16 bits") }
        CVPixelBufferLockBaseAddress(drawn, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(drawn, .readOnly) }
        CVPixelBufferLockBaseAddress(wide, [])
        defer { CVPixelBufferUnlockBaseAddress(wide, []) }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(drawn), height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(drawn))
        var destination = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(wide), height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(wide))
        // Each value v becomes (v × 65 535 + 127) / 255 = v × 257; destination channel i is source channel map[i]:
        // RGBA from BGRA.
        let map: [UInt8] = [2, 1, 0, 3], background: [UInt16] = [0, 0, 0, 0]
        let error = vImageConvert_ARGB8888ToARGB16U(&source, &destination, map, 0, background, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw ExportError.writerFailed("cannot widen a frame to 16 bits (vImage \(error))") }
        CVBufferPropagateAttachments(drawn, wide)
    }

    /// The audio settings of `settings`'s codec for a mix of `channels` channels (1 or 2) at 48 kHz: AAC at 160 kbps,
    /// constant, for H.264, HEVC and HEVC with alpha, as phase 1 exported; for ProRes (422, 422 HQ and 4444), 24-bit
    /// integer LPCM, little-endian and interleaved (phase 2 design §6.8).
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
    /// The BGRA buffers the frames are drawn into when the writer is given another format (ProRes 4444,
    /// `MP4Exporter.sourcePixelFormat(of:)`), each widened into one of the adaptor's before it is appended; `nil` when the
    /// frames are drawn into the adaptor's own, as every other codec's are.
    private let drawingPool: CVPixelBufferPool?
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
        let drawnBuffers: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputSize.x,
            kCVPixelBufferHeightKey as String: settings.outputSize.y,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let source = MP4Exporter.sourcePixelFormat(of: codec)
        if source == kCVPixelFormatType_32BGRA {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: drawnBuffers)
            drawingPool = nil
        } else {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: source,
                kCVPixelBufferWidthKey as String: settings.outputSize.x,
                kCVPixelBufferHeightKey as String: settings.outputSize.y,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, drawnBuffers as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                throw ExportError.writerFailed("cannot make the buffers the \(codec.name) frames are drawn into (CVReturn \(status))")
            }
            drawingPool = pool
        }

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
        guard let writerPool = adaptor.pixelBufferPool else { throw ExportError.writerFailed("the writer has no pixel buffer pool") }
        let pool = drawingPool ?? writerPool
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
    /// are, nothing converts them. With a codec with alpha, its alpha is premultiplied, as the compositor draws it and the
    /// encoder is told (`MP4Exporter.videoSettings`): VideoToolbox fails on a buffer that says otherwise. Any other codec's
    /// buffers are tagged as before 4c: the three Rec. 709 tags, no alpha mode.
    private func makePixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw ExportError.writerFailed("no pixel buffer from the pool (CVReturn \(status))")
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        if settings.codec.hasAlpha {
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        }
        return pixelBuffer
    }

    /// Throws as the writer would once `appended` frames are encoded, if the settings ask for it (`failAfterFrames`).
    private func failIfAsked(_ appended: Int) throws {
        if let limit = settings.failAfterFrames, appended >= limit {
            throw ExportError.writerFailed("failing after \(limit) frames, as the settings ask")
        }
    }

    /// Appends `pixelBuffer`, drawn, as frame `frame` at `frame / fps`, once the writer takes it: as it is, or widened
    /// into a buffer of the writer's pool when the frames are drawn into buffers of their own (`drawingPool`).
    private func append(_ pixelBuffer: CVPixelBuffer, frame: Int) throws {
        try waitUntilReady(videoInput)  // drawing took time: the writer may have failed meanwhile
        frameSink?(frame, pixelBuffer)
        var encoded = pixelBuffer
        if drawingPool != nil {
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed("the writer has no pixel buffer pool") }
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            guard status == kCVReturnSuccess, let wide = created else {
                throw ExportError.writerFailed("no pixel buffer from the pool (CVReturn \(status))")
            }
            try MP4Exporter.widen(pixelBuffer, into: wide)
            encoded = wide
        }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(settings.framesPerSecond))
        guard adaptor.append(encoded, withPresentationTime: time) else { throw failure() }
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
