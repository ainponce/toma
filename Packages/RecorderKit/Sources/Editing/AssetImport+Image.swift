// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ProjectFormat

/// A TIFF, a GIF or a PDF of the user's own (phase 3 design §5.4; phase 3a plan, decision 14): decoded once, as it is
/// imported, and placed in `assets/` as the PNG of what it shows. A package can come from anywhere, so its assets are
/// only ever decoded as PNG, JPEG or HEIC (`PackageFileKind.asset.imageTypes`, 1b's rule); the user's own file, which
/// they chose, is the one place those other decoders are reached from, and only by what its name says it is.
extension AssetImport {
    /// The images converted to PNG as they are imported, by their extension lowercased: TIFF, GIF and PDF.
    public static let convertedExtensions = ["tif", "tiff", "gif", "pdf"]

    /// Every image an import takes, by its extension lowercased (`jpeg` as `jpg`): the ones copied as they are
    /// (`allowedExtensions`), then the ones converted (`convertedExtensions`).
    public static let importableImageExtensions = allowedExtensions + convertedExtensions

    /// The longer side, in pixels, a PDF's first page is drawn at.
    public static let pdfLongestSide = 4_096

    /// The PNG the image `data` of the user's, named with `extension` (one of `convertedExtensions`), is placed as;
    /// `nil` if it is not one, or does not decode as what its extension says.
    ///
    /// - A TIFF (`tif`, `tiff`) or a GIF: read by ImageIO only if its content is of that type (`public.tiff`,
    ///   `com.compuserve.gif`), its first image (a TIFF's first page, a GIF's first frame) whole, of a size its header
    ///   gives, at most `PackageFileKind.asset.maxPixelSide` a side (checked before anything is decoded). It is decoded
    ///   upright by its orientation, reduced so its longer side is at most `PackageFileKind.largestDecodedSide` (what the
    ///   asset's reader would reduce it to; never enlarged), and drawn into sRGB at 8 bits a component, with its alpha if
    ///   it has one.
    /// - A PDF: its first page, unless the document is encrypted (with or without a password to open it) or has none.
    ///   Its crop box, turned as its `/Rotate` says, is drawn on opaque white into sRGB so its longer side is
    ///   `pdfLongestSide` pixels (its shorter one at least 1).
    ///
    /// The PNG is `nil` too if it would be larger than `PackageFileKind.asset.maxBytes`, which the asset's reader never
    /// reads. The same `data` always gives the same bytes, so the same file is one asset. It decodes and draws:
    /// call it off the main thread.
    static func convertedPNG(of data: Data, extension ext: String) -> Data? {
        let image: CGImage?
        switch ext {
        case "tif", "tiff": image = convertedImage(of: data, type: "public.tiff")
        case "gif": image = convertedImage(of: data, type: "com.compuserve.gif")
        case "pdf": image = firstPage(of: data)
        default: image = nil
        }
        guard let image, let png = pngData(of: image), png.count <= PackageFileKind.asset.maxBytes else { return nil }
        return png
    }

    /// `convertedPNG(of:extension:)` of the user's file `source`, opened by `openSource(_:as:)`: read whole, at most one
    /// byte more than its size (a file that grew or shrank since it was measured is `changed`), and converted. A file
    /// that does not convert is `source(EFTYPE)`.
    static func convertedPNG(of source: (fd: Int32, size: off_t, ext: String)) throws(Failure) -> Data {
        let data: Data
        do {
            data = try readAll(source.fd, size: Int(source.size), atMost: Int(source.size) + 1)
        } catch {
            throw .source(error)
        }
        guard data.count == Int(source.size) else { throw .changed }
        guard let png = convertedPNG(of: data, extension: source.ext) else { throw .source(POSIXError(.EFTYPE)) }
        return png
    }

    // MARK: - Private

    /// The first image of `data`, read by ImageIO as `type` alone, as `convertedPNG(of:extension:)` says.
    private static func convertedImage(of data: Data, type: String) -> CGImage? {
        let kind = PackageFileKind.asset
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0, width <= kind.maxPixelSide, height <= kind.maxPixelSide,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return nil }
        // From the full image (never a thumbnail the file carries), upright, decoded now.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(PackageFileKind.largestDecodedSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = sRGBContext(width: image.width, height: image.height, opaque: opaque) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The first page of the PDF `data`, as `convertedPNG(of:extension:)` says.
    private static func firstPage(of data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
            !document.isEncrypted, document.numberOfPages > 0, let page = document.page(at: 1)
        else { return nil }
        let box = page.getBoxRect(.cropBox).standardized
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        // A quarter turn either way swaps the sides it is shown with.
        let turned = abs(Int(page.rotationAngle)) % 180 == 90
        let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = Double(pdfLongestSide) / max(shown.width, shown.height)
        let width = min(pdfLongestSide, max(1, Int((shown.width * scale).rounded())))
        let height = min(pdfLongestSide, max(1, Int((shown.height * scale).rounded())))
        guard let context = sRGBContext(width: width, height: height, opaque: true) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        context.interpolationQuality = .high
        // The page's own transform turns its crop box into a rect of its shown size; scaled from there to the pixels.
        context.scaleBy(x: Double(width) / shown.width, y: Double(height) / shown.height)
        context.concatenate(
            page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// A context of `width` × `height` pixels in sRGB at 8 bits a component: RGBA with premultiplied alpha, or RGB
    /// with no alpha if `opaque`.
    private static func sRGBContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: alpha.rawValue)
    }

    /// `image` as a PNG file.
    private static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
