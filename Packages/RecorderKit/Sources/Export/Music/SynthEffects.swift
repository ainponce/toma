// SPDX-License-Identifier: GPL-3.0-or-later

// The effects of `music-1`: a reverb (a feedback delay network of 8 lines), a stereo delay at the score's tempo and a
// chorus, and the filters they and the voices share. All of them are linear, so the tail that passes the loop's end can
// be folded onto its start (`MusicSynth`, plan decision 3); the chorus is the only one that changes with time, and its
// LFO turns a whole number of times per loop. Arithmetic only as `SynthMath` allows.

// MARK: - Settings

/// The score's reverb: one for the whole theme, fed by each part's `reverbSend`.
public struct ReverbSettings: Sendable, Equatable {
    /// The time the reverb takes to fall 60 dB (T60), in seconds: 0.1 to 3 (outside, the nearest), so its tail is under
    /// −120 dB before `MusicSynth.tailFrames` are over.
    public var decay: Double
    /// The size of the room: scales the lengths of the lines, 0.3 (a small room) to 2 (a hall); 1 is about 30 to 70 ms.
    public var size: Double
    /// Above this frequency, in Hz, the tail fades faster (a one-pole low-pass in each line): 1 000 is dark, 10 000 bright.
    public var damping: Double
    /// What comes in waits this long, in seconds (0 to 0.25), before the room answers.
    public var preDelay: Double
    /// What comes in is high-passed at this frequency, in Hz, so the low end stays dry and clear.
    public var lowCut: Double
    /// The stereo width of what comes out: 0 is mono, 1 the network's own width.
    public var width: Double
    /// The level of what comes out, as an amplitude.
    public var level: Double

    public init(
        decay: Double = 2.2, size: Double = 1, damping: Double = 6_000, preDelay: Double = 0.02, lowCut: Double = 180,
        width: Double = 1, level: Double = 1
    ) {
        self.decay = decay
        self.size = size
        self.damping = damping
        self.preDelay = preDelay
        self.lowCut = lowCut
        self.width = width
        self.level = level
    }

    /// No reverb at all.
    public static let none = ReverbSettings(level: 0)
    /// A small, warm room.
    public static let room = ReverbSettings(decay: 1.1, size: 0.6, damping: 5_000, preDelay: 0.01, lowCut: 200)
    /// A medium hall, the default.
    public static let hall = ReverbSettings()
    /// A long, soft space for ambient pads.
    public static let cathedral = ReverbSettings(decay: 3, size: 1.8, damping: 4_500, preDelay: 0.04, lowCut: 150)
}

/// The score's delay: echoes at the tempo, fed by each part's `delaySend`.
public struct DelaySettings: Sendable, Equatable {
    /// The time between echoes, in beats of the score (0.75 is a dotted eighth in 4/4), from 1/64 of a beat to 4 s.
    public var beats: Double
    /// How much of each echo comes back (0 to 0.95); capped so the echoes are under −120 dB within 6 s, inside the tail.
    public var feedback: Double
    /// Whether the echoes go from one side to the other (the first on the left).
    public var pingPong: Bool
    /// The echoes lose their lows under this frequency, in Hz, and their highs over `highCut`, a little more each time.
    public var lowCut: Double
    public var highCut: Double
    /// The level of the echoes, as an amplitude.
    public var level: Double

    public init(
        beats: Double = 0.75, feedback: Double = 0.3, pingPong: Bool = true, lowCut: Double = 300, highCut: Double = 4_500,
        level: Double = 1
    ) {
        self.beats = beats
        self.feedback = feedback
        self.pingPong = pingPong
        self.lowCut = lowCut
        self.highCut = highCut
        self.level = level
    }
}

/// A chorus on one part: two copies of it, each a little late by a time that sways, one on each side.
public struct ChorusSettings: Sendable, Equatable {
    /// How loud the copies are, as an amplitude next to the part's own sound (0 to 1).
    public var mix: Double
    /// Their mean delay and how far it sways, in seconds.
    public var delay: Double
    public var depth: Double
    /// How often it sways, in Hz: rounded to a whole number of times per loop (at least one), so the loop has no seam.
    public var rate: Double

