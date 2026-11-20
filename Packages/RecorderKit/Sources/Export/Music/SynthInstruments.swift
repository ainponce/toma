// SPDX-License-Identifier: GPL-3.0-or-later

// The instruments of `music-1`: their presets (what a theme chooses) and their voices (what plays one note). A voice is a
// function of its note alone — its pitch, velocity, length, its own `SynthRandom` and, for what sways over the loop, the
// frame in the loop — so it sounds the same on every pass and in any thread. Arithmetic only as `SynthMath` allows.
//
// Levels: a voice at velocity 1 and `level` 1 peaks around 0.5 to 1; a theme balances its parts with `ScorePart.gain`
// and its loudness with `MusicScore.masterGain`.

// MARK: - Presets

/// A pad: detuned saws spread across the stereo field and a sine an octave down, through a low-pass that opens with the
/// note and sways slowly over the loop.
public struct PadPreset: Sendable, Equatable {
    /// How many saws (1 to 7), from the left to the right.
    public var oscillators: Int
    /// The cents between the lowest and the highest saw.
    public var detune: Double
    /// The level of the sine an octave down.
    public var sub: Double
    /// The envelope, in seconds (`sustain` a level): the note fades in, settles and fades out after it is let go.
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    /// The low-pass, in Hz at C4 (MIDI 60), and how much it follows the pitch (0 not at all, 1 an octave per octave).
    public var cutoff: Double
    public var keyTracking: Double
    public var resonance: Double
    /// The octaves the low-pass opens with the envelope.
    public var envelopeAmount: Double
    /// The octaves it sways, and how often, in Hz (a whole number of times per loop).
    public var sweepDepth: Double
    public var sweepRate: Double
    public var level: Double

    public init(
        oscillators: Int = 4, detune: Double = 14, sub: Double = 0.3, attack: Double = 1.5, decay: Double = 2.5,
        sustain: Double = 0.8, release: Double = 2, cutoff: Double = 1_400, keyTracking: Double = 0.4,
        resonance: Double = 0.1, envelopeAmount: Double = 0.8, sweepDepth: Double = 0.5, sweepRate: Double = 0.05,
        level: Double = 1
    ) {
        self.oscillators = oscillators
        self.detune = detune
        self.sub = sub
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.cutoff = cutoff
        self.keyTracking = keyTracking
        self.resonance = resonance
        self.envelopeAmount = envelopeAmount
        self.sweepDepth = sweepDepth
        self.sweepRate = sweepRate
        self.level = level
    }

    /// Warm and slow, for ambient chords.
    public static let warm = PadPreset()
    /// Brighter and airier, with more saws.
    public static let airy = PadPreset(
        oscillators: 6, detune: 22, sub: 0.1, attack: 2.5, release: 2, cutoff: 3_200, resonance: 0.15, envelopeAmount: 0.4,
        sweepDepth: 0.8, sweepRate: 0.033)
    /// Short and soft, for chords that move with the beat.
    public static let soft = PadPreset(
        oscillators: 3, detune: 10, sub: 0.2, attack: 0.08, decay: 0.8, sustain: 0.6, release: 0.5, cutoff: 1_100,
        envelopeAmount: 1.2, sweepDepth: 0.2)
}

/// An electric piano: two-operator FM, a bright tine that fades in a moment, the body that decays while held, and a
/// stereo tremolo.
public struct EPianoPreset: Sendable, Equatable {
    /// The modulator's frequency over the carrier's.
    public var ratio: Double
    /// The modulation index at the attack (the brightness; more with velocity), and the time it takes to fall to 1/e.
    public var index: Double
    public var indexDecay: Double
    /// The bell of the attack: a modulator at 14 times the pitch that fades in 50 ms.
    public var tine: Double
    /// The time the note takes to fall to 1/e while held, and to stop after it is let go, in seconds.
    public var decay: Double
    public var release: Double
    /// The tremolo: how much it pans the note from side to side (0 to 1), and how often, in Hz (a whole number of times
    /// per loop).
    public var tremoloDepth: Double
    public var tremoloRate: Double
    public var level: Double

    public init(
        ratio: Double = 1, index: Double = 1.6, indexDecay: Double = 0.6, tine: Double = 0.35, decay: Double = 2.5,
        release: Double = 0.35, tremoloDepth: Double = 0.25, tremoloRate: Double = 3, level: Double = 1
    ) {
        self.ratio = ratio
        self.index = index
        self.indexDecay = indexDecay
        self.tine = tine
        self.decay = decay
        self.release = release
        self.tremoloDepth = tremoloDepth
        self.tremoloRate = tremoloRate
        self.level = level
    }

    /// Round and mellow, for lo-fi chords.
    public static let mellow = EPianoPreset(index: 1.1, tine: 0.2, tremoloDepth: 0.3)
    /// Brighter, with more bell.
    public static let bell = EPianoPreset(ratio: 1, index: 2.4, indexDecay: 0.4, tine: 0.7, decay: 2, tremoloDepth: 0.15)
}

/// An acoustic piano: a few slightly inharmonic partials per string, two or three strings a hair apart, the felt's thump,
/// lower notes ringing longer and to the left.
public struct PianoPreset: Sendable, Equatable {
    /// Partials per string (1 to 16; those over 15 kHz are left out).
    public var partials: Int
    /// How sharp the upper partials are (B of fₙ = n·f₀·√(1 + B·n²)).
    public var inharmonicity: Double
    /// Each partial's level over the one before (0.3 dark to 0.85 bright), brighter with velocity.
    public var brightness: Double
    /// The time C4's fundamental takes to fall to 1/e, in seconds (higher notes less), and how much faster the upper
    /// partials fall.
    public var decay: Double
    public var damping: Double
    /// Strings per note (1 to 3) and the cents between the outermost.
    public var strings: Int
    public var detune: Double
    /// The thump of the felt hammer.
    public var hammer: Double
    /// The time the damper takes to stop the note after it is let go, in seconds.
    public var release: Double
    /// How far low notes go to the left and high ones to the right (0 to 1).
    public var width: Double
    public var level: Double

    public init(
        partials: Int = 10, inharmonicity: Double = 0.0003, brightness: Double = 0.6, decay: Double = 3, damping: Double = 1,
        strings: Int = 2, detune: Double = 0.8, hammer: Double = 0.15, release: Double = 0.3, width: Double = 0.4,
        level: Double = 1
    ) {
        self.partials = partials
        self.inharmonicity = inharmonicity
        self.brightness = brightness
        self.decay = decay
        self.damping = damping
        self.strings = strings
        self.detune = detune
        self.hammer = hammer
        self.release = release
        self.width = width
        self.level = level
    }

