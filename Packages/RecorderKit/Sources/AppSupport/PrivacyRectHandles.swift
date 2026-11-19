// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The rect of a privacy block over the preview (phase 2 design §7.1, plan 2c decision 5): where it is drawn, which part
/// of it the pointer is on, and what a drag makes of it. Pure: the overlay passes it the frame the render draws at the
/// playhead (`RenderFrame.drawnScreen`) and the pointer.
///
/// The rect is in fractions of the screen's content (the Area in Area mode, `ShownScreen.crop`); the layer draws its crop
/// (`ScreenLayer.crop`, which a reframe or a change of shape cuts) over its rect in output pixels, through the zoom, the
/// card and the reframe (`PrivacyGeometry.inLayerCrop`); the view shows the output scaled to its size. A drag is worked
/// out back the same way, so the rect follows the pointer 1:1 whatever the zoom. A dragged rect stays inside the content
/// and at least `PrivacyGeometry.minimumSide` of it on each side.
///
/// Its parts: the four corners (0 top left, 1 top right, 2 bottom left, 3 bottom right), the four edges (0 top, 1 right,
/// 2 bottom, 3 left) and the body.
public enum PrivacyRectHandles {
    public enum Part: Equatable, Sendable {
        case body
        case corner(Int)
        case edge(Int)
    }

    /// How large the place a handle is grabbed by is, in points: half of it around the corner or the edge, outward, and as
    /// much inward as a quarter of the rect leaves (so a small rect keeps a body to move it by).
    public static let hitSize = 10.0

    /// Where `rect` (fractions of the content `contentCrop`, itself in fractions of the frame) is in a view of `viewSize`
    /// points that shows an output of `outputSize` pixels, the screen's layer drawing `layerCrop` of the frame over
    /// `drawnScreen` (output pixels). Not clipped to the view: through a zoom, part of it may be outside.
    public static func viewRect(
        _ rect: NormalizedRect, drawnScreen: Rect, layerCrop: Rect, contentCrop: Rect, outputSize: SIMD2<Double>,
        viewSize: SIMD2<Double>
    ) -> Rect {
        let f = PrivacyGeometry.inLayerCrop(rect, contentCrop: contentCrop, layerCrop: layerCrop)
        let scale = viewSize / outputSize
        return Rect(
            x: (drawnScreen.x + f.x * drawnScreen.width) * scale.x, y: (drawnScreen.y + f.y * drawnScreen.height) * scale.y,
            width: f.width * drawnScreen.width * scale.x, height: f.height * drawnScreen.height * scale.y)
    }

    /// The part of `viewRect` at `point` (both in the view's points, y down), `nil` off it: a corner within `hitSize / 2`
    /// of both of its edges, then an edge, then the body.
    public static func part(at point: SIMD2<Double>, in viewRect: Rect) -> Part? {
        let outward = hitSize / 2
        let inX = min(outward, viewRect.width / 4), inY = min(outward, viewRect.height / 4)
        // How far inside each edge the point is (negative outside).
        let left = point.x - viewRect.x, right = viewRect.x + viewRect.width - point.x
        let top = point.y - viewRect.y, bottom = viewRect.y + viewRect.height - point.y
        guard [left, right, top, bottom].allSatisfy({ $0 >= -outward }) else { return nil }
        func near(_ a: Double, _ inward: Double) -> Bool { a <= inward }
        // The nearer of two edges both within reach (a thin rect).
        let horizontal: Int? = near(left, inX) && (!near(right, inX) || abs(left) <= abs(right)) ? 3 : near(right, inX) ? 1 : nil
        let vertical: Int? = near(top, inY) && (!near(bottom, inY) || abs(top) <= abs(bottom)) ? 0 : near(bottom, inY) ? 2 : nil
        switch (horizontal, vertical) {
        case let (h?, v?): return .corner((v == 0 ? 0 : 2) + (h == 3 ? 0 : 1))
        case let (h?, nil): return .edge(h)
        case let (nil, v?): return .edge(v)
        case (nil, nil): return .body
        }
    }

