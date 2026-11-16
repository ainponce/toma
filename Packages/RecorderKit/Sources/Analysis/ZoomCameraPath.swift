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
public struct ZoomCameraPath: Sendable {
    /// The central box of the crop the cursor moves in without moving the camera, as a fraction of the crop on each axis.
    public static let deadZone = 0.60
    /// How much farther than the cursor went out of the box the camera moves, as a fraction of the crop.
    public static let followStep = 0.15
    /// How much bigger than the camera's bubble the area the cursor counts as under it is, as a fraction of its size.
    public static let bubbleMargin = 0.08

    /// The last step simulated: the one of the end of the output.
    let lastStep: Int

    private let stageSize: SIMD2<Double>
    private let spring: SpringSpec
    /// In output order, never overlapping.
    private let blocks: [Block]
    private let takeID: String
    /// The take of each clip of the sequence.
    private let clipTakes: [String]
    private let timeMap: TimeMap
    private let stage: StagePoints
    private let cursor: CursorPath
    /// `nil` where the render draws no camera.
    private let bubble: CameraBubble?
    /// The camera on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`.
    private var checkpoints: [Camera] = []

    public init(document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, take: TakeRecord) {
        lastStep = StepGrid.firstStep(atOrAfter: timeMap.duration)
        stageSize = stage.stageSize
        spring = StepGrid.stable(document.zoom.spring)
        blocks = document.zoom.show ? Self.blocks(of: document.zoom, take: take.id, timeMap: timeMap) : []
        takeID = take.id
        clipTakes = document.sequence.map(\.take)
        self.timeMap = timeMap
        self.stage = stage
        self.cursor = cursor
        bubble = CameraBubble(document: document, take: take, timeMap: timeMap)
        checkpoints = simulatedCheckpoints()
    }

    /// The camera on step `s` of the grid (held to the steps of the output), placed.
    public func state(atStep s: Int) -> ZoomCameraState {
        state(atStep: s, from: FromCheckpoint())
    }

    /// The camera at output time `τ`: the state of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`),
    /// otherwise the two around it mixed and placed at `τ`.
    public func state(atOutput τ: Int64) -> ZoomCameraState {
        state(atOutput: τ, from: FromCheckpoint())
    }

