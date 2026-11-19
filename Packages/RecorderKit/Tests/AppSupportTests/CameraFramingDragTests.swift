// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Testing

@testable import AppSupport

/// The small view of Manual framing (phase 2 design §6.2): a 16:9 camera shown 320 × 180 points, the crop over it.
@Suite struct CameraFramingDragTests {
    private let frame = SIMD2<Double>(1920, 1080)
    private let view = SIMD2<Double>(320, 180)

    private func crop(center: SIMD2<Double> = SIMD2(0.5, 0.5), zoom: Double = 1.5) -> Rect {
        CameraFramingGeometry.crop(frameSize: frame, rectAspect: 1, center: center, zoom: zoom)
    }

    @Test func dragMovesTheCropAsSeen() {
        let start = NormalizedPoint(x: 0.5, y: 0.5)
        // 10 % of the view's width to the right: the centre moves 10 % of the frame, to the right.
        let right = CameraFramingDrag.center(from: start, drag: SIMD2(32, 0), viewSize: view, crop: crop(), mirrored: false)
        #expect(abs(right.x - 0.6) < 1e-12 && abs(right.y - 0.5) < 1e-12)
        // Mirrored, the picture is shown flipped: the same drag moves the frame's centre to the left.
        let mirrored = CameraFramingDrag.center(from: start, drag: SIMD2(32, 0), viewSize: view, crop: crop(), mirrored: true)
        #expect(abs(mirrored.x - 0.4) < 1e-12 && abs(mirrored.y - 0.5) < 1e-12)
        // Down by 10 % of the view's height is down by 10 % of the frame, mirrored or not.
        let down = CameraFramingDrag.center(from: start, drag: SIMD2(0, 18), viewSize: view, crop: crop(), mirrored: true)
        #expect(abs(down.x - 0.5) < 1e-12 && abs(down.y - 0.6) < 1e-12)
    }

    @Test func dragStartsFromTheCropAsSeen() {
        // A centre kept at the left edge: the crop stays inside the frame, its middle at half its width. A drag moves
        // what is seen at once, from that middle, never first through the part that shows nothing.
        let pinned = crop(center: SIMD2(0, 0.5))
        let middle = pinned.x + pinned.width / 2
        #expect(pinned.x == 0 && middle > 0.1)
        let moved = CameraFramingDrag.center(
            from: NormalizedPoint(x: 0, y: 0.5), drag: SIMD2(16, 0), viewSize: view, crop: pinned, mirrored: false)
        #expect(abs(moved.x - (middle + 0.05)) < 1e-12)
    }

    @Test func dragStaysInsideTheFrame() {
        let start = NormalizedPoint(x: 0.5, y: 0.5)
        let far = CameraFramingDrag.center(from: start, drag: SIMD2(5000, -5000), viewSize: view, crop: crop(), mirrored: false)
        #expect(far == NormalizedPoint(x: 1, y: 0))
        let farMirrored = CameraFramingDrag.center(
            from: start, drag: SIMD2(5000, 5000), viewSize: view, crop: crop(), mirrored: true)
        #expect(farMirrored == NormalizedPoint(x: 0, y: 1))
        // A view without a size, or a drag that is not a number, moves nothing.
        let none = CameraFramingDrag.center(from: start, drag: SIMD2(10, 10), viewSize: .zero, crop: crop(), mirrored: false)
        let nan = CameraFramingDrag.center(from: start, drag: SIMD2(.nan, 10), viewSize: view, crop: crop(), mirrored: false)
        #expect(none == NormalizedPoint(x: 0.5, y: 0.5) && nan == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test func seenCropIsFlippedWithTheMirror() {
        let shown = Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(CameraFramingDrag.seenCrop(shown, mirrored: false) == shown)
        let flipped = CameraFramingDrag.seenCrop(shown, mirrored: true)
        #expect(abs(flipped.x - 0.6) < 1e-12 && flipped.y == 0.2 && flipped.width == 0.3 && flipped.height == 0.4)
    }

    @Test func scrollZoomsWithinRange() {
        #expect(CameraFramingDrag.zoom(2.4, scroll: 10_000) == 2.5)
        #expect(CameraFramingDrag.zoom(1.1, scroll: -10_000) == 1)
        // Up zooms in, down zooms out, by the same factor each way; nothing scrolled, nothing changes.
        let up = CameraFramingDrag.zoom(1.5, scroll: 20), down = CameraFramingDrag.zoom(1.5, scroll: -20)
        #expect(up > 1.5 && down < 1.5 && abs(up / 1.5 - 1.5 / down) < 1e-12)
        #expect(CameraFramingDrag.zoom(1.5, scroll: 0) == 1.5)
        #expect(CameraFramingDrag.zoom(1.5, scroll: .nan) == 1.5)
        // A zoom out of range or not a number is read as the render reads it.
        #expect(CameraFramingDrag.zoom(.nan, scroll: 0) == 1 && CameraFramingDrag.zoom(9, scroll: 0) == 2.5)
    }

    @Test func aWheelNotchIsSeveralPoints() {
        #expect(CameraFramingDrag.scrollPoints(delta: 3, precise: true) == 3)
        #expect(CameraFramingDrag.scrollPoints(delta: 1, precise: false) == CameraFramingDrag.pointsPerLine)
        #expect(CameraFramingDrag.scrollPoints(delta: .infinity, precise: true) == 0)
    }

    @Test func pinchZoomsFromWhereItStarted() {
        #expect(abs(CameraFramingDrag.zoom(1.2, magnifiedBy: 1.5) - 1.8) < 1e-12)
        #expect(CameraFramingDrag.zoom(2, magnifiedBy: 4) == 2.5)
        #expect(CameraFramingDrag.zoom(1.2, magnifiedBy: 0.1) == 1)
        #expect(CameraFramingDrag.zoom(1.2, magnifiedBy: -1) == 1.2 && CameraFramingDrag.zoom(1.2, magnifiedBy: .nan) == 1.2)
    }
}
