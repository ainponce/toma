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
///   `FrameRenderer.releaseMedia(keeping:)`): their `AVAssetReader`s and the frames they hold go, and a reader is made
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
        /// `retryInterval`, less for tests.
        var retryInterval = MediaClipResources.retryInterval
    }

    init(device: any MTLDevice, package: ProjectPackage) {
        self.package = package
        mipmappedCopies = MipmappedCopies(device: device)
    }

    /// The reader of `id`, a clip's reader id (`AssetFrameReader.readerID(of:)`): the one kept, or one made now (kept from
    /// then on), also in place of one that has given no frame for `retryInterval` seconds or more (while the file gives
    /// one); `nil` for any other id, and while the file gives none (`AssetFrameReader.make(asset:package:orientations:)`).
    func reader(for id: String) -> TrackFrameReader? {
        guard let asset = AssetFrameReader.asset(ofReaderID: id) else { return nil }
        return state.withLock { state in
            let kept = state.readers[id]
            if let kept {
                guard let since = kept.unusableSince, HostTime.now().seconds(since: since) >= state.retryInterval else {
                    return kept
                }
            }
            guard let reader = AssetFrameReader.make(asset: asset, package: package, orientations: orientations) else {
                return kept
            }
            state.readers[id] = reader
            return reader
        }
    }

    /// The reader of `id` kept, without making one.
    func existingReader(for id: String) -> TrackFrameReader? {
        state.withLock { $0.readers[id] }
    }

    /// Stops keeping the readers whose ids are not in `kept`, and returns them, for the caller to let go
    /// (`TrackFrameReader.letGo()`).
    func release(keeping kept: Set<String>) -> [TrackFrameReader] {
        state.withLock { state in
            let gone = state.readers.filter { !kept.contains($0.key) }
            for id in gone.keys { state.readers[id] = nil }
            return Array(gone.values)
        }
    }

    /// How a player turns the frames of the clip `asset` upright, as noted when its track loaded; as decoded before.
    func orientation(of asset: String) -> MediaOrientation {
        orientations.orientation(of: asset) ?? .upright
    }

    /// How many readers are kept: for tests.
    var readerCount: Int { state.withLock { $0.readers.count } }

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

    /// Lets go of the imported clips' readers and prefetchers that `kept` does not name (`asset:` ids; the tracks of the
    /// takes and the masks are not touched): each prefetcher is reset and dropped, and each reader's `AVAssetReader` let go
    /// with the frames it holds, off the caller's thread (`TrackFrameReader.letGo()`, which waits for a frame being
    /// decoded). A frame that shows the file again makes them again. Returns the tracks let go, for whoever keeps their
    /// frames (`PreviewEngine`).
    @discardableResult
    func releaseMedia(keeping kept: Set<TrackKey>) -> [TrackKey] {
        let (released, readers) = withAhead { releaseMedia(keeping: kept, in: &$0) }
        Self.letGo(readers)
        return released
    }

    /// `releaseMedia(keeping:)` with the renderer's prefetchers held (`ahead`): the tracks let go, and the readers to let
    /// go once they are no longer held (`letGo(_:)`).
    func releaseMedia(keeping kept: Set<TrackKey>, in ahead: inout Ahead) -> ([TrackKey], [TrackFrameReader]) {
        let ids = Set(kept.filter(Self.isMedia).map(\.track))
        var released: [TrackKey] = []
        for (track, prefetcher) in ahead.prefetchers where Self.isMedia(track) && !ids.contains(track.track) {
            prefetcher.reset()
            ahead.prefetchers[track] = nil
            released.append(track)
        }
        let readers = mediaResources.release(keeping: ids)
        for reader in readers where !released.contains(TrackKey(take: nil, track: reader.trackID)) {
            released.append(TrackKey(take: nil, track: reader.trackID))
        }
        return (released, readers)
    }

    /// Lets each of `readers` go (`TrackFrameReader.letGo()`) on a queue of their own, so no caller waits for a frame one
    /// is decoding.
    static func letGo(_ readers: [TrackFrameReader]) {
        guard !readers.isEmpty else { return }
        mediaClosingQueue.async {
            for reader in readers { reader.letGo() }
        }
    }

    /// The imported clips of the sequence that cannot be drawn, in output seconds (`missingVideo`'s): the whole of each clip
    /// whose file the package's safe reader does not give (`.fileMissing`: gone, a link, not a video of `assets/`) or
    /// whose reader gives no frame at all (its reason); otherwise each span of the file its reader could not decode, where
    /// a clip shows it. By the clip's reader id (`AssetFrameReader.readerID(of:)`) as the track and its path as the file.
    /// No reader is made here.
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
            guard let reader = mediaResources.existingReader(for: id) else { continue }
            let gaps = reader.gaps
            if reader.unusableSince != nil {
                missing.append(span(start, start + duration, gaps.last?.reason ?? .unreadable))
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

/// Where the clips' readers let go wind down (`FrameRenderer.letGo(_:)`), one after the other.
private let mediaClosingQueue = DispatchQueue(label: "dev.toma.FrameRenderer.mediaClosing", qos: .utility)
