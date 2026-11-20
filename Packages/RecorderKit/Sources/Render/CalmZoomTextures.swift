// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import Synchronization

/// The textures the calm zoom's Dim and loupe draw through (plan 3b decision 8): the copy of the frame as drawn (whole
/// with its mipmaps for Dim, the lens's box for the loupe) and Dim's two blur passes. One for each frame on the GPU, of
/// its kind (size, format and levels), kept once the GPU is done with that frame for a later one to use again, so a frame
/// never writes into a texture another frame still reads, as `MipmappedCopies` keeps the screen's copies. Only textures
/// of the last kinds asked for are kept (Dim's three and a lens's), and apart from the screen's copies, so neither
/// displaces the other.
///
/// A frame's completion hands its textures back on a thread of Metal's, which reads nothing of this but through
/// `state`'s lock: what Metal orders between a commit and its completion, the thread sanitizer cannot see.
final class CalmZoomTextures: @unchecked Sendable {
    /// The most textures kept for later frames: past it the oldest is let go. Four kinds of three frames on the GPU (the
    /// preview's drawables, the export's).
    private static let kept = 12
    /// How many kinds of textures are kept: Dim's copy and its blur's two, and a lens's copy.
    private static let keptKinds = 4

    /// A texture, to be handed back: textures are not `Sendable`. Made with `state`'s lock held.
    private final class Held: @unchecked Sendable {
        let texture: any MTLTexture

        init(_ texture: any MTLTexture) {
            self.texture = texture
        }
    }

    /// A texture's size, format and mipmap levels.
    private struct Kind: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: MTLPixelFormat
        var levels: Int

        init(width: Int, height: Int, pixelFormat: MTLPixelFormat, levels: Int) {
            (self.width, self.height, self.pixelFormat, self.levels) = (width, height, pixelFormat, levels)
        }

        init(of texture: any MTLTexture) {
            self.init(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat, levels: texture.mipmapLevelCount)
        }
    }

    private struct State {
        /// The textures no frame on the GPU uses, oldest first.
        var free: [Held] = []
        /// How many were made, for tests.
        var made = 0
        /// The kinds last asked for, the latest last: `keptKinds` at most.
        var kinds: [Kind] = []
        /// For tests: every texture fails as when Metal cannot make one.
        var failing = false

        /// Notes that `kind` was asked for, and lets go of the free textures of a kind no longer among the last ones.
        mutating func ask(_ kind: Kind) {
            kinds.removeAll { $0 == kind }
            kinds.append(kind)
            if kinds.count > CalmZoomTextures.keptKinds { kinds.removeFirst(kinds.count - CalmZoomTextures.keptKinds) }
            free.removeAll { !kinds.contains(Kind(of: $0.texture)) }
        }
    }

    private let device: any MTLDevice
    private let state = Mutex(State())

    init(device: any MTLDevice) {
        self.device = device
    }

    /// How many textures were made so far, and how many no frame on the GPU uses: for tests.
    var count: (made: Int, free: Int) { state.withLock { ($0.made, $0.free.count) } }

    /// For tests: every texture asked for while it is set fails, as when Metal cannot make one.
    var failsForTests: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    /// A private texture `width` × `height` of `pixelFormat` with `levels` mipmap levels, that shaders read and render
    /// passes and blits write, for a frame encoded into `commandBuffer`: free, or new, and handed back when
    /// `commandBuffer` completes. Throws `RenderError.metalResourceUnavailable` when Metal cannot make it.
    func texture(
        width: Int, height: Int, pixelFormat: MTLPixelFormat, levels: Int = 1, commandBuffer: any MTLCommandBuffer
    ) throws -> any MTLTexture {
        let kind = Kind(width: max(width, 1), height: max(height, 1), pixelFormat: pixelFormat, levels: max(levels, 1))
        guard let held = take(kind) else { throw RenderError.metalResourceUnavailable("the calm zoom's copy of the frame") }
        commandBuffer.addCompletedHandler { [self] _ in give(held) }
        return held.texture
    }

    /// A free texture of that kind, or a new one; `nil` when Metal cannot make it, or for tests.
    private func take(_ kind: Kind) -> Held? {
        let (failing, reused) = state.withLock { state -> (Bool, Held?) in
            guard !state.failing else { return (true, nil) }
            state.ask(kind)
            let index = state.free.lastIndex { Kind(of: $0.texture) == kind }
            return (false, index.map { state.free.remove(at: $0) })
        }
        guard !failing else { return nil }
        if let reused { return reused }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: kind.pixelFormat, width: kind.width, height: kind.height, mipmapped: kind.levels > 1)
        descriptor.mipmapLevelCount = kind.levels
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Compositor calm zoom"
        return state.withLock { state in
            state.made += 1
            return Held(texture)
        }
    }

    private func give(_ held: Held) {
        state.withLock { state in
            // One of a kind no longer asked for goes.
            guard state.kinds.contains(Kind(of: held.texture)) else { return }
            state.free.append(held)
            if state.free.count > Self.kept { state.free.removeFirst() }
        }
    }
}
