// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Metal

/// The redrawn cursor: an original arrow (black with a white outline, no Apple artwork) drawn with
/// CoreGraphics into a 96×128 px premultiplied BGRA texture, its tip at the top-left corner.
///
/// Each mip level is drawn from the vector shape at its own size, so the arrow stays crisp at the
/// 20–50 px it is usually shown at.
public enum CursorSprite {
    /// The point of the sprite placed at the cursor position, as a fraction of its size (0, 0 is the
    /// top-left corner): the arrow's tip.
    public static let hotspot = SIMD2<Double>(0, 0)
    /// Width over height of the sprite.
    public static let aspect = 0.75

    static let width = 96
    static let height = 128
    /// Half the outline's width, in pixels of level 0: the arrow's path is inset by it, so the outline
    /// fits inside the sprite and its outer edge reaches the top-left corner.
    private static let outline = 6.0
    /// The arrow's path, in fractions of the inset height, y growing down, tip first.
    private static let arrow: [SIMD2<Double>] = [
        [0, 0], [0, 0.78], [0.19, 0.615], [0.31, 0.885], [0.43, 0.835], [0.315, 0.575], [0.55, 0.575],
    ]

    public static func makeTexture(device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("cursor texture")
        }
        for level in 0..<texture.mipmapLevelCount {
            let levelWidth = max(1, width >> level), levelHeight = max(1, height >> level)
            let bytes = try draw(width: levelWidth, height: levelHeight)
            texture.replace(
                region: MTLRegionMake2D(0, 0, levelWidth, levelHeight), mipmapLevel: level,
                withBytes: bytes, bytesPerRow: levelWidth * 4)
        }
        return texture
    }

    /// The arrow scaled to `width`×`height`, as premultiplied BGRA rows from the top.
    private static func draw(width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("cursor bitmap") }
            // Level-0 pixels, y down, origin at the top left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: CGFloat(width) / CGFloat(Self.width), y: -CGFloat(height) / CGFloat(Self.height))
            let scale = Double(Self.height) - 2 * outline
            let path = CGMutablePath()
            path.addLines(between: arrow.map { CGPoint(x: outline + $0.x * scale, y: outline + $0.y * scale) })
            path.closeSubpath()
            context.addPath(path)
            context.setLineJoin(.round)
            context.setLineWidth(2 * outline)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.strokePath()
            context.addPath(path)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fillPath()
        }
        return bytes
    }
}
