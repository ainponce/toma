// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Testing

// Design §8.5, on output times given directly: hidden after `delay` without moving more than 3 pt, faded out in 0.30 s,
// back in 0.15 s from 0.10 s before it moves or 0.15 s before a click, never within 0.5 s after a click or with a
// button down.

/// `seconds` of output, in nanoseconds.
private func idleTime(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

private typealias IdleSample = (output: Int64, point: SIMD2<Double>, pressed: Bool)

/// Positions every 1/60 s from `from` to `to` seconds, both included, going right at 200 pt/s from `x`.
private func moving(from: Double, to: Double, x: Double, y: Double = 300) -> [IdleSample] {
    let count = Int(((to - from) * 60).rounded())
    return (0...count).map { i in
        let t = from + Double(i) / 60
        return (idleTime(t), SIMD2(x + 200 * (t - from), y), false)
    }
}

@Test func idleFadesAfterTheDelayAndReturnsBeforeMoving() {
    // It moves until 1 s, stands still (no positions: the recorder logs only movement) and moves again at 6 s.
    let samples = moving(from: 0, to: 1, x: 100) + moving(from: 6, to: 7, x: 320)
    let idle = IdleVisibility(samples: samples, clicks: [], delay: 2)
    #expect(idle.opacity(atOutput: idleTime(0.5)) == 1)
    #expect(idle.opacity(atOutput: idleTime(2.99)) == 1)
    #expect(idle.opacity(atOutput: idleTime(3)) == 1)
    #expect(abs(idle.opacity(atOutput: idleTime(3.15)) - 0.5) <= 0.01)
    #expect(idle.opacity(atOutput: idleTime(3.30)) == 0)
    #expect(idle.opacity(atOutput: idleTime(5)) == 0)
    // Back from 0.10 s before it moves, in 0.15 s: it is already moving when it shows.
    #expect(idle.opacity(atOutput: idleTime(5.899)) == 0)
    #expect(idle.opacity(atOutput: idleTime(5.90)) == 0)
    #expect(idle.opacity(atOutput: idleTime(5.901)) > 0)
    #expect(abs(idle.opacity(atOutput: idleTime(5.975)) - 0.5) <= 0.01)
    #expect(idle.opacity(atOutput: idleTime(6.05)) == 1)
    #expect(idle.opacity(atOutput: idleTime(6.5)) == 1)
}

@Test func neverHiddenNearAClickOrPressed() {
    // Still from 7 s at (500, 300); a click there at 10 s, without moving: down, and up 50 ms later.
    let point = SIMD2(500.0, 300)
    var samples = moving(from: 6, to: 7, x: 300)
    samples += [(idleTime(10), point, true), (idleTime(10.05), point, false)]
    let idle = IdleVisibility(samples: samples, clicks: [idleTime(10)], delay: 2)
    #expect(idle.opacity(atOutput: idleTime(9.5)) == 0)
    // It starts to come back 0.15 s before the click, so it is whole at the click...
    #expect(idle.opacity(atOutput: idleTime(9.849)) == 0)
    #expect(idle.opacity(atOutput: idleTime(9.851)) > 0)
    #expect(idle.opacity(atOutput: idleTime(10)) == 1)
    // ...and stays so for the 0.5 s after it.
    let afterTheClick = (0...50).map { idle.opacity(atOutput: idleTime(10 + Double($0) / 100)) }
    #expect(afterTheClick.allSatisfy { $0 == 1 })
    // A click does not restart the delay: still since 7 s, it fades out again from 10.5 s (§8.5).
    #expect(abs(idle.opacity(atOutput: idleTime(10.65)) - 0.5) <= 0.01)
    #expect(idle.opacity(atOutput: idleTime(10.8)) == 0)

    // A button held down for 10 s without moving: never hidden while it is down, from the press on.
    let held: [IdleSample] =
        moving(from: 0, to: 1, x: 100) + [(idleTime(1), SIMD2(300, 300), true), (idleTime(11), SIMD2(300, 300), false)]
    let pressed = IdleVisibility(samples: held, clicks: [idleTime(1)], delay: 2)
    let whileDown = (0...1100).map { pressed.opacity(atOutput: idleTime(Double($0) / 100)) }
    #expect(whileDown.allSatisfy { $0 == 1 })
    // Let go, still since 1 s: it fades out from the release.
    #expect(pressed.opacity(atOutput: idleTime(11.3)) == 0)
}

@Test func moreThanThreePointsIsMoving() {
    // Positions that wander within 3 pt of where it stopped are still; one 3.5 pt away moves it.
    var samples = moving(from: 0, to: 1, x: 100)
    let stop = samples[samples.count - 1].point
    samples += [(idleTime(1.5), stop + SIMD2(3, 0), false), (idleTime(2.2), stop + SIMD2(0, -3), false)]
    let still = IdleVisibility(samples: samples, clicks: [], delay: 2)
    #expect(still.opacity(atOutput: idleTime(3.3)) == 0)
    samples.append((idleTime(2.9), stop + SIMD2(3.5, 0), false))
    let moved = IdleVisibility(samples: samples, clicks: [], delay: 2)
    #expect(moved.opacity(atOutput: idleTime(3.3)) == 1)
    #expect(moved.opacity(atOutput: idleTime(5.2)) == 0)
}

@Test func aShortStopNeverHides() {
    // It moves again 0.05 s after the delay: the return would start before the fade, so nothing changes.
    let samples = moving(from: 0, to: 1, x: 100) + moving(from: 3.05, to: 4, x: 320)
    let idle = IdleVisibility(samples: samples, clicks: [], delay: 2)
    let around = (0...400).map { idle.opacity(atOutput: idleTime(Double($0) / 100)) }
    #expect(around.allSatisfy { $0 == 1 })
}

@Test func pressesKnownApartFromThePositions() {
    // Still from 0 s, with a button down over [1.04, 6.04) s and no position to say so (the press came in a cut).
    let positions: [(output: Int64, point: SIMD2<Double>)] = [(0, SIMD2(300, 300)), (idleTime(8), SIMD2(300, 300))]
    let pressed = IdleVisibility(positions: positions, presses: [idleTime(1.04)..<idleTime(6.04)], clicks: [], delay: 2)
    let whileDown = (0...604).map { pressed.opacity(atOutput: idleTime(Double($0) / 100)) }
    #expect(whileDown.allSatisfy { $0 == 1 })
    #expect(pressed.opacity(atOutput: idleTime(6.34)) == 0)
    // Without it, the same positions hide from 2 s.
    let free = IdleVisibility(positions: positions, presses: [], clicks: [], delay: 2)
    #expect(free.opacity(atOutput: idleTime(2.3)) == 0)
}
