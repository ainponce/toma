// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Follow the Cursor (phase 2 design §6.5, plan 2b decision 9), `reframe-1`: where the window a reframed screen shows of
/// its region is, simulated in output time on the grid of 600 Hz of the motion paths (`StepGrid`).
///
/// A view is reframed where the document follows the cursor (`style.reframe` `followCursor`) and its region is wider than
/// the room inside the padding (`StagePoints.isReframed(_:)`): the screen then fills the room with a window of the
/// region as tall as it and as wide as the room's aspect allows, `w = room's aspect / region's aspect` of the region's
/// width (`part(of:atOutput:stage:)`). The path is that window's horizontal centre, in fractions of the region:
///
/// - **What a step reads** is the view shown at its source instant (`StagePoints.shownScreen(at:)`, in a clip of the
///   take), worked out once where it can change (`readings`): at each clip's start and at each of the take's screen
///   changes and geometry events in a clip. Where the view is not reframed, a window is not on screen, or another take is
///   shown, nothing moves the target.
/// - **The cursor** is `CursorPath`'s on the step (the smoothed one, `sample(atStep:)`'s position, read step after step
///   from its checkpoint, `CursorPath.PositionReader`), in fractions of the region; off the region, it moves nothing.
/// - **The target**: while the cursor is within `deadZone` (25 %) of `w` of it, it stays; once the cursor is farther,
///   the target goes to where the cursor is on the edge of that zone. It is held to `[w / 2, 1 − w / 2]`, so the window
///   never leaves the region.
/// - **The centre** follows the target with `spring` (critically damped, a response of 0.9 s, `StepGrid.spring`), in
///   output time: through a cut, a clip's border or a change of screen it goes on as the zoom's cameras do (design
///   §8.6), and never jumps. It starts at rest on the first cursor the output shows in a reframed view (held to
///   `[w / 2, 1 − w / 2]`), and is there on every step before it; at 0.5 without one.
///
/// The whole state is kept every `StepGrid.checkpointEvery` steps, so a query simulates at most 600 steps from the
/// checkpoint before it, with the same bits as from output 0 (`Reader` reads it step after step, for the zoom cameras).
public struct ReframePath: Sendable {
    public static let id = "reframe-1"
    /// How much wider (in aspect) than the output the content must be for Follow the Cursor to be offered.
    public static let offeredFactor = 1.3
    /// How far from the target the cursor goes before it moves it, as a fraction of the window's width: the dead zone is
    /// the target ± this.
    public static let deadZone = 0.25
    /// The centre's spring.
    public static let spring = SpringSpec(damping: 1, response: 0.9)

    /// The last step simulated: the one of the end of the output.
    let lastStep: Int
    /// What the steps read: in order of step, one per step at most, each different from the one before it.
    private let readings: [Reading]
    private let cursor: CursorPath
    /// Where the centre is before the path starts (on the first cursor of a reframed view), and forever without one.
    private(set) var start = ReframePath.unstarted
    /// The step the path starts on; `nil` without a cursor in a reframed view.
    private(set) var startStep: Int?
    /// The state on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`.
    private(set) var checkpoints: [State] = []
    /// The steps simulated to build `checkpoints`.
    private(set) var simulatedSteps = 0

    /// Whether Follow the Cursor is offered for content of `contentRatio` (width over height; `StagePoints.contentRatio`)
    /// in an output of `outputRatio`: the content at least `offeredFactor` times as wide, in aspect, as the output. Never
    /// without a content ratio; never for `auto` either, whose output has the content's ratio or 16:9 within 1 % of it.
    public static func isOffered(contentRatio: Double?, outputRatio: Double) -> Bool {
        guard let contentRatio, contentRatio.isFinite, contentRatio > 0, outputRatio.isFinite, outputRatio > 0 else {
            return false
        }
        return contentRatio / outputRatio >= offeredFactor * (1 - 1e-12)
    }

    /// `nil` unless the document follows the cursor (`style.reframe` `followCursor`).
    public init?(document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath) {
        self.init(document: document, timeMap: timeMap, stage: stage, cursor: cursor, after: nil, changedFrom: nil)
    }

