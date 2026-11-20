// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The zoom camera at one instant (design §7.4), in stage units (the stage is 1 tall), so it does not depend on the
/// size the output is drawn at.
public struct ZoomCameraState: Equatable, Sendable {
    /// `u = ln z`, with `z` the depth: 0 at rest.
    public var logDepth: Double
    /// The centre of the crop shown: the stage's centre at rest.
    public var center: SIMD2<Double>

    public init(logDepth: Double, center: SIMD2<Double>) {
        self.logDepth = logDepth
        self.center = center
    }

    /// `z`, 1 at rest: the crop shown is the stage over it, and a point of the stage is drawn at
    /// `(point − center) × z + stage / 2`.
    public var depth: Double { exp(logDepth) }
}

/// Where the zoom camera looks over the output, and how deep (design §8.3 and §8.6): simulated on `StepGrid` from
/// output 0, in stage units, from the document's zoom blocks of the take and the smoothed cursor.
///
/// - The blocks are the take's `zoom.regions` in their output ranges (`TimeMap.outputRange(ofSource:take:)`, cuts
///   closed); none with `zoom.show` off, so the camera is always at rest. A block reads the steps whose output time is
///   in its range. Blocks do not overlap (the track does not let them); in a document edited by hand, one that starts
///   inside the one before it starts where that one ends. Two blocks at most 1 ns apart touch: an automatic block's
///   end mapped back to the output can be 1 ns short of the next one's start (plan decision 16). Of those, the camera
///   reads the `classic` ones alone (phase 3 design §6, `ZoomRegion.resolvedMode(auto:)`): in a calm block (highlight,
///   dim or loupe) it is at rest, as outside every block, and `CalmZoomPath` simulates the same camera over the calm
///   ones alone.
/// - The target, read on each step: outside every block, rest (`u` 0, the stage's centre); in a block, `u = ln` of its
///   depth (the block's, or `zoom.auto.depth`; read from 1 to 16, 1 if not a number) and a centre placed with
///   `StageCrop` at that depth over the screen's rect at the step's source instant (`StagePoints.screenRect(at:)`; the
///   stage without one):
///   - `fixed`: the point at its fractions of the screen's rect (read from 0 to 1, 0.5 if not a number); the cursor
///     does not move it.
///   - `follow`: on entering the block, the cursor's stage point (where the camera already heads without one). Then,
///     with the dead zone: on each axis where the cursor leaves the central box (`deadZone` of the crop it heads to),
///     the target moves by how far it went out and `followStep` of the crop more, that way. A cursor under the camera's
///     bubble (its rect in the output, `CameraStyleTimeline` at stage size, grown by `bubbleMargin` of its size about
///     its centre) counts as out toward the bubble's side: the target moves, on the axis where that takes the least, by
///     what takes the cursor out of the bubble through its edge that faces the output's centre and `followStep` of the
///     crop more (the image moves away from the bubble), but never nearer the output's edge than `frameMargin`. The
///     bubble is applied after the box, so a bubble too big for the box leaves the cursor out of the box but visible,
///     in the frame, on the same target every step. The bubble counts where the render draws the camera, by the one
///     rule of both (`CameraBubble`): with `camera.show`, a camera track with a segment, from the start of its first
///     segment on, measured against the document's `camera.sizeReference`. With camera layouts (a document whose
///     `LayoutTimeline` is not trivial, with the camera readable as the render reads it, plan decision 40), the bubble is
///     the layouts' camera in stage units (`LayoutTimeline.geometry(atOutput:_:)`, through a transition into the span
///     too) only where a Bubble span rules, the take's or a block's with its own bubble, and none where another does:
///     in Screen only nothing is over the screen, and the cards of the others are beside it or cover it all (1c design
///     §5.4). A trivial document's is the take's bubble, as in 1b. The cursor is `CursorPath`'s on the step, read before
///     the camera moves (design §8.6), at its stage point (`StagePoints.stagePoint(global:at:)`); without one, the
///     target stays. Where the screen is reframed (`ReframePath`, `reframe-1`), the cursor's stage point is where it is
///     in the window the screen shows on the step (`StagePoints.stagePoint(global:at:part:)`, the window read step after
///     step as the cursor is), none outside it; the screen's rect is the room, so a fixed focus is a point of it.
/// - The motion: `zoom.spring` (`StepGrid.spring`, the spring read through `StepGrid.stable(_:)` so a document edited
///   by hand never stops the render) for `u` and for each axis of the centre, toward the target. On entering or
///   leaving an `instant` block, the camera jumps to the target with velocity 0.
/// - Drawn (`state(atStep:)`, `state(atOutput:)`): `u` at least 0 and the centre placed with `StageCrop` at that
///   depth over the screen's rect of the instant, so the crop never leaves the stage, nor the screen on an axis where
///   it fits in it.
///
/// The whole state is kept every `StepGrid.checkpointEvery` steps; a step is simulated from the checkpoint before it,
/// which gives the same bits as from output 0. Off the grid, the two steps around are mixed linearly before being
/// placed. After the end of the output the camera stays as on its last step.
///
/// The simulation is `ZoomSimulation`'s over the stage (`StageViewport`), the one `CardZoomPath` runs over the screen in
/// its card: the blocks, the dead zone, the steps and the checkpoints are written once for both.
public struct ZoomCameraPath: Sendable {
    /// The central box of the crop the cursor moves in without moving the camera, as a fraction of the crop on each axis.
    public static let deadZone = 0.60
    /// How much farther than the cursor went out of the box the camera moves, as a fraction of the crop.
    public static let followStep = 0.15
    /// How much bigger than the camera's bubble the area the cursor counts as under it is, as a fraction of its size.
    public static let bubbleMargin = 0.08

    /// The bubble never moves the cursor nearer the output's edges than this, in stage units: the camera's own margin
    /// (`CameraStyle.marginFraction` of the height), so even the biggest bubble on the side of a 9:16 output leaves it in
    /// the frame, and out from under the bubble.
    static let frameMargin = CameraStyle.marginFraction

    private let simulation: ZoomSimulation<StageViewport>

