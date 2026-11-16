// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Render
import Testing

// While it plays, the preview draws at half the side after half a second of late frames in a row, never under 720 on
// the short side, until it pauses (design §7.8, plan decision 38).

/// Records frames every 1/60 s from `start` for `seconds`, all late or all in time; returns the last size.
private func record(_ quality: inout PreviewQuality, late: Bool, from start: Double, seconds: Double) -> SIMD2<Int> {
    var size = quality.size
    for k in 0...Int((seconds * 60).rounded()) { size = quality.record(late: late, atSeconds: start + Double(k) / 60) }
    return size
}

@Test func lateForHalfASecondHalvesTheSide() {
    var hd = PreviewQuality(exportSize: [1920, 1080])
    // Just under half a second late: still the export's size.
    #expect(record(&hd, late: true, from: 10, seconds: 0.49) == SIMD2(1920, 1080))
    // Half a second: half the side would be 960 × 540, under 720: 1280 × 720.
    #expect(hd.record(late: true, atSeconds: 10.5) == SIMD2(1280, 720))
    // It stays there while playing, in time or late.
    #expect(record(&hd, late: false, from: 10.6, seconds: 2) == SIMD2(1280, 720))
    #expect(record(&hd, late: true, from: 13, seconds: 2) == SIMD2(1280, 720))
    hd.reset()
    #expect(hd.size == SIMD2(1920, 1080))

    var uhd = PreviewQuality(exportSize: [3840, 2160])
    #expect(record(&uhd, late: true, from: 0, seconds: 0.5) == SIMD2(1920, 1080))
    uhd.reset()
    #expect(uhd.size == SIMD2(3840, 2160))
    #expect(uhd == PreviewQuality(exportSize: [3840, 2160]))

    // Only late frames in a row count: one in time starts the half second again.
    var interrupted = PreviewQuality(exportSize: [3840, 2160])
    _ = record(&interrupted, late: true, from: 0, seconds: 0.4)
    _ = interrupted.record(late: false, atSeconds: 0.41)
    #expect(record(&interrupted, late: true, from: 0.42, seconds: 0.4) == SIMD2(3840, 2160))
    #expect(interrupted.record(late: true, atSeconds: 0.92) == SIMD2(1920, 1080))

    // Portrait and square formats, and one already at 720 or under, which never changes.
    var portrait = PreviewQuality(exportSize: [1080, 1920])
    #expect(record(&portrait, late: true, from: 0, seconds: 0.5) == SIMD2(720, 1280))
    var square = PreviewQuality(exportSize: [2160, 2160])
    #expect(record(&square, late: true, from: 0, seconds: 0.5) == SIMD2(1080, 1080))
    var small = PreviewQuality(exportSize: [1280, 720])
    #expect(record(&small, late: true, from: 0, seconds: 3) == SIMD2(1280, 720))
    #expect(PreviewQuality.minimumShortSide == 720 && PreviewQuality.lateWindow == 0.5)
}
