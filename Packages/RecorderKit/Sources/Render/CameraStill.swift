// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

/// The camera's frame at the playhead as a picture (plan 2b decision 19): what the small view of Manual framing and the
/// Color tiles of the Camera tab show, made off the main thread when the playhead stops.
///
/// It is the frame the render draws there (`TrackFrameReader`): the one presented at or before the instant, of the last
/// segment of the track that starts at or before it and can be read, its last frame held after its end. Exactly that
/// frame (`AVAssetImageGenerator` without tolerance), as it is decoded (no track transform, as the render's texture), not
/// mirrored: the view flips it with the document's mirror. It reads only regular files of the package, never through a
/// link, and writes nothing.
public enum CameraStill {
    /// How much before its media's end the last frame is asked for: a time at the end itself is past every frame.
    static let lastFrameMargin = CMTime(value: 1, timescale: 1_000)

    /// The frame of video track `track` of `project`'s take at source instant `host`, scaled down to fit `maxPixelSide`
    /// pixels on its longer side (never up), with the size of the frame as it is decoded, in pixels (what
    /// `CameraFramingGeometry.crop` reads, as the render reads its texture's). `nil` before the track's first frame, for a
    /// track the take does not have or that is not video, a segment whose file is not a regular file of the package (or
    /// whose names are not ones a manifest may have), one that cannot be decoded, a size not above 0, and when the caller
    /// is cancelled.
    @concurrent
    public static func frame(
        project: LoadedProject, track id: String, at host: HostTime, maxPixelSide: Int
    ) async -> (image: CGImage, frameSize: SIMD2<Int>)? {
        guard maxPixelSide > 0, (try? project.take.validatePaths()) != nil, let track = project.take.track(id), track.kind.isVideo,
            let segment = segment(of: track, at: host, in: project.package)
        else { return nil }
        let asset = AVURLAsset(url: project.package.fileURL(segment.file))
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
            let (natural, range) = try? await video.load(.naturalSize, .timeRange),
            natural.width >= 1, natural.height >= 1, range.duration.isNumeric, range.duration > .zero, !Task.isCancelled
        else { return nil }
        let generator = Generator(asset: asset, maxPixelSide: maxPixelSide)
        let time = fileTime(of: host, in: segment, media: range)
        let image = await withTaskCancellationHandler {
            await generator.image(at: time)
        } onCancel: {
            generator.cancel()
        }
        guard let image, !Task.isCancelled else { return nil }
        return (image, SIMD2(Int(natural.width.rounded()), Int(natural.height.rounded())))
    }

