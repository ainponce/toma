// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share: a package, a session's context, and real TIFF, GIF and PDF files made in code.
private enum FormatFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(caches: URL) -> EditContext {
        let count = Mutex(0)
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.3.0"), cachesRoot: caches, defaultStyle: .toma,
            now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            })
    }

    /// A take of 1 s of one display, in a new version 3 package. Written off the main actor, where the sessions live.
    @concurrent static func package(in dir: URL) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "Formats")
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: 320, height: 180)])
        return try builder.write()
    }

    @MainActor static func session(of project: LoadedProject, in dir: URL) async throws -> EditSession {
        let session = try await EditSession.open(project.package.url, take: nil, context: context(caches: dir.appending(path: "Caches")))
        #expect(session.access == .editable)
        return session
    }

    /// A `width` × `height` image of 8 bits a component in sRGB, its left `opaqueFraction` filled with the color and
    /// the rest transparent.
    static func image(
        red: Double, green: Double, blue: Double, width: Int = 32, height: Int = 16, opaqueFraction: Double = 1
    ) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(width) * opaqueFraction, height: Double(height)))
        return try #require(context.makeImage())
    }

    /// `images` as one file of `type`, each with `properties`.
    static func encoded(_ images: [CGImage], as type: UTType, properties: [CFString: Any]? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary?) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A GIF of two frames, red and then blue.
    static func animatedGIF() throws -> Data {
        try encoded(
            [image(red: 1, green: 0, blue: 0, width: 24), image(red: 0, green: 0, blue: 1, width: 24)], as: .gif,
            properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
    }

    /// A TIFF of 16 bits a component in CMYK, filled with magenta and yellow: a red.
    static func cmyk16TIFF() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 16, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.genericCMYK)!, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(genericCMYKCyan: 0, magenta: 1, yellow: 1, black: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = try #require(context.makeImage())
        #expect(image.bitsPerComponent == 16 && image.colorSpace?.model == .cmyk)
        return try encoded([image], as: .tiff)
    }

    /// A PDF of `pages` pages of `box`: the first with its left half red, the others all blue. With a user password it
    /// opens only with it; with an owner password alone it opens, encrypted.
    static func pdf(
        pages: Int, box: CGRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89), userPassword: String? = nil,
        ownerPassword: String? = nil
    ) throws -> Data {
        let data = NSMutableData()
        var mediaBox = box
        var info: [CFString: Any] = [:]
        if let userPassword { info[kCGPDFContextUserPassword] = userPassword }
        if let ownerPassword { info[kCGPDFContextOwnerPassword] = ownerPassword }
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            if page == 0 {
                context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height))
            } else {
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
                context.fill(box)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PDF written by hand, its objects in order with a correct cross-reference table: a catalog, a page tree of
    /// `pages` (the page objects that follow, each `page` the dictionary of one, which names its content as the
    /// object after it) and, for each page, its content `content`.
    static func handmadePDF(pages: [String], content: String) -> Data {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pages.indices.map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
        ]
        for (index, page) in pages.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R \(page) /Contents \(4 + 2 * index) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }

    /// A TIFF written by hand that declares an image of `width` × `height` pixels of 8-bit gray in one strip, with 64
    /// bytes of pixels: a small file that claims a picture far too large.
    static func declaredTIFF(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func short(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func long(_ value: UInt32) { data.append(contentsOf: (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        // Tag, type (3 short, 4 long), value.
        let entries: [(UInt16, UInt16, UInt32)] = [
            (256, 4, width), (257, 4, height), (258, 3, 8), (259, 3, 1), (262, 3, 1), (273, 4, 200), (277, 3, 1),
            (278, 4, height), (279, 4, 64),
        ]
        short(UInt16(entries.count))
        for (tag, type, value) in entries {
            short(tag)
            short(type)
            long(1)
            if type == 3 {
                short(UInt16(value))
                short(0)
            } else {
                long(value)
            }
        }
        long(0)
        data.append(Data(count: 200 - data.count))
        data.append(Data(repeating: 0x80, count: 64))
        return data
    }

    /// The name of an asset of `data`: 32 hex digits of its SHA-256.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The path of `.imported`, or a recorded issue.
    static func path(_ outcome: AssetImportOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard case let .imported(path) = outcome else {
            Issue.record("not imported: \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return path
    }

    /// `data` written as `name` in `dir`.
    static func file(_ name: String, _ data: Data, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }
}

/// An image's pixels in 8-bit sRGB RGBA with premultiplied alpha, rows from the top.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: FormatFixture.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        (self.width, self.height, self.bytes) = (width, height, bytes)
    }

    /// The pixel `x` from the left and `y` from the top.
    subscript(x x: Int, y y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(bytes[start..<(start + 4)])
    }

    /// Whether every pixel is opaque.
    var isOpaque: Bool { stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 } }
}

/// Whether `pixel` is `expected` within `tolerance` in each component.
private func near(_ pixel: [UInt8], _ expected: [UInt8], within tolerance: Int = 3) -> Bool {
    zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

/// TIFF, GIF and PDF images are decoded as they are imported and placed as PNG (phase 3 design §5.4; phase 3a plan,
/// Task A4, decision 14): a package's asset is only ever decoded as a PNG, a JPEG or a HEIC.
@Suite struct ImageImportFormatsTests {
    @Test func theExtensionsImported() {
        #expect(AssetImport.allowedExtensions == ["png", "jpg", "heic"])
        #expect(AssetImport.convertedExtensions == ["tif", "tiff", "gif", "pdf"])
        #expect(AssetImport.importableImageExtensions == ["png", "jpg", "heic", "tif", "tiff", "gif", "pdf"])
        #expect(AssetImport.pdfLongestSide == 4_096)
    }

    @MainActor @Test func tiffGifAndPdfBecomePNG() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)
            let files = try [
                ("Scan.tif", FormatFixture.encoded([FormatFixture.image(red: 0.1, green: 0.6, blue: 0.3)], as: .tiff)),
                ("Other Scan.TIFF", FormatFixture.encoded([FormatFixture.image(red: 0.7, green: 0.2, blue: 0.3)], as: .tiff)),
                ("Animation.gif", FormatFixture.animatedGIF()),
                ("Slides.PDF", FormatFixture.pdf(pages: 3)),
            ]
            var placed: [String] = []
            for (name, data) in files {
                let url = try FormatFixture.file(name, data, in: dir)
                let path = try #require(FormatFixture.path(await session.importAsset(url)))
                let png = try Data(contentsOf: package.fileURL(path))
                // Named by the PNG's bytes, as any asset is by its own.
                #expect(path == "assets/\(FormatFixture.hash(png)).png", "\(name)")
                #expect(PackageFileKind.asset.isValidName(String(path.dropFirst("assets/".count))))
                #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(name)")
                // What the render's reader decodes, through the package's safe readers.
                #expect(PackageFileKind.asset.decodedImage(png) != nil, "\(name)")
                #expect(package.asset(path) != nil, "\(name)")
                #expect(await MediaInfo.imageSize(path, in: package) != nil, "\(name)")
                placed.append(String(path.dropFirst("assets/".count)))
            }
            // One PNG each and nothing else: no temporary file left, no copy of the original.
            #expect(try FormatFixture.names(in: package.assetsURL) == placed.sorted())
            #expect(Set(placed).count == files.count)

            // A 1-pixel-high TIFF wider than an asset is decoded: reduced to that, as the reader would.
            let wide = try FormatFixture.file(
                "Wide.tiff", FormatFixture.encoded([FormatFixture.image(red: 0, green: 0, blue: 1, width: 8_000, height: 4)], as: .tiff),
                in: dir)
            let widePath = try #require(FormatFixture.path(await session.importAsset(wide)))
            let wideImage = try #require(package.asset(widePath))
            #expect(wideImage.width == PackageFileKind.largestDecodedSide)
            #expect(wideImage.height == 4)

            // A TIFF turned by its orientation comes in upright, with no orientation of its own.
            let turned = try FormatFixture.file(
                "Turned.tif",
                FormatFixture.encoded(
                    [FormatFixture.image(red: 0.2, green: 0.2, blue: 0.9, width: 40, height: 20)], as: .tiff,
                    properties: [kCGImagePropertyOrientation: 6]),
                in: dir)
            let turnedPath = try #require(FormatFixture.path(await session.importAsset(turned)))
            #expect(await MediaInfo.imageSize(turnedPath, in: package) == SIMD2(20, 40))
            let upright = try #require(package.asset(turnedPath))
            #expect(upright.width == 20 && upright.height == 40)

            // `AssetImport.copy` converts as `importAsset` does.
            let copied = try AssetImport.copy(try FormatFixture.file("Again.gif", FormatFixture.animatedGIF(), in: dir), into: package)
            #expect(copied == "assets/\(placed[2])")
            await session.close()
        }
    }

    @MainActor @Test func gifIsItsFirstFrame() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let session = try await FormatFixture.session(of: project, in: dir)
            let url = try FormatFixture.file("Animation.gif", FormatFixture.animatedGIF(), in: dir)
            let path = try #require(FormatFixture.path(await session.importAsset(url)))
            let pixels = try Pixels(#require(project.package.asset(path)))
            #expect(pixels.width == 24 && pixels.height == 16)
            #expect(near(pixels[x: 3, y: 3], [255, 0, 0, 255]), "\(pixels[x: 3, y: 3])")
            #expect(near(pixels[x: 20, y: 12], [255, 0, 0, 255]), "\(pixels[x: 20, y: 12])")
            await session.close()
        }
    }

    @MainActor @Test func pdfIsItsFirstPageOnWhite() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)

            // An A4 document of 300 pages: its first page, its longer side 4 096 pixels, on opaque white.
            let url = try FormatFixture.file("Manual.pdf", FormatFixture.pdf(pages: 300), in: dir)
            let path = try #require(FormatFixture.path(await session.importAsset(url)))
            let pixels = try Pixels(#require(package.asset(path)))
            #expect(pixels.height == AssetImport.pdfLongestSide)
            #expect(pixels.width == Int((595.28 * 4_096 / 841.89).rounded()), "\(pixels.width)")
            #expect(pixels.isOpaque)
            #expect(near(pixels[x: 100, y: 2_000], [255, 0, 0, 255]), "\(pixels[x: 100, y: 2_000])")
            #expect(near(pixels[x: pixels.width - 100, y: 2_000], [255, 255, 255, 255]), "\(pixels[x: pixels.width - 100, y: 2_000])")
            #expect(near(pixels[x: pixels.width - 1, y: pixels.height - 1], [255, 255, 255, 255]))

            // A landscape page, away from the origin: its longer side across.
            let landscape = try FormatFixture.file(
                "Landscape.pdf", FormatFixture.pdf(pages: 1, box: CGRect(x: 50, y: 30, width: 400, height: 100)), in: dir)
            let widePath = try #require(FormatFixture.path(await session.importAsset(landscape)))
            let wide = try Pixels(#require(package.asset(widePath)))
            #expect(wide.width == 4_096 && wide.height == 1_024)
            #expect(near(wide[x: 10, y: 512], [255, 0, 0, 255]) && near(wide[x: 4_086, y: 512], [255, 255, 255, 255]))

            // A page that says it is shown turned a quarter clockwise, and its crop box: as a viewer shows it. Its
            // left half, red, is the top once turned.
            let rotated = try FormatFixture.file(
                "Rotated.pdf",
                FormatFixture.handmadePDF(
                    pages: ["/MediaBox [0 0 400 100] /CropBox [0 0 200 100] /Rotate 90"], content: "1 0 0 rg 0 0 100 100 re f"),
                in: dir)
            let turnedPath = try #require(FormatFixture.path(await session.importAsset(rotated)))
            let turned = try Pixels(#require(package.asset(turnedPath)))
            #expect(turned.width == 2_048 && turned.height == 4_096, "\(turned.width) × \(turned.height)")
            #expect(near(turned[x: 1_024, y: 1_000], [255, 0, 0, 255]), "\(turned[x: 1_024, y: 1_000])")
            #expect(near(turned[x: 1_024, y: 3_000], [255, 255, 255, 255]), "\(turned[x: 1_024, y: 3_000])")
            await session.close()
        }
    }

    @MainActor @Test func tiffKeepsItsAlpha() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)

            // Its left half green, its right half transparent: so it stays.
            let half = try FormatFixture.encoded(
                [FormatFixture.image(red: 0, green: 1, blue: 0, width: 32, height: 16, opaqueFraction: 0.5)], as: .tiff)
            let path = try #require(FormatFixture.path(await session.importAsset(FormatFixture.file("Cutout.tiff", half, in: dir))))
            let pixels = try Pixels(#require(package.asset(path)))
            #expect(pixels.width == 32 && pixels.height == 16)
            #expect(near(pixels[x: 4, y: 8], [0, 255, 0, 255]), "\(pixels[x: 4, y: 8])")
            #expect(pixels[x: 28, y: 8] == [0, 0, 0, 0], "\(pixels[x: 28, y: 8])")

            // 16 bits a component in CMYK: in sRGB, 8 bits, opaque, red.
            let cmyk = try #require(FormatFixture.path(
                await session.importAsset(FormatFixture.file("Print.tif", FormatFixture.cmyk16TIFF(), in: dir))))
            let png = try Data(contentsOf: package.fileURL(cmyk))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelRGB as String)
            #expect((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8)
            let red = try Pixels(#require(package.asset(cmyk)))
            #expect(red.width == 20 && red.height == 10 && red.isOpaque)
            let pixel = red[x: 10, y: 5]
            #expect(pixel[0] > 200 && pixel[1] < 90 && pixel[2] < 90, "\(pixel)")
            await session.close()
        }
    }

    @MainActor @Test func pngJpegAndHeicStillClone() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let session = try await FormatFixture.session(of: project, in: dir)
            let picture = try FormatFixture.image(red: 0.8, green: 0.3, blue: 0.5)
            for (name, type, ext) in [("Background.png", UTType.png, "png"), ("Photo.jpeg", .jpeg, "jpg"), ("Photo.HEIC", .heic, "heic")] {
                let data = try FormatFixture.encoded([picture], as: type)
                let path = try #require(FormatFixture.path(await session.importAsset(FormatFixture.file(name, data, in: dir))))
                #expect(path == "assets/\(FormatFixture.hash(data)).\(ext)")
                #expect(try Data(contentsOf: project.package.fileURL(path)) == data, "\(name)")
            }
            await session.close()
        }
    }

    @MainActor @Test func brokenOrEncryptedPdfIsNotAnImage() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)
            let whole = try FormatFixture.pdf(pages: 2)
            let pdfs = try [
                ("Locked.pdf", FormatFixture.pdf(pages: 1, userPassword: "secret", ownerPassword: "owner")),
                ("Restricted.pdf", FormatFixture.pdf(pages: 1, ownerPassword: "owner")),
                ("Garbage.pdf", Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
                ("Header Only.pdf", Data("%PDF-1.7\n%%EOF\n".utf8)),
                ("Cut.pdf", whole.prefix(whole.count / 2)),
                ("No Pages.pdf", FormatFixture.handmadePDF(pages: [], content: "")),
                ("Picture.pdf", FormatFixture.encoded([FormatFixture.image(red: 1, green: 0, blue: 0)], as: .png)),
            ]
            for (name, data) in pdfs {
                let url = try FormatFixture.file(name, data, in: dir)
                #expect(await session.importAsset(url) == .notAnImage, "\(name)")
                #expect(throws: POSIXError(.EFTYPE), "\(name)") { try AssetImport.copy(url, into: package) }
            }
            // Nothing written: not even `assets/`.
            #expect(!FileManager.default.fileExists(atPath: package.assetsURL.path))
            await session.close()
        }
    }

    @MainActor @Test func malformedOrHugeImagesAreNotImages() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)
            let gif = try FormatFixture.animatedGIF()
            var hugeCanvas = gif
            // The logical screen of 20 000 × 20 000 pixels, little-endian at bytes 6 to 9.
            hugeCanvas.replaceSubrange(6..<10, with: [0x20, 0x4E, 0x20, 0x4E])
            let files = try [
                ("Huge.tiff", FormatFixture.declaredTIFF(width: 100_000, height: 100_000)),
                ("Tall.tif", FormatFixture.declaredTIFF(width: 8, height: 20_000)),
                // A real one, whole, one pixel wider than any asset is decoded: refused before it is decoded.
                ("Banner.tif", FormatFixture.encoded(
                    [FormatFixture.image(red: 0, green: 0, blue: 1, width: PackageFileKind.asset.maxPixelSide + 1, height: 2)],
                    as: .tiff)),
                ("Huge.gif", hugeCanvas),
                ("Cut.gif", gif.prefix(gif.count / 2)),
                ("Picture.gif", FormatFixture.encoded([FormatFixture.image(red: 1, green: 0, blue: 0)], as: .png)),
                ("Photo.tiff", FormatFixture.encoded([FormatFixture.image(red: 1, green: 0, blue: 0)], as: .jpeg)),
                ("Empty.gif", Data()),
            ]
            for (name, data) in files {
                let url = try FormatFixture.file(name, data, in: dir)
                #expect(await session.importAsset(url) == .notAnImage, "\(name)")
                #expect(throws: POSIXError(.EFTYPE), "\(name)") { try AssetImport.copy(url, into: package) }
            }
            // Larger than an asset is read: never read at all.
            let large = dir.appending(path: "Large.pdf")
            let fd = open(large.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            #expect(fd >= 0)
            #expect(ftruncate(fd, off_t(PackageFileKind.asset.maxBytes + 1)) == 0)
            close(fd)
            #expect(await session.importAsset(large) == .notAnImage)
            #expect(throws: POSIXError(.EFBIG)) { try AssetImport.copy(large, into: package) }
            // Not there, or not a file.
            #expect(await session.importAsset(dir.appending(path: "Missing.gif")) == .notAnImage)
            let folder = dir.appending(path: "Folder.tiff", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            #expect(await session.importAsset(folder) == .notAnImage)
            #expect(!FileManager.default.fileExists(atPath: package.assetsURL.path))
            await session.close()
        }
    }

    @MainActor @Test func theSameFileTwiceIsOneAsset() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await FormatFixture.package(in: dir)
            let package = project.package
            let session = try await FormatFixture.session(of: project, in: dir)
            let tiff = try FormatFixture.cmyk16TIFF()
            let pdf = try FormatFixture.pdf(pages: 2)
            var paths: [String] = []
            for (first, second, data) in [("A.tiff", "Copy of A.TIF", tiff), ("B.pdf", "Copy of B.pdf", pdf)] {
                let one = try #require(FormatFixture.path(await session.importAsset(FormatFixture.file(first, data, in: dir))))
                let two = try #require(FormatFixture.path(await session.importAsset(FormatFixture.file(second, data, in: dir))))
                #expect(one == two, "\(first)")
                #expect(try AssetImport.copy(dir.appending(path: first), into: package) == one)
                paths.append(String(one.dropFirst("assets/".count)))
            }
            #expect(try FormatFixture.names(in: package.assetsURL) == paths.sorted())
            await session.close()
        }
    }

    @Test func thePackageStillDecodesOnlyPNGJPEGAndHEIC() throws {
        try withTemporaryDirectory { dir in
            #expect(PackageFileKind.asset.imageTypes == ["public.png", "public.jpeg", "public.heic"])
            let hex = String(repeating: "0123456789abcdef", count: 2)
            for ext in ["gif", "pdf", "tif", "GIF"] {
                #expect(!PackageFileKind.asset.isValidName("\(hex).\(ext)"), "\(ext)")
            }
            let package = ProjectPackage(url: dir.appending(path: "Formats.toma", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: package.assetsURL, withIntermediateDirectories: true)
            // A TIFF, a GIF or a PDF in `assets/` is never decoded, whatever it is named.
            let picture = try FormatFixture.image(red: 1, green: 0, blue: 0)
            let files = try [
                ("\(hex).tiff", FormatFixture.encoded([picture], as: .tiff)),
                (String(hex.reversed()) + ".png", FormatFixture.encoded([picture], as: .gif)),
                ("fedcba9876543210fedcba9876543210.png", FormatFixture.pdf(pages: 1)),
            ]
            for (name, data) in files {
                try data.write(to: package.assetsURL.appending(path: name))
                #expect(package.asset("assets/\(name)") == nil, "\(name)")
            }
        }
    }
}