    /// `state(atStep:)`, the camera read from `steps`: the one query, whatever simulated it.
    fileprivate func state(atStep s: Int, from steps: some ZoomCameraSteps) -> ZoomCameraState {
        let step = clamped(s)
        let camera = steps.camera(atStep: step, of: self)
        return placed(logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step))
    }

    /// `state(atOutput:)`, the cameras read from `steps`: the one query, whatever simulated them.
    fileprivate func state(atOutput τ: Int64, from steps: some ZoomCameraSteps) -> ZoomCameraState {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else { return state(atStep: s, from: steps) }
        let (a, b) = steps.cameras(atSteps: s, of: self)
        return placed(
            logDepth: a.logDepth + (b.logDepth - a.logDepth) * fraction, center: a.center + (b.center - a.center) * fraction,
            atOutput: τ)
    }

    // MARK: - Internal (the state of the simulation, for the tests)

    /// Everything the simulation carries from one step to the next.
    struct Camera: Equatable, Sendable {
        var logDepth: Double
        var logDepthVelocity: Double
        /// Not placed: the spring's.
        var center: SIMD2<Double>
        var centerVelocity: SIMD2<Double>
        /// Where the centre heads, placed: the stage's centre at rest, the focus in a fixed block, where the dead zone
        /// left it in a following one.
        var target: SIMD2<Double>
        /// The block of the step, as an index of the blocks in output order; `nil` outside them.
        var block: Int?
    }

    /// The camera on step `s` (held to `0...lastStep`), from the checkpoint before it.
    func camera(atStep s: Int) -> Camera {
        let step = clamped(s)
        var simulation = simulation(toward: step)
        while simulation.step < step { advance(&simulation) }
        return simulation.camera
    }

    /// The camera on step `s` (held to `0...lastStep`) simulated from output 0, without the checkpoints.
    func cameraSimulatedFromStart(atStep s: Int) -> Camera {
        let step = clamped(s)
        var simulation = startingSimulation()
        while simulation.step < step { advance(&simulation) }
        return simulation.camera
    }

    /// `state(atStep: s)` simulated from output 0, without the checkpoints.
    func stateSimulatedFromStart(atStep s: Int) -> ZoomCameraState {
        let step = clamped(s)
        let camera = cameraSimulatedFromStart(atStep: step)
        return placed(logDepth: camera.logDepth, center: camera.center, atOutput: StepGrid.outputTime(ofStep: step))
    }

    // MARK: - Inputs

    /// A block, on the grid.
    private struct Block: Sendable {
        /// The steps whose output time is in its output range.
        var steps: Range<Int>
        /// From 1 to 16.
        var depth: Double
        var logDepth: Double
        /// Fractions of the screen's rect; `nil`, it follows the cursor.
        var focus: SIMD2<Double>?
        var instant: Bool
    }

    /// Where a simulation is: its step, the camera on it, and where it is in the inputs.
    private struct Simulation: Sendable {
        var step: Int
        var camera: Camera
        /// The first block whose steps end after `step`.
        var nextBlock: Int
        var cursor: CursorPath.Reader
    }

    /// Two blocks at most this far apart in output time touch.
    private static let touching: Int64 = 1
    private static let depthRange = 1.0...16.0
    /// A bubble whose centre is this close to the output's centre on an axis is on neither side of it (one in the
    /// middle of an edge).
    private static let centred = 1e-9
    /// The bubble never moves the cursor nearer the output's edges than this, in stage units: the camera's own margin
    /// (`CameraStyle.marginFraction` of the height), so even the biggest bubble on the side of a 9:16 output leaves it in
    /// the frame, and out from under the bubble.
    static let frameMargin = CameraStyle.marginFraction

    /// The take's blocks of `zoom` on the grid, in output order (the document's among those that start together).
    private static func blocks(of zoom: ZoomPlan, take: String, timeMap: TimeMap) -> [Block] {
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
            return Block(steps: steps, depth: depth, logDepth: log(depth), focus: focus, instant: block.region.instant)
        }
    }

    /// `value` read from 0 to 1, 0.5 if it is not a number.
    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0.5 : min(max(value, 0), 1)
    }

    // MARK: - Simulation

    /// `s` held to `0...lastStep`.
    private func clamped(_ s: Int) -> Int {
        min(max(s, 0), lastStep)
    }

    /// The camera drawn with `logDepth` and `center`, at output time `τ`.
    private func placed(logDepth: Double, center: SIMD2<Double>, atOutput τ: Int64) -> ZoomCameraState {
        let logDepth = max(logDepth, 0)
        let screen = screen(at: host(atOutput: τ))
        return ZoomCameraState(
            logDepth: logDepth, center: StageCrop.clamp(center: center, depth: exp(logDepth), stage: stageSize, screen: screen))
    }

    /// The source instant of the take shown at output time `τ`; `nil` with no output, or another take's.
    private func host(atOutput τ: Int64) -> HostTime? {
        guard let shown = timeMap.source(atOutput: τ), clipTakes[shown.clip] == takeID else { return nil }
        return shown.source
    }

    /// The rect of the screen shown at `host`: the stage itself where none is.
    private func screen(at host: HostTime?) -> Rect {
        host.flatMap(stage.screenRect(at:)) ?? Rect(x: 0, y: 0, width: stageSize.x, height: stageSize.y)
    }

    /// The camera on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`, simulated from output 0.
    private func simulatedCheckpoints() -> [Camera] {
        var simulation = startingSimulation()
        var checkpoints: [Camera] = []
        checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
        while simulation.step < lastStep {
            advance(&simulation)
            if simulation.step % StepGrid.checkpointEvery == 0 { checkpoints.append(simulation.camera) }
        }
        return checkpoints
    }

    /// A simulation at rest before step 0.
    private func startingSimulation() -> Simulation {
        let rest = Camera(
            logDepth: 0, logDepthVelocity: 0, center: stageSize / 2, centerVelocity: .zero, target: stageSize / 2, block: nil)
        return Simulation(step: -1, camera: rest, nextBlock: 0, cursor: CursorPath.Reader(cursor))
    }

    /// A simulation from the checkpoint at or before step `s` (in `0...lastStep`).
    private func simulation(toward s: Int) -> Simulation {
        let index = s / StepGrid.checkpointEvery
        guard index < checkpoints.count else { return startingSimulation() }
        let step = index * StepGrid.checkpointEvery
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].steps.upperBound <= step { low = mid + 1 } else { high = mid }
        }
        return Simulation(step: step, camera: checkpoints[index], nextBlock: low, cursor: CursorPath.Reader(cursor))
    }

    /// Takes `simulation` to the next step: reads the block and, in a following one, the cursor, places the target,
    /// and moves the camera one step of 1/600 s toward it (or jumps, at an instant block's edge).
    private func advance(_ simulation: inout Simulation) {
        simulation.step += 1
        let step = simulation.step
        while simulation.nextBlock < blocks.count, blocks[simulation.nextBlock].steps.upperBound <= step {
            simulation.nextBlock += 1
        }
        let index = simulation.nextBlock < blocks.count && blocks[simulation.nextBlock].steps.lowerBound <= step
            ? simulation.nextBlock : nil
        var camera = simulation.camera
        let entering = index != camera.block
        var logTarget = 0.0
        var target = stageSize / 2
        if let index {
            let block = blocks[index]
            let τ = StepGrid.outputTime(ofStep: step)
            let host = host(atOutput: τ)
            let screen = screen(at: host)
            logTarget = block.logDepth
            if let focus = block.focus {
                target = SIMD2(screen.x, screen.y) + focus * SIMD2(screen.width, screen.height)
            } else {
                target = camera.target
                if let host, let sample = simulation.cursor.sample(atStep: step),
                    let point = stage.stagePoint(global: sample.position, at: host)
                {
                    target = entering ? point : followed(target, cursor: point, depth: block.depth, atOutput: τ, host: host)
                }
            }
            target = StageCrop.clamp(center: target, depth: block.depth, stage: stageSize, screen: screen)
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
        simulation.camera = camera
    }

    // MARK: - Following the cursor

    /// Where the target of a following block of `depth` goes from `target` with the cursor at stage point `point`: the
    /// dead zone, then the bubble.
    private func followed(
        _ target: SIMD2<Double>, cursor point: SIMD2<Double>, depth: Double, atOutput τ: Int64, host: HostTime
    ) -> SIMD2<Double> {
        let crop = stageSize / depth
        var moved = target
        let half = crop * (Self.deadZone / 2)
        for axis in 0..<2 {
            let low = target[axis] - half[axis], high = target[axis] + half[axis]
            if point[axis] > high {
                moved[axis] += point[axis] - high + Self.followStep * crop[axis]
            } else if point[axis] < low {
                moved[axis] -= low - point[axis] + Self.followStep * crop[axis]
            }
        }
        guard let bubble = bubbleRect(atOutput: τ, host: host) else { return moved }
        return cleared(moved, of: bubble, cursor: point, depth: depth)
    }

    /// The camera's bubble at output time `τ` (source instant `host`), grown by `bubbleMargin`; `nil` where there is
    /// none.
    private func bubbleRect(atOutput τ: Int64, host: HostTime) -> Rect? {
        guard let rect = bubble?.frame(atOutput: τ, host: host, output: stageSize)?.rect else { return nil }
        let grow = Self.bubbleMargin / 2
        return Rect(
            x: rect.x - rect.width * grow, y: rect.y - rect.height * grow, width: rect.width * (1 + Self.bubbleMargin),
            height: rect.height * (1 + Self.bubbleMargin))
    }

    /// `target` with the cursor at stage point `point` moved out from under `bubble` (see the type's notes).
    private func cleared(
        _ target: SIMD2<Double>, of bubble: Rect, cursor point: SIMD2<Double>, depth: Double
    ) -> SIMD2<Double> {
        // The cursor in the output, as the crop the camera heads to shows it.
        let shown = (point - target) * depth + stageSize / 2
        let low = SIMD2(bubble.x, bubble.y), high = SIMD2(bubble.x + bubble.width, bubble.y + bubble.height)
        guard shown.x >= low.x, shown.x <= high.x, shown.y >= low.y, shown.y <= high.y else { return target }
        var best: (axis: Int, need: Double, side: Double)?
        for axis in 0..<2 {
            let side = (low[axis] + high[axis]) / 2 - stageSize[axis] / 2
            guard abs(side) > Self.centred else { continue }
            let need = side > 0 ? shown[axis] - low[axis] : high[axis] - shown[axis]
            if best.map({ need < $0.need }) ?? true { best = (axis, need, side) }
        }
        guard let best else { return target }
        // Where the cursor goes in the output on that axis: `followStep` of the output past the bubble's edge, but never
        // nearer the output's edge than `frameMargin` (a big bubble on the side of a narrow output), nor back.
        let axis = best.axis
        let edge = stageSize[axis] * Self.followStep
        let goal = best.side > 0
            ? min(shown[axis], max(low[axis] - edge, Self.frameMargin))
            : max(shown[axis], min(high[axis] + edge, stageSize[axis] - Self.frameMargin))
        var moved = target
        moved[axis] += (shown[axis] - goal) / depth
        return moved
    }
}

