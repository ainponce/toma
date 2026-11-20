// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The calm zoom of a frame (phase 3 design §6 and §12, step 4, `calmZoom-1` and `loupe-1`): highlight, dim or the loupe,
/// over the stage drawn and under the annotations stuck to the recording (`Compositor.drawCalmZoom`, `CalmZoomLook`).
/// Nothing is drawn of one that is not seen: `amount` not above 0 (or not a number), `classic`, a focus that is not
/// finite, or the loupe without a lens of some size. `init()` is such a one.
public struct CalmZoomLayer: Equatable, Sendable {
    /// Highlight, dim or the loupe; `classic` draws nothing.
    public var mode: ZoomMode
    /// How much of the effect is seen, 0 to 1 (more is 1): every part of it is mixed with what is under it by this much.
    public var amount: Double
    /// The focus in stage coordinates (output pixels with the stage unzoomed, as `RenderFrame.cursor`), drawn through the
    /// stage's transform, or the card's content in a card's mode: what highlight rings and dim leaves sharp, and where the
    /// loupe's lens is centred.
    public var focus: Rect
    /// The lens in `loupe` mode; `nil` otherwise.
    public var loupe: LoupeLayer?

    public init(
        mode: ZoomMode = .highlight, amount: Double = 0, focus: Rect = Rect(x: 0, y: 0, width: 0, height: 0),
        loupe: LoupeLayer? = nil
    ) {
        self.mode = mode
        self.amount = amount
        self.focus = focus
        self.loupe = loupe
    }
}

/// The loupe's lens (phase 3 design §6, `loupe-1`), centred on the focus's centre as it is drawn.
public struct LoupeLayer: Equatable, Sendable {
    /// In output pixels: the circle's radius, or the rounded rectangle's half height (it is 1.5 times as wide).
    public var radius: Double
    public var shape: LoupeShape
    /// How many times larger what is under the lens is shown, at least 1 (less is 1): the depth of the instant.
    public var magnification: Double

    public init(radius: Double, shape: LoupeShape, magnification: Double) {
        self.radius = radius
        self.shape = shape
        self.magnification = magnification
    }
}

/// The calm zoom's blocks of a document (`ZoomMode` other than `classic`) as the frames draw them, worked out once for the
/// scene from its motion paths (`FrameEvaluator.init`): it depends on no size. `nil` everywhere in the base.
struct CalmZoomScene: Sendable {
    init(document: EditDocument, take: TakeRecord, timeMap: TimeMap, paths: MotionPaths) {}

    /// The calm zoom of `frame`, a frame of the take at output time `output` as either path left it (`finishLayers`):
    /// `nil` without a calm block there, and always in the base.
    func layer(atOutput output: Int64, frame: RenderFrame) -> CalmZoomLayer? {
        nil
    }
}
