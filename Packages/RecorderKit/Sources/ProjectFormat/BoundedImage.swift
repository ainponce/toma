// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO

/// Decodes an image of a package (a cursor, a wallpaper photo, a background of the user's own) only once its format,
/// read from the content, is one allowed and its size, read from the file's header, is known to be within bounds: a
/// package can come from anywhere, and a small file can claim an image too large to fit in memory.
public enum BoundedImage {
    /// The image's primary picture as 8-bit RGBA with premultiplied alpha last (in its own color space if that is RGB,
    /// otherwise sRGB), or `nil` if ImageIO does not read the content as one of `allowedTypes` (uniform type
    /// identifiers such as `public.png`; by default the formats of `PackageFileKind.asset`), if the file is not read
    /// whole, if its width or height is more than `maxPixelSide` (checked before anything is decoded), if it is a PNG
    /// cut short or if it does not decode.
    ///
    /// With `longSide`, the image is decoded already reduced so its longer side is at most `longSide` (never
    /// enlarged), from the full image (never the small thumbnail a JPEG or HEIC may carry) and turned upright as its
    /// EXIF orientation says. Without it, the pixels are decoded as stored. Either way they are in memory when this
    /// returns, never decoded later when drawn (a file that fails to decode gives `nil` here), at 4 bytes a pixel: a
    /// 16-bit PNG comes out 8-bit.
    public static func decode(
        _ data: Data, maxPixelSide: Int, reducedTo longSide: Int? = nil,
        allowedTypes: Set<String> = PackageFileKind.asset.imageTypes
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxPixelSide, height <= maxPixelSide,
              CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
              type != pngType || isWholePNG(data)
        else { return nil }
        let decoded: CGImage?
        if let longSide {
            guard longSide > 0 else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longSide, max(width, height)),
            ]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        return decoded.flatMap(eightBitRGBA)
    }

    private static let pngType = "public.png"

    /// `image` drawn as it is into 8-bit RGBA with premultiplied alpha last. ImageIO keeps a 16-bit PNG at 16 bits a
    /// component (8 bytes a pixel), even reduced, and leaves a large image to decode when it is first drawn, even
    /// asked to cache it at once; drawing it here does both now, the same way for every file.
    private static func eightBitRGBA(_ image: CGImage) -> CGImage? {
        let rgb = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let context = eightBitRGBAContext(for: image, in: rgb)
            ?? eightBitRGBAContext(for: image, in: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// `nil` without a color space, or with one a context of 8 bits a component does not support.
    private static func eightBitRGBAContext(for image: CGImage, in space: CGColorSpace?) -> CGContext? {
        guard let space else { return nil }
        return CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Whether `data`, a PNG, holds every chunk whole up to its `IEND`. ImageIO says a PNG cut short is complete
    /// (`CGImageSourceGetStatusAtIndex` gives `.statusComplete`) and decodes it without an error, with the rows it
    /// lacks filled in, so the cut is found here. Bytes after `IEND` are allowed, as decoders ignore them.
    private static func isWholePNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let end = Array("IEND".utf8)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.starts(with: signature) else { return false }
            // Each chunk: a 4-byte big-endian length, a 4-byte type, the data and a 4-byte CRC.
            var offset = signature.count
            while bytes.count - offset >= 12 {
                let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
                guard length <= bytes.count - offset - 12 else { return false }
                if bytes[(offset + 4)..<(offset + 8)].elementsEqual(end) { return true }
                offset += 12 + length
            }
            return false
        }
    }
}
