// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Metal
import ProjectFormat
import Synchronization

/// What a renderer draws the imported clips of the sequence with (phase 3 design §5.4, plan 3a decision 12), besides the
/// take's videos: a reader for each file of `assets/` a frame shows (`AssetFrameReader`), by a reader id that no track of a
/// take has (`asset:<path>`), one for every clip of that file; decoded with the take's videos (`FrameRenderer.videos(of:)`,
/// ahead by its prefetchers too) and handed back when the frame is drawn (`FrameRenderer.mediaTextures(for:decoded:…)`),
/// with how a player turns the file's frames upright (`MediaOrientations`, noted when its track loads), and copied with
/// mipmaps for a style that samples the screens with them.
///
/// - **Made when asked for, let go when not needed.** A reader is made the first time a frame asks for it, and kept while
///   the frames drawn and those coming show its file; whoever draws lets go of the others (`release(keeping:)`, from
///   `FrameRenderer.releaseVideos(keeping:)`): their `AVAssetReader`s and the frames they hold go, and a reader is made
///   again when a frame shows the file again.
/// - **A few at once.** At most `decodesAtOnce` of its readers open or decode at once (`gate`), whichever thread decodes:
///   the clips the next second shows start decoding then, two at a time.
/// - **Tried again.** A file that gives no reader (gone, a link, not a video of `assets/`) is looked for again the next
///   time a frame asks, drawing the background alone meanwhile; one whose reader gives no frame at all (AVFoundation could
///   not open it or read it through) gets a new reader once `retryInterval` seconds have passed since.
///
/// With no clip in the sequence, nothing is made. Called from any thread.
final class MediaClipResources: Sendable {
    /// How many of a renderer's clips open or decode at once at most.
    static let decodesAtOnce = 2
    /// Seconds after which a file whose reader gave no frame is read again by a new reader.
    static let retryInterval = 2.0

    /// Where the clips are read from (`ProjectPackage.mediaAsset(_:as:)`).
    let package: ProjectPackage
    /// Around every decode of a clip's reader: `decodesAtOnce` at most.
    let gate = DecodeGate(width: MediaClipResources.decodesAtOnce)
    /// How each file's frames are turned upright, once its track is loaded.
    let orientations = MediaOrientations()
    /// The copies with mipmaps of the clips' frames a style that samples with mipmaps draws (`MediaClipLayer.mipmapped`).
    let mipmappedCopies: MipmappedCopies
    private let state = Mutex(State())

    private struct State {
        /// The readers kept, by their reader id.
        var readers: [String: TrackFrameReader] = [:]
        /// The reader of each id let go last while none is kept, its `AVAssetReader` closed: what it could not read is
        /// still said (`notes(for:)`), so a clip an export went past is still missing video.
        var released: [String: TrackFrameReader] = [:]
        /// The spans earlier readers of each id that gave frames could not decode (`TrackFrameReader.gaps`), gathered
        /// from those let go before the last.
        var gaps: [String: [TrackFrameReader.Gap]] = [:]
        /// `retryInterval`, less for tests.
        var retryInterval = MediaClipResources.retryInterval
        /// Called with each reader made, before it reads: for tests.
        var made: (@Sendable (TrackFrameReader) -> Void)?

        /// Keeps what `reader`, of `id`, could not decode, if it gave frames (`gaps`): the spans of one that gave none
        /// are only of that failure, which a newer reader leaves behind.
        mutating func gather(_ reader: TrackFrameReader, of id: String) {
            guard reader.unusableSince == nil else { return }
            var known = gaps[id] ?? []
            for gap in reader.gaps where !known.contains(gap) { known.append(gap) }
            gaps[id] = known
        }

        /// `reader` kept as `id`'s from now on: the one let go before it, gathered (`gather`).
        mutating func keep(_ reader: TrackFrameReader, as id: String) {
            if let released = released.removeValue(forKey: id) { gather(released, of: id) }
            readers[id] = reader
        }
    }

    init(device: any MTLDevice, package: ProjectPackage) {
        self.package = package
        mipmappedCopies = MipmappedCopies(device: device)
    }

