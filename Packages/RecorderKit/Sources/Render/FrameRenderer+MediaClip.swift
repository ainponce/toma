// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import Synchronization

/// What a renderer draws the imported clips of the sequence with (phase 3 design §5.4, plan 3a decision 12), besides the
/// take's videos: a reader for each file of `assets/` a frame shows (`AssetFrameReader`), by a reader id that no track of a
/// take has (`asset:<path>`), made the first time it is asked for and kept, one for every clip of that file; decoded with
/// the take's videos (`FrameRenderer.videos(of:)`, ahead by its prefetchers too) and handed back when the frame is drawn
/// (`FrameRenderer.mediaTextures(for:decoded:commandBuffer:)`), with how a player turns the file's frames upright, loaded
/// once a frame of it is decoded. A file that gives no reader (gone, a link, not a video of `assets/`) is looked for again
/// the next time a frame asks, and draws the background alone meanwhile; with no clip in the sequence, nothing is made.
///
/// `reader(for:)` is called from any thread; `orientation(of:)` with the renderer's lock held.
final class MediaClipResources: Sendable {
    /// Where the clips are read from (`ProjectPackage.mediaAsset(_:as:)`).
    let package: ProjectPackage
    private let state = Mutex(State())

    private struct State {
        /// The readers made, by their reader id.
        var readers: [String: TrackFrameReader] = [:]
        /// How each file's frames are turned upright, by its path, once loaded.
        var orientations: [String: MediaOrientation] = [:]
    }

    init(device: any MTLDevice, package: ProjectPackage) {
        self.package = package
    }

    /// The reader of `id`, a clip's reader id (`AssetFrameReader.readerID(of:)`), made the first time it is asked for and
    /// kept; `nil` for any other id, and while the file gives none (`AssetFrameReader.make(asset:package:)`).
    func reader(for id: String) -> TrackFrameReader? {
        guard let asset = AssetFrameReader.asset(ofReaderID: id) else { return nil }
        return state.withLock { state in
            if let reader = state.readers[id] { return reader }
            guard let reader = AssetFrameReader.make(asset: asset, package: package) else { return nil }
            state.readers[id] = reader
            return reader
        }
    }

    /// How many readers were made: for tests.
    var readerCount: Int { state.withLock { $0.readers.count } }

    /// How a player turns the frames of the clip `asset` upright (`AssetFrameReader.orientation(of:)`), loaded the first
    /// time and kept; as decoded while it cannot be loaded (the file gone since its frame was decoded, say). Blocks while it
    /// loads, once for each file.
    func orientation(of asset: String) -> MediaOrientation {
        if let known = state.withLock({ $0.orientations[asset] }) { return known }
        guard let url = package.mediaAsset(asset, as: .video), let loaded = AssetFrameReader.orientation(of: url) else {
            return .upright
        }
        return state.withLock { state in
            if let known = state.orientations[asset] { return known }
            state.orientations[asset] = loaded
            return loaded
        }
    }
}

extension FrameRenderer {
    /// The (reader id, file time) of the imported clip's frame `frame` shows (`AssetFrameReader.readerID(of:)`, at its
    /// `fileTime` as host time from 0), after the camera's look's (`videos(of:)`'s order): none without one.
    func mediaVideos(of frame: RenderFrame) -> [DecodedKey] {
        guard let media = frame.media else { return [] }
        return [DecodedKey(trackID: AssetFrameReader.readerID(of: media.asset), time: media.sourceTime)]
    }

    /// The reader of `id`, a video `mediaVideos(of:)` or `annotationVideos(of:)` gives (a file of `assets/`), made the
    /// first time it is asked for (`MediaClipResources.reader(for:)`); `nil` for any other id, and for a file that gives
    /// none.
    func mediaReader(for id: String) -> TrackFrameReader? {
        mediaResources.reader(for: id)
    }

    /// What `frame`'s imported clip is drawn with (`LayerTextures.media`): the frame `decoded` gives for its video of
    /// `mediaVideos(of:)`, which the renderer keeps alive until `commandBuffer` completes, and how its file's frames are
    /// turned upright. `nil` without a clip, and without its frame (a file that cannot be read): the background alone.
    /// Called with the renderer's lock held.
    func mediaTextures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> MediaClipTextures? {
        guard let media = frame.media,
              let texture = try decoded(AssetFrameReader.readerID(of: media.asset), media.sourceTime)?.texture
        else { return nil }
        return MediaClipTextures(frame: texture, orientation: mediaResources.orientation(of: media.asset))
    }
}
