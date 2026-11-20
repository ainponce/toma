// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// A theme of the music library as `MusicSynth` plays it (`music-1`): a loop of `bars` bars at `tempo`, made of parts,
/// each an instrument playing notes, all of them through one reverb and one delay.
///
/// How to write one (`Themes/`):
///
/// - Its notes start inside the loop, beat 0 to `bars × beatsPerBar` (a note a little before 0, as `humanized` may leave
///   the downbeat, starts that much before the loop's end). Anything still sounding at the loop's end — a release, the
///   reverb, an echo — comes back at its start, so the last bar can lead into the first without a seam.
/// - A note sounds to its end, its release included (up to 2 s, `MusicSynth.maxRelease`), even when that is well into
///   the next pass; it may be held at most a whole loop. After the last note, the reverb (its decay up to 3 s) and the
///   echoes (capped to fade within 6 s) die out within `MusicSynth.tailFrames` (8 s).
/// - What sways over the loop (a filter sweep, a tremolo, a chorus) takes a whole number of cycles per loop: give it in
///   Hz and it is rounded. A note's own vibrato starts with the note.
/// - Its randomness comes from `seed`: each note gets `SynthRandom.mix(seed, part, note)` (or its own `ScoreNote.seed`),
///   and `ScoreBuilder.humanized` takes a seed. Never a `random()` of Swift, never the time.
/// - `masterGain` brings it to −16 LUFS (plan decision 5; `recorder-dev music` prints its loudness); the soft clip after
///   it keeps every peak under −1 dBFS.
///
/// Changing anything a theme sounds like changes its bytes, pinned in its test; after the merge of phase 3 into `main`,
/// another sound is `music-2`.
public struct MusicScore: Sendable, Equatable, Codable {
    /// One of `MusicThemes.ids`.
    public var id: String
    /// Beats per minute.
    public var tempo: Double
    public var beatsPerBar: Int
    public var bars: Int
    /// The seed of every voice of the theme.
    public var seed: UInt64
    /// Summed in this order.
    public var parts: [ScorePart]
    public var reverb: ReverbSettings
    public var delay: DelaySettings?
    /// The amplitude the whole theme is multiplied by before the soft clip.
    public var masterGain: Double
    /// Whether this is a stand-in for a theme not composed yet (a pad chord), not the theme itself.
    public var isPlaceholder: Bool

    public init(
        id: String, tempo: Double, beatsPerBar: Int, bars: Int, seed: UInt64, parts: [ScorePart], reverb: ReverbSettings,
        delay: DelaySettings?, masterGain: Double, isPlaceholder: Bool
    ) {
        self.id = id
        self.tempo = tempo
        self.beatsPerBar = beatsPerBar
        self.bars = bars
        self.seed = seed
        self.parts = parts
        self.reverb = reverb
        self.delay = delay
        self.masterGain = masterGain
        self.isPlaceholder = isPlaceholder
    }

    /// The longest loop `MusicSynth` renders: 5 minutes.
    public static let maxLoopFrames = 14_400_000

    /// The beats of the loop: `bars × beatsPerBar`.
    public var beats: Int { bars * beatsPerBar }

    /// The frames of the loop at 48 kHz, `bars × beatsPerBar × 60 / tempo × 48 000`, when that is a whole number from 1
    /// to `maxLoopFrames`; `nil` otherwise (a tempo whose loop does not end on a frame cannot repeat exactly).
    public var loopFrames: Int? {
        guard tempo.isFinite, tempo > 0, bars > 0, beatsPerBar > 0, bars <= 100_000, beatsPerBar <= 1_000 else { return nil }
        let numerator = Double(bars * beatsPerBar) * 60 * Double(MusicSynth.sampleRate)
        let frames = numerator / tempo
        guard frames.isFinite, frames >= 1, frames <= Double(Self.maxLoopFrames), frames == frames.rounded(.toNearestOrEven),
              frames * tempo == numerator
        else { return nil }
        return Int(frames)
    }

    /// The frames of one beat: `60 × 48 000 / tempo` (not always a whole number).
    public var framesPerBeat: Double { 60 * Double(MusicSynth.sampleRate) / tempo }

    /// The frame where beat `beat` falls, rounded to the nearest.
    public func frame(atBeat beat: Double) -> Int {
        Int((beat * 60 * Double(MusicSynth.sampleRate) / tempo).rounded(.toNearestOrEven))
    }

