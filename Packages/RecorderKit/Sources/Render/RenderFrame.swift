// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Everything one output frame shows, worked out from the project and the time alone. Positions are in
/// output pixels with the origin at the top left.
public struct RenderFrame: Equatable, Sendable {
    public var outputSize: SIMD2<Int>
    /// `gradientStart`, `gradientEnd` and `gradientAngleDegrees`: the gradient that a `.gradient` `background` draws.
    public var gradientStart: SIMD4<Float>
    public var gradientEnd: SIMD4<Float>
    public var gradientAngleDegrees: Float
    /// `nil` when the take has no screen track, and when its area cannot be shown: no part of it is on the display, or
    /// it cannot be placed (a `captureArea` with a size that is not usable, or a display without a usable
    /// `globalFrame`).
    public var screen: ScreenLayer?
    /// `nil` when the cursor's position is unknown or off what is shown of the screen. In stage coordinates: output
    /// pixels with the stage unzoomed. While it is hidden (`opacity` 0) nothing is drawn of it.
    public var cursor: CursorLayer?
    /// `nil` when the take has no camera, and before its first frame.
    public var camera: CameraLayer?
    /// What is drawn behind everything: the gradient above (today's), a colour, a wallpaper or an image (with the
    /// gradient above, Toma classic, when it cannot be read).
    public var background: BackgroundLayer
    /// The macOS window around the screen, its bar above `screen`'s rect; `nil` without a frame, and when no screen is
    /// shown.
    public var windowFrame: WindowFrameLayer?
    /// The click effects shown (`ClickEffects`), in click order: in stage coordinates like the cursor, drawn over it
    /// and never blurred. None without an effect.
    public var clickEffects: [ClickEffectLayer]
    /// The shadow under `screen`, or under the whole window with `windowFrame`; `nil` without a shadow (`style.shadow`
    /// 0) and when no screen is shown.
    public var shadow: ShadowLayer?
    /// The zoom camera at the frame's time (design §7.4): how the stage is drawn without `subframes`, and how the click
    /// effects always are. `nil`, like an identity, draws the stage as it is, as without a zoom.
    public var stage: StageTransform?
    /// The motion blur of the zoom camera (design §7.2 and §7.4): with any, the stage is drawn once for each, through its
    /// transform and with its cursor instead of `stage` and `cursor`, and they are averaged in their order before the
    /// click effects and the camera are drawn. Empty: the stage drawn once, directly into the target, as without a blur.
    public var subframes: [StageSubframe]
    /// The motion blur of the cursor with the zoom camera still (design §7.5): without `subframes`, with any, the stage is
    /// drawn once through `stage` and these cursors, averaged, over it instead of `cursor`. In stage coordinates, like
    /// `cursor`, each with its own position, opacity and press and the image of `cursor`.
    public var cursorSamples: [CursorLayer]

    public init(
        outputSize: SIMD2<Int>,
        gradientStart: SIMD4<Float>,
        gradientEnd: SIMD4<Float>,
        gradientAngleDegrees: Float,
        screen: ScreenLayer? = nil,
        cursor: CursorLayer? = nil,
        camera: CameraLayer? = nil,
        background: BackgroundLayer = .gradient,
        windowFrame: WindowFrameLayer? = nil,
        clickEffects: [ClickEffectLayer] = [],
        shadow: ShadowLayer? = nil,
        stage: StageTransform? = nil,
        subframes: [StageSubframe] = [],
        cursorSamples: [CursorLayer] = []
    ) {
        self.outputSize = outputSize
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientAngleDegrees = gradientAngleDegrees
        self.screen = screen
        self.cursor = cursor
        self.camera = camera
        self.background = background
        self.windowFrame = windowFrame
        self.clickEffects = clickEffects
        self.shadow = shadow
        self.stage = stage
        self.subframes = subframes
        self.cursorSamples = cursorSamples
    }
}

