// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import Recording
import Synchronization
import SyntheticCapture
import Testing

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

/// Whether the tests that draw run: on a machine with a Metal device, and always in CI (`TOMA_CI=1`), where a
/// runner without one must fail them loudly instead of skipping them and staying green.
let metalAvailable = MTLCreateSystemDefaultDevice() != nil || ProcessInfo.processInfo.environment["TOMA_CI"] == "1"

let takeID = "take-001"
let displayID = "display-1"
let micID = "mic"

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

// MARK: - Synthetic projects

/// One microphone segment of a synthetic take: `seconds` of the `SampleFactory` sine from `start` seconds
/// after `base`, with `channels` channels at 48 kHz. Without a file, the manifest lists it but nothing is
/// written.
struct MicSegment {
    enum Contents { case audio, none, garbage }

    var start: Double
    var seconds: Double
    var channels = 1
    var endReason = SegmentEndReason.stopped
    /// What is written at the segment's path: its audio, nothing, or 4 KiB that are not a movie.
    var contents = Contents.audio
}

/// `<directory>/Synthetic.toma` with one complete take written as the recorder would: `seconds` of 30 fps
/// 640×360 `SampleFactory` video from `base`, the microphone segments `mic` (by default one as long as the
/// video; no microphone track at all when `microphone` is false), and the manifest on disk.
func makeSyntheticPackage(
    in directory: URL, seconds: Double, mic: [MicSegment]? = nil, microphone: Bool = true, noise: Bool = false
) async throws -> ProjectPackage {
    let package = try ProjectPackage.create(in: directory, name: "Synthetic", app: AppInfo(name: "Tests", version: "0"), now: Date())

    let videoURL = package.segmentURL(take: takeID, track: displayID, index: 1)
    try FileManager.default.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let video = try FragmentedTrackWriter(url: videoURL, media: .video(framesPerSecond: 30), realTime: false)
    for i in 0..<Int((seconds * 30).rounded()) {
        let pts = base.adding(seconds: Double(i) / 30)
        try video.append(noise
            ? noiseVideoSample(width: 640, height: 360, pts: pts.cmTime, seed: UInt64(i))
            : SampleFactory.videoSample(width: 640, height: 360, pts: pts, frameIndex: i))
    }
    let videoResult = try await video.finish(at: base.adding(seconds: seconds))
    #expect(video.failure == nil)

    var micRecords: [SegmentRecord] = []
    for (k, segment) in (microphone ? mic ?? [MicSegment(start: 0, seconds: seconds)] : []).enumerated() {
        let url = package.segmentURL(take: takeID, track: micID, index: k + 1)
        let start = base.adding(seconds: segment.start)
        var end = start.adding(seconds: segment.seconds)
        if segment.contents == .garbage {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 4096).write(to: url)
        } else if segment.contents == .audio {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let audio = try FragmentedTrackWriter(url: url, media: .audio, realTime: false)
            for block in 0..<Int((segment.seconds * 100).rounded()) {
                try audio.append(SampleFactory.audioSample(
                    pts: start.adding(seconds: Double(block) / 100), frames: 480, sampleRate: 48_000, channels: segment.channels))
            }
            end = try await audio.finish(at: end).endHostTime
            #expect(audio.failure == nil)
        }
        micRecords.append(SegmentRecord(
            index: k + 1, file: try package.relativePath(of: url), startHostTime: start,
            endHostTime: end, endReason: segment.endReason, droppedFrames: 0, heartbeatFrames: 0))
    }

    var tracks = [
        TrackRecord(
            id: displayID, kind: .display,
            source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1),
            segments: [SegmentRecord(
                index: 1, file: try package.relativePath(of: videoURL), startHostTime: base,
                endHostTime: videoResult.endHostTime, endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)]),
    ]
    if microphone {
        tracks.append(TrackRecord(
            id: micID, kind: .microphone, source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: micRecords))
    }
    let take = TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    try ManifestStore(package: package).update { $0.takes.append(take) }
    return package
}