/// Where `ZoomCameraPath`'s queries read the simulated camera from: a simulation from the checkpoint before the step
/// asked for (`FromCheckpoint`), or the steps a `Span` kept. Every source gives the same bits.
private protocol ZoomCameraSteps {
    /// The camera on step `s`, in `0...lastStep`.
    func camera(atStep s: Int, of path: ZoomCameraPath) -> ZoomCameraPath.Camera
    /// The cameras on steps `s` and `s + 1`, `s` in `0..<lastStep`.
    func cameras(atSteps s: Int, of path: ZoomCameraPath) -> (ZoomCameraPath.Camera, ZoomCameraPath.Camera)
}

extension ZoomCameraPath {
    /// The camera simulated from the checkpoint before the step.
    fileprivate struct FromCheckpoint: ZoomCameraSteps {
        func camera(atStep s: Int, of path: ZoomCameraPath) -> Camera {
            path.camera(atStep: s)
        }

        func cameras(atSteps s: Int, of path: ZoomCameraPath) -> (Camera, Camera) {
            var simulation = path.simulation(toward: s)
            while simulation.step < s { path.advance(&simulation) }
            let a = simulation.camera
            path.advance(&simulation)
            return (a, simulation.camera)
        }
    }

    /// The cameras a span kept, from its first step on; the others simulated from their checkpoint.
    fileprivate struct Kept: ZoomCameraSteps {
        let first: Int
        let cameras: [Camera]

        func camera(atStep s: Int, of path: ZoomCameraPath) -> Camera {
            kept(s) ?? FromCheckpoint().camera(atStep: s, of: path)
        }

        func cameras(atSteps s: Int, of path: ZoomCameraPath) -> (Camera, Camera) {
            guard let a = kept(s), let b = kept(s + 1) else { return FromCheckpoint().cameras(atSteps: s, of: path) }
            return (a, b)
        }

        private func kept(_ s: Int) -> Camera? {
            cameras.indices.contains(s - first) ? cameras[s - first] : nil
        }
    }

