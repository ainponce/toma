// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

// MARK: - Fixtures

private let hash = "0123456789abcdef0123456789abcdef"
private let otherHash = "fedcba9876543210fedcba9876543210"

/// `<dir>/Demo.toma` with `takes/take-001/`, as a recorded package has it.
private func makePackage(in dir: URL) throws -> ProjectPackage {
    let package = ProjectPackage(url: dir.appendingPathComponent("Demo.toma", isDirectory: true))
    try FileManager.default.createDirectory(at: package.takeDirectory("take-001"), withIntermediateDirectories: true)
    return package
}

/// Writes `data` at `relativePath` of `package`, making the folders it needs.
private func put(_ data: Data, at relativePath: String, in package: ProjectPackage) throws {
    let url = package.url.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// Deterministic bytes from a linear congruential generator, so a failure can be reproduced.
private func noise(count: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

/// The color the images that are not `noisy` are filled with, and its 8-bit components.
private let fill = (red: 0.2, green: 0.5, blue: 0.8)
private let fillBytes: (red: UInt8, green: UInt8, blue: UInt8) = (51, 128, 204)

/// An opaque sRGB image; with `noisy`, every pixel differs, so it compresses poorly. With 16 bits a component, it
/// is encoded as a 16-bit PNG.
private func image(width: Int, height: Int, noisy: Bool = false, bitsPerComponent: Int = 8) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let alpha = bitsPerComponent == 16
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
        bytesPerRow: width * 4 * bitsPerComponent / 8, space: space, bitmapInfo: alpha
    ))
    if noisy {
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        for (index, byte) in noise(count: width * height * 4, seed: 7).enumerated() { pixels[index] = byte }
    } else {
        context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return try #require(context.makeImage())
}

/// A gray image, which ImageIO decodes in a gray color space.
private func grayImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// The bytes of the first pixel of `image`, which must be 8-bit RGBA.
private func firstPixel(of image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data as Data?)
    return Array(data.prefix(4))
}

/// Whether `image` is what every reader gives: 8 bits a component, RGBA with premultiplied alpha last, in an RGB
/// color space.
private func isEightBitRGBA(_ image: CGImage) -> Bool {
    image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.alphaInfo == .premultipliedLast
        && image.bitmapInfo.intersection(.byteOrderMask).isEmpty && image.colorSpace?.model == .rgb
}

/// `image` encoded as `type` (`public.png`, `public.jpeg`, `com.microsoft.bmp`…) with the image `properties` given.
private func encoded(_ image: CGImage, as type: String, properties: [CFString: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private func png(width: Int, height: Int, noisy: Bool = false) throws -> Data {
    try encoded(try image(width: width, height: height, noisy: noisy), as: "public.png")
}

// MARK: - Reading

@Test func readsARegularCursorImage() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try put(try png(width: 32, height: 32), at: "takes/take-001/cursors/\(hash).png", in: package)

        let cursor = try #require(package.cursorImage(take: "take-001", hash: hash))
        #expect(cursor.width == 32 && cursor.height == 32)
        #expect(SafePackageFile.read("takes/take-001/cursors/\(hash).png", in: package, as: .cursorImage) != nil)
        // Another take, or a hash with no file, has none.
        #expect(package.cursorImage(take: "take-002", hash: hash) == nil)
        #expect(package.cursorImage(take: "take-001", hash: otherHash) == nil)
    }
}

@Test func readsARegularWallpaperAndAsset() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try put(try png(width: 40, height: 20), at: "takes/take-001/wallpapers/display-69734208.png", in: package)
        try put(try encoded(try image(width: 64, height: 32), as: "public.heic"), at: "assets/\(hash).heic", in: package)
        try put(try png(width: 30, height: 10), at: "assets/\(otherHash).png", in: package)

        let wallpaper = try #require(package.wallpaper(take: "take-001", displayID: 69_734_208))
        #expect(wallpaper.width == 40 && wallpaper.height == 20)
        #expect(package.wallpaper(take: "take-001", displayID: 1) == nil)
        let heic = try #require(package.asset("assets/\(hash).heic"))
        #expect(heic.width == 64 && heic.height == 32)
        #expect(package.asset("assets/\(otherHash).png")?.width == 30)
    }
}

