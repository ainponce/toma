// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch

/// `music-1`: a `MusicScore` rendered to a loop of stereo samples at 48 kHz that repeats without a seam, the same bytes on
/// every Mac and every run (plan decision 3, design §7.6).
///
/// How a loop of N frames (`MusicScore.loopFrames`) is made:
///
/// 1. Every note becomes a voice (`SynthInstruments.swift`) seeded with `SynthRandom.mix(seed, part, note)` (or the
///    note's own seed): a function of its note alone, never of the time it is rendered at or of another voice.
/// 2. N + T frames are rendered (T = `tailFrames`, 8 s), a block of `blockFrames` at a time. In each block every voice
///    writes into a buffer of its own — the voices of a block run on several threads at once — and then, on one thread,
///    the voices of a part are added in the order of its notes, each part gets its chorus, is panned and goes to the dry
///    mix, the reverb and the delay in the order of the parts, and the master is the dry mix plus the delay plus the reverb,
///    high-passed at 28 Hz and low-passed at 16 kHz. Every addition happens in the same order on every run, so no thread
///    changes a bit.
/// 3. Frame k of the render is added onto frame k mod N of the loop: the tail [N, N + T) — releases, the reverb, echoes —
///    lands on [0, T), where the next pass of the loop would hear it. Everything before this point is linear (or belongs
///    to one note), and what sways over the loop turns a whole number of times in it, so the loop is the steady state of
///    playing the score forever: its end leads into its start like any other two frames.
/// 4. Only steps without memory follow: each channel's mean is taken out, the result is multiplied by `masterGain`, and a
///    soft clip (`SynthMath.tanh` above −6 dBFS) keeps every sample under −1 dBFS. Then, and only then, `Float(_:)`.
public enum MusicSynth {
    public static let sampleRate = 48_000
    /// T: 8 s, longer than anything a theme may sound after the loop's end (a 2 s release and a 3 s reverb, −120 dB at
    /// 6 s after it).
    public static let tailFrames = 384_000
    /// The longest release a voice takes, in seconds: a longer one is cut to this.
    public static let maxRelease = 2.0

    /// The frames rendered at a time.
    static let blockFrames = 8_192
    /// The soft clip: unchanged up to `knee`, then bent along tanh towards `ceiling` (−1.01 dBFS), never reaching it.
    static let knee = 0.5
    static let ceiling = 0.89
    /// The master's fixed filters, in Hz.
    static let masterHighPass = 28.0
    static let masterLowPass = 16_000.0

    /// The loop of `score`: exactly `2 × loopFrames` samples, stereo interleaved (left, right, left…).
    /// - Precondition: `score.loopFrames` is not `nil`.
    public static func render(_ score: MusicScore) -> [Float] {
        guard let samples = render(score, until: { false }) else { preconditionFailure("MusicSynth: not cancelled") }
        return samples
    }

