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
///   end mapped back to the output can be 1 ns short of the next one's start (plan decision 16).
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
///     segment on. The cursor is `CursorPath`'s on the step, read before the camera moves (design §8.6), at its stage
///     point (`StagePoints.stagePoint(global:at:)`); without one, the target stays.
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

    public init(document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord) {
        simulation = ZoomSimulation(
            document: document, timeMap: timeMap, cursor: cursor, take: take,
            viewport: StageViewport(stage: stage, bubble: CameraBubble(document: document, take: take, timeMap: timeMap)))
    }

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
}

extension ZoomCameraState {
    /// A camera `ZoomSimulation` placed over the stage.
    fileprivate init(_ placed: ZoomPlacement) {
        self.init(logDepth: placed.logDepth, center: placed.center)
    }
}

/// The stage, in stage units: what `ZoomCameraPath` looks over. A fixed focus is measured in the screen's rect and the
/// crop keeps to it (the whole stage where none is shown); a following target keeps the cursor out from under the
/// camera's bubble.
struct StageViewport: ZoomViewport {
    let size: SIMD2<Double>
    private let stage: StagePoints
    /// `nil` where the render draws no camera.
    private let bubble: CameraBubble?

    /// A bubble whose centre is this close to the output's centre on an axis is on neither side of it (one in the
    /// middle of an edge).
    private static let centred = 1e-9

    init(stage: StagePoints, bubble: CameraBubble?) {
        size = stage.stageSize
        self.stage = stage
        self.bubble = bubble
    }

    func screen(at host: HostTime?) -> Rect {
        host.flatMap(stage.screenRect(at:)) ?? Rect(x: 0, y: 0, width: size.x, height: size.y)
    }

    func cursor(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>? {
        stage.stagePoint(global: global, at: host)
    }

    /// The bubble, applied after the dead zone (see `ZoomCameraPath`'s notes).
    func cleared(
        _ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime
    ) -> SIMD2<Double> {
        guard let bubble = bubbleRect(atOutput: τ, host: host) else { return target }
        return cleared(target, of: bubble, cursor: point, depth: depth)
    }

    /// The camera's bubble at output time `τ` (source instant `host`), grown by `bubbleMargin`; `nil` where there is
    /// none.
    private func bubbleRect(atOutput τ: Int64, host: HostTime) -> Rect? {
        guard let rect = bubble?.frame(atOutput: τ, host: host, output: size)?.rect else { return nil }
        let grow = ZoomCameraPath.bubbleMargin / 2
        return Rect(
            x: rect.x - rect.width * grow, y: rect.y - rect.height * grow, width: rect.width * (1 + ZoomCameraPath.bubbleMargin),
            height: rect.height * (1 + ZoomCameraPath.bubbleMargin))
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
    /// The rect of the screen shown at source instant `host` (`nil`: no instant of the take is shown), in the viewport's
    /// units: what a fixed focus is a fraction of, and what the crop keeps to where it fits in it.
    func screen(at host: HostTime?) -> Rect
    /// Where the cursor at `global` (global points) is at source instant `host`, in the viewport's units; `nil` off the
    /// screen shown, as `StagePoints.stagePoint(global:at:)`.
    func cursor(global: SIMD2<Double>, at host: HostTime) -> SIMD2<Double>?
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
    /// Where the centre heads, placed: the viewport's centre at rest, the focus in a fixed block, where the dead zone
    /// left it in a following one.
    var target: SIMD2<Double>
    /// The block of the step, as an index of the blocks in output order; `nil` outside them.
    var block: Int?
}

/// A zoom camera drawn: its depth (`u = ln z`, at least 0) and the centre of its crop, placed, in its viewport's units.
struct ZoomPlacement: Equatable, Sendable {
    var logDepth: Double
    var center: SIMD2<Double>
}

/// A zoom block of the take, on the grid.
private struct ZoomBlock: Sendable {
    /// The steps whose output time is in its output range.
    var steps: Range<Int>
    /// From 1 to 16.
    var depth: Double
    var logDepth: Double
    /// Fractions of the screen's rect; `nil`, it follows the cursor.
    var focus: SIMD2<Double>?
    var instant: Bool

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
            return ZoomBlock(steps: steps, depth: depth, logDepth: log(depth), focus: focus, instant: block.region.instant)
        }
    }

    /// `value` read from 0 to 1, 0.5 if it is not a number.
    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0.5 : min(max(value, 0), 1)
    }
}