    /// Soft and dark, like a felt piano.
    public static let felt = PianoPreset(partials: 8, brightness: 0.45, decay: 2.5, damping: 1.5, hammer: 0.25)
    /// A clearer grand.
    public static let grand = PianoPreset(partials: 12, brightness: 0.68, decay: 3.5, damping: 0.8, strings: 3, detune: 1.2)
}

/// A plucked string (Karplus–Strong): a burst of seeded noise ringing in a tuned delay line.
public struct PluckPreset: Sendable, Equatable {
    /// How bright the pluck is (0 to 1), more with velocity.
    public var brightness: Double
    /// How fast its highs fade as it rings (0 bright to 1 dark).
    public var damping: Double
    /// The time it takes to fall 60 dB while held, in seconds.
    public var decay: Double
    /// Where along the string it is plucked (0.05 near the bridge, thin, to 0.5 the middle, round).
    public var pickPosition: Double
    /// The time the finger takes to stop it after it is let go.
    public var release: Double
    /// How far each note goes to one side or the other, at random (0 to 1).
    public var spread: Double
    public var level: Double

    public init(
        brightness: Double = 0.6, damping: Double = 0.4, decay: Double = 2.5, pickPosition: Double = 0.18,
        release: Double = 0.12, spread: Double = 0.4, level: Double = 1
    ) {
        self.brightness = brightness
        self.damping = damping
        self.decay = decay
        self.pickPosition = pickPosition
        self.release = release
        self.spread = spread
        self.level = level
    }

    /// A nylon guitar or a harp.
    public static let harp = PluckPreset(brightness: 0.55, damping: 0.45, decay: 3, pickPosition: 0.2)
    /// A bright steel string.
    public static let steel = PluckPreset(brightness: 0.85, damping: 0.2, decay: 2.2, pickPosition: 0.12)
    /// A short, muted pluck.
    public static let muted = PluckPreset(brightness: 0.4, damping: 0.8, decay: 0.6, pickPosition: 0.3, release: 0.06)
}

/// A bass: a sine and a saw through a low-pass that opens at the attack, with a little warmth.
public struct BassPreset: Sendable, Equatable {
    /// The levels of the sine and of the saw.
    public var sine: Double
    public var saw: Double
    /// The low-pass, in Hz, the octaves it opens at the attack and the time that takes to close to 1/e.
    public var cutoff: Double
    public var envelopeAmount: Double
    public var filterDecay: Double
    public var resonance: Double
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    /// Saturation, 0 (clean) to 1.
    public var drive: Double
    public var level: Double

    public init(
        sine: Double = 1, saw: Double = 0.35, cutoff: Double = 450, envelopeAmount: Double = 2, filterDecay: Double = 0.18,
        resonance: Double = 0.2, attack: Double = 0.004, decay: Double = 0.6, sustain: Double = 0.75,
        release: Double = 0.08, drive: Double = 0.2, level: Double = 1
    ) {
        self.sine = sine
        self.saw = saw
        self.cutoff = cutoff
        self.envelopeAmount = envelopeAmount
        self.filterDecay = filterDecay
        self.resonance = resonance
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.drive = drive
        self.level = level
    }

    /// Mostly sine, deep and round.
    public static let sub = BassPreset(sine: 1, saw: 0.1, cutoff: 300, envelopeAmount: 1, drive: 0.1)
    /// A round electric bass.
    public static let round = BassPreset()
    /// A brighter synth bass that cuts through.
    public static let synth = BassPreset(sine: 0.6, saw: 0.8, cutoff: 700, envelopeAmount: 2.5, resonance: 0.35, drive: 0.4)
}

/// A lead: a saw or a pulse, two of them a few cents apart (one on each side), through a low-pass, with vibrato that
/// comes in after the note starts.
public struct LeadPreset: Sendable, Equatable {
    /// 0 a saw, 1 a pulse of `pulseWidth` (0.5 is a square).
    public var square: Double
    public var pulseWidth: Double
    /// The cents between the two oscillators.
    public var detune: Double
    public var cutoff: Double
    public var resonance: Double
    /// The octaves the low-pass opens with the envelope.
    public var envelopeAmount: Double
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    /// The vibrato: its depth in cents, its rate in Hz and the time before it comes in, in seconds. It belongs to the
    /// note (it starts with it), so it needs no whole number of cycles per loop.
    public var vibratoDepth: Double
    public var vibratoRate: Double
    public var vibratoDelay: Double
    public var level: Double

    public init(
        square: Double = 0.3, pulseWidth: Double = 0.5, detune: Double = 8, cutoff: Double = 2_400, resonance: Double = 0.15,
        envelopeAmount: Double = 1, attack: Double = 0.01, decay: Double = 0.3, sustain: Double = 0.7,
        release: Double = 0.25, vibratoDepth: Double = 15, vibratoRate: Double = 5, vibratoDelay: Double = 0.3,
        level: Double = 1
    ) {
        self.square = square
        self.pulseWidth = pulseWidth
        self.detune = detune
        self.cutoff = cutoff
        self.resonance = resonance
        self.envelopeAmount = envelopeAmount
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.vibratoDepth = vibratoDepth
        self.vibratoRate = vibratoRate
        self.vibratoDelay = vibratoDelay
        self.level = level
    }

    /// A soft, round lead.
    public static let soft = LeadPreset(square: 0.6, cutoff: 1_800, envelopeAmount: 0.6, attack: 0.03)
    /// A bright saw lead.
    public static let bright = LeadPreset(square: 0, detune: 12, cutoff: 3_500, resonance: 0.25, envelopeAmount: 1.5)
}

// MARK: - What a voice is built from

/// Frames between the updates of a voice's slow parameters (a filter's cutoff, an LFO): 32 frames, 0.67 ms.
let controlFrames = 32

/// What a voice needs to know about its note.
struct NoteContext {
    /// The note's first frame in the render (from 0 to the loop's end).
    var start: Int
    /// The frames it is held.
    var gate: Int
    var pitch: Double
    var velocity: Double
    var random: SynthRandom
    var loopFrames: Int
    var sampleRate: Double = 48_000

    var frequency: Double { SynthMath.frequency(midi: pitch) }