    /// What its render depends on, as 16 lowercase hex digits: the first 8 bytes of the SHA-256 of
    /// `music-1/engine-<MusicSynth.engineVersion>/` and the score as JSON with sorted keys. A change to any note,
    /// preset or setting of the score, or to the engine's version, changes it; the music library keeps a theme's file
    /// under it, so a file made from another score is never taken for the theme.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        var data = Data("\(MusicThemes.algorithm)/engine-\(MusicSynth.engineVersion)/".utf8)
        data.append((try? encoder.encode(self)) ?? Data(String(describing: self).utf8))
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// An instrument and the notes it plays, with where it sits in the mix.
public struct ScorePart: Sendable, Equatable, Codable {
    public var instrument: Instrument
    public var notes: [ScoreNote]
    /// Its level, as an amplitude.
    public var gain: Double
    /// −1 left, 0 center, 1 right (equal power).
    public var pan: Double
    /// How much of it goes to the reverb and to the delay, as amplitudes (after `gain` and `pan`).
    public var reverbSend: Double
    public var delaySend: Double
    /// A chorus on this part alone, before it is panned.
    public var chorus: ChorusSettings?

    public init(
        instrument: Instrument, notes: [ScoreNote], gain: Double = 1, pan: Double = 0, reverbSend: Double = 0.2,
        delaySend: Double = 0, chorus: ChorusSettings? = nil
    ) {
        self.instrument = instrument
        self.notes = notes
        self.gain = gain
        self.pan = pan
        self.reverbSend = reverbSend
        self.delaySend = delaySend
        self.chorus = chorus
    }
}

/// One note: where it starts and how long it is held, in beats of the score, its pitch and how hard it is played.
public struct ScoreNote: Sendable, Equatable, Codable {
    public var beat: Double
    public var beats: Double
    /// MIDI: 60 is C4, 69 A4 (440 Hz); a fraction is that many hundredths of a semitone. Drums take 60 as their own
    /// tuning (a kick or a snare follows the pitch; the others ignore it).
    public var pitch: Double
    /// 0 to 1.
    public var velocity: Double
    /// The seed of this note's voice; `nil` (the default) is `SynthRandom.mix(score.seed, part, note)`, its place in the
    /// score. Give two notes the same seed to make them the very same sound.
    public var seed: UInt64?

    public init(beat: Double, beats: Double, pitch: Double, velocity: Double, seed: UInt64? = nil) {
        self.beat = beat
        self.beats = beats
        self.pitch = pitch
        self.velocity = velocity
        self.seed = seed
    }
}

/// What plays a part's notes (`SynthInstruments.swift` has the presets and what each value does).
public enum Instrument: Sendable, Equatable, Codable {
    case pad(PadPreset)
    case electricPiano(EPianoPreset)
    case piano(PianoPreset)
    case pluck(PluckPreset)
    case bass(BassPreset)
    case lead(LeadPreset)
    case kick
    case snare
    case hat(open: Bool)
    case clap
    case shaker
    /// The crackle of a record while the note is held: hold one note over the whole loop.
    case vinyl
}

// MARK: - Pitches and chords

/// Note names as MIDI pitches.
public enum Pitch {
    /// The MIDI pitch of `name`: a letter A to G, an optional `#` or `b`, and an octave from −1 to 9 (`"C4"` is 60,
    /// `"A4"` 69, `"Eb3"` 51, `"F#2"` 42). A name that is not one stops the program: themes are code, and their tests
    /// build them.
    public static func midi(_ name: String) -> Double {
        guard let pitch = parse(name) else { preconditionFailure("Pitch: \"\(name)\" is not a note name") }
        return pitch
    }

    static func parse(_ name: String) -> Double? {
        var characters = Substring(name)
        guard let letter = characters.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)]
        else { return nil }
        characters = characters.dropFirst()
        var semitone = base
        if characters.first == "#" {
            semitone += 1
            characters = characters.dropFirst()
        } else if characters.first == "b" {
            semitone -= 1
            characters = characters.dropFirst()
        }
        guard let octave = Int(characters), (-1...9).contains(octave) else { return nil }
        return Double((octave + 1) * 12 + semitone)
    }
}

/// A chord: a root and the semitones of its pitches above it.
public struct Chord: Sendable, Equatable {
    /// MIDI.
    public var root: Double
    /// Semitones above the root, the root's 0 included, from the lowest.
    public var intervals: [Double]

