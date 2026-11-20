// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import Metal
import ProjectFormat
import Synchronization

/// The texture of an image over the video (an `ImageAnnotation`'s, phase 3 design §5.4, plan 3a decision 13), as every
/// renderer of a device draws it: `.rgba8Unorm` (never `_srgb`, which would linearize the bytes when sampled) with
/// mipmaps, in sRGB, its alpha premultiplied, so a transparent PNG is drawn transparent and an image larger than its box
/// is reduced without aliasing; and whether every pixel of it is opaque (`opaque`: its shadow is its box's, otherwise it
/// follows its alpha). Nothing writes to it once made, and Metal textures may be read from any thread.
struct OverlayImageTexture: @unchecked Sendable {
    let texture: any MTLTexture
    let opaque: Bool

    /// Its bytes on the GPU: its level 0 and its mipmaps, a third more.
    var bytes: Int { texture.width * texture.height * 4 * 4 / 3 }
}

/// The process's images over the video, by package, asset and Metal device (plan 3a decision 13, as
/// `BackgroundImageCache`, but with the alpha kept and the texture shared): each is decoded and uploaded once while some
/// renderer holds its entry, its decoded bytes let go once uploaded, and every renderer that asks for it meanwhile gets the
/// same texture, so the preview and an export of a project draw the same pixels even where ImageIO would decode a JPEG or
/// a HEIC differently twice, and hold one copy of it. An entry nobody holds goes, with its texture.
///
/// The image is read only through the package's safe reader (`ProjectPackage.asset(_:)`, `PackageFileKind.decodedImage`:
/// PNG, JPEG or HEIC of `assets/`, reached through no link, its longer side reduced to 7 680 pixels); one that is missing
/// or cannot be read has no texture, and draws nothing.
final class OverlayImageCache: Sendable {
    static let shared = OverlayImageCache()

    /// The package's path, the asset and the device: the asset's name is its content's hash, but a frame is a function of
    /// its own package alone.
    struct Key: Hashable, Sendable {
        let package: String
        let asset: String
        let device: UInt64

        init(_ asset: String, in package: ProjectPackage, device: UInt64) {
            self.package = package.url.standardizedFileURL.path
            self.asset = asset
            self.device = device
        }
    }

    /// One image of the cache: made the first time it is asked for, by whoever asks first while the others wait.
    final class Entry: Sendable {
        let key: Key
        private let package: ProjectPackage
        private let device: MetalHandle<any MTLDevice>
        private let cache: OverlayImageCache
        /// `nil` until made; then its texture (`nil` when the image is missing or cannot be read), or why Metal could not
        /// make it.
        private let state = Mutex<Result<OverlayImageTexture?, RenderError>?>(nil)

        fileprivate init(key: Key, package: ProjectPackage, device: MetalHandle<any MTLDevice>, cache: OverlayImageCache) {
            self.key = key
            self.package = package
            self.device = device
            self.cache = cache
        }

        /// The image's texture, made the first time: decoded, uploaded with its mipmaps, and its decoded bytes let go.
        func texture() -> Result<OverlayImageTexture?, RenderError> {
            state.withLock { state in
                if let made = state { return made }
                let made = cache.make(key.asset, in: package, device: device)
                state = made
                return made
            }
        }
    }

    /// An entry, held weakly, and how many times its key has been decoded since the slot was made.
    private struct Slot {
        weak var entry: Entry?
        var decodes = 0
    }

    private let slots = Mutex<[Key: Slot]>([:])
    /// The command queue each device's mipmaps are made with, by its registry ID: made the first time.
    private let queues = Mutex<[UInt64: MetalHandle<any MTLCommandQueue>]>([:])

    /// The entry of the image `asset` (`assets/<sha>.<ext>`) of `package` on `device`: the one some renderer holds, or a
    /// new one, not made yet.
    func entry(for asset: String, in package: ProjectPackage, device: any MTLDevice) -> Entry {
        let key = Key(asset, in: package, device: device.registryID)
        let handle = MetalHandle(device)
        return slots.withLock { slots in
            if let entry = slots[key]?.entry { return entry }
            // The other images nobody holds any more leave, with their counts.
            slots = slots.filter { $0.key == key || $0.value.entry != nil }
            let entry = Entry(key: key, package: package, device: handle, cache: self)
            slots[key, default: Slot()].entry = entry
            return entry
        }
    }

    /// How many times the process has decoded the image `asset` of `package` (on any device) since the cache last had
    /// nothing of it, for tests: once while renderers share it.
    func decodeCount(of asset: String, in package: ProjectPackage) -> Int {
        let path = package.url.standardizedFileURL.path
        return slots.withLock { slots in
            slots.filter { $0.key.asset == asset && $0.key.package == path }.reduce(0) { $0 + $1.value.decodes }
        }
    }

