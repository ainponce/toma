// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// What a drag of an annotation edits (phase 3 plan 3a, decision 5): its box in fractions of its space, and the points an
/// arrow (`from`, `to`) or a speech bubble (`target`) has besides it; `size` is a text's or a bubble's, a fraction of the
/// height of the space. (Not `AnnotationShape`, which is the kind of a shape of `ProjectFormat`.)
public struct AnnotationFrame: Equatable, Sendable {
    public var rect: NormalizedRect
    public var from: NormalizedPoint?
    public var to: NormalizedPoint?
    public var target: NormalizedPoint?
    public var size: Double?

    public init(
        rect: NormalizedRect, from: NormalizedPoint? = nil, to: NormalizedPoint? = nil, target: NormalizedPoint? = nil,
        size: Double? = nil
    ) {
        self.rect = rect
        self.from = from
        self.to = to
        self.target = target
        self.size = size
    }
}

/// The handles of an annotation over the preview: which part of it a point is on, what a drag makes of it and where it
/// snaps (plan 3a, decisions 5 and 6). Pure, in the manner of `PrivacyRectHandles`. The box is in points of the view and
/// the space the annotation is measured in (the content of the shown screen, or the output frame) is a `Rect` of the view
/// too; a drag arrives as a `delta` in fractions of the space (`spaceDelta`), so it follows the pointer 1:1.
///
/// Parts: the four corners (0 top left, 1 top right, 2 bottom left, 3 bottom right), the four edges (0 top, 1 right,
/// 2 bottom, 3 left), the body, and an arrow's two ends and a bubble's point.
public enum AnnotationHandles {
    public enum Part: Hashable, Sendable {
        case body
        case corner(Int)
        case edge(Int)
        case from, to, target
    }

    /// Which handles an annotation has and how they edit it.
    public enum Behavior: Sendable {
        /// A text: the corners scale the width and the size together, the left and right sides the width (the height is the
        /// text's own).
        case text
        /// A shape, an image or a clip: the corners and all the sides, free; ⇧ keeps the proportion.
        case free
        /// An arrow: its two ends and its body.
        case arrow
        /// A step: the corners, and it stays a circle.
        case step
        /// A speech bubble: those of a text, and its point.
        case callout
    }

    /// How large the place a handle is grabbed by is, in points.
    public static let hitSize = 10.0
    /// How near, in points, a drag snaps to the centre and the edges of the space.
    public static let snapDistance = 6.0

    public static func behavior(of kind: AnnotationKind) -> Behavior {
        switch kind {
        case .text: .text
        case .arrow: .arrow
        case .callout: .callout
        case .step: .step
        case .shape, .image, .clip: .free
        }
    }

    /// The part of an annotation at `point` (points of the view, y down), `nil` off it. `box` is its rect in the view,
    /// turned `rotation` degrees clockwise about its centre (an arrow and a bubble ignore the rotation); `points` are where
    /// the arrow's ends or the bubble's point are drawn. The point goes back to the unrotated box before the search; a
    /// point of the annotation is grabbed within half of `hitSize` and wins over the box.
    public static func part(
        at point: SIMD2<Double>, box: Rect, rotation: Double, points: [Part: SIMD2<Double>], behavior: Behavior
    ) -> Part? {
        let points = points.filter { [.from, .to, .target].contains($0.key) }
        let allowed: Set<Part>
        switch behavior {
        case .arrow: allowed = [.from, .to]
        case .callout: allowed = [.target]
        default: allowed = []
        }
        var nearest: (part: Part, distance: Double)?
        for (part, p) in points where allowed.contains(part) {
            let distance = hypot(point.x - p.x, point.y - p.y)
            if distance <= hitSize / 2, distance < (nearest?.distance ?? .infinity) { nearest = (part, distance) }
        }
        if let nearest { return nearest.part }
        let turned = behavior == .arrow || behavior == .callout ? 0 : rotation
        let local = unrotated(point, about: box, degrees: turned)
        guard let found = PrivacyRectHandles.part(at: local, in: box) else { return nil }
        switch (behavior, found) {
        case (_, .body): return .body
        case (.arrow, _): return .body
        case let (.text, .edge(k)), let (.callout, .edge(k)): return k == 1 || k == 3 ? .edge(k) : .body
        case (.step, .edge): return .body
        case let (_, .corner(k)): return .corner(k)
        case let (_, .edge(k)): return .edge(k)
        }
    }