/// A zoom camera simulated on `StepGrid` from output 0 over `Viewport` (design §8.3 and §8.6, 1c design §5.4), what
/// `ZoomCameraPath` and `CardZoomPath` share; `ZoomCameraPath`'s notes say it in the stage's units.
///
/// - The blocks are the take's `zoom.regions` on the grid (none with `zoom.show` off: always at rest).
/// - The target, read on each step: outside every block, rest (`u` 0, the viewport's centre); in a block, `u = ln` of
///   its depth and a centre placed with `StageCrop` at that depth over the viewport's screen at the step's source
///   instant: a fixed focus is its point of that screen; a following one is, on entering the block, the cursor's point
///   (`CursorPath`'s on the step, read before the camera moves), then the dead zone (`ZoomCameraPath.deadZone` of the
///   crop it heads to, steps of `followStep` of it) and what the viewport clears (`ZoomViewport.cleared`).
/// - The motion: `zoom.spring` (`StepGrid.spring`, through `StepGrid.stable(_:)`) for `u` and each axis of the centre;
///   on entering or leaving an `instant` block, a jump to the target with velocity 0.
/// - Drawn: `u` at least 0 and the centre placed with `StageCrop` over the viewport's screen of the instant.
///
/// The whole state is kept every `StepGrid.checkpointEvery` steps, and every query reads a step from its checkpoint (or
/// from the steps a span kept), with the same bits as from output 0: a run from a checkpoint is a pure function of it
/// and the inputs, so the checkpoints after one can be simulated again from it alone.
struct ZoomSimulation<Viewport: ZoomViewport>: Sendable {
    /// The last step simulated: the one of the end of the output.
    let lastStep: Int
    private let viewport: Viewport
    private let spring: SpringSpec
    /// In output order, never overlapping.
    private let blocks: [ZoomBlock]
    private let takeID: String
    /// The take of each clip of the sequence.
    private let clipTakes: [String]
    private let timeMap: TimeMap
    private let cursor: CursorPath
    /// The camera on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`.
    private var checkpoints: [ZoomCamera] = []

    init(document: EditDocument, timeMap: TimeMap, cursor: CursorPath, take: TakeRecord, viewport: Viewport) {
        lastStep = StepGrid.firstStep(atOrAfter: timeMap.duration)
        self.viewport = viewport
        spring = StepGrid.stable(document.zoom.spring)
        blocks = document.zoom.show ? ZoomBlock.blocks(of: document.zoom, take: take.id, timeMap: timeMap) : []
        takeID = take.id
        clipTakes = document.sequence.map(\.take)
        self.timeMap = timeMap
        self.cursor = cursor
        checkpoints = simulatedCheckpoints(from: startingRun())
    }

    // MARK: - Queries

    /// The camera on step `s` of the grid (held to the steps of the output), placed: read from `kept` when it has the
    /// step, simulated from the checkpoint before it otherwise. The one query, whatever simulated the camera.
    func state(atStep s: Int, kept: Kept = .none) -> ZoomPlacement {
        let step = clamped(s)
        let camera = kept.camera(atStep: step) ?? camera(atStep: step)
        return placed(logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step))
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`; read from `kept` as `state(atStep:kept:)`.
    func state(atOutput τ: Int64, kept: Kept = .none) -> ZoomPlacement {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else { return state(atStep: s, kept: kept) }
        let (a, b) = kept.cameras(atSteps: s) ?? cameras(atSteps: s)
        return placed(
            logDepth: a.logDepth + (b.logDepth - a.logDepth) * fraction, center: a.center + (b.center - a.center) * fraction,
            atOutput: τ)
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

        static var none: Kept { Kept(first: 0, cameras: []) }

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

    /// The camera drawn with `logDepth` and `center`, at output time `τ`.
    private func placed(logDepth: Double, center: SIMD2<Double>, atOutput τ: Int64) -> ZoomPlacement {
        let logDepth = max(logDepth, 0)
        let screen = viewport.screen(at: host(atOutput: τ))
        return ZoomPlacement(
            logDepth: logDepth,
            center: StageCrop.clamp(center: center, depth: exp(logDepth), stage: viewport.size, screen: screen))
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
    }

    /// The camera on every `StepGrid.checkpointEvery`-th step after `run`'s, to `lastStep`.
    private func simulatedCheckpoints(from run: Run) -> [ZoomCamera] {
        var run = run
        var checkpoints: [ZoomCamera] = []
        checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
        while run.step < lastStep {
            advance(&run)
            if run.step % StepGrid.checkpointEvery == 0 { checkpoints.append(run.camera) }
        }
        return checkpoints
    }

    /// A run at rest before step 0.
    private func startingRun() -> Run {
        let center = viewport.size / 2
        let rest = ZoomCamera(
            logDepth: 0, logDepthVelocity: 0, center: center, centerVelocity: .zero, target: center, block: nil)
        return Run(step: -1, camera: rest, nextBlock: 0, cursor: CursorPath.Reader(cursor))
    }

    /// A run from the checkpoint at or before step `s` (in `0...lastStep`).
    private func run(toward s: Int) -> Run {
        let index = s / StepGrid.checkpointEvery
        guard index < checkpoints.count else { return startingRun() }
        let step = index * StepGrid.checkpointEvery
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].steps.upperBound <= step { low = mid + 1 } else { high = mid }
        }
        return Run(step: step, camera: checkpoints[index], nextBlock: low, cursor: CursorPath.Reader(cursor))
    }

    /// Takes `run` to the next step: reads the block and, in a following one, the cursor, places the target, and moves
    /// the camera one step of 1/600 s toward it (or jumps, at an instant block's edge).
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
                    let point = viewport.cursor(global: sample.position, at: host)
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