/// Root mean square of `samples[from ..< to]`, with `from` and `to` in seconds of a stream that starts at
/// `start` seconds, 48 kHz.
func rms(_ samples: [Float], start: Double, from: Double, to: Double) -> Double {
    let slice = samples[Int(((from - start) * 48_000).rounded())..<Int(((to - start) * 48_000).rounded())]
    return sqrt(slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(slice.count))
}

/// Every regular file under `directory` with its bytes, by path relative to it.
func snapshot(of directory: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let root = directory.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey]) else {
        return files
    }
    for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        files[String(url.resolvingSymlinksInPath().path.dropFirst(root.count))] = try Data(contentsOf: url)
    }
    return files
}

/// The names in `directory` that contain `.partial`.
func partialFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".partial") }
}

// MARK: - Reading an MP4

private enum TrackReadError: Error {
    case cannotAddOutput, didNotStart
}

/// Reads every sample of the first `mediaType` track of `url` with `outputSettings`, folding them into
/// `initial` with `fold`.
///
/// The reading runs on a thread of its own, as in the recording tests: `copyNextSampleBuffer` blocks until
/// AVFoundation's own file reads finish, and many test cases blocking the cooperative pool that way at once
/// can starve those reads of threads and deadlock the test run.
func readTrack<T: Sendable>(
    of url: URL, mediaType: AVMediaType, outputSettings: [String: any Sendable]?, into initial: T,
    _ fold: @escaping @Sendable (inout T, CMSampleBuffer) throws -> Void
) async throws -> T {
    let asset = AVURLAsset(url: url)
    // Handed over to the reading thread, and not used here again.
    nonisolated(unsafe) let track = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
    let (value, status) = try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result { () throws -> (T, AVAssetReader.Status) in
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                guard reader.canAdd(output) else { throw TrackReadError.cannotAddOutput }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? TrackReadError.didNotStart }
                var value = initial
                while let sample = output.copyNextSampleBuffer() { try fold(&value, sample) }
                return (value, reader.status)
            })
        }.start()
    }
    #expect(status == .completed)
    return value
}

struct DecodedFrame: Sendable {
    var time: Double
    var width: Int
    var height: Int
    /// BGRA, `width × 4` bytes per row.
    var bytes: [UInt8]
}

/// Folds every decoded frame of the first video track, as BGRA, in presentation order.
func readVideoFrames<T: Sendable>(of url: URL, into initial: T, _ fold: @escaping @Sendable (inout T, DecodedFrame) -> Void) async throws -> T {
    let settings: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    return try await readTrack(of: url, mediaType: .video, outputSettings: settings, into: initial) { value, sample in
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        fold(&value, DecodedFrame(
            time: sample.presentationTimeStamp.seconds,
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
            bytes: packedBytes(of: pixelBuffer)))
    }
}

/// The decoded frame of the first video track presented closest to `time`.
func videoFrame(of url: URL, nearest time: Double) async throws -> DecodedFrame {
    let best = try await readVideoFrames(of: url, into: DecodedFrame?.none) { best, frame in
        if best.map({ abs($0.time - time) > abs(frame.time - time) }) ?? true { best = frame }
    }
    return try #require(best)
}

/// The first audio track decoded as 48 kHz Float32: channel 0 of every frame, and the presentation time of
/// the first one.
func decodedAudio(of url: URL) async throws -> (start: Double, samples: [Float]) {
    let settings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let (start, samples) = try await readTrack(of: url, mediaType: .audio, outputSettings: settings, into: (Double?.none, [Float]())) { value, sample in
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sample)
        else { return }
        if value.0 == nil { value.0 = sample.presentationTimeStamp.seconds }
        let channels = Int(asbd.mChannelsPerFrame)
        var interleaved = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        _ = interleaved.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        value.1.append(contentsOf: stride(from: 0, to: interleaved.count, by: channels).map { interleaved[$0] })
    }
    return (try #require(start), samples)
}

// MARK: - Image comparison