@Test func readsThroughALinkToThePackageItself() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try put(try png(width: 32, height: 32), at: "takes/take-001/cursors/\(hash).png", in: package)
        let link = dir.appendingPathComponent("Link.toma", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.url)

        // The user may reach the package through a link of their own; only what is inside it is never followed.
        #expect(ProjectPackage(url: link).cursorImage(take: "take-001", hash: hash)?.width == 32)
    }
}

@Test func symlinkedFileIsAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let outside = dir.appendingPathComponent("outside.png", isDirectory: false)
        try png(width: 32, height: 32).write(to: outside)
        try FileManager.default.createDirectory(at: package.cursorsDirectory(take: "take-001"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.cursorImageURL(take: "take-001", hash: hash), withDestinationURL: outside)
        // The link leads to an image that would decode.
        #expect(BoundedImage.decode(try Data(contentsOf: package.cursorImageURL(take: "take-001", hash: hash)), maxPixelSide: 512) != nil)

        #expect(package.cursorImage(take: "take-001", hash: hash) == nil)
        #expect(SafePackageFile.read("takes/take-001/cursors/\(hash).png", in: package, as: .cursorImage) == nil)
    }
}

@Test func symlinkedFolderIsAbsent() throws {
    // A link at each folder on the way to the file, to a folder that holds the rest of the way.
    let cases: [(link: String, file: String, read: @Sendable (ProjectPackage) -> CGImage?)] = [
        ("takes", "takes/take-001/wallpapers/display-1.png", { $0.wallpaper(take: "take-001", displayID: 1) }),
        ("takes/take-001", "takes/take-001/wallpapers/display-1.png", { $0.wallpaper(take: "take-001", displayID: 1) }),
        ("takes/take-001/wallpapers", "takes/take-001/wallpapers/display-1.png", { $0.wallpaper(take: "take-001", displayID: 1) }),
        ("takes/take-001/cursors", "takes/take-001/cursors/\(hash).png", { $0.cursorImage(take: "take-001", hash: hash) }),
        ("assets", "assets/\(hash).png", { $0.asset("assets/\(hash).png") }),
    ]
    for (index, item) in cases.enumerated() {
        try withTemporaryDirectory { dir in
            let package = ProjectPackage(url: dir.appendingPathComponent("Demo.toma", isDirectory: true))
            let linkURL = package.url.appendingPathComponent(item.link, isDirectory: true)
            try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let elsewhere = dir.appendingPathComponent("elsewhere-\(index)", isDirectory: true)
            let rest = String(item.file.dropFirst(item.link.count + 1))
            let target = elsewhere.appendingPathComponent(rest, isDirectory: false)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png(width: 16, height: 16).write(to: target)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: elsewhere)
            // Through the link, the file is there.
            #expect(FileManager.default.fileExists(atPath: package.url.appendingPathComponent(item.file).path), "\(item.link)")

            #expect(item.read(package) == nil, "\(item.link)")
        }
    }
}

