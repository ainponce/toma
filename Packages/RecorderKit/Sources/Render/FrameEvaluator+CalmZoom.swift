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

/// The calm zoom's blocks of a document (`ZoomMode` other than `classic`) as the frames draw them (plan 3b decision 6),
/// worked out once for the scene from its motion paths (`FrameEvaluator.init`): it depends on no size, as the paths do
/// not. Each take of a sequence has its own scene and paths (`FrameEvaluator.init(project:document:…)`).
///
/// A frame's layer is the path's state of its output time (`CalmZoomPath.state(atOutput:)`), in the output's pixels:
///
/// - The focus is in the stage's coordinates of the output, as `RenderFrame.cursor` is: its centre is the path's, from
///   stage units to the output (`StagePoints.stageSize`), placed again with `StageCrop` at the depth it was placed at
///   (the larger of the instant's and the block's) over the rect today's zoom keeps to at this size, the window's with a
///   frame, the device's bounds with one, the screen's, or the whole output without a screen, as
///   `FrameEvaluator.stageTransform` places the stage's camera; so once settled it is exactly the crop the classic zoom
///   would show. Across a short gap into a deeper block the path places it at that block's depth already, so it does not
///   jump on a screen's edge (`CalmZoomPath`): there, where placing it at this block's depth would move it, it is the
///   path's as it is. Its size is the output over the depth of the instant.
/// - In a split's card (`RenderFrame.card`), where what is drawn of the screen is on the card and the card's zoom shows
///   the crop of the screen's content (`CardZoomPath`), it is that crop: the path's centre at its fractions of the
///   screen's rect in stage units (`StagePoints.rects(of:)`) taken to the screen's content on the card, the content
///   over the depth of the instant; while the card comes in or goes (`CardPlacement.mix` from 0 to 1), the stage's focus
///   and the card's mixed by it, so it does not jump. The compositor draws it through the card's content and cuts
///   Highlight's and Dim's hole to the card.
/// - In `loupe` mode the lens is the block's (`LoupeStyle`), its radius a fraction of the output's short side, and it
///   magnifies by the depth of the instant: from 1× to the block's depth, without moving.
///
/// `nil` without a calm block (`MotionPaths.calmZoom`) and where nothing of one is seen.
struct CalmZoomScene: Sendable {
    /// The path of the take's calm blocks; `nil` without one.
    private let path: CalmZoomPath?
    private let stage: StagePoints
    private let timeMap: TimeMap
    /// The take of each clip of the sequence, and the scene's: the stage's rect is read for its own clips alone, as the
    /// path reads it.
    private let clipTakes: [String]
    private let take: String

    init(document: EditDocument, take: TakeRecord, timeMap: TimeMap, paths: MotionPaths) {
        path = paths.calmZoom
        stage = paths.stage
        self.timeMap = timeMap
        clipTakes = document.sequence.map(\.take)
        self.take = take.id
    }

    /// The calm zoom of `frame`, a frame of the take at output time `output` as either path left it (`finishLayers`):
    /// `nil` without a calm block there or where nothing of it is seen (see the type's notes).
    func layer(atOutput output: Int64, frame: RenderFrame) -> CalmZoomLayer? {
        guard let path, let state = path.state(atOutput: output) else { return nil }
        let size = SIMD2<Double>(frame.outputSize), stageSize = stage.stageSize
        let host = timeMap.source(atOutput: output).flatMap { shown in
            clipTakes.indices.contains(shown.clip) && clipTakes[shown.clip] == take ? shown.source : nil
        }
        // The centre as the path placed it, and placed again at that depth over the rect the zoom keeps to at this size.
        let placedDepth = max(state.depth, state.blockDepth)
        var center = state.center / stageSize * size
        let stageRoom = host.flatMap(stage.screenRect(at:)) ?? Rect(x: 0, y: 0, width: stageSize.x, height: stageSize.y)
        if StageCrop.clamp(center: state.center, depth: placedDepth, stage: stageSize, screen: stageRoom) == state.center {
            let room = frame.windowFrame?.rect ?? frame.deviceFrame?.rects.bounds ?? frame.screen?.rect
                ?? Rect(x: 0, y: 0, width: size.x, height: size.y)
            center = StageCrop.clamp(center: center, depth: placedDepth, stage: size, screen: room)
        }
        var half = size / state.depth / 2
        if let card = frame.card, let content = frame.screen?.rect,
           let screen = host.flatMap(stage.shownScreen(at:)).map({ stage.rects(of: $0.view).screen }),
           screen.width > 0, screen.height > 0
        {
            let fraction = (state.center - SIMD2(screen.x, screen.y)) / SIMD2(screen.width, screen.height)
            let extent = SIMD2(content.width, content.height)
            let weight = card.mix.isNaN ? 0 : min(max(card.mix, 0), 1)
            center += (SIMD2(content.x, content.y) + fraction * extent - center) * weight
            half += (extent / state.depth / 2 - half) * weight
        }
        let loupe = state.mode == .loupe
            ? LoupeLayer(
                radius: state.loupe.radius * min(size.x, size.y), shape: state.loupe.shape, magnification: state.depth)
            : nil
        return CalmZoomLayer(
            mode: state.mode, amount: state.amount,
            focus: Rect(x: center.x - half.x, y: center.y - half.y, width: 2 * half.x, height: 2 * half.y), loupe: loupe)
    }
}