/// The zoom camera's transform of the stage (design §7.4): a point `p` of the stage, in its coordinates (output pixels
/// with the stage unzoomed), is drawn at `(p − center) × depth + (W, H) / 2` of an output `W × H` big.
public struct StageTransform: Equatable, Sendable {
    /// `z`: 1 at rest, larger zoomed in.
    public var depth: Double
    /// The centre of the crop shown, in stage coordinates: the stage's at rest.
    public var center: SIMD2<Double>

    public init(depth: Double, center: SIMD2<Double>) {
        self.depth = depth
        self.center = center
    }

    /// At rest: depth 1, centred on an output of `outputSize`.
    public static func identity(outputSize: SIMD2<Int>) -> StageTransform {
        StageTransform(depth: 1, center: SIMD2<Double>(outputSize) / 2)
    }

    /// Where stage point `p` is drawn in an output of `outputSize`.
    public func outputPoint(ofStage p: SIMD2<Double>, outputSize: SIMD2<Int>) -> SIMD2<Double> {
        (p - center) * depth + SIMD2<Double>(outputSize) / 2
    }

    /// `rect` of the stage as it is drawn in an output of `outputSize`.
    func outputRect(ofStage rect: Rect, outputSize: SIMD2<Int>) -> Rect {
        let origin = outputPoint(ofStage: SIMD2(rect.x, rect.y), outputSize: outputSize)
        return Rect(x: origin.x, y: origin.y, width: rect.width * depth, height: rect.height * depth)
    }
}

extension StageTransform {
    // The stage's layers as they are drawn in an output of `outputSize` through the transform: every position moved and
    // every length scaled by `depth`, so the whole stage is zoomed, edges and all.

    func drawn(_ layer: ScreenLayer, outputSize: SIMD2<Int>) -> ScreenLayer {
        var drawn = layer
        drawn.rect = outputRect(ofStage: layer.rect, outputSize: outputSize)
        drawn.cornerRadius = layer.cornerRadius * depth
        return drawn
    }

    func drawn(_ layer: ShadowLayer, outputSize: SIMD2<Int>) -> ShadowLayer {
        ShadowLayer(
            rect: outputRect(ofStage: layer.rect, outputSize: outputSize), cornerRadius: layer.cornerRadius * depth,
            opacity: layer.opacity, sigma: layer.sigma * depth, offsetY: layer.offsetY * depth)
    }

    func drawn(_ layer: WindowFrameLayer, outputSize: SIMD2<Int>) -> WindowFrameLayer {
        var drawn = layer
        drawn.rect = outputRect(ofStage: layer.rect, outputSize: outputSize)
        drawn.barHeight = layer.barHeight * depth
        drawn.cornerRadius = layer.cornerRadius * depth
        drawn.bottomCornerRadius = layer.bottomCornerRadius * depth
        drawn.screenTopCornerRadius = layer.screenTopCornerRadius * depth
        return drawn
    }

    func drawn(_ layer: CursorLayer, outputSize: SIMD2<Int>) -> CursorLayer {
        var drawn = layer
        drawn.hotspot = outputPoint(ofStage: layer.hotspot, outputSize: outputSize)
        drawn.height = layer.height * depth
        return drawn
    }

    func drawn(_ layer: ClickEffectLayer, outputSize: SIMD2<Int>) -> ClickEffectLayer {
        var drawn = layer
        drawn.center = outputPoint(ofStage: layer.center, outputSize: outputSize)
        drawn.radius = layer.radius * depth
        drawn.thickness = layer.thickness * depth
        return drawn
    }
}

/// One subsample of the zoom camera's motion blur: the stage through `stage`, with `cursor` (none: no cursor in it).
public struct StageSubframe: Equatable, Sendable {
    public var stage: StageTransform
    /// In stage coordinates, like `RenderFrame.cursor`.
    public var cursor: CursorLayer?

    public init(stage: StageTransform, cursor: CursorLayer? = nil) {
        self.stage = stage
        self.cursor = cursor
    }
}

