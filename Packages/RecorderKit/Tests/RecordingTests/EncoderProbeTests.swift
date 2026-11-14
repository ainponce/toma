// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import Metal
import ProjectFormat
import SyntheticCapture
import Testing

/// Writes one 640×360 frame with `codec` through a plain `AVAssetWriter` and returns its final status.
private func encodeOneFrame(codec: AVVideoCodecType, to url: URL) throws -> AVAssetWriter.Status {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 640, AVVideoHeightKey: 360]
    try #require(writer.canApply(outputSettings: settings, forMediaType: .video))
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let deadline = ContinuousClock.now + .seconds(5)
    while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    try #require(input.isReadyForMoreMediaData && writer.status == .writing)
    let frame = SampleFactory.videoSample(width: 640, height: 360, pts: HostTime(nanoseconds: 0), frameIndex: 0)
    try #require(input.append(frame))
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))

    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    #expect(writer.error == nil)
    return writer.status
}

@Test func hevcAndH264EncodersAreAvailable() throws {
    print("Metal device: \(MTLCreateSystemDefaultDevice()?.name ?? "none")")
    // In CI the drawing tests run even without a device (they would fail); say why here first.
    if ProcessInfo.processInfo.environment["TOMA_CI"] == "1" {
        #expect(MTLCreateSystemDefaultDevice() != nil, "this runner has no Metal device: the render and export tests fail")
    }
    try withTemporaryDirectory { dir in
        for codec in [AVVideoCodecType.hevc, .h264] {
            let url = dir.appendingPathComponent("probe-\(codec.rawValue).mov")
            #expect(try encodeOneFrame(codec: codec, to: url) == .completed, "codec \(codec.rawValue)")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 0, "codec \(codec.rawValue)")
        }
    }
}
