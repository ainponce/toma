// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The device drawn around the screen (phase 2 design §6.7, `WindowFrame.device`), with the background, the shadow and
/// the window frame (§11, step 1): its body before the screen, and its island or notch over the stage (plan 2b decision
/// 10). In the stage's coordinates, like the screen.
public struct DeviceFrameLayer: Equatable, Sendable {
    /// Where its parts go.
    public var rects: DeviceRects
    public var model: DeviceModel
    /// sRGB from 0 to 1, not premultiplied: the band (the MacBook's lid), the bezel and the MacBook's base.
    public var band: SIMD4<Float>
    public var bezel: SIMD4<Float>
    public var base: SIMD4<Float>
    /// 0 to 1: the screen's group's (`RenderFrame.screenOpacity`), 1 on 1b's path.
    public var opacity: Double

    public init(rects: DeviceRects, model: DeviceModel, band: SIMD4<Float>, bezel: SIMD4<Float>, base: SIMD4<Float>, opacity: Double) {
        self.rects = rects
        self.model = model
        self.band = band
        self.bezel = bezel
        self.base = base
        self.opacity = opacity
    }
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
/// Milestone 2b's seam leaves it empty: no layer, so every document draws as in phase 1. Task I3 fills it here.
struct DeviceFrameScene: Sendable {
    init(document: EditDocument, outputSize: SIMD2<Int>) {}

    /// Puts the device around `frame`'s screen (`RenderFrame.deviceFrame`), as either path left the frame: the device's
    /// corners on the screen and on the one being left, and the style's shadow cast by its body. Nothing without a device,
    /// always in the seam.
    func apply(to frame: inout RenderFrame) {}
}
