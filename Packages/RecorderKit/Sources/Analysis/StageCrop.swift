// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the zoom camera's crop can be (design §7.4): the crop of depth `z` is the stage over `z`, centred on the
/// camera's centre, and it is placed ("acomodado") on each axis on its own:
///
/// - It never leaves the stage. A crop as large as the stage or larger (a depth of 1 or less) is centred on it.
/// - Where it fits in the screen's rect, it does not leave the screen either, so a zoom in never shows the background
///   of one side.
/// - Where it does not fit, it covers the whole screen on that axis. That is what keeps the camera from jumping as the
///   depth goes through the screen's size: at that depth the crop has exactly the screen's size and both rules give
///   the screen's centre, and the room the crop has grows from there on either side.
///
/// The stage wins over the screen (a screen out of the stage); the centre of the stage is its middle on each axis.
public enum StageCrop {
    /// `center` moved to where the crop of `depth` of a stage of `stage` (width and height) can be, with the screen at
    /// `screen` (in stage units; the stage itself where no screen is shown).
    public static func clamp(center: SIMD2<Double>, depth: Double, stage: SIMD2<Double>, screen: Rect) -> SIMD2<Double> {
        guard depth >= 1 else { return stage / 2 }
        let half = stage / depth / 2
        return SIMD2(
            axis(center.x, half: half.x, stage: stage.x, screen: screen.x, screen.x + screen.width),
            axis(center.y, half: half.y, stage: stage.y, screen: screen.y, screen.y + screen.height))
    }

    /// One axis of `clamp`: `c` with a crop of half size `half`, a stage of `stage` and a screen from `a` to `b`.
    private static func axis(_ c: Double, half: Double, stage: Double, screen a: Double, _ b: Double) -> Double {
        // Inside the screen where the crop fits in it (`a + half ≤ b − half`), around it where it does not.
        let onScreen = min(max(c, min(a + half, b - half)), max(a + half, b - half))
        guard 2 * half < stage else { return stage / 2 }
        return min(max(onScreen, half), stage - half)
    }
}
