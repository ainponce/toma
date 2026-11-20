// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// What a renderer draws the imported clips of the sequence with (phase 3 design §5.4), besides the take's videos: a
/// reader for each file of `assets/` a frame shows, by a reader id that no track of a take has, decoded with the take's
/// videos (`FrameRenderer.videos(of:)`, ahead by its prefetchers too) and handed back when the frame is drawn
/// (`FrameRenderer.mediaTextures(for:decoded:commandBuffer:)`). Nothing in the base; milestone 3a fills it (plan 3a
/// decision 12).
final class MediaClipResources: Sendable {
    init(device: any MTLDevice, package: ProjectPackage) {}
}

extension FrameRenderer {
    /// The (reader id, file time) of each imported clip's frame `frame` shows, after the camera's look's
    /// (`videos(of:)`'s order): none in the base.
    func mediaVideos(of frame: RenderFrame) -> [DecodedKey] {
        []
    }

    /// The reader of `id`, a video `mediaVideos(of:)` or `annotationVideos(of:)` gives (a file of `assets/`), made the
    /// first time it is asked for; `nil` for any other id, and always in the base.
    func mediaReader(for id: String) -> TrackFrameReader? {
        nil
    }

    /// What `frame`'s imported clip is drawn with (`LayerTextures.media`): the frame `decoded` gives for its video of
    /// `mediaVideos(of:)`, which the renderer keeps alive until `commandBuffer` completes. `nil` without one, and in the
    /// base. Called with the renderer's lock held.
    func mediaTextures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> MediaClipTextures? {
        nil
    }
}