    /// Where the camera jumps (at an instant block's entry and exit), in order: each from the output time of the step
    /// before the jump through that of the step it jumps on. A motion blur never mixes the two sides.
    public var jumps: [ClosedRange<Int64>] { simulation.jumps }

    /// `cameraReadable`: some camera track of the take can be read (plan decision 40, `LayoutTimeline.cameraReadable`), as
    /// the render is told; without one, the layouts that need the camera are Screen only, with no bubble. `reframe`: the
    /// document's window of the screen that follows the cursor (`MotionPaths.reframe`); `nil`, the screen fitted whole.
    public init(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        cameraReadable: Bool = true, reframe: ReframePath? = nil
    ) {
        self.init(
            document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: nil, changedFrom: nil,
            layouts: Self.layouts(of: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable),
            reframe: reframe)
    }

    /// The camera of the same take after an edit (`MotionPaths.init(take:events:document:after:)`): bit for bit
    /// `init(document:timeMap:stage:cursor:take:cameraReadable:)`'s (that one without `old`), from `old`'s checkpoints as
    /// `ZoomSimulation` keeps them. `changed` is the first step at which what the camera reads besides its blocks and
    /// spring (the time map, the stage, the cursor, the camera's bubble, the layouts and the window that follows the
    /// cursor) can differ; `nil`, none of them does. `layouts`: `layouts(of:take:timeMap:cameraReadable:)` of the
    /// document; with the camera readable when `nil`.
    /// `selection`: the blocks the camera reads, the classic ones (the stage's camera) or the calm ones alone
    /// (`CalmZoomPath`'s, with the rules of the calm focus, `ZoomSimulation`); `old` was built with the same.
    init(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord,
        after old: ZoomCameraPath?, changedFrom changed: Int?, layouts: LayoutTimeline? = nil, reframe: ReframePath? = nil,
        selecting selection: ZoomSelection = .classic
    ) {
        let layouts = layouts ?? Self.layouts(of: document, take: take, timeMap: timeMap, cameraReadable: true)
        self.layouts = layouts
        simulation = ZoomSimulation(
            document: document, timeMap: timeMap, cursor: cursor, take: take,
            viewport: StageViewport(
                stage: stage, bubble: CameraBubble(document: document, take: take, timeMap: timeMap),
                reference: document.camera.sizeReference,
                layouts: layouts.isTrivial ? nil : StageViewport.Layouts(layouts, document: document, size: stage.stageSize),
                reframe: reframe),
            after: old?.simulation, changedFrom: changed, selecting: selection)
    }

    /// The layouts the camera's bubble is read from, as the render reads them (`FrameEvaluator`): with the camera readable
    /// only where the document shows a camera the take has.
    static func layouts(of document: EditDocument, take: TakeRecord, timeMap: TimeMap, cameraReadable: Bool) -> LayoutTimeline {
        let bubble = CameraBubble(document: document, take: take, timeMap: timeMap)
        return LayoutTimeline(document: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable && bubble != nil)
    }

    /// The layouts the camera's bubble was read from (`layouts(of:take:timeMap:cameraReadable:)`): what an edit compares.
    let layouts: LayoutTimeline