@Test func invalidNamesAreAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let image = try png(width: 16, height: 16)

        // A hash in capitals.
        let capitals = hash.uppercased()
        try put(image, at: "takes/take-001/cursors/\(capitals).png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: capitals) == nil)

        // 31 hex digits, and 33.
        try put(image, at: "takes/take-001/cursors/\(hash.dropLast()).png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: String(hash.dropLast())) == nil)
        try put(image, at: "takes/take-001/cursors/\(hash)0.png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: hash + "0") == nil)

        // A wallpaper photo that is not a PNG by its name, next to one that is.
        try put(image, at: "takes/take-001/wallpapers/display-1.jpg", in: package)
        try put(image, at: "takes/take-001/wallpapers/display-1.png", in: package)
        #expect(SafePackageFile.read("takes/take-001/wallpapers/display-1.jpg", in: package, as: .wallpaper) == nil)
        #expect(SafePackageFile.read("takes/take-001/wallpapers/display-1.png", in: package, as: .wallpaper) != nil)

        // Out of the package, or back into it, with `..`; and `.` or an empty component.
        try image.write(to: dir.appendingPathComponent("\(hash).png"))
        try put(image, at: "assets/\(hash).png", in: package)
        #expect(package.asset("../x.png") == nil)
        #expect(package.asset("../\(hash).png") == nil)
        #expect(package.asset("assets/../assets/\(hash).png") == nil)
        #expect(package.asset("./assets/\(hash).png") == nil)
        #expect(package.asset("assets//\(hash).png") == nil)
        #expect(package.asset("/assets/\(hash).png") == nil)
        #expect(package.asset("assets/\(hash).png") != nil)

        // An image type that is not allowed, and a name that is not a hash.
        try put(image, at: "assets/\(otherHash).gif", in: package)
        try put(image, at: "assets/x.gif", in: package)
        #expect(package.asset("assets/\(otherHash).gif") == nil)
        #expect(package.asset("assets/x.gif") == nil)

        // A file of one kind read where another kind lives.
        try put(image, at: "takes/take-001/cursors/\(otherHash).png", in: package)
        #expect(package.asset("takes/take-001/cursors/\(otherHash).png") == nil)
        #expect(SafePackageFile.read("assets/\(hash).png", in: package, as: .cursorImage) == nil)
        #expect(SafePackageFile.read("takes/take-001/cursors/\(otherHash).png", in: package, as: .cursorImage) != nil)

        // A take ID that is not take-NNN, or that walks out of its folder.
        try put(image, at: "takes/take-1/cursors/\(hash).png", in: package)
        #expect(package.cursorImage(take: "take-1", hash: hash) == nil)
        #expect(package.cursorImage(take: "take-001/../take-001", hash: otherHash) == nil)
        #expect(package.cursorImage(take: "take-001", hash: "../cursors/\(otherHash)") == nil)

        // A hash of an event is not checked when events.jsonl is read: one that is a path names no file, even where
        // that path leads to an image.
        try put(image, at: "takes/x.png", in: package)
        try put(image, at: "takes/take-001/cursors/a/b.png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: "../../x") == nil)
        #expect(package.cursorImage(take: "take-001", hash: "a/b") == nil)
        #expect(SafePackageFile.read("takes/take-001/cursors/../../x.png", in: package, as: .cursorImage) == nil)
        #expect(SafePackageFile.read("takes/take-001/cursors/a/b.png", in: package, as: .cursorImage) == nil)
    }
}

@Test func namesFollowTheirKindsRules() {
    #expect(PackageFileKind.cursorImage.isValidName("\(hash).png"))
    #expect(!PackageFileKind.cursorImage.isValidName("\(hash).PNG"))
    #expect(!PackageFileKind.cursorImage.isValidName("\(hash).png\n"))
    #expect(!PackageFileKind.cursorImage.isValidName("\(hash).jpg"))
    #expect(!PackageFileKind.cursorImage.isValidName("0123456789abcdef0123456789abcdeg.png"))
    #expect(!PackageFileKind.cursorImage.isValidName(".png"))

    #expect(PackageFileKind.wallpaper.isValidName("display-1.png"))
    #expect(PackageFileKind.wallpaper.isValidName("display-4294967295.png"))
    #expect(!PackageFileKind.wallpaper.isValidName("display-.png"))
    #expect(!PackageFileKind.wallpaper.isValidName("display--1.png"))
    #expect(!PackageFileKind.wallpaper.isValidName("display-1.png.png"))
    #expect(!PackageFileKind.wallpaper.isValidName("display-\u{0661}.png"))  // ARABIC-INDIC DIGIT ONE
    #expect(!PackageFileKind.wallpaper.isValidName("Display-1.png"))

    for ext in ["png", "jpg", "heic", "tiff"] {
        #expect(PackageFileKind.asset.isValidName("\(hash).\(ext)"))
    }
    for ext in ["gif", "jpeg", "tif", "HEIC", "png.png", ""] {
        #expect(!PackageFileKind.asset.isValidName("\(hash).\(ext)"), "\(ext)")
    }
    #expect(!PackageFileKind.asset.isValidName(hash))
    #expect(!PackageFileKind.asset.isValidName("display-1.png"))
    #expect(!PackageFileKind.cursorImage.isValidName("display-1.png"))
}

@Test func limitsAreTheDesignsOnes() {
    #expect(PackageFileKind.cursorImage.maxBytes == 1_048_576 && PackageFileKind.cursorImage.maxPixelSide == 512)
    #expect(PackageFileKind.wallpaper.maxBytes == 67_108_864 && PackageFileKind.wallpaper.maxPixelSide == 16_384)
    #expect(PackageFileKind.asset.maxBytes == 104_857_600 && PackageFileKind.asset.maxPixelSide == 16_384)
    #expect(PackageFileKind.cursorImage.imageTypes == ["public.png"])
    #expect(PackageFileKind.wallpaper.imageTypes == ["public.png"])
    #expect(PackageFileKind.asset.imageTypes == ["public.png", "public.jpeg", "public.heic"])
}

@Test func oversizedFilesAreAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let image = try png(width: 32, height: 32)

        // A PNG padded after its end to exactly the limit still decodes; one byte more is absent.
        try put(image + Data(count: 1_048_576 - image.count), at: "takes/take-001/cursors/\(hash).png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: hash)?.width == 32)
        try put(image + Data(count: 1_048_577 - image.count), at: "takes/take-001/cursors/\(otherHash).png", in: package)
        #expect(SafePackageFile.read("takes/take-001/cursors/\(otherHash).png", in: package, as: .cursorImage) == nil)
        #expect(package.cursorImage(take: "take-001", hash: otherHash) == nil)

        // 512 pixels on a side is fine for a cursor; 513 is not.
        let wide = "00000000000000000000000000000512"
        let tooWide = "00000000000000000000000000000513"
        try put(try png(width: 512, height: 10), at: "takes/take-001/cursors/\(wide).png", in: package)
        try put(try png(width: 513, height: 10), at: "takes/take-001/cursors/\(tooWide).png", in: package)
        try put(try png(width: 10, height: 513), at: "takes/take-001/cursors/1\(tooWide.dropFirst()).png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: wide)?.width == 512)
        #expect(package.cursorImage(take: "take-001", hash: tooWide) == nil)
        #expect(package.cursorImage(take: "take-001", hash: "1" + tooWide.dropFirst()) == nil)
        #expect(BoundedImage.decode(try png(width: 513, height: 10), maxPixelSide: 512) == nil)
        #expect(BoundedImage.decode(try png(width: 513, height: 10), maxPixelSide: 513)?.width == 513)
    }
}

@Test func damagedImageIsAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let bytes = Data(noise(count: 100, seed: 42))
        try put(bytes, at: "takes/take-001/cursors/\(hash).png", in: package)
        try put(bytes, at: "assets/\(hash).png", in: package)

        #expect(SafePackageFile.read("takes/take-001/cursors/\(hash).png", in: package, as: .cursorImage) == bytes)
        #expect(package.cursorImage(take: "take-001", hash: hash) == nil)
        #expect(package.asset("assets/\(hash).png") == nil)
        #expect(BoundedImage.decode(Data(), maxPixelSide: 512) == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func fifoIsAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try FileManager.default.createDirectory(at: package.wallpapersDirectory(take: "take-001"), withIntermediateDirectories: true)
        let path = package.wallpapersDirectory(take: "take-001").appendingPathComponent("display-2.png").path
        #expect(mkfifo(path, 0o644) == 0)
        try FileManager.default.createDirectory(at: package.assetsURL, withIntermediateDirectories: true)
        let assetPath = package.assetsURL.appendingPathComponent("\(hash).png").path
        #expect(mkfifo(assetPath, 0o644) == 0)

        // No writer ever opens the other end: a blocking open would wait for one until the watchdog opens it, and the
        // test would fail instead of hanging.
        let watchdog = FIFOWatchdog(paths: [path, assetPath])
        let wallpaper = package.wallpaper(take: "take-001", displayID: 2)
        let asset = package.asset("assets/\(hash).png")
        #expect(!watchdog.disarm(), "an open of a FIFO waited for its other end")
        #expect(wallpaper == nil && asset == nil)
        // Refused by `fstat` as no regular file, never read as the empty file it would seem.
        #expect(SafePackageFile.read("takes/take-001/wallpapers/display-2.png", in: package, as: .wallpaper) == nil)
        #expect(SafePackageFile.read("assets/\(hash).png", in: package, as: .asset) == nil)
    }
}

@Test func folderWhereAFileShouldBeIsAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try FileManager.default.createDirectory(
            at: package.cursorImageURL(take: "take-001", hash: hash), withIntermediateDirectories: true)
        try put(try png(width: 8, height: 8), at: "takes/take-001/wallpapers", in: package)

        #expect(package.cursorImage(take: "take-001", hash: hash) == nil)
        #expect(package.wallpaper(take: "take-001", displayID: 1) == nil)
    }
}

// MARK: - Decoding

@Test func onlyTheKindsFormatsAreDecoded() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let picture = try image(width: 16, height: 16)
        let formats = [
            "public.jpeg": try encoded(picture, as: "public.jpeg"),
            "com.compuserve.gif": try encoded(picture, as: "com.compuserve.gif"),
            "com.microsoft.bmp": try encoded(picture, as: "com.microsoft.bmp"),
            "public.tiff": try encoded(picture, as: "public.tiff"),
        ]
        // Each is an image ImageIO decodes, and reads as the type it is, whatever the file is named.
        for (type, data) in formats {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == type)
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "\(type)")
        }
        let jpeg = try #require(formats["public.jpeg"])
        let gif = try #require(formats["com.compuserve.gif"])
        let bmp = try #require(formats["com.microsoft.bmp"])
        let tiff = try #require(formats["public.tiff"])

        // Cursors and wallpaper photos are PNG only.
        try put(jpeg, at: "takes/take-001/cursors/\(hash).png", in: package)
        try put(gif, at: "takes/take-001/cursors/\(otherHash).png", in: package)
        try put(jpeg, at: "takes/take-001/wallpapers/display-1.png", in: package)
        try put(gif, at: "takes/take-001/wallpapers/display-2.png", in: package)
        #expect(package.cursorImage(take: "take-001", hash: hash) == nil)
        #expect(package.cursorImage(take: "take-001", hash: otherHash) == nil)
        #expect(package.wallpaper(take: "take-001", displayID: 1) == nil)
        #expect(package.wallpaper(take: "take-001", displayID: 2) == nil)

        // The user's own images are PNG, JPEG or HEIC: not BMP, GIF or TIFF, even named as one that is allowed.
        try put(jpeg, at: "assets/\(hash).jpg", in: package)
        try put(bmp, at: "assets/\(hash).png", in: package)
        try put(bmp, at: "assets/\(otherHash).jpg", in: package)
        try put(gif, at: "assets/\(otherHash).png", in: package)
        try put(tiff, at: "assets/\(hash).tiff", in: package)
        #expect(package.asset("assets/\(hash).jpg")?.width == 16)
        #expect(package.asset("assets/\(hash).png") == nil)
        #expect(package.asset("assets/\(otherHash).jpg") == nil)
        #expect(package.asset("assets/\(otherHash).png") == nil)
        #expect(package.asset("assets/\(hash).tiff") == nil)

        // The types are what `decode` is given; by default, the user's own images'.
        #expect(BoundedImage.decode(jpeg, maxPixelSide: 16)?.width == 16)
        #expect(BoundedImage.decode(jpeg, maxPixelSide: 16, allowedTypes: PackageFileKind.cursorImage.imageTypes) == nil)
        #expect(BoundedImage.decode(bmp, maxPixelSide: 16) == nil)
        #expect(BoundedImage.decode(bmp, maxPixelSide: 16, allowedTypes: ["com.microsoft.bmp"])?.width == 16)
    }
}

