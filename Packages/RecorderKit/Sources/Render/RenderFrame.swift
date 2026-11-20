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
    /// pixels with the stage unzoomed. While it is hidden (`opacity` 0) nothing is drawn of it. In a card (`card`), drawn
    /// through the card's content and cut to it, like the screen.
    public var cursor: CursorLayer?
    /// `nil` when the take has no camera, before its first frame in the Bubble, and where a layout hides it.
    public var camera: CameraLayer?
    /// What is drawn behind everything: the gradient above (today's), a colour, a wallpaper or an image (with the
    /// gradient above, Toma classic, when it cannot be read).
    public var background: BackgroundLayer
    /// The macOS window around the screen, its bar above `screen`'s rect; `nil` without a frame, and when no screen is
    /// shown.
    public var windowFrame: WindowFrameLayer?
    /// The click effects shown (`ClickEffects`), in click order: in stage coordinates like the cursor, drawn over it
    /// and never blurred (in a card, through the card's content and cut to it). None without an effect.
    public var clickEffects: [ClickEffectLayer]
    /// The shadow under `screen`, or under the whole window with `windowFrame`; `nil` without a shadow (`style.shadow`
    /// 0) and when no screen is shown.
    public var shadow: ShadowLayer?
    /// The zoom camera at the frame's time (design §7.4): how the stage is drawn without `subframes`, and how the click
    /// effects always are. `nil`, like an identity, draws the stage as it is, as without a zoom. In a card
    /// (`backgroundTransform`), `nil`: the background goes through `backgroundTransform` and the screen's content through
    /// `card`'s.
    public var stage: StageTransform?
    /// The motion blur of the zoom camera (design §7.2 and §7.4): with any, the stage is drawn once for each, through its
    /// transform and with its cursor instead of `stage` and `cursor`, and they are averaged in their order before the
    /// click effects and the camera are drawn. Empty: the stage drawn once, directly into the target, as without a blur.
    /// In a card (1c design §5.4), each is the card's content (the screens and the cursor) through its transform, cut to
    /// the card, and their average is drawn over the rest of the stage, drawn once through `backgroundTransform`: the
    /// background is the same as without the blur.
    public var subframes: [StageSubframe]
    /// The motion blur of the cursor with the zoom camera still (design §7.5): without `subframes`, with any, the stage is
    /// drawn once through `stage` and these cursors, averaged, over it instead of `cursor`. In stage coordinates, like
    /// `cursor`, each with its own position, opacity and press and the image of `cursor`. In a card, through its content
    /// and cut to it.
    public var cursorSamples: [CursorLayer]
    /// During a change of screen with `GeometryTransitions.spring` (design §7.6), the screen going away: drawn under
    /// `screen`, in its rect and cut as it is, while `screen` fades in over it (`ScreenLayer.opacity`). `nil` otherwise.
    public var previousScreen: ScreenLayer?
    /// While a change moves the window frame (design §7.6), the window where it goes: its title is drawn from there, a
    /// step of √2 at a time (`TitleTexture.scale(for:)`), onto `windowFrame`'s bar. `nil` otherwise: the title is
    /// `windowFrame`'s own.
    public var settledWindowFrame: WindowFrameLayer?
    /// On the camera layouts' path (1c design §5.3 and §14.2, plan decision 13), the opacity of the screen's group: the
    /// screen with its shadow, its window frame and its title, its cursor and its click effects, which fade together (0
    /// to 1). The shadow and the window's bar are drawn at it only where what goes over them lets them through, so the
    /// shadow, the bar and the screen are exactly the group drawn opaque and then blended; the title is drawn at it over
    /// the bar. The screens' own opacities (`ScreenLayer.opacity`), the cursor's and the click effects' already carry it.
    /// `nil` on 1b's path: all of it drawn as in 1b.
    public var screenOpacity: Double?
    /// The camera covers every pixel of the output, opaque: Camera full screen settled (1c design §14.4). Nothing under it
    /// is drawn, neither the background nor the screen with its shadow, window frame, cursor and click effects, and the
    /// frame is the one they would give under it. `false` on 1b's path and wherever anything shows past the camera.
    public var coveredByCamera: Bool
    /// The screen's card, when the zoom acts inside it (1c design §5.4 and §14.2): the screens, the cursor and the click
    /// effects are drawn through its content's transform and cut to it, and the window frame and the shadow stay with the
    /// background (`backgroundTransform`). `nil` on the stage (1b's mode), and where the screen's group is not drawn.
    public var card: CardPlacement?
    /// How the background is drawn in a card's mode (1c design §5.4 and §14.2), the shadow and the window frame with it:
    /// still (an identity) in a card, the stage's zoom (`StageTransform.mix`) on the way between the two during a
    /// transition. `nil` on the stage, 1b's mode: everything through `stage`.
    public var backgroundTransform: StageTransform?
    /// The device around the screen (phase 2 design §6.7), drawn after the window frame (§11, step 1); `nil` without one,
    /// as every document of phase 1.
    public var deviceFrame: DeviceFrameLayer?
    /// The keys on screen (phase 2 design §7.4), over the camera (§11, step 5); `nil` without them, as every document of
    /// phase 1.
    public var keys: KeyOverlayLayer?
    /// The captions (phase 2 design §5.2), over everything (§11, step 6); `nil` without them, as every document of phase 1.
    public var captions: CaptionLayer?
    /// The captions' layers the frames draw next after `captions`, in output order (`CaptionScene.layersAhead`): not drawn
    /// in this frame, but their textures are drawn ahead, off the frame (`CaptionTextures.prepare`), so the frame that
    /// changes word or caption binds a texture made already. Empty without captions, as every document of phase 1.
    public var captionsAhead: [CaptionLayer]
    /// The imported clip of the sequence (phase 3 design §5.4 and §12, step 2), drawn where the screens are; `nil` without
    /// one, as every document of phases 1 and 2.
    public var media: MediaClipLayer?
    /// The calm zoom (phase 3 design §6 and §12, step 4): highlight, dim or the loupe, over the stage drawn; `nil` without
    /// one, as every document of phases 1 and 2.
    public var calmZoom: CalmZoomLayer?
    /// The annotations stuck to the recording (phase 3 design §5.1 and §12, step 5), by layer, in the stage (the zoom moves
    /// them), under the camera. Empty without them, as every document of phases 1 and 2.
    public var contentAnnotations: [AnnotationLayer]
    /// The annotations of the output (phase 3 design §5.1 and §12, step 7), by layer, over the camera and under the keys:
    /// those of the frame's output time, over a frozen frame, a title card or an imported clip too. Empty without them, as
    /// every document of phases 1 and 2.
    public var outputAnnotations: [AnnotationLayer]
    /// The title card (phase 3 design §5.2 and §12), which takes the place of steps 1 to 6, under the output's annotations
    /// (base plan decision 9); `nil` without one, as every document of phases 1 and 2.
    public var titleCard: TitleCardLayer?
    /// The take whose videos and cursor images the frame shows (phase 3 design §9, base plan decision 10): `nil` for the
    /// project's own take (`LoadedProject.take`), as every frame of phases 1 and 2, and a frame of the background alone;
    /// the id of another take for a frame of a clip of it, whose tracks the renderer reads apart from the take's own
    /// (`FrameRenderer`'s `TrackKey`), however alike their ids.
    public var take: String?
    /// The title cards the frames start next, within `TitleCardScene.aheadWindow` after this one (`TitleCardScene.ahead`):
    /// not drawn in this frame, but their texts' textures are drawn ahead, off the frame (`TitleCardTextures.prepare`), so
    /// a card's first frame binds a texture made already. Empty without title cards, as every document of phases 1 and 2.
    public var titleCardsAhead: [TitleCardLayer]
    /// The annotations' layers the frames draw soon after this one, at the scales they will be drawn at (`AnnotationScene`'s
    /// `outputAhead` and `contentAhead`): not drawn in this frame, but their bitmaps are drawn ahead, off the frame
    /// (`AnnotationRasters.prepare`), so a frame where they come in, a step of one being drawn in or a step of √2 of a zoom
    /// binds a texture made already. Empty without annotations, as every document of phases 1 and 2.
    public var annotationsAhead: [AnnotationAhead]

    /// Whether the frame is drawn in a card's mode (`card`, `backgroundTransform`).
    var isCardMode: Bool { card != nil || backgroundTransform != nil }

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
        cursorSamples: [CursorLayer] = [],
        previousScreen: ScreenLayer? = nil,
        settledWindowFrame: WindowFrameLayer? = nil,
        screenOpacity: Double? = nil,
        coveredByCamera: Bool = false,
        card: CardPlacement? = nil,
        backgroundTransform: StageTransform? = nil,
        deviceFrame: DeviceFrameLayer? = nil,
        keys: KeyOverlayLayer? = nil,
        captions: CaptionLayer? = nil,
        captionsAhead: [CaptionLayer] = [],
        media: MediaClipLayer? = nil,
        calmZoom: CalmZoomLayer? = nil,
        contentAnnotations: [AnnotationLayer] = [],
        outputAnnotations: [AnnotationLayer] = [],
        titleCard: TitleCardLayer? = nil,
        take: String? = nil,
        titleCardsAhead: [TitleCardLayer] = [],
        annotationsAhead: [AnnotationAhead] = []
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
        self.previousScreen = previousScreen
        self.settledWindowFrame = settledWindowFrame
        self.screenOpacity = screenOpacity
        self.coveredByCamera = coveredByCamera
        self.card = card
        self.backgroundTransform = backgroundTransform
        self.deviceFrame = deviceFrame
        self.keys = keys
        self.captions = captions
        self.captionsAhead = captionsAhead
        self.media = media
        self.calmZoom = calmZoom
        self.contentAnnotations = contentAnnotations
        self.outputAnnotations = outputAnnotations
        self.titleCard = titleCard
        self.take = take
        self.titleCardsAhead = titleCardsAhead
        self.annotationsAhead = annotationsAhead
    }
}

