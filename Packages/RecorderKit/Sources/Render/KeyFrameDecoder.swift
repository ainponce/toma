// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import VideoToolbox
import os

/// Decodes key frames alone, for scrubbing (plan decision 32): the key frame at or before an instant, found with an
/// `AVSampleCursor` (from the sample at or before the instant, back in presentation order to a full sync sample), its
/// sample read by an `AVSampleBufferGenerator` without a timebase (synchronously) and decoded by a
/// `VTDecompressionSession` kept while the format allows, to BGRA in IOSurfaces like `TrackFrameReader`'s. No
/// `AVAssetReader` is opened, so a scrub costs one decode of one frame, and none while the key frame stays the same.
///
/// Not thread-safe; blocks while it reads and decodes.
final class KeyFrameDecoder {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "KeyFrameDecoder")

    /// How many key frames were decoded, for tests.
    private(set) var decodeCount = 0

    private let textureCache: CVMetalTextureCache
    private var session: VTDecompressionSession?
    /// The generator of the segment last read, by its file.
    private var generator: (asset: AVURLAsset, generator: AVSampleBufferGenerator)?
    /// The key frame last decoded: its file, its presentation time in it, and its frame.
    private var last: (asset: AVURLAsset, time: CMTime, frame: CachedTexture?)?
    /// The segments read so far, closed ones: their files, by the span of host time each holds.
    private var segments: [TrackFrameReader.Media] = []
    /// Errors already logged.
    private var reported: Set<String> = []

    /// - Throws: `RenderError.metalResourceUnavailable` if Core Video cannot make a texture cache for `device`.
    init(device: any MTLDevice) throws {
        let usage = MTLTextureUsage.shaderRead.rawValue
        let attributes = [kCVMetalTextureUsage as String: NSNumber(value: usage)] as CFDictionary
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, attributes, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw RenderError.metalResourceUnavailable("key frame texture cache (CVReturn \(status))")
        }
        textureCache = cache
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// The segment read before that holds `time`, if one does (only a closed segment is kept: its span is known).
    func media(at time: HostTime) -> TrackFrameReader.Media? {
        segments.first { $0.start <= time && $0.end.map { time < $0 } == true }
    }

    /// The key frame at or before host time `time` in the segment `media` (`TrackFrameReader.media(at:)`); `nil` before
    /// its first frame or when it cannot be read or decoded.
    func keyFrame(at time: HostTime, of media: TrackFrameReader.Media) -> CachedTexture? {
        if media.end != nil, !segments.contains(where: { $0.start == media.start }) { segments.append(media) }
        guard time >= media.start else { return nil }
        let offset = CMTime(value: Int64(time.nanoseconds - media.start.nanoseconds), timescale: 1_000_000_000)
        guard let cursor = media.track.makeSampleCursor(presentationTimeStamp: offset) else { return nil }
        // "At or near" the time: back to the sample at or before it, then to a full sync sample.
        while cursor.presentationTimeStamp > offset {
            guard cursor.stepInPresentationOrder(byCount: -1) == -1 else { return nil }
        }
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            guard cursor.stepInPresentationOrder(byCount: -1) == -1 else { return nil }
        }
        let keyTime = cursor.presentationTimeStamp
        if let last, last.asset === media.asset, last.time == keyTime { return last.frame }
        let frame = decode(cursor, of: media.asset)
        last = (media.asset, keyTime, frame)
        return frame
    }

    /// The sample at `cursor` of `asset`, decoded, as a texture.
    private func decode(_ cursor: AVSampleCursor, of asset: AVURLAsset) -> CachedTexture? {
        let generator = self.generator.flatMap { $0.asset === asset ? $0.generator : nil }
            ?? AVSampleBufferGenerator(asset: asset, timebase: nil)
        self.generator = (asset, generator)
        let sample: CMSampleBuffer
        do {
            sample = try generator.makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
        } catch {
            report("cannot read the key frame: \(TrackFrameReader.describe(error))")
            return nil
        }
        guard let format = CMSampleBufferGetFormatDescription(sample), let session = session(for: format) else { return nil }
        let output = DecodedImage()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            output.set(status == noErr ? image : nil)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, let pixelBuffer = output.get() else {
            report("cannot decode the key frame (OSStatus \(status))")
            return nil
        }
        decodeCount += 1
        CVMetalTextureCacheFlush(textureCache, 0)
        do {
            return try CachedTexture(pixelBuffer, cache: textureCache)
        } catch {
            report("cannot make a texture of the key frame: \(error)")
            return nil
        }
    }

    /// The session, made again when it cannot take `format`.
    private func session(for format: CMFormatDescription) -> VTDecompressionSession? {
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) { return session }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &made)
        guard status == noErr, let made else {
            report("cannot make a decompression session (OSStatus \(status))")
            return nil
        }
        session = made
        return made
    }

    private func report(_ message: String) {
        guard reported.insert(message).inserted else { return }
        Self.logger.error("\(message, privacy: .public)")
    }
}

/// The image a decompression session hands its output handler, read once it returned.
private final class DecodedImage: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CVImageBuffer?

    func set(_ image: CVImageBuffer?) {
        lock.withLock { self.image = image }
    }

    func get() -> CVImageBuffer? {
        lock.withLock { image }
    }
}
