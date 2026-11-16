// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// The cursor's path (design §8.4–§8.6) over a take whose source seconds count from `origin`, with one clip over its
// first 60 s unless a test cuts it: output seconds are then source seconds.

private let origin = HostTime(nanoseconds: 7_000_000_000_000)
private let pathTakeID = "take-001"
private let pathTake = TakeRecord(
    id: pathTakeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])

private let fast = CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.10))
private let medium = CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.16))
private let smooth = CursorSmoothing.spring(SpringSpec(damping: 0.92, response: 0.26))

private func sourceTime(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

/// `seconds` of output, in nanoseconds.
private func outputTime(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

private func moveTo(_ seconds: Double, _ point: SIMD2<Double>) -> InputEvent {
    InputEvent(t: sourceTime(seconds), kind: .cursor(x: point.x, y: point.y))
}

private func press(_ seconds: Double, _ point: SIMD2<Double>, _ button: MouseButton = .left) -> InputEvent {
    InputEvent(t: sourceTime(seconds), kind: .mouseDown(button, x: point.x, y: point.y))
}

private func release(_ seconds: Double, _ point: SIMD2<Double>, _ button: MouseButton = .left) -> InputEvent {
    InputEvent(t: sourceTime(seconds), kind: .mouseUp(button, x: point.x, y: point.y))
}

/// The clip over source seconds `[from, to)`.
private func pathClip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
    Clip(id: "c-0000000\(number)", take: pathTakeID, start: sourceTime(from), end: sourceTime(to), speed: speed)
}

private func cursorStyle(_ smoothing: CursorSmoothing, hideWhenIdle: Bool = false) -> CursorStyle {
    CursorStyle(
        show: true, style: .system, scale: 1, smoothing: smoothing, hideWhenIdle: hideWhenIdle, idleDelay: 2, clickEffect: "none",
        clickSound: "none", clickSoundGain: 1, motionBlur: 0)
}

private func cursorPath(
    _ events: [InputEvent], _ smoothing: CursorSmoothing = medium, hideWhenIdle: Bool = false,
    sequence: [Clip] = [pathClip(1, from: 0, to: 60)]
) -> CursorPath {
    let style = cursorStyle(smoothing, hideWhenIdle: hideWhenIdle)
    return CursorPath(take: pathTake, events: events, style: style, timeMap: TimeMap(sequence: sequence))
}

/// Positions every 1/60 s from `from` to `to` seconds, both included, at `along(t)`.
private func positions(from: Double, to: Double, _ along: (Double) -> SIMD2<Double>) -> [InputEvent] {
    let count = Int(((to - from) * 60).rounded())
    return (0...count).map { i in
        let t = from + Double(i) / 60
        return moveTo(t, along(t))
    }
}

/// A closed curve over a 1440×900 pt display.
private func curve(_ t: Double) -> SIMD2<Double> {
    SIMD2(700 + 400 * cos(2 * t), 450 + 300 * sin(3 * t))
}

/// Pointer positions moving along `curve` for 4 s, with clicks on it at 1.234 s and 2.5 s, each let go 80 ms later.
private let curveEvents: [InputEvent] =
    positions(from: 0, to: 4, curve) + [1.234, 2.5].flatMap { [press($0, curve($0)), release($0 + 0.08, curve($0 + 0.08))] }

/// The distance from `a` to `b`.
private func apart(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    ((a - b) * (a - b)).sum().squareRoot()
}

/// Every bit of a state of the path.
private func bits(_ state: CursorPath.State?) -> [UInt64]? {
    guard let state else { return nil }
    let values = [state.position.x, state.position.y, state.velocity.x, state.velocity.y, state.target.x, state.target.y]
    return (values + [state.scale, state.scaleVelocity]).map(\.bitPattern) + [state.pressed ? 1 : 0]
}

/// The cursor of phase 0 and 1a (`FrameEvaluator.cursor(at:)`), copied: the last position at or before `τ`, moved
/// toward the next one if that comes within 50 ms.
private func todaysCursor(at τ: Int64, positions: [(t: Int64, point: SIMD2<Double>)]) -> SIMD2<Double>? {
    var low = 0, high = positions.count
    while low < high {
        let mid = (low + high) / 2
        if positions[mid].t <= τ { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { return nil }
    let previous = positions[low - 1]
    var point = previous.point
    if low < positions.count {
        let next = positions[low]
        let gap = (Double(next.t) - Double(previous.t)) / 1_000_000_000
        if gap <= 0.050 {
            point += (next.point - previous.point) * (((Double(τ) - Double(previous.t)) / 1_000_000_000) / gap)
        }
    }
    return point
}

@Test func offIsTodaysRuleExactly() {
    var generator = PathRandom(seed: 0x6375_7273_6f72)
    // Positions from 0.3 s before the first clip to past the last, 0 to 120 ms apart (some at the same instant), with
    // presses among them; three clips with cuts between them, at 1×, 2× and 0.5×.
    var events: [InputEvent] = []
    var t = -0.3
    while t < 12 {
        let point = SIMD2(Double.random(in: 0...1440, using: &generator), Double.random(in: 0...900, using: &generator))
        switch Int.random(in: 0..<10, using: &generator) {
        case 0: events.append(press(t, point))
        case 1: events.append(release(t, point))
        default: events.append(moveTo(t, point))
        }
        t += [0, 0.004, 0.016, 0.03, 0.049, 0.051, 0.12][Int.random(in: 0..<7, using: &generator)]
    }
    let sequence = [pathClip(1, from: 0, to: 4), pathClip(2, from: 5, to: 8, speed: 2), pathClip(3, from: 9, to: 11, speed: 0.5)]
    let timeMap = TimeMap(sequence: sequence)
    let today = events.sortedByTime().compactMap { event -> (t: Int64, point: SIMD2<Double>)? in
        guard let point = event.kind.pointerPosition, let t = timeMap.output(ofSampleAt: event.t, take: pathTakeID) else {
            return nil
        }
        return (t, point)
    }
    let path = cursorPath(events, .off, sequence: sequence)

    var mismatches: [String] = []
    for _ in 0..<1000 {
        let τ = Int64.random(in: -500_000_000...(timeMap.duration + 500_000_000), using: &generator)
        let sample = path.sample(atOutput: τ)
        let expected = todaysCursor(at: τ, positions: today)
        let got = sample.map { [$0.position.x.bitPattern, $0.position.y.bitPattern] }
        let same = got == expected.map { [$0.x.bitPattern, $0.y.bitPattern] }
        if !same || (sample.map { $0.opacity != 1 || $0.clickScale != 1 } ?? false), mismatches.count < 10 {
            mismatches.append("at \(τ): \(String(describing: sample)), not \(String(describing: expected))")
        }
    }
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

@Test(arguments: [fast, medium, smooth])
func smoothedCursorIsExactlyOnEachClick(smoothing: CursorSmoothing) throws {
    let path = cursorPath(curveEvents, smoothing)
    #expect(path.clicks.map(\.output) == [outputTime(1.234), outputTime(2.5)])
    #expect(path.clicks.map(\.point) == [curve(1.234), curve(2.5)])
    // round(1.234 × 600) = 740 and 2.5 × 600 = 1500.
    #expect(try #require(path.sample(atStep: 740)).position == curve(1.234))
    #expect(try #require(path.sample(atStep: 1500)).position == curve(2.5))
    // It lands rather than jumps: a step before, it is already there.
    #expect(apart(try #require(path.sample(atStep: 739)).position, curve(1.234)) < 1)
    #expect(apart(try #require(path.sample(atStep: 1499)).position, curve(2.5)) < 1)
}

@Test func anyCheckpointGivesTheSameBits() {
    let path = cursorPath(curveEvents + positions(from: 4, to: 6) { _ in SIMD2(200, 200) }, smooth, hideWhenIdle: true)
    #expect(StepGrid.checkpointEvery == 600)
    for step in [0, 1, 599, 600, 601, 1199, 1200, 1234, 1500, 1799, 2399, 2400, 3599] {
        let fromCheckpoint = bits(path.state(atStep: step))
        #expect(fromCheckpoint != nil)
        #expect(fromCheckpoint == bits(path.stateSimulatedFromStart(atStep: step)), "step \(step)")
    }
}

/// Springs a document edited by hand can have: a response of 0, negative or not a number, a damping of 100, negative
/// or not a number.
private let handEdited: [CursorSmoothing] = [(1, 0), (1, -0.5), (1, .nan), (100, 0.16), (-3, 0.16), (.nan, 0.16)].map {
    .spring(SpringSpec(damping: $0.0, response: $0.1))
}

@Test(arguments: [CursorSmoothing.off, fast, medium, smooth] + handEdited)
func neverNaN(smoothing: CursorSmoothing) {
    // Positions at the same instant, a jump of 10 000 pt between two of them 10 ms apart with a click on each side, a
    // press and its release at the same instant.
    var events = positions(from: 0, to: 1, curve)
    events += [moveTo(1.2, [100, 100]), moveTo(1.2, [900, 600]), press(1.2, [400, 300]), moveTo(1.2, [50, 800])]
    events += [press(1.5, [10, 10]), release(1.5, [10, 10]), moveTo(1.51, [10_010, 10]), press(1.52, [10_010, 10])]
    events += [release(1.6, [10_010, 10]), moveTo(2, [10_010, 10])]
    var generator = PathRandom(seed: 7)
    let cases = [("many", events), ("one position", [moveTo(0.5, [300, 300])]), ("one press", [press(0.5, [300, 300])])]
    for (name, events) in cases {
        let path = cursorPath(events, smoothing, hideWhenIdle: true, sequence: [pathClip(1, from: 0, to: 4)])
        let steps = (0...2400).compactMap { path.sample(atStep: $0) }
        let between = (0..<500).compactMap { _ in path.sample(atOutput: Int64.random(in: 0..<4_000_000_000, using: &generator)) }
        #expect(steps.count >= 2400 - 300, "\(name)")
        let bad = (steps + between).filter { sample in
            !(sample.position.x.isFinite && sample.position.y.isFinite && sample.opacity.isFinite && sample.clickScale.isFinite)
        }
        #expect(bad.isEmpty, "\(name): \(bad.prefix(3))")
    }
}

@Test(arguments: [(medium, 0.049), (fast, 0.030), (smooth, 0.074)])
func mediumLagsAbout51msInSteadyMotion(smoothing: CursorSmoothing, lag: Double) throws {
    // 1000 pt/s to the right; the raw position at each step is the interpolated one.
    let path = cursorPath(positions(from: 0, to: 4) { SIMD2(100 + 1000 * $0, 400) }, smoothing)
    for step in [1200, 1500, 1800] {
        let sample = try #require(path.sample(atStep: step))
        let raw = 100 + 1000 * Double(step) / 600
        #expect(abs((raw - sample.position.x) / 1000 - lag) <= 0.003, "step \(step): \((raw - sample.position.x) / 1000) s")
        #expect(sample.position.y == 400)
    }
}

@Test func gridFramesLandOnExactSteps() {
    var mismatches: [String] = []
    for fps in [24, 25, 30, 50, 60] {
        for n in 0..<36_000 {
            let position = StepGrid.position(ofOutput: TimeMap.frameTime(n, frameRate: fps))
            if (position.step, position.fraction) != (StepGrid.step(frame: n, frameRate: fps), 0), mismatches.count < 10 {
                mismatches.append("frame \(n) at \(fps) fps: \(position)")
            }
        }
    }
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    #expect(StepGrid.rate == 600)
    #expect(StepGrid.step(frame: 7, frameRate: 24) == 175)
    // Off the grid: the step before and how far toward the next one.
    let between = StepGrid.position(ofOutput: 2_500_000)
    #expect(between.step == 1 && abs(between.fraction - 0.5) < 1e-12)
    let early = StepGrid.position(ofOutput: -2_500_000)
    #expect(early.step == -2 && abs(early.fraction - 0.5) < 1e-12)
}

@Test func stableSpringsStayFinite() {
    // Every spring of the design is left as it is.
    let design = [
        SpringSpec(damping: 1, response: 0.10), SpringSpec(damping: 1, response: 0.16), SpringSpec(damping: 0.92, response: 0.26),
        SpringSpec(damping: 1, response: 0.06), SpringSpec(damping: 0.70, response: 0.18), SpringSpec(damping: 1, response: 0.45),
        SpringSpec(damping: 1, response: 0.70), SpringSpec(damping: 1, response: 1.00),
    ]
    #expect(design.map(StepGrid.stable) == design)
    #expect(StepGrid.stable(SpringSpec(damping: 1, response: 0)) == SpringSpec(damping: 1, response: 0.06))
    #expect(StepGrid.stable(SpringSpec(damping: 1, response: -0.5)) == SpringSpec(damping: 1, response: 0.06))
    #expect(StepGrid.stable(SpringSpec(damping: 1, response: .nan)) == SpringSpec(damping: 1, response: 0.16))
    #expect(StepGrid.stable(SpringSpec(damping: 100, response: 0.16)) == SpringSpec(damping: 2, response: 0.16))
    #expect(StepGrid.stable(SpringSpec(damping: -3, response: 0.16)) == SpringSpec(damping: 0, response: 0.16))
    #expect(StepGrid.stable(SpringSpec(damping: .nan, response: 0.16)) == SpringSpec(damping: 1, response: 0.16))

    /// The largest distance from 0 over 10 s toward 1000, then 10 s toward −1000.
    func reach(_ spring: SpringSpec) -> Double {
        var (x, v, largest) = (0.0, 0.0, 0.0)
        for step in 0..<12_000 {
            StepGrid.spring(&x, &v, target: step < 6_000 ? 1000 : -1000, spring)
            largest = x.isFinite ? max(largest, abs(x)) : .infinity
        }
        return largest
    }
    // Read as they are, a damping of 100 or a response of 1 ms diverge; read through `stable`, nothing does.
    #expect(!(reach(SpringSpec(damping: 100, response: 0.16)) < 1e12))
    #expect(!(reach(SpringSpec(damping: 1, response: 0.001)) < 1e12))
    let edited = [(1, 0), (1, -0.5), (1, .nan), (100, 0.16), (-3, 0.16), (.nan, 0.16), (100, 0), (0, 0.06), (2, 0.06)]
    for (damping, response) in edited {
        #expect(reach(StepGrid.stable(SpringSpec(damping: damping, response: response))) < 10_000, "\(damping) · \(response)")
    }
}

@Test func dragFollowsTheRawTightly() throws {
    // Pressed at 0.5 s and moving at 500 pt/s until it is let go at 3.5 s.
    let start = SIMD2(100.0, 400)
    func along(_ t: Double) -> SIMD2<Double> { start + SIMD2(500 * (t - 0.5), 0) }
    let events = [press(0.5, start)] + positions(from: 0.5 + 1.0 / 60, to: 3.5 - 1.0 / 60, along) + [release(3.5, along(3.5))]
    let path = cursorPath(events, medium)
    for step in [1200, 1800] {
        let sample = try #require(path.sample(atStep: step))
        #expect(sample.pressed)
        let lag = (along(Double(step) / 600).x - sample.position.x) / 500
        #expect(lag > 0 && lag <= 0.02, "step \(step): \(lag) s")
    }
}

@Test(arguments: [fast, medium, smooth])
func deadZoneHoldsAgainstJitter(smoothing: CursorSmoothing) {
    // Shaking up to 1 pt on each axis around where it started.
    let center = SIMD2(500.0, 400)
    let shakes: [SIMD2<Double>] = [[1, 1], [-1, -1], [1, -1], [-1, 1], [0, 1], [1, 0]]
    let events = [moveTo(0, center)] + (1...180).map { moveTo(Double($0) / 60, center + shakes[$0 % shakes.count]) }
    let path = cursorPath(events, smoothing)
    let moved = (0...1800).filter { path.sample(atStep: $0)?.position != center }
    #expect(moved.isEmpty, "\(moved.prefix(5))")
}

@Test func cutsDoNotJump() throws {
    // At (0, 0) until a cut over source [1, 2) s, at (1000, 0) after it: the output jumps there at 1 s, step 600.
    let events = [0, 0.5, 0.9].map { moveTo($0, [0, 0]) } + [2, 2.5, 3].map { moveTo($0, [1000, 0]) }
    let path = cursorPath(events, medium, sequence: [pathClip(1, from: 0, to: 1), pathClip(2, from: 2, to: 4)])
    let before = try #require(path.sample(atStep: 599)).position
    let first = try #require(path.sample(atStep: 600)).position
    #expect(before == [0, 0])
    #expect(apart(first, before) < 0.05 * 1000)
    // It does get there.
    #expect(apart(try #require(path.sample(atStep: 1200)).position, [1000, 0]) < 0.5)
}

@Test func pressShrinksToEightyFivePercent() throws {
    let point = SIMD2(300.0, 300)
    let events = [moveTo(0, point), press(1, point), moveTo(1.5, point), release(2, point), moveTo(3, point)]
    let path = cursorPath(events, medium)
    #expect(try #require(path.sample(atStep: 540)).clickScale == 1)
    let pressed = try #require(path.sample(atStep: 780))
    #expect(pressed.pressed)
    #expect(abs(pressed.clickScale - 0.85) <= 0.01)
    let released = try #require(path.sample(atStep: 1380))
    #expect(!released.pressed)
    #expect(abs(released.clickScale - 1) <= 0.01)

    let off = cursorPath(events, .off)
    #expect((0...1800).allSatisfy { off.sample(atStep: $0)?.clickScale ?? 1 == 1 })
    #expect((0...300).allSatisfy { off.sample(atOutput: Int64($0) * 10_000_000)?.clickScale ?? 1 == 1 })
    #expect(try #require(off.sample(atOutput: outputTime(1.3))).pressed)
}

@Test func nothingBeforeTheFirstPosition() throws {
    let events = [moveTo(1.001, [300, 300]), moveTo(2, [400, 300])]
    // The first step at or after 1.001 s is 601.
    let path = cursorPath(events, medium)
    #expect(path.sample(atStep: 600) == nil)
    #expect(try #require(path.sample(atStep: 601)).position == [300, 300])
    #expect(path.sample(atOutput: outputTime(1.0005)) == nil)
    let off = cursorPath(events, .off)
    #expect(off.sample(atOutput: outputTime(1.001) - 1) == nil)
    #expect(try #require(off.sample(atOutput: outputTime(1.001))).position == [300, 300])
    #expect(cursorPath([], medium).sample(atStep: 0) == nil)

    // One before the first clip counts at output 0.
    let early = cursorPath([moveTo(0.95, [300, 200]), moveTo(2, [900, 500])], medium, sequence: [pathClip(1, from: 1, to: 3)])
    #expect(try #require(early.sample(atStep: 0)).position == [300, 200])
}

/// Clips over source [0, 1.04) s and [3, 12) s: the cut is at output 1.04 s, step 624.
private let cutAt104 = [pathClip(1, from: 0, to: 1.04), pathClip(2, from: 3, to: 12)]

@Test func aReleaseInACutRulesFromTheNextClip() throws {
    // Pressed at 1 s and let go at 1.08 s, in the cut, with the pointer still on (300, 300) until 10 s.
    let point = SIMD2(300.0, 300)
    let events = [moveTo(0, point), press(1, point), release(1.08, point), moveTo(10, point)]
    for smoothing in [CursorSmoothing.off, medium] {
        let path = cursorPath(events, smoothing, hideWhenIdle: true, sequence: cutAt104)
        #expect(try #require(path.sample(atStep: 623)).pressed)
        #expect(try #require(path.sample(atStep: 624)).pressed == false)
        #expect(try #require(path.sample(atOutput: outputTime(1.04))).pressed == false)
        // Back to its size, and, still since 0 s, hidden 2 s later as nothing holds it any more.
        #expect(abs(try #require(path.sample(atStep: 624 + 180)).clickScale - 1) <= 0.01)
        #expect(try #require(path.sample(atStep: 1380)).opacity == 0)
    }
}

@Test func aPressInACutRulesFromTheNextClip() throws {
    // Still on (300, 300) from 0 s; pressed at 1.5 s, in the cut, and let go at 8 s (output 6.04 s).
    let point = SIMD2(300.0, 300)
    let events = [moveTo(0, point), press(1.5, point), release(8, point), moveTo(10, point)]
    for smoothing in [CursorSmoothing.off, medium] {
        let path = cursorPath(events, smoothing, hideWhenIdle: true, sequence: cutAt104)
        #expect(path.clicks.isEmpty)
        #expect(try #require(path.sample(atStep: 623)).pressed == false)
        #expect(try #require(path.sample(atStep: 624)).pressed)
        #expect(try #require(path.sample(atOutput: outputTime(1.04))).pressed)
        if smoothing != .off { #expect(abs(try #require(path.sample(atStep: 624 + 180)).clickScale - 0.85) <= 0.01) }
        // Never hidden while it is down, though still for far longer than the delay; hidden once let go.
        let whileDown = stride(from: 0, through: 3624, by: 6).compactMap { path.sample(atStep: $0)?.opacity }
        #expect(whileDown.count == 605 && whileDown.allSatisfy { $0 == 1 })
        #expect(try #require(path.sample(atStep: 3624 + 180)).opacity == 0)
    }
}

@Test func clicksAreTheKeptPresses() {
    // Before the first clip, in the cut and after the last one, a press moves the pointer but is no click.
    let events = [press(0.5, [1, 1]), press(1.5, [2, 2]), press(2.5, [3, 3]), press(3.5, [4, 4]), press(4.5, [5, 5])]
    let path = cursorPath(events, medium, sequence: [pathClip(1, from: 1, to: 2), pathClip(2, from: 3, to: 4)])
    #expect(path.clicks.map(\.output) == [outputTime(0.5), outputTime(1.5)])
    #expect(path.clicks.map(\.point) == [[2, 2], [4, 4]])
}

@Test func offTheGridIsBetweenTheTwoSteps() throws {
    let path = cursorPath(curveEvents, medium, hideWhenIdle: true)
    let (a, b) = (try #require(path.sample(atStep: 1000)), try #require(path.sample(atStep: 1001)))
    // About a quarter of the way from step 1000 to 1001.
    let τ = StepGrid.outputTime(ofStep: 1000) + 416_667
    let fraction = StepGrid.position(ofOutput: τ).fraction
    #expect(abs(fraction - 0.25) < 1e-6)
    let between = try #require(path.sample(atOutput: τ))
    #expect(apart(between.position, a.position + (b.position - a.position) * fraction) < 1e-9)
    #expect(abs(between.opacity - (a.opacity + (b.opacity - a.opacity) * fraction)) < 1e-12)
    #expect(between.pressed == a.pressed)
    // On a frame of the grid, the step itself.
    #expect(path.sample(atOutput: TimeMap.frameTime(100, frameRate: 60)) == path.sample(atStep: 1000))
}

@Test func hidingWhenIdleFadesTheSmoothedCursorToo() throws {
    // Still from 1 s with a delay of 2 s: hidden from 3.3 s, whatever the smoothing.
    let events = positions(from: 0, to: 1) { SIMD2(100 + 200 * $0, 300) }
    for smoothing in [CursorSmoothing.off, medium] {
        let path = cursorPath(events, smoothing, hideWhenIdle: true)
        #expect(try #require(path.sample(atStep: 1500)).opacity == 1)
        #expect(try #require(path.sample(atStep: 2000)).opacity == 0)
        #expect(try #require(cursorPath(events, smoothing).sample(atStep: 2000)).opacity == 1)
    }
}

/// The SplitMix64 generator (Steele, Lea and Flood), for a fixed seed's sequence of numbers on every run.
private struct PathRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
