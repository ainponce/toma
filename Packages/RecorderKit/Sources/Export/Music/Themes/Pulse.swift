// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Pulso (electronic): 128 BPM, 4/4, 64 bars, 2:00, in F# minor. An arpeggio of filtered saws in sixteenths, a kick on
    /// every beat with everything else pumping on each beat, a bass on the off-beats, a pad and a lead that swell after
    /// every kick, and a delay of a dotted eighth (`PulseTheme` has the score bar by bar).
    static func pulse() -> MusicScore {
        PulseTheme.score()
    }
}

/// Pulso, bar by bar: eight phrases of 8 bars, a chord every 2 bars.
///
/// 1. F#m D A E: the kick, the off-beat bass, the arpeggio, the hats and the pad.
/// 2. The same with claps and open hats.
/// 3. Bm D A E: the lead comes in, the arpeggio turns another way.
/// 4. F#m D A E: the lead's second tune.
/// 5. D E F#m: the breakdown — no kick, no bass, the arpeggio darker, the pad breathing slower, the lead held.
/// 6. Bm D A E: the kick and the bass come back without the lead; a snare roll rises into the drop.
/// 7. F#m D A E: everything.
/// 8. F#m D A E: the groove with claps. Its last bar pushes the F#m of bar 1 to the and of 4 — the pad and the bass,
///    tied over the seam — and the first beat of bar 1 holds it without a kick, the arpeggio easing back in under it; the
///    kick comes back on beat 2. The turnaround of the form, so the loop's seam is a push, not a jump.
///
/// The pump is a periodic gain envelope at the beat, not a compressor: a note that starts at a point of its beat is
/// played at `pump(_:)` of that point (from 0.4 at the kick back to 1 at 0.55 of the beat), and what is held — the pad,
/// the lead — is played again on every beat, swelling in after the kick and let go just as the next one hits.
private enum PulseTheme {
    static let tempo = 128.0
    static let beatsPerBar = 4
    static let bars = 64
    static let seed: UInt64 = 0x7075_6C73_0000_0002

    /// How deep the pump goes at the kick, and the part of the beat it takes to come back up.
    static let pumpDepth = 0.6
    static let pumpRecovery = 0.55

    /// A chord: the bass's root (A1 to F#2), the arpeggio's three notes (D4 to D5), and the pad's.
    struct Harmony {
        var root: Double
        var arpeggio: [Double]
        var pad: [Double]
    }

    static let harmony: [String: Harmony] = [
        "F#m": Harmony(root: 42, arpeggio: [66, 69, 73], pad: [54, 61, 66, 69]),
        "D": Harmony(root: 38, arpeggio: [62, 66, 69], pad: [50, 57, 62, 66]),
        "A": Harmony(root: 33, arpeggio: [64, 69, 73], pad: [52, 57, 61, 64]),
        "E": Harmony(root: 40, arpeggio: [64, 68, 71], pad: [52, 56, 59, 64]),
        "Bm": Harmony(root: 35, arpeggio: [66, 71, 74], pad: [50, 54, 59, 62]),
    ]

    struct Phrase {
        /// A chord every 2 bars.
        var chords: [String]
        var kick: Bool
        var claps: Bool
        var openHats: Bool
        /// The other way of the arpeggio.
        var turned: Bool
        /// The breakdown: the dark arpeggio, the slow pad, no bass, soft hats.
        var breakdown: Bool
        /// The lead, eight bars of beats (see `beats(_:)`).
        var lead: String?
        /// A snare roll in its last bar.
        var roll: Bool
    }

    static let home = ["F#m", "D", "A", "E"]
    static let away = ["Bm", "D", "A", "E"]
    static let down = ["D", "E", "F#m", "F#m"]

