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

/// The palette index (`SampleFactory.frameIndex(nearestTo:)`) of every decoded frame of the movie's
/// video track, read from a pixel near the bottom-right corner, away from the moving white square.
func decodedFrameIndices(of url: URL) async throws -> [Int] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    try #require(reader.canAdd(output))
    reader.add(output)
    try #require(reader.startReading())
    var indices: [Int] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        indices.append(SampleFactory.frameIndex(nearestTo: bottomRightPixel(of: pixelBuffer)))
    }
    #expect(reader.status == .completed)
    return indices
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
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    try #require(reader.canAdd(output))
    reader.add(output)
    try #require(reader.startReading())
    var end = 0.0
    while let sample = output.copyNextSampleBuffer() {
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        guard CMSampleBufferGetNumSamples(sample) > 0, pts.isNumeric, duration.isNumeric, duration > .zero else { continue }
        end = max(end, (pts + duration).seconds)
    }
    #expect(reader.status == .completed)
    return end
}