    func frames(_ seconds: Double) -> Int {
        Int((max(seconds.isFinite ? seconds : 0, 0) * sampleRate).rounded(.toNearestOrEven))
    }

    /// The value in [−1, 1] of an LFO of `rate` Hz (rounded to a whole number of cycles per loop, at least one) at frame
    /// `frame` of the render: exactly the same at `frame` and `frame + loopFrames`.
    func lfo(rate: Double, at frame: Int) -> Double {
        let cycles = max(1, Int(((rate.isFinite ? max(rate, 0) : 0) * Double(loopFrames) / sampleRate).rounded(.toNearestOrEven)))
        return SynthMath.sine(cycles: Double((cycles * frame) % loopFrames) / Double(loopFrames))
    }
}

/// One note being played: it writes its frames in order, a block at a time.
protocol Voice: AnyObject {
    /// Writes (not adds) its next `frames` stereo frames to `out`, interleaved.
    func render(_ out: UnsafeMutablePointer<Double>, frames: Int)
}

/// The polyBLEP of a saw's step at phase `t` with phase step `dt`: what makes it band-limited enough.
@inline(__always)
func polyBLEP(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    }
    if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// A band-limited saw from −1 to 1, its phase in turns.
struct Saw {
    var phase: Double
    var step: Double

    @inline(__always)
    mutating func next() -> Double {
        let p = phase
        phase += step
        if phase >= 1 { phase -= 1 }
        return 2 * p - 1 - polyBLEP(p, step)
    }

    /// The saw at `offset` turns ahead of the phase (without moving it), for a pulse made of two saws.
    @inline(__always)
    func ahead(_ offset: Double) -> Double {
        var p = phase + offset
        if p >= 1 { p -= 1 }
        return 2 * p - 1 - polyBLEP(p, step)
    }
}

/// An attack (a smooth step), a decay to the sustain (exponential), and after the gate a release from wherever it was to
/// exactly 0, along (1 − u)³.
struct Envelope {
    private let attack: Int
    private let decayFactor: Double
    private let sustain: Double
    private let gate: Int
    private let release: Int
    private var position = 0
    private var excess: Double
    private var held = 0.0

    init(attack: Int, decay: Double, sustain: Double, gate: Int, release: Int, sampleRate: Double = 48_000) {
        self.attack = max(attack, 1)
        decayFactor = SynthMath.decayFactor(seconds: decay / 3, sampleRate: sampleRate)
        self.sustain = min(max(sustain.isFinite ? sustain : 1, 0), 1)
        self.gate = max(gate, 0)
        self.release = max(release, 1)
        excess = 1 - self.sustain
    }

    /// The frames from the start to the end of the release.
    var length: Int { gate + release }

    @inline(__always)
    mutating func next() -> Double {
        let p = position
        position += 1
        if p < gate {
            var level = sustain + excess
            if p < attack {
                level *= SynthMath.smoothstep(Double(p + 1) / Double(attack))
            } else {
                excess *= decayFactor
            }
            held = level
            return level
        }
        let u = Double(p - gate) / Double(release)
        guard u < 1 else { return 0 }
        let v = 1 - u
        return held * v * v * v
    }
}

/// A one-shot's end: 1 until the last quarter of `length` frames, then down to exactly 0 along (1 − u)².
@inline(__always)
func tailFade(_ position: Int, _ length: Int) -> Double {
    let start = length - length / 4
    guard position >= start else { return 1 }
    let u = Double(position - start) / Double(max(length - start, 1))
    let v = max(1 - u, 0)
    return v * v
}

// MARK: - The voices of the presets

final class PadVoice: Voice {
    private var saws: [Saw]
    private let leftGains: [Double]
    private let rightGains: [Double]
    private var subPhase: Double
    private let subStep: Double
    private let subLevel: Double
    private var envelope: Envelope
    private var left = StateVariableFilter()
    private var right = StateVariableFilter()
    private let preset: PadPreset
    private let context: NoteContext
    private let amplitude: Double
    private var position = 0
    private var envelopeLevel = 0.0

    init(_ preset: PadPreset, _ context: NoteContext) {
        var random = context.random
        let count = min(max(preset.oscillators, 1), 7)
        var saws: [Saw] = []
        var leftGains: [Double] = []
        var rightGains: [Double] = []
        let norm = 1 / Double(count).squareRoot()
        for j in 0..<count {
            let spread = count == 1 ? 0 : Double(j) / Double(count - 1) - 0.5
            let step = context.frequency * SynthMath.ratio(cents: preset.detune * spread) / context.sampleRate
            saws.append(Saw(phase: random.unit(), step: min(step, 0.45)))
            let pan = SynthMath.panGains(spread * 1.6)
            leftGains.append(pan.left * norm)
            rightGains.append(pan.right * norm)
        }
        self.saws = saws
        self.leftGains = leftGains
        self.rightGains = rightGains
        subPhase = random.unit()
        subStep = context.frequency / 2 / context.sampleRate
        subLevel = preset.sub * 0.7
        envelope = Envelope(
            attack: context.frames(preset.attack), decay: preset.decay, sustain: preset.sustain, gate: context.gate,
            release: context.frames(min(preset.release, MusicSynth.maxRelease)), sampleRate: context.sampleRate)
        self.preset = preset
        self.context = context
        amplitude = context.velocity * preset.level
    }

    static func length(_ preset: PadPreset, gate: Int, sampleRate: Double) -> Int {
        gate + Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var saws = [Saw]()
        swap(&saws, &self.saws)
        defer { swap(&saws, &self.saws) }
        var left = self.left, right = self.right, envelope = self.envelope
        var subPhase = self.subPhase
        let tracking = preset.keyTracking * (context.pitch - 60) / 12
        saws.withUnsafeMutableBufferPointer { saws in
            for f in 0..<frames {
                if (position + f) % controlFrames == 0 {
                    let sweep = preset.sweepDepth * context.lfo(rate: preset.sweepRate, at: context.start + position + f)
                    let octaves = tracking + preset.envelopeAmount * envelopeLevel + sweep
                    let cutoff = preset.cutoff * SynthMath.exp2(octaves)
                    left.set(cutoff: cutoff, resonance: preset.resonance, sampleRate: context.sampleRate)
                    right.set(cutoff: cutoff, resonance: preset.resonance, sampleRate: context.sampleRate)
                }
                var l = 0.0, r = 0.0
                for j in 0..<saws.count {
                    let s = saws[j].next()
                    l += s * leftGains[j]
                    r += s * rightGains[j]
                }
                if subLevel != 0 {
                    let s = SynthMath.sine(cycles: subPhase) * subLevel
                    subPhase += subStep
                    if subPhase >= 1 { subPhase -= 1 }
                    l += s
                    r += s
                }
                let e = envelope.next()
                envelopeLevel = e
                out[2 * f] = left.lowPass(l) * e * amplitude
                out[2 * f + 1] = right.lowPass(r) * e * amplitude
            }
        }
        position += frames
        self.left = left
        self.right = right
        self.envelope = envelope
        self.subPhase = subPhase
    }
}

