// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import Synchronization

/// The mipmapped copies of the screen's frames (`ScreenLayer.mipmapped`), each of the part of its frame shown alone: one
/// for each frame on the GPU, of its size and format, kept once the GPU is done with that frame for a later one to use
/// again, so a frame never writes into a copy another frame still reads. Only copies of the last two sizes asked for are
/// kept (the screen, and the one being left in a crossfade): while a change of geometry moves the crop, every frame asks
/// for another size, and the copies of the sizes before it (about 45 MB each at 4K) are let go rather than kept.
///
/// A frame's completion hands its copy back on a thread of Metal's, which reads nothing of this but through `state`'s
/// lock: what Metal orders between a commit and its completion, the thread sanitizer cannot see.
final class MipmappedCopies: @unchecked Sendable {
    /// The most copies kept for later frames: past it the oldest is let go, so copies of a size no longer drawn do not
    /// stay. Two screens (a change of screen) of three frames on the GPU (the preview's drawables, the export's).
    private static let kept = 6

    /// A copy, to be handed back: textures are not `Sendable`. Made with `state`'s lock held.
    private final class Copy: @unchecked Sendable {
        let texture: any MTLTexture

        init(_ texture: any MTLTexture) {
            self.texture = texture
        }
    }

    /// A copy's size and format.
    private struct Size: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: MTLPixelFormat

        init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
            (self.width, self.height, self.pixelFormat) = (width, height, pixelFormat)
        }

        init(of texture: any MTLTexture) {
            self.init(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
        }
    }

    /// How many sizes of copies are kept.
    private static let keptSizes = 2

    private struct State {
        /// The copies no frame on the GPU uses, oldest first.
        var free: [Copy] = []
        /// How many were made, for tests.
        var made = 0
        /// The sizes last asked for, the latest last: `keptSizes` at most.
        var sizes: [Size] = []

        /// Notes that `size` was asked for, and lets go of the free copies of a size no longer among the last ones.
        mutating func ask(_ size: Size) {
            sizes.removeAll { $0 == size }
            sizes.append(size)
            if sizes.count > MipmappedCopies.keptSizes { sizes.removeFirst(sizes.count - MipmappedCopies.keptSizes) }
            free.removeAll { !sizes.contains(Size(of: $0.texture)) }
        }
    }

    private let device: any MTLDevice
    private let state = Mutex(State())

    init(device: any MTLDevice) {
        self.device = device
    }

    var count: (made: Int, free: Int) { state.withLock { ($0.made, $0.free.count) } }

    /// How many sizes the free copies are of, for tests.
    var freeSizes: Int {
        state.withLock { state in
            state.free.reduce(into: [Size]()) { sizes, copy in
                if !sizes.contains(Size(of: copy.texture)) { sizes.append(Size(of: copy.texture)) }
            }.count
        }
    }

    /// The whole pixels of a frame `width` × `height` inside `crop` (fractions of it, 0, 0 its top-left corner), rounded
    /// inward: on each axis from `ceil(start − 10⁻⁶)` to `floor(end + 10⁻⁶)` within the frame, or the pixel of the crop's
    /// middle when no whole pixel is inside it. And `crop` as fractions of those pixels: (0, 0) to (1, 1) when its
    /// borders are on pixels, a little past them when they are not (the part that only the cut pixels show). `nil` for a
    /// crop that is not finite.
    static func region(
        of crop: Rect, width: Int, height: Int
    ) -> (pixels: MTLRegion, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>)? {
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        func axis(_ start: Double, _ length: Double, _ pixels: Int) -> (first: Int, count: Int, uvOrigin: Float, uvSize: Float) {
            let count = Double(pixels), low = start * count, high = (start + length) * count
            var first = min(max((low - 1e-6).rounded(.up), 0), count)
            var end = min(max((high + 1e-6).rounded(.down), 0), count)
            if end <= first {
                first = min(max(((low + high) / 2).rounded(.down), 0), count - 1)
                end = first + 1
            }
            let size = end - first
            return (Int(first), Int(size), Float((low - first) / size), Float(length * count / size))
        }
        let x = axis(crop.x, crop.width, width), y = axis(crop.y, crop.height, height)
        return (MTLRegionMake2D(x.first, y.first, x.count, y.count), SIMD2(x.uvOrigin, y.uvOrigin), SIMD2(x.uvSize, y.uvSize))
    }

    /// A copy of `region` of `source` with its mipmaps, encoded into `commandBuffer`, which has no encoder open: a blit of
    /// those pixels of its level 0, then `generateMipmaps`. Throws `RenderError.metalResourceUnavailable`, having encoded
    /// nothing, when Metal cannot make the copy or the blit pass.
    func copy(of source: any MTLTexture, region: MTLRegion, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        guard let copy = take(width: region.size.width, height: region.size.height, pixelFormat: source.pixelFormat) else {
            throw RenderError.metalResourceUnavailable("mipmapped copy of the screen")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            give(copy)
            throw RenderError.metalResourceUnavailable("blit pass for the screen's mipmaps")
        }
        blit.label = "Compositor mipmaps"
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: copy.texture,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: copy.texture)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { [self] _ in give(copy) }
        return copy.texture
    }

    /// A free copy of that size and format, or a new one.
    private func take(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Copy? {
        let size = Size(width: width, height: height, pixelFormat: pixelFormat)
        let reused = state.withLock { state -> Copy? in
            state.ask(size)
            let index = state.free.lastIndex { Size(of: $0.texture) == size }
            return index.map { state.free.remove(at: $0) }
        }
        if let reused { return reused }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        return state.withLock { state in
            state.made += 1
            return Copy(texture)
        }
    }

    private func give(_ copy: Copy) {
        state.withLock { state in
            // One of a size no longer asked for goes.
            guard state.sizes.contains(Size(of: copy.texture)) else { return }
            state.free.append(copy)
            if state.free.count > Self.kept { state.free.removeFirst() }
        }
    }
}