/// BGRA bytes of a pixel buffer without row padding.
func packedBytes(of pixelBuffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        bytes.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: y * bytesPerRow), count: width * 4))
    }
    return bytes
}

/// The BGRA pixel at (`x`, `y`) of packed BGRA bytes `width` pixels wide.
func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> SIMD4<UInt8> {
    let i = (y * width + x) * 4
    return SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
}

/// Mean SSIM of the Rec.709 luma of two packed BGRA images, over non-overlapping 8×8 windows, with the
/// usual constants for 8-bit samples (C1 = (0.01 · 255)², C2 = (0.03 · 255)²).
func ssimLuma(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Double {
    precondition(a.count == width * height * 4 && b.count == a.count, "ssimLuma: images of another size")
    func luma(_ bytes: [UInt8], _ i: Int) -> Double {
        0.0722 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.2126 * Double(bytes[i + 2])
    }
    let c1 = (0.01 * 255.0) * (0.01 * 255.0), c2 = (0.03 * 255.0) * (0.03 * 255.0)
    var total = 0.0
    var windows = 0
    for y0 in stride(from: 0, through: height - 8, by: 8) {
        for x0 in stride(from: 0, through: width - 8, by: 8) {
            var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
            for y in y0..<(y0 + 8) {
                for x in x0..<(x0 + 8) {
                    let i = (y * width + x) * 4
                    let la = luma(a, i), lb = luma(b, i)
                    sumA += la; sumB += lb; sumAA += la * la; sumBB += lb * lb; sumAB += la * lb
                }
            }
            let n = 64.0
            let meanA = sumA / n, meanB = sumB / n
            let varA = sumAA / n - meanA * meanA, varB = sumBB / n - meanB * meanB
            let covariance = sumAB / n - meanA * meanB
            total += ((2 * meanA * meanB + c1) * (2 * covariance + c2)) / ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2))
            windows += 1
        }
    }
    return total / Double(windows)
}

// MARK: - Flash and click

/// Presentation time of the first decoded frame whose centre is white: the flash.
func flashTime(in url: URL) async throws -> Double {
    let found = try await readVideoFrames(of: url, into: Double?.none) { found, frame in
        guard found == nil else { return }
        let p = pixel(frame.bytes, width: frame.width, x: frame.width / 2, y: frame.height / 2)
        if p.x > 240, p.y > 240, p.z > 240 { found = frame.time }
    }
    return try #require(found, "no white frame")
}

/// Time of the loudest sample of the first audio track within `window` seconds of `time`: the click.
func clickTime(in url: URL, near time: Double, window: Double = 0.5) async throws -> Double {
    let (start, samples) = try await decodedAudio(of: url)
    let from = max(0, Int(((time - window - start) * 48_000).rounded(.down)))
    let to = min(samples.count, Int(((time + window - start) * 48_000).rounded(.up)))
    try #require(from < to, "no audio near \(time) s")
    var loudest = from
    for i in from..<to where abs(samples[i]) > abs(samples[loudest]) { loudest = i }
    #expect(abs(samples[loudest]) > 0.6, "the click stands out from the 0.25 sine")
    return start + Double(loudest) / 48_000
}

/// A BGRA, IOSurface-backed frame of random pixels (SplitMix64 from `seed`) presented at `pts`: content no
/// encoder can compress below its target bitrate.
func noiseVideoSample(width: Int, height: Int, pts: CMTime, seed: UInt64) -> CMSampleBuffer {
    var state = seed &* 0x9E37_79B9_7F4A_7C15
    return videoSample(width: width, height: height, pts: pts) { base, bytesPerRow in
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt64.self)
            for x in 0..<(width / 2) {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                row[x] = (z ^ (z >> 31)) | 0xFF00_0000_FF00_0000  // two pixels, opaque
            }
        }
    }
}

/// A BGRA, IOSurface-backed white frame presented at `pts`.
func whiteVideoSample(width: Int, height: Int, pts: CMTime) -> CMSampleBuffer {
    videoSample(width: width, height: height, pts: pts) { base, bytesPerRow in
        memset(base, 0xFF, bytesPerRow * height)
    }
}

