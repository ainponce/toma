// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import simd

/// Where an annotation is, in pixels of its space, and the shapes of its arrow, speech-bubble tail and step (phase 3 plan
/// 3a, decisions 2, 4 and 5). Pure; the render, the editor's handles and the hit test share it. Y goes down.
public enum AnnotationGeometry {
    /// The shortest side of an annotation's rect.
    public static let minimumSide = 0.01
    /// Where the rect of an annotation anchored to the take can be, on each axis, in fractions of the content.
    public static let contentRange: ClosedRange<Double> = -0.5...1.5
    /// The head of an arrow is this many widths long (and half as wide on each side); an open head's strokes lean ±28°.
    static let headLength = 4.5
    static let headHalfWidth = 2.25
    static let openHeadAngle = 28.0 * Double.pi / 180

    /// The space of an annotation anchored to the take: where the whole content of the shown screen would be drawn, in the
    /// stage's coordinates. `drawnRect` is where the layer draws what `layerCrop` shows (both crops in fractions of the
    /// screen's frame; `contentCrop` is the Area, or the whole frame), so the content is carried to the layer's crop
    /// (`PrivacyGeometry.inLayerCrop`) and then to `drawnRect`. `nil` if a crop or the rect has no area.
    public static func contentSpace(contentCrop: Rect, layerCrop: Rect, drawnRect: Rect) -> Rect? {
        guard contentCrop.width > 0, contentCrop.height > 0, layerCrop.width > 0, layerCrop.height > 0, drawnRect.width > 0,
            drawnRect.height > 0
        else { return nil }
        let inLayer = PrivacyGeometry.inLayerCrop(.unit, contentCrop: contentCrop, layerCrop: layerCrop)
        return Rect(
            x: drawnRect.x + inLayer.x * drawnRect.width, y: drawnRect.y + inLayer.y * drawnRect.height,
            width: inLayer.width * drawnRect.width, height: inLayer.height * drawnRect.height)
    }

    /// The space of an annotation of the output or of the whole video: the output frame, in pixels.
    public static func outputSpace(outputSize: SIMD2<Double>) -> Rect {
        Rect(x: 0, y: 0, width: outputSize.x, height: outputSize.y)
    }

    /// `rect`, in fractions of `space`, in the space's own units.
    public static func pixels(_ rect: NormalizedRect, in space: Rect) -> Rect {
        Rect(
            x: space.x + rect.x * space.width, y: space.y + rect.y * space.height, width: rect.width * space.width,
            height: rect.height * space.height)
    }

    public static func point(_ p: NormalizedPoint, in space: Rect) -> SIMD2<Double> {
        SIMD2(space.x + p.x * space.width, space.y + p.y * space.height)
    }

    /// The inverse of `pixels(_:in:)`; a space with no area gives a rect of size 0 at the origin.
    public static func normalized(_ rect: Rect, in space: Rect) -> NormalizedRect {
        guard space.width > 0, space.height > 0 else { return NormalizedRect(x: 0, y: 0, width: 0, height: 0) }
        return NormalizedRect(
            x: (rect.x - space.x) / space.width, y: (rect.y - space.y) / space.height, width: rect.width / space.width,
            height: rect.height / space.height)
    }

    /// `rect` held where its anchor lets it be: anchored to the take, inside −0.5…1.5 on each axis; anchored to the output
    /// or the whole video, with its centre inside 0…1. Either way at least `minimumSide` wide and high. Numbers that are not
    /// finite are taken as 0.
    public static func clamped(_ rect: NormalizedRect, anchor: AnnotationAnchor) -> NormalizedRect {
        func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
        switch anchor {
        case .content:
            let span = contentRange.upperBound - contentRange.lowerBound
            let width = min(max(finite(rect.width), minimumSide), span)
            let height = min(max(finite(rect.height), minimumSide), span)
            return NormalizedRect(
                x: min(max(finite(rect.x), contentRange.lowerBound), contentRange.upperBound - width),
                y: min(max(finite(rect.y), contentRange.lowerBound), contentRange.upperBound - height), width: width, height: height)
        case .output, .whole:
            let width = max(finite(rect.width), minimumSide)
            let height = max(finite(rect.height), minimumSide)
            let centerX = min(max(finite(rect.x) + width / 2, 0), 1)
            let centerY = min(max(finite(rect.y) + height / 2, 0), 1)
            return NormalizedRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        }
    }

