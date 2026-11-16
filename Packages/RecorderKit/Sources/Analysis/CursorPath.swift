// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The drawn cursor at one instant of the output.
public struct CursorSample: Equatable, Sendable {
    /// In global points.
    public var position: SIMD2<Double>
    /// 1 shown, 0 hidden (`IdleVisibility`).
    public var opacity: Double
    /// The press: 1 at rest, toward 0.85 while a button is down.
    public var clickScale: Double
    /// Whether a button is down.
    public var pressed: Bool

    public init(position: SIMD2<Double>, opacity: Double, clickScale: Double, pressed: Bool) {
        self.position = position
        self.opacity = opacity
        self.clickScale = clickScale
        self.pressed = pressed
    }
}

/// The path of the drawn cursor of a take in the output (design §8.4–§8.6): where it is, how visible and how pressed.
///
/// The raw positions are the take's `cursor`, `mouseDown` and `mouseUp` events in global points at their output times,
/// by the rule of the render (`TimeMap.output(ofSampleAt:take:)`): one in a cut between two clips is dropped, one
/// before the first clip or after the last keeps its time through that clip's mapping. Whether a button is down is
/// read from all the events, the dropped ones too. The clicks, and the landings on them, are the `mouseDown`s (of any
/// button) inside a kept clip. There is no cursor before the first raw position.
///
/// - `off`: the cursor of phase 0 and 1a at the exact output time, off the grid: the last raw position at or before
///   it, moved toward the next one if that comes within 50 ms; never pressed smaller.
/// - A spring: simulated on `StepGrid` from output 0, reading the raw position (the rule of `off`) and the buttons at
///   each step's time; it starts at the first step at or after the first raw position, at rest on it.
///   - Dead zone: the target stays while the raw position is less than 1.5 pt from it; once it is not, the target is
///     the raw position.
///   - Landing: with the next click 0.5 s or less ahead, the target is that click's point, and over its last 0.175 s
///     the response goes down linearly to 0.06 s; on the click's step, `round(t × 600)`, the cursor is on the click's
///     point, at rest.
///   - With a button down the target is the raw position, with a spring of 1.0 · 0.06 s, so a drag looks precise.
///   - The press: toward 0.85 while a button is down and back to 1 after, with a spring of 0.70 · 0.18 s.
///   The whole state is kept every `StepGrid.checkpointEvery` steps; a step is simulated from the checkpoint before
///   it, which gives the same bits as from output 0. Off the grid, the samples of the two steps around are mixed
///   linearly. After the end of the output the cursor stays as it is on its last step.
///   A spring is read where the 600 Hz step stays stable: a response of at least 0.06 s (0.16 s if not a number) and
///   a damping from 0 to 2 (1 if not a number), so a document edited by hand never stops the render.
/// - With `hideWhenIdle`, the opacity is `IdleVisibility`'s of the raw positions and the clicks after `idleDelay`;
///   otherwise 1.
public struct CursorPath: Sendable {
    /// The kept `mouseDown`s, in output order: where the click effects and sounds come from.
    public let clicks: [(output: Int64, point: SIMD2<Double>)]

    /// The raw positions, in output order.
    private let samples: [Sample]
    private let idle: IdleVisibility?
    /// `nil` with `off`.
    private let motion: Motion?

    public init(take: TakeRecord, events: [InputEvent], style: CursorStyle, timeMap: TimeMap) {
        var samples: [Sample] = []
        var clicks: [(output: Int64, point: SIMD2<Double>)] = []
        var down = Set<MouseButton>()
        for event in events.sortedByTime() {
            switch event.kind {
            case let .mouseDown(button, _, _): down.insert(button)
            case let .mouseUp(button, _, _): down.remove(button)
            default: break
            }
            guard let point = event.kind.pointerPosition, let output = timeMap.output(ofSampleAt: event.t, take: take.id)
            else { continue }
            samples.append(Sample(output: output, point: point, pressed: !down.isEmpty))
            if case .mouseDown = event.kind, let kept = timeMap.output(atSource: event.t, take: take.id) {
                clicks.append((kept, point))
            }
        }
        self.samples = samples
        self.clicks = clicks
        idle = style.hideWhenIdle
            ? IdleVisibility(
                samples: samples.map { ($0.output, $0.point, $0.pressed) }, clicks: clicks.map(\.output), delay: style.idleDelay)
            : nil
        switch style.smoothing {
        case .off:
            motion = nil
        case let .spring(spec):
            motion = Motion(samples: samples, clicks: clicks, spring: Self.stable(spec), duration: timeMap.duration)
        }
    }