    /// The camera on step `s` of the grid (held to the steps of the output), placed.
    public func state(atStep s: Int) -> ZoomCameraState {
        ZoomCameraState(simulation.state(atStep: s))
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`.
    public func state(atOutput τ: Int64) -> ZoomCameraState {
        ZoomCameraState(simulation.state(atOutput: τ))
    }

    /// The camera over a short span of output time, from one simulation (the motion blur's subsamples, design §7.4):
    /// `state(atOutput:)`, the same query over the steps kept, so with the same bits at every time of the span, without
    /// simulating from a checkpoint for each.
    public struct Span: Sendable {
        private let span: ZoomSimulation<StageViewport>.Span

        fileprivate init(_ span: ZoomSimulation<StageViewport>.Span) {
            self.span = span
        }

        /// `state(atOutput: τ)`: from the steps kept for a time of the span, simulated on its own otherwise.
        public func state(atOutput τ: Int64) -> ZoomCameraState {
            ZoomCameraState(span.state(atOutput: τ))
        }
    }

    /// The camera from the step of `start` to the one after the step of `end` (held to the output's steps), simulated
    /// once from the checkpoint before them, every step kept: for spans of a few frames.
    public func span(from start: Int64, through end: Int64) -> Span {
        Span(simulation.span(from: start, through: end))
    }

    // MARK: - Internal (for `CalmZoomPath`)

    /// The blocks the camera reads, in output order.
    var blocks: [ZoomBlock] { simulation.blocks }

    /// The last step simulated: the one of the end of the output.
    var lastStep: Int { simulation.lastStep }

    /// `state(atOutput: τ)` with the centre placed at `depth` (`StageCrop`) rather than at the camera's own.
    func state(atOutput τ: Int64, placedAt depth: Double) -> ZoomCameraState {
        ZoomCameraState(simulation.state(atOutput: τ, placedAt: depth))
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
    func stateSimulatedFromStart(atStep s: Int) -> ZoomCameraState {
        ZoomCameraState(simulation.stateSimulatedFromStart(atStep: s))
    }

    /// The camera on every `StepGrid.checkpointEvery`-th step.
    var checkpoints: [Camera] { simulation.checkpoints }

    /// The steps simulated to build `checkpoints`.
    var simulatedSteps: Int { simulation.simulatedSteps }

    /// The checkpoint from which the checkpoints are the old simulation's, after an edit of blocks alone; `nil` when
    /// they were all simulated or kept from before the edit.
    var splicedAt: Int? { simulation.splicedAt }

    /// The camera a following target keeps the cursor out from under at output time `τ` (source instant `host`), in stage
    /// units, before `bubbleMargin` grows it; `nil` where there is none.
    func avoidedCamera(atOutput τ: Int64, host: HostTime) -> Rect? {
        simulation.viewport.camera(atOutput: τ, host: host)
    }
}

extension ZoomCameraState {
    /// A camera `ZoomSimulation` placed over the stage.
    fileprivate init(_ placed: ZoomPlacement) {
        self.init(logDepth: placed.logDepth, center: placed.center)
    }
}

/// The stage, in stage units: what `ZoomCameraPath` looks over. A fixed focus is measured in the screen's rect and the
/// crop keeps to it (the whole stage where none is shown); a following target keeps the cursor out from under the
/// camera's bubble, or, with layouts, the layouts' camera where a Bubble span rules (see `ZoomCameraPath`'s notes).
struct StageViewport: ZoomViewport {
    let size: SIMD2<Double>
    let reframe: ReframePath?
    private let stage: StagePoints
    /// `nil` where the render draws no camera.
    private let bubble: CameraBubble?
    /// What the bubble is measured against, as the render measures it: the document's `camera.sizeReference`.
    private let reference: SizeReference
    /// A document's layouts that are not trivial; `nil`, the take's bubble alone, as in 1b.
    private let layouts: Layouts?

    /// A bubble whose centre is this close to the output's centre on an axis is on neither side of it (one in the
    /// middle of an edge).
    private static let centred = 1e-9

    init(
        stage: StagePoints, bubble: CameraBubble?, reference: SizeReference, layouts: Layouts? = nil,
        reframe: ReframePath? = nil
    ) {
        size = stage.stageSize
        self.reframe = reframe
        self.stage = stage
        self.bubble = bubble
        self.reference = reference
        self.layouts = layouts
    }

    /// The camera layouts the bubble is read from, and what their geometry reads of the document, in stage units.
    struct Layouts: Sendable {
        let timeline: LayoutTimeline
        /// `StageStyle.padding` and `cornerRadius`.
        let padding: Double
        let cornerRadius: Double
        /// From this long after a border on, its transition has settled (`LayoutTimeline.StepResponse`).
        let settleSeconds: Double
        /// For each span, a Bubble block's own bubble over the stage (`CameraStyle.frame(in:reference:)`), as the
        /// layouts place it; `nil` for the project's, which is the take's.
        let blockBubbles: [Rect?]

        init(_ timeline: LayoutTimeline, document: EditDocument, size: SIMD2<Double>) {
            self.timeline = timeline
            padding = document.style.padding
            cornerRadius = document.style.cornerRadius
            settleSeconds = LayoutTimeline.StepResponse(document.camera.spring).settleSeconds
            let region = Rect(x: 0, y: 0, width: size.x, height: size.y), reference = document.camera.sizeReference
            blockBubbles = timeline.spans.map { span in
                span.blockID == nil ? nil : span.bubbleStyle.map { $0.frame(in: region, reference: reference).rect }
            }
        }

        /// The span that rules at output time `τ`, as `LayoutTimeline.span(atOutput:)` finds it: the last one starting at
        /// or before it, the first one before the output.
        func index(atOutput τ: Int64) -> Int {
            let spans = timeline.spans
            var low = 0, high = spans.count
            while low < high {
                let mid = (low + high) / 2
                if spans[mid].output.lowerBound <= τ { low = mid + 1 } else { high = mid }
            }
            return max(low - 1, 0)
        }

        /// Whether the transition at the start of span `k` is under way at output time `τ`, as the timeline blends it: a
        /// border that is not an edge of an instant block, less than `settleSeconds` before `τ`.
        func isMoving(border k: Int, at τ: Int64) -> Bool {
            let spans = timeline.spans
            guard k > 0, !spans[k].instant, !spans[k - 1].instant else { return false }
            return CursorPath.seconds(τ, since: spans[k].output.lowerBound) < settleSeconds
        }
    }

    func screen(at host: HostTime?) -> Rect {
        host.flatMap(stage.screenRect(at:)) ?? Rect(x: 0, y: 0, width: size.x, height: size.y)
    }

    func cursor(global: SIMD2<Double>, at host: HostTime, windowCenter: Double?) -> SIMD2<Double>? {
        guard let windowCenter else { return stage.stagePoint(global: global, at: host) }
        guard let view = stage.shownScreen(at: host)?.view else { return nil }
        let part = stage.reframedWidth(of: view).map { ReframePath.part(center: windowCenter, width: $0) }
        return stage.stagePoint(global: global, in: view, part: part)
    }

    /// The bubble, applied after the dead zone (see `ZoomCameraPath`'s notes).
    func cleared(
        _ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime
    ) -> SIMD2<Double> {
        guard let bubble = bubbleRect(atOutput: τ, host: host) else { return target }
        return cleared(target, of: bubble, cursor: point, depth: depth)
    }

    /// The camera at output time `τ` (source instant `host`), grown by `bubbleMargin`; `nil` where there is none.
    private func bubbleRect(atOutput τ: Int64, host: HostTime) -> Rect? {
        guard let rect = camera(atOutput: τ, host: host) else { return nil }
        let grow = ZoomCameraPath.bubbleMargin / 2
        return Rect(
            x: rect.x - rect.width * grow, y: rect.y - rect.height * grow, width: rect.width * (1 + ZoomCameraPath.bubbleMargin),
            height: rect.height * (1 + ZoomCameraPath.bubbleMargin))
    }

    /// The camera the cursor is kept from at output time `τ` (source instant `host`), in stage units: the take's bubble
    /// without layouts (1b); with them, where a Bubble span rules, the layouts' camera when it is seen (some opacity, some
    /// size), and none elsewhere (see `ZoomCameraPath`'s notes). `nil` where there is none.
    func camera(atOutput τ: Int64, host: HostTime) -> Rect? {
        guard let layouts else { return bubble?.frame(atOutput: τ, host: host, output: size, reference: reference)?.rect }
        let k = layouts.index(atOutput: τ)
        guard layouts.timeline.spans[k].kind == .bubble else { return nil }
        let takeBubble = bubble?.frame(atOutput: τ, host: host, output: size, reference: reference)
        let rect: Rect
        if layouts.isMoving(border: k, at: τ) {
            // A transition into the span: what it shows.
            let screen = stage.screenRect(at: host)
            let camera = layouts.timeline.geometry(atOutput: τ, LayoutInputs(
                output: size, padding: layouts.padding, cornerRadius: layouts.cornerRadius,
                screenAspect: screen.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil }, takeBubble: takeBubble,
                sizeReference: reference)).camera
            guard camera.opacity > 0 else { return nil }
            rect = camera.rect
        } else {
            // Settled: its block's own bubble or the take's, as `geometry(atOutput:_:)` gives them, but none before the
            // camera's first frame.
            guard let takeBubble else { return nil }
            rect = layouts.blockBubbles[k] ?? takeBubble.rect
        }
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// `target` with the cursor at stage point `point` moved out from under `bubble` (see `ZoomCameraPath`'s notes).
    private func cleared(
        _ target: SIMD2<Double>, of bubble: Rect, cursor point: SIMD2<Double>, depth: Double
    ) -> SIMD2<Double> {
        // The cursor in the output, as the crop the camera heads to shows it.
        let shown = (point - target) * depth + size / 2
        let low = SIMD2(bubble.x, bubble.y), high = SIMD2(bubble.x + bubble.width, bubble.y + bubble.height)
        guard shown.x >= low.x, shown.x <= high.x, shown.y >= low.y, shown.y <= high.y else { return target }
        var best: (axis: Int, need: Double, side: Double)?
        for axis in 0..<2 {
            let side = (low[axis] + high[axis]) / 2 - size[axis] / 2
            guard abs(side) > Self.centred else { continue }
            let need = side > 0 ? shown[axis] - low[axis] : high[axis] - shown[axis]
            if best.map({ need < $0.need }) ?? true { best = (axis, need, side) }
        }
        guard let best else { return target }
        // Where the cursor goes in the output on that axis: `followStep` of the output past the bubble's edge, but never
        // nearer the output's edge than `frameMargin` (a big bubble on the side of a narrow output), nor back.
        let axis = best.axis
        let edge = size[axis] * ZoomCameraPath.followStep
        let goal = best.side > 0
            ? min(shown[axis], max(low[axis] - edge, ZoomCameraPath.frameMargin))
            : max(shown[axis], min(high[axis] + edge, size[axis] - ZoomCameraPath.frameMargin))
        var moved = target
        moved[axis] += (shown[axis] - goal) / depth
        return moved
    }
}

// MARK: - The simulation both zoom cameras share

/// What a zoom camera looks over (1c design §4.2: the zoom of 1b "with another viewport"): the whole stage, in stage
/// units (`StageViewport`, `ZoomCameraPath`'s), or the screen in its card, in fractions of it (`CardViewport`,
/// `CardZoomPath`'s). The crop of depth `z` is `size / z`, centred on the camera's centre, and `StageCrop` keeps it
/// inside `size` and inside the screen's rect.
protocol ZoomViewport: Sendable {
    /// What the camera looks over, from (0, 0) to `size`: at rest it looks at all of it, from its centre.
    var size: SIMD2<Double> { get }
    /// The window of a reframed screen that follows the cursor (`ReframePath`), where the cursor is placed; `nil` with
    /// the screen fitted whole.
    var reframe: ReframePath? { get }
    /// The rect of the screen shown at source instant `host` (`nil`: no instant of the take is shown), in the viewport's
    /// units: what a fixed focus is a fraction of, and what the crop keeps to where it fits in it.
    func screen(at host: HostTime?) -> Rect
    /// Where the cursor at `global` (global points) is at source instant `host`, in the viewport's units; `nil` off the
    /// screen shown, as `StagePoints.stagePoint(global:at:)`. `windowCenter`: with `reframe`, its centre on the step
    /// (`ReframePath.center(atStep:)`, read step after step): a reframed screen shows the window about it
    /// (`ReframePath.part`), and the cursor is placed in it, `nil` outside it.
    func cursor(global: SIMD2<Double>, at host: HostTime, windowCenter: Double?) -> SIMD2<Double>?
    /// `target`, where the dead zone left a following block's target of `depth` with the cursor at `point`, moved off
    /// what else the viewport keeps the cursor from at output time `τ` (source instant `host`); `target` where nothing.
    func cleared(_ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime)
        -> SIMD2<Double>
}

/// Everything a zoom camera's simulation carries from one step to the next, in its viewport's units.
struct ZoomCamera: Equatable, Sendable {
    var logDepth: Double
    var logDepthVelocity: Double
    /// Not placed: the spring's.
    var center: SIMD2<Double>
    var centerVelocity: SIMD2<Double>
    /// Where the centre heads, placed: the viewport's centre at rest (where the centre is, outside every block of a
    /// simulation of the calm blocks), the focus in a fixed block, where the dead zone left it in a following one.
    var target: SIMD2<Double>
    /// The block of the step, as an index of the blocks in output order; `nil` outside them.
    var block: Int?

    /// Whether `other` is this camera bit for bit: `==` would take 0 for −0, which can part from it on later steps.
    func hasTheBits(of other: ZoomCamera) -> Bool {
        let values = [logDepth, logDepthVelocity, center.x, center.y, centerVelocity.x, centerVelocity.y, target.x, target.y]
        let others = [
            other.logDepth, other.logDepthVelocity, other.center.x, other.center.y, other.centerVelocity.x,
            other.centerVelocity.y, other.target.x, other.target.y,
        ]
        return block == other.block && values.map(\.bitPattern) == others.map(\.bitPattern)
    }
}

/// A zoom camera drawn: its depth (`u = ln z`, at least 0) and the centre of its crop, placed, in its viewport's units.
struct ZoomPlacement: Equatable, Sendable {
    var logDepth: Double
    var center: SIMD2<Double>
}

/// A zoom block of the take, on the grid.
struct ZoomBlock: Equatable, Sendable {
    /// The steps whose output time is in its output range.
    var steps: Range<Int>
    /// From 1 to 16.
    var depth: Double
    var logDepth: Double
    /// Fractions of the screen's rect; `nil`, it follows the cursor.
    var focus: SIMD2<Double>?
    var instant: Bool
    /// How it shows its focus (`ZoomRegion.resolvedMode(auto:)`): which of the two simulations reads it
    /// (`ZoomSelection`).
    var mode: ZoomMode
    /// Its lens in `loupe` mode (`ZoomRegion.resolvedLoupe`).
    var loupe: LoupeStyle

    /// Two blocks at most this far apart in output time touch.
    private static let touching: Int64 = 1
    private static let depthRange = 1.0...16.0

    /// The take's blocks of `zoom` on the grid, in output order (the document's among those that start together).
    static func blocks(of zoom: ZoomPlan, take: String, timeMap: TimeMap) -> [ZoomBlock] {
        var placed: [(output: Range<Int64>, region: ZoomRegion)] = []
        for region in zoom.regions where region.take == take && region.start < region.end {
            guard let output = timeMap.outputRange(ofSource: region.start..<region.end, take: take), !output.isEmpty else {
                continue
            }
            placed.append((output, region))
        }
        placed = placed.enumerated()
            .sorted { ($0.element.output.lowerBound, $0.offset) < ($1.element.output.lowerBound, $1.offset) }
            .map(\.element)
        var kept: [(output: Range<Int64>, region: ZoomRegion)] = []
        for var block in placed {
            if let last = kept.last {
                let start = max(block.output.lowerBound, last.output.upperBound)
                guard start < block.output.upperBound else { continue }
                block.output = start..<block.output.upperBound
                if start - last.output.upperBound <= touching { kept[kept.count - 1].output = last.output.lowerBound..<start }
            }
            kept.append(block)
        }
        return kept.compactMap { block in
            let first = StepGrid.firstStep(atOrAfter: block.output.lowerBound)
            let steps = first..<StepGrid.firstStep(atOrAfter: block.output.upperBound)
            guard !steps.isEmpty else { return nil }
            let read = block.region.depth ?? zoom.auto.depth
            let depth = read.isNaN ? 1 : min(max(read, depthRange.lowerBound), depthRange.upperBound)
            let focus: SIMD2<Double>? = switch block.region.focus {
            case .follow: nil
            case let .fixed(x, y): SIMD2(unit(x), unit(y))
            }
            return ZoomBlock(
                steps: steps, depth: depth, logDepth: log(depth), focus: focus, instant: block.region.instant,
                mode: block.region.resolvedMode(auto: zoom.auto), loupe: block.region.resolvedLoupe)
        }
    }

    /// `value` read from 0 to 1, 0.5 if it is not a number.
    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0.5 : min(max(value, 0), 1)
    }

    /// The first step on which a camera over `new` can read another block than over `old`: the first step of the first
    /// block that differs in one of them (a step before it is in the same blocks of both, under the same index, or in
    /// none). `nil` when they are the same.
    static func firstChangedStep(_ old: [ZoomBlock], _ new: [ZoomBlock]) -> Int? {
        let common = min(old.count, new.count)
        let i = (0..<common).first { old[$0] != new[$0] } ?? common
        return [old, new].compactMap { i < $0.count ? $0[i].steps.lowerBound : nil }.min()
    }

    /// Where `old` and `new` differ, when they do: past the blocks both start with, before those both end with (the
    /// most they can), the blocks of either one there are the ones an edit changed. `end`, the step after the last of
    /// those to end (a step from it on is in a block both end with, or in none); `oldAfter`, the index in `old` of the
    /// first block both end with; `shift`, how far its index moves in `new`.
    static func edited(_ old: [ZoomBlock], _ new: [ZoomBlock]) -> (end: Int, oldAfter: Int, shift: Int)? {
        let common = min(old.count, new.count)
        let first = (0..<common).first { old[$0] != new[$0] } ?? common
        guard first < max(old.count, new.count) else { return nil }
        var last = 0
        while last < common - first, old[old.count - 1 - last] == new[new.count - 1 - last] { last += 1 }
        let changed = old[first..<(old.count - last)] + new[first..<(new.count - last)]
        return (changed.map(\.steps.upperBound).max() ?? 0, old.count - last, new.count - old.count)
    }

    /// Where a camera over `blocks` jumps, in order (final review B-M1): an instant block is entered on its first step
    /// and left on the one after its last, and the camera jumps there, from the output time of the step before through
    /// that of the step it jumps on; none on step 0 nor after `lastStep`.
    static func jumps(of blocks: [ZoomBlock], lastStep: Int) -> [ClosedRange<Int64>] {
        let steps = Set(blocks.filter { $0.instant && !$0.steps.isEmpty }.flatMap { [$0.steps.lowerBound, $0.steps.upperBound] })
        return steps.filter { $0 > 0 && $0 <= lastStep }.sorted().map {
            StepGrid.outputTime(ofStep: $0 - 1)...StepGrid.outputTime(ofStep: $0)
        }
    }
}

/// Which of the take's zoom blocks a simulation of the zoom camera reads (phase 3 plan 3b, decision 3), from the list
/// `ZoomBlock.blocks(of:take:timeMap:)` makes, its overlaps already settled: the `classic` ones (the camera that moves
/// the picture, the stage's and the card's: with every block classic, the list of phase 2) or the calm ones
/// (`ZoomMode.isCalm`, `CalmZoomPath`'s focus).
enum ZoomSelection: Sendable {
    case classic, calm

    /// Whether a simulation of this selection reads `block`.
    func selects(_ block: ZoomBlock) -> Bool {
        block.mode.isCalm == (self == .calm)
    }
}

/// A zoom camera simulated on `StepGrid` from output 0 over `Viewport` (design §8.3 and §8.6, 1c design §5.4), what
/// `ZoomCameraPath`, `CardZoomPath` and `CalmZoomPath` share; `ZoomCameraPath`'s notes say it in the stage's units.
///
/// - The blocks are the take's `zoom.regions` on the grid (none with `zoom.show` off: always at rest), those of its
///   selection alone (`ZoomSelection`).
/// - The target, read on each step: outside every block, rest (`u` 0, the viewport's centre); in a block, `u = ln` of
///   its depth and a centre placed with `StageCrop` at that depth over the viewport's screen at the step's source
///   instant: a fixed focus is its point of that screen; a following one is, on entering the block, the cursor's point
///   (`CursorPath`'s on the step, read before the camera moves; in the window of a reframed screen, the viewport's
///   `ReframePath` read on the step after the cursor), then the dead zone (`ZoomCameraPath.deadZone` of the crop it
///   heads to, steps of `followStep` of it) and what the viewport clears (`ZoomViewport.cleared`).
/// - The motion: `zoom.spring` (`StepGrid.spring`, through `StepGrid.stable(_:)`) for `u` and each axis of the centre;
///   on entering or leaving an `instant` block, a jump to the target with velocity 0.
/// - Of the calm blocks (`ZoomSelection.calm`, plan decision 4), so the focus never appears at the centre and travels:
///   outside every block the centre stays where it is (its target, with velocity 0) while `u` heads to 0; on entering a
///   block from outside every one, the centre jumps to its target with velocity 0 and `u` goes on with the spring (both
///   jump into an `instant` one, as above). From one block into the next one touching it, as the classic camera.
/// - Drawn: `u` at least 0 and the centre placed with `StageCrop` over the viewport's screen of the instant.
///
/// The whole state is kept every `StepGrid.checkpointEvery` steps, and every query reads a step from its checkpoint (or
/// from the steps a span kept), with the same bits as from output 0: a run from a checkpoint is a pure function of it
/// and the inputs, so the checkpoints after one can be simulated again from it alone. That is also how an edit rebuilds
/// it (`init(document:timeMap:cursor:take:viewport:after:changedFrom:)` with `old`): the checkpoints before the first
/// step the edit can change are kept, and the rest simulated again from the last of them, until, after an edit of
/// blocks alone, the camera is again on one of the old simulation's.
struct ZoomSimulation<Viewport: ZoomViewport>: Sendable {
    /// The last step simulated: the one of the end of the output.
    let lastStep: Int
    let viewport: Viewport
    private let spring: SpringSpec
    /// In output order, never overlapping: those of `selection`.
    let blocks: [ZoomBlock]
    private let selection: ZoomSelection
    /// Where the camera jumps (`ZoomBlock.jumps(of:lastStep:)`): read from the blocks and the end alone, so an edit's
    /// rebuild has them as building from nothing does.
    let jumps: [ClosedRange<Int64>]
    private let takeID: String
    /// The take of each clip of the sequence.
    private let clipTakes: [String]
    private let timeMap: TimeMap
    private let cursor: CursorPath
    /// The camera on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`.
    private(set) var checkpoints: [ZoomCamera] = []
    /// The steps simulated to build `checkpoints`.
    private(set) var simulatedSteps = 0
    /// The step of the checkpoint from which `checkpoints` are the old simulation's tail (`Tail`); `nil` without one.
    private(set) var splicedAt: Int?

    /// The simulation from output 0 without `old`. With `old`, the simulation of the same take after an edit, bit for
    /// bit the one without it: `old`'s checkpoints before the first step the edit can change
    /// (`StepGrid.checkpointsKept(changingFrom:)`), the rest simulated from the last of them. That step is the first of
    /// `changed` (where what it reads besides its blocks and spring, the time map, the viewport and the cursor, can
    /// differ from what `old` read; `nil`, nowhere), of the first block that differs (`ZoomBlock.firstChangedStep`), the
    /// one after the end of the shorter output when the end moved, and 0 with another spring.
    ///
    /// After an edit of blocks alone (`changed` `nil`, the same spring and end), the simulation also takes `old`'s tail:
    /// once the camera on a checkpoint at or after the end of the blocks the edit changed (`ZoomBlock.edited`) is bit
    /// for bit the old one there, with the index of its block moved as the blocks after the edit moved, every later
    /// step reads the same as the old one did, so every later checkpoint is the old one, moved alike (`Tail`). Without
    /// such a checkpoint, the rest is simulated.
    ///
    /// `selection`: the blocks it reads (`ZoomSelection`); `old` was simulated over the same.
    init(
        document: EditDocument, timeMap: TimeMap, cursor: CursorPath, take: TakeRecord, viewport: Viewport,
        after old: ZoomSimulation?, changedFrom changed: Int?, selecting selection: ZoomSelection = .classic
    ) {
        lastStep = StepGrid.firstStep(atOrAfter: timeMap.duration)
        self.viewport = viewport
        spring = StepGrid.stable(document.zoom.spring)
        blocks = document.zoom.show
            ? ZoomBlock.blocks(of: document.zoom, take: take.id, timeMap: timeMap).filter(selection.selects) : []
        self.selection = selection
        jumps = ZoomBlock.jumps(of: blocks, lastStep: lastStep)
        takeID = take.id
        clipTakes = document.sequence.map(\.take)
        self.timeMap = timeMap
        self.cursor = cursor
        var kept: ArraySlice<ZoomCamera> = []
        var tail: Tail?
        if let old {
            var first = [changed, ZoomBlock.firstChangedStep(old.blocks, blocks)].compactMap { $0 }.min() ?? .max
            if lastStep != old.lastStep { first = min(first, min(lastStep, old.lastStep) + 1) }
            if spring != old.spring { first = 0 }
            kept = old.checkpoints.prefix(
                min(StepGrid.checkpointsKept(changingFrom: first), lastStep / StepGrid.checkpointEvery + 1))
            if changed == nil, spring == old.spring, lastStep == old.lastStep,
                let edit = ZoomBlock.edited(old.blocks, blocks)
            {
                tail = Tail(checkpoints: old.checkpoints, from: edit.end, oldAfter: edit.oldAfter, shift: edit.shift)
            }
        }
        (checkpoints, simulatedSteps, splicedAt) = simulatedCheckpoints(keeping: kept, tail: tail)
    }

    // MARK: - Queries

    /// The camera on step `s` of the grid (held to the steps of the output), placed: read from `kept` when it has the
    /// step, simulated from the checkpoint before it otherwise. The one query, whatever simulated the camera.
    func state(atStep s: Int, kept: Kept = .empty) -> ZoomPlacement {
        let step = clamped(s)
        let camera = kept.camera(atStep: step) ?? camera(atStep: step)
        return placed(logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step))
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`; read from `kept` as `state(atStep:kept:)`.
    func state(atOutput τ: Int64, kept: Kept = .empty) -> ZoomPlacement {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else { return state(atStep: s, kept: kept) }
        let (a, b) = kept.cameras(atSteps: s) ?? cameras(atSteps: s)
        return placed(
            logDepth: a.logDepth + (b.logDepth - a.logDepth) * fraction, center: a.center + (b.center - a.center) * fraction,
            atOutput: τ)
    }

    /// `state(atOutput: τ)` with the centre placed at `depth` rather than at the camera's own: the calm focus, placed at
    /// its block's depth while the camera's goes from 1 to it (plan decision 4).
    func state(atOutput τ: Int64, placedAt depth: Double) -> ZoomPlacement {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else {
            let step = clamped(s)
            let camera = camera(atStep: step)
            return placed(
                logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step), placedAt: depth)
        }
        let (a, b) = cameras(atSteps: s)
        return placed(
            logDepth: a.logDepth + (b.logDepth - a.logDepth) * fraction, center: a.center + (b.center - a.center) * fraction,
            atOutput: τ, placedAt: depth)
    }

    /// The camera on step `s` (held to `0...lastStep`), from the checkpoint before it.
    func camera(atStep s: Int) -> ZoomCamera {
        let step = clamped(s)
        var run = run(toward: step)
        while run.step < step { advance(&run) }
        return run.camera
    }

    /// The cameras on steps `s` and `s + 1` (`s` in `0..<lastStep`), from the checkpoint before them.
    private func cameras(atSteps s: Int) -> (ZoomCamera, ZoomCamera) {
        var run = run(toward: s)
        while run.step < s { advance(&run) }
        let a = run.camera
        advance(&run)
        return (a, run.camera)
    }

    /// The camera on step `s` (held to `0...lastStep`) simulated from output 0, without the checkpoints.
    func cameraSimulatedFromStart(atStep s: Int) -> ZoomCamera {
        let step = clamped(s)
        var run = startingRun()
        while run.step < step { advance(&run) }
        return run.camera
    }

    /// `state(atStep: s)` simulated from output 0, without the checkpoints.
    func stateSimulatedFromStart(atStep s: Int) -> ZoomPlacement {
        let step = clamped(s)
        let camera = cameraSimulatedFromStart(atStep: step)
        return placed(logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step))
    }

    // MARK: - Spans

    /// The cameras a span kept, from its first step on; none, every step is simulated from its checkpoint.
    struct Kept: Sendable {
        let first: Int
        let cameras: [ZoomCamera]

        static var empty: Kept { Kept(first: 0, cameras: []) }

        func camera(atStep s: Int) -> ZoomCamera? {
            cameras.indices.contains(s - first) ? cameras[s - first] : nil
        }

        /// The cameras on steps `s` and `s + 1`, when both were kept.
        func cameras(atSteps s: Int) -> (ZoomCamera, ZoomCamera)? {
            guard let a = camera(atStep: s), let b = camera(atStep: s + 1) else { return nil }
            return (a, b)
        }
    }

    /// The camera over a short span of output time: `state(atOutput:)` over the steps kept.
    struct Span: Sendable {
        let simulation: ZoomSimulation
        let kept: Kept

        func state(atOutput τ: Int64) -> ZoomPlacement {
            simulation.state(atOutput: τ, kept: kept)
        }
    }

    /// The camera from the step of `start` to the one after the step of `end` (held to the output's steps), simulated
    /// once from the checkpoint before them, every step kept: for spans of a few frames (the motion blur's subsamples).
    func span(from start: Int64, through end: Int64) -> Span {
        let low = clamped(StepGrid.position(ofOutput: min(start, end)).step)
        let high = clamped(StepGrid.position(ofOutput: max(start, end)).step + 1)
        var run = run(toward: low)
        while run.step < low { advance(&run) }
        var cameras = [run.camera]
        cameras.reserveCapacity(high - low + 1)
        while run.step < high {
            advance(&run)
            cameras.append(run.camera)
        }
        return Span(simulation: self, kept: Kept(first: low, cameras: cameras))
    }

    // MARK: - Placing

    /// `s` held to `0...lastStep`.
    private func clamped(_ s: Int) -> Int {
        min(max(s, 0), lastStep)
    }

    /// The camera drawn with `logDepth` and `center`, at output time `τ`: the centre placed at `depth`, the camera's own
    /// when `nil`.
    private func placed(
        logDepth: Double, center: SIMD2<Double>, atOutput τ: Int64, placedAt depth: Double? = nil
    ) -> ZoomPlacement {
        let logDepth = max(logDepth, 0)
        let screen = viewport.screen(at: host(atOutput: τ))
        return ZoomPlacement(
            logDepth: logDepth,
            center: StageCrop.clamp(center: center, depth: depth ?? exp(logDepth), stage: viewport.size, screen: screen))
    }

    /// The source instant of the take shown at output time `τ`; `nil` with no output, or another take's.
    private func host(atOutput τ: Int64) -> HostTime? {
        guard let shown = timeMap.source(atOutput: τ), clipTakes[shown.clip] == takeID else { return nil }
        return shown.source
    }

    // MARK: - Simulation

    /// One run of the simulation: its step, the camera on it, and where it is in the inputs.
    private struct Run: Sendable {
        var step: Int
        var camera: ZoomCamera
        /// The first block whose steps end after `step`.
        var nextBlock: Int
        var cursor: CursorPath.Reader
        /// The viewport's window that follows the cursor, read step after step; `nil` without one.
        var reframe: ReframePath.Reader?
    }

    /// What of an old simulation an edit of its blocks alone can leave as it was after it: its checkpoints from the first
    /// one at or after `from` on which the camera is the old one, `moved`.
    private struct Tail {
        /// The old simulation's, over the same steps.
        let checkpoints: [ZoomCamera]
        /// The end of the blocks the edit changed (`ZoomBlock.edited`): no checkpoint before it is compared.
        let from: Int
        /// The old index of the first block after those the edit changed, and how far it moved.
        let oldAfter: Int
        let shift: Int

        /// The old camera on checkpoint `index`, with the index of its block in the edited blocks.
        func moved(_ index: Int) -> ZoomCamera {
            var camera = checkpoints[index]
            if let block = camera.block, block >= oldAfter { camera.block = block + shift }
            return camera
        }
    }

    /// The camera on every `StepGrid.checkpointEvery`-th step to `lastStep`: `kept`, those of the first steps, then the
    /// rest simulated from the last of them (from output 0 without one), or `tail`'s from the first checkpoint on which
    /// the camera simulated is its, bit for bit; the steps simulated, and that checkpoint's step.
    private func simulatedCheckpoints(
        keeping kept: ArraySlice<ZoomCamera>, tail: Tail?
    ) -> (checkpoints: [ZoomCamera], steps: Int, splicedAt: Int?) {
        var checkpoints = Array(kept)
        guard checkpoints.count <= lastStep / StepGrid.checkpointEvery else { return (checkpoints, 0, nil) }
        var run = kept.last.map { run(atCheckpoint: kept.count - 1, camera: $0) } ?? startingRun()
        checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
        let first = run.step
        while run.step < lastStep {
            advance(&run)
            guard run.step % StepGrid.checkpointEvery == 0 else { continue }
            checkpoints.append(run.camera)
            let index = run.step / StepGrid.checkpointEvery
            if let tail, run.step >= tail.from, run.camera.hasTheBits(of: tail.moved(index)) {
                checkpoints += (index + 1..<tail.checkpoints.count).map(tail.moved)
                return (checkpoints, run.step - first, run.step)
            }
        }
        return (checkpoints, run.step - first, nil)
    }

    /// A run at rest before step 0.
    private func startingRun() -> Run {
        let center = viewport.size / 2
        let rest = ZoomCamera(
            logDepth: 0, logDepthVelocity: 0, center: center, centerVelocity: .zero, target: center, block: nil)
        return Run(
            step: -1, camera: rest, nextBlock: 0, cursor: CursorPath.Reader(cursor),
            reframe: viewport.reframe.map(ReframePath.Reader.init))
    }

    /// A run from the checkpoint at or before step `s` (in `0...lastStep`).
    private func run(toward s: Int) -> Run {
        let index = s / StepGrid.checkpointEvery
        guard index < checkpoints.count else { return startingRun() }
        return run(atCheckpoint: index, camera: checkpoints[index])
    }

    /// A run on checkpoint `index` with `camera` on it.
    private func run(atCheckpoint index: Int, camera: ZoomCamera) -> Run {
        let step = index * StepGrid.checkpointEvery
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].steps.upperBound <= step { low = mid + 1 } else { high = mid }
        }
        return Run(
            step: step, camera: camera, nextBlock: low, cursor: CursorPath.Reader(cursor),
            reframe: viewport.reframe.map(ReframePath.Reader.init))
    }

    /// Takes `run` to the next step: reads the block and, in a following one, the cursor, places the target, and moves
    /// the camera one step of 1/600 s toward it (or jumps, at an instant block's edge; of the calm blocks, with the
    /// centre held outside every block and jumping into one from there).
    private func advance(_ run: inout Run) {
        run.step += 1
        let step = run.step
        while run.nextBlock < blocks.count, blocks[run.nextBlock].steps.upperBound <= step {
            run.nextBlock += 1
        }
        let index = run.nextBlock < blocks.count && blocks[run.nextBlock].steps.lowerBound <= step ? run.nextBlock : nil
        var camera = run.camera
        let entering = index != camera.block
        var logTarget = 0.0
        var target = viewport.size / 2
        if selection == .calm, index == nil { target = camera.center }
        if let index {
            let block = blocks[index]
            let τ = StepGrid.outputTime(ofStep: step)
            let host = host(atOutput: τ)
            let screen = viewport.screen(at: host)
            logTarget = block.logDepth
            if let focus = block.focus {
                target = SIMD2(screen.x, screen.y) + focus * SIMD2(screen.width, screen.height)
            } else {
                target = camera.target
                if let host, let sample = run.cursor.sample(atStep: step),
                    let point = viewport.cursor(
                        global: sample.position, at: host, windowCenter: run.reframe?.center(atStep: step))
                {
                    target = entering
                        ? point
                        : viewport.cleared(
                            Self.deadZone(target, cursor: point, crop: viewport.size / block.depth), cursor: point,
                            depth: block.depth, atOutput: τ, host: host)
                }
            }
            target = StageCrop.clamp(center: target, depth: block.depth, stage: viewport.size, screen: screen)
        }
        let instant = (index.map { blocks[$0].instant } ?? false) || (camera.block.map { blocks[$0].instant } ?? false)
        if entering && instant {
            camera.logDepth = logTarget
            camera.logDepthVelocity = 0
            camera.center = target
            camera.centerVelocity = .zero
        } else if selection == .calm, index == nil || camera.block == nil {
            // The calm focus: outside every block the centre stays; into a block from there, it is at its target at once.
            StepGrid.spring(&camera.logDepth, &camera.logDepthVelocity, target: logTarget, spring)
            camera.center = target
            camera.centerVelocity = .zero
        } else {
            StepGrid.spring(&camera.logDepth, &camera.logDepthVelocity, target: logTarget, spring)
            StepGrid.spring(&camera.center.x, &camera.centerVelocity.x, target: target.x, spring)
            StepGrid.spring(&camera.center.y, &camera.centerVelocity.y, target: target.y, spring)
        }
        camera.target = target
        camera.block = index
        run.camera = camera
    }

    /// Where a following target goes from `target` with the cursor at `point` and a crop of `crop`: on each axis where the
    /// cursor leaves the central box (`ZoomCameraPath.deadZone` of the crop), by how far it went out and
    /// `ZoomCameraPath.followStep` of the crop more, that way.
    private static func deadZone(_ target: SIMD2<Double>, cursor point: SIMD2<Double>, crop: SIMD2<Double>) -> SIMD2<Double> {
        var moved = target
        let half = crop * (ZoomCameraPath.deadZone / 2)
        for axis in 0..<2 {
            let low = target[axis] - half[axis], high = target[axis] + half[axis]
            if point[axis] > high {
                moved[axis] += point[axis] - high + ZoomCameraPath.followStep * crop[axis]
            } else if point[axis] < low {
                moved[axis] -= low - point[axis] + ZoomCameraPath.followStep * crop[axis]
            }
        }
        return moved
    }
}