/// The recorded screen: the `crop` of the frame of track `trackID` shown at host time `sourceTime`, drawn into
/// `rect`. Inside a window frame (`RenderFrame.windowFrame`), the window's rounded rect cuts it, square along its top
/// edge, under the bar (but for a recorded window's, `WindowFrameLayer.screenTopCornerRadius`).
public struct ScreenLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels: inside a window frame, the window's bottom ones.
    public var cornerRadius: Double
    /// The part of the frame shown, as fractions of it (0, 0 is its top-left corner, 1, 1 the bottom-right one):
    /// the area recorded in Area mode, the whole frame otherwise.
    public var crop: Rect
    /// Sampled trilinear from mipmaps made of each frame (`ScreenSampling.mipmapped`), which does not alias the frame
    /// drawn much smaller than recorded; bilinear, as in phase 0 and 1a, otherwise.
    public var mipmapped: Bool

    public init(
        trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double, crop: Rect = Rect(x: 0, y: 0, width: 1, height: 1),
        mipmapped: Bool = false
    ) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.crop = crop
        self.mipmapped = mipmapped
    }
}

/// The shadow under the screen or its window (design §7.3): a black box, `rect` moved down by `offsetY` with corners of
/// `cornerRadius`, blurred by a Gaussian of σ `sigma`, at `opacity` (its alpha, premultiplied black). Its shape is the
/// analytic one of `ShadowMath`, drawn in one pass without textures. Nothing is drawn of one at opacity 0, of no size
/// or without a blur.
public struct ShadowLayer: Equatable, Sendable {
    /// What casts it: the screen's rect, or the whole window's. In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels.
    public var cornerRadius: Double
    /// 0 to 1.
    public var opacity: Double
    /// In output pixels.
    public var sigma: Double
    /// How far down the shadow is from `rect`, in output pixels.
    public var offsetY: Double

    public init(rect: Rect, cornerRadius: Double, opacity: Double, sigma: Double, offsetY: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.sigma = sigma
        self.offsetY = offsetY
    }
}

/// The camera: the frame of track `trackID` shown at host time `sourceTime`, filling `rect` (cropped to its shape,
/// centred) with corners of `cornerRadius`.
public struct CameraLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels: half the side for a circle.
    public var cornerRadius: Double

    public init(trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// The image a cursor is drawn with.
public enum CursorImageRef: Equatable, Sendable {
    /// Toma's cursor of that shape (`CursorSprite`).
    case toma(CursorKind)
    /// The take's image `cursors/<hash>.png`.
    case recorded(hash: String)
}

/// The drawn cursor: its `image`, `height` tall and `aspect` × `height` wide, with the point `hotspotFraction` of it (0,
/// 0 is its top-left corner) at `hotspot`, at `opacity` (premultiplied: every channel times it) and pressed to
/// `clickScale` of its size about `hotspot`. Nothing is drawn of it at opacity 0 or of no size.
public struct CursorLayer: Equatable, Sendable {
    /// In output pixels, origin at the top left.
    public var hotspot: SIMD2<Double>
    /// In output pixels, before `clickScale`.
    public var height: Double
    public var image: CursorImageRef
    /// Fractions of the image.
    public var hotspotFraction: SIMD2<Double>
    /// Width over height of the image.
    public var aspect: Double
    /// 1 shown, 0 hidden.
    public var opacity: Double
    /// 1 at rest, smaller while pressed.
    public var clickScale: Double

    public init(
        hotspot: SIMD2<Double>, height: Double, image: CursorImageRef = .toma(.arrow),
        hotspotFraction: SIMD2<Double> = CursorSprite.hotspot, aspect: Double = CursorSprite.aspect, opacity: Double = 1,
        clickScale: Double = 1
    ) {
        self.hotspot = hotspot
        self.height = height
        self.image = image
        self.hotspotFraction = hotspotFraction
        self.aspect = aspect
        self.opacity = opacity
        self.clickScale = clickScale
    }
}
