// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// The small view of Manual framing in the Camera tab (phase 2 design §6.2, plan 2b decision 19): the camera's whole frame,
/// shown as it is drawn (flipped with the mirror), with the crop over it. Dragging moves the crop as it is seen; the scroll
/// wheel, a pinch or the bar change the zoom. Every value is kept as the document keeps it: the centre within 0 to 1, the
/// zoom within `CameraFraming.zoomRange`.
public enum CameraFramingDrag {
    /// How many points of a precise scroll a line of a wheel without them (one notch) counts as.
    public static let pointsPerLine = 8.0
    /// How much the zoom grows for a point scrolled up: 100 points, about ×1.65.
    static let zoomPerPoint = 0.005

    /// The centre after a drag of `drag` points (x to the right, y down) across a view of `viewSize` points that shows
    /// the whole frame, from the centre `start` of the framing whose crop is `crop` (`CameraFramingGeometry.crop`, in
    /// fractions of the frame, before the mirror) when the drag began: the crop moves as much of the frame as the drag
    /// is of the view, the way it is seen. Mirrored, the view shows the frame flipped, so a drag to the right moves the
    /// frame's centre to the left. It starts from the middle of the crop, which is the centre unless the crop was held
    /// inside the frame (a centre near an edge): what is seen moves at once. Within 0 to 1; `start` itself (each
    /// coordinate read as the middle when it is not a number) for a view without a size or a drag that is not a number.
    public static func center(
        from start: NormalizedPoint, drag: SIMD2<Double>, viewSize: SIMD2<Double>, crop: Rect, mirrored: Bool
    ) -> NormalizedPoint {
        let held = NormalizedPoint(x: unit(start.x), y: unit(start.y))
        guard viewSize.x > 0, viewSize.y > 0, viewSize.x.isFinite, viewSize.y.isFinite, drag.x.isFinite, drag.y.isFinite
        else { return held }
        let middle = SIMD2(crop.x + crop.width / 2, crop.y + crop.height / 2)
        let from = SIMD2(middle.x.isFinite ? middle.x : held.x, middle.y.isFinite ? middle.y : held.y)
        let moved = drag / viewSize
        return NormalizedPoint(x: unit(from.x + (mirrored ? -moved.x : moved.x)), y: unit(from.y + moved.y))
    }

    /// `crop` (fractions of the frame, before the mirror) as the view shows it: flipped across the frame when mirrored.
    public static func seenCrop(_ crop: Rect, mirrored: Bool) -> Rect {
        guard mirrored else { return crop }
        return Rect(x: 1 - crop.x - crop.width, y: crop.y, width: crop.width, height: crop.height)
    }

    /// The zoom after scrolling `scroll` points up (down when negative; `scrollPoints` for a wheel's lines): each point
    /// multiplies it by the same factor, so up and down undo each other. Within `CameraFraming.zoomRange`; a scroll that
    /// is not a number changes nothing.
    public static func zoom(_ zoom: Double, scroll: Double) -> Double {
        let from = CameraFramingGeometry.clampedZoom(zoom)
        guard scroll.isFinite else { return from }
        return CameraFramingGeometry.clampedZoom(from * exp(scroll * zoomPerPoint))
    }

    /// The zoom of a pinch: the zoom `start` when it began, times its magnification `scale` (1 is none). A scale that is
    /// not above 0, or not a number, leaves `start`.
    public static func zoom(_ start: Double, magnifiedBy scale: Double) -> Double {
        let from = CameraFramingGeometry.clampedZoom(start)
        guard scale > 0, scale.isFinite else { return from }
        return CameraFramingGeometry.clampedZoom(from * scale)
    }

    /// A scroll event's vertical delta as points: a trackpad's (`precise`) as it is, a wheel's lines by `pointsPerLine`.
    /// 0 when it is not a number.
    public static func scrollPoints(delta: Double, precise: Bool) -> Double {
        guard delta.isFinite else { return 0 }
        return precise ? delta : delta * pointsPerLine
    }

    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0.5 : min(max(value, 0), 1)
    }
}
