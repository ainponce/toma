// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The device drawn around the screen (phase 2 design §6.7, `WindowFrame.device`), with the background, the shadow and
/// the window frame (§11, step 1). Empty in the base: milestone 2b gives it what it draws.
public struct DeviceFrameLayer: Equatable, Sendable {
    public init() {}
}

/// Where the screen goes inside a device frame (phase 2 design §6.7).
enum DeviceFrameGeometry {
    /// The screen (and the device around it, as the window) of `contentAspect` inside `padding` (a fraction of the output's
    /// width) of an output `outputSize` big, in `frame`; `nil` when the screen is placed as with no frame, always in the
    /// base, so a device draws as no frame until milestone 2b fills this (base plan decision 10).
    static func placement(contentAspect: Double?, padding: Double, outputSize: SIMD2<Double>, frame: DeviceFrame) -> ScreenPlacement? {
        nil
    }
}

/// The device frame of a document (`style.frame`) as the frames draw it, worked out once for the scene and again for each
/// size (`FrameEvaluator.init` and `resized(to:)`).
///
/// The base of phase 2 leaves it empty: no layer, so every document draws as in phase 1. Milestone 2b fills it here.
struct DeviceFrameScene: Sendable {
    init(document: EditDocument, outputSize: SIMD2<Int>) {}

    /// The device around `screen` (the frame's screen, `nil` without one); `nil` without a device, always in the base.
    func layer(around screen: ScreenLayer?) -> DeviceFrameLayer? {
        nil
    }
}