    /// The texture of the image `asset` of `package` on `device` (`Entry.texture()`): decoded, uploaded and its mipmaps
    /// made, waiting for the GPU; the decoded bytes go when this returns.
    private func make(
        _ asset: String, in package: ProjectPackage, device handle: MetalHandle<any MTLDevice>
    ) -> Result<OverlayImageTexture?, RenderError> {
        let device = handle.object
        let decoded = Self.decode(asset, in: package)
        slots.withLock { $0[Key(asset, in: package, device: device.registryID), default: Slot()].decodes += 1 }
        guard let image = decoded else { return .success(nil) }
        let queue = queues.withLock { queues -> MetalHandle<any MTLCommandQueue>? in
            if let queue = queues[device.registryID] { return queue }
            guard let made = device.makeCommandQueue() else { return nil }
            queues[device.registryID] = MetalHandle(made)
            return MetalHandle(made)
        }?.object
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let queue, let texture = device.makeTexture(descriptor: descriptor) else {
            return .failure(.metalResourceUnavailable("overlay image texture"))
        }
        image.bytes.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: image.width * 4)
        }
        guard let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            return .failure(.metalResourceUnavailable("overlay image mipmaps"))
        }
        commandBuffer.label = "OverlayImageCache"
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            return .failure(.gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)"))
        }
        return .success(OverlayImageTexture(texture: texture, opaque: image.opaque))
    }

    /// The image `asset` through the package's safe reader, drawn into a transparent sRGB context of 8-bit RGBA with its
    /// alpha premultiplied, and whether all of it is opaque; `nil` when the reader gives none (missing, a link, not a
    /// regular file, too large, not a format allowed, not decodable) or the context cannot be made.
    private static func decode(_ asset: String, in package: ProjectPackage) -> (width: Int, height: Int, bytes: [UInt8], opaque: Bool)? {
        guard let image = package.asset(asset), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.clear(rect)
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }
        let opaque = bytes.withUnsafeBytes { buffer in
            stride(from: 3, to: buffer.count, by: 4).allSatisfy { buffer[$0] == 255 }
        }
        return (width, height, bytes, opaque)
    }
}

/// The textures of one renderer's images over the video (plan 3a decision 13): each image of `assets/` a frame shows,
/// taken from the process's cache (`OverlayImageCache`, which makes it once for every renderer of the device). Under a
/// lock: a frame asks for its images while it is encoded (`texture(for:)`), and the images coming in soon
/// (`RenderFrame.annotationsAhead`) are made ahead on a queue of its own (`prepare(_:)`), so the frame they come in binds a
/// texture made already; a frame that asks for one being made waits for it.
///
/// - Kept: every image a frame used or handed over ahead, the current one and the one before (`endFrame()` ends each),
///   however many; past them, the last `kept` used and at most `maxBytes` of them, the oldest going first.
/// - An image that is missing or cannot be read, or whose texture Metal could not make, has none and is kept so, so no
///   frame reads or decodes it again, until `forgetUnreadable()` (a new scene).
final class OverlayImageTextures: Sendable {
    /// How many textures are kept, past those in use.
    static let kept = 8
    /// The most bytes of textures kept, past those in use.
    static let maxBytes = 512 << 20

    private struct Slot {
        let asset: String
        /// The cache's entry, held so the other renderers of the device share its texture.
        let entry: OverlayImageCache.Entry
        /// `nil` while it is being made ahead; then its texture (`nil` for an image with nothing to draw), or why Metal
        /// could not make it.
        var texture: Result<OverlayImageTexture?, RenderError>?
        var bytes = 0
        /// The last frame that used it or handed it over ahead.
        var used: UInt64
        /// Signalled once it is made, when it is made ahead.
        let done: DispatchGroup?
    }

    private struct State {
        /// The images, the one used last, last.
        var slots: [Slot] = []
        var bytes = 0
        /// The frame being drawn: `endFrame()` ends it.
        var frame: UInt64 = 1
        var textureCount = 0
    }

    private let device: MetalHandle<any MTLDevice>
    private let package: ProjectPackage
    private let state: Mutex<State>
    /// Where the images ahead are made, one at a time.
    private let queue = DispatchQueue(label: "dev.toma.OverlayImageTextures", qos: .userInitiated)

    init(device: any MTLDevice, package: ProjectPackage) {
        self.device = MetalHandle(device)
        self.package = package
        state = Mutex(State())
    }

    /// How many textures it took from the cache (made or shared), for tests.
    var textureCount: Int { state.withLock { $0.textureCount } }
    /// How many images are kept, with a texture or without, for tests.
    var keptCount: Int { state.withLock { $0.slots.count } }

