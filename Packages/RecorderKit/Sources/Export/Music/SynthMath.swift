// SPDX-License-Identifier: GPL-3.0-or-later

// The arithmetic of `music-1`: everything a sample of the music library goes through is built from `+ − × ÷` and
// `squareRoot()` in `Double`, which IEEE 754 rounds the same way on every Mac, and from exact operations (rounding to an
// integer, integer arithmetic, bit patterns). Never `sin`, `exp`, `pow` or `log` of libm, whose last bits may change with
// macOS, and never a reduction of Accelerate, whose order of additions may change with the machine (Global Constraints of
// milestone 3c). The polynomials here are Taylor series on a reduced range, evaluated by Horner's rule, so every value is
// the same bits everywhere: a theme's bytes are pinned in its test.

/// SplitMix64 (Steele, Lea and Flood, 2014; the reference of Vigna's `splitmix64.c`): the only source of randomness of the
/// music library. Each voice of a theme gets its own, seeded with `mix(_:)` of the theme's seed, its part and its note, so
/// nothing depends on time, on another voice or on the order threads run in.
///
/// It is deliberately not a `RandomNumberGenerator`: `Double.random(in:using:)` and the like may change how they use the
/// bits between versions of Swift. Use `unit()`, `bipolar()` or `next()`.
public struct SynthRandom: Sendable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// The next 64 bits.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in [0, 1): the top 53 bits of `next()` times 2⁻⁵³.
    public mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// A number in [−1, 1): `2 · unit() − 1`.
    public mutating func bipolar() -> Double {
        unit() * 2 - 1
    }

    /// A number in [`low`, `high`): `low + (high − low) · unit()`.
    public mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    /// One seed made from `values`, in their order: each is folded in through a step of SplitMix64, so seeds that differ
    /// in one value differ in every bit. `mix(themeSeed, part, note)` seeds a voice.
    public static func mix(_ values: UInt64...) -> UInt64 {
        var hash: UInt64 = 0x6A09_E667_F3BC_C908
        for value in values {
            var random = SynthRandom(seed: hash ^ value)
            hash = random.next()
        }
        return hash
    }
}

/// Sine, `exp2`, `tanh` and the conversions `music-1` needs, in pure Swift (see the top of this file). Each is within a
/// few units in the last place of the true value; what matters more is that it is the same value on every Mac.
public enum SynthMath {
    /// 2π, the `Double` nearest to it.
    static let twoPi = 6.283185307179586
    /// ln 2 and log₂ e, the `Double`s nearest to them.
    static let ln2 = 0.6931471805599453
    static let log2e = 1.4426950408889634
    /// log₂ 10 / 20: `exp2(dB × decibelsToOctaves)` is the amplitude of `dB` decibels.
    static let decibelsToOctaves = 0.16609640474436813

    // MARK: Sine and cosine

    /// sin(2π·`cycles`): the sine of a phase measured in turns, so an oscillator keeps its phase in [0, 1) and never loses
    /// precision. Within a unit or two in the last place (its tests check 1e-14; the plan asks 1e-9). Not a number for an
    /// infinite or not-a-number phase.
    ///
    /// The phase is reduced exactly to r ∈ [−½, ½] and then to a quarter turn q and f ∈ [−⅛, ⅛], and sin or cos of 2πf
    /// (|2πf| ≤ π/4) is a Taylor polynomial to the 15th or 16th power, whose first term left out is under 5e-17.
    public static func sine(cycles: Double) -> Double {
        sinCos(cycles, quarter: 0)
    }

    /// cos(2π·`cycles`), as `sine(cycles:)`: a quarter turn more, added to the quadrant (exactly), not to the phase.
    public static func cosine(cycles: Double) -> Double {
        sinCos(cycles, quarter: 1)
    }

    /// tan(2π·`cycles`), `sine / cosine`. The bilinear transform's tan(π·f/fs) is `tan(cycles: f / (2·fs))`.
    public static func tan(cycles: Double) -> Double {
        sine(cycles: cycles) / cosine(cycles: cycles)
    }

    private static func sinCos(_ cycles: Double, quarter: Int) -> Double {
        guard cycles.isFinite else { return .nan }
        let r = cycles - cycles.rounded(.toNearestOrEven)
        let q = (r * 4).rounded(.toNearestOrEven)
        // Exact: r · 4 and q / 4 only move the exponent, and r − q/4 is a difference of nearby numbers.
        let t = (r - q * 0.25) * twoPi
        switch (Int(q) + quarter) & 3 {
        case 0: return sinPolynomial(t)
        case 1: return cosPolynomial(t)
        case 2: return -sinPolynomial(t)
        default: return -cosPolynomial(t)
        }
    }

    /// sin t for |t| ≤ π/4.
    private static func sinPolynomial(_ t: Double) -> Double {
        let s = t * t
        var p = -1.0 / 1_307_674_368_000.0
        p = p * s + 1.0 / 6_227_020_800.0
        p = p * s - 1.0 / 39_916_800.0
        p = p * s + 1.0 / 362_880.0
        p = p * s - 1.0 / 5_040.0
        p = p * s + 1.0 / 120.0
        p = p * s - 1.0 / 6.0
        return t + t * s * p
    }

    /// cos t for |t| ≤ π/4.
    private static func cosPolynomial(_ t: Double) -> Double {
        let s = t * t
        var p = 1.0 / 20_922_789_888_000.0
        p = p * s - 1.0 / 87_178_291_200.0
        p = p * s + 1.0 / 479_001_600.0
        p = p * s - 1.0 / 3_628_800.0
        p = p * s + 1.0 / 40_320.0
        p = p * s - 1.0 / 720.0
        p = p * s + 1.0 / 24.0
        p = p * s - 0.5
        return 1 + s * p
    }