    /// `render(_:)`, asking `isCancelled` between blocks (on the thread that renders): `nil` as soon as it says so.
    /// - Precondition: `score.loopFrames` is not `nil`.
    public static func render(_ score: MusicScore, until isCancelled: () -> Bool) -> [Float]? {
        guard let loop = score.loopFrames else {
            preconditionFailure("MusicSynth: the loop of \(score.id) is not a whole number of frames")
        }
        let total = loop + tailFrames
        let rate = Double(sampleRate)
        let parts = score.parts.enumerated().map { PartState(score: score, part: $0.element, index: $0.offset, loop: loop, total: total) }
        var delay = score.delay.map { StereoDelay($0, framesPerBeat: score.framesPerBeat, sampleRate: rate) }
        var reverb = FDNReverb(score.reverb, sampleRate: rate)
        var highPass = (Biquad(.highPass, cutoff: masterHighPass), Biquad(.highPass, cutoff: masterHighPass))
        var lowPass = (Biquad(.lowPass, cutoff: masterLowPass), Biquad(.lowPass, cutoff: masterLowPass))

        var loopSum = [Double](repeating: 0, count: 2 * loop)
        let block = 2 * blockFrames
        let dry = UnsafeMutablePointer<Double>.allocate(capacity: block)
        let reverbIn = UnsafeMutablePointer<Double>.allocate(capacity: block)
        let delayIn = UnsafeMutablePointer<Double>.allocate(capacity: block)
        let bus = UnsafeMutablePointer<Double>.allocate(capacity: block)
        defer {
            dry.deallocate()
            reverbIn.deallocate()
            delayIn.deallocate()
            bus.deallocate()
        }

        var start = 0
        while start < total {
            if isCancelled() { return nil }
            let frames = min(blockFrames, total - start)
            let blockStart = start
            let end = start + frames
            // The voices sounding in this block, each into its own buffer, at once.
            var sounding: [VoiceSlot] = []
            for part in parts {
                part.begin(blockStart: start, blockEnd: end)
                sounding += part.active
            }
            let slots = sounding
            if slots.count > 1 {
                DispatchQueue.concurrentPerform(iterations: slots.count) { slots[$0].render(blockStart: blockStart, blockEnd: end) }
            } else {
                slots.first?.render(blockStart: blockStart, blockEnd: end)
            }
            // Then, in a fixed order, the parts.
            dry.update(repeating: 0, count: 2 * frames)
            reverbIn.update(repeating: 0, count: 2 * frames)
            delayIn.update(repeating: 0, count: 2 * frames)
            for part in parts {
                guard part.mix(into: bus, frames: frames, blockStart: start) else { continue }
                let (left, right) = part.gains
                let toReverb = part.reverbSend, toDelay = delay == nil ? 0 : part.delaySend
                for f in 0..<frames {
                    let l = bus[2 * f] * left, r = bus[2 * f + 1] * right
                    dry[2 * f] += l
                    dry[2 * f + 1] += r
                    reverbIn[2 * f] += l * toReverb
                    reverbIn[2 * f + 1] += r * toReverb
                    delayIn[2 * f] += l * toDelay
                    delayIn[2 * f + 1] += r * toDelay
                }
                part.end(blockEnd: end)
            }
            delay?.process(delayIn, adding: dry, frames: frames)
            reverb.process(reverbIn, adding: dry, frames: frames)
            // The master's filters, and the fold of frame k onto frame k mod N.
            var k = start % loop
            loopSum.withUnsafeMutableBufferPointer { sum in
                for f in 0..<frames {
                    let l = lowPass.0.process(highPass.0.process(dry[2 * f]))
                    let r = lowPass.1.process(highPass.1.process(dry[2 * f + 1]))
                    sum[2 * k] += l
                    sum[2 * k + 1] += r
                    k += 1
                    if k == loop { k = 0 }
                }
            }
            start = end
        }
        if isCancelled() { return nil }
        return finish(loopSum, frames: loop, gain: score.masterGain)
    }

    /// Steps without memory on the folded loop: each channel without its mean, times `gain`, through the soft clip, as
    /// `Float`.
    static func finish(_ loopSum: [Double], frames: Int, gain: Double) -> [Float] {
        var means = (0.0, 0.0)
        for k in 0..<frames {
            means.0 += loopSum[2 * k]
            means.1 += loopSum[2 * k + 1]
        }
        means.0 /= Double(frames)
        means.1 /= Double(frames)
        let gain = gain.isFinite ? gain : 0
        var samples = [Float](repeating: 0, count: 2 * frames)
        for k in 0..<frames {
            samples[2 * k] = Float(softClip((loopSum[2 * k] - means.0) * gain))
            samples[2 * k + 1] = Float(softClip((loopSum[2 * k + 1] - means.1) * gain))
        }
        return samples
    }

    /// `x` up to `knee` in magnitude; above it, bent along tanh towards `ceiling`, with the same slope at the knee.
    static func softClip(_ x: Double) -> Double {
        let a = x.magnitude
        guard a > knee else { return x }
        let room = ceiling - knee
        let bent = knee + room * SynthMath.tanh((a - knee) / room)
        return x < 0 ? -bent : bent
    }
}

// MARK: - Scheduling

/// A note waiting for its block: where it starts and ends in the render, and what its voice needs.
private struct NoteEvent {
    var index: Int
    var start: Int
    var end: Int
    var context: NoteContext
}

/// A voice sounding, with the buffer it renders a block into.
///
/// Unchecked because a voice is a class with state: a slot is rendered by one thread at a time — in a block, each slot by
/// one iteration of `concurrentPerform`, which returns only once all are done — and read by the render's own thread
/// between blocks.
private final class VoiceSlot: @unchecked Sendable {
    let index: Int
    let start: Int
    let end: Int
    private let voice: any Voice
    let buffer: UnsafeMutablePointer<Double>
    /// Where in the block it wrote, in frames.
    private(set) var from = 0
    private(set) var count = 0