@Test func decodedImagesAreEightBitRGBA() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        // 16-bit PNGs, which ImageIO decodes at 8 bytes a pixel; one a wallpaper as wide as a wallpaper may be.
        let cursor16 = try encoded(try image(width: 64, height: 64, bitsPerComponent: 16), as: "public.png")
        let wallpaper16 = try encoded(try image(width: 16_384, height: 16, bitsPerComponent: 16), as: "public.png")
        let source = try #require(CGImageSourceCreateWithData(wallpaper16 as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.bitsPerComponent == 16)
        try put(cursor16, at: "takes/take-001/cursors/\(hash).png", in: package)
        try put(wallpaper16, at: "takes/take-001/wallpapers/display-1.png", in: package)
        try put(cursor16, at: "assets/\(hash).png", in: package)
        try put(try encoded(try grayImage(width: 8, height: 8), as: "public.png"), at: "assets/\(otherHash).png", in: package)
        try put(try encoded(try image(width: 8, height: 8), as: "public.jpeg"), at: "assets/\(hash).jpg", in: package)

        let cursor = try #require(package.cursorImage(take: "take-001", hash: hash))
        let wallpaper = try #require(package.wallpaper(take: "take-001", displayID: 1))
        let asset = try #require(package.asset("assets/\(hash).png"))
        let gray = try #require(package.asset("assets/\(otherHash).png"))
        let jpeg = try #require(package.asset("assets/\(hash).jpg"))
        for decoded in [cursor, wallpaper, asset, gray, jpeg] {
            #expect(isEightBitRGBA(decoded), "\(decoded.bitsPerComponent) bits, \(decoded.bitsPerPixel) a pixel")
        }

        // A wallpaper photo is reduced like the user's own images, to 7 680 on its longer side.
        #expect(wallpaper.width == 7680 && wallpaper.height == 8)
        #expect(cursor.width == 64 && cursor.height == 64)

        // The pixels are the file's.
        for decoded in [cursor, wallpaper, asset] {
            let pixel = try firstPixel(of: decoded)
            #expect(abs(Int(pixel[0]) - Int(fillBytes.red)) <= 1 && abs(Int(pixel[1]) - Int(fillBytes.green)) <= 1
                && abs(Int(pixel[2]) - Int(fillBytes.blue)) <= 1 && pixel[3] == 255, "\(pixel)")
        }
        let grayPixel = try firstPixel(of: gray)
        #expect(grayPixel[0] == grayPixel[1] && grayPixel[1] == grayPixel[2] && grayPixel[3] == 255, "\(grayPixel)")
    }
}