final class EPianoVoice: Voice {
    private var carrier: Double
    private var modulator: Double
    private var tinePhase: Double
    private let carrierStep: Double
    private let modulatorStep: Double
    private let tineStep: Double
    private var index: Double
    private let indexFactor: Double
    private var tine: Double
    private let tineFactor: Double
    private var body = 1.0
    private let bodyFactor: Double
    private var envelope: Envelope
    private let preset: EPianoPreset
    private let context: NoteContext
    private let amplitude: Double
    private var position = 0

    init(_ preset: EPianoPreset, _ context: NoteContext) {
        var random = context.random
        let f = context.frequency
        carrier = random.unit()
        modulator = random.unit()
        tinePhase = random.unit()
        carrierStep = f / context.sampleRate
        modulatorStep = f * max(preset.ratio, 0) / context.sampleRate
        tineStep = min(f * 14 / context.sampleRate, 0.45)
        let v = min(max(context.velocity, 0), 1)
        // Radians of phase modulation, as turns.
        index = preset.index * (0.5 + 0.5 * v) / SynthMath.twoPi
        indexFactor = SynthMath.decayFactor(seconds: preset.indexDecay, sampleRate: context.sampleRate)
        tine = f * 14 < context.sampleRate * 0.45 ? preset.tine * v / SynthMath.twoPi : 0
        tineFactor = SynthMath.decayFactor(seconds: 0.05, sampleRate: context.sampleRate)
        bodyFactor = SynthMath.decayFactor(seconds: preset.decay, sampleRate: context.sampleRate)
        envelope = Envelope(
            attack: context.frames(0.002), decay: 0, sustain: 1, gate: context.gate,
            release: context.frames(min(preset.release, MusicSynth.maxRelease)), sampleRate: context.sampleRate)
        self.preset = preset
        self.context = context
        amplitude = context.velocity * preset.level * 0.5
    }

    static func length(_ preset: EPianoPreset, gate: Int, sampleRate: Double) -> Int {
        gate + Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var envelope = self.envelope
        var carrier = self.carrier, modulator = self.modulator, tinePhase = self.tinePhase
        var index = self.index, tine = self.tine, body = self.body
        var tremolo = 0.0
        for f in 0..<frames {
            if (position + f) % controlFrames == 0 {
                tremolo = preset.tremoloDepth * context.lfo(rate: preset.tremoloRate, at: context.start + position + f)
            }
            let m = index * SynthMath.sine(cycles: modulator) + tine * SynthMath.sine(cycles: tinePhase)
            let y = SynthMath.sine(cycles: carrier + m) * body * envelope.next() * amplitude
            carrier += carrierStep
            if carrier >= 1 { carrier -= 1 }
            modulator += modulatorStep
            if modulator >= 1 { modulator -= 1 }
            tinePhase += tineStep
            if tinePhase >= 1 { tinePhase -= 1 }
            index *= indexFactor
            tine *= tineFactor
            body *= bodyFactor
            out[2 * f] = y * (1 + tremolo)
            out[2 * f + 1] = y * (1 - tremolo)
        }
        position += frames
        self.envelope = envelope
        self.carrier = carrier
        self.modulator = modulator
        self.tinePhase = tinePhase
        self.index = index
        self.tine = tine
        self.body = body
    }
}

final class PianoVoice: Voice {
    /// Each partial of each string: its value as a turning complex number (`re`, `im`) and its turn per frame (`cr`, `ci`,
    /// which also shrinks it by its decay).
    private var re: [Double]
    private var im: [Double]
    private let cr: [Double]
    private let ci: [Double]
    private let leftGain: Double
    private let rightGain: Double
    private var envelope: Envelope
    private var random: SynthRandom
    private var hammer: Double
    private let hammerFactor: Double
    private var hammerFilter: OnePole
    private let attack: Int
    private var position = 0

    init(_ preset: PianoPreset, _ context: NoteContext) {
        var random = context.random
        let f0 = context.frequency
        let v = min(max(context.velocity, 0), 1)
        let rho = min(max(preset.brightness, 0.05), 0.95) * (0.75 + 0.25 * v)
        let fundamental = Self.fundamentalDecay(preset, f0)
        let strings = min(max(preset.strings, 1), 3)
        var re: [Double] = [], im: [Double] = [], cr: [Double] = [], ci: [Double] = []
        var amplitude = 1.0
        for n in 1...min(max(preset.partials, 1), 16) {
            let k = Double(n)
            let fn = k * f0 * (1 + max(preset.inharmonicity, 0) * k * k).squareRoot()
            if fn > 15_000 { break }
            // The hammer strikes at 1/7 of the string, so the partials near the 7th are weak.
            let strike = SynthMath.sine(cycles: k / 14).magnitude
            let tau = fundamental / (1 + max(preset.damping, 0) * (fn - f0) / 1_000)
            let shrink = SynthMath.decayFactor(seconds: tau, sampleRate: context.sampleRate)
            for s in 0..<strings {
                let spread = strings == 1 ? 0 : Double(s) / Double(strings - 1) - 0.5
                let turn = fn * SynthMath.ratio(cents: preset.detune * spread) / context.sampleRate
                let phase = random.unit()
                let a = amplitude / k * strike / Double(strings)
                re.append(a * SynthMath.cosine(cycles: phase))
                im.append(a * SynthMath.sine(cycles: phase))
                cr.append(shrink * SynthMath.cosine(cycles: turn))
                ci.append(shrink * SynthMath.sine(cycles: turn))
            }
            amplitude *= rho
        }
        self.re = re
        self.im = im
        self.cr = cr
        self.ci = ci
        let pan = SynthMath.panGains(min(max(preset.width, 0), 1) * min(max((context.pitch - 64) / 30, -1), 1))
        let level = context.velocity * preset.level * 1.4
        leftGain = pan.left * level
        rightGain = pan.right * level
        let length = Self.length(preset, gate: context.gate, frequency: f0, sampleRate: context.sampleRate)
        let release = min(context.frames(min(preset.release, MusicSynth.maxRelease)).clampedToOne, length)
        envelope = Envelope(attack: 1, decay: 0, sustain: 1, gate: length - release, release: release, sampleRate: context.sampleRate)
        self.random = random
        hammer = max(preset.hammer, 0) * (0.3 + 0.7 * v)
        hammerFactor = SynthMath.decayFactor(seconds: 0.004, sampleRate: context.sampleRate)
        hammerFilter = OnePole(cutoff: 600 + 2_400 * v, sampleRate: context.sampleRate)
        attack = context.frames(0.0015).clampedToOne
    }

