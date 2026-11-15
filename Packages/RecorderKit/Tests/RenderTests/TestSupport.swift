// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import SyntheticCapture

/// An arbitrary host time well after boot.
let base = HostTime(nanoseconds: 5_000_000_000_000)

let takeID = "take-001"
let trackID = "display-1"
let cameraID = "camera"
let cameraSource = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")

func displaySource(globalFrame: Rect?, pixelScale: Double = 1) -> TrackSource {
    TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: globalFrame, pixelScale: pixelScale)
}

/// A track without files, for tests that only look at the manifest: display 1 by default, or a track `id` of
/// another `kind` (a window, a camera) with the same `globalFrame` and `pixelScale` and no `displayID`.
func displayTrack(
    id: String = trackID, kind: TrackKind = .display, displayID: UInt32 = 1, globalFrame: Rect?, pixelScale: Double = 1,
    captureArea: Rect? = nil, segments: [SegmentRecord]
) -> TrackRecord {
    var source = displaySource(globalFrame: globalFrame, pixelScale: pixelScale)
    source.displayID = kind == .display ? displayID : nil
    source.captureArea = captureArea
    return TrackRecord(id: id, kind: kind, source: source, segments: segments)
}

func makeTake(tracks: [TrackRecord], cameraStyle: CameraStyle? = nil) -> TakeRecord {
    TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks,
        cameraStyle: cameraStyle)
}

func makeProject(_ package: ProjectPackage, take: TakeRecord, events: [InputEvent] = []) -> LoadedProject {
    let manifest = Manifest(
        formatVersion: Manifest.currentFormatVersion, app: AppInfo(name: "Tests", version: "0"),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000), takes: [take])
    return LoadedProject(package: package, manifest: manifest, take: take, events: events)
}

/// A segment record of track `track` without a file, for tests that only look at the manifest.
func segment(
    track: String = trackID, index: Int = 1, start: HostTime, end: HostTime?, reason: SegmentEndReason? = .stopped
) -> SegmentRecord {
    SegmentRecord(
        index: index, file: "takes/\(takeID)/\(track)/seg-\(String(format: "%04d", index)).mov",
        startHostTime: start, endHostTime: end, endReason: reason, droppedFrames: 0, heartbeatFrames: 0)
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

/// `sample` with the bottom-right quarter of its frame painted green (a `VideoSegmentSpec.transform`), so where the
/// frame's corners land in the output can be seen whatever its size.
@Sendable func paintingTheBottomRightQuarterGreen(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in height / 2..<height {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + width / 2 * 4)
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFF00_FF00, count: width - width / 2)  // BGRA (0, 255, 0, 255)
    }
    return sample
}