/// A BGRA, IOSurface-backed frame presented at `pts`, its pixels written by `fill(baseAddress, bytesPerRow)`.
private func videoSample(width: Int, height: Int, pts: CMTime, fill: (UnsafeMutableRawPointer, Int) -> Void) -> CMSampleBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
    guard status == kCVReturnSuccess, let pixelBuffer = created else { preconditionFailure("video frame: \(status)") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    fill(CVPixelBufferGetBaseAddress(pixelBuffer)!, CVPixelBufferGetBytesPerRow(pixelBuffer))
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    do {
        let format = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
    } catch {
        preconditionFailure("video frame: \(error)")
    }
}

/// A capture source that hands what `inner` produces to the sink through `transform`, on the same queue.
final class TransformingSource: CaptureSource {
    let inner: any CaptureSource
    private let transform: @Sendable (CMSampleBuffer) -> CMSampleBuffer

    var trackID: String { inner.trackID }
    var kind: TrackKind { inner.kind }
    var media: TrackMedia { inner.media }
    var sourceInfo: TrackSource { inner.sourceInfo }
    var activeDeviceUniqueID: String? { inner.activeDeviceUniqueID }

    init(_ inner: any CaptureSource, transform: @escaping @Sendable (CMSampleBuffer) -> CMSampleBuffer) {
        self.inner = inner
        self.transform = transform
    }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await inner.start(on: queue, sink: Relay(sink: sink, transform: transform))
    }

    func stop() async {
        await inner.stop()
    }

    private final class Relay: CaptureSink {
        let sink: any CaptureSink
        let transform: @Sendable (CMSampleBuffer) -> CMSampleBuffer

        init(sink: any CaptureSink, transform: @escaping @Sendable (CMSampleBuffer) -> CMSampleBuffer) {
            self.sink = sink
            self.transform = transform
        }

        func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
            sink.source(trackID, didOutput: transform(sample))
        }

        func source(_ trackID: String, didStopWithError error: any Error) {
            sink.source(trackID, didStopWithError: error)
        }
    }
}

/// Turns the frames presented in `[from, from + seconds)` white.
func flashing(_ source: SyntheticVideoSource, width: Int, height: Int, from: HostTime, seconds: Double) -> TransformingSource {
    let end = from.adding(seconds: seconds)
    return TransformingSource(source) { sample in
        let pts = HostTime(sample.presentationTimeStamp)
        guard pts >= from, pts < end else { return sample }
        return whiteVideoSample(width: width, height: height, pts: sample.presentationTimeStamp)
    }
}

/// Writes a click (`clickLength` samples at 0.95) into mono Float32 audio at host time `at`, given that the
/// source's samples are `(1 + skewPPM / 1e6) / sampleRate` seconds of host time apart, as
/// `SyntheticAudioSource` stamps them.
func clicking(_ source: SyntheticAudioSource, at time: HostTime, skewPPM: Double, sampleRate: Double = 48_000) -> TransformingSource {
    let clickLength = 8
    let period = (1 + skewPPM / 1_000_000) / sampleRate
    let pending = Mutex(clickLength)  // click samples still to write
    return TransformingSource(source) { sample in
        let frames = CMSampleBufferGetNumSamples(sample)
        let pts = HostTime(sample.presentationTimeStamp)
        let offset = time.seconds(since: pts) / period
        let first: Int
        if offset >= 0, offset < Double(frames) {
            first = Int(offset.rounded(.down))
        } else if offset < 0, pending.withLock({ $0 }) < clickLength {
            first = 0  // the rest of a click that began in the previous block
        } else {
            return sample
        }
        let count = pending.withLock { remaining in
            let count = min(remaining, frames - first)
            remaining -= count
            return count
        }
        guard count > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let click = [Float](repeating: 0.95, count: count)
        let status = click.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: first * MemoryLayout<Float>.size,
                dataLength: $0.count)
        }
        precondition(status == noErr, "click: \(status)")
        return sample
    }
}
