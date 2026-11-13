// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Testing
import ProjectFormat

@Suite struct CursorGeometryTests {
    @Test func normalizesPointOnSecondaryDisplayWithNegativeOrigin() {
        let secondary = Rect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(CursorGeometry.normalized(CGPoint(x: -960, y: 340), in: secondary) == SIMD2(0.5, 0.5))
        #expect(CursorGeometry.contains(CGPoint(x: 10, y: 10), secondary) == false)
        #expect(CursorGeometry.contains(CGPoint(x: -960, y: 340), secondary))
    }

    @Test func containsIsHalfOpen() {
        let frame = Rect(x: 0, y: 0, width: 100, height: 50)
        #expect(CursorGeometry.contains(CGPoint(x: 0, y: 0), frame))
        #expect(CursorGeometry.contains(CGPoint(x: 99.9, y: 49.9), frame))
        #expect(!CursorGeometry.contains(CGPoint(x: 100, y: 10), frame))
        #expect(!CursorGeometry.contains(CGPoint(x: 10, y: 50), frame))
        #expect(!CursorGeometry.contains(CGPoint(x: -0.1, y: 10), frame))
    }

    @Test func normalizedOutsideFrameIsOutsideUnitRange() {
        let frame = Rect(x: 100, y: 100, width: 200, height: 100)
        #expect(CursorGeometry.normalized(CGPoint(x: 0, y: 200), in: frame) == SIMD2(-0.5, 1.0))
    }
}
