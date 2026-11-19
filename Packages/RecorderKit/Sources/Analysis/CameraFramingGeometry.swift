// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The part of the camera's frame its framing shows (phase 2 design §6.2, plan 2b decision 2): one rule for the render
/// (`Compositor.cameraFill`) and the small view of the Camera tab. The crop depends on the frame's proportion, which only
/// the camera's picture knows, so whoever has the picture asks for it.
public enum CameraFramingGeometry {
    /// The part of a frame of `frameSize` (pixels) that a shape of `rectAspect` (its width over its height) shows, in
    /// fractions of the frame (y going down): the part that fills the shape without stretching (all of the frame along
    /// the axis where the frame is narrower than the shape, as `Compositor.aspectFill`), divided by `zoom` (read by
    /// `clampedZoom`), centred at `center` (fractions of the frame; the middle on an axis that is not a number) and moved
    /// to stay inside the frame. A frame or a shape without a size, or not a number, fills with the whole frame.
    ///
    /// Centred at 1×, it is `Compositor.aspectFill`'s part, with the same numbers: the camera of phase 1.
    public static func crop(frameSize: SIMD2<Double>, rectAspect: Double, center: SIMD2<Double>, zoom: Double) -> Rect {
        var fill = SIMD2<Double>(1, 1)
        if frameSize.x > 0, frameSize.y > 0, frameSize.x.isFinite, frameSize.y.isFinite, rectAspect > 0, rectAspect.isFinite {
            let imageAspect = frameSize.x / frameSize.y
            if imageAspect > rectAspect {
                fill.x = rectAspect / imageAspect
            } else {
                fill.y = imageAspect / rectAspect
            }
        }
        let size = fill / clampedZoom(zoom)
        var origin = SIMD2<Double>.zero
        for axis in 0..<2 {
            let middle = center[axis].isFinite ? center[axis] : 0.5
            // Within 0…1 − size: the size is never above 1, so the crop's far edge is never past the frame's.
            origin[axis] = min(max(middle - size[axis] / 2, 0), 1 - size[axis])
        }
        return Rect(x: origin.x, y: origin.y, width: size.x, height: size.y)
    }

    /// `zoom` as the framing reads it: in `CameraFraming.zoomRange` (1 to 2.5), 1 when it is not a number.
    public static func clampedZoom(_ zoom: Double) -> Double {
        guard !zoom.isNaN else { return CameraFraming.zoomRange.lowerBound }
        return min(max(zoom, CameraFraming.zoomRange.lowerBound), CameraFraming.zoomRange.upperBound)
    }
}