    public init(root: Double, intervals: [Double]) {
        self.root = root
        self.intervals = intervals
    }

    /// The chord of `symbol` with its root in octave `octave` (`Chord("Am7")` is A3 C4 E4 G4, `Chord("C", octave: 4)`
    /// C4 E4 G4):
    /// a root as in `Pitch` without the octave, then one of the qualities in `qualities` (`""` major, `"m"`, `"7"`,
    /// `"maj7"`, `"m7"`, `"6"`, `"m6"`, `"9"`, `"maj9"`, `"m9"`, `"add9"`, `"madd9"`, `"sus2"`, `"sus4"`, `"7sus4"`,
    /// `"m11"`, `"dim"`, `"aug"`, `"m7b5"`, `"5"`). A symbol that is not one stops the program.
    public init(_ symbol: String, octave: Int = 3) {
        var rest = Substring(symbol)
        var rootName = rest.prefix(1)
        rest = rest.dropFirst()
        if rest.first == "#" || rest.first == "b" {
            rootName += rest.prefix(1)
            rest = rest.dropFirst()
        }
        guard let root = Pitch.parse("\(rootName)\(octave)"), let intervals = Self.qualities[String(rest)] else {
            preconditionFailure("Chord: \"\(symbol)\" is not a chord symbol")
        }
        self.init(root: root, intervals: intervals)
    }

    /// The qualities `init(_:octave:)` knows, as semitones above the root.
    public static let qualities: [String: [Double]] = [
        "": [0, 4, 7], "m": [0, 3, 7], "5": [0, 7], "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10],
        "6": [0, 4, 7, 9], "m6": [0, 3, 7, 9], "9": [0, 4, 7, 10, 14], "maj9": [0, 4, 7, 11, 14], "m9": [0, 3, 7, 10, 14],
        "add9": [0, 4, 7, 14], "madd9": [0, 3, 7, 14], "sus2": [0, 2, 7], "sus4": [0, 5, 7], "7sus4": [0, 5, 7, 10],
        "m11": [0, 3, 7, 10, 14, 17], "dim": [0, 3, 6], "aug": [0, 4, 8], "m7b5": [0, 3, 6, 10],
    ]

    /// Its pitches, from the lowest.
    public var pitches: [Double] { intervals.map { root + $0 } }

    /// The same chord `semitones` higher.
    public func transposed(_ semitones: Double) -> Chord {
        Chord(root: root + semitones, intervals: intervals)
    }
}

/// How a chord's pitches are laid out when it is played.
public enum Voicing: Sendable, Equatable {
    /// As they are.
    case close
    /// Every other pitch, from the second, an octave up: wider, more open.
    case open
    /// The root an octave down, the rest as they are.
    case spread
    /// The lowest `n` pitches an octave up.
    case inversion(Int)
    /// Only the root, `octaves` octaves from it: what a bass plays.
    case root(octaves: Int)

    /// `pitches` (from the lowest) laid out, from the lowest.
    public func apply(_ pitches: [Double]) -> [Double] {
        switch self {
        case .close:
            return pitches
        case .open:
            return pitches.enumerated().map { $0.offset % 2 == 1 ? $0.element + 12 : $0.element }.sorted()
        case .spread:
            guard let first = pitches.first else { return [] }
            return [first - 12] + pitches.dropFirst()
        case .inversion(let n):
            let k = min(max(n, 0), pitches.count)
            return (pitches.dropFirst(k) + pitches.prefix(k).map { $0 + 12 }).sorted()
        case .root(let octaves):
            return pitches.first.map { [$0 + 12 * Double(octaves)] } ?? []
        }
    }
}

/// A chord held over a stretch of the score, in beats.
public struct ChordSpan: Sendable, Equatable {
    public var chord: Chord
    public var beat: Double
    public var beats: Double

    public init(chord: Chord, beat: Double, beats: Double) {
        self.chord = chord
        self.beat = beat
        self.beats = beats
    }
}

/// The notes an arpeggio plays over each chord.
public struct ArpeggioPattern: Sendable, Equatable {
    /// Beats from one note to the next.
    public var step: Double
    /// The chord's pitch each step plays, in turn (0 is the lowest); past the last pitch, the same ones an octave up
    /// (with 3 pitches, 3 is the root an octave up), and −1 a rest.
    public var order: [Int]
    /// How long each note is held, in steps (more than 1 lets them ring over each other).
    public var gate: Double
    public var velocity: Double
    /// Extra velocity on the notes that fall on a beat (0 to 1).
    public var accent: Double
    /// Semitones added to every pitch.
    public var transpose: Double

