// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording
import Synchronization
import SyntheticCapture
import Testing

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

let takeID = "take-001"
let displayID = "display-1"
let micID = "mic"

let systemAudioID = "system-audio"

let displaySource = TrackSource(
    name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1)
let micSource = TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic")
let systemAudioSource = TrackSource(name: "System Audio", excludedBundleIDs: [])

/// Root mean square of `samples[from ..< to]`, with `from` and `to` in seconds of a stream that starts at
/// `start` seconds, 48 kHz.
func rms(_ samples: [Float], start: Double, from: Double, to: Double) -> Double {
    let slice = samples[Int(((from - start) * 48_000).rounded())..<Int(((to - start) * 48_000).rounded())]
    return sqrt(slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(slice.count))
}

/// Amplitude of the `frequency` Hz component of `samples[from ..< to]` (seconds of a 48 kHz stream that starts at
/// `start`): the Goertzel algorithm over a Hann window, scaled so that a sine of amplitude A there gives A.
func toneAmplitude(_ samples: [Float], start: Double, frequency: Double, from: Double, to: Double) -> Double {
    let first = Int(((from - start) * 48_000).rounded()), count = Int(((to - start) * 48_000).rounded()) - first
    precondition(first >= 0 && count > 1 && first + count <= samples.count, "toneAmplitude: \(from) ..< \(to) s is outside the audio")
    let coefficient = 2 * cos(2 * Double.pi * frequency / 48_000)
    var previous = 0.0, beforePrevious = 0.0, windowSum = 0.0
    for n in 0..<count {
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1))
        windowSum += window
        let s = Double(samples[first + n]) * window + coefficient * previous - beforePrevious
        beforePrevious = previous
        previous = s
    }
    let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    return 2 * max(power, 0).squareRoot() / windowSum
}

/// When a burst of `frequency` Hz begins within `window` seconds of `time` in the first audio track of `url`: the
/// first time, in steps of 0.25 ms, where the tone's amplitude over 20 ms centred on it (`toneAmplitude`) reaches
/// half of its largest there. A window centred on the burst's start holds half of it, so it is the start, other
/// frequencies left out.
func toneOnset(in url: URL, frequency: Double, near time: Double, window: Double = 0.3) async throws -> Double {
    let (start, samples) = try await decodedAudio(of: url)
    let half = 0.010, step = 0.000_25
    let times = stride(from: time - window, through: time + window, by: step).filter {
        $0 - half >= start && $0 + half <= start + Double(samples.count) / 48_000
    }
    let amplitudes = times.map { toneAmplitude(samples, start: start, frequency: frequency, from: $0 - half, to: $0 + half) }
    let peak = try #require(amplitudes.max(), "no audio near \(time) s")
    #expect(peak > 0.3, "the \(frequency) Hz burst stands out")
    let onset = try #require(amplitudes.firstIndex { $0 >= peak / 2 })
    return times[onset]
}

/// Writes a burst of `seconds` of a `frequency` Hz sine at `amplitude`, on every one of `channels`, into the 10 ms
/// blocks of a 48 kHz audio segment from `start` (an `AudioSegmentSpec.transform`), at host time `time`: given that
/// its frames are `(1 + skewPPM / 1e6) / 48 kHz` seconds of host time apart, as `TakeBuilder` stamps them.
func toneBurst(
    at time: HostTime, start: HostTime, skewPPM: Double, frequency: Double, channels: Int, amplitude: Float = 0.5,
    seconds: Double = 0.05
) -> @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer {
    let firstFrame = Int((time.seconds(since: start) * 48_000 / (1 + skewPPM / 1_000_000)).rounded())
    let length = Int(seconds * 48_000)
    return { block, sample in
        let frames = CMSampleBufferGetNumSamples(sample), blockStart = block * frames
        let from = max(firstFrame, blockStart), to = min(firstFrame + length, blockStart + frames)
        guard from < to, let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        var burst = [Float]()
        for frame in from..<to {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame - firstFrame) / 48_000))
            burst.append(contentsOf: repeatElement(value, count: channels))
        }
        let status = burst.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: data,
                offsetIntoDestination: (from - blockStart) * channels * MemoryLayout<Float>.size, dataLength: $0.count)
        }
        precondition(status == noErr, "tone burst: \(status)")
        return sample
    }
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
