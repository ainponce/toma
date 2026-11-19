// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import CoreVideo
import Foundation
import ProjectFormat

/// The frames of an iPhone or iPad turned during its take (phase 2 design §7.6, plan 2c decision 18), fitted as they are
/// read. Turning the device changes the size of its frames, and the track goes on in a segment of that size; every frame
/// of another size than the track's first segment (`TrackSource.globalFrame`) is read scaled whole into that size, without
/// cropping, centred, with video black (BGRA 0, 0, 0, 255) around it. The placement and the geometry stay those of the
/// first segment, and the preview, the scrub and the export read the same frames (`TrackFrameReader`, `KeyFrameDecoder`).
/// The scale is vImage's (Lanczos), the same on every read.
enum DeviceFrameFit {
    /// The size every frame of `track` is read at: for a `device` track, its `globalFrame` in pixels (× `pixelScale`,
    /// which is 1), the size of its first segment. `nil` for any other kind of track, whose frames are read as recorded,
    /// and for a device that never told its size (no `globalFrame`, or one that is not finite and positive).
    static func referenceSize(of track: TrackRecord) -> SIMD2<Int>? {
        guard track.kind == .device, let frame = track.source.globalFrame else { return nil }
        let scale = track.source.pixelScale ?? 1
        let width = (frame.width * scale).rounded(), height = (frame.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 65_536, height <= 65_536 else { return nil }
        return SIMD2(Int(width), Int(height))
    }

    /// Where a frame of `source` pixels goes in one of `size`: scaled by the larger factor that keeps it whole, its sides
    /// rounded to whole pixels, and centred (the half pixel left over to the bottom and the right).
    static func placement(of source: SIMD2<Int>, in size: SIMD2<Int>) -> (origin: SIMD2<Int>, size: SIMD2<Int>) {
        guard source.x > 0, source.y > 0, size.x > 0, size.y > 0 else { return (.zero, size) }
        let scale = min(Double(size.x) / Double(source.x), Double(size.y) / Double(source.y))
        let fitted = SIMD2(
            min(max(Int((Double(source.x) * scale).rounded()), 1), size.x),
            min(max(Int((Double(source.y) * scale).rounded()), 1), size.y))
        return ((size &- fitted) / 2, fitted)
    }

    /// `buffer` itself when it is `size` already; otherwise a new BGRA, IOSurface-backed, Metal-compatible buffer of
    /// `size` from `pool` (made, or made again for another size, here) with `buffer` scaled whole into it at `placement`
    /// and black around it, and `buffer`'s attachments. `nil` when it cannot be made: a frame that is not BGRA, a pool or a
    /// scale that fails (the reader then holds the frame before, its rule for a frame it cannot give).
    static func fitted(_ buffer: CVPixelBuffer, into size: SIMD2<Int>, pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
        let source = SIMD2(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        if source == size { return buffer }
        guard size.x > 0, size.y > 0, source.x > 0, source.y > 0,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(buffer),
              let output = makeBuffer(size, pool: &pool)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let from = CVPixelBufferGetBaseAddress(buffer), let into = CVPixelBufferGetBaseAddress(output) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(output)
        var whole = vImage_Buffer(data: into, height: vImagePixelCount(size.y), width: vImagePixelCount(size.x), rowBytes: rowBytes)
        let black: [UInt8] = [0, 0, 0, 255]
        guard vImageBufferFill_ARGB8888(&whole, black, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        let placed = placement(of: source, in: size)
        var destination = vImage_Buffer(
            data: into.advanced(by: placed.origin.y * rowBytes + placed.origin.x * 4), height: vImagePixelCount(placed.size.y),
            width: vImagePixelCount(placed.size.x), rowBytes: rowBytes)
        var frame = vImage_Buffer(
            data: from, height: vImagePixelCount(source.y), width: vImagePixelCount(source.x),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        guard vImageScale_ARGB8888(&frame, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        CVBufferPropagateAttachments(buffer, output)
        return output
    }

    /// A buffer of `size` from `pool`, which is made first when there is none or it makes buffers of another size.
    private static func makeBuffer(_ size: SIMD2<Int>, pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
        if let existing = pool, !makes(existing, size) { pool = nil }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.x,
                kCVPixelBufferHeightKey as String: size.y,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made) == kCVReturnSuccess else {
                return nil
            }
            pool = made
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Whether `pool` makes buffers of `size`.
    private static func makes(_ pool: CVPixelBufferPool, _ size: SIMD2<Int>) -> Bool {
        guard let attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool) as? [String: Any],
              let width = (attributes[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue,
              let height = (attributes[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue
        else { return false }
        return width == size.x && height == size.y
    }
}