    /// The reader of `id`, a clip's reader id (`AssetFrameReader.readerID(of:)`): the one kept, or one made now (kept from
    /// then on), also in place of one that has given no frame for `retryInterval` seconds or more (while the file gives
    /// one), its `trackID` `id`; `nil` for any other id, and while the file gives none
    /// (`AssetFrameReader.make(asset:id:package:orientations:)`).
    func reader(for id: String) -> TrackFrameReader? {
        guard let asset = AssetFrameReader.asset(ofReaderID: id) else { return nil }
        return state.withLock { state in
            let kept = state.readers[id]
            if let kept {
                guard let since = kept.unusableSince, HostTime.now().seconds(since: since) >= state.retryInterval else {
                    return kept
                }
            }
            guard let reader = AssetFrameReader.make(asset: asset, id: id, package: package, orientations: orientations) else {
                return kept
            }
            state.made?(reader)
            // One that gave no frame is let go as it is: its spans are of that failure alone.
            state.keep(reader, as: id)
            return reader
        }
    }

    /// The reader of `id` kept, without making one.
    func existingReader(for id: String) -> TrackFrameReader? {
        state.withLock { $0.readers[id] }
    }

    /// Stops keeping the readers whose ids are not in `kept`, and returns them, for the caller to let go
    /// (`TrackFrameReader.letGo()`). What each could not read stays known (`notes(for:)`): it is the last let go of its
    /// id, and the one let go before it is gathered.
    func release(keeping kept: Set<String>) -> [TrackFrameReader] {
        state.withLock { state in
            let gone = state.readers.filter { !kept.contains($0.key) }
            for (id, reader) in gone {
                state.readers[id] = nil
                if let before = state.released.updateValue(reader, forKey: id) { state.gather(before, of: id) }
            }
            return Array(gone.values)
        }
    }

    /// What the readers of `id` could not read, kept or let go: whether the latest gives no frame at all, with why (the
    /// reason of its last span), and the spans the readers that gave frames could not decode (in the file's time). Waits
    /// for a frame the kept reader is decoding.
    func notes(for id: String) -> (unusable: MissingVideo.Reason?, gaps: [TrackFrameReader.Gap]) {
        let (latest, gathered) = state.withLock { state in (state.readers[id] ?? state.released[id], state.gaps[id] ?? []) }
        guard let latest else { return (nil, gathered) }
        let gaps = latest.gaps
        if latest.unusableSince != nil { return (gaps.last?.reason ?? .unreadable, gathered) }
        return (nil, gathered + gaps.filter { !gathered.contains($0) })
    }

    /// How a player turns the frames of the clip `asset` upright, as noted when its track loaded; as decoded before.
    func orientation(of asset: String) -> MediaOrientation {
        orientations.orientation(of: asset) ?? .upright
    }

    /// How many readers are kept: for tests.
    var readerCount: Int { state.withLock { $0.readers.count } }

    /// Called with each reader made, before it reads (to load its track another way, say): for tests.
    var readerMade: (@Sendable (TrackFrameReader) -> Void)? {
        get { state.withLock { $0.made } }
        set { state.withLock { $0.made = newValue } }
    }

    /// `retryInterval`, which tests make shorter.
    var retryInterval: Double {
        get { state.withLock { $0.retryInterval } }
        set { state.withLock { $0.retryInterval = newValue } }
    }
}

extension FrameRenderer {
    /// The (reader id, file time) of the imported clip's frame `frame` shows (`AssetFrameReader.readerID(of:)`, at its
    /// `fileTime` as host time from 0), after the camera's look's (`videos(of:)`'s order): none without one.
    func mediaVideos(of frame: RenderFrame) -> [DecodedKey] {
        guard let media = frame.media else { return [] }
        return [DecodedKey(trackID: AssetFrameReader.readerID(of: media.asset), time: media.sourceTime)]
    }

    /// The reader of `id`, a video `mediaVideos(of:)` or `annotationVideos(of:)` gives (a file of `assets/`), made when
    /// asked for (`MediaClipResources.reader(for:)`); `nil` for any other id, and for a file that gives none.
    func mediaReader(for id: String) -> TrackFrameReader? {
        mediaResources.reader(for: id)
    }