    /// The texture of the image `asset` (`assets/<sha>.<ext>`), taken from the cache the first time it is asked for (or
    /// ahead) and kept; `nil` when it is missing or cannot be read, or when Metal could not make it (the frame is drawn
    /// without it). Waits for one being made ahead. Marks it used by the frame being drawn.
    func texture(for asset: String) -> OverlayImageTexture? {
        enum Found {
            case made(Result<OverlayImageTexture?, RenderError>)
            case pending(DispatchGroup)
            case make(OverlayImageCache.Entry)
        }
        while true {
            let found: Found = state.withLock { state in
                if let index = state.slots.firstIndex(where: { $0.asset == asset }) {
                    var slot = state.slots.remove(at: index)
                    slot.used = state.frame
                    state.slots.append(slot)
                    if let texture = slot.texture { return .made(texture) }
                    return .pending(slot.done ?? DispatchGroup())
                }
                return .make(OverlayImageCache.shared.entry(for: asset, in: package, device: device.object))
            }
            switch found {
            case let .made(texture):
                return (try? texture.get()) ?? nil
            case let .pending(done):
                done.wait()
            case let .make(entry):
                // Made outside the lock (the cache's entry has its own), kept after.
                let made = entry.texture()
                return state.withLock { state in
                    if let index = state.slots.firstIndex(where: { $0.asset == asset }), let kept = state.slots[index].texture {
                        state.slots[index].used = state.frame
                        return (try? kept.get()) ?? nil
                    }
                    state.slots.removeAll { $0.asset == asset }
                    Self.keep(Slot(asset: asset, entry: entry, texture: made, used: state.frame, done: nil), in: &state)
                    return (try? made.get()) ?? nil
                }
            }
        }
    }

    /// Makes in the background the images `assets` not kept nor being made (those of the layers coming in,
    /// `RenderFrame.annotationsAhead`), and marks those kept used by the frame being drawn. Returns at once.
    func prepare(_ assets: [String]) {
        guard !assets.isEmpty else { return }
        let scheduled: [(String, OverlayImageCache.Entry, DispatchGroup)] = state.withLock { state in
            var scheduled: [(String, OverlayImageCache.Entry, DispatchGroup)] = []
            for asset in assets {
                if let index = state.slots.firstIndex(where: { $0.asset == asset }) {
                    state.slots[index].used = state.frame
                    continue
                }
                let done = DispatchGroup()
                done.enter()
                let entry = OverlayImageCache.shared.entry(for: asset, in: package, device: device.object)
                // Kept at once, without a texture yet: a frame that asks for it waits for it.
                state.slots.append(Slot(asset: asset, entry: entry, texture: nil, used: state.frame, done: done))
                scheduled.append((asset, entry, done))
            }
            return scheduled
        }
        for (asset, entry, done) in scheduled {
            queue.async { [self] in
                let made = entry.texture()
                state.withLock { state in
                    guard let index = state.slots.firstIndex(where: { $0.asset == asset && $0.texture == nil }) else { return }
                    let slot = state.slots.remove(at: index)
                    Self.keep(Slot(asset: asset, entry: entry, texture: made, used: slot.used, done: nil), in: &state)
                }
                done.leave()
            }
        }
    }

    /// Ends the frame being drawn: what it and the one before it used stays kept.
    func endFrame() {
        state.withLock { state in
            Self.trim(making: 0, bytes: 0, in: &state)
            state.frame += 1
        }
    }

    /// Lets go of the images that are missing or cannot be read, or whose texture could not be made, so the next frame
    /// that shows one looks for it again: for a new scene, after which a file put back or imported again is drawn.
    func forgetUnreadable() {
        state.withLock { state in
            state.slots.removeAll { slot in
                switch slot.texture {
                case .success(.some)?, nil: false
                case .success(nil)?, .failure?: true
                }
            }
        }
    }

    /// Waits until no image is being made ahead, for tests.
    func waitUntilPrepared() {
        while let done = state.withLock({ $0.slots.first { $0.texture == nil }?.done }) { done.wait() }
    }

    /// Keeps `slot`, just made: the oldest go first while more than `kept` or `maxBytes` are kept, but never one used by
    /// this frame or the one before it, nor one being made.
    private static func keep(_ slot: Slot, in state: inout State) {
        var slot = slot
        if case let .success(made?)? = slot.texture {
            slot.bytes = made.bytes
            state.textureCount += 1
        }
        trim(making: 1, bytes: slot.bytes, in: &state)
        state.slots.append(slot)
        state.bytes += slot.bytes
    }

    /// Drops the oldest images while, with room made for `room` more of `bytes`, more than `kept` or more than `maxBytes`
    /// would be kept, but never one used by the frame being drawn or the one before it, nor one being made.
    private static func trim(making room: Int, bytes: Int, in state: inout State) {
        let inUse = state.frame > 1 ? state.frame - 1 : 0
        var index = 0
        while index < state.slots.count, state.slots.count + room > kept || state.bytes + bytes > maxBytes {
            if state.slots[index].used >= inUse || state.slots[index].texture == nil {
                index += 1
            } else {
                state.bytes -= state.slots.remove(at: index).bytes
            }
        }
    }
}

/// A Metal device or command queue used from the queue that makes the images ahead and from a frame's: both are safe to
/// use from any thread.
struct MetalHandle<Object>: @unchecked Sendable {
    let object: Object

    init(_ object: Object) {
        self.object = object
    }
}