    /// C4's time to 1/e, shorter for higher notes: `decay · 2 / (1 + f₀ / 261.63)`.
    private static func fundamentalDecay(_ preset: PianoPreset, _ f0: Double) -> Double {
        max(preset.decay, 0.05) * 2 / (1 + f0 / 261.63)
    }

    /// Held for `gate` frames and then damped, or over once the fundamental is 100 dB down (11.5 times its time to 1/e),
    /// whichever is first.
    static func length(_ preset: PianoPreset, gate: Int, frequency: Double, sampleRate: Double) -> Int {
        let release = Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
        let natural = Int((11.5 * fundamentalDecay(preset, frequency) * sampleRate).rounded(.toNearestOrEven))
        return max(min(gate + release, natural), release)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var re = [Double](), im = [Double]()
        swap(&re, &self.re)
        swap(&im, &self.im)
        defer {
            swap(&re, &self.re)
            swap(&im, &self.im)
        }
        var envelope = self.envelope, random = self.random, hammerFilter = self.hammerFilter
        var hammer = self.hammer
        let count = re.count
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                cr.withUnsafeBufferPointer { cr in
                    ci.withUnsafeBufferPointer { ci in
                        for f in 0..<frames {
                            var y = 0.0
                            for p in 0..<count {
                                let a = re[p], b = im[p]
                                re[p] = a * cr[p] - b * ci[p]
                                im[p] = a * ci[p] + b * cr[p]
                                y += b
                            }
                            if hammer > 1e-7 {
                                y += hammerFilter.lowPass(random.bipolar()) * hammer
                                hammer *= hammerFactor
                            }
                            let p = position + f
                            if p < attack { y *= SynthMath.smoothstep(Double(p + 1) / Double(attack)) }
                            y *= envelope.next()
                            out[2 * f] = y * leftGain
                            out[2 * f + 1] = y * rightGain
                        }
                    }
                }
            }
        }
        position += frames
        self.envelope = envelope
        self.random = random
        self.hammerFilter = hammerFilter
        self.hammer = hammer
    }
}

final class PluckVoice: Voice {
    private var line: [Double]
    private var index = 0
    private let loopGain: Double
    private let weight: Double
    private let allPass: Double
    private var allPassIn = 0.0
    private var allPassOut = 0.0
    private var previous = 0.0
    private var excitation: [Double]
    private var envelope: Envelope
    private let leftGain: Double
    private let rightGain: Double
    private var position = 0

    init(_ preset: PluckPreset, _ context: NoteContext) {
        var random = context.random
        let f0 = min(max(context.frequency, 20), 4_000)
        let period = context.sampleRate / f0
        let v = min(max(context.velocity, 0), 1)
        // The loop: `count` samples, a two-point low-pass of weight S (delay S) and an all-pass for the rest (Jaffe–Smith).
        weight = 0.05 + 0.45 * min(max(preset.damping, 0), 1)
        let count = max(Int((period - weight - 0.1).rounded(.down)), 2)
        let fraction = period - weight - Double(count)
        allPass = (1 - fraction) / (1 + fraction)
        line = [Double](repeating: 0, count: count)
        loopGain = SynthMath.gain(decibels: -60 / (max(preset.decay, 0.05) * f0))
        // The excitation: a period of seeded noise, low-passed by the brightness, combed at the pick position, without DC.
        var filter = OnePole(cutoff: 400 + 9_000 * min(max(preset.brightness, 0), 1) * (0.4 + 0.6 * v), sampleRate: context.sampleRate)
        var burst = (0..<Int(period.rounded(.toNearestOrEven)).clampedToOne).map { _ in filter.lowPass(random.bipolar()) }
        let pick = max(Int((min(max(preset.pickPosition, 0.02), 0.5) * Double(burst.count)).rounded(.toNearestOrEven)), 1)
        if pick < burst.count {
            for i in stride(from: burst.count - 1, through: pick, by: -1) { burst[i] -= burst[i - pick] }
        }
        var sum = 0.0
        for x in burst { sum += x }
        let mean = sum / Double(burst.count)
        var peak = 0.0
        for i in burst.indices {
            burst[i] -= mean
            peak = max(peak, burst[i].magnitude)
        }
        excitation = burst.map { peak > 0 ? $0 / peak : 0 }
        let length = Self.length(preset, gate: context.gate, frequency: f0, sampleRate: context.sampleRate)
        let release = min(context.frames(min(preset.release, MusicSynth.maxRelease)).clampedToOne, length)
        envelope = Envelope(attack: 1, decay: 0, sustain: 1, gate: length - release, release: release, sampleRate: context.sampleRate)
        let pan = SynthMath.panGains(min(max(preset.spread, 0), 1) * 0.7 * random.bipolar())
        let level = context.velocity * preset.level * 0.8
        leftGain = pan.left * level
        rightGain = pan.right * level
    }

    /// Held for `gate` frames and then stopped, or over once it is 100 dB down, whichever is first.
    static func length(_ preset: PluckPreset, gate: Int, frequency: Double, sampleRate: Double) -> Int {
        let release = Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
        let natural = Int((max(preset.decay, 0.05) * 100 / 60 * sampleRate).rounded(.toNearestOrEven))
        return max(min(gate + release, natural), release)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var line = [Double]()
        swap(&line, &self.line)
        defer { swap(&line, &self.line) }
        var envelope = self.envelope
        var index = self.index, previous = self.previous, allPassIn = self.allPassIn, allPassOut = self.allPassOut
        let count = line.count
        line.withUnsafeMutableBufferPointer { line in
            for f in 0..<frames {
                let p = position + f
                let delayed = line[index]
                // The loop filter, then the all-pass that tunes the fraction of a sample.
                let filtered = (1 - weight) * delayed + weight * previous
                previous = delayed
                let tuned = allPass * filtered + allPassIn - allPass * allPassOut
                allPassIn = filtered
                allPassOut = tuned
                let input = p < excitation.count ? excitation[p] : 0
                let y = input + loopGain * tuned
                line[index] = y
                index += 1
                if index == count { index = 0 }
                let out1 = y * envelope.next()
                out[2 * f] = out1 * leftGain
                out[2 * f + 1] = out1 * rightGain
            }
        }
        position += frames
        self.envelope = envelope
        self.index = index
        self.previous = previous
        self.allPassIn = allPassIn
        self.allPassOut = allPassOut
    }
}