    /// `point` with the turn of `degrees` clockwise (y down) about the centre of `box` taken back.
    private static func unrotated(_ point: SIMD2<Double>, about box: Rect, degrees: Double) -> SIMD2<Double> {
        guard degrees != 0, degrees.isFinite else { return point }
        let center = SIMD2(box.x + box.width / 2, box.y + box.height / 2)
        let a = -degrees * .pi / 180
        let d = point - center
        return center + SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
    }

    /// `viewDelta` (points of the view) in fractions of `space`. Zero if the space has no area or the delta is not finite.
    public static func spaceDelta(_ viewDelta: SIMD2<Double>, space: Rect) -> SIMD2<Double> {
        guard space.width > 0, space.height > 0 else { return .zero }
        let delta = viewDelta / SIMD2(space.width, space.height)
        guard delta.x.isFinite, delta.y.isFinite else { return .zero }
        return delta
    }

    /// `shape` after `part` is dragged by `delta` (fractions of the space), in the manner of `behavior`: the body moves the
    /// rect and its points; an end or the point moves alone (an arrow's rect then wraps its ends, straight: the app works
    /// out the curve's with `AnnotationGeometry.arrowRect`); a corner or an edge moves only its own edges, never past
    /// `AnnotationGeometry.minimumSide` from the opposite ones. With `keepAspect` (⇧), and always for a step, the
    /// proportion in pixels (`spaceAspect`, the space's width over its height) stays: a corner by the larger of its two
    /// changes about the opposite corner, an edge by scaling the other side about its middle. The corners of a text and of
    /// a bubble scale the width and the size together by the same factor about the opposite corner (the delta's x decides),
    /// its sides change the width alone. Not clamped to where the anchor allows (`AnnotationGeometry.clamped`).
    public static func dragged(
        _ shape: AnnotationFrame, part: Part, by delta: SIMD2<Double>, keepAspect: Bool, behavior: Behavior, spaceAspect: Double
    ) -> AnnotationFrame {
        guard delta.x.isFinite, delta.y.isFinite else { return shape }
        var result = shape
        let minimum = AnnotationGeometry.minimumSide
        func moved(_ p: NormalizedPoint?) -> NormalizedPoint? { p.map { NormalizedPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
        switch part {
        case .body:
            result.rect.x += delta.x
            result.rect.y += delta.y
            result.from = moved(shape.from)
            result.to = moved(shape.to)
            result.target = moved(shape.target)
        case .from, .to:
            guard behavior == .arrow, let a = shape.from, let b = shape.to else { return shape }
            if part == .from { result.from = NormalizedPoint(x: a.x + delta.x, y: a.y + delta.y) }
            if part == .to { result.to = NormalizedPoint(x: b.x + delta.x, y: b.y + delta.y) }
            result.rect = wrapping(result.from!, result.to!)
        case .target:
            guard behavior == .callout, shape.target != nil else { return shape }
            result.target = moved(shape.target)
        case let .corner(k):
            guard behavior != .arrow else { return shape }
            let right = k == 1 || k == 3, bottom = k >= 2
            let rect = shape.rect
            if behavior == .text || behavior == .callout {
                let factor = max((rect.width + (right ? delta.x : -delta.x)) / rect.width, minimum / rect.width)
                guard factor.isFinite else { return shape }
                result.rect.width = rect.width * factor
                result.rect.height = rect.height * factor
                result.rect.x = right ? rect.x : rect.x + rect.width - result.rect.width
                result.rect.y = bottom ? rect.y : rect.y + rect.height - result.rect.height
                result.size = shape.size.map { $0 * factor }
                return result
            }
            let width = max(rect.width + (right ? delta.x : -delta.x), minimum)
            let height = max(rect.height + (bottom ? delta.y : -delta.y), minimum)
            var (newWidth, newHeight) = (width, height)
            if keepAspect || behavior == .step {
                // About the opposite corner, by the larger change; the proportion of pixels is that of the fractions.
                let factor = max(width / rect.width, height / rect.height, minimum / rect.width, minimum / rect.height)
                (newWidth, newHeight) = (rect.width * factor, rect.height * factor)
            }
            result.rect.width = newWidth
            result.rect.height = newHeight
            result.rect.x = right ? rect.x : rect.x + rect.width - newWidth
            result.rect.y = bottom ? rect.y : rect.y + rect.height - newHeight
        case let .edge(k):
            guard behavior != .arrow, behavior != .step else { return shape }
            let rect = shape.rect
            let horizontal = k == 1 || k == 3
            if (behavior == .text || behavior == .callout) && !horizontal { return shape }
            if horizontal {
                let width = max(rect.width + (k == 1 ? delta.x : -delta.x), minimum)
                result.rect.width = width
                result.rect.x = k == 1 ? rect.x : rect.x + rect.width - width
                if keepAspect && behavior == .free {
                    let height = max(rect.height * width / rect.width, minimum)
                    result.rect.height = height
                    result.rect.y = rect.y + (rect.height - height) / 2
                }
            } else {
                let height = max(rect.height + (k == 2 ? delta.y : -delta.y), minimum)
                result.rect.height = height
                result.rect.y = k == 2 ? rect.y : rect.y + rect.height - height
                if keepAspect {
                    let width = max(rect.width * height / rect.height, minimum)
                    result.rect.width = width
                    result.rect.x = rect.x + (rect.width - width) / 2
                }
            }
        }
        return result
    }

    /// The box around two points, at least the least side each way.
    private static func wrapping(_ a: NormalizedPoint, _ b: NormalizedPoint) -> NormalizedRect {
        let minimum = AnnotationGeometry.minimumSide
        var rect = NormalizedRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if rect.width < minimum {
            rect.x -= (minimum - rect.width) / 2
            rect.width = minimum
        }
        if rect.height < minimum {
            rect.y -= (minimum - rect.height) / 2
            rect.height = minimum
        }
        return rect
    }

    /// `shape` (fractions of `space`, which is a rect of the view) snapped, as `part` is dragged, to the centre and the
    /// edges of `space` within `tolerance` points: what the part moves only (the body, all its lines and its centre; an
    /// end or the point, itself). Each axis on its own. `guides` are the lines snapped to, in points of the view. The
    /// rotation is not considered: the box is the unrotated one. `behavior` is that of the drag, so a text's corner scales
    /// rather than stretches (an end or the point is always that of an arrow or a bubble).
    public static func snapped(
        _ shape: AnnotationFrame, part: Part, space: Rect, tolerance: Double, behavior: Behavior = .free
    ) -> (shape: AnnotationFrame, guides: (x: Double?, y: Double?)) {
        guard space.width > 0, space.height > 0 else { return (shape, (nil, nil)) }
        let box: Rect
        let privacyPart: PrivacyRectHandles.Part
        switch part {
        case .from, .to, .target:
            let point: NormalizedPoint?
            switch part {
            case .from: point = shape.from
            case .to: point = shape.to
            default: point = shape.target
            }
            guard let point else { return (shape, (nil, nil)) }
            let p = AnnotationGeometry.point(point, in: space)
            box = Rect(x: p.x, y: p.y, width: 0, height: 0)
            privacyPart = .body
        case .body:
            box = AnnotationGeometry.pixels(shape.rect, in: space)
            privacyPart = .body
        case let .corner(k):
            box = AnnotationGeometry.pixels(shape.rect, in: space)
            privacyPart = .corner(k)
        case let .edge(k):
            box = AnnotationGeometry.pixels(shape.rect, in: space)
            privacyPart = .edge(k)
        }
        let snap = PrivacyRectHandles.snap(box, part: privacyPart, to: space, tolerance: tolerance)
        guard snap.guideX != nil || snap.guideY != nil else { return (shape, (nil, nil)) }
        let offset = spaceDelta(snap.offset, space: space)
        let editing: Behavior
        switch part {
        case .from, .to: editing = .arrow
        case .target: editing = .callout
        default: editing = behavior
        }
        let result = dragged(shape, part: part, by: offset, keepAspect: false, behavior: editing, spaceAspect: space.width / space.height)
        return (result, (snap.guideX, snap.guideY))
    }
}
