// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ProjectFormat

/// What a clip or a sound of a package's `assets/` is (phase 3 design §5.4, §7.7; phase 3a plan, Task A3): how long it
/// lasts, its picture's size and whether it has a sound, for the steps that put it into the document (`addMedia`'s
/// `fileDuration`, an overlay's proportion). Read only through the package's safe readers: a file that is not one of its
/// kind in `assets/`, a link, or one AVFoundation does not read gives nothing.
public struct MediaInfo: Equatable, Sendable {
    /// Its length, in ns of the file.
    public var duration: Int64
    /// Its picture's size in pixels, upright as a player shows it (its `preferredTransform`); `nil` without a picture.
    public var size: SIMD2<Int>?
    /// Whether it has a track of sound with any length.
    public var hasAudio: Bool

    public init(duration: Int64, size: SIMD2<Int>?, hasAudio: Bool) {
        self.duration = duration
        self.size = size
        self.hasAudio = hasAudio
    }

    /// The clip `asset` (`assets/<sha>.<mov|mp4|m4v>`) or the sound (`assets/<sha>.<m4a|mp3|wav|aiff|caf>`) of
    /// `package`, as the document names it, read by `AVURLAsset.load` from where `ProjectPackage.mediaAsset(_:as:)` says
    /// it is (never through a link): its duration, the size of its first video track with any length, and whether it has
    /// an audio track with any length. `nil` if it is not a file of its kind there, AVFoundation does not read it, it
    /// lasts nothing, or the caller's task is cancelled.
    ///
    /// Off the main thread and the caller's actor: AVFoundation reads the file meanwhile.
    @concurrent public static func probe(_ asset: String, in package: ProjectPackage) async -> MediaInfo? {
        guard !Task.isCancelled,
            let url = package.mediaAsset(asset, as: .video) ?? package.mediaAsset(asset, as: .audio)
        else { return nil }
        // Precise: a sound of variable bit rate (an MP3) is measured by its frames, not estimated from its bit rate.
        let file = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let (length, readable) = try await file.load(.duration, .isReadable)
            guard readable, length.isNumeric, length > .zero else { return nil }
            let duration = CMTimeConvertScale(length, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
            guard duration > 0 else { return nil }
            var size: SIMD2<Int>?
            for track in try await file.loadTracks(withMediaType: .video) {
                let (range, natural, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)
                guard range.duration.isNumeric, range.duration > .zero else { continue }
                let upright = natural.applying(transform)
                let (width, height) = (Int(abs(upright.width).rounded()), Int(abs(upright.height).rounded()))
                guard width > 0, height > 0 else { continue }
                size = SIMD2(width, height)
                break
            }
            var hasAudio = false
            for track in try await file.loadTracks(withMediaType: .audio) {
                let range = try await track.load(.timeRange)
                if range.duration.isNumeric, range.duration > .zero {
                    hasAudio = true
                    break
                }
            }
            guard !Task.isCancelled else { return nil }
            return MediaInfo(duration: duration, size: size, hasAudio: hasAudio)
        } catch {
            return nil
        }
    }

    /// The size in pixels of the image `asset` (`assets/<sha>.<png|jpg|heic>`) of `package`, upright as its EXIF
    /// orientation turns it, read from its header by ImageIO's properties without decoding it: the size
    /// `ProjectPackage.asset(_:)` decodes it at, up to a longer side of 7 680 pixels, and its proportion beyond. `nil` if
    /// it is not an image of `assets/` its reader would decode (`SafePackageFile`, no link; PNG, JPEG or HEIC by its
    /// content, `PackageFileKind.asset.imageTypes`, never another decoder of ImageIO), or its header gives no size or one
    /// larger than `PackageFileKind.asset.maxPixelSide`. A file whose pixels are cut short still gives the size its header
    /// says: nothing of it is decoded here.
    ///
    /// Off the main thread and the caller's actor: it reads the whole file meanwhile (up to
    /// `PackageFileKind.asset.maxBytes`, as the reader does). `nil` if the caller's task is cancelled first.
    @concurrent public static func imageSize(_ asset: String, in package: ProjectPackage) async -> SIMD2<Int>? {
        guard !Task.isCancelled else { return nil }
        let kind = PackageFileKind.asset
        guard let data = SafePackageFile.read(asset, in: package, as: kind),
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?, kind.imageTypes.contains(type),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0, width <= kind.maxPixelSide, height <= kind.maxPixelSide
        else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter: upright, its sides swap.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? SIMD2(height, width) : SIMD2(width, height)
    }
}