final class BassVoice: Voice {
    private var sinePhase: Double
    private var saw: Saw
    private let step: Double
    private var filter = StateVariableFilter()
    private var filterEnvelope = 1.0
    private let filterFactor: Double
    private var envelope: Envelope
    private let preset: BassPreset
    private let context: NoteContext
    private let amplitude: Double
    private let drive: Double
    private var position = 0

    init(_ preset: BassPreset, _ context: NoteContext) {
        var random = context.random
        step = context.frequency / context.sampleRate
        sinePhase = 0
        saw = Saw(phase: random.unit(), step: min(step, 0.45))
        filterFactor = SynthMath.decayFactor(seconds: preset.filterDecay, sampleRate: context.sampleRate)
        envelope = Envelope(
            attack: context.frames(preset.attack), decay: preset.decay, sustain: preset.sustain, gate: context.gate,
            release: context.frames(min(preset.release, MusicSynth.maxRelease)), sampleRate: context.sampleRate)
        self.preset = preset
        self.context = context
        amplitude = context.velocity * preset.level * 0.6
        drive = 1 + 3 * min(max(preset.drive, 0), 1)
    }

    static func length(_ preset: BassPreset, gate: Int, sampleRate: Double) -> Int {
        gate + Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var envelope = self.envelope, filter = self.filter, saw = self.saw
        var sinePhase = self.sinePhase, filterEnvelope = self.filterEnvelope
        let tracking = (context.pitch - 36) / 12 * 0.5
        let norm = 1 / SynthMath.tanh(drive)
        for f in 0..<frames {
            if (position + f) % controlFrames == 0 {
                let cutoff = preset.cutoff * SynthMath.exp2(tracking + preset.envelopeAmount * filterEnvelope)
                filter.set(cutoff: cutoff, resonance: preset.resonance, sampleRate: context.sampleRate)
            }
            let s = SynthMath.sine(cycles: sinePhase) * preset.sine
            sinePhase += step
            if sinePhase >= 1 { sinePhase -= 1 }
            let x = s + filter.lowPass(saw.next() * preset.saw)
            filterEnvelope *= filterFactor
            let y = SynthMath.tanh(x * drive) * norm * envelope.next() * amplitude
            out[2 * f] = y
            out[2 * f + 1] = y
        }
        position += frames
        self.envelope = envelope
        self.filter = filter
        self.saw = saw
        self.sinePhase = sinePhase
        self.filterEnvelope = filterEnvelope
    }
}

final class LeadVoice: Voice {
    private var first: Saw
    private var second: Saw
    private let firstStep: Double
    private let secondStep: Double
    private var left = StateVariableFilter()
    private var right = StateVariableFilter()
    private var envelope: Envelope
    private var envelopeLevel = 0.0
    private let preset: LeadPreset
    private let context: NoteContext
    private let amplitude: Double
    private var position = 0

    init(_ preset: LeadPreset, _ context: NoteContext) {
        var random = context.random
        firstStep = context.frequency * SynthMath.ratio(cents: -preset.detune / 2) / context.sampleRate
        secondStep = context.frequency * SynthMath.ratio(cents: preset.detune / 2) / context.sampleRate
        first = Saw(phase: random.unit(), step: min(firstStep, 0.45))
        second = Saw(phase: random.unit(), step: min(secondStep, 0.45))
        envelope = Envelope(
            attack: context.frames(preset.attack), decay: preset.decay, sustain: preset.sustain, gate: context.gate,
            release: context.frames(min(preset.release, MusicSynth.maxRelease)), sampleRate: context.sampleRate)
        self.preset = preset
        self.context = context
        amplitude = context.velocity * preset.level * 0.5
    }

    static func length(_ preset: LeadPreset, gate: Int, sampleRate: Double) -> Int {
        gate + Int((min(max(preset.release, 0), MusicSynth.maxRelease) * sampleRate).rounded(.toNearestOrEven)).clampedToOne
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        var envelope = self.envelope, left = self.left, right = self.right, first = self.first, second = self.second
        let square = min(max(preset.square, 0), 1)
        let width = min(max(preset.pulseWidth, 0.05), 0.95)
        let tracking = (context.pitch - 72) / 12 * 0.5
        let vibratoTurns = preset.vibratoRate / context.sampleRate
        let vibratoDelay = Double(max(context.frames(preset.vibratoDelay), 1))
        for f in 0..<frames {
            let p = position + f
            if p % controlFrames == 0 {
                let cutoff = preset.cutoff * SynthMath.exp2(tracking + preset.envelopeAmount * envelopeLevel)
                left.set(cutoff: cutoff, resonance: preset.resonance, sampleRate: context.sampleRate)
                right.set(cutoff: cutoff, resonance: preset.resonance, sampleRate: context.sampleRate)
                // The vibrato, faded in after its delay, belongs to the note: its phase counts from the note's start.
                let fadeIn = SynthMath.smoothstep((Double(p) - vibratoDelay) / vibratoDelay)
                let cents = preset.vibratoDepth * fadeIn * SynthMath.sine(cycles: Double(p) * vibratoTurns)
                let bend = SynthMath.ratio(cents: cents)
                first.step = min(firstStep * bend, 0.45)
                second.step = min(secondStep * bend, 0.45)
            }
            // A pulse is the saw minus itself `width` of a turn ahead, at the same phase.
            let aheadA = first.ahead(width), aheadB = second.ahead(width)
            let a = first.next(), b = second.next()
            let pulseA = (a - aheadA) * 0.5
            let pulseB = (b - aheadB) * 0.5
            let l = a + (pulseA - a) * square
            let r = b + (pulseB - b) * square
            let e = envelope.next()
            envelopeLevel = e
            out[2 * f] = left.lowPass(l) * e * amplitude
            out[2 * f + 1] = right.lowPass(r) * e * amplitude
        }
        position += frames
        self.envelope = envelope
        self.left = left
        self.right = right
        self.first = first
        self.second = second
    }
}