    /// The cursor on step `s` of the grid; `nil` before the first raw position (with a spring, before step 0 too).
    public func sample(atStep s: Int) -> CursorSample? {
        guard let motion else { return todaysSample(at: StepGrid.outputTime(ofStep: s)) }
        guard let state = motion.state(atStep: s) else { return nil }
        return sample(state, atStep: motion.clamped(s))
    }

    /// The cursor at output time `τ`: with `off`, at `τ` itself; with a spring, the sample of its step when `τ` is on
    /// the grid (`StepGrid.position(ofOutput:)`), otherwise the two around it mixed. `nil` before the first raw
    /// position.
    public func sample(atOutput τ: Int64) -> CursorSample? {
        guard let motion else { return todaysSample(at: τ) }
        let (step, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0 else { return sample(atStep: step) }
        guard let (before, after) = motion.states(atSteps: step) else { return nil }
        let a = sample(before, atStep: motion.clamped(step))
        let b = sample(after, atStep: motion.clamped(step + 1))
        return CursorSample(
            position: a.position + (b.position - a.position) * fraction,
            opacity: a.opacity + (b.opacity - a.opacity) * fraction,
            clickScale: a.clickScale + (b.clickScale - a.clickScale) * fraction,
            pressed: a.pressed)
    }

    // MARK: - Internal (the state of the simulation, for the tests)

    /// Everything the simulation carries from one step to the next.
    struct State: Equatable, Sendable {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        /// Where the spring heads: the raw position past the dead zone, a click's point, or the raw one while pressed.
        var target: SIMD2<Double>
        var scale: Double
        var scaleVelocity: Double
        /// Whether a button is down at the step.
        var pressed: Bool
    }

    /// The state on step `s`, from the checkpoint before it; `nil` with `off`.
    func state(atStep s: Int) -> State? {
        motion?.state(atStep: s)
    }

    /// The state on step `s` simulated from output 0, without the checkpoints; `nil` with `off`.
    func stateSimulatedFromStart(atStep s: Int) -> State? {
        guard let motion, s >= 0 else { return nil }
        return motion.stateSimulatedFromStart(atStep: motion.clamped(s))
    }

    // MARK: - Rules and inputs

    // Design §8.4 (and decision 8 of the plan for the press, which only a spring has).
    static let deadZone = 1.5
    static let landingLead = Int((0.5 * Double(StepGrid.rate)).rounded())
    static let landingRamp = Int((0.175 * Double(StepGrid.rate)).rounded())
    static let landingResponse = 0.06
    static let dragSpring = SpringSpec(damping: 1.0, response: 0.06)
    static let pressedScale = 0.85
    static let pressSpring = SpringSpec(damping: 0.70, response: 0.18)
    /// Two raw positions at most this far apart in output seconds are interpolated; farther apart, it stays put.
    static let maxInterpolationGap = 0.050

    struct Sample: Sendable {
        var output: Int64
        /// In global points.
        var point: SIMD2<Double>
        /// Whether a button is down from this position on.
        var pressed: Bool
    }

    private func sample(_ state: State, atStep s: Int) -> CursorSample {
        CursorSample(
            position: state.position, opacity: idle?.opacity(atOutput: StepGrid.outputTime(ofStep: s)) ?? 1,
            clickScale: state.scale, pressed: state.pressed)
    }

    /// The cursor of phase 0 and 1a at `τ`, with the opacity of `idle`.
    private func todaysSample(at τ: Int64) -> CursorSample? {
        let next = Self.firstSample(after: τ, in: samples)
        guard let point = Self.todaysPoint(at: τ, next: next, in: samples) else { return nil }
        return CursorSample(
            position: point, opacity: idle?.opacity(atOutput: τ) ?? 1, clickScale: 1, pressed: samples[next - 1].pressed)
    }

    /// The raw position at `τ` (as `FrameEvaluator.cursor(at:)` has always placed it), with `next` the index of the
    /// first sample after `τ`: the last one at or before `τ`, moved toward the next one if that comes within
    /// `maxInterpolationGap`. `nil` before the first one.
    static func todaysPoint(at τ: Int64, next: Int, in samples: [Sample]) -> SIMD2<Double>? {
        guard next > 0 else { return nil }
        let previous = samples[next - 1]
        var point = previous.point
        if next < samples.count {
            let following = samples[next]
            let gap = seconds(following.output, since: previous.output)
            // `gap` is never 0 below 2⁵³ ns; beyond, two outputs can be the same `Double`.
            if gap > 0, gap <= maxInterpolationGap {
                point += (following.point - previous.point) * (seconds(τ, since: previous.output) / gap)
            }
        }
        return point
    }

    /// The index of the first sample after `τ`.
    static func firstSample(after τ: Int64, in samples: [Sample]) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].output <= τ { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Seconds from output time `b` to `a`, counted as the render has always counted them.
    private static func seconds(_ a: Int64, since b: Int64) -> Double {
        (Double(a) - Double(b)) / 1_000_000_000
    }

    /// `spec` where the 600 Hz step is stable (see the type's notes).
    private static func stable(_ spec: SpringSpec) -> SpringSpec {
        SpringSpec(
            damping: spec.damping.isNaN ? 1 : min(max(spec.damping, 0), 2),
            response: spec.response.isNaN ? 0.16 : max(spec.response, landingResponse))
    }
}

extension CursorPath {
    /// A click on the grid: its step, `round(t × 600)`, and its point.
    struct ClickStep: Sendable {
        var step: Int
        var point: SIMD2<Double>
    }

