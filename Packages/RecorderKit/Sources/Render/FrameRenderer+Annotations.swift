// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// What a renderer draws the annotations with (phase 3 design §5.1 and §5.4, plan 3a decision 13), besides their own
/// bitmaps: the images of `assets/` they show, uploaded once with mipmaps (`OverlayImageTextures`, from the process's
/// `OverlayImageCache`), and the frames of their clips, decoded with the take's videos (`FrameRenderer.videos(of:)`, by
/// the imported clips' readers, `mediaReader(for:)`, ahead by the renderer's prefetchers too) and handed back when the
/// frame is drawn (`FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`). With no image in a frame, nothing is
/// made.
final class AnnotationResources: Sendable {
    let images: OverlayImageTextures

    init(device: any MTLDevice, package: ProjectPackage) {
        images = OverlayImageTextures(device: device, package: package)
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
    /// of that file (`overlayReaderID(of:lane:)`), never the one the sequence reads the same file with, so a file shown in
    /// the sequence and over it at another instant is read forward by each. Two clips of one file shown at once at
    /// different instants are read by two of them (lanes): the one that has been shown longest (the most of its file
    /// played, `fileTime − start`) by the first, and so on; one shown alone, or two at the same instant, by the first.
    static func overlayClipVideos(of frame: RenderFrame) -> [(layer: String, key: DecodedKey)] {
        guard !frame.contentAnnotations.isEmpty || !frame.outputAnnotations.isEmpty else { return [] }
        var clips: [(layer: String, asset: String, fileTime: Int64, played: Int64)] = []
        for layer in frame.contentAnnotations + frame.outputAnnotations {
            guard case let .clip(clip, fileTime) = layer.content else { continue }
            let (played, overflow) = fileTime.subtractingReportingOverflow(clip.start)
            clips.append((layer.id, clip.asset, max(fileTime, 0), overflow ? 0 : played))
        }
        guard !clips.isEmpty else { return [] }
        // The lanes of each file: its instants shown, the one played the longest first.
        var lanes: [String: [Int64]] = [:]
        for clip in clips.sorted(by: { ($1.played, $0.fileTime) < ($0.played, $1.fileTime) }) where !(lanes[clip.asset] ?? []).contains(clip.fileTime) {
            lanes[clip.asset, default: []].append(clip.fileTime)
        }
        return clips.map { clip in
            let lane = lanes[clip.asset]?.firstIndex(of: clip.fileTime) ?? 0
            let key = DecodedKey(
                trackID: overlayReaderID(of: clip.asset, lane: lane), time: HostTime(nanoseconds: UInt64(clip.fileTime)))
            return (clip.layer, key)
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
    /// frames are turned upright; and, in the background, the images of the layers coming in
    /// (`RenderFrame.annotationsAhead`). `nil` without an image or a clip to draw. Ends the frame for the images kept.
    /// Called with the renderer's lock held.
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
        for (layer, key) in Self.overlayClipVideos(of: frame) {
            guard let texture = try decoded(key.trackID, key.time)?.texture,
                let asset = AssetFrameReader.asset(ofReaderID: key.trackID)
            else { continue }
            textures.clips[layer] = texture
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
