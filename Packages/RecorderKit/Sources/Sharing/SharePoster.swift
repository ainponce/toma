// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ImageIO

/// `poster.jpg` (fases 4 y 5 design §8.2, plan 5a decision 10): a frame of the exported video itself, exactly the one
/// shown at a time (`AVAssetImageGenerator` with no tolerance), as a JPEG of the video's size.
public enum SharePoster {
    /// The JPEG's quality, from 0 to 1.
    public static let quality = 0.85

    /// Writes to `destination` (replacing a file there) the JPEG of the frame of `video` shown at `time` ns of output,
    /// the last frame for a time at or past its end, and gives its size in pixels. The frame is the one whose start on the
    /// video's frame grid (`TimeMap.frameTime`) is the last not after `time`, read in its middle, so a time a nanosecond
    /// off a frame's start, as a grid in ns has them, never gives the frame before.
    /// - Throws: `CocoaError(.fileReadCorruptFile)` for a file without video, `CocoaError(.fileWriteUnknown)` if the JPEG
    ///   cannot be made, or what reading the frame or writing the file throws.
    public static func write(from video: URL, atOutput time: Int64, to destination: URL) async throws -> SIMD2<Int> {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (range, nominalRate) = try await track.load(.timeRange, .nominalFrameRate)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: requestTime(time, range: range, nominalFrameRate: nominalRate))
        let data = NSMutableData()
        guard let jpeg = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(jpeg, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: destination, options: .atomic)
        return SIMD2(image.width, image.height)
    }

    /// The time to ask the generator for: the middle of the frame shown at `time` (`ShareInputs.frame(at:frameRate:)`),
    /// held to the video's frames, from the start of its track. A video whose frame rate is unknown is asked at `time`
    /// itself, held to its track.
    static func requestTime(_ time: Int64, range: CMTimeRange, nominalFrameRate: Float) -> CMTime {
        let fps = Int(nominalFrameRate.rounded())
        guard fps > 0, range.duration.isNumeric, range.duration.seconds > 0 else {
            let at = CMTime(value: max(time, 0), timescale: 1_000_000_000)
            let last = CMTimeSubtract(range.end, CMTime(value: 1, timescale: 1_000_000_000))
            return CMTimeMaximum(range.start, CMTimeMinimum(CMTimeAdd(range.start, at), last))
        }
        let frames = max(1, Int((range.duration.seconds * Double(fps)).rounded()))
        let frame = min(ShareInputs.frame(at: time, frameRate: fps), frames - 1)
        return CMTimeAdd(range.start, CMTime(value: CMTimeValue(2 * frame + 1), timescale: CMTimeScale(2 * fps)))
    }
}
