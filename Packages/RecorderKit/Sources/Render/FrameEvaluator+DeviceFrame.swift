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
    /// The shadow the MacBook's base casts, the style's under its own rect (the lid casts the frame's): `nil` without a
    /// base or a shadow.
    public var baseShadow: ShadowLayer?

    public init(
        rects: DeviceRects, model: DeviceModel, band: SIMD4<Float>, bezel: SIMD4<Float>, base: SIMD4<Float>, opacity: Double,
        baseShadow: ShadowLayer? = nil
    ) {
        self.rects = rects
        self.model = model
        self.band = band
        self.bezel = bezel
        self.base = base
        self.opacity = opacity
        self.baseShadow = baseShadow
    }
}

/// Where the screen goes inside a device frame (phase 2 design §6.7, `deviceFrame-1`), and the device's colours.
enum DeviceFrameGeometry {
    /// The screen (and the device's bounds around it, as the window) of `contentAspect` inside `padding` (a fraction of the
    /// output's width) of an output `outputSize` big, in `frame` (`StageLayout.deviceRects(contentAspect:…)`): an empty
    /// rect at the centre when the padding leaves no room, as for a window.
    static func placement(contentAspect: Double?, padding: Double, outputSize: SIMD2<Double>, frame: DeviceFrame) -> ScreenPlacement {
        guard let rects = StageLayout.deviceRects(
            contentAspect: contentAspect, padding: padding, outputSize: outputSize, model: frame.model)
        else {
            let empty = Rect(x: outputSize.x / 2, y: outputSize.y / 2, width: 0, height: 0)
            return ScreenPlacement(screen: empty, window: empty, barHeight: 0)
        }
        return ScreenPlacement(screen: rects.screen, window: rects.bounds, barHeight: 0)
    }

    /// What the device of `frame` takes around a screen at `screen`: the union of its body, buttons and base.
    static func bounds(around screen: Rect, frame: DeviceFrame) -> Rect {
        StageLayout.deviceRects(around: screen, model: frame.model).bounds
    }

    /// The colours of `frame` (`DeviceFrameLayer`), opaque sRGB: the iPhone's and the iPad's band #2C2C2E (dark) or #D9D9DE
    /// (light) around a black bezel; the MacBook's lid and base #2E2F33 or #D7D8DC, its bezel #0A0A0A.
    static func colors(_ frame: DeviceFrame) -> (band: SIMD4<Float>, bezel: SIMD4<Float>, base: SIMD4<Float>) {
        let dark = frame.finish == .dark
        switch frame.model {
        case .iPhone, .iPad:
            let band = rgb(dark ? 0x2C2C2E : 0xD9D9DE)
            return (band, rgb(0x000000), band)
        case .macBook:
            let lid = rgb(dark ? 0x2E2F33 : 0xD7D8DC)
            return (lid, rgb(0x0A0A0A), lid)
        }
    }

    /// An opaque colour of `hex` (`0xRRGGBB`), sRGB-encoded as the output stores it.
    private static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }
}

/// The device frame of a document (`style.frame`) as the frames draw it, worked out once for the scene and again for each
/// size (`FrameEvaluator.init` and `resized(to:)`): a device around the screen fitted whole (`style.reframe` `fit`; one
/// that follows the cursor is cut, and has no frame, phase 2 design §6.5).
struct DeviceFrameScene: Sendable {
    /// `nil` without a device drawn.
    private let device: DeviceFrame?
    private let colors: (band: SIMD4<Float>, bezel: SIMD4<Float>, base: SIMD4<Float>)

    init(document: EditDocument, outputSize: SIMD2<Int>) {
        if case let .device(device) = document.style.frame, document.style.reframe == .fit {
            self.device = device
            colors = DeviceFrameGeometry.colors(device)
        } else {
            device = nil
            colors = (.zero, .zero, .zero)
        }
    }

    /// What the device takes around a screen at `screen`, which the zoom keeps to and a card holds whole; `nil` without a
    /// device.
    func bounds(around screen: Rect) -> Rect? {
        device.map { DeviceFrameGeometry.bounds(around: screen, frame: $0) }
    }

    /// Puts the device around `frame`'s screen (`RenderFrame.deviceFrame`), as either path left the frame: the device's
    /// screen's corners on the screen and on the one being left (and on a card's cut, as the background's transform draws
    /// it), and the style's shadow cast by its body (the MacBook's lid; its base casts the same one, `baseShadow`), at the
    /// opacity of the screen's group. Nothing without a device or a screen.
    func apply(to frame: inout RenderFrame) {
        guard let device, let screen = frame.screen else { return }
        let rects = StageLayout.deviceRects(around: screen.rect, model: device.model)
        frame.screen?.cornerRadius = rects.screenCornerRadius
        frame.previousScreen?.cornerRadius = rects.screenCornerRadius
        if var card = frame.card {
            card.cornerRadius = rects.screenCornerRadius * (frame.backgroundTransform?.depth ?? 1)
            frame.card = card
        }
        var baseShadow: ShadowLayer?
        if var shadow = frame.shadow {
            if let base = rects.base {
                baseShadow = ShadowLayer(
                    rect: base, cornerRadius: rects.baseFrontRadius, opacity: shadow.opacity, sigma: shadow.sigma,
                    offsetY: shadow.offsetY)
            }
            shadow.rect = rects.body
            shadow.cornerRadius = rects.bodyCornerRadius
            frame.shadow = shadow
        }
        let opacity = frame.screenOpacity.map { $0.isNaN ? 0 : min(max($0, 0), 1) } ?? 1
        frame.deviceFrame = DeviceFrameLayer(
            rects: rects, model: device.model, band: colors.band, bezel: colors.bezel, base: colors.base, opacity: opacity,
            baseShadow: baseShadow)
    }
}

extension StageTransform {
    /// `layer` as it is drawn in an output of `outputSize` through the transform: every rect moved, every length scaled.
    func drawn(_ layer: DeviceFrameLayer, outputSize: SIMD2<Int>) -> DeviceFrameLayer {
        func rect(_ r: Rect) -> Rect { outputRect(ofStage: r, outputSize: outputSize) }
        var result = layer
        let rects = layer.rects
        result.rects = DeviceRects(
            screen: rect(rects.screen), screenCornerRadius: rects.screenCornerRadius * depth, body: rect(rects.body),
            bodyCornerRadius: rects.bodyCornerRadius * depth, bandWidth: rects.bandWidth * depth, cutout: rects.cutout.map(rect),
            buttons: rects.buttons.map(rect), base: rects.base.map(rect), baseFrontRadius: rects.baseFrontRadius * depth,
            bounds: rect(rects.bounds))
        result.baseShadow = layer.baseShadow.map { drawn($0, outputSize: outputSize) }
        return result
    }
}