    /// Whether `track` is a clip's (`AssetFrameReader.readerID(of:)`), which no take's track is.
    static func isMedia(_ track: TrackKey) -> Bool {
        track.take == nil && AssetFrameReader.asset(ofReaderID: track.track) != nil
    }

    /// What `frame`'s imported clip is drawn with (`LayerTextures.media`): the frame `decoded` gives for its video of
    /// `mediaVideos(of:)`, which the renderer keeps alive until `commandBuffer` completes, or, for a layer sampled with
    /// mipmaps (`MediaClipLayer.mipmapped`), a copy of it with its mipmaps made in `commandBuffer`
    /// (`MipmappedCopies`); and how its file's frames are turned upright. `nil` without a clip, and without its frame (a
    /// file that cannot be read): the background alone. Called with the renderer's lock held.
    /// - Throws: `RenderError.metalResourceUnavailable` when Metal cannot make the copy, having encoded nothing: the frame
    ///   is not drawn, as a screen's.
    func mediaTextures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> MediaClipTextures? {
        guard let media = frame.media,
              let texture = try decoded(AssetFrameReader.readerID(of: media.asset), media.sourceTime)?.texture
        else { return nil }
        let orientation = mediaResources.orientation(of: media.asset)
        guard media.mipmapped else { return MediaClipTextures(frame: texture, orientation: orientation) }
        let copy = try mediaResources.mipmappedCopies.copy(
            of: texture, region: MTLRegionMake2D(0, 0, texture.width, texture.height), commandBuffer: commandBuffer)
        return MediaClipTextures(frame: copy, orientation: orientation, mipmapped: true)
    }

    /// The imported clips of the sequence that cannot be drawn, in output seconds (`missingVideo`'s): the whole of each clip
    /// whose file the package's safe reader does not give (`.fileMissing`: gone, a link, not a video of `assets/`) or
    /// whose latest reader gives no frame at all (its reason); otherwise each span of the file its readers could not
    /// decode, where a clip shows it: of those kept and of those let go (`MediaClipResources.notes(for:)`), so a clip the
    /// frames drawn went past is still listed. By the clip's reader id (`AssetFrameReader.readerID(of:)`) as the track and
    /// its path as the file. No reader is made here.
    func mediaMissingVideo(of scene: FrameEvaluator) -> [MissingVideo] {
        let timeMap = scene.timeMap, sequence = scene.document.sequence
        guard sequence.count == timeMap.clipOutputStarts.count else { return [] }
        var missing: [MissingVideo] = []
        for (k, clip) in sequence.enumerated() {
            guard case let .media(media)? = clip.content else { continue }
            let start = timeMap.clipOutputStarts[k], duration = TimeMap.outputDuration(of: clip)
            guard duration > 0, media.end > media.start else { continue }
            let id = AssetFrameReader.readerID(of: media.asset), speed = ClipSpeed.clamped(media.speed)
            func span(_ from: Int64, _ to: Int64, _ reason: MissingVideo.Reason) -> MissingVideo {
                MissingVideo(track: id, file: media.asset, start: Double(from) / 1e9, end: Double(to) / 1e9, reason: reason)
            }
            /// The output instant within the clip that shows file instant `x` (from its start), held to the clip.
            func output(_ x: Int64) -> Int64 {
                let into = (Double(x &- media.start) / speed).rounded()
                return start + (into.isFinite ? Int64(min(max(into, 0), Double(duration))) : 0)
            }
            guard package.mediaAsset(media.asset, as: .video) != nil else {
                missing.append(span(start, start + duration, .fileMissing))
                continue
            }
            let (unusable, gaps) = mediaResources.notes(for: id)
            if let unusable {
                missing.append(span(start, start + duration, unusable))
                continue
            }
            for gap in gaps {
                let from = Int64(clamping: gap.start.nanoseconds), to = Int64(clamping: gap.end.nanoseconds)
                if from == to {
                    if (media.start..<media.end).contains(from) { missing.append(span(output(from), output(from), gap.reason)) }
                } else if max(from, media.start) < min(to, media.end) {
                    missing.append(span(output(max(from, media.start)), output(min(to, media.end)), gap.reason))
                }
            }
        }
        return missing
    }
}
