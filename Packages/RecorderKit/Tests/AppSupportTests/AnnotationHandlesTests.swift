// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import ProjectFormat
import Testing

@Suite struct AnnotationHandlesTests {
    private typealias Part = AnnotationHandles.Part
    private static let box = Rect(x: 100, y: 100, width: 200, height: 100)
    private static let space = Rect(x: 0, y: 0, width: 800, height: 450)
    private static let frame = AnnotationFrame(rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2), size: 0.05)

    private static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    private static func part(_ x: Double, _ y: Double, behavior: AnnotationHandles.Behavior, rotation: Double = 0,
        points: [Part: SIMD2<Double>] = [:]) -> Part? {
        AnnotationHandles.part(at: SIMD2(x, y), box: box, rotation: rotation, points: points, behavior: behavior)
    }

    @Test func partsPerBehavior() {
        // Text: four corners, the edges 1 and 3 (right, left), and the body; never the top or the bottom edge.
        #expect(Self.part(100, 100, behavior: .text) == .corner(0))
        #expect(Self.part(300, 100, behavior: .text) == .corner(1))
        #expect(Self.part(100, 200, behavior: .text) == .corner(2))
        #expect(Self.part(300, 200, behavior: .text) == .corner(3))
        #expect(Self.part(300, 150, behavior: .text) == .edge(1))
        #expect(Self.part(100, 150, behavior: .text) == .edge(3))
        #expect(Self.part(200, 100, behavior: .text) == .body)
        #expect(Self.part(200, 200, behavior: .text) == .body)
        #expect(Self.part(200, 150, behavior: .text) == .body)
        #expect(Self.part(50, 50, behavior: .text) == nil)
        // Free: every edge.
        #expect(Self.part(200, 100, behavior: .free) == .edge(0))
        #expect(Self.part(200, 200, behavior: .free) == .edge(2))
        // Step: the corners only.
        #expect(Self.part(300, 200, behavior: .step) == .corner(3))
        #expect(Self.part(300, 150, behavior: .step) == .body)
        // Arrow: its ends and its body.
        let ends: [Part: SIMD2<Double>] = [.from: SIMD2(100, 100), .to: SIMD2(300, 200)]
        #expect(Self.part(101, 99, behavior: .arrow, points: ends) == .from)
        #expect(Self.part(299, 201, behavior: .arrow, points: ends) == .to)
        #expect(Self.part(200, 150, behavior: .arrow, points: ends) == .body)
        #expect(Self.part(300, 100, behavior: .arrow, points: ends) == .body)
        // Callout: the text's parts and the point, which wins where it overlaps.
        let target: [Part: SIMD2<Double>] = [.target: SIMD2(150, 260)]
        #expect(Self.part(150, 262, behavior: .callout, points: target) == .target)
        #expect(Self.part(300, 150, behavior: .callout, points: target) == .edge(1))
        let onACorner: [Part: SIMD2<Double>] = [.target: SIMD2(100, 100)]
        #expect(Self.part(100, 100, behavior: .callout, points: onACorner) == .target)
        // Behaviors by kind.
        #expect(AnnotationHandles.behavior(of: .step(StepAnnotation())) == .step)
        #expect(AnnotationHandles.behavior(of: .shape(ShapeAnnotation(shape: .rect))) == .free)
        #expect(AnnotationHandles.behavior(of: .arrow(ArrowAnnotation(from: NormalizedPoint(x: 0, y: 0), to: NormalizedPoint(x: 1, y: 1), head: .filled))) == .arrow)
        #expect(AnnotationHandles.behavior(of: .text(TextAnnotation(string: "a", preset: .plain))) == .text)
        #expect(AnnotationHandles.behavior(of: .image(ImageAnnotation(asset: "assets/x.png", fit: .fit))) == .free)
        #expect(AnnotationHandles.behavior(of: .clip(ClipAnnotation(asset: "assets/x.mov", start: 0, end: 1))) == .free)
        #expect(AnnotationHandles.behavior(
            of: .callout(CalloutAnnotation(text: TextAnnotation(string: "a", preset: .plain), target: NormalizedPoint(x: 0, y: 0)))) == .callout)
    }

    @Test func rotationIsUndoneForTheHit() {
        // 90° clockwise about the centre (200, 150): the top left corner (−100, −50 from it) is drawn at (250, 50).
        #expect(Self.part(250, 50, behavior: .free, rotation: 90) == .corner(0))
        // Where it was unrotated there is nothing now.
        #expect(Self.part(100, 100, behavior: .free, rotation: 90) == nil)
        // The bottom right corner goes to (150, 250).
        #expect(Self.part(150, 250, behavior: .free, rotation: 90) == .corner(3))
        // The centre is the body at any angle.
        #expect(Self.part(200, 150, behavior: .free, rotation: 37) == .body)
    }

    @Test func shiftKeepsTheAspect() {
        let shape = AnnotationFrame(rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2))
        let aspect = 16.0 / 9
        let before = shape.rect.width * aspect / shape.rect.height
        for part: Part in [.corner(0), .corner(1), .corner(2), .corner(3), .edge(0), .edge(1), .edge(2), .edge(3)] {
            let moved = AnnotationHandles.dragged(shape, part: part, by: SIMD2(0.08, 0.03), keepAspect: true, behavior: .free, spaceAspect: aspect)
            #expect(Self.close(moved.rect.width * aspect / moved.rect.height, before, 1e-9), "\(part)")
            #expect(moved.rect != shape.rect, "\(part)")
        }
        // Anchored on the opposite corner.
        let bottomRight = AnnotationHandles.dragged(shape, part: .corner(3), by: SIMD2(0.1, 0.0), keepAspect: true, behavior: .free, spaceAspect: aspect)
        #expect(Self.close(bottomRight.rect.x, 0.2) && Self.close(bottomRight.rect.y, 0.2))
        // Without ⇧ the corner is free.
        let free = AnnotationHandles.dragged(shape, part: .corner(3), by: SIMD2(0.1, 0.0), keepAspect: false, behavior: .free, spaceAspect: aspect)
        #expect(Self.close(free.rect.width, 0.4) && Self.close(free.rect.height, 0.2))
        // A step is always square in pixels.
        let step = AnnotationFrame(rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05 * aspect))
        let grown = AnnotationHandles.dragged(step, part: .corner(3), by: SIMD2(0.05, 0), keepAspect: false, behavior: .step, spaceAspect: aspect)
        #expect(Self.close(grown.rect.width * aspect / grown.rect.height, 1, 1e-9))
        #expect(grown.rect.width > 0.05)
    }

    @Test func textCornersScaleWidthAndSize() {
        let rect = Self.frame.rect
        // The right bottom corner, +10 % of the width: width and size by 1.1, the left and top edges stay.
        let corner = AnnotationHandles.dragged(Self.frame, part: .corner(3), by: SIMD2(0.04, 0.2), keepAspect: false, behavior: .text, spaceAspect: 16.0 / 9)
        #expect(Self.close(corner.rect.width, 0.44))
        #expect(Self.close(corner.size!, 0.055))
        #expect(Self.close(corner.rect.x, rect.x) && Self.close(corner.rect.y, rect.y))
        #expect(Self.close(corner.rect.height, rect.height * 1.1))
        // The top left corner keeps the bottom right.
        let left = AnnotationHandles.dragged(Self.frame, part: .corner(0), by: SIMD2(-0.04, 0), keepAspect: false, behavior: .text, spaceAspect: 1)
        #expect(Self.close(left.rect.x + left.rect.width, rect.x + rect.width))
        #expect(Self.close(left.rect.y + left.rect.height, rect.y + rect.height))
        #expect(Self.close(left.size!, 0.055))
        // The right side: the width only.
        let side = AnnotationHandles.dragged(Self.frame, part: .edge(1), by: SIMD2(0.04, 0.3), keepAspect: false, behavior: .text, spaceAspect: 1)
        #expect(Self.close(side.rect.width, 0.44) && Self.close(side.size!, 0.05))
        #expect(Self.close(side.rect.height, rect.height) && Self.close(side.rect.x, rect.x))
        // The left side.
        let leftSide = AnnotationHandles.dragged(Self.frame, part: .edge(3), by: SIMD2(0.05, 0), keepAspect: false, behavior: .text, spaceAspect: 1)
        #expect(Self.close(leftSide.rect.width, 0.35) && Self.close(leftSide.rect.x, 0.25))
        // It never flips nor goes below the least side.
        let crushed = AnnotationHandles.dragged(Self.frame, part: .edge(1), by: SIMD2(-5, 0), keepAspect: false, behavior: .text, spaceAspect: 1)
        #expect(Self.close(crushed.rect.width, AnnotationGeometry.minimumSide))
        // Top and bottom edges do nothing to a text.
        #expect(AnnotationHandles.dragged(Self.frame, part: .edge(0), by: SIMD2(0, 0.1), keepAspect: false, behavior: .text, spaceAspect: 1) == Self.frame)
    }

    @Test func bodyAndEndsMove() {
        let delta = SIMD2(0.1, -0.05)
        let moved = AnnotationHandles.dragged(Self.frame, part: .body, by: delta, keepAspect: false, behavior: .text, spaceAspect: 1)
        #expect(Self.close(moved.rect.x, 0.3) && Self.close(moved.rect.y, 0.25) && moved.rect.width == Self.frame.rect.width)
        // An arrow: the body takes both ends along; an end moves alone and the rect follows the ends.
        let arrow = AnnotationFrame(
            rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), from: NormalizedPoint(x: 0.2, y: 0.2), to: NormalizedPoint(x: 0.4, y: 0.4))
        let whole = AnnotationHandles.dragged(arrow, part: .body, by: delta, keepAspect: false, behavior: .arrow, spaceAspect: 1)
        #expect(Self.close(whole.from!.x, 0.3) && Self.close(whole.to!.y, 0.35) && Self.close(whole.rect.x, 0.3))
        let end = AnnotationHandles.dragged(arrow, part: .to, by: SIMD2(0.2, 0), keepAspect: false, behavior: .arrow, spaceAspect: 1)
        #expect(end.from == arrow.from && Self.close(end.to!.x, 0.6))
        #expect(Self.close(end.rect.x, 0.2) && Self.close(end.rect.width, 0.4))
        // A callout's point moves alone, and with the body.
        let callout = AnnotationFrame(rect: Self.frame.rect, target: NormalizedPoint(x: 0.5, y: 0.8), size: 0.05)
        let point = AnnotationHandles.dragged(callout, part: .target, by: SIMD2(0.1, 0.1), keepAspect: false, behavior: .callout, spaceAspect: 1)
        #expect(point.rect == callout.rect && Self.close(point.target!.x, 0.6) && Self.close(point.target!.y, 0.9))
        let both = AnnotationHandles.dragged(callout, part: .body, by: delta, keepAspect: false, behavior: .callout, spaceAspect: 1)
        #expect(Self.close(both.target!.x, 0.6) && Self.close(both.rect.x, 0.3))
        // A delta that is not a number changes nothing.
        #expect(AnnotationHandles.dragged(Self.frame, part: .body, by: SIMD2(.nan, 0), keepAspect: false, behavior: .text, spaceAspect: 1) == Self.frame)
    }

    @Test func snapsToTheCenterAndTheEdges() {
        let space = Self.space
        // A shape 4 pt (view) left of the centre line: x = 0.5 − 0.2 − 5/800 → its centre is 5 pt from the middle.
        let width = 0.2
        let shape = AnnotationFrame(rect: NormalizedRect(x: 0.5 - width / 2 - 5.0 / 800, y: 0.1, width: width, height: 0.2))
        let near = AnnotationHandles.snapped(shape, part: .body, space: space, tolerance: AnnotationHandles.snapDistance)
        #expect(Self.close(near.shape.rect.x + near.shape.rect.width / 2, 0.5))
        #expect(near.guides.x == 400)
        #expect(near.shape.rect.y == 0.1 && near.guides.y == nil)
        // 7 pt away: it stays.
        let far = AnnotationFrame(rect: NormalizedRect(x: 0.5 - width / 2 - 7.0 / 800, y: 0.1, width: width, height: 0.2))
        let kept = AnnotationHandles.snapped(far, part: .body, space: space, tolerance: AnnotationHandles.snapDistance)
        #expect(kept.shape == far && kept.guides.x == nil && kept.guides.y == nil)
        // The edge of the space: a corner drag snaps only the edges it moves.
        let edge = AnnotationFrame(rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.5 - 3.0 / 800, height: 0.2))
        let right = AnnotationHandles.snapped(edge, part: .corner(3), space: space, tolerance: 6)
        #expect(Self.close(right.shape.rect.x + right.shape.rect.width, 1) && Self.close(right.shape.rect.x, 0.5))
        #expect(right.guides.x == 800)
        // A point of an arrow snaps by itself.
        let arrow = AnnotationFrame(
            rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.5 + 4.0 / 800, y: 0.4))
        let snappedEnd = AnnotationHandles.snapped(arrow, part: .to, space: space, tolerance: 6)
        #expect(Self.close(snappedEnd.shape.to!.x, 0.5), "\(snappedEnd)")
        #expect(snappedEnd.shape.from == arrow.from)
        #expect(snappedEnd.guides.x == 400, "\(snappedEnd.guides)")
    }

    @Test func viewDeltaRoundTrips() {
        let space = Rect(x: 20, y: 10, width: 800, height: 450)
        let delta = AnnotationHandles.spaceDelta(SIMD2(80, -45), space: space)
        #expect(Self.close(delta.x, 0.1) && Self.close(delta.y, -0.1))
        #expect(Self.close(delta.x * space.width, 80) && Self.close(delta.y * space.height, -45))
        // A space with no extent gives no delta.
        #expect(AnnotationHandles.spaceDelta(SIMD2(5, 5), space: Rect(x: 0, y: 0, width: 0, height: 10)) == .zero)
    }
}