    static let phrases: [Phrase] = [
        Phrase(chords: home, kick: true, claps: false, openHats: false, turned: false, breakdown: false, lead: nil, roll: false),
        Phrase(chords: home, kick: true, claps: true, openHats: true, turned: false, breakdown: false, lead: nil, roll: false),
        Phrase(
            chords: away, kick: true, claps: true, openHats: true, turned: true, breakdown: false,
            lead: "F#5 - - D5 - - B4 - | A4 - - D5 - - F#5 - | E5 - - C#5 - - E5 - | G#5 - - E5 - - B4 -", roll: false),
        Phrase(
            chords: home, kick: true, claps: true, openHats: true, turned: false, breakdown: false,
            lead: "A5 - - G#5 - - F#5 - | F#5 - - E5 - - D5 - | C#5 - - E5 - - A5 - | G#5 - - - - - E5 -", roll: false),
        Phrase(
            chords: down, kick: false, claps: false, openHats: false, turned: false, breakdown: true,
            lead: "F#5 - - - - - - - | G#5 - - - E5 - - - | F#5 - - - - - - - | C#5 - - - E5 - - -", roll: false),
        Phrase(chords: away, kick: true, claps: true, openHats: true, turned: true, breakdown: false, lead: nil, roll: true),
        Phrase(
            chords: home, kick: true, claps: true, openHats: true, turned: false, breakdown: false,
            lead: "F#5 - - E5 - - C#5 - | D5 - - E5 - - F#5 - | E5 - - C#5 - - A4 - | B4 - - C#5 - - E5 -", roll: false),
        Phrase(chords: home, kick: true, claps: true, openHats: false, turned: false, breakdown: false, lead: nil, roll: false),
    ]