// MARK: - Drums and noise

/// A kick: a sine whose pitch falls fast from about 160 Hz to 48 Hz (tuned by the note: C4 is that), a click, and a
/// little saturation.
final class KickVoice: Voice {
    static let seconds = 0.7
    private var phase = 0.0
    private var sweep = 1.0
    private let sweepFactor: Double
    private var body = 1.0
    private let bodyFactor: Double
    private var click: Double
    private let clickFactor: Double
    private var clickFilter: OnePole
    private var random: SynthRandom
    private let high: Double
    private let low: Double
    private let amplitude: Double
    private let length: Int
    private var position = 0

    init(_ context: NoteContext) {
        let tune = SynthMath.exp2((context.pitch - 60) / 12)
        high = 160 * tune / context.sampleRate
        low = 48 * tune / context.sampleRate
        sweepFactor = SynthMath.decayFactor(seconds: 0.035, sampleRate: context.sampleRate)
        bodyFactor = SynthMath.decayFactor(seconds: 0.16, sampleRate: context.sampleRate)
        click = 0.3 * min(max(context.velocity, 0), 1)
        clickFactor = SynthMath.decayFactor(seconds: 0.002, sampleRate: context.sampleRate)
        clickFilter = OnePole(cutoff: 3_000, sampleRate: context.sampleRate)
        random = context.random
        amplitude = context.velocity * 0.9
        length = context.frames(Self.seconds)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        let norm = 1 / SynthMath.tanh(1.5)
        for f in 0..<frames {
            let p = position + f
            var y = SynthMath.sine(cycles: phase) * body
            phase += low + (high - low) * sweep
            if phase >= 1 { phase -= 1 }
            sweep *= sweepFactor
            body *= bodyFactor
            if click > 1e-6 {
                y += clickFilter.highPass(random.bipolar()) * click
                click *= clickFactor
            }
            if p < 48 { y *= Double(p + 1) / 48 }
            let v = SynthMath.tanh(y * 1.5) * norm * amplitude * tailFade(p, length)
            out[2 * f] = v
            out[2 * f + 1] = v
        }
        position += frames
    }
}

/// A snare: two tones of the drum's head (about 180 and 330 Hz, tuned by the note) and the wires, noise through a
/// band-pass.
final class SnareVoice: Voice {
    static let seconds = 0.45
    private var low = 0.0, high = 0.0
    private let lowStep: Double, highStep: Double
    private var tone = 1.0
    private let toneFactor: Double
    private var wires = 1.0
    private let wiresFactor: Double
    private var filter = StateVariableFilter()
    private var random: SynthRandom
    private let amplitude: Double
    private let length: Int
    private var position = 0

    init(_ context: NoteContext) {
        let tune = SynthMath.exp2((context.pitch - 60) / 12)
        lowStep = 180 * tune / context.sampleRate
        highStep = 330 * tune / context.sampleRate
        toneFactor = SynthMath.decayFactor(seconds: 0.05, sampleRate: context.sampleRate)
        wiresFactor = SynthMath.decayFactor(seconds: 0.09, sampleRate: context.sampleRate)
        filter.set(cutoff: 2_400, resonance: 0.2, sampleRate: context.sampleRate)
        random = context.random
        amplitude = context.velocity * 0.7
        length = context.frames(Self.seconds)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        for f in 0..<frames {
            let p = position + f
            let body = (SynthMath.sine(cycles: low) * 0.6 + SynthMath.sine(cycles: high) * 0.4) * tone
            low += lowStep
            if low >= 1 { low -= 1 }
            high += highStep
            if high >= 1 { high -= 1 }
            let noise = filter.process(random.bipolar())
            let y = (body * 0.6 + (noise.band * 1.6 + noise.high * 0.4) * wires) * amplitude * tailFade(p, length)
            tone *= toneFactor
            wires *= wiresFactor
            let v = p < 24 ? y * Double(p + 1) / 24 : y
            out[2 * f] = v
            out[2 * f + 1] = v
        }
        position += frames
    }
}

/// A hi-hat: noise and six detuned pulses (the cymbals of a drum machine), high-passed; closed it is short, open it rings.
final class HatVoice: Voice {
    private static let ratios = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
    static func seconds(open: Bool) -> Double { open ? 0.7 : 0.15 }
    private var metal: [Saw]
    private var filter = StateVariableFilter()
    private var random: SynthRandom
    private var decay = 1.0
    private let decayFactor: Double
    private let amplitude: Double
    private let length: Int
    private var position = 0

    init(_ context: NoteContext, open: Bool) {
        var random = context.random
        metal = Self.ratios.map { Saw(phase: random.unit(), step: 205 * $0 / context.sampleRate) }
        filter.set(cutoff: 7_500, resonance: 0.3, sampleRate: context.sampleRate)
        self.random = random
        decayFactor = SynthMath.decayFactor(seconds: open ? 0.16 : 0.025, sampleRate: context.sampleRate)
        amplitude = context.velocity * 0.35
        length = context.frames(Self.seconds(open: open))
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        for f in 0..<frames {
            let p = position + f
            var metallic = 0.0
            for j in 0..<metal.count {
                let half = metal[j].ahead(0.5)
                metallic += metal[j].next() - half
            }
            let x = random.bipolar() * 0.6 + metallic * 0.08
            let y = filter.highPass(x) * decay * amplitude * tailFade(p, length)
            decay *= decayFactor
            let v = p < 12 ? y * Double(p + 1) / 12 : y
            out[2 * f] = v
            out[2 * f + 1] = v
        }
        position += frames
    }
}

/// A clap: three quick bursts of noise and a short tail, through a band-pass around 1.2 kHz.
final class ClapVoice: Voice {
    static let seconds = 0.45
    private var filter = StateVariableFilter()
    private var random: SynthRandom
    private let burstFactor: Double
    private let tailFactor: Double
    private let spacing: Int
    private let amplitude: Double
    private let length: Int
    private var position = 0
    private var burst = 0.0
    private var tail = 0.0

