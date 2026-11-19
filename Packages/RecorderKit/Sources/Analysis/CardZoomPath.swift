// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat

/// The zoom inside the screen's card of a split at one instant (1c design §5.4), in fractions of the screen's content: what
/// the screen shows of the recording (`StagePoints.rects(of:)`'s `screen`), under the bar with a macOS window frame, whose
/// bar stays still over the content in a card (1c design §14.2). So it depends neither on where the card is nor on its
/// size.
public struct CardZoomState: Equatable, Sendable {
    /// `u = ln z`, with `z` the depth: 0 at rest.
    public var logDepth: Double
    /// The centre of the crop shown: (0.5, 0.5), the screen's centre, at rest.
    public var center: SIMD2<Double>

    public init(logDepth: Double, center: SIMD2<Double>) {
        self.logDepth = logDepth
        self.center = center
    }

    /// `z`, 1 at rest: the crop shown is `1/z` of the content on each axis, and a point `p` of the content (in fractions
    /// of it) is drawn at `(p − center) × z + 0.5` of the content's place in the card.
    public var depth: Double { exp(logDepth) }
}

/// Where the zoom inside the screen's card of a split looks, and how deep (1c design §5.4, part of `cameraLayout-1`):
/// the zoom camera of `ZoomCameraPath` over another viewport, the screen's content in its card, in fractions of it. Its
/// simulation is the same `ZoomSimulation`, so:
///
/// - The same blocks of the take, `zoom.spring`, grid of 600 Hz and checkpoints every 600 steps as the stage's camera,
///   and so the same depth on every step; with `zoom.show` off, always at rest.
/// - The crop is `1/z` of the content on each axis and its centre stays in `[1/(2z), 1 − 1/(2z)]` (`StageCrop` over the
///   unit square): the card never shows background, nor, with a window frame, a strip under the bar that is not the
///   screen.
/// - `fixed(x, y)` is the point of 1b: at those fractions of `StagePoints.screenRect(at:)` (with a window frame, the
///   whole window, bar included), taken to the content's fractions and placed. `follow` starts at the cursor's point in
///   the content (`CursorGeometry.normalized` in the region shown, as `StagePoints.stagePoint(global:at:)` places it),
///   then moves with the dead zone, the central box of `ZoomCameraPath.deadZone` of the crop and steps of `followStep`
///   of it. No zone to avoid: in a split the camera is beside the screen, not over it. `instant` jumps.
/// - Where the screen is reframed (`ReframePath`, `reframe-1`), its content is the window it shows of its region: the
///   cursor is in fractions of that window (`ReframePath.part` on the step, read step after step), none outside it.
///
/// The card has the screen's proportion, so the path does not depend on where the card is: it is simulated once for the
/// whole output, only for a document with a split (the project's layout or a block). Simulated everywhere, also where
/// another layout rules, so when the split comes back the zoom is where it has to be.
public struct CardZoomPath: Sendable {
    private let simulation: ZoomSimulation<CardViewport>

    /// Where the card's camera jumps (at an instant block's entry and exit), in order, as `ZoomCameraPath.jumps`: a motion
    /// blur in the card never mixes the two sides.
    public var jumps: [ClosedRange<Int64>] { simulation.jumps }

    /// `nil` when neither the project's layout nor any block is a split. `reframe`: the document's window of the screen
    /// that follows the cursor (`MotionPaths.reframe`); `nil`, the screen fitted whole.
    public init?(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        reframe: ReframePath? = nil
    ) {
        self.init(
            document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: nil, changedFrom: nil,
            reframe: reframe)
    }

    /// The card's camera of the same take after an edit (`MotionPaths.init(take:events:document:after:)`): bit for bit
    /// `init(document:timeMap:stage:cursor:take:)`'s (that one without `old`). With `old`, from its checkpoints as
    /// `ZoomSimulation` keeps them; `changed` is the first step at which what the camera reads besides its blocks and
    /// spring (the time map, the stage, the cursor and the window that follows it) can differ, `nil` where none of them
    /// does; the layouts only decide whether there is a card's camera. Without `old`, simulated from output 0.
    init?(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        after old: CardZoomPath?, changedFrom changed: Int?, reframe: ReframePath? = nil
    ) {
        guard Self.hasSplit(document) else { return nil }
        simulation = ZoomSimulation(
            document: document, timeMap: timeMap, cursor: cursor, take: take,
            viewport: CardViewport(stage: stage, reframe: reframe), after: old?.simulation, changedFrom: changed)
    }

    /// Whether the project's layout or a block is a split.
    private static func hasSplit(_ document: EditDocument) -> Bool {
        document.camera.layout.kind == .split || document.camera.layouts.contains(where: { $0.kind == .split })
    }