    /// Where a simulation is: its step, its state on it, and where it is in the inputs.
    struct Simulation: Sendable {
        fileprivate(set) var step: Int
        fileprivate(set) var state: State?
        /// The first sample after the step's output time.
        fileprivate var nextSample: Int
        /// The first click on the step or after it.
        fileprivate var nextClick: Int
    }

    /// The spring's inputs and its checkpoints.
    struct Motion: Sendable {
        let samples: [Sample]
        let clicks: [ClickStep]
        let spring: SpringSpec
        /// The step the cursor starts on; `nil` without raw positions.
        let firstStep: Int?
        /// The step of the end of the output: the last one simulated.
        let lastStep: Int
        /// The state on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`; `nil` before the cursor starts.
        private(set) var checkpoints: [State?] = []

        init(samples: [Sample], clicks: [(output: Int64, point: SIMD2<Double>)], spring: SpringSpec, duration: Int64) {
            self.samples = samples
            self.clicks = clicks.map { ClickStep(step: StepGrid.nearestStep(toOutput: $0.output), point: $0.point) }
            self.spring = spring
            firstStep = samples.first.map { StepGrid.firstStep(atOrAfter: $0.output) }
            lastStep = StepGrid.firstStep(atOrAfter: duration)
            if firstStep != nil { checkpoints = simulatedCheckpoints() }
        }

        /// `s` held to `0...lastStep`.
        func clamped(_ s: Int) -> Int {
            min(max(s, 0), lastStep)
        }

        /// The state on step `s` (the last one's after the end), from the checkpoint before it; `nil` before the
        /// cursor starts and before step 0.
        func state(atStep s: Int) -> State? {
            guard let firstStep, s >= 0, clamped(s) >= firstStep else { return nil }
            var simulation = simulation(toward: clamped(s))
            while simulation.step < clamped(s) { advance(&simulation) }
            return simulation.state
        }

        /// The states on steps `s` and `s + 1` (held to `lastStep`), from the checkpoint before `s`; `nil` when the
        /// first of them is.
        func states(atSteps s: Int) -> (State, State)? {
            guard let firstStep, s >= 0, clamped(s) >= firstStep else { return nil }
            var simulation = simulation(toward: clamped(s))
            while simulation.step < clamped(s) { advance(&simulation) }
            guard let before = simulation.state else { return nil }
            if simulation.step < clamped(s + 1) { advance(&simulation) }
            // Once started, the cursor never stops.
            return (before, simulation.state ?? before)
        }