    /// The path of the same take after an edit (`MotionPaths.init(take:events:document:after:)`): bit for bit
    /// `init(document:timeMap:stage:cursor:)`'s. With `old`, built over the same stage, its checkpoints before the first
    /// step the edit can change (`StepGrid.checkpointsKept(changingFrom:)`) are kept and the rest simulated from the last
    /// of them; `changed` is the first step at which what it reads (the time map and the cursor) can differ, `nil` where
    /// neither does. Without `old`, simulated from output 0.
    init?(
        document: EditDocument, timeMap: TimeMap, stage: StagePoints, cursor: CursorPath, after old: ReframePath?,
        changedFrom changed: Int?
    ) {
        guard document.style.reframe == .followCursor else { return nil }
        lastStep = StepGrid.firstStep(atOrAfter: timeMap.duration)
        readings = Self.readings(document: document, timeMap: timeMap, stage: stage)
        self.cursor = cursor
        var kept: ArraySlice<State> = []
        var started: (step: Int, center: Double)?
        if let old {
            var first = changed ?? .max
            if lastStep != old.lastStep { first = min(first, min(lastStep, old.lastStep) + 1) }
            kept = old.checkpoints.prefix(
                min(StepGrid.checkpointsKept(changingFrom: first), lastStep / StepGrid.checkpointEvery + 1))
            // Started on a step before the first the edit can change, it starts there as before. Otherwise every
            // checkpoint kept is before the start, and the steps simulated after them find it.
            if let step = old.startStep, step < first { started = (step, old.start) }
        }
        let simulated = simulatedCheckpoints(keeping: kept)
        (checkpoints, simulatedSteps) = (simulated.checkpoints, simulated.steps)
        if let found = started ?? simulated.start { (startStep, start) = (found.step, found.center) }
    }

    // MARK: - Queries

    /// The window's centre on step `s` of the grid (held to the steps of the output), in fractions of the region, from
    /// the checkpoint before it.
    public func center(atStep s: Int) -> Double {
        let step = clamped(s)
        var run = run(toward: step)
        while run.step < step { advance(&run) }
        return center(of: run.state)
    }

    /// The window's centre at output time `τ`: the one of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`,
    /// as every frame of the output is), otherwise the two around it mixed.
    public func center(atOutput τ: Int64) -> Double {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else { return center(atStep: s) }
        var run = run(toward: s)
        while run.step < s { advance(&run) }
        let a = center(of: run.state)
        advance(&run)
        return a + (center(of: run.state) - a) * fraction
    }

    /// The part of `view`'s region a reframed screen shows at output time `τ`, in fractions of the region: as tall as it,
    /// `w` of its width (`StagePoints.reframedWidth(of:)`) about the centre at `τ`, moved to stay inside the region. `nil`
    /// when `view` is not reframed (`StagePoints.isReframed(_:)`): it is shown whole.
    public func part(of view: ShownScreen, atOutput τ: Int64, stage: StagePoints) -> Rect? {
        guard let width = stage.reframedWidth(of: view) else { return nil }
        return Self.part(center: center(atOutput: τ), width: width)
    }

    /// The window of `width` (a fraction of the region's, below 1) about `center`, moved to stay inside the region.
    static func part(center: Double, width: Double) -> Rect {
        Rect(x: min(max(center - width / 2, 0), 1 - width), y: 0, width: width, height: 1)
    }

    // MARK: - Internal (the simulation, for the tests)

    /// The centre, its velocity and the target it goes to, on a step; before the path starts (`started` false), none of
    /// them is read.
    struct State: Equatable, Sendable {
        var center: Double
        var velocity: Double
        var target: Double
        var started: Bool
    }

    /// The state on step `s` (held to `0...lastStep`), from the checkpoint before it.
    func state(atStep s: Int) -> State {
        let step = clamped(s)
        var run = run(toward: step)
        while run.step < step { advance(&run) }
        return run.state
    }

    /// The centre on every step from 0 to `s` (held to `0...lastStep`), simulated from output 0 without the checkpoints:
    /// the one at index `n` is step `n`'s.
    func centersSimulatedFromStart(through s: Int) -> [Double] {
        let last = clamped(s)
        var run = startingRun()
        var centers: [Double] = []
        centers.reserveCapacity(last + 1)
        while run.step < last {
            advance(&run)
            centers.append(center(of: run.state))
        }
        return centers
    }

    /// The reframed view a step reads from `step` on, until the next reading: its region and the window's width.
    struct Reading: Equatable, Sendable {
        var step: Int
        /// `nil` where nothing moves the target: no reframed view on screen.
        var window: Window?
    }