    // MARK: Powers of two

    /// 2ˣ, within a unit or two in the last place (its tests check a relative 1e-12 in [−64, 64], as the plan asks, and
    /// 2ˣ·2⁻ˣ within 1e-15 of 1). 0 under −1022 (the music never goes that quiet), +∞ over 1023, and not a number for not
    /// a number.
    ///
    /// x = n + f with n an integer and f ∈ [−½, ½]; 2ᶠ = eʸ with y = f·ln 2, a Taylor polynomial to the 13th power (the
    /// first term left out is under 5e-18); 2ⁿ is built from its bits.
    public static func exp2(_ x: Double) -> Double {
        if x.isNaN { return x }
        if x > 1023 { return .infinity }
        if x < -1022 { return 0 }
        let n = x.rounded(.toNearestOrEven)
        let y = (x - n) * ln2
        return expPolynomial(y) * Double(bitPattern: UInt64(1023 + Int(n)) << 52)
    }

    /// eʸ for |y| ≤ ln 2 / 2.
    private static func expPolynomial(_ y: Double) -> Double {
        1 + expMinusOnePolynomial(y)
    }

    /// eʸ − 1 for |y| ≤ ln 2 / 2, without the cancellation of `eʸ − 1` near 0.
    private static func expMinusOnePolynomial(_ y: Double) -> Double {
        var p = 1.0 / 6_227_020_800.0
        p = p * y + 1.0 / 479_001_600.0
        p = p * y + 1.0 / 39_916_800.0
        p = p * y + 1.0 / 3_628_800.0
        p = p * y + 1.0 / 362_880.0
        p = p * y + 1.0 / 40_320.0
        p = p * y + 1.0 / 5_040.0
        p = p * y + 1.0 / 720.0
        p = p * y + 1.0 / 120.0
        p = p * y + 1.0 / 24.0
        p = p * y + 1.0 / 6.0
        p = p * y + 0.5
        p = p * y + 1
        return p * y
    }

    /// eˣ, as `exp2(x · log₂ e)`.
    public static func exp(_ x: Double) -> Double {
        exp2(x * log2e)
    }

    // MARK: Hyperbolic tangent

    /// tanh x, odd, in (−1, 1), with a relative error of a few units in the last place: −(e⁻²ᵃ − 1)/(e⁻²ᵃ + 1) for
    /// a = |x|, with e⁻²ᵃ − 1 from its own polynomial while 2a ≤ ln 2 / 2, so small values keep their precision. ±1 from
    /// |x| = 22 on, where the true value rounds to it.
    public static func tanh(_ x: Double) -> Double {
        if x.isNaN { return x }
        let a = x.magnitude
        if a >= 22 { return x < 0 ? -1 : 1 }
        let y = -2 * a
        let t: Double
        if y >= -0.5 * ln2 {
            let m = expMinusOnePolynomial(y)
            t = -m / (2 + m)
        } else {
            let e = exp2(y * log2e)
            t = (1 - e) / (1 + e)
        }
        return x < 0 ? -t : t
    }

    // MARK: Conversions

    /// The frequency of MIDI pitch `midi` (69 is A4, 440 Hz; fractions are cents): 440 · 2^((p − 69)/12).
    public static func frequency(midi: Double) -> Double {
        440 * exp2((midi - 69) / 12)
    }

    /// The amplitude of `decibels` dB: 10^(dB/20), as `exp2(dB · log₂ 10 / 20)`.
    public static func gain(decibels: Double) -> Double {
        exp2(decibels * decibelsToOctaves)
    }

    /// The ratio of `cents` cents: 2^(cents/1200).
    public static func ratio(cents: Double) -> Double {
        exp2(cents / 1200)
    }

    /// The factor that, applied once a frame at `sampleRate`, takes a value to 1/e of itself in `seconds`: e^(−1/(s·fs)).
    /// 0 for a time that is not positive (at once).
    public static func decayFactor(seconds: Double, sampleRate: Double = 48_000) -> Double {
        guard seconds > 0 else { return 0 }
        return exp2(-log2e / (seconds * sampleRate))
    }

    /// The factor that, applied once a frame, lowers a value by 60 dB in `seconds` (a reverberation time, T60):
    /// 10^(−3/(s·fs)). 0 for a time that is not positive.
    public static func t60Factor(seconds: Double, sampleRate: Double = 48_000) -> Double {
        guard seconds > 0 else { return 0 }
        return gain(decibels: -60 / (seconds * sampleRate))
    }

    /// The feedback coefficient of a one-pole low-pass at `cutoff` Hz: e^(−2π·fc/fs), in [0, 1).
    public static func onePole(cutoff: Double, sampleRate: Double = 48_000) -> Double {
        let fc = min(max(cutoff, 0), sampleRate / 2)
        return exp2(-twoPi * fc / sampleRate * log2e)
    }

    /// `(left, right)` gains of an equal-power pan: `pan` −1 is all left, 0 is both at √½, 1 all right.
    public static func panGains(_ pan: Double) -> (left: Double, right: Double) {
        let p = pan.isFinite ? min(max(pan, -1), 1) : 0
        let turn = (p + 1) / 8
        return (cosine(cycles: turn), sine(cycles: turn))
    }

    /// The smooth step 3u² − 2u³ of `u` clamped to [0, 1]: 0 at 0 and 1 at 1, with no slope at either end.
    public static func smoothstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
