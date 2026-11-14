// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SyntheticCapture

private enum TrackReadError: Error {
    case cannotAddOutput, didNotStart
}

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread.
private func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// Reads every sample of `track` with `outputSettings` and folds them into `initial` with `fold`.
/// Throws `TestSupportError.failed` if the reader does not complete.
///
/// The reading runs on a thread of its own: `copyNextSampleBuffer` blocks until AVFoundation's own
/// file reads finish, and many test cases blocking the cooperative pool that way at once starve
/// those reads of threads and deadlock the whole test run.
public func readTrack<T: Sendable>(
    _ track: AVAssetTrack, of asset: AVURLAsset, outputSettings: [String: any Sendable]?, into initial: T,
    _ fold: @escaping @Sendable (inout T, CMSampleBuffer) throws -> Void
) async throws -> T {
    // Handed over to the reading thread, and not used here again until it is done.
    nonisolated(unsafe) let track = track
    let (value, status) = try await onOwnThread { () throws -> (T, AVAssetReader.Status) in
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { throw TrackReadError.cannotAddOutput }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TrackReadError.didNotStart }
        var value = initial
        while let sample = output.copyNextSampleBuffer() { try fold(&value, sample) }
        return (value, reader.status)
    }
    guard status == .completed else {
        throw TestSupportError.failed("reading \(asset.url.lastPathComponent) ended with status \(status.rawValue)")
    }
    return value
}

/// The palette index (`SampleFactory.frameIndex(nearestTo:)`) of every decoded frame of the movie's
/// video track, read from a pixel near the bottom-right corner, away from the moving white square.
public func decodedFrameIndices(of url: URL) async throws -> [Int] {
    let asset = AVURLAsset(url: url)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "a video track in \(url.lastPathComponent)")
    let settings: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    return try await readTrack(track, of: asset, outputSettings: settings, into: [Int]()) { indices, sample in
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        indices.append(SampleFactory.frameIndex(nearestTo: bottomRightPixel(of: pixelBuffer)))
    }
}

private func bottomRightPixel(of pixelBuffer: CVPixelBuffer) -> SIMD4<UInt8> {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let x = CVPixelBufferGetWidth(pixelBuffer) - 8
    let y = CVPixelBufferGetHeight(pixelBuffer) - 8
    let row = CVPixelBufferGetBaseAddress(pixelBuffer)!
        .advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
        .assumingMemoryBound(to: UInt8.self)
    let p = row.advanced(by: x * 4)
    return SIMD4(p[0], p[1], p[2], p[3])
}

/// Where the media of the movie's video track ends: the latest presentation end of a sample that
/// carries data and lasts. A gap after the last frame (the edit list alone reaching further) does
/// not count, so this tells whether the last frame itself is held.
public func videoMediaEnd(of url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first, "a video track in \(url.lastPathComponent)")
    return try await readTrack(track, of: asset, outputSettings: nil, into: 0.0) { end, sample in
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        guard CMSampleBufferGetNumSamples(sample) > 0, pts.isNumeric, duration.isNumeric, duration > .zero else { return }
        end = max(end, (pts + duration).seconds)
    }
}

/// Every frame of the movie's audio track, decoded to interleaved Float32 in the file's own channel
/// order: the reader is given the file's channel count and layout, so it does not remap channels.
public func decodedAudioChannels(of url: URL) async throws -> (channels: Int, samples: [Float]) {
    let asset = AVURLAsset(url: url)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .audio).first, "an audio track in \(url.lastPathComponent)")
    let format = try unwrap(try await track.load(.formatDescriptions).first, "the audio format of \(url.lastPathComponent)")
    let channels = Int(try unwrap(
        CMAudioFormatDescriptionGetStreamBasicDescription(format), "the stream description of \(url.lastPathComponent)"
    ).pointee.mChannelsPerFrame)
    var settings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: channels,
    ]
    var layoutSize = 0
    if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) {
        settings[AVChannelLayoutKey] = Data(bytes: layout, count: layoutSize)
    }
    let samples = try await readTrack(track, of: asset, outputSettings: settings, into: [Float]()) { samples, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return }
        let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
        var chunk = [Float](repeating: 0, count: count)
        let status = chunk.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        samples += chunk
    }
    return (channels, samples)
}
