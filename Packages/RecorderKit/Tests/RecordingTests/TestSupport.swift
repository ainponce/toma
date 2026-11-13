// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import SyntheticCapture
import Testing

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

/// The readable duration of the movie at `url`, polled until it reaches `target` or `timeout` passes.
/// A movie that is still being written (or that AVFoundation cannot open yet) reads as 0.
func readableDuration(of url: URL, reaching target: Double, timeout: Duration = .seconds(5)) async -> Double {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var seconds = 0.0
    while true {
        seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        if seconds >= target || clock.now >= deadline { return seconds }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

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
///
/// The reading runs on a thread of its own: `copyNextSampleBuffer` blocks until AVFoundation's own
/// file reads finish, and many test cases blocking the cooperative pool that way at once starve
/// those reads of threads and deadlock the whole test run.
func readTrack<T: Sendable>(
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
    #expect(status == .completed)
    return value
}

/// The palette index (`SampleFactory.frameIndex(nearestTo:)`) of every decoded frame of the movie's
/// video track, read from a pixel near the bottom-right corner, away from the moving white square.
func decodedFrameIndices(of url: URL) async throws -> [Int] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
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
func videoMediaEnd(of url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    return try await readTrack(track, of: asset, outputSettings: nil, into: 0.0) { end, sample in
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        guard CMSampleBufferGetNumSamples(sample) > 0, pts.isNumeric, duration.isNumeric, duration > .zero else { return }
        end = max(end, (pts + duration).seconds)
    }
}

/// Channel `channel` of `multichannelAudio` at frame `frame`: a sine of 110·(c + 1) Hz at level
/// 0.05·(c + 1), so every channel differs from every other in both pitch and level.
func channelSignal(_ channel: Int, frame: Int, sampleRate: Double) -> Float {
    let c = Double(channel + 1)
    return Float(0.05 * c * sin(2 * Double.pi * 110 * c * Double(frame) / sampleRate))
}

/// Float32 LPCM, frames `startFrame ..< startFrame + frames`, where each channel carries its own
/// `channelSignal`, with the channel layout `layout`: interleaved, or `planar` (one plane per channel).
func multichannelAudio(
    pts: HostTime, startFrame: Int, frames: Int, sampleRate: Double, channels: Int, layout: AudioChannelLayoutTag,
    planar: Bool = false
) throws -> CMSampleBuffer {
    var samples = [Float](repeating: 0, count: frames * channels)
    for n in 0..<frames {
        for c in 0..<channels {
            samples[planar ? c * frames + n : n * channels + c] = channelSignal(c, frame: startFrame + n, sampleRate: sampleRate)
        }
    }
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (planar ? 1 : channels))
    let flags = kAudioFormatFlagsNativeFloatPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
    )
    var channelLayout = AudioChannelLayout()
    channelLayout.mChannelLayoutTag = layout
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
        layout: &channelLayout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    ) == noErr)
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
    ) == noErr)
    let data = try #require(block)
    try samples.withUnsafeBytes { bytes in
        try #require(CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: byteCount
        ) == noErr)
    }
    var sample: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: try #require(format), sampleCount: frames,
        presentationTimeStamp: pts.cmTime, packetDescriptions: nil, sampleBufferOut: &sample
    ) == noErr)
    return try #require(sample)
}

/// Every frame of the movie's audio track, decoded to interleaved Float32 in the file's own channel
/// order: the reader is given the file's channel count and layout, so it does not remap channels.
func decodedAudio(of url: URL) async throws -> (channels: Int, samples: [Float]) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let channels = Int(try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mChannelsPerFrame)
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
