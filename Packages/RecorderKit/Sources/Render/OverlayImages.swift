// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import Metal
import ProjectFormat
import Synchronization

/// An image over the video (an `ImageAnnotation`'s, phase 3 design §5.4, plan 3a decision 13) as every renderer uploads
/// it: `width × height` pixels of 8-bit RGBA, rows from the top, in sRGB, with its alpha premultiplied, so a transparent
/// PNG is drawn transparent.
struct DecodedOverlayImage: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

/// The process's decoded images over the video, by package and asset (plan 3a decision 13, as `BackgroundImageCache` but
/// with the alpha kept): each is decoded once while some renderer holds its entry, and every renderer that asks for it
/// meanwhile gets the same pixels, so the preview and an export of a project draw the same image even where ImageIO would
/// decode a JPEG or a HEIC differently twice. An entry nobody holds goes, with its memory.
///
/// The image is read only through the package's safe reader (`ProjectPackage.asset(_:)`, `PackageFileKind.decodedImage`:
/// PNG, JPEG or HEIC of `assets/`, reached through no link, its longer side reduced to 7 680 pixels); one that is missing
/// or cannot be read has no pixels, and draws nothing.
final class OverlayImageCache: Sendable {
    static let shared = OverlayImageCache()

    /// The package's path and the asset: the asset's name is its content's hash, but a frame is a function of its own
    /// package alone.
    struct Key: Hashable, Sendable {
        let package: String
        let asset: String

        init(_ asset: String, in package: ProjectPackage) {
            self.package = package.url.standardizedFileURL.path
            self.asset = asset
        }
    }

    /// One image of the cache: decoded the first time it is asked for, by whoever asks first while the others wait.
    final class Entry: Sendable {
        private enum State {
            case pending
            /// `nil` when the image is missing or cannot be read.
            case decoded(DecodedOverlayImage?)
        }

        let key: Key
        private let package: ProjectPackage
        private let cache: OverlayImageCache
        private let state = Mutex(State.pending)

        fileprivate init(key: Key, package: ProjectPackage, cache: OverlayImageCache) {
            self.key = key
            self.package = package
            self.cache = cache
        }

        /// The image, decoded the first time; `nil` when it is missing or cannot be read.
        func image() -> DecodedOverlayImage? {
            state.withLock { state in
                if case let .decoded(image) = state { return image }
                let image = OverlayImageCache.decode(key.asset, in: package)
                cache.noteDecode(of: key)
                state = .decoded(image)
                return image
            }
        }
    }

    /// An entry, held weakly, and how many times its key has been decoded since the slot was made.
    private struct Slot {
        weak var entry: Entry?
        var decodes = 0
    }

    private let slots = Mutex<[Key: Slot]>([:])

    /// The entry of the image `asset` (`assets/<sha>.<ext>`) of `package`: the one some renderer holds, or a new one, not
    /// decoded yet.
    func entry(for asset: String, in package: ProjectPackage) -> Entry {
        let key = Key(asset, in: package)
        return slots.withLock { slots in
            if let entry = slots[key]?.entry { return entry }
            // The other images nobody holds any more leave, with their counts.
            slots = slots.filter { $0.key == key || $0.value.entry != nil }
            let entry = Entry(key: key, package: package, cache: self)
            slots[key, default: Slot()].entry = entry
            return entry
        }
    }

    /// How many times the process has decoded the image `asset` of `package` since the cache last had nothing of it, for
    /// tests: once while renderers share it.
    func decodeCount(of asset: String, in package: ProjectPackage) -> Int {
        slots.withLock { $0[Key(asset, in: package)]?.decodes ?? 0 }
    }

    private func noteDecode(of key: Key) {
        slots.withLock { $0[key, default: Slot()].decodes += 1 }
    }

    /// The image `asset` through the package's safe reader, drawn into a transparent sRGB context of 8-bit RGBA with its
    /// alpha premultiplied; `nil` when the reader gives none (missing, a link, not a regular file, too large, not a format
    /// allowed, not decodable) or the context cannot be made.
    private static func decode(_ asset: String, in package: ProjectPackage) -> DecodedOverlayImage? {
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
        return drawn ? DecodedOverlayImage(width: width, height: height, bytes: bytes) : nil
    }
}

