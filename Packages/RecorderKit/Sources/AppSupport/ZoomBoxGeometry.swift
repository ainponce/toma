// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import ProjectFormat

/// The box of a fixed zoom over the preview (design §5.3): what is seen inside the zoom, drawn over the frame without
/// zoom. All in stage units (the stage is `stage` wide and tall, origin at its top left), the screen at `screen`. The
/// focus is in fractions of the screen, as `ZoomFocus.fixed` keeps it. The box has the format's proportion and is
/// placed as the zoom camera places its crop (`StageCrop`), so it never leaves the screen where it fits in it.
public enum ZoomBoxGeometry {
    /// The depths of a zoom: 1.25× to 4×.
    public static let depthRange = ZoomCommands.depthRange

    /// The crop of depth `depth` the camera shows for `focus`, placed.
    public static func box(focus: SIMD2<Double>, depth: Double, screen: Rect, stage: SIMD2<Double>) -> Rect {
        let depth = clamped(depth)
        let center = StageCrop.clamp(center: point(of: focus, in: screen), depth: depth, stage: stage, screen: screen)
        let size = stage / depth
        return Rect(x: center.x - size.x / 2, y: center.y - size.y / 2, width: size.x, height: size.y)
    }

    /// The focus (fractions of the screen, 0 to 1) of `box` dragged by `delta`: its centre moved and placed again, so the
    /// focus is where the box touches the screen's edge when it was dragged past it.
    public static func focus(afterDragging box: Rect, by delta: SIMD2<Double>, screen: Rect, stage: SIMD2<Double>) -> SIMD2<Double> {
        let depth = depth(of: box, stage: stage)
        let moved = SIMD2(box.x + box.width / 2 + delta.x, box.y + box.height / 2 + delta.y)
        let center = StageCrop.clamp(center: moved, depth: depth, stage: stage, screen: screen)
        return fractions(of: center, in: screen)
    }

    /// The depth of `box` with a corner dragged to `point`: the box keeps its centre and its proportion, and its corner
    /// goes as far from the centre as `point` is on the axis that asks for more; kept between 1.25× and 4×.
    public static func depth(afterDraggingCorner box: Rect, to point: SIMD2<Double>, screen: Rect, stage: SIMD2<Double>) -> Double {
        let center = SIMD2(box.x + box.width / 2, box.y + box.height / 2)
        let half = SIMD2(abs(point.x - center.x), abs(point.y - center.y))
        // The width of the box on each axis' rule: the proportion is the stage's.
        let width = 2 * max(half.x, half.y * stage.x / stage.y)
        guard width > 0 else { return depthRange.upperBound }
        return clamped(stage.x / width)
    }

    private static func depth(of box: Rect, stage: SIMD2<Double>) -> Double {
        box.width > 0 ? clamped(stage.x / box.width) : depthRange.upperBound
    }

    private static func clamped(_ depth: Double) -> Double {
        depth.isNaN ? depthRange.lowerBound : min(max(depth, depthRange.lowerBound), depthRange.upperBound)
    }

    private static func point(of focus: SIMD2<Double>, in screen: Rect) -> SIMD2<Double> {
        SIMD2(screen.x + unit(focus.x) * screen.width, screen.y + unit(focus.y) * screen.height)
    }

    private static func fractions(of point: SIMD2<Double>, in screen: Rect) -> SIMD2<Double> {
        SIMD2(
            screen.width > 0 ? unit((point.x - screen.x) / screen.width) : 0.5,
            screen.height > 0 ? unit((point.y - screen.y) / screen.height) : 0.5)
    }

    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0.5 : min(max(value, 0), 1)
    }
}