    public init(
        step: Double = 0.5, order: [Int] = [0, 1, 2, 3], gate: Double = 1, velocity: Double = 0.6, accent: Double = 0.15,
        transpose: Double = 0
    ) {
        self.step = step
        self.order = order
        self.gate = gate
        self.velocity = velocity
        self.accent = accent
        self.transpose = transpose
    }

    /// Up through the chord and its octave, in eighths.
    public static let up = ArpeggioPattern()
    /// Up and down, in eighths.
    public static let upDown = ArpeggioPattern(order: [0, 1, 2, 3, 2, 1])
    /// A broken chord in sixteenths that rings.
    public static let ringing = ArpeggioPattern(step: 0.25, order: [0, 2, 1, 3, 2, 4, 3, 1], gate: 3, velocity: 0.5)
}

/// A drum part as steps: one character a step, repeated over its bars.
public struct DrumPattern: Sendable, Equatable {
    /// `X` a hit at velocity 1, `x` at 0.8, `o` at 0.55, `g` (a ghost) at 0.3; `-` or `.` a rest. Spaces and `|` are
    /// ignored, so bars can be written apart: `"x---x---x---x---"` is a kick on every beat in sixteenths.
    public var steps: String
    /// Beats per step: 0.25 is sixteenths in 4/4, 0.5 eighths.
    public var step: Double
    /// The bars it fills, repeating `steps` as often as it takes.
    public var bars: Int
    public var beatsPerBar: Int
    /// The pitch of its notes (tunes a kick or a snare; 60 is their own tuning).
    public var pitch: Double
    /// The beat its first step falls on.
    public var from: Double

    public init(steps: String, step: Double = 0.25, bars: Int, beatsPerBar: Int = 4, pitch: Double = 60, from: Double = 0) {
        self.steps = steps
        self.step = step
        self.bars = bars
        self.beatsPerBar = beatsPerBar
        self.pitch = pitch
        self.from = from
    }

    /// The velocity of each step (`nil` a rest), spaces and bar lines left out.
    var velocities: [Double?] {
        steps.compactMap { character -> Double?? in
            switch character {
            case "X": return .some(1)
            case "x": return .some(0.8)
            case "o": return .some(0.55)
            case "g": return .some(0.3)
            case "-", ".": return .some(nil)
            default: return nil
            }
        }
    }
}

// MARK: - Writing a score

/// Builds the notes of a score from chords, patterns and melodies, and shapes them (shift, repeat, transpose, humanize).
/// Everything is in beats of the score, and all of it is deterministic: the only randomness, in `humanized`, comes from
/// its seed.
public enum ScoreBuilder {
    /// Each chord held for `bars` bars, one after the other from beat `from`.
    public static func progression(_ chords: [Chord], bars: Double, beatsPerBar: Int = 4, from: Double = 0) -> [ChordSpan] {
        let beats = bars * Double(beatsPerBar)
        return chords.enumerated().map { ChordSpan(chord: $0.element, beat: from + Double($0.offset) * beats, beats: beats) }
    }

    /// Each chord held for `bars` bars, one after the other from beat 0, its pitches laid out by `voicing`.
    public static func chords(
        _ chords: [Chord], bars: Double, voicing: Voicing = .close, beatsPerBar: Int = 4, velocity: Double = 0.6
    ) -> [ScoreNote] {
        self.chords(progression(chords, bars: bars, beatsPerBar: beatsPerBar), voicing: voicing, velocity: velocity)
    }

    /// Each span's chord held over it, its pitches laid out by `voicing`, `legato` of its length (more than 1 overlaps
    /// the next chord, less leaves a gap).
    public static func chords(
        _ spans: [ChordSpan], voicing: Voicing = .close, velocity: Double = 0.6, legato: Double = 1
    ) -> [ScoreNote] {
        spans.flatMap { span in
            voicing.apply(span.chord.pitches).map {
                ScoreNote(beat: span.beat, beats: span.beats * legato, pitch: $0, velocity: velocity)
            }
        }
    }