    init(_ event: NoteEvent, voice: any Voice, buffer: UnsafeMutablePointer<Double>) {
        index = event.index
        start = event.start
        end = event.end
        self.voice = voice
        self.buffer = buffer
    }

    func render(blockStart: Int, blockEnd: Int) {
        from = max(start, blockStart) - blockStart
        count = max(min(end, blockEnd) - blockStart - from, 0)
        if count > 0 { voice.render(buffer + 2 * from, frames: count) }
    }
}

/// A part while it is rendered: its notes by their start, the voices sounding, its chorus and its gains.
private final class PartState {
    private let instrument: Instrument
    private var events: [NoteEvent]
    private var next = 0
    private(set) var active: [VoiceSlot] = []
    private var chorus: Chorus?
    private var spare: [UnsafeMutablePointer<Double>] = []
    let gains: (left: Double, right: Double)
    let reverbSend: Double
    let delaySend: Double

    init(score: MusicScore, part: ScorePart, index: Int, loop: Int, total: Int) {
        instrument = part.instrument
        let rate = Double(MusicSynth.sampleRate)
        let framesPerBeat = score.framesPerBeat
        var events: [NoteEvent] = []
        for (i, note) in part.notes.enumerated() {
            guard note.beat.isFinite, note.beat.magnitude < 1e9, note.beats.isFinite, note.beats > 0, note.pitch.isFinite,
                  (0...140).contains(note.pitch), note.velocity.isFinite, note.velocity > 0
            else { continue }
            var start = score.frame(atBeat: note.beat) % loop
            if start < 0 { start += loop }
            let gate = min(max(Int((note.beats * framesPerBeat).rounded(.toNearestOrEven)), 1), loop)
            let length = min(part.instrument.frames(gate: gate, pitch: note.pitch, sampleRate: rate), total - start)
            let seed = note.seed ?? SynthRandom.mix(score.seed, UInt64(index), UInt64(i))
            let context = NoteContext(
                start: start, gate: gate, pitch: note.pitch, velocity: min(note.velocity, 1), random: SynthRandom(seed: seed),
                loopFrames: loop, sampleRate: rate)
            events.append(NoteEvent(index: i, start: start, end: start + max(length, 1), context: context))
        }
        // By start, and in the order of the score where two start together.
        self.events = events.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
        chorus = part.chorus.map { Chorus($0, loopFrames: loop, sampleRate: rate) }
        let pan = SynthMath.panGains(part.pan)
        let gain = part.gain.isFinite ? part.gain : 0
        gains = (pan.left * gain, pan.right * gain)
        reverbSend = part.reverbSend.isFinite ? max(part.reverbSend, 0) : 0
        delaySend = part.delaySend.isFinite ? max(part.delaySend, 0) : 0
    }

    deinit {
        for slot in active { slot.buffer.deallocate() }
        for buffer in spare { buffer.deallocate() }
    }

    /// Starts the voices of the notes that start before `blockEnd`, keeping `active` in the order of the score.
    func begin(blockStart: Int, blockEnd: Int) {
        while next < events.count, events[next].start < blockEnd {
            let event = events[next]
            next += 1
            let buffer = spare.popLast() ?? UnsafeMutablePointer<Double>.allocate(capacity: 2 * MusicSynth.blockFrames)
            let slot = VoiceSlot(event, voice: instrument.voice(event.context), buffer: buffer)
            let at = active.firstIndex { $0.index > slot.index } ?? active.count
            active.insert(slot, at: at)
        }
    }

    /// The part's voices added in the order of its notes, then its chorus, into `bus`; whether it has anything to add.
    func mix(into bus: UnsafeMutablePointer<Double>, frames: Int, blockStart: Int) -> Bool {
        guard !active.isEmpty || chorus != nil else { return false }
        bus.update(repeating: 0, count: 2 * frames)
        for slot in active where slot.count > 0 {
            let from = 2 * slot.from
            for i in from..<(from + 2 * slot.count) {
                bus[i] += slot.buffer[i]
            }
        }
        chorus?.process(bus, frames: frames, start: blockStart)
        return true
    }

    /// Lets go of the voices that end by `blockEnd`.
    func end(blockEnd: Int) {
        active.removeAll { slot in
            guard slot.end <= blockEnd else { return false }
            spare.append(slot.buffer)
            return true
        }
    }
}
