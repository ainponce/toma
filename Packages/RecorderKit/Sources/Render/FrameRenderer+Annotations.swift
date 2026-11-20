// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// What a renderer draws the annotations with (phase 3 design §5.1 and §5.4), besides their own textures: the images of
/// `assets/` they show, uploaded once, and the frames of their clips, decoded with the take's videos
/// (`FrameRenderer.videos(of:)`, by the imported clips' readers, `mediaReader(for:)`) and handed back when the frame is
/// drawn (`FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`). Nothing in the base; milestone 3a fills it (plan
/// 3a decision 13).
final class AnnotationResources: Sendable {
    init(device: any MTLDevice, package: ProjectPackage) {}
}

extension FrameRenderer {
    /// The (reader id, file time) of each annotation clip's frame `frame` shows, after the imported clips'
    /// (`videos(of:)`'s order): none in the base.
    func annotationVideos(of frame: RenderFrame) -> [DecodedKey] {
        []
    }

    /// What `frame`'s annotations are drawn with (`LayerTextures.annotations`): their images, and the frames `decoded`
    /// gives for their videos of `annotationVideos(of:)`, which the renderer keeps alive until `commandBuffer` completes.
    /// `nil` without any, and in the base. Called with the renderer's lock held.
    func annotationTextures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> AnnotationTextures? {
        nil
    }
}