/// The screen's card where the zoom acts inside it (1c design §5.4 and §14.2): a Split settled, or the way to or from one.
public struct CardPlacement: Equatable, Sendable {
    /// What the card's content is cut to: the screen's rect (under the bar with a window frame) as `backgroundTransform`
    /// draws it, in output pixels. With a window frame, the window drawn the same way cuts it too, as it cuts the screen.
    public var rect: Rect
    /// In output pixels: the screen's corners (without a window frame).
    public var cornerRadius: Double
    /// How the screen's content (the screens, the cursor and the click effects, in stage coordinates) is drawn: the card's
    /// zoom (`MotionPaths.cardZoom`) over the screen's rect in a card, mixed with the stage's zoom during a transition
    /// (`StageTransform.mix`). The cursor is as many times larger as its depth.
    public var content: StageTransform
    /// How far from the stage to the card (`LayoutTimeline.cardWeight`): 1 in a card, between 0 and 1 (a little past them
    /// with the spring) during a transition, by which the transforms and the cut are mixed. What goes past the screen's
    /// edge on the stage, the cursor and the click effects, is cut by this much of the cut, read from 0 to 1, so it is not
    /// cut on the stage nor at a transition's start.
    public var mix: Double

    public init(rect: Rect, cornerRadius: Double, content: StageTransform, mix: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.content = content
        self.mix = mix
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

    /// `a` and `b` mixed at `p` as the layouts mix their numbers (1c design §5.3 and §5.4): every stage point drawn at
    /// `1 − p` times where `a` draws it plus `p` times where `b` does, in any output. So the depth is mixed linearly and a
    /// rect is drawn at the two drawings of it mixed; `b` itself, exactly, at `p` 1.
    static func mix(_ a: StageTransform, _ b: StageTransform, _ p: Double) -> StageTransform {
        let depth = a.depth * (1 - p) + b.depth * p
        // `centre × depth` is `a`'s and `b`'s mixed: `b.center` plus `a`'s offset from it, in its share of the depth.
        return StageTransform(depth: depth, center: b.center + (a.center - b.center) * (a.depth * (1 - p) / depth))
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

/// The recorded screen: the `crop` of the frame of track `trackID` shown at host time `sourceTime`, drawn into `rect` at
/// `opacity`. Inside a window frame (`RenderFrame.windowFrame`), the window's rounded rect cuts it, square along its top
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
    /// 1 opaque, as the recorded video always is; below it while it fades in over the screen going away
    /// (`RenderFrame.previousScreen`), or with its group in the camera layouts (`RenderFrame.screenOpacity`); 0 not drawn.
    public var opacity: Double
    /// What privacy hides of it (phase 2 design §7.1), in its shader (§11, step 2): at most `PrivacyRegion.maxPerFrame`,
    /// as fractions of `crop`. None, as in phase 1: the screen's own shader.
    public var privacy: [PrivacyRegion]

    public init(
        trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double, crop: Rect = Rect(x: 0, y: 0, width: 1, height: 1),
        mipmapped: Bool = false, opacity: Double = 1, privacy: [PrivacyRegion] = []
    ) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.crop = crop
        self.mipmapped = mipmapped
        self.opacity = opacity
        self.privacy = privacy
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
/// centred) with corners of `cornerRadius`, and its look (1c design §14.3): its `shadow` under it, its picture flipped
/// with `mirror`, its `border` inside its edge, all at `opacity`. The fields after `cornerRadius` draw what 1b drew at
/// their defaults: not one drawing nor one value more.
public struct CameraLayer: Equatable, Sendable {
    public var trackID: String
    public var sourceTime: HostTime
    /// In output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels: half the side for a circle.
    public var cornerRadius: Double
    /// Whether the picture is flipped horizontally inside `rect`: its `u` becomes `1 − u` after the centred crop. The rect
    /// stays where it is.
    public var mirror: Bool
    /// 1 opaque, as in 1b; below it, the camera, its border and its shadow are blended over what is under them; 0 (or
    /// less, or not a number) nothing is drawn of it.
    public var opacity: Double
    /// `nil` without one.
    public var border: CameraBorderLayer?
    /// Under the camera, drawn before it; `nil` without one. It fades with the camera as one group, so the camera hides
    /// its own shadow at any opacity, as it does opaque.
    public var shadow: ShadowLayer?
    /// A part of the camera's picture, as fractions of it (0, 0 its top-left corner): the whole picture, and not drawn.
    /// The framing's crop depends on the aspect of the camera's frame, which only its texture knows, so it is
    /// `look.framing`, which the compositor fills the rect from (`Compositor.cameraFill`, plan 2b decision 2).
    public var crop: Rect
    /// Its colour (phase 2 design §6.3); `nil`, natural, as in phase 1.
    public var look: CameraLookLayer?
    /// What is behind the person (phase 2 design §6.1); `nil`, the original, as in phase 1.
    public var background: CameraBackgroundLayer?

    public init(
        trackID: String, sourceTime: HostTime, rect: Rect, cornerRadius: Double, mirror: Bool = false, opacity: Double = 1,
        border: CameraBorderLayer? = nil, shadow: ShadowLayer? = nil, crop: Rect = Rect(x: 0, y: 0, width: 1, height: 1),
        look: CameraLookLayer? = nil, background: CameraBackgroundLayer? = nil
    ) {
        self.trackID = trackID
        self.sourceTime = sourceTime
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.mirror = mirror
        self.opacity = opacity
        self.border = border
        self.shadow = shadow
        self.crop = crop
        self.look = look
        self.background = background
    }
}

/// The camera's border (1c design §14.3): a stroke `width` wide inside the camera's rounded rect, along its edge, with the
/// same antialiasing as its corners. It neither grows the camera nor moves it: the picture fills the rect under it.
/// Nothing is drawn of one that is not above 0 wide.
public struct CameraBorderLayer: Equatable, Sendable {
    /// In output pixels.
    public var width: Double
    /// sRGB from 0 to 1, not premultiplied, written to the output as it is (like the background's colours).
    public var color: SIMD4<Float>

    public init(width: Double, color: SIMD4<Float>) {
        self.width = width
        self.color = color
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