    static func score() -> MusicScore {
        precondition(phrases.count * 8 == bars)
        var kick: [ScoreNote] = [], clap: [ScoreNote] = [], snare: [ScoreNote] = []
        var closed: [ScoreNote] = [], open: [ScoreNote] = [], bass: [ScoreNote] = []
        var arpeggio: [ScoreNote] = [], darkArpeggio: [ScoreNote] = [], pad: [ScoreNote] = [], slowPad: [ScoreNote] = []
        var lead: [ScoreNote] = []
        let straight = ArpeggioPattern(step: 0.25, order: [0, 1, 2, 1, 3, 2, 1, 2], gate: 0.6, velocity: 0.8, accent: 0)
        let turned = ArpeggioPattern(step: 0.25, order: [0, 2, 1, 3, 2, 4, 3, 1], gate: 0.6, velocity: 0.8, accent: 0)
        for (p, phrase) in phrases.enumerated() {
            let phraseBeat = Double(p * 8 * beatsPerBar)
            if let text = phrase.lead {
                lead += ScoreBuilder.melody(beats(text), step: 1, from: phraseBeat, velocity: 0.7)
            }
            var spans: [ChordSpan] = []
            for (c, name) in phrase.chords.enumerated() {
                guard let chord = harmony[name], let root = chord.arpeggio.first else {
                    preconditionFailure("PulseTheme: no chord \(name)")
                }
                let beat = phraseBeat + Double(c * 2 * beatsPerBar)
                let arpeggioChord = Chord(root: root, intervals: chord.arpeggio.map { $0 - root })
                spans.append(ChordSpan(chord: arpeggioChord, beat: beat, beats: Double(2 * beatsPerBar)))
                let held = chord.pad.map { ScoreNote(beat: beat, beats: Double(2 * beatsPerBar), pitch: $0, velocity: 0.55) }
                if phrase.breakdown { slowPad += held } else { pad += held }
                if !phrase.breakdown {
                    for k in 0..<(2 * beatsPerBar) {
                        bass.append(ScoreNote(beat: beat + Double(k) + 0.5, beats: 0.38, pitch: chord.root, velocity: 0.85))
                    }
                }
            }
            let notes = ScoreBuilder.arpeggio(spans, pattern: phrase.turned ? turned : straight)
            if phrase.breakdown { darkArpeggio += notes } else { arpeggio += notes }
            for b in 0..<8 {
                let beat = phraseBeat + Double(b * beatsPerBar)
                if phrase.kick { kick += drums(p == 0 && b == 0 ? "----x---x---x---" : "X---x---x---x---", at: beat) }
                if phrase.claps { clap += drums("----x-------x---", at: beat) }
                closed += drums(phrase.breakdown ? "--o---o---o---o-" : "ggogggogggogggog", at: beat)
                if phrase.openHats { open += drums("--o---o---o---o-", at: beat) }
                if phrase.roll, b == 7 {
                    // Sixteenths rising from 0.2 to 0.9.
                    snare += (0..<16).map {
                        ScoreNote(beat: beat + 0.25 * Double($0), beats: 0.25, pitch: 60, velocity: 0.2 + 0.7 * Double($0) / 15)
                    }
                }
            }
        }
        // The turnaround: the pad and the bass of bar 1 pushed to the and of 4 of the last bar, held over the first beat.
        let end = Double(bars * beatsPerBar)
        guard let top = harmony[phrases[0].chords[0]] else { preconditionFailure("PulseTheme: no first chord") }
        var padNotes = everyBeat(pad).filter { $0.beat != 0 }.map { note in
            var note = note
            if note.beat == end - 1 { note.beats = 0.5 }
            return note
        }
        padNotes += top.pad.map { ScoreNote(beat: end - 0.5, beats: 1.5, pitch: $0, velocity: 0.55) }
        bass = bass.map { note in
            var note = note
            if note.beat == end - 0.5 {
                note.pitch = top.root
                note.beats = 0.9
            }
            return note
        }

        let arpeggioPreset = LeadPreset(
            square: 0, pulseWidth: 0.5, detune: 9, cutoff: 1_100, resonance: 0.35, envelopeAmount: 1.6, attack: 0.002,
            decay: 0.14, sustain: 0.3, release: 0.05, vibratoDepth: 0, vibratoRate: 5, vibratoDelay: 0.3, level: 1)
        var darkPreset = arpeggioPreset
        darkPreset.cutoff = 600
        darkPreset.envelopeAmount = 1.2
        let padPreset = PadPreset(
            oscillators: 5, detune: 20, sub: 0, attack: 0.14, decay: 0.3, sustain: 0.85, release: 0.05, cutoff: 1_500,
            keyTracking: 0.3, resonance: 0.12, envelopeAmount: 0.6, sweepDepth: 0.7, sweepRate: 1.0 / 30, level: 1)
        var slowPadPreset = padPreset
        slowPadPreset.attack = 0.3
        slowPadPreset.release = 0.12
        slowPadPreset.cutoff = 1_100
        slowPadPreset.sweepDepth = 0.9
        let leadPreset = LeadPreset(
            square: 0.45, pulseWidth: 0.4, detune: 12, cutoff: 2_200, resonance: 0.12, envelopeAmount: 0.6, attack: 0.07,
            decay: 0.25, sustain: 0.8, release: 0.06, vibratoDepth: 0, vibratoRate: 5, vibratoDelay: 0.15, level: 1)
        let bassPreset = BassPreset(
            sine: 0.8, saw: 0.6, cutoff: 500, envelopeAmount: 2.2, filterDecay: 0.12, resonance: 0.3, attack: 0.003,
            decay: 0.25, sustain: 0.6, release: 0.05, drive: 0.35, level: 1)

        return MusicScore(
            id: "pulse", tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: seed,
            parts: [
                ScorePart(instrument: .kick, notes: humanized(kick, 1, timing: 0, velocity: 0.03), gain: 0.72, reverbSend: 0),
                ScorePart(instrument: .clap, notes: humanized(clap, 2, timing: 0.002, velocity: 0.06), gain: 2.2, reverbSend: 0.25),
                ScorePart(instrument: .snare, notes: snare, gain: 0.7, reverbSend: 0.2),
                ScorePart(
                    instrument: .hat(open: false), notes: humanized(pumped(closed), 4, timing: 0.002, velocity: 0.08),
                    gain: 3.7, pan: -0.2, reverbSend: 0.05),
                ScorePart(
                    instrument: .hat(open: true), notes: humanized(pumped(open), 5, timing: 0.002, velocity: 0.08), gain: 1.6,
                    pan: 0.2, reverbSend: 0.05),
                ScorePart(
                    instrument: .bass(bassPreset), notes: humanized(pumped(bass), 6, timing: 0, velocity: 0.04), gain: 0.8,
                    reverbSend: 0),
                ScorePart(
                    instrument: .lead(arpeggioPreset), notes: pumped(arpeggio), gain: 1.05, pan: 0.15, reverbSend: 0.2,
                    delaySend: 0.3),
                ScorePart(
                    instrument: .lead(darkPreset), notes: pumped(darkArpeggio), gain: 0.9, pan: 0.15, reverbSend: 0.3,
                    delaySend: 0.35),
                ScorePart(instrument: .pad(padPreset), notes: padNotes, gain: 0.22, reverbSend: 0.3, chorus: .gentle),
                ScorePart(instrument: .pad(slowPadPreset), notes: everyBeat(slowPad), gain: 0.35, reverbSend: 0.4, chorus: .gentle),
                ScorePart(instrument: .lead(leadPreset), notes: everyBeat(lead), gain: 0.65, pan: -0.1, reverbSend: 0.3, delaySend: 0.25),
            ],
            reverb: ReverbSettings(decay: 2, size: 1.2, damping: 5_000, preDelay: 0.02, lowCut: 300, width: 1, level: 1),
            delay: DelaySettings(beats: 0.75, feedback: 0.35, pingPong: true, lowCut: 500, highCut: 5_000, level: 1),
            masterGain: 0.644, isPlaceholder: false)
    }

