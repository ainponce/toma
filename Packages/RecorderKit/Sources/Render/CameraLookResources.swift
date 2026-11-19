// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Metal
import ProjectFormat
import Synchronization
import simd

/// What a renderer draws the camera's colour and background with (phase 2 design §6.1 and §6.3), besides the take's
/// videos: the 3D LUTs of the looks and of the package's `.cube`s (`CameraLUTRef`), and a reader for each person's mask of
/// the analysis caches a frame shows (`PersonMaskSource.readerID`, an id no track of a take has), read like the camera.
/// `FrameRenderer` decodes a frame's mask with the take's videos (`videos(of:)`, ahead by its prefetchers too) and hands
/// what is decoded here when it draws (`textures(for:decoded:commandBuffer:)`): a mask that is not there draws the camera
/// as it is, never an error.
///
/// - **LUTs** (`cameraLook-1`): each look's made in code (`CameraLooks.lut`) the first time a frame shows it, once for the
///   renderer; each `.cube` of the package by its path, read with the safe reader (`SafePackageFile`, `.lut`) and parsed
///   (`CubeLUT.parse`) the first time, kept. Both `rgba16Float`, one texel a point. A `.cube` that cannot be read or parsed
///   draws Natural and is not looked for again until `forgetUnreadable()`.
/// - **Masks** (`personMask-1`): a frame's mask is its camera's (`CameraBackgroundLayer.mask`), at the camera's own source
///   instant, by a reader of its segment's video (`TrackFrameReader(maskFile:trackID:start:end:)`) made the first time it
///   is asked for. While the file is not a regular file of some bytes where the caches keep it (macOS emptied the caches,
///   say), the frame asks for no mask, and its camera is the original from that frame on.
///
/// `videos(of:)` and `reader(for:)` are called from any thread; `textures(for:decoded:commandBuffer:)` and
/// `forgetUnreadable()` with the renderer's lock held.
final class CameraLookResources: @unchecked Sendable {
    /// The renderer's device, which the LUTs' textures are made with.
    let device: any MTLDevice
    /// Where a `.cube` is read from (`CameraLUTRef.file`).
    let package: ProjectPackage
    private let state = Mutex(State())

    /// A LUT as a texture, with the domain it maps.
    private struct LUT {
        let texture: any MTLTexture
        let domain: (min: SIMD3<Float>, max: SIMD3<Float>)
    }

    private final class Box<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private struct State {
        /// The looks made so far.
        var presets: [CameraColorPreset: Box<LUT>] = [:]
        /// The `.cube`s read so far, by path; `nil` for one that could not be read or parsed.
        var files: [String: Box<LUT>?] = [:]
        /// Every mask a frame asked for, by its reader id: where its reader reads.
        var masks: [String: PersonMaskSource] = [:]
        var readers: [String: TrackFrameReader] = [:]
    }

    init(device: any MTLDevice, package: ProjectPackage) {
        self.device = device
        self.package = package
    }

    /// The (reader id, source instant) of each video `frame` draws the camera with, after the take's
    /// (`FrameRenderer.videos(of:)`): its person's mask at the camera's instant, while its file is there. None without a
    /// background.
    func videos(of frame: RenderFrame) -> [DecodedKey] {
        mask(of: frame).map { [DecodedKey(trackID: $0.readerID, time: $0.time)] } ?? []
    }

    /// The reader of `id`, a video `videos(of:)` gives that is not a track of the take (a person's mask), made the first
    /// time it is asked for; `nil` for any other id.
    func reader(for id: String) -> TrackFrameReader? {
        state.withLock { state in
            if let reader = state.readers[id] { return reader }
            guard let mask = state.masks[id] else { return nil }
            let reader = TrackFrameReader(maskFile: mask.file, trackID: id, start: mask.segmentStart, end: mask.segmentEnd)
            state.readers[id] = reader
            return reader
        }
    }

    /// What `frame`'s camera is drawn with (`Compositor.encode`'s `cameraLook`): the LUT of its look and its mask, the
    /// frame `decoded` gives for each of `videos(of:)` (which the renderer keeps alive until `commandBuffer` completes);
    /// without the mask, `mask` is `nil` and the camera's background is the original. `nil` without a look nor a
    /// background, or with neither there.
    func textures(
        for frame: RenderFrame, decoded: (_ id: String, _ time: HostTime) throws -> CachedTexture?,
        commandBuffer: any MTLCommandBuffer
    ) throws -> CameraLookTextures? {
        guard let camera = frame.camera else { return nil }
        var textures = CameraLookTextures()
        if let ref = camera.look?.lut, let lut = lut(ref) {
            textures.lut = lut.texture
            textures.lutDomain = lut.domain
        }
        if let mask = mask(of: frame) {
            textures.mask = try decoded(mask.readerID, mask.time)?.texture
        }
        return textures.lut == nil && textures.mask == nil ? nil : textures
    }

    /// Lets a `.cube` that could not be read be looked for again (`FrameRenderer.setScene(_:)`).
    func forgetUnreadable() {
        state.withLock { state in
            state.files = state.files.filter { $0.value != nil }
        }
    }

    /// The mask of `frame`'s camera, noted for its reader (`reader(for:)`), while its file is a regular file of some bytes;
    /// `nil` without a background.
    private func mask(of frame: RenderFrame) -> PersonMaskSource? {
        guard let mask = frame.camera?.background?.mask else { return nil }
        var info = stat()
        guard lstat(mask.file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return nil }
        state.withLock { state in
            if state.masks[mask.readerID] == nil { state.masks[mask.readerID] = mask }
        }
        return mask
    }

    /// The LUT of `ref`: made, or read, the first time.
    private func lut(_ ref: CameraLUTRef) -> LUT? {
        switch ref {
        case .preset(let preset):
            if let made = state.withLock({ $0.presets[preset] }) { return made.value }
            guard let cube = CameraLooks.lut(preset), let lut = texture(of: cube) else { return nil }
            state.withLock { $0.presets[preset] = Box(lut) }
            return lut
        case .file(let path):
            if let read = state.withLock({ $0.files[path] }) { return read?.value }
            let lut = SafePackageFile.read(path, in: package, as: .lut)
                .flatMap { try? CubeLUT.parse($0) }
                .flatMap(texture(of:))
            // Kept as it is, `nil` too: an unreadable `.cube` is not looked for again until `forgetUnreadable()`.
            state.withLock { _ = $0.files.updateValue(lut.map(Box.init), forKey: path) }
            return lut
        }
    }

    /// `cube` as a 3D texture of `rgba16Float`, red along its width, green its height and blue its depth; `nil` when Metal
    /// cannot make it.
    private func texture(of cube: CubeLUT) -> LUT? {
        let n = cube.size
        guard CubeLUT.sizes.contains(n), cube.values.count == n * n * n else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        (descriptor.width, descriptor.height, descriptor.depth) = (n, n, n)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // A `.cube`'s order: red the fastest, then green, then blue. A value past what a half float holds is its largest.
        let largest = Float(Float16.greatestFiniteMagnitude)
        let texels = cube.values.map { value in
            let held = simd_clamp(value, SIMD3(repeating: -largest), SIMD3(repeating: largest))
            return SIMD4<Float16>(Float16(held.x), Float16(held.y), Float16(held.z), 1)
        }
        let row = n * MemoryLayout<SIMD4<Float16>>.stride
        texels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: row,
                bytesPerImage: row * n)
        }
        return LUT(texture: texture, domain: (cube.domainMin, cube.domainMax))
    }
}