    public init(mix: Double = 0.4, delay: Double = 0.012, depth: Double = 0.003, rate: Double = 0.4) {
        self.mix = mix
        self.delay = delay
        self.depth = depth
        self.rate = rate
    }

    /// The gentle widening of a pad or an electric piano.
    public static let gentle = ChorusSettings()
    /// A deeper, slower sway.
    public static let lush = ChorusSettings(mix: 0.6, delay: 0.018, depth: 0.006, rate: 0.25)
}

// MARK: - Filters

/// A one-pole low-pass: y += (1 − a)(x − y), a = e^(−2π·fc/fs).
struct OnePole {
    private var a: Double
    private var y = 0.0

    init(cutoff: Double, sampleRate: Double = 48_000) {
        a = SynthMath.onePole(cutoff: cutoff, sampleRate: sampleRate)
    }

    mutating func lowPass(_ x: Double) -> Double {
        y = x + a * (y - x)
        return y
    }

    /// `x` minus its low-pass: a one-pole high-pass.
    mutating func highPass(_ x: Double) -> Double {
        x - lowPass(x)
    }
}

/// A second-order Butterworth filter by the bilinear transform, in transposed direct form II.
struct Biquad {
    private var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    enum Kind { case lowPass, highPass }

    init(_ kind: Kind, cutoff: Double, sampleRate: Double = 48_000) {
        let fc = min(max(cutoff, 1), sampleRate * 0.49)
        let k = SynthMath.tan(cycles: fc / (2 * sampleRate))
        let q = 0.5.squareRoot() // 1/√2
        let norm = 1 / (1 + k / q + k * k)
        switch kind {
        case .lowPass:
            b0 = k * k * norm
            b1 = 2 * b0
            b2 = b0
        case .highPass:
            b0 = norm
            b1 = -2 * norm
            b2 = norm
        }
        a1 = 2 * (k * k - 1) * norm
        a2 = (1 - k / q + k * k) * norm
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// The state-variable filter of the topology-preserving transform (Zavalishin): stable while its cutoff moves, which a
/// voice's envelope does. `set` is the costly part (a tangent); voices call it every `MusicSynth.controlFrames`.
struct StateVariableFilter {
    private var ic1 = 0.0, ic2 = 0.0
    private var a1 = 0.0, a2 = 0.0, a3 = 0.0, k = 2.0

    /// Cutoff in Hz (kept between 20 Hz and 0.45·fs) and resonance 0 (none, Q ½) to 1 (just short of ringing).
    mutating func set(cutoff: Double, resonance: Double, sampleRate: Double = 48_000) {
        let fc = min(max(cutoff, 20), sampleRate * 0.45)
        let g = SynthMath.tan(cycles: fc / (2 * sampleRate))
        k = 2 - 1.96 * min(max(resonance, 0), 1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// One sample in; the low-pass, band-pass and high-pass out.
    mutating func process(_ x: Double) -> (low: Double, band: Double, high: Double) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }

    mutating func lowPass(_ x: Double) -> Double { process(x).low }
    mutating func bandPass(_ x: Double) -> Double { process(x).band }
    mutating func highPass(_ x: Double) -> Double { process(x).high }
}

/// A ring of `count` samples, read `count` samples after they were written (or less, with `read(back:)`).
struct DelayLine {
    private(set) var count: Int
    private var buffer: [Double]
    private var position = 0

    init(count: Int) {
        self.count = max(count, 1)
        buffer = [Double](repeating: 0, count: self.count)
    }

    /// The sample written `count` samples ago: what `write` will replace.
    var oldest: Double { buffer[position] }

    /// The sample written `back` samples ago (1 ... `count`), with linear interpolation between samples.
    func read(back: Double) -> Double {
        let d = min(max(back, 1), Double(count))
        let whole = Int(d.rounded(.down))
        let fraction = d - Double(whole)
        var i = position - whole
        if i < 0 { i += count }
        var j = i - 1
        if j < 0 { j += count }
        let a = buffer[i]
        return a + (buffer[j] - a) * fraction
    }

    mutating func write(_ x: Double) {
        buffer[position] = x
        position += 1
        if position == count { position = 0 }
    }
}

/// A Schroeder all-pass, `g` of feedback over a delay of `count` samples: it smears a sound in time without colouring it.
struct AllPass {
    private var line: DelayLine
    private let g: Double

    init(count: Int, g: Double) {
        line = DelayLine(count: count)
        self.g = g
    }

    mutating func process(_ x: Double) -> Double {
        let delayed = line.oldest
        let v = x + g * delayed
        line.write(v)
        return delayed - g * v
    }
}

/// The smallest prime ≥ `n` (n ≥ 2): the lengths of the reverb's lines, so their echoes never line up.
func nextPrime(_ n: Int) -> Int {
    var candidate = max(n, 2)
    while true {
        var isPrime = true
        var divisor = 2
        while divisor * divisor <= candidate {
            if candidate % divisor == 0 {
                isPrime = false
                break
            }
            divisor += 1
        }
        if isPrime { return candidate }
        candidate += 1
    }
}

// MARK: - Effects

/// The reverb: a pre-delay and a high-pass on what comes in, two all-passes on each side to diffuse it, then a feedback
/// delay network of 8 lines of prime lengths mixed by a Hadamard matrix, each with the gain of `decay` for its length and
/// a one-pole low-pass (`damping`). Linear and time-invariant.
struct FDNReverb {
    /// The lines' lengths at size 1, in seconds.
    static let baseLengths = [0.0297, 0.0371, 0.0411, 0.0437, 0.0479, 0.0533, 0.0599, 0.0671]
    static let maxDecay = 3.0

    private var lines: [DelayLine]
    private var gains: [Double]
    private var lows: [Double]
    private let dampingCoefficient: Double
    private var preDelayLeft: DelayLine
    private var preDelayRight: DelayLine
    private let preDelayFrames: Int
    private var lowCutLeft: OnePole
    private var lowCutRight: OnePole
    private var diffusers: [AllPass]
    private let width: Double
    private let level: Double

    init(_ settings: ReverbSettings, sampleRate: Double = 48_000) {
        let size = min(max(settings.size.isFinite ? settings.size : 1, 0.3), 2)
        let decay = min(max(settings.decay.isFinite ? settings.decay : 1, 0.1), Self.maxDecay)
        let lengths = Self.baseLengths.map { nextPrime(Int(($0 * size * sampleRate).rounded(.toNearestOrEven))) }
        lines = lengths.map { DelayLine(count: $0) }
        gains = lengths.map { SynthMath.gain(decibels: -60 * Double($0) / (decay * sampleRate)) }
        lows = [Double](repeating: 0, count: lengths.count)
        dampingCoefficient = SynthMath.onePole(cutoff: settings.damping.isFinite ? settings.damping : 6_000, sampleRate: sampleRate)
        let preDelay = min(max(settings.preDelay.isFinite ? settings.preDelay : 0, 0), 0.25)
        preDelayFrames = Int((preDelay * sampleRate).rounded(.toNearestOrEven))
        preDelayLeft = DelayLine(count: max(preDelayFrames, 1))
        preDelayRight = DelayLine(count: max(preDelayFrames, 1))
        lowCutLeft = OnePole(cutoff: settings.lowCut.isFinite ? settings.lowCut : 0, sampleRate: sampleRate)
        lowCutRight = OnePole(cutoff: settings.lowCut.isFinite ? settings.lowCut : 0, sampleRate: sampleRate)
        let diffusion = [0.0047, 0.0036, 0.0127, 0.0093].map { nextPrime(Int(($0 * size * sampleRate).rounded(.toNearestOrEven))) }
        diffusers = [
            AllPass(count: diffusion[0], g: 0.6), AllPass(count: diffusion[2], g: 0.6),
            AllPass(count: diffusion[1], g: 0.6), AllPass(count: diffusion[3], g: 0.6),
        ]
        width = min(max(settings.width.isFinite ? settings.width : 1, 0), 1)
        level = settings.level.isFinite ? max(settings.level, 0) : 0
    }

    /// Adds the reverb of the `frames` stereo frames of `input` to `output`, both interleaved.
    mutating func process(_ input: UnsafePointer<Double>, adding output: UnsafeMutablePointer<Double>, frames: Int) {
        guard level > 0 else { return }
        let norm = 1 / 8.0.squareRoot()
        let a = dampingCoefficient
        var d = [Double](repeating: 0, count: 8)
        for f in 0..<frames {
            var left = input[2 * f]
            var right = input[2 * f + 1]
            if preDelayFrames > 0 {
                let l = preDelayLeft.oldest, r = preDelayRight.oldest
                preDelayLeft.write(left)
                preDelayRight.write(right)
                left = l
                right = r
            }
            left = diffusers[1].process(diffusers[0].process(lowCutLeft.highPass(left)))
            right = diffusers[3].process(diffusers[2].process(lowCutRight.highPass(right)))
            for i in 0..<8 {
                d[i] = lines[i].oldest
            }
            // The damped, decayed lines…
            var v0 = gains[0] * damp(0, d[0], a), v1 = gains[1] * damp(1, d[1], a)
            var v2 = gains[2] * damp(2, d[2], a), v3 = gains[3] * damp(3, d[3], a)
            var v4 = gains[4] * damp(4, d[4], a), v5 = gains[5] * damp(5, d[5], a)
            var v6 = gains[6] * damp(6, d[6], a), v7 = gains[7] * damp(7, d[7], a)
            // …mixed by the 8 × 8 Hadamard matrix (three stages of butterflies), scaled to be orthogonal.
            (v0, v1) = (v0 + v1, v0 - v1); (v2, v3) = (v2 + v3, v2 - v3)
            (v4, v5) = (v4 + v5, v4 - v5); (v6, v7) = (v6 + v7, v6 - v7)
            (v0, v2) = (v0 + v2, v0 - v2); (v1, v3) = (v1 + v3, v1 - v3)
            (v4, v6) = (v4 + v6, v4 - v6); (v5, v7) = (v5 + v7, v5 - v7)
            (v0, v4) = (v0 + v4, v0 - v4); (v1, v5) = (v1 + v5, v1 - v5)
            (v2, v6) = (v2 + v6, v2 - v6); (v3, v7) = (v3 + v7, v3 - v7)
            // What comes in: the left on the even lines, the right on the odd ones, with alternating signs.
            lines[0].write(v0 * norm + left)
            lines[1].write(v1 * norm + right)
            lines[2].write(v2 * norm - left)
            lines[3].write(v3 * norm - right)
            lines[4].write(v4 * norm + left)
            lines[5].write(v5 * norm + right)
            lines[6].write(v6 * norm - left)
            lines[7].write(v7 * norm - right)
            // Two orthogonal rows of the matrix for the two sides.
            let outLeft = (d[0] - d[1] + d[2] - d[3] + d[4] - d[5] + d[6] - d[7]) * norm
            let outRight = (d[0] + d[1] - d[2] - d[3] + d[4] + d[5] - d[6] - d[7]) * norm
            let mid = (outLeft + outRight) * 0.5
            let side = (outLeft - outRight) * 0.5 * width
            output[2 * f] += (mid + side) * level
            output[2 * f + 1] += (mid - side) * level
        }
    }

    private mutating func damp(_ i: Int, _ x: Double, _ a: Double) -> Double {
        lows[i] = x + a * (lows[i] - x)
        return lows[i]
    }
}

/// The delay: echoes `beats` apart, each through a high-pass and a low-pass, back with `feedback`; ping-pong sends the
/// first to the left and the next one to the other side each time. Linear and time-invariant.
struct StereoDelay {
    private var left: DelayLine
    private var right: DelayLine
    private let feedback: Double
    private let pingPong: Bool
    private let level: Double
    private var lowCutLeft: OnePole, lowCutRight: OnePole
    private var highCutLeft: OnePole, highCutRight: OnePole

    /// The longest delay, in seconds.
    static let maxSeconds = 4.0
    /// The echoes are under −120 dB this long after the last sound came in.
    static let tailSeconds = 6.0

    init(_ settings: DelaySettings, framesPerBeat: Double, sampleRate: Double = 48_000) {
        let wanted = (settings.beats.isFinite ? settings.beats : 0.75) * framesPerBeat
        let frames = Int(min(max(wanted, framesPerBeat / 64), Self.maxSeconds * sampleRate).rounded(.toNearestOrEven))
        left = DelayLine(count: frames)
        right = DelayLine(count: frames)
        let cap = SynthMath.gain(decibels: -120 * Double(left.count) / (Self.tailSeconds * sampleRate))
        feedback = min(max(settings.feedback.isFinite ? settings.feedback : 0, 0), 0.95, cap)
        pingPong = settings.pingPong
        level = settings.level.isFinite ? max(settings.level, 0) : 0
        lowCutLeft = OnePole(cutoff: settings.lowCut, sampleRate: sampleRate)
        lowCutRight = OnePole(cutoff: settings.lowCut, sampleRate: sampleRate)
        highCutLeft = OnePole(cutoff: settings.highCut, sampleRate: sampleRate)
        highCutRight = OnePole(cutoff: settings.highCut, sampleRate: sampleRate)
    }

    /// Adds the echoes of the `frames` stereo frames of `input` to `output`, both interleaved.
    mutating func process(_ input: UnsafePointer<Double>, adding output: UnsafeMutablePointer<Double>, frames: Int) {
        guard level > 0 else { return }
        for f in 0..<frames {
            let echoLeft = left.oldest
            let echoRight = right.oldest
            let backLeft = highCutLeft.lowPass(lowCutLeft.highPass(echoLeft))
            let backRight = highCutRight.lowPass(lowCutRight.highPass(echoRight))
            if pingPong {
                left.write((input[2 * f] + input[2 * f + 1]) * 0.5 + feedback * backRight)
                right.write(feedback * backLeft)
            } else {
                left.write(input[2 * f] + feedback * backLeft)
                right.write(input[2 * f + 1] + feedback * backRight)
            }
            output[2 * f] += echoLeft * level
            output[2 * f + 1] += echoRight * level
        }
    }
}

/// The chorus of a part: the part's mono sum, read back through two delays that sway in quadrature, one per side, added
/// to the part. Its LFO is a function of the frame in the loop (`cycles · t mod loop`, in integers), so it is the same
/// on every pass and the tail lines up with the start.
struct Chorus {
    private var line: DelayLine
    private let mix: Double
    private let delay: Double
    private let depth: Double
    private let cycles: Int
    private let loopFrames: Int

    init(_ settings: ChorusSettings, loopFrames: Int, sampleRate: Double = 48_000) {
        delay = min(max(settings.delay.isFinite ? settings.delay : 0.012, 0.001), 0.05) * sampleRate
        depth = min(max(settings.depth.isFinite ? settings.depth : 0, 0), 0.02) * sampleRate
        mix = min(max(settings.mix.isFinite ? settings.mix : 0, 0), 1)
        let rate = settings.rate.isFinite ? max(settings.rate, 0) : 0
        cycles = max(1, Int((rate * Double(loopFrames) / sampleRate).rounded(.toNearestOrEven)))
        self.loopFrames = loopFrames
        line = DelayLine(count: Int(delay + depth) + 4)
    }

    /// Adds the chorus to the `frames` stereo frames of `buffer`, interleaved, whose first is frame `start` of the render.
    mutating func process(_ buffer: UnsafeMutablePointer<Double>, frames: Int, start: Int) {
        guard mix > 0 else { return }
        for f in 0..<frames {
            let phase = Double((cycles * (start + f)) % loopFrames) / Double(loopFrames)
            let tapLeft = line.read(back: delay + depth * SynthMath.sine(cycles: phase))
            let tapRight = line.read(back: delay + depth * SynthMath.cosine(cycles: phase))
            line.write((buffer[2 * f] + buffer[2 * f + 1]) * 0.5)
            buffer[2 * f] += mix * tapLeft
            buffer[2 * f + 1] += mix * tapRight
        }
    }
}