    /// The camera on step `s` of the grid (held to the steps of the output), placed.
    public func state(atStep s: Int) -> CardZoomState {
        CardZoomState(simulation.state(atStep: s))
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`.
    public func state(atOutput τ: Int64) -> CardZoomState {
        CardZoomState(simulation.state(atOutput: τ))
    }

    /// The camera over a short span of output time, from one simulation (the motion blur's subsamples in the card, 1c
    /// design §5.4): `state(atOutput:)`, the same query over the steps kept, so with the same bits at every time.
    public struct Span: Sendable {
        private let span: ZoomSimulation<CardViewport>.Span

        fileprivate init(_ span: ZoomSimulation<CardViewport>.Span) {
            self.span = span
        }

        /// `state(atOutput: τ)`: from the steps kept for a time of the span, simulated on its own otherwise.
        public func state(atOutput τ: Int64) -> CardZoomState {
            CardZoomState(span.state(atOutput: τ))
        }
    }

    /// The camera from the step of `start` to the one after the step of `end` (held to the output's steps), simulated
    /// once from the checkpoint before them, every step kept: for spans of a few frames.
    public func span(from start: Int64, through end: Int64) -> Span {
        Span(simulation.span(from: start, through: end))
    }

    // MARK: - Internal (the state of the simulation, for the tests)

    typealias Camera = ZoomCamera

    /// The camera on step `s` (held to `0...lastStep`), from the checkpoint before it.
    func camera(atStep s: Int) -> Camera {
        simulation.camera(atStep: s)
    }

    /// The camera on step `s` (held to `0...lastStep`) simulated from output 0, without the checkpoints.
    func cameraSimulatedFromStart(atStep s: Int) -> Camera {
        simulation.cameraSimulatedFromStart(atStep: s)
    }

    /// `state(atStep: s)` simulated from output 0, without the checkpoints.
    func stateSimulatedFromStart(atStep s: Int) -> CardZoomState {
        CardZoomState(simulation.stateSimulatedFromStart(atStep: s))
    }

    /// The camera on every `StepGrid.checkpointEvery`-th step.
    var checkpoints: [Camera] { simulation.checkpoints }

    /// The steps simulated to build `checkpoints`.
    var simulatedSteps: Int { simulation.simulatedSteps }

    /// The checkpoint from which the checkpoints are the old simulation's, after an edit of blocks alone; `nil` when
    /// they were all simulated or kept from before the edit.
    var splicedAt: Int? { simulation.splicedAt }
}

extension CardZoomState {
    /// A camera `ZoomSimulation` placed over the card.
    fileprivate init(_ placed: ZoomPlacement) {
        self.init(logDepth: placed.logDepth, center: placed.center)
    }
}

/// The screen's content in its card, in fractions of it: what `CardZoomPath` looks over. The crop keeps to the unit
/// square (`size`), the content, even where the window around it is bigger; nothing else is kept off the cursor.
struct CardViewport: ZoomViewport {
    let size = SIMD2<Double>(1, 1)
    let reframe: ReframePath?
    private let stage: StagePoints

    /// The content, and the window where no screen is shown.
    private static let content = Rect(x: 0, y: 0, width: 1, height: 1)

    init(stage: StagePoints, reframe: ReframePath? = nil) {
        self.stage = stage
        self.reframe = reframe
    }

    /// The window around the screen shown at `host` (`StagePoints.screenRect(at:)`), in fractions of its content: what a
    /// fixed focus is a fraction of, as in 1b. Without a window frame, the content itself.
    func screen(at host: HostTime?) -> Rect {
        guard let host, let view = stage.shownScreen(at: host)?.view else { return Self.content }
        let (window, content) = stage.rects(of: view)
        guard content.width > 0, content.height > 0 else { return Self.content }
        return Rect(
            x: (window.x - content.x) / content.width, y: (window.y - content.y) / content.height,
            width: window.width / content.width, height: window.height / content.height)
    }

    /// The cursor at `global` in fractions of the content: where `StagePoints.stagePoint(global:at:)` places it, by the
    /// same rule (on screen, in the region shown, its far edges out). Of a reframed screen, the content is the window
    /// about `windowCenter` (`ReframePath.part`): the cursor in fractions of it, `nil` outside it.
    func cursor(global: SIMD2<Double>, at host: HostTime, windowCenter: Double?) -> SIMD2<Double>? {
        guard let view = stage.shownScreen(at: host)?.view, view.onScreen, let region = view.region else { return nil }
        let point = CGPoint(x: global.x, y: global.y)
        guard CursorGeometry.contains(point, region) else { return nil }
        let fraction = CursorGeometry.normalized(point, in: region)
        guard let windowCenter, let width = stage.reframedWidth(of: view) else { return fraction }
        return StagePoints.placed(fraction, in: ReframePath.part(center: windowCenter, width: width))
    }

    func cleared(
        _ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime
    ) -> SIMD2<Double> {
        target
    }
}