    /// The camera over a short span of output time, from one simulation (the motion blur's subsamples, design §7.4):
    /// `state(atOutput:)`, the same query over the steps kept, so with the same bits at every time of the span, without
    /// simulating from a checkpoint for each.
    public struct Span: Sendable {
        private let path: ZoomCameraPath
        private let steps: Kept

        fileprivate init(path: ZoomCameraPath, steps: Kept) {
            self.path = path
            self.steps = steps
        }

        /// `state(atOutput: τ)`: from the steps kept for a time of the span, simulated on its own otherwise.
        public func state(atOutput τ: Int64) -> ZoomCameraState {
            path.state(atOutput: τ, from: steps)
        }
    }

    /// The camera from the step of `start` to the one after the step of `end` (held to the output's steps), simulated
    /// once from the checkpoint before them, every step kept: for spans of a few frames.
    public func span(from start: Int64, through end: Int64) -> Span {
        let low = clamped(StepGrid.position(ofOutput: min(start, end)).step)
        let high = clamped(StepGrid.position(ofOutput: max(start, end)).step + 1)
        var simulation = simulation(toward: low)
        while simulation.step < low { advance(&simulation) }
        var cameras = [simulation.camera]
        cameras.reserveCapacity(high - low + 1)
        while simulation.step < high {
            advance(&simulation)
            cameras.append(simulation.camera)
        }
        return Span(path: self, steps: Kept(first: low, cameras: cameras))
    }
}
