// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Metal
import ProjectFormat

/// The textures of one renderer's cursors (`CursorLayer.image`), each made the first time a frame shows it and kept:
/// Toma's (`CursorSprite`, the arrow made up front), and the images the take recorded.
///
/// - A recorded image, `takes/<take>/cursors/<hash>.png`, is read only through the package's safe reader
///   (`ProjectPackage.cursorImage(take:hash:)`: no link followed, nothing but a regular PNG of at most 1 MiB and 512 px a
///   side). One that is missing or cannot be read has no texture, which is kept too, so it is not looked for again on
///   every frame; the frame draws the arrow for it (`FrameEvaluator.frame(at:cursorImageIsReadable:)`). Its pixel size
///   says nothing of the size it is drawn at, which is its event's, in points.
/// - Each is uploaded as the bytes of a fixed sRGB `CGContext` (premultiplied BGRA, as `CursorSprite` draws) to a
///   `.bgra8Unorm` texture, never an `_srgb` one, which would linearize them when sampled; with mipmaps, each level the
///   image drawn at that level's size, so a cursor drawn smaller than its image does not alias.
///
/// Not thread-safe: `FrameRenderer` uses it with its lock held.
final class CursorImages {
    private let device: any MTLDevice
    private let package: ProjectPackage
    private let take: String
    private var tomaTextures: [CursorKind: any MTLTexture]
    /// By hash: `nil` for an image that is missing or cannot be read.
    private var recorded: [String: (any MTLTexture)?] = [:]

    /// - Throws: `RenderError.metalResourceUnavailable` if Metal cannot make the arrow's texture.
    init(device: any MTLDevice, package: ProjectPackage, take: String) throws {
        self.device = device
        self.package = package
        self.take = take
        tomaTextures = [.arrow: try CursorSprite.makeTexture(device: device, kind: .arrow)]
    }

    /// The texture of `image`: for a recorded one that cannot be read, the arrow's.
    /// - Throws: `RenderError.metalResourceUnavailable` if Metal cannot make it.
    func texture(for image: CursorImageRef) throws -> any MTLTexture {
        switch image {
        case let .toma(kind): try tomaTexture(kind)
        case let .recorded(hash): try recordedTexture(hash) ?? tomaTexture(.arrow)
        }
    }

    /// Whether the take's image `hash` can be read and drawn.
    /// - Throws: `RenderError.metalResourceUnavailable` if Metal cannot make its texture.
    func isReadable(_ hash: String) throws -> Bool {
        try recordedTexture(hash) != nil
    }

    private func tomaTexture(_ kind: CursorKind) throws -> any MTLTexture {
        if let texture = tomaTextures[kind] { return texture }
        let texture = try CursorSprite.makeTexture(device: device, kind: kind)
        tomaTextures[kind] = texture
        return texture
    }

    private func recordedTexture(_ hash: String) throws -> (any MTLTexture)? {
        if let texture = recorded[hash] { return texture }
        let texture = try package.cursorImage(take: take, hash: hash).flatMap(upload)
        recorded.updateValue(texture, forKey: hash)
        return texture
    }

    /// `image` as a `.bgra8Unorm` texture with mipmaps; `nil` when CoreGraphics cannot draw it.
    private func upload(_ image: CGImage) throws -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("cursor image texture")
        }
        for level in 0..<texture.mipmapLevelCount {
            let width = max(1, image.width >> level), height = max(1, image.height >> level)
            guard let bytes = Self.draw(image, width: width, height: height) else { return nil }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level, withBytes: bytes, bytesPerRow: width * 4)
        }
        return texture
    }

    /// `image` scaled to `width` × `height`, as premultiplied sRGB BGRA rows from the top; `nil` without a context.
    private static func draw(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