/// The textures of one renderer's images over the video (plan 3a decision 13): each image of `assets/` a frame shows,
/// taken from the process's cache (`OverlayImageCache`) and uploaded once as an `.rgba8Unorm` texture with mipmaps (never
/// an `_srgb` one, which would linearize the bytes when sampled), so an image larger than its box is reduced to it without
/// aliasing. Under a lock: a frame asks for its images while it is encoded (`texture(for:)`), and the images coming in
/// soon (`RenderFrame.annotationsAhead`) are decoded and uploaded ahead on a queue of its own (`prepare(_:)`), so the frame
/// they come in binds a texture made already; a frame that asks for one being made waits for it.
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
        /// The cache's entry, held so another renderer of it shares the decoded pixels.
        let entry: OverlayImageCache.Entry
        /// `nil` while it is being made ahead; then its texture (`nil` for an image with nothing to draw), or why Metal
        /// could not make it.
        var texture: Result<UploadedTexture?, RenderError>?
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
        var uploadCount = 0
        /// Made the first time an image is uploaded: a renderer whose frames show none never makes it.
        var commandQueue: MetalHandle<any MTLCommandQueue>?
    }

    private let device: MetalHandle<any MTLDevice>
    private let package: ProjectPackage
    private let state: Mutex<State>
    /// Where the images ahead are decoded and uploaded, one at a time.
    private let queue = DispatchQueue(label: "dev.toma.OverlayImageTextures", qos: .userInitiated)

    init(device: any MTLDevice, package: ProjectPackage) {
        self.device = MetalHandle(device)
        self.package = package
        state = Mutex(State())
    }

    /// How many images have been uploaded (or tried to), for tests.
    var uploadCount: Int { state.withLock { $0.uploadCount } }
    /// How many images are kept, with a texture or without, for tests.
    var keptCount: Int { state.withLock { $0.slots.count } }

    /// The texture of the image `asset` (`assets/<sha>.<ext>`), made the first time it is asked for (or ahead) and kept;
    /// `nil` when it is missing or cannot be read, or when Metal could not make it (the frame is drawn without it). Waits
    /// for one being made ahead. Marks it used by the frame being drawn.
    func texture(for asset: String) -> (any MTLTexture)? {
        enum Found {
            case made(Result<UploadedTexture?, RenderError>)
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
                return .make(OverlayImageCache.shared.entry(for: asset, in: package))
            }
            switch found {
            case let .made(texture):
                return (try? texture.get())??.texture
            case let .pending(done):
                done.wait()
            case let .make(entry):
                // Decoded and uploaded outside the lock, kept after: a frame that asks again meanwhile makes it again,
                // the same bytes, and the first one kept stays.
                let made = upload(entry.image())
                return state.withLock { state in
                    if let index = state.slots.firstIndex(where: { $0.asset == asset }), let kept = state.slots[index].texture {
                        state.slots[index].used = state.frame
                        return (try? kept.get())??.texture
                    }
                    state.slots.removeAll { $0.asset == asset }
                    Self.keep(Slot(asset: asset, entry: entry, texture: made, used: state.frame, done: nil), in: &state)
                    return (try? made.get())??.texture
                }
            }
        }
    }

    /// Decodes and uploads in the background the images `assets` not kept nor being made (those of the layers coming in,
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
                let entry = OverlayImageCache.shared.entry(for: asset, in: package)
                // Kept at once, without a texture yet: a frame that asks for it waits for it.
                state.slots.append(Slot(asset: asset, entry: entry, texture: nil, used: state.frame, done: done))
                scheduled.append((asset, entry, done))
            }
            return scheduled
        }
        for (asset, entry, done) in scheduled {
            queue.async { [self] in
                let made = upload(entry.image())
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

    /// `image` as an `.rgba8Unorm` texture with mipmaps; `nil` without an image.
    private func upload(_ image: DecodedOverlayImage?) -> Result<UploadedTexture?, RenderError> {
        guard let image else { return .success(nil) }
        let device = self.device.object
        let handle: MetalHandle<any MTLCommandQueue>? = state.withLock { state in
            state.uploadCount += 1
            if state.commandQueue == nil, let made = device.makeCommandQueue() { state.commandQueue = MetalHandle(made) }
            return state.commandQueue
        }
        let queue = handle?.object
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
        commandBuffer.label = "OverlayImageTextures"
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            return .failure(.gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)"))
        }
        return .success(UploadedTexture(texture: texture))
    }

    /// Keeps `slot`, just made: the oldest go first while more than `kept` or `maxBytes` are kept, but never one used by
    /// this frame or the one before it, nor one being made.
    private static func keep(_ slot: Slot, in state: inout State) {
        var slot = slot
        if case let .success(made?)? = slot.texture {
            // Its mipmaps: a third more.
            slot.bytes = made.texture.width * made.texture.height * 4 * 4 / 3
        }
        trim(making: 1, bytes: slot.bytes, in: &state)
        state.slots.append(slot)
        state.bytes += slot.bytes
    }

    /// Drops the oldest images while, with room made for `room` more of `bytes`, more than `kept` or `maxBytes` would be
    /// kept, but never one used by the frame being drawn or the one before it, nor one being made.
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

/// A texture an image was uploaded to, handed from the queue that made it to the textures kept, under their lock:
/// nothing writes to it once made, and Metal textures may be read from any thread.
struct UploadedTexture: @unchecked Sendable {
    let texture: any MTLTexture
}

/// A Metal device or command queue used from the queue that makes the images ahead and from a frame's: both are safe to
/// use from any thread.
struct MetalHandle<Object>: @unchecked Sendable {
    let object: Object

    init(_ object: Object) {
        self.object = object
    }
}