    /// `image` with the look `preset` (`cameraLook-1`, `CameraLooks.apply`) on each of its pixels, as sRGB, its alpha
    /// kept, scaled down to fit `maxPixelSide` pixels on its longer side (never up): the Color tiles' pictures. Natural and
    /// Custom give the picture as it is (redrawn as sRGB). `nil` for a picture or a size of none, or one Core Graphics
    /// cannot draw.
    public static func withLook(_ preset: CameraColorPreset, _ image: CGImage, maxPixelSide: Int = .max) -> CGImage? {
        guard image.width > 0, image.height > 0, maxPixelSide > 0 else { return nil }
        let scale = min(1, Double(maxPixelSide) / Double(max(image.width, image.height)))
        let width = max(Int((Double(image.width) * scale).rounded()), 1), height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard var pixels = rgba(of: image, width: width, height: height) else { return nil }
        if preset != .natural, preset != .custom {
            // Opaque pictures (a camera's frame): the premultiplied colour is the colour.
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Float(pixels[i + 3]) / 255
                guard alpha > 0 else { continue }
                let rgb = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / (255 * alpha)
                let looked = CameraLooks.apply(preset, to: rgb) * (255 * alpha)
                pixels[i] = byte(looked.x)
                pixels[i + 1] = byte(looked.y)
                pixels[i + 2] = byte(looked.z)
            }
        }
        return picture(pixels, width: width, height: height)
    }

    /// A small scene that stands for a camera's frame while there is none (a portrait over a window: sky, skin, hair,
    /// foliage and a shirt), `width` × `height` pixels: the Color tiles show each look on it. `nil` for a size not above 0.
    public static func sampleScene(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let aspect = Double(width) / Double(height)
        let sky = SIMD3<Double>(0.58, 0.74, 0.90), wall = SIMD3<Double>(0.86, 0.80, 0.70), leaves = SIMD3<Double>(0.30, 0.55, 0.28)
        let skin = SIMD3<Double>(0.88, 0.67, 0.53), hair = SIMD3<Double>(0.25, 0.16, 0.11), shirt = SIMD3<Double>(0.80, 0.26, 0.22)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
                // A window of sky and leaves on the left, a warm wall elsewhere.
                var color = u < 0.42 && v < 0.62 ? (v > 0.42 ? leaves : sky) : wall
                // Shoulders in a shirt, a neck, a head with its hair on top.
                let px = (u - 0.62) * aspect
                let shoulders = (px * px) / (0.34 * 0.34) + ((v - 1.08) * (v - 1.08)) / (0.36 * 0.36)
                let head = (px * px) / (0.17 * 0.17) + ((v - 0.42) * (v - 0.42)) / (0.24 * 0.24)
                if shoulders < 1 { color = shirt }
                if abs(px) < 0.07, v > 0.55, v < 0.8 { color = skin }
                if head < 1 { color = v < 0.3 || (head > 0.72 && v < 0.42) ? hair : skin }
                let i = (y * width + x) * 4
                pixels[i] = byte(Float(color.x * 255))
                pixels[i + 1] = byte(Float(color.y * 255))
                pixels[i + 2] = byte(Float(color.z * 255))
            }
        }
        return picture(pixels, width: width, height: height)
    }

    // MARK: - Private

    /// The last segment of `track` starting at or before `host` whose file is a regular file of some bytes, as
    /// `TrackFrameReader` falls back to the frame of an earlier one.
    private static func segment(of track: TrackRecord, at host: HostTime, in package: ProjectPackage) -> SegmentRecord? {
        track.segments
            .filter { $0.startHostTime <= host }
            .sorted { $0.startHostTime < $1.startHostTime }
            .last { segment in
                guard SegmentAvailability.classify(segment, in: package) == .present else { return false }
                var info = stat()
                return lstat(package.fileURL(segment.file).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0
            }
    }

    /// Where in `segment`'s file the frame of `host` is: from the segment's start, held to its end and to its last frame.
    private static func fileTime(of host: HostTime, in segment: SegmentRecord, media: CMTimeRange) -> CMTime {
        var nanoseconds = Int64(clamping: host.nanoseconds - segment.startHostTime.nanoseconds)
        if let end = segment.endHostTime, end > segment.startHostTime {
            nanoseconds = min(nanoseconds, Int64(clamping: end.nanoseconds - segment.startHostTime.nanoseconds))
        }
        let time = CMTime(value: nanoseconds, timescale: 1_000_000_000)
        let last = CMTimeSubtract(media.end, lastFrameMargin)
        return CMTimeMaximum(media.start, CMTimeMinimum(time, last))
    }

    /// The bytes of `image` drawn as sRGB at `width` × `height`, RGBA with premultiplied alpha, rows packed.
    private static func rgba(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The sRGB picture of RGBA bytes with premultiplied alpha.
    private static func picture(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value.isNaN ? 0 : value, 0), 255).rounded())
    }
}

/// One `AVAssetImageGenerator` for one frame, which a cancelled caller stops from another thread (the generator's own
/// `cancelAllCGImageGeneration` is made for that).
private final class Generator: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(asset: AVURLAsset, maxPixelSide: Int) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxPixelSide, height: maxPixelSide)
    }

    /// The frame at `time` in the file, or `nil` if it cannot be made (or was cancelled).
    func image(at time: CMTime) async -> CGImage? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}