    /// A reframed view, as the simulation reads it.
    struct Window: Equatable, Sendable {
        /// In global points.
        var region: Rect
        /// `StagePoints.reframedWidth(of:)`.
        var width: Double
        /// The region's right and bottom edges, `x + width` and `y + height`, as `CursorGeometry.contains` has them.
        private var right: Double
        private var bottom: Double

        init(region: Rect, width: Double) {
            self.region = region
            self.width = width
            right = region.x + region.width
            bottom = region.y + region.height
        }

        /// Where the cursor at `point` (global points) is across the region, `CursorGeometry.normalized`'s `x`, when it is
        /// in the region by the rule of `CursorGeometry.contains` (its far edges out); `nil` otherwise. The same bits,
        /// worked out here because the simulation reads it on every step.
        func across(_ point: SIMD2<Double>) -> Double? {
            guard point.x >= region.x, point.x < right, point.y >= region.y, point.y < bottom else { return nil }
            return (point.x - region.x) / region.width
        }
    }

    /// The window's centre read step after step, as a zoom camera reads it (design §8.6: on each step, first the cursor,
    /// then the window, then the camera): `center(atStep:)`, the same simulation going forward with the steps asked for,
    /// from the step asked for before when the next one is not before it and that step is not before the next one's
    /// checkpoint, from that checkpoint otherwise.
    struct Reader: Sendable {
        private let path: ReframePath
        private var run: Run?

        init(_ path: ReframePath) {
            self.path = path
        }

        /// `center(atStep: s)`.
        mutating func center(atStep s: Int) -> Double {
            let step = path.clamped(s)
            let checkpoint = step / StepGrid.checkpointEvery * StepGrid.checkpointEvery
            var current = run.flatMap { $0.step <= step && $0.step >= checkpoint ? $0 : nil } ?? path.run(toward: step)
            while current.step < step { path.advance(&current) }
            run = current
            return path.center(of: current.state)
        }
    }

    // MARK: - Simulation

    /// `start` while it is not known, and without a cursor in a reframed view.
    private static let unstarted = 0.5

    /// One run of the simulation: its step, the state on it, the view it reads and the first reading after it, and the
    /// cursor read step after step.
    private struct Run: Sendable {
        var step: Int
        var state: State
        var window: Window?
        var next: Int
        var cursor: CursorPath.PositionReader
    }

    /// `s` held to `0...lastStep`.
    private func clamped(_ s: Int) -> Int {
        min(max(s, 0), lastStep)
    }

    /// The centre drawn with `state`: `start` before the path starts.
    private func center(of state: State) -> Double {
        state.started ? state.center : start
    }

    /// A run before step 0, not started.
    private func startingRun() -> Run {
        let rest = Self.unstarted
        return Run(
            step: -1, state: State(center: rest, velocity: 0, target: rest, started: false), window: nil, next: 0,
            cursor: CursorPath.PositionReader(cursor))
    }

    /// A run from the checkpoint at or before step `s` (in `0...lastStep`).
    private func run(toward s: Int) -> Run {
        let index = s / StepGrid.checkpointEvery
        guard index < checkpoints.count else { return startingRun() }
        return run(atCheckpoint: index, state: checkpoints[index])
    }

    /// A run on checkpoint `index` with `state` on it.
    private func run(atCheckpoint index: Int, state: State) -> Run {
        let step = index * StepGrid.checkpointEvery
        let next = Self.partitionPoint(readings.count) { readings[$0].step <= step }
        return Run(
            step: step, state: state, window: next > 0 ? readings[next - 1].window : nil, next: next,
            cursor: CursorPath.PositionReader(cursor))
    }

    /// The state on every `StepGrid.checkpointEvery`-th step to `lastStep`: `kept`, those of the first steps, then the
    /// rest simulated from the last of them (from output 0 without one); the steps simulated, and the step and centre the
    /// path started on in them (`nil` when it did not start there).
    private func simulatedCheckpoints(
        keeping kept: ArraySlice<State>
    ) -> (checkpoints: [State], steps: Int, start: (step: Int, center: Double)?) {
        var checkpoints = Array(kept)
        guard checkpoints.count <= lastStep / StepGrid.checkpointEvery else { return (checkpoints, 0, nil) }
        var run = kept.last.map { run(atCheckpoint: kept.count - 1, state: $0) } ?? startingRun()
        checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
        let first = run.step
        var start: (step: Int, center: Double)?
        var started = run.state.started
        while run.step < lastStep {
            advance(&run)
            if !started, run.state.started {
                started = true
                start = (run.step, run.state.center)
            }
            if run.step % StepGrid.checkpointEvery == 0 { checkpoints.append(run.state) }
        }
        return (checkpoints, run.step - first, start)
    }