    /// An arrow in the pixels of its space: a quadratic Bézier from `start` to `end` with `control`, the shaft ending at
    /// `shaftEnd` where the head starts, and the head's points.
    public struct ArrowPath: Equatable, Sendable {
        public var start, control, end, shaftEnd: SIMD2<Double>
        /// A filled head: the tip, then the two corners of its base. An open head: the end of one stroke, the tip, the end of
        /// the other. No head: empty.
        public var head: [SIMD2<Double>]

        public init(start: SIMD2<Double>, control: SIMD2<Double>, end: SIMD2<Double>, shaftEnd: SIMD2<Double>, head: [SIMD2<Double>]) {
            self.start = start
            self.control = control
            self.end = end
            self.shaftEnd = shaftEnd
            self.head = head
        }
    }

    /// The arrow in `space`: the control point is the middle of the ends moved `curve × 0.5 × length` along the normal to
    /// the left of the way from `start` to `end` (curve in −1…1; y down, so the left of a rightward arrow is up); the head
    /// is 4.5 w long and 2.25 w to each side (a filled one) or two strokes of 4.5 w at ±28° (an open one), where `w` is the
    /// arrow's width, a fraction of the space's height; the head follows the curve's direction at `end`.
    public static func arrow(_ arrow: ArrowAnnotation, in space: Rect) -> ArrowPath {
        let start = point(arrow.from, in: space)
        let end = point(arrow.to, in: space)
        let delta = end - start
        let length = simd_length(delta)
        let curve = arrow.curve.isFinite ? min(max(arrow.curve, -1), 1) : 0
        var control = (start + end) / 2
        if length > 0 {
            // The left of the way, with y down: (dy, −dx).
            control += SIMD2(delta.y, -delta.x) / length * (curve * 0.5 * length)
        }
        var tangent = end - control
        if simd_length(tangent) < 1e-9 { tangent = delta }
        let direction = simd_length(tangent) < 1e-9 ? SIMD2(1.0, 0) : simd_normalize(tangent)
        let side = SIMD2(-direction.y, direction.x)
        let w = max(arrow.width, 0) * space.height
        let size = headLength * w
        switch arrow.head {
        case .none:
            return ArrowPath(start: start, control: control, end: end, shaftEnd: end, head: [])
        case .filled:
            let base = end - direction * size
            let half = headHalfWidth * w
            return ArrowPath(start: start, control: control, end: end, shaftEnd: base, head: [end, base + side * half, base - side * half])
        case .open:
            func stroke(_ sign: Double) -> SIMD2<Double> {
                let a = openHeadAngle * sign
                let back = -direction
                let rotated = SIMD2(cos(a) * back.x - sin(a) * back.y, sin(a) * back.x + cos(a) * back.y)
                return end + rotated * size
            }
            return ArrowPath(start: start, control: control, end: end, shaftEnd: end, head: [stroke(1), end, stroke(-1)])
        }
    }

