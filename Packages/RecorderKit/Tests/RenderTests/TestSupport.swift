// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import Recording
import SyntheticCapture
import Testing

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

/// Whether this machine has a Metal device; tests that draw are skipped without one.
let metalAvailable = MTLCreateSystemDefaultDevice() != nil

let takeID = "take-001"
let trackID = "display-1"

/// A fresh, empty directory that is removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RenderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

/// `<directory>/Test.toma` with an empty manifest.
func makePackage(in directory: URL) throws -> ProjectPackage {
    try ProjectPackage.create(in: directory, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
}

func displayTrack(globalFrame: Rect?, pixelScale: Double = 1, segments: [SegmentRecord]) -> TrackRecord {
    TrackRecord(
        id: trackID, kind: .display,
        source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: globalFrame, pixelScale: pixelScale),
        segments: segments)
}

func makeTake(tracks: [TrackRecord]) -> TakeRecord {
    TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
}

func makeProject(_ package: ProjectPackage, take: TakeRecord, events: [InputEvent] = []) -> LoadedProject {
    let manifest = Manifest(
        formatVersion: Manifest.currentFormatVersion, app: AppInfo(name: "Tests", version: "0"),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000), takes: [take])
    return LoadedProject(package: package, manifest: manifest, take: take, events: events)
}

/// A segment record without a file, for tests that only look at the manifest.
func segment(index: Int = 1, start: HostTime, end: HostTime?, reason: SegmentEndReason? = .stopped) -> SegmentRecord {
    SegmentRecord(
        index: index, file: "takes/\(takeID)/\(trackID)/seg-\(String(format: "%04d", index)).mov",
        startHostTime: start, endHostTime: end, endReason: reason, droppedFrames: 0, heartbeatFrames: 0)
}

/// Writes segment `index` of the display track: `seconds` of 30 fps synthetic video from `start`, the frames
/// numbered from `firstFrame` (`SampleFactory.color(forFrame:)`), finished at `start + seconds`.
func writeSegment(
    in package: ProjectPackage, index: Int, start: HostTime, seconds: Double, firstFrame: Int = 0,
    width: Int = 640, height: Int = 360
) async throws -> SegmentRecord {
    let url = package.segmentURL(take: takeID, track: trackID, index: index)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
    for i in 0..<Int((seconds * 30).rounded()) {
        try writer.append(SampleFactory.videoSample(
            width: width, height: height, pts: start.adding(seconds: Double(i) / 30), frameIndex: firstFrame + i))
    }
    let result = try await writer.finish(at: start.adding(seconds: seconds))
    #expect(writer.failure == nil)
    return SegmentRecord(
        index: index, file: try package.relativePath(of: url), startHostTime: start,
        endHostTime: result.endHostTime, endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
}

/// The palette index of a decoded frame, read near its bottom-right corner, away from the moving white square.
func frameIndex(of pixelBuffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let x = CVPixelBufferGetWidth(pixelBuffer) - 8
    let y = CVPixelBufferGetHeight(pixelBuffer) - 8
    let p = CVPixelBufferGetBaseAddress(pixelBuffer)!
        .advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4)
        .assumingMemoryBound(to: UInt8.self)
    return SampleFactory.frameIndex(nearestTo: SIMD4(p[0], p[1], p[2], p[3]))
}

/// The BGRA pixel at (`x`, `y`) of tightly packed BGRA bytes `width` pixels wide.
func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> SIMD4<UInt8> {
    let i = (y * width + x) * 4
    return SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
}

/// The bytes of a BGRA pixel buffer without row padding.
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

/// The background the compositor should draw at pixel (`x`, `y`) of an image `size` big, as BGRA:
/// `t = dot(uv − 0.5, (sin θ, −cos θ)) + 0.5` at the pixel centre, clamped to 0...1.
func expectedBackground(x: Int, y: Int, size: SIMD2<Int>, start: SIMD4<Float>, end: SIMD4<Float>, angleDegrees: Float) -> SIMD4<Float> {
    let uv = SIMD2<Float>((Float(x) + 0.5) / Float(size.x), (Float(y) + 0.5) / Float(size.y))
    let theta = angleDegrees * .pi / 180
    let direction = SIMD2<Float>(sin(theta), -cos(theta))
    let t = min(max(((uv - 0.5) * direction).sum() + 0.5, 0), 1)
    let rgba = start + (end - start) * t
    return SIMD4(rgba.z, rgba.y, rgba.x, rgba.w) * 255
}

/// Whether every channel of `pixel` is within `tolerance` of `expected` (0...255 scale).
func isClose(_ pixel: SIMD4<UInt8>, _ expected: SIMD4<Float>, tolerance: Float = 2) -> Bool {
    let difference = SIMD4<Float>(Float(pixel.x), Float(pixel.y), Float(pixel.z), Float(pixel.w)) - expected
    return max(abs(difference.x), abs(difference.y), abs(difference.z), abs(difference.w)) <= tolerance
}

/// Cursor samples every 1/120 s for `seconds` from `start`, moving across a display at `frame`.
func cursorEvents(from start: HostTime, seconds: Double, across frame: Rect) -> [InputEvent] {
    (0..<Int(seconds * 120)).map { i in
        let f = Double(i) / (seconds * 120)
        return InputEvent(
            t: start.adding(seconds: Double(i) / 120),
            kind: .cursor(x: frame.x + frame.width * (0.2 + 0.6 * f), y: frame.y + frame.height * (0.3 + 0.4 * f)))
    }
}