    /// The pump at `beat`: 1 − depth at the beat, back to 1 along a smooth step by `pumpRecovery` of it.
    static func pump(_ beat: Double) -> Double {
        let x = min((beat - beat.rounded(.down)) / pumpRecovery, 1)
        return 1 - pumpDepth * (1 - x * x * (3 - 2 * x))
    }

    /// `notes`, each played at the pump of the point of the beat it starts at.
    static func pumped(_ notes: [ScoreNote]) -> [ScoreNote] {
        notes.map { note in
            var note = note
            note.velocity *= pump(note.beat)
            return note
        }
    }

    /// `notes` (each starting on a beat) played again on every beat they are held over.
    static func everyBeat(_ notes: [ScoreNote]) -> [ScoreNote] {
        notes.flatMap { note in
            (0..<Int(note.beats.rounded(.up))).map { k in
                ScoreNote(beat: note.beat + Double(k), beats: min(1, note.beats - Double(k)), pitch: note.pitch, velocity: note.velocity)
            }
        }
    }

    /// One bar of a drum part in sixteenths, from `beat`.
    static func drums(_ steps: String, at beat: Double) -> [ScoreNote] {
        ScoreBuilder.drums(DrumPattern(steps: steps, step: 0.25, bars: 1, beatsPerBar: beatsPerBar, from: beat))
    }

    /// `notes` humanized with a seed of their own.
    static func humanized(_ notes: [ScoreNote], _ part: UInt64, timing: Double, velocity: Double) -> [ScoreNote] {
        ScoreBuilder.humanized(notes, seed: SynthRandom.mix(seed, part), timing: timing, velocity: velocity)
    }

    /// `text`, bars of eight beats (two bars of the score each) apart by `|`; a group that is not eight beats stops the
    /// program (themes are code, and their tests build them).
    static func beats(_ text: String) -> String {
        for group in text.split(separator: "|") {
            let tokens = group.split(whereSeparator: { $0 == " " || $0 == "\n" })
            precondition(tokens.count == 8, "PulseTheme: a group of \(tokens.count) beats: \(group)")
        }
        return text
    }
}