    init(_ context: NoteContext) {
        filter.set(cutoff: 1_200, resonance: 0.45, sampleRate: context.sampleRate)
        random = context.random
        burstFactor = SynthMath.decayFactor(seconds: 0.004, sampleRate: context.sampleRate)
        tailFactor = SynthMath.decayFactor(seconds: 0.09, sampleRate: context.sampleRate)
        spacing = context.frames(0.011)
        amplitude = context.velocity * 1.1
        length = context.frames(Self.seconds)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        for f in 0..<frames {
            let p = position + f
            if p < 3 * spacing, p % spacing == 0 { burst = 1 }
            if p == 3 * spacing { tail = 0.7 }
            let envelope = burst + tail
            burst *= burstFactor
            tail *= tailFactor
            let y = filter.bandPass(random.bipolar()) * envelope * amplitude * tailFade(p, length)
            out[2 * f] = y
            out[2 * f + 1] = y
        }
        position += frames
    }
}

/// A shaker: high noise that swells in 8 ms and fades.
final class ShakerVoice: Voice {
    static let seconds = 0.2
    private var filter = StateVariableFilter()
    private var random: SynthRandom
    private var decay = 1.0
    private let decayFactor: Double
    private let attack: Int
    private let amplitude: Double
    private let length: Int
    private var position = 0

    init(_ context: NoteContext) {
        filter.set(cutoff: 6_500, resonance: 0.25, sampleRate: context.sampleRate)
        random = context.random
        decayFactor = SynthMath.decayFactor(seconds: 0.035, sampleRate: context.sampleRate)
        attack = context.frames(0.008)
        amplitude = context.velocity * 0.3
        length = context.frames(Self.seconds)
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        for f in 0..<frames {
            let p = position + f
            let swell = p < attack ? SynthMath.smoothstep(Double(p + 1) / Double(attack)) : 1
            if p >= attack { decay *= decayFactor }
            let y = filter.highPass(random.bipolar()) * swell * decay * amplitude * tailFade(p, length)
            out[2 * f] = y
            out[2 * f + 1] = y
        }
        position += frames
    }
}

/// The crackle of a record, for as long as the note is held: a faint hiss, random pops and the soft tick of the record
/// going round about every 1.8 s (a whole number of turns per loop, at the same place in the loop on every pass). Held
/// for the whole loop, it repeats without a seam: the noise has no envelope and its filters' ringing wraps onto the start.
final class VinylVoice: Voice {
    static let ringSeconds = 0.05
    private var random: SynthRandom
    private var hissLow: OnePole
    private var hissHigh: OnePole
    private var popFilter: OnePole
    private var tickFilter: OnePole
    private var pop = 0.0
    private var tick = 0.0
    private let popChance: Double
    private let turns: Int
    private let context: NoteContext
    private let amplitude: Double
    private var position = 0

    init(_ context: NoteContext) {
        random = context.random
        hissLow = OnePole(cutoff: 5_000, sampleRate: context.sampleRate)
        hissHigh = OnePole(cutoff: 700, sampleRate: context.sampleRate)
        popFilter = OnePole(cutoff: 1_500, sampleRate: context.sampleRate)
        tickFilter = OnePole(cutoff: 250, sampleRate: context.sampleRate)
        popChance = 7 / context.sampleRate
        turns = max(1, Int((Double(context.loopFrames) / context.sampleRate / 1.8).rounded(.toNearestOrEven)))
        self.context = context
        amplitude = context.velocity
    }

    func render(_ out: UnsafeMutablePointer<Double>, frames: Int) {
        let popFactor = 0.55
        let tickFactor = 0.993
        for f in 0..<frames {
            let p = position + f
            let held = p < context.gate
            var input = 0.0
            var popIn = 0.0
            var tickIn = 0.0
            if held {
                input = random.bipolar()
                if random.unit() < popChance {
                    let size = random.unit()
                    popIn = size * size * size * (random.unit() < 0.5 ? -1 : 1)
                }
                let frame = context.start + p
                if (turns * frame) % context.loopFrames < turns { tickIn = 0.25 }
            }
            let hiss = hissLow.lowPass(hissHigh.highPass(input)) * 0.03
            pop = pop * popFactor + popIn
            tick = tick * tickFactor + tickIn
            let y = (hiss + popFilter.highPass(pop) * 0.4 + tickFilter.lowPass(tick) * 0.3) * amplitude
            out[2 * f] = y
            out[2 * f + 1] = y
        }
        position += frames
    }
}

// MARK: - From an instrument to a voice

extension Instrument {
    /// The frames a note held for `gate` frames sounds, from its start to the end of its release.
    func frames(gate: Int, pitch: Double, sampleRate: Double) -> Int {
        let frequency = SynthMath.frequency(midi: pitch)
        func seconds(_ s: Double) -> Int { Int((s * sampleRate).rounded(.toNearestOrEven)) }
        switch self {
        case .pad(let preset): return PadVoice.length(preset, gate: gate, sampleRate: sampleRate)
        case .electricPiano(let preset): return EPianoVoice.length(preset, gate: gate, sampleRate: sampleRate)
        case .piano(let preset): return PianoVoice.length(preset, gate: gate, frequency: frequency, sampleRate: sampleRate)
        case .pluck(let preset): return PluckVoice.length(preset, gate: gate, frequency: frequency, sampleRate: sampleRate)
        case .bass(let preset): return BassVoice.length(preset, gate: gate, sampleRate: sampleRate)
        case .lead(let preset): return LeadVoice.length(preset, gate: gate, sampleRate: sampleRate)
        case .kick: return seconds(KickVoice.seconds)
        case .snare: return seconds(SnareVoice.seconds)
        case .hat(let open): return seconds(HatVoice.seconds(open: open))
        case .clap: return seconds(ClapVoice.seconds)
        case .shaker: return seconds(ShakerVoice.seconds)
        case .vinyl: return gate + seconds(VinylVoice.ringSeconds)
        }
    }

    func voice(_ context: NoteContext) -> any Voice {
        switch self {
        case .pad(let preset): return PadVoice(preset, context)
        case .electricPiano(let preset): return EPianoVoice(preset, context)
        case .piano(let preset): return PianoVoice(preset, context)
        case .pluck(let preset): return PluckVoice(preset, context)
        case .bass(let preset): return BassVoice(preset, context)
        case .lead(let preset): return LeadVoice(preset, context)
        case .kick: return KickVoice(context)
        case .snare: return SnareVoice(context)
        case .hat(let open): return HatVoice(context, open: open)
        case .clap: return ClapVoice(context)
        case .shaker: return ShakerVoice(context)
        case .vinyl: return VinylVoice(context)
        }
    }
}

extension Int {
    /// At least 1.
    var clampedToOne: Int { Swift.max(self, 1) }
}
