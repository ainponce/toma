// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat

/// What a renderer draws the camera's colour and background with (phase 2 design §6.1 and §6.3), besides the take's
/// videos: the 3D LUTs of the looks and of the package's `.cube`s (`CameraLUTRef`), and a reader for each person's mask of
/// the analysis caches a frame shows (`PersonMaskSource.readerID`, an id no track of a take has), read like the camera.
/// `FrameRenderer` decodes a frame's mask with the take's videos (`videos(of:)`, ahead by its prefetchers too) and hands
/// what is decoded here when it draws (`textures(for:decoded:commandBuffer:)`): a mask that is not there draws the camera
/// as it is, never an error.
///
/// Milestone 2b's seam leaves it empty: no video, no reader and no texture, so every frame draws as in phase 1. Task I10
/// fills it here.
///
/// `videos(of:)` and `reader(for:)` are called from any thread; `textures(for:decoded:commandBuffer:)` and
/// `forgetUnreadable()` with the renderer's lock held.
final class CameraLookResources: @unchecked Sendable {
    /// The renderer's device, which the LUTs' textures are made with.
    let device: any MTLDevice
    /// Where a `.cube` is read from (`CameraLUTRef.file`).
    let package: ProjectPackage

    init(device: any MTLDevice, package: ProjectPackage) {
        self.device = device
        self.package = package
    }

    /// The (reader id, source instant) of each video `frame` draws the camera with, after the take's
    /// (`FrameRenderer.videos(of:)`): its person's mask at the camera's instant. None in the seam.
    func videos(of frame: RenderFrame) -> [DecodedKey] {
        []
    }

    /// The reader of `id`, a video `videos(of:)` gives that is not a track of the take (a person's mask), made the first
    /// time it is asked for; `nil` for any other id, always in the seam.
    func reader(for id: String) -> TrackFrameReader? {
        nil
    }

    /// What `frame`'s camera is drawn with (`Compositor.encode`'s `cameraLook`): the LUT of its look and its mask, the
    /// frame `decoded` gives for each of `videos(of:)` (which the renderer keeps alive until `commandBuffer` completes);
    /// without the mask, `mask` is `nil` and the camera's background is the original. `nil` without a look nor a
    /// background, always in the seam.
    func textures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> CameraLookTextures? {
        nil
    }

    /// Lets a `.cube` that could not be read be looked for again (`FrameRenderer.setScene(_:)`). Nothing in the seam.
    func forgetUnreadable() {}
}
