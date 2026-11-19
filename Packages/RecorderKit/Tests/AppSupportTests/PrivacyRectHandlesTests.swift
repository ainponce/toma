// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import ProjectFormat
import Testing

@Suite struct PrivacyRectHandlesTests {
    private static let output = SIMD2(1920.0, 1080)
    private static let view = SIMD2(800.0, 450)
    private static let unit = Rect(x: 0, y: 0, width: 1, height: 1)
    /// The screen filling a 16:9 output, without a zoom, and through a zoom of 2× on its centre.
    private static let plain = Rect(x: 0, y: 0, width: 1920, height: 1080)
    private static let zoomed = Rect(x: -960, y: -540, width: 3840, height: 2160)
    private static let rect = NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)

    private static func close(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-9) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) <= tolerance }
    }

    private static func close(_ a: NormalizedRect, _ b: NormalizedRect, _ tolerance: Double = 1e-9) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) <= tolerance }
    }

    private static func viewRect(_ rect: NormalizedRect, _ screen: Rect, layerCrop: Rect = unit, contentCrop: Rect = unit) -> Rect {
        PrivacyRectHandles.viewRect(
            rect, drawnScreen: screen, layerCrop: layerCrop, contentCrop: contentCrop, outputSize: output, viewSize: view)
    }

    @Test func handlesSitOnTheDrawnRect() {
        // 1920 × 1080 in 800 × 450: 5/12 of a point a pixel.
        #expect(Self.close(Self.viewRect(Self.rect, Self.plain), Rect(x: 240, y: 180, width: 320, height: 90)))
        // Twice as large, moved out from the centre.
        #expect(Self.close(Self.viewRect(Self.rect, Self.zoomed), Rect(x: 80, y: 135, width: 640, height: 180)))
        // In Area mode the content is part of the frame; a reframe draws part of that.
        let area = Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let drawn = Rect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)
        let shown = Self.viewRect(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), Self.plain, layerCrop: drawn, contentCrop: area)
        #expect(Self.close(shown, Rect(x: 0, y: 0, width: 800, height: 450)))
    }

    @Test func partsAreTheCornersTheEdgesAndTheBody() {
        let rect = Rect(x: 100, y: 100, width: 200, height: 100)
        func part(_ x: Double, _ y: Double) -> PrivacyRectHandles.Part? {
            PrivacyRectHandles.part(at: SIMD2(x, y), in: rect)
        }
        #expect(part(100, 100) == .corner(0))
        #expect(part(304, 96) == .corner(1))
        #expect(part(97, 203) == .corner(2))
        #expect(part(300, 200) == .corner(3))
        #expect(part(200, 97) == .edge(0))
        #expect(part(302, 150) == .edge(1))
        #expect(part(150, 204) == .edge(2))
        #expect(part(99, 160) == .edge(3))
        #expect(part(200, 150) == .body)
        #expect(part(200, 90) == nil)
        #expect(part(320, 150) == nil)
        // At least 8 pt of a handle are hit, whatever its size on the screen.
        #expect(PrivacyRectHandles.hitSize >= 8)
    }

    @Test func aSmallRectKeepsItsBody() {
        // 16 × 16 pt: the handles reach a quarter of it inside, the middle is the body.
        let rect = Rect(x: 100, y: 100, width: 16, height: 16)
        #expect(PrivacyRectHandles.part(at: SIMD2(108, 108), in: rect) == .body)
        #expect(PrivacyRectHandles.part(at: SIMD2(97, 97), in: rect) == .corner(0))
        #expect(PrivacyRectHandles.part(at: SIMD2(119, 108), in: rect) == .edge(1))
    }

    @Test func cornerDragResizesAndBodyDragMoves() {
        let moved = PrivacyRectHandles.dragged(Self.rect, part: .body, by: SIMD2(0.1, -0.1))
        #expect(Self.close(moved, NormalizedRect(x: 0.4, y: 0.3, width: 0.4, height: 0.2)))
        // The bottom-right corner: the top left stays.
        let grown = PrivacyRectHandles.dragged(Self.rect, part: .corner(3), by: SIMD2(0.1, 0.05))
        #expect(Self.close(grown, NormalizedRect(x: 0.3, y: 0.4, width: 0.5, height: 0.25)))
        // The top-left corner: the bottom right stays.
        let fromTheTop = PrivacyRectHandles.dragged(Self.rect, part: .corner(0), by: SIMD2(0.1, 0.05))
        #expect(Self.close(fromTheTop, NormalizedRect(x: 0.4, y: 0.45, width: 0.3, height: 0.15)))
        // An edge moves only itself.
        let wider = PrivacyRectHandles.dragged(Self.rect, part: .edge(3), by: SIMD2(-0.1, 0.3))
        #expect(Self.close(wider, NormalizedRect(x: 0.2, y: 0.4, width: 0.5, height: 0.2)))
        let taller = PrivacyRectHandles.dragged(Self.rect, part: .edge(2), by: SIMD2(0.3, 0.1))
        #expect(Self.close(taller, NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.3)))
    }

    @Test func dragsStayInsideTheContentWithAMinimum() {
        // Moved past the right and the bottom: against them, the same size.
        let pushed = PrivacyRectHandles.dragged(Self.rect, part: .body, by: SIMD2(2, 2))
        #expect(Self.close(pushed, NormalizedRect(x: 0.6, y: 0.8, width: 0.4, height: 0.2)))
        // A corner past the opposite one stops at the shortest side, never flips.
        let squeezed = PrivacyRectHandles.dragged(Self.rect, part: .corner(3), by: SIMD2(-1, -1))
        #expect(Self.close(squeezed, NormalizedRect(x: 0.3, y: 0.4, width: PrivacyGeometry.minimumSide, height: PrivacyGeometry.minimumSide)))
        // An edge past the content's: at its edge.
        let out = PrivacyRectHandles.dragged(Self.rect, part: .corner(0), by: SIMD2(-1, -1))
        #expect(Self.close(out, NormalizedRect(x: 0, y: 0, width: 0.7, height: 0.6)))
        // A number that is not one moves nothing.
        #expect(PrivacyRectHandles.dragged(Self.rect, part: .body, by: SIMD2(.nan, 0.1)) == Self.rect)
    }

    @Test func viewDeltaMapsBackThroughTheZoom() {
        let area = Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let drawn = Rect(x: 0.15, y: 0.25, width: 0.4, height: 0.4)
        for screen in [Self.plain, Self.zoomed] {
            let delta = SIMD2(37.0, -21.0)
            let content = PrivacyRectHandles.contentDelta(
                delta, drawnScreen: screen, layerCrop: drawn, contentCrop: area, outputSize: Self.output, viewSize: Self.view)
            let before = Self.viewRect(Self.rect, screen, layerCrop: drawn, contentCrop: area)
            let after = Self.viewRect(
                PrivacyRectHandles.dragged(Self.rect, part: .body, by: content), screen, layerCrop: drawn, contentCrop: area)
            #expect(abs(after.x - before.x - delta.x) < 1e-9 && abs(after.y - before.y - delta.y) < 1e-9)
            #expect(abs(after.width - before.width) < 1e-9 && abs(after.height - before.height) < 1e-9)
        }
        // Twice the zoom, half the content for the same points.
        let plain = PrivacyRectHandles.contentDelta(
            SIMD2(80, 45), drawnScreen: Self.plain, layerCrop: Self.unit, contentCrop: Self.unit, outputSize: Self.output,
            viewSize: Self.view)
        let zoomed = PrivacyRectHandles.contentDelta(
            SIMD2(80, 45), drawnScreen: Self.zoomed, layerCrop: Self.unit, contentCrop: Self.unit, outputSize: Self.output,
            viewSize: Self.view)
        #expect(abs(plain.x - 0.1) < 1e-12 && abs(plain.y - 0.1) < 1e-12)
        #expect(abs(zoomed.x - 0.05) < 1e-12 && abs(zoomed.y - 0.05) < 1e-12)
        // A screen of no size moves nothing.
        let none = PrivacyRectHandles.contentDelta(
            SIMD2(80, 45), drawnScreen: Rect(x: 0, y: 0, width: 0, height: 0), layerCrop: Self.unit, contentCrop: Self.unit,
            outputSize: Self.output, viewSize: Self.view)
        #expect(none == .zero)
    }

    @Test func movingSnapsToTheDrawnScreensEdgesAndCentre() {
        let screen = Rect(x: 0, y: 0, width: 800, height: 450)
        // Its left edge 4 pt from the screen's: onto it, with a guide there.
        let left = PrivacyRectHandles.snap(Rect(x: 4, y: 100, width: 200, height: 80), part: .body, to: screen, tolerance: 6)
        #expect(left == PrivacyRectHandles.Snap(offset: SIMD2(-4, 0), guideX: 0, guideY: nil))
        // Its centre 3 pt from the screen's, both ways.
        let centre = PrivacyRectHandles.snap(Rect(x: 303, y: 182, width: 200, height: 80), part: .body, to: screen, tolerance: 6)
        #expect(centre == PrivacyRectHandles.Snap(offset: SIMD2(-3, 3), guideX: 400, guideY: 225))
        // Too far: nothing.
        let free = PrivacyRectHandles.snap(Rect(x: 50, y: 100, width: 200, height: 80), part: .body, to: screen, tolerance: 6)
        #expect(free == PrivacyRectHandles.Snap(offset: .zero, guideX: nil, guideY: nil))
    }

    @Test func resizingSnapsOnlyTheEdgesThatMove() {
        let screen = Rect(x: 0, y: 0, width: 800, height: 450)
        // The bottom-right corner near the right edge; its left edge, near the screen's left, does not move.
        let corner = PrivacyRectHandles.snap(Rect(x: 2, y: 100, width: 795, height: 80), part: .corner(3), to: screen, tolerance: 6)
        #expect(corner == PrivacyRectHandles.Snap(offset: SIMD2(3, 0), guideX: 800, guideY: nil))
        // The top edge near the middle.
        let top = PrivacyRectHandles.snap(Rect(x: 2, y: 221, width: 100, height: 80), part: .edge(0), to: screen, tolerance: 6)
        #expect(top == PrivacyRectHandles.Snap(offset: SIMD2(0, 4), guideX: nil, guideY: 225))
    }
}
