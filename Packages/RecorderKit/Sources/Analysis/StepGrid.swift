// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The grid of the motion paths (design §8.6): the cursor and the zoom camera are simulated in output time with a
/// fixed step of 1/600 s from output 0, and their whole state is kept every 600 steps (1 s), so evaluating an instant
/// simulates at most 600 steps from the checkpoint before it, and on the grid gives the same bits from any checkpoint.
///
/// 600 Hz because every frame rate of a document (24, 25, 30, 50 and 60) lands exactly on it: the step of frame `n`
/// is `n × 600 / frameRate`, in integers. Step `s` stands for output time `s × 10⁹ / 600` ns, which is a whole
/// nanosecond only every third step; a path reads its inputs (raw positions, zoom blocks) at `outputTime(ofStep:)`,
/// that time rounded.
public enum StepGrid {
    /// Steps per second of output.
    public static let rate = 600
    /// Steps between two checkpoints of a path.
    public static let checkpointEvery = 600

    /// The step of frame `n` at `frameRate`: `n × 600 / frameRate`, exact for 24, 25, 30, 50 and 60 fps (0 for a frame
    /// rate that is not positive; held at the ends of `Int` for an `n` too large for it).
    public static func step(frame n: Int, frameRate: Int) -> Int {
        guard frameRate > 0 else { return 0 }
        let (product, overflow) = n.multipliedReportingOverflow(by: rate)
        if overflow { return n < 0 ? .min : .max }
        return product / frameRate
    }

    /// Where output time `τ` (ns) is on the grid, in integers: with `r = (τ × 600) mod 10⁹`, the step itself
    /// (`round(τ × 600 / 10⁹)`, fraction 0) when `r ≤ 600` or `r ≥ 10⁹ − 600`, the step before it and `r / 10⁹`
    /// otherwise. Rounding a frame's time to nanoseconds moves it at most 1/3 ns, 200 of those units, so every frame
    /// of `TimeMap.frameTime(_:frameRate:)` from 24 to 60 fps is exactly on its step, and a frame of the export or of
    /// the paused preview reads that step rather than a mix of two (design §8.6).
    public static func position(ofOutput τ: Int64) -> (step: Int, fraction: Double) {
        let (quotient, remainder) = flooredSteps(τ)
        if remainder <= snap { return (quotient, 0) }
        if remainder >= nanosecondsPerSecond - snap { return (quotient + 1, 0) }
        return (quotient, Double(remainder) / Double(nanosecondsPerSecond))
    }

    /// One step of 1/600 s of `spring` from `x` at velocity `v` toward `target`, semi-implicit Euler (the integration
    /// of `SpringValue`, without its settling): `a = −ω²(x − target) − 2ζωv` with ω = 2π / response and ζ = damping,
    /// then `v += a·dt` and `x += v·dt`.
    public static func spring(_ x: inout Double, _ v: inout Double, target: Double, _ spring: SpringSpec) {
        let omega = 2 * Double.pi / spring.response
        let acceleration = -omega * omega * (x - target) - 2 * spring.damping * omega * v
        v += acceleration * stepSeconds
        x += v * stepSeconds
    }

    /// `spring` where `spring(_:_:target:_:)` stays stable at 600 Hz: a response of at least 0.06 s (0.16 s if it is
    /// not a number) and a damping from 0 to 2 (1 if it is not a number); every spring of the design is already there.
    /// One step multiplies (x, v·h) by a matrix of determinant 1 − 2ζωh and trace 2 − 2ζωh − ω²h² (h = 1/600 s); it is
    /// stable while 0 ≤ ζωh ≤ 1 − ω²h²/4. A response of 0.06 s makes ωh ≈ 0.175, so a damping of 2 (ζωh ≈ 0.35) has
    /// room to spare; a response of 0 or a damping of 100 would diverge to infinity and then to NaN.
    public static func stable(_ spring: SpringSpec) -> SpringSpec {
        SpringSpec(
            damping: spring.damping.isNaN ? 1 : min(max(spring.damping, 0), 2),
            response: spring.response.isNaN ? 0.16 : max(spring.response, 0.06))
    }

    // MARK: - Internal

    /// 1/600 s.
    static let stepSeconds = 1.0 / Double(rate)

    /// Output time of step `s`: `s × 10⁹ / 600` ns rounded to the nearest (it is never a half), held at the ends of
    /// `Int64`.
    static func outputTime(ofStep s: Int) -> Int64 {
        // s × 10⁹ / 600 = 5_000_000 × ⌊s / 3⌋ + 5_000_000 × (s mod 3) / 3, the last one 0, 1_666_666.67 or 3_333_333.33,
        // rounded as ⌊(10_000_000 × (s mod 3) + 3) / 6⌋: 0, 1_666_667 or 3_333_333.
        var (thirds, part) = s.quotientAndRemainder(dividingBy: 3)
        if part < 0 { (thirds, part) = (thirds - 1, part + 3) }
        let (whole, overflow) = Int64(thirds).multipliedReportingOverflow(by: 5_000_000)
        if overflow { return thirds < 0 ? .min : .max }
        let (sum, over) = whole.addingReportingOverflow((10_000_000 * Int64(part) + 3) / 6)
        return over ? .max : sum
    }

    /// The step nearest to output time `τ`: `round(τ × 600 / 10⁹)`, halves up.
    static func nearestStep(toOutput τ: Int64) -> Int {
        let (quotient, remainder) = flooredSteps(τ)
        return 2 * remainder >= nanosecondsPerSecond ? quotient + 1 : quotient
    }

    /// The first step from 0 on whose `outputTime(ofStep:)` is at or after `τ`.
    static func firstStep(atOrAfter τ: Int64) -> Int {
        guard τ > 0 else { return 0 }
        var step = nearestStep(toOutput: τ)
        while outputTime(ofStep: step) < τ { step += 1 }
        while step > 0, outputTime(ofStep: step - 1) >= τ { step -= 1 }
        return step
    }

    // MARK: - Private

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000
    /// In units of 10⁻⁹ step: 1 ns of output.
    private static let snap: Int64 = 600

    /// `⌊τ × 600 / 10⁹⌋` and `(τ × 600) mod 10⁹`, never negative, in full width so no `τ` overflows.
    private static func flooredSteps(_ τ: Int64) -> (quotient: Int, remainder: Int64) {
        var (quotient, remainder) = nanosecondsPerSecond.dividingFullWidth(τ.multipliedFullWidth(by: Int64(rate)))
        if remainder < 0 { (quotient, remainder) = (quotient - 1, remainder + nanosecondsPerSecond) }
        return (Int(quotient), remainder)
    }
}