    /// `rect` after `part` is dragged by `contentDelta` (fractions of the content): the body moves it whole, kept inside the
    /// content; a corner or an edge moves only its own edges, each kept inside the content and at least
    /// `PrivacyGeometry.minimumSide` from the opposite one (it stops there, never flips). A delta that is not a number
    /// changes nothing.
    public static func dragged(_ rect: NormalizedRect, part: Part, by contentDelta: SIMD2<Double>) -> NormalizedRect {
        guard contentDelta.x.isFinite, contentDelta.y.isFinite else { return rect }
        let start = PrivacyGeometry.clamped(rect)
        let minimum = PrivacyGeometry.minimumSide
        let (dx, dy) = (contentDelta.x, contentDelta.y)
        var (left, top) = (start.x, start.y)
        var (right, bottom) = (start.x + start.width, start.y + start.height)
        let moves: (left: Bool, right: Bool, top: Bool, bottom: Bool)
        switch part {
        case .body:
            let x = min(max(start.x + dx, 0), 1 - start.width), y = min(max(start.y + dy, 0), 1 - start.height)
            return NormalizedRect(x: x, y: y, width: start.width, height: start.height)
        case let .corner(k):
            moves = (k == 0 || k == 2, k == 1 || k == 3, k == 0 || k == 1, k == 2 || k == 3)
        case let .edge(k):
            moves = (k == 3, k == 1, k == 0, k == 2)
        }
        if moves.left { left = min(max(left + dx, 0), right - minimum) }
        if moves.right { right = min(max(right + dx, left + minimum), 1) }
        if moves.top { top = min(max(top + dy, 0), bottom - minimum) }
        if moves.bottom { bottom = min(max(bottom + dy, top + minimum), 1) }
        return NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `viewDelta` (points of the view) in fractions of the content, back through what `viewRect` goes through. Zero when
    /// the screen, a crop or a size has no extent.
    public static func contentDelta(
        _ viewDelta: SIMD2<Double>, drawnScreen: Rect, layerCrop: Rect, contentCrop: Rect, outputSize: SIMD2<Double>,
        viewSize: SIMD2<Double>
    ) -> SIMD2<Double> {
        let delta = viewDelta * outputSize / viewSize / SIMD2(drawnScreen.width, drawnScreen.height)
            * SIMD2(layerCrop.width, layerCrop.height) / SIMD2(contentCrop.width, contentCrop.height)
        guard delta.x.isFinite, delta.y.isFinite else { return .zero }
        return delta
    }

    /// What a drag snaps by: the offset to add to it (view points), and the lines of the screen it snapped to, to draw.
    public struct Snap: Equatable, Sendable {
        public var offset: SIMD2<Double>
        public var guideX: Double?
        public var guideY: Double?

        public init(offset: SIMD2<Double>, guideX: Double?, guideY: Double?) {
            self.offset = offset
            self.guideX = guideX
            self.guideY = guideY
        }
    }

    /// How far `viewRect`, as a drag of `part` leaves it, snaps to the drawn screen `screen` (both in view points): the
    /// edges `part` moves (all three lines of the body: its edges and its centre) onto the screen's edges and centre, each
    /// way on its own, the nearest within `tolerance`.
    public static func snap(_ viewRect: Rect, part: Part, to screen: Rect, tolerance: Double) -> Snap {
        let moves: (left: Bool, right: Bool, top: Bool, bottom: Bool, centre: Bool)
        switch part {
        case .body: moves = (true, true, true, true, true)
        case let .corner(k): moves = (k == 0 || k == 2, k == 1 || k == 3, k == 0 || k == 1, k == 2 || k == 3, false)
        case let .edge(k): moves = (k == 3, k == 1, k == 0, k == 2, false)
        }
        func nearest(_ lines: [Double], _ targets: [Double]) -> (offset: Double, guide: Double)? {
            var best: (offset: Double, guide: Double)?
            for line in lines {
                for target in targets where abs(target - line) <= tolerance && abs(target - line) < abs(best?.offset ?? .infinity) {
                    best = (target - line, target)
                }
            }
            return best
        }
        let xs = [moves.left ? viewRect.x : nil, moves.centre ? viewRect.x + viewRect.width / 2 : nil,
                  moves.right ? viewRect.x + viewRect.width : nil].compactMap { $0 }
        let ys = [moves.top ? viewRect.y : nil, moves.centre ? viewRect.y + viewRect.height / 2 : nil,
                  moves.bottom ? viewRect.y + viewRect.height : nil].compactMap { $0 }
        let x = nearest(xs, [screen.x, screen.x + screen.width / 2, screen.x + screen.width])
        let y = nearest(ys, [screen.y, screen.y + screen.height / 2, screen.y + screen.height])
        return Snap(offset: SIMD2(x?.offset ?? 0, y?.offset ?? 0), guideX: x?.guide, guideY: y?.guide)
    }
}