    /// Takes `run` to the next step: reads the view when it changes there and, in a reframed one, the cursor; moves the
    /// target when the cursor is out of the dead zone around it, holds it to the window's room, and moves the centre one
    /// step of 1/600 s toward it. Before the path starts, the first cursor in a reframed view starts it, at rest.
    private func advance(_ run: inout Run) {
        run.step += 1
        while run.next < readings.count, readings[run.next].step <= run.step {
            run.window = readings[run.next].window
            run.next += 1
        }
        guard let window = run.window else {
            // Nothing to follow: the centre goes on toward the target it has.
            if run.state.started { StepGrid.spring(&run.state.center, &run.state.velocity, target: run.state.target, Self.spring) }
            return
        }
        var target = run.state.target
        if let position = run.cursor.position(atStep: run.step) {
            if let x = window.across(position) {
                guard run.state.started else {
                    let start = Self.held(x, width: window.width)
                    run.state = State(center: start, velocity: 0, target: start, started: true)
                    return
                }
                let zone = Self.deadZone * window.width
                if x > target + zone {
                    target = x - zone
                } else if x < target - zone {
                    target = x + zone
                }
            }
        }
        guard run.state.started else { return }
        target = Self.held(target, width: window.width)
        run.state.target = target
        StepGrid.spring(&run.state.center, &run.state.velocity, target: target, Self.spring)
    }

    /// `x` held to `[width / 2, 1 − width / 2]`: where the centre of a window of `width` can be.
    private static func held(_ x: Double, width: Double) -> Double {
        min(max(x, width / 2), 1 - width / 2)
    }

    // MARK: - What the steps read

    /// What the steps read over the output (`Reading`): the view shown at the first step of each clip and, in a clip of
    /// the take, around the step of each of the take's view changes in it (`StagePoints.viewChanges`; the first step at
    /// which a clip shows a change's instant is that of its output time or one beside it, at any speed: the two are a few
    /// nanoseconds apart), read at each of those steps (`window(atStep:)`): between two of them the view is the same.
    /// Only where it changes.
    private static func readings(document: EditDocument, timeMap: TimeMap, stage: StagePoints) -> [Reading] {
        let changes = stage.viewChanges
        let take = stage.takeID
        var steps: [Int] = []
        for (k, clip) in document.sequence.enumerated() where k < timeMap.clipOutputStarts.count {
            guard TimeMap.outputDuration(of: clip) > 0 else { continue }
            let first = StepGrid.firstStep(atOrAfter: timeMap.clipOutputStarts[k])
            steps.append(first)
            guard clip.take == take else { continue }
            var i = partitionPoint(changes.count) { changes[$0] <= clip.start }
            while i < changes.count, changes[i] < clip.end {
                if let τ = timeMap.output(atSource: changes[i], take: take) {
                    let step = StepGrid.firstStep(atOrAfter: τ)
                    steps += max(step - 1, first)...(step + 1)
                }
                i += 1
            }
        }
        var readings: [Reading] = []
        var last = -1
        for step in steps.sorted() where step > last {
            last = step
            let window = window(atStep: step, document: document, timeMap: timeMap, stage: stage)
            if readings.last?.window == window || (readings.isEmpty && window == nil) { continue }
            readings.append(Reading(step: step, window: window))
        }
        return readings
    }

    /// The reframed view shown on step `s`, on screen; `nil` for another take's clip, no screen, one that is not on
    /// screen or not reframed.
    private static func window(atStep s: Int, document: EditDocument, timeMap: TimeMap, stage: StagePoints) -> Window? {
        guard let shown = timeMap.source(atOutput: StepGrid.outputTime(ofStep: s)),
            document.sequence[shown.clip].take == stage.takeID,
            let view = stage.shownScreen(at: shown.source)?.view, view.onScreen, let region = view.region,
            let width = stage.reframedWidth(of: view)
        else { return nil }
        return Window(region: region, width: width)
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    private static func partitionPoint(_ count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