@Test func wallpaperIsDecodedReduced() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try put(try png(width: 8000, height: 100), at: "takes/take-001/wallpapers/display-1.png", in: package)

        let wallpaper = try #require(package.wallpaper(take: "take-001", displayID: 1))
        #expect(wallpaper.width == 7680 && wallpaper.height == 96)
    }
}

@Test func assetIsDecodedReduced() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try put(try png(width: 8000, height: 100), at: "assets/\(hash).png", in: package)

        let asset = try #require(package.asset("assets/\(hash).png"))
        #expect(asset.width == 7680)
        #expect(asset.height == 96)
    }
}

@Test func reducingNeverEnlarges() throws {
    let small = try #require(BoundedImage.decode(try png(width: 300, height: 200), maxPixelSide: 16_384, reducedTo: 7680))
    #expect(small.width == 300 && small.height == 200)
}

@Test func jpegWithExifThumbnailDecodesFullSize() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let jpeg = try encoded(
            try image(width: 2000, height: 1000), as: "public.jpeg", properties: [kCGImageDestinationEmbedThumbnail: true])
        // The file has a small thumbnail of its own, which a thumbnail asked for by size alone would be.
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let embedded = try #require(CGImageSourceCreateThumbnailAtIndex(
            source, 0, [kCGImageSourceThumbnailMaxPixelSize: 7680] as CFDictionary))
        #expect(embedded.width <= 320)
        try put(jpeg, at: "assets/\(hash).jpg", in: package)

        let asset = try #require(package.asset("assets/\(hash).jpg"))
        #expect(asset.width == 2000 && asset.height == 1000)
    }
}

@Test func exifOrientationIsApplied() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        // 6: the stored pixels are turned 90° counterclockwise from how the photo is seen.
        let jpeg = try encoded(try image(width: 200, height: 100), as: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        try put(jpeg, at: "assets/\(hash).jpg", in: package)

        let asset = try #require(package.asset("assets/\(hash).jpg"))
        #expect(asset.width == 100 && asset.height == 200)
    }
}

@Test func truncatedPNGIsAbsent() throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        let whole = try png(width: 64, height: 64, noisy: true)
        let half = whole.prefix(whole.count / 2)
        // The header is whole: what is missing is the pixels.
        let source = try #require(CGImageSourceCreateWithData(half as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
        try put(Data(half), at: "takes/take-001/cursors/\(hash).png", in: package)
        try put(Data(half), at: "assets/\(hash).png", in: package)

        #expect(BoundedImage.decode(whole, maxPixelSide: 512)?.width == 64)
        #expect(package.cursorImage(take: "take-001", hash: hash) == nil)
        #expect(package.asset("assets/\(hash).png") == nil)

        // Cut anywhere before the end of its last chunk, IEND: without IEND, or without IEND's CRC.
        for count in [whole.count / 4, whole.count * 3 / 4, whole.count - 12, whole.count - 1] {
            #expect(BoundedImage.decode(whole.prefix(count), maxPixelSide: 512) == nil, "\(count) of \(whole.count) bytes")
            #expect(BoundedImage.decode(whole.prefix(count), maxPixelSide: 512, reducedTo: 32) == nil, "\(count) of \(whole.count) bytes")
        }
        #expect(BoundedImage.decode(whole, maxPixelSide: 512, reducedTo: 32)?.width == 32)
    }
}