    /// The pitches of each span's chord, one per step of `pattern`, over the span.
    public static func arpeggio(_ spans: [ChordSpan], pattern: ArpeggioPattern) -> [ScoreNote] {
        guard pattern.step > 0, !pattern.order.isEmpty else { return [] }
        var notes: [ScoreNote] = []
        for span in spans {
            let pitches = span.chord.pitches
            guard !pitches.isEmpty else { continue }
            let count = Int((span.beats / pattern.step).rounded(.towardZero))
            for k in 0..<max(count, 0) {
                let index = pattern.order[k % pattern.order.count]
                guard index >= 0 else { continue }
                let pitch = pitches[index % pitches.count] + 12 * Double(index / pitches.count) + pattern.transpose
                let beat = span.beat + Double(k) * pattern.step
                let onBeat = (beat - beat.rounded(.down)) == 0
                let velocity = min(pattern.velocity + (onBeat ? pattern.accent : 0), 1)
                notes.append(ScoreNote(beat: beat, beats: pattern.step * pattern.gate, pitch: pitch, velocity: velocity))
            }
        }
        return notes
    }

    /// The hits of `pattern`, every second step late by `swing` of a step (0 straight, 0.33 a triplet feel, at most 0.5).
    public static func drums(_ pattern: DrumPattern, swing: Double = 0) -> [ScoreNote] {
        let velocities = pattern.velocities
        guard !velocities.isEmpty, pattern.step > 0 else { return [] }
        let late = min(max(swing, 0), 0.5) * pattern.step
        let count = Int((Double(pattern.bars * pattern.beatsPerBar) / pattern.step).rounded(.towardZero))
        var notes: [ScoreNote] = []
        for i in 0..<max(count, 0) {
            guard let velocity = velocities[i % velocities.count] else { continue }
            let beat = pattern.from + Double(i) * pattern.step + (i % 2 == 1 ? late : 0)
            notes.append(ScoreNote(beat: beat, beats: pattern.step, pitch: pattern.pitch, velocity: velocity))
        }
        return notes
    }

    /// A melody written as steps of `step` beats from beat `from`, separated by spaces: a note name (`"E5"`, `"Bb4"`, as
    /// in `Pitch`) or a MIDI number starts a note of one step, `-` holds the note before one step more, `.` rests a step,
    /// and `|` (a bar line) is ignored. `"C5 - E5 G5 | . A5 - -"`. A token that is none of these stops the program.
    public static func melody(_ text: String, step: Double, from: Double = 0, velocity: Double = 0.8) -> [ScoreNote] {
        var notes: [ScoreNote] = []
        var position = from
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            switch token {
            case "|":
                continue
            case "-":
                if !notes.isEmpty { notes[notes.count - 1].beats += step }
            case ".":
                break
            default:
                guard let pitch = Pitch.parse(String(token)) ?? Double(token) else {
                    preconditionFailure("ScoreBuilder.melody: \"\(token)\" is not a note, - or .")
                }
                notes.append(ScoreNote(beat: position, beats: step, pitch: pitch, velocity: velocity))
            }
            position += step
        }
        return notes
    }

    /// `notes` with each start moved by up to ±`timing` beats and each velocity changed by up to ±`velocity` of itself
    /// (kept in 0 … 1), at random from `seed`, in their order: the same notes and seed give the same result.
    public static func humanized(_ notes: [ScoreNote], seed: UInt64, timing: Double, velocity: Double) -> [ScoreNote] {
        var random = SynthRandom(seed: seed)
        return notes.map { note in
            var note = note
            note.beat += random.bipolar() * timing
            note.velocity = min(max(note.velocity * (1 + random.bipolar() * velocity), 0), 1)
            return note
        }
    }

    /// `notes` `times` times, each copy `every` beats after the one before.
    public static func repeated(_ notes: [ScoreNote], every beats: Double, times: Int) -> [ScoreNote] {
        (0..<max(times, 0)).flatMap { shifted(notes, by: Double($0) * beats) }
    }

    /// `notes` `beats` later.
    public static func shifted(_ notes: [ScoreNote], by beats: Double) -> [ScoreNote] {
        notes.map { note in
            var note = note
            note.beat += beats
            return note
        }
    }

    /// `notes` `semitones` higher.
    public static func transposed(_ notes: [ScoreNote], by semitones: Double) -> [ScoreNote] {
        notes.map { note in
            var note = note
            note.pitch += semitones
            return note
        }
    }
}
