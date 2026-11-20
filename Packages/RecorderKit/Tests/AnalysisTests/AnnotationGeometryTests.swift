// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProjectFormat
import simd

@testable import Analysis

@Suite struct AnnotationGeometryTests {
    static func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ e: Double = 1e-9) -> Bool { simd_length(a - b) < e }

    @Test func contentSpaceThroughTheDrawnCrop() {
        let drawn = Rect(x: 100, y: 50, width: 800, height: 450)
        let whole = Rect(x: 0, y: 0, width: 1, height: 1)
        #expect(AnnotationGeometry.contentSpace(contentCrop: whole, layerCrop: whole, drawnRect: drawn) == drawn)
        // Area 50 % and a reframe: the same as `PrivacyGeometry.inLayerCrop` of the whole content, scaled by the rect.
        let content = Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let layer = Rect(x: 0.15, y: 0.25, width: 0.3, height: 0.4)
        let space = AnnotationGeometry.contentSpace(contentCrop: content, layerCrop: layer, drawnRect: drawn)
        let f = PrivacyGeometry.inLayerCrop(.unit, contentCrop: content, layerCrop: layer)
        #expect(space != nil)
        #expect(abs(space!.x - (100 + f.x * 800)) < 1e-9 && abs(space!.y - (50 + f.y * 450)) < 1e-9)
        #expect(abs(space!.width - f.width * 800) < 1e-9 && abs(space!.height - f.height * 450) < 1e-9)
        // The point a content fraction names lands on the same pixel the layer draws it at.
        let p = AnnotationGeometry.point(NormalizedPoint(x: 0.4, y: 0.6), in: space!)
        let inLayer = PrivacyGeometry.inLayerCrop(NormalizedRect(x: 0.4, y: 0.6, width: 0, height: 0), contentCrop: content, layerCrop: layer)
        #expect(Self.close(p, SIMD2(100 + inLayer.x * 800, 50 + inLayer.y * 450)))
        #expect(AnnotationGeometry.contentSpace(contentCrop: whole, layerCrop: Rect(x: 0, y: 0, width: 0, height: 1), drawnRect: drawn) == nil)
    }

    @Test func outputSpaceAndTheConversions() {
        let space = AnnotationGeometry.outputSpace(outputSize: SIMD2(1920, 1080))
        #expect(space == Rect(x: 0, y: 0, width: 1920, height: 1080))
        let r = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.1)
        let px = AnnotationGeometry.pixels(r, in: Rect(x: 10, y: 20, width: 200, height: 100))
        #expect(px == Rect(x: 60, y: 70, width: 100, height: 10))
        let back = AnnotationGeometry.normalized(px, in: Rect(x: 10, y: 20, width: 200, height: 100))
        #expect(abs(back.x - 0.25) < 1e-12 && abs(back.y - 0.5) < 1e-12 && abs(back.width - 0.5) < 1e-12 && abs(back.height - 0.1) < 1e-12)
    }

    @Test func arrowCurveAndHead() {
        let space = Rect(x: 0, y: 0, width: 1000, height: 500)
        func arrow(curve: Double, head: ArrowHead = .filled) -> ArrowAnnotation {
            ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.6, y: 0.5), curve: curve, width: 0.01, head: head)
        }
        let straight = AnnotationGeometry.arrow(arrow(curve: 0), in: space)
        #expect(Self.close(straight.start, SIMD2(200, 250)) && Self.close(straight.end, SIMD2(600, 250)))
        #expect(Self.close(straight.control, SIMD2(400, 250)))
        // Curve 1: 0.5 × length (200) to the left of a rightward arrow, which is up on the screen.
        let bent = AnnotationGeometry.arrow(arrow(curve: 1), in: space)
        #expect(Self.close(bent.control, SIMD2(400, 250 - 200)))
        #expect(Self.close(AnnotationGeometry.arrow(arrow(curve: -1), in: space).control, SIMD2(400, 450)))
        // Head: w = 5 px, 4.5 w = 22.5 long, 2.25 w = 11.25 to each side, tip on `end`.
        #expect(straight.head.count == 3 && Self.close(straight.head[0], SIMD2(600, 250)))
        #expect(Self.close(straight.shaftEnd, SIMD2(577.5, 250)))
        #expect(Self.close(straight.head[1], SIMD2(577.5, 250 + 11.25)) && Self.close(straight.head[2], SIMD2(577.5, 250 - 11.25)))
        // The head follows the curve at the end: the control is up-left, so the head looks down-right.
        #expect(bent.shaftEnd.x < 600 && bent.shaftEnd.y < 250)
        #expect(Self.close(simd_normalize(bent.end - bent.shaftEnd), simd_normalize(bent.end - bent.control)))
        // Open: two strokes of 22.5 at ±28° from the tip.
        let open = AnnotationGeometry.arrow(arrow(curve: 0, head: .open), in: space)
        #expect(open.head.count == 3 && Self.close(open.head[1], SIMD2(600, 250)) && Self.close(open.shaftEnd, open.end))
        for stroke in [open.head[0], open.head[2]] {
            #expect(abs(simd_length(stroke - open.end) - 22.5) < 1e-9)
            let angle = atan2(abs(stroke.y - 250), 600 - stroke.x) * 180 / .pi
            #expect(abs(angle - 28) < 1e-9)
        }
        let none = AnnotationGeometry.arrow(arrow(curve: 0, head: .none), in: space)
        #expect(none.head.isEmpty && none.shaftEnd == none.end)
        // A point of zero length does not make NaNs.
        let dot = AnnotationGeometry.arrow(
            ArrowAnnotation(from: NormalizedPoint(x: 0.3, y: 0.3), to: NormalizedPoint(x: 0.3, y: 0.3), curve: 1, head: .filled), in: space)
        #expect(dot.head.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func arrowRectHoldsTheCurve() {
        for curve in [-1.0, -0.4, 0, 0.7, 1] {
            let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.7), to: NormalizedPoint(x: 0.6, y: 0.3), curve: curve, head: .filled)
            let rect = AnnotationGeometry.arrowRect(arrow)
            func holds(_ x: Double, _ y: Double) -> Bool {
                x >= rect.x - 1e-9 && x <= rect.x + rect.width + 1e-9 && y >= rect.y - 1e-9 && y <= rect.y + rect.height + 1e-9
            }
            #expect(holds(0.2, 0.7) && holds(0.6, 0.3))
            // The curve's own points, sampled, in a square space.
            let path = AnnotationGeometry.arrow(arrow, in: Rect(x: 0, y: 0, width: 1, height: 1))
            for i in 0...50 {
                let t = Double(i) / 50
                let p = (1 - t) * (1 - t) * path.start + 2 * (1 - t) * t * path.control + t * t * path.end
                #expect(holds(p.x, p.y))
            }
        }
        // A bent arrow's box is bigger than the ends'.
        let straightRect = AnnotationGeometry.arrowRect(
            ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.6, y: 0.5), curve: 1, head: .none))
        #expect(abs(straightRect.height - 0.1) < 1e-9 && abs(straightRect.y - 0.4) < 1e-9)
        // A straight horizontal one still has a side.
        let flat = AnnotationGeometry.arrowRect(
            ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.6, y: 0.5), head: .none))
        #expect(flat.height == AnnotationGeometry.minimumSide)
    }

    @Test func calloutTailPointsAtTheTarget() {
        let bubble = Rect(x: 100, y: 100, width: 400, height: 100)
        // Below: the base on the bottom edge, 1.2 em wide (em 20 → 24; 0.3 × 400 = 120), under the point, the tip on it.
        let below = AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(300, 260), em: 20)
        #expect(below != nil && below!.baseStart.y == 200 && below!.baseEnd.y == 200 && below!.tip == SIMD2(300, 260))
        #expect(abs(below!.baseStart.x - 288) < 1e-9 && abs(below!.baseEnd.x - 312) < 1e-9)
        // Above, left and right pick their edges.
        #expect(AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(300, 40), em: 20)?.baseStart.y == 100)
        let left = AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(20, 150), em: 20)
        #expect(left?.baseStart.x == 100 && left?.baseEnd.x == 100)
        #expect(AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(700, 150), em: 20)?.baseStart.x == 500)
        // The base keeps clear of the corners: a point past the corner moves it to the end, radius and half the base in.
        let corner = AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(490, 260), em: 20)
        #expect(abs(corner!.baseEnd.x - (500 - 10)) < 1e-9 && abs(corner!.baseStart.x - (500 - 10 - 24)) < 1e-9)
        // A big em is held to 0.3 of the edge.
        let wide = AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(300, 260), em: 500)
        #expect(abs((wide!.baseEnd.x - wide!.baseStart.x) - 120) < 1e-9)
        // Inside or on the edge: no tail.
        #expect(AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(300, 150), em: 20) == nil)
        #expect(AnnotationGeometry.calloutTail(bubble: bubble, cornerRadius: 10, target: SIMD2(300, 200), em: 20) == nil)
    }

    @Test func stepIsACircleInTheShorterSide() {
        let c = AnnotationGeometry.stepCircle(in: Rect(x: 10, y: 20, width: 80, height: 50))
        #expect(c.center == SIMD2(50, 45) && c.radius == 25)
        #expect(AnnotationGeometry.stepCircle(in: Rect(x: 0, y: 0, width: 30, height: 90)).radius == 15)
        #expect(abs(AnnotationGeometry.roundedCorner(of: Rect(x: 0, y: 0, width: 100, height: 50)) - 9) < 1e-12)
    }

    @Test func clampedKeepsContentRectsNearTheContent() {
        let content = AnnotationAnchor.content(take: "take-001", start: AnnotationFixtures.at(0), end: AnnotationFixtures.at(1))
        let a = AnnotationGeometry.clamped(NormalizedRect(x: -2, y: 3, width: 0.001, height: 0.4), anchor: content)
        #expect(a.x == -0.5 && a.width == 0.01 && abs(a.y - 1.1) < 1e-12 && a.height == 0.4)
        let b = AnnotationGeometry.clamped(NormalizedRect(x: 1.4, y: 0, width: 0.5, height: 5), anchor: content)
        #expect(abs(b.x - 1.0) < 1e-12 && b.height == 2 && b.y == -0.5)
        let inside = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        #expect(AnnotationGeometry.clamped(inside, anchor: content) == inside)
        // Of the output: the centre in 0…1, the box may hang over the edge.
        let out = AnnotationGeometry.clamped(NormalizedRect(x: 2, y: -3, width: 0.2, height: 0.1), anchor: .whole)
        #expect(abs(out.x + out.width / 2 - 1) < 1e-12 && abs(out.y + out.height / 2) < 1e-12 && out.width == 0.2)
        let tiny = AnnotationGeometry.clamped(NormalizedRect(x: .nan, y: 0.5, width: 0, height: .infinity), anchor: .output(start: 0, end: 1))
        #expect(tiny.width == 0.01 && tiny.height == 0.01 && tiny.x.isFinite)
        let kept = AnnotationGeometry.clamped(inside, anchor: .whole)
        #expect(abs(kept.x - 0.2) < 1e-12 && abs(kept.y - 0.3) < 1e-12)
    }

    @Test func aspectChangesMoveContentAnnotationsWithTheContent() {
        // The same fractions follow the content's rect when the stage's aspect changes.
        let content = Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let whole = Rect(x: 0, y: 0, width: 1, height: 1)
        let landscape = AnnotationGeometry.contentSpace(contentCrop: content, layerCrop: content, drawnRect: Rect(x: 160, y: 90, width: 1600, height: 900))!
        let portrait = AnnotationGeometry.contentSpace(contentCrop: content, layerCrop: content, drawnRect: Rect(x: 54, y: 400, width: 972, height: 547))!
        let p = NormalizedPoint(x: 0.5, y: 0.25)
        let a = AnnotationGeometry.point(p, in: landscape), b = AnnotationGeometry.point(p, in: portrait)
        #expect(abs((a.x - landscape.x) / landscape.width - 0.5) < 1e-12 && abs((b.x - portrait.x) / portrait.width - 0.5) < 1e-12)
        _ = whole
        // The unit is the content's height: a width of 0.01 is the same share of it in both.
        #expect(abs(AnnotationGeometry.pixels(NormalizedRect(x: 0, y: 0, width: 0, height: 0.05), in: landscape).height / landscape.height - 0.05) < 1e-12)
    }
}
