// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// What a renderer draws the annotations with (phase 3 design §5.1 and §5.4, plan 3a decision 13), besides their own
/// bitmaps: the images of `assets/` they show, uploaded once with mipmaps (`OverlayImageTextures`, from the process's
/// `OverlayImageCache`), and the frames of their clips, decoded with the take's videos (`FrameRenderer.videos(of:)`, by
/// the imported clips' readers, `mediaReader(for:)`, ahead by the renderer's prefetchers too) and handed back when the
/// frame is drawn (`FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`), copied with their mipmaps
/// (`mipmappedCopies`, of their own: the sequence's clip keeps its sizes) when the style samples the screens so
/// (`AnnotationLayer.mipmapped`). With no image or clip in a frame, nothing is made.
final class AnnotationResources: Sendable {
    let images: OverlayImageTextures
    let mipmappedCopies: MipmappedCopies

    init(device: any MTLDevice, package: ProjectPackage) {
        images = OverlayImageTextures(device: device, package: package)
        mipmappedCopies = MipmappedCopies(device: device)
    }
}

extension FrameRenderer {
    /// The (reader id, file time) of each annotation clip's frame `frame` shows, in its layers' order, after the imported
    /// clips' (`videos(of:)`'s order): `overlayClipVideos(of:)`'s. None without a clip over the video.
    func annotationVideos(of frame: RenderFrame) -> [DecodedKey] {
        Self.overlayClipVideos(of: frame).map(\.key)
    }

    /// Each clip over the video `frame` shows, by its layer's id, with the (reader id, file time) of its frame: the file's
    /// time `fileTime` (`AnnotationLayer.Content.clip`) as host time from 0, read by a reader of the clips over the video
    /// of that file in the layer's lane (`overlayReaderID(of:lane:)`, `AnnotationLayer.lane`), never the one the sequence
    /// reads the same file with, so a file shown in the sequence and over it at another instant is read forward by each.
    /// A lane is fixed for its annotation: clips of a file one after the other share one, and each of those shown at once
    /// keeps its own while it is shown.
    static func overlayClipVideos(of frame: RenderFrame) -> [(layer: String, key: DecodedKey)] {
        guard !frame.contentAnnotations.isEmpty || !frame.outputAnnotations.isEmpty else { return [] }
        return (frame.contentAnnotations + frame.outputAnnotations).compactMap { layer in
            guard case let .clip(clip, fileTime) = layer.content else { return nil }
            let key = DecodedKey(
                trackID: overlayReaderID(of: clip.asset, lane: max(layer.lane, 0)), time: HostTime(nanoseconds: UInt64(max(fileTime, 0))))
            return (layer.id, key)
        }
    }

    /// The reader id of the clips over the video of the file `asset` in `lane` (0 first): `asset:<asset>#overlay`, then
    /// `#overlay-2`…, which `AssetFrameReader.asset(ofReaderID:)` reads as the file and `MediaClipResources` keeps apart
    /// from the sequence's `asset:<asset>`.
    static func overlayReaderID(of asset: String, lane: Int) -> String {
        AssetFrameReader.readerID(of: asset) + (lane > 0 ? "#overlay-\(lane + 1)" : "#overlay")
    }

    /// What `frame`'s annotations are drawn with (`LayerTextures.annotations`): the images its layers show
    /// (`OverlayImageTextures.texture(for:)`, made the first time), and the frames `decoded` gives for its clips' videos
    /// of `annotationVideos(of:)`, which the renderer keeps alive until `commandBuffer` completes, with how each file's
    /// frames are turned upright, each copied with its mipmaps into `commandBuffer` when its layer says so
    /// (`AnnotationLayer.mipmapped`, `AnnotationResources.mipmappedCopies`); and, in the background, the images of the
    /// layers coming in (`RenderFrame.annotationsAhead`). `nil` without an image or a clip to draw. Ends the frame for the
    /// images kept. Called with the renderer's lock held, before the frame's passes are encoded.
    /// - Throws: `RenderError.metalResourceUnavailable` when Metal cannot make a clip's mipmapped copy, having encoded
    ///   nothing for it: the frame is not drawn, as a screen's.
    func annotationTextures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> AnnotationTextures? {
        guard !frame.contentAnnotations.isEmpty || !frame.outputAnnotations.isEmpty || !frame.annotationsAhead.isEmpty else {
            return nil
        }
        let images = annotationResources.images
        var textures = AnnotationTextures()
        var hasImage = false
        for layer in frame.contentAnnotations + frame.outputAnnotations {
            guard case let .image(image) = layer.content else { continue }
            hasImage = true
            if textures.images[image.asset] == nil, let texture = images.texture(for: image.asset) {
                textures.images[image.asset] = texture
            }
        }
        let mipmapped = Set((frame.contentAnnotations + frame.outputAnnotations).filter(\.mipmapped).map(\.id))
        for (layer, key) in Self.overlayClipVideos(of: frame) {
            guard let texture = try decoded(key.trackID, key.time)?.texture,
                let asset = AssetFrameReader.asset(ofReaderID: key.trackID)
            else { continue }
            if mipmapped.contains(layer) {
                textures.clips[layer] = try annotationResources.mipmappedCopies.copy(
                    of: texture, region: MTLRegionMake2D(0, 0, texture.width, texture.height), commandBuffer: commandBuffer)
                textures.mipmappedClips.insert(layer)
            } else {
                textures.clips[layer] = texture
            }
            textures.orientations[layer] = mediaResources.orientation(of: asset)
        }
        let ahead = frame.annotationsAhead.compactMap { wanted -> String? in
            if case let .image(image) = wanted.layer.content { image.asset } else { nil }
        }
        images.prepare(ahead)
        if hasImage || !ahead.isEmpty { images.endFrame() }
        return textures.isEmpty ? nil : textures
    }
}
