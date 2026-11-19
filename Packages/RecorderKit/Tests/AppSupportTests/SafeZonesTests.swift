// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import AppSupport

@Suite struct SafeZonesTests {
    @Test func onlyForTallOutputs() {
        #expect(SafeZones.applies(to: SIMD2(1080, 1920)))  // 9:16
        #expect(SafeZones.applies(to: SIMD2(1080, 1350)))  // 4:5
        #expect(SafeZones.applies(to: SIMD2(1080, 1440)))  // 3:4
        #expect(SafeZones.applies(to: SIMD2(1000, 1250)))  // "like the recording" at exactly 0.8
        #expect(!SafeZones.applies(to: SIMD2(1080, 1080)))  // 1:1
        #expect(!SafeZones.applies(to: SIMD2(1440, 1080)))  // 4:3
        #expect(!SafeZones.applies(to: SIMD2(1920, 1080)))  // 16:9
        #expect(!SafeZones.applies(to: SIMD2(0, 0)))
        #expect(SafeZones.applies(ratio: 0.8))
        #expect(!SafeZones.applies(ratio: .nan))
    }

    @Test func zonesOfReels() {
        let rects = SafeZones.rects(in: SIMD2(1080, 1920))
        #expect(rects.count == 3)
        let top = rects[0], bottom = rects[1], right = rects[2]
        #expect(top.y == 0 && abs(top.height - 230.4) < 1e-9 && top.width == 1080)
        #expect(abs(bottom.y - 1497.6) < 1e-9 && abs(bottom.height - 422.4) < 1e-9)
        #expect(abs(right.x - 928.8) < 1e-9 && abs(right.width - 151.2) < 1e-9)
        // The right strip sits between the other two: nothing is covered twice.
        #expect(abs(right.y - top.height) < 1e-9 && abs(right.y + right.height - bottom.y) < 1e-9)
    }
}