        /// The state on step `s` (in `0...lastStep`) simulated from output 0, without the checkpoints.
        func stateSimulatedFromStart(atStep s: Int) -> State? {
            var simulation = simulation(atStep: -1, state: nil)
            while simulation.step < s { advance(&simulation) }
            return simulation.state
        }

        /// The states on steps 0, `StepGrid.checkpointEvery`, … up to `lastStep`, simulated from output 0.
        private func simulatedCheckpoints() -> [State?] {
            var simulation = simulation(atStep: -1, state: nil)
            var checkpoints: [State?] = []
            checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
            while simulation.step < lastStep {
                advance(&simulation)
                if simulation.step % StepGrid.checkpointEvery == 0 { checkpoints.append(simulation.state) }
            }
            return checkpoints
        }

        /// A simulation from the checkpoint at or before step `s` (in `0...lastStep`).
        private func simulation(toward s: Int) -> Simulation {
            let index = s / StepGrid.checkpointEvery
            guard index < checkpoints.count else { return simulation(atStep: -1, state: nil) }
            return simulation(atStep: index * StepGrid.checkpointEvery, state: checkpoints[index])
        }

        /// A simulation on `step` with `state`, placed in the inputs.
        private func simulation(atStep step: Int, state: State?) -> Simulation {
            var low = 0, high = clicks.count
            while low < high {
                let mid = (low + high) / 2
                if clicks[mid].step < step { low = mid + 1 } else { high = mid }
            }
            let nextSample = CursorPath.firstSample(after: StepGrid.outputTime(ofStep: step), in: samples)
            return Simulation(step: step, state: state, nextSample: nextSample, nextClick: low)
        }

        /// Takes `simulation` to the next step: reads the raw position, the buttons and the next click at its time, and
        /// moves the cursor one step of 1/600 s toward its target.
        private func advance(_ simulation: inout Simulation) {
            simulation.step += 1
            let step = simulation.step
            let τ = StepGrid.outputTime(ofStep: step)
            var next = simulation.nextSample
            while next < samples.count, samples[next].output <= τ { next += 1 }
            simulation.nextSample = next
            while simulation.nextClick < clicks.count, clicks[simulation.nextClick].step < step { simulation.nextClick += 1 }
            guard let firstStep, step >= firstStep else { return }
            // From the first step on there is a raw position: at the latest, the first sample is on it.
            let raw = CursorPath.todaysPoint(at: τ, next: next, in: samples) ?? samples[0].point
            let pressed = next > 0 && samples[next - 1].pressed
            let click = simulation.nextClick < clicks.count ? clicks[simulation.nextClick] : nil

            guard var current = simulation.state else {
                var start = State(
                    position: raw, velocity: .zero, target: raw, scale: pressed ? CursorPath.pressedScale : 1, scaleVelocity: 0,
                    pressed: pressed)
                if let click, click.step == step { start.position = click.point }
                simulation.state = start
                return
            }
            var spring = spring
            if pressed {
                current.target = raw
                spring = CursorPath.dragSpring
            } else if let click, click.step - step <= CursorPath.landingLead {
                current.target = click.point
                let left = click.step - step
                if left < CursorPath.landingRamp {
                    let response = CursorPath.landingResponse
                    spring.response = response + (spring.response - response) * Double(left) / Double(CursorPath.landingRamp)
                }
            } else if distance(raw, current.target) >= CursorPath.deadZone {
                current.target = raw
            }
            StepGrid.spring(&current.position.x, &current.velocity.x, target: current.target.x, spring)
            StepGrid.spring(&current.position.y, &current.velocity.y, target: current.target.y, spring)
            StepGrid.spring(
                &current.scale, &current.scaleVelocity, target: pressed ? CursorPath.pressedScale : 1, CursorPath.pressSpring)
            current.pressed = pressed
            if let click, click.step == step {
                current.position = click.point
                current.velocity = .zero
            }
            simulation.state = current
        }
    }
}