    /// The rect of an arrow in fractions of its space: the box around `from`, `to` and the extremes of the curve (in a space
    /// of `aspect`, its width over its height, so the bend is the pixels' one), at least `minimumSide` each way. Not the head
    /// or the stroke's width.
    public static func arrowRect(_ arrow: ArrowAnnotation, aspect: Double = 1) -> NormalizedRect {
        let a = aspect.isFinite && aspect > 0 ? aspect : 1
        let start = SIMD2(arrow.from.x * a, arrow.from.y)
        let end = SIMD2(arrow.to.x * a, arrow.to.y)
        let delta = end - start
        let length = simd_length(delta)
        let curve = arrow.curve.isFinite ? min(max(arrow.curve, -1), 1) : 0
        var control = (start + end) / 2
        if length > 0 { control += SIMD2(delta.y, -delta.x) / length * (curve * 0.5 * length) }
        var low = simd_min(start, end)
        var high = simd_max(start, end)
        for axis in 0..<2 {
            let denominator = start[axis] - 2 * control[axis] + end[axis]
            guard abs(denominator) > 1e-12 else { continue }
            let u = (start[axis] - control[axis]) / denominator
            guard u > 0, u < 1 else { continue }
            let v = (1 - u) * (1 - u) * start[axis] + 2 * (1 - u) * u * control[axis] + u * u * end[axis]
            low[axis] = min(low[axis], v)
            high[axis] = max(high[axis], v)
        }
        var rect = NormalizedRect(x: low.x / a, y: low.y, width: (high.x - low.x) / a, height: high.y - low.y)
        if rect.width < minimumSide {
            rect.x -= (minimumSide - rect.width) / 2
            rect.width = minimumSide
        }
        if rect.height < minimumSide {
            rect.y -= (minimumSide - rect.height) / 2
            rect.height = minimumSide
        }
        return rect
    }

    /// The tail of a speech bubble: the two ends of its base on the bubble's edge and its tip.
    public struct CalloutTail: Equatable, Sendable {
        public var baseStart, baseEnd, tip: SIMD2<Double>

        public init(baseStart: SIMD2<Double>, baseEnd: SIMD2<Double>, tip: SIMD2<Double>) {
            self.baseStart = baseStart
            self.baseEnd = baseEnd
            self.tip = tip
        }
    }

    /// The tail of `bubble` (rounded by `cornerRadius`, text of size `em`, all in pixels) pointing at `target`: its base on
    /// the edge nearest to the point, `min(1.2 em, 0.3 ×` that edge`)` wide and moved along the edge towards the point but
    /// kept clear of the corners; its tip at the point. `nil` when the point is inside the bubble.
    public static func calloutTail(bubble: Rect, cornerRadius: Double, target: SIMD2<Double>, em: Double) -> CalloutTail? {
        let (minX, maxX, minY, maxY) = (bubble.x, bubble.x + bubble.width, bubble.y, bubble.y + bubble.height)
        let left = minX - target.x
        let right = target.x - maxX
        let above = minY - target.y
        let below = target.y - maxY
        let farthest = max(left, right, above, below)
        guard farthest > 0 else { return nil }
        let radius = max(cornerRadius, 0)
        func along(_ low: Double, _ high: Double, _ p: Double) -> (Double, Double) {
            let edge = high - low
            let base = min(1.2 * em, 0.3 * edge)
            let lowest = low + radius + base / 2
            let highest = high - radius - base / 2
            let center = lowest <= highest ? min(max(p, lowest), highest) : (low + high) / 2
            return (center - base / 2, center + base / 2)
        }
        if farthest == below || farthest == above {
            let y = farthest == below ? maxY : minY
            let (a, b) = along(minX, maxX, target.x)
            return CalloutTail(baseStart: SIMD2(a, y), baseEnd: SIMD2(b, y), tip: target)
        }
        let x = farthest == right ? maxX : minX
        let (a, b) = along(minY, maxY, target.y)
        return CalloutTail(baseStart: SIMD2(x, a), baseEnd: SIMD2(x, b), tip: target)
    }

    /// The circle of a step: centred in `rect`, as wide as its shorter side.
    public static func stepCircle(in rect: Rect) -> (center: SIMD2<Double>, radius: Double) {
        (SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2), min(rect.width, rect.height) / 2)
    }

    /// The corner radius of a rounded rectangle shape: 0.18 of its shorter side.
    public static func roundedCorner(of rect: Rect) -> Double {
        0.18 * min(rect.width, rect.height)
    }
}
