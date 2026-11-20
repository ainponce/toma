// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import RecorderKitTestSupport
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What a clip or an image of `assets/` is, read without decoding it (phase 3a plan, Task A3; design §5.4): a clip's
/// length, size and whether it has a sound by AVFoundation, an image's size by ImageIO's properties, each only through
/// the package's safe readers.
@Suite struct MediaInfoTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// A take of 1 s of one display, in a new package, written off the caller's actor.
    @concurrent private static func package(in dir: URL, name: String = "Media") async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: 320, height: 180)])
        return try builder.write()
    }

    /// `data` written at `path` of `package` (`assets/…`), with the folder made.
    private static func place(_ data: Data, at path: String, in package: ProjectPackage) throws {
        try FileManager.default.createDirectory(at: package.assetsURL, withIntermediateDirectories: true)
        try data.write(to: package.url.appending(path: path))
    }

    /// An image of `width` × `height` pixels of the type `type`, with the EXIF orientation `orientation`.
    private static func image(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let picture = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func probeReadsDurationSizeAndAudio() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir)
            let withTone = try MediaFixtures.clip(in: dir, seconds: 2, size: SIMD2(640, 360), pattern: 0, tone: 440)
            let silent = try MediaFixtures.clip(in: dir, seconds: 1.5, size: SIMD2(320, 240), pattern: 1)
            let mono = try MediaFixtures.clip(
                in: dir, seconds: 1, size: SIMD2(160, 90), pattern: 2, tone: 660, sampleRate: 44_100, channels: 1)
            let toned = try await MediaFixtures.imported(withTone, into: project, as: .video)
            let quiet = try await MediaFixtures.imported(silent, into: project, as: .video)
            let monoAsset = try await MediaFixtures.imported(mono, into: project, as: .video)

            let frame: Int64 = 33_333_334
            let info = try #require(await MediaInfo.probe(toned, in: project.package))
            #expect(abs(info.duration - 2_000_000_000) <= frame, "\(info.duration)")
            #expect(info.size == SIMD2(640, 360))
            #expect(info.hasAudio)
            let none = try #require(await MediaInfo.probe(quiet, in: project.package))
            #expect(abs(none.duration - 1_500_000_000) <= frame, "\(none.duration)")
            #expect(none == MediaInfo(duration: none.duration, size: SIMD2(320, 240), hasAudio: false))
            let small = try #require(await MediaInfo.probe(monoAsset, in: project.package))
            #expect(small.size == SIMD2(160, 90))
            #expect(small.hasAudio)
        }
    }

    @Test func aLinkOrAMissingFileIsNil() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir)
            let package = project.package
            let clip = try MediaFixtures.clip(in: dir, seconds: 1, size: SIMD2(160, 90), pattern: 4, tone: 440)
            let asset = try await MediaFixtures.imported(clip, into: project, as: .video)
            #expect(await MediaInfo.probe(asset, in: package) != nil)

            // A link in `assets/` to the same clip, named as a clip.
            let link = "assets/" + String(repeating: "a", count: 32) + ".mov"
            try FileManager.default.createSymbolicLink(at: package.url.appending(path: link), withDestinationURL: clip)
            // Bytes that are not a movie, named as one.
            let garbage = "assets/" + String(repeating: "b", count: 32) + ".mp4"
            try Self.place(Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }), at: garbage, in: package)
            // A clip under a name that is not a clip's, out of `assets/`, or not there at all.
            let named = "assets/" + String(repeating: "c", count: 32) + ".png"
            try FileManager.default.copyItem(at: clip, to: package.url.appending(path: named))
            let missing = "assets/" + String(repeating: "d", count: 32) + ".mov"
            for path in [link, garbage, named, missing, "../" + clip.lastPathComponent, clip.path, "assets/clip.mov"] {
                #expect(await MediaInfo.probe(path, in: package) == nil, "\(path)")
            }
            // A link to the assets folder itself: nothing is reached through it either.
            let other = try await Self.package(in: dir, name: "Other")
            try FileManager.default.createSymbolicLink(at: other.package.assetsURL, withDestinationURL: package.assetsURL)
            #expect(await MediaInfo.probe(asset, in: other.package) == nil)
        }
    }

    @Test func imageSizeWithoutDecoding() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir)
            let package = project.package
            let png = "assets/" + String(repeating: "1", count: 32) + ".png"
            try Self.place(try Self.image(width: 300, height: 200, type: .png), at: png, in: package)
            // A JPEG turned a quarter by its EXIF orientation: upright, it is as the package's reader decodes it.
            let jpeg = "assets/" + String(repeating: "2", count: 32) + ".jpg"
            try Self.place(try Self.image(width: 300, height: 200, type: .jpeg, orientation: 6), at: jpeg, in: package)
            #expect(MediaInfo.imageSize(png, in: package) == SIMD2(300, 200))
            #expect(MediaInfo.imageSize(jpeg, in: package) == SIMD2(200, 300))
            for path in [png, jpeg] {
                let decoded = try #require(package.asset(path))
                #expect(MediaInfo.imageSize(path, in: package) == SIMD2(decoded.width, decoded.height))
            }

            // A PNG cut short in its pixels: its header says its size, though the package's reader decodes nothing of it.
            let whole = try Self.image(width: 640, height: 480, type: .png)
            let cut = "assets/" + String(repeating: "3", count: 32) + ".png"
            try Self.place(whole.prefix(whole.count - 40), at: cut, in: package)
            #expect(package.asset(cut) == nil)
            #expect(MediaInfo.imageSize(cut, in: package) == SIMD2(640, 480))

            // A TIFF (whose decoder is never reached from a package), a link, garbage, a missing file and a path out of
            // `assets/`: no size.
            let tiff = "assets/" + String(repeating: "4", count: 32) + ".tiff"
            try Self.place(try Self.image(width: 30, height: 20, type: .tiff), at: tiff, in: package)
            let link = "assets/" + String(repeating: "5", count: 32) + ".png"
            try FileManager.default.createSymbolicLink(
                at: package.url.appending(path: link), withDestinationURL: package.url.appending(path: png))
            let garbage = "assets/" + String(repeating: "6", count: 32) + ".heic"
            try Self.place(Data(repeating: 7, count: 512), at: garbage, in: package)
            let missing = "assets/" + String(repeating: "7", count: 32) + ".png"
            for path in [tiff, link, garbage, missing, "../x.png", "assets/x.png"] {
                #expect(MediaInfo.imageSize(path, in: package) == nil, "\(path)")
            }
        }
    }
}
