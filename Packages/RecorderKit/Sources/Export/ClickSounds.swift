// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The click sounds of `CursorStyle.clickSound`, made in code (plan decision 2: no audio file, nothing downloaded, nothing
/// to credit): mono at 48 kHz, at most 60 ms, peaks at most 0.5, they start and end at 0 and their mean is 0, so a sound
/// never clicks at its own edges nor moves the mix off its centre.
///
/// Each is a function of its id alone, frozen with it like everything else whose look is defined in code: the noise
/// comes from an integer hash of the sample's index, never from a random number. `EditedMix` plays one per left or
/// right `mouseDown` kept, at its output time, at `clickSoundGain`, never stretched.
public enum ClickSounds {
    public static let ids = ["soft-1", "mechanical-1"]
    /// Two clicks closer than this in output time sound once (design §7.7): 40 ms, in nanoseconds.
    public static let minimumSpacing: Int64 = 40_000_000

    /// The samples of sound `id`; `nil` for `none` or any id that is not one of `ids`.
    public static func samples(_ id: String) -> [Float]? {
        switch id {
        case "soft-1": soft
        case "mechanical-1": mechanical
        default: nil
        }
    }

    private static let rate = 48_000.0

    /// A soft knock, 45 ms: hash noise through two one-pole low-passes at 1.8 kHz with an exponential decay of 6 ms,
    /// over a short low tone (140 Hz, decaying in 11 ms).
    private static let soft: [Float] = {
        let count = 2_160
        let smoothing = 1 - exp(-2 * Double.pi * 1_800 / rate)
        var low = 0.0, lower = 0.0
        let samples = (0..<count).map { n -> Double in
            let t = Double(n)
            low += smoothing * (noise(n, seed: 0x50F7_0001) - low)
            lower += smoothing * (low - lower)
            let knock = 3 * lower * exp(-t / 300)
            let thump = 0.8 * sin(2 * Double.pi * 140 * t / rate) * exp(-t / 520)
            return knock + thump
        }
        return finished(samples, attack: 96, release: 480, peak: 0.42)
    }()

    /// A key, 55 ms: a strike as it goes down and a softer one 29 ms later as it comes back up, each a burst of
    /// differentiated hash noise that dies in under a millisecond, ringing at a resonance of its own (2.35 and 2.9 kHz)
    /// over the body of the key (620 Hz).
    private static let mechanical: [Float] = {
        let count = 2_640, release = 1_392
        let samples = (0..<count).map { n -> Double in
            var value = strike(n, resonance: 2_350, seed: 0x3E7A_0001)
            if n >= release { value += 0.55 * strike(n - release, resonance: 2_900, seed: 0x3E7A_0002) }
            return value
        }
        return finished(samples, attack: 12, release: 192, peak: 0.48)
    }()

    /// Frame `n` of one strike of the key: the click of the noise, the ring of `resonance` Hz and the body.
    private static func strike(_ n: Int, resonance: Double, seed: UInt32) -> Double {
        let t = Double(n)
        let click = 0.5 * (noise(n, seed: seed) - noise(n - 1, seed: seed)) * exp(-t / 36)
        let ring = 0.6 * sin(2 * Double.pi * resonance * t / rate) * exp(-t / 170)
        let body = 0.35 * sin(2 * Double.pi * 620 * t / rate) * exp(-t / 400)
        return click + ring + body
    }

    /// `samples` shaped into a sound: a raised-cosine rise over the first `attack` frames and fall over the last
    /// `release` (both exactly 0 at the ends), its mean taken out along that same shape (so the ends stay 0), scaled to
    /// `peak`, its ends +0 (a negative sample times 0 is −0).
    private static func finished(_ samples: [Double], attack: Int, release: Int, peak: Double) -> [Float] {
        let count = samples.count
        let shape = (0..<count).map { n -> Double in
            var value = 1.0
            if n < attack { value *= (1 - cos(Double.pi * Double(n) / Double(attack))) / 2 }
            let fromEnd = count - 1 - n
            if fromEnd < release { value *= (1 - cos(Double.pi * Double(fromEnd) / Double(release))) / 2 }
            return value
        }
        var shaped = zip(samples, shape).map { $0 * $1 }
        let offset = shaped.reduce(0, +) / shape.reduce(0, +)
        for n in shaped.indices { shaped[n] -= offset * shape[n] }
        let largest = shaped.map(abs).max() ?? 0
        let scale = largest > 0 ? peak / largest : 0
        var sound = shaped.map { Float($0 * scale) }
        sound[0] = 0
        sound[count - 1] = 0
        return sound
    }

    /// A value in [−1, 1] from frame `n` and `seed` alone: Chris Wellons' `lowbias32` hash.
    private static func noise(_ n: Int, seed: UInt32) -> Double {
        var x = UInt32(truncatingIfNeeded: n) &* 0x9E37_79B9 ^ seed
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return Double(x) / Double(UInt32.max) * 2 - 1
    }
}
