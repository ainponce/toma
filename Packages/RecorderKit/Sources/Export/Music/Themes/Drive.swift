// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Impulso (happy pop): 112 BPM, 4/4, 56 bars, 2:00, in E major. A kick on every beat, claps on 2 and 4, a bass in
    /// eighths, a bright pluck that plays the hook in the verses and the tune in the choruses, muted plucks on the
    /// off-beats and a pad in the choruses (`DriveTheme` has the score bar by bar).
    static func drive() -> MusicScore {
        DriveTheme.score()
    }
}

/// Impulso, bar by bar: seven phrases of 8 bars.
///
/// 1. Verse, E B C#m A · E B A B: the hook, the off-beat plucks, closed hats.
/// 2. Verse again, the hook a chord note higher in bars 5 to 7.
/// 3. Chorus, A E B C#m · A E B B: the tune, the pad, open hats, the bass jumping octaves.
/// 4. Chorus with the tune's second ending; a clap fill leads into the bridge.
/// 5. Bridge, C#m A E B · C#m A F#m B: the pluck rings in arpeggios over the pad, a shaker, the bass in half notes.
/// 6. The last chorus, with the shaker and an ending that comes down to the verse.
/// 7. Verse, the hook higher in its first bars. Its last bar pushes the E of bar 1 to the and of 4 — the bass, the
///    plucks, a kick and the hook's first note, tied over the seam — and bar 1 lets it ring instead of striking its
///    downbeat: the turnaround of the form, so the loop's seam is a push, not a jump.
private enum DriveTheme {
    static let tempo = 112.0
    static let beatsPerBar = 4
    static let bars = 56
    static let seed: UInt64 = 0x6472_6976_0000_0002

    /// A chord: the bass's root (A1 to F#2), the muted plucks' voicing near middle C, and the pad's.
    struct Harmony {
        var root: Double
        var stab: [Double]
        var pad: [Double]
    }

    static let harmony: [String: Harmony] = [
        "E": Harmony(root: 40, stab: [56, 59, 64], pad: [52, 59, 64, 68]),
        "B": Harmony(root: 35, stab: [54, 59, 63], pad: [51, 54, 59, 63]),
        "C#m": Harmony(root: 37, stab: [56, 61, 64], pad: [49, 56, 61, 64]),
        "A": Harmony(root: 33, stab: [57, 61, 64], pad: [52, 57, 61, 64]),
        "F#m": Harmony(root: 42, stab: [54, 57, 61], pad: [54, 57, 61, 66]),
    ]

    /// The hook, a bar per chord: the chord's notes on beats 1, 2 and 3, the and of 3 and the and of 4.
    static let hook: [String: String] = [
        "E": "E5 . B4 . G#4 B4 . E5", "B": "D#5 . B4 . F#4 B4 . D#5", "C#m": "C#5 . G#4 . E4 G#4 . C#5",
        "A": "C#5 . A4 . E4 A4 . C#5",
    ]
    /// The hook a chord note higher.
    static let hookHigh: [String: String] = [
        "E": "G#5 . E5 . B4 E5 . G#5", "B": "F#5 . D#5 . B4 D#5 . F#5", "C#m": "E5 . C#5 . G#4 C#5 . E5",
        "A": "E5 . C#5 . A4 C#5 . E5",
    ]

    enum Kind { case verse, chorus, bridge }

    struct Phrase {
        var kind: Kind
        var chords: [String]
        /// What the lead pluck plays, eight bars of eighths.
        var lead: String?
        var shaker: Bool
        /// The claps of its last bar, which lead into the next phrase.
        var fill: String
    }

    static let verse = ["E", "B", "C#m", "A", "E", "B", "A", "B"]
    static let chorus = ["A", "E", "B", "C#m", "A", "E", "B", "B"]
    static let bridge = ["C#m", "A", "E", "B", "C#m", "A", "F#m", "B"]

    static let pickup = "----x-------x-o-"

    static let phrases: [Phrase] = [
        Phrase(kind: .verse, chords: verse, lead: hooks(verse, high: []), shaker: false, fill: pickup),
        Phrase(kind: .verse, chords: verse, lead: hooks(verse, high: [4, 5, 6]), shaker: false, fill: pickup),
        Phrase(
            kind: .chorus, chords: chorus,
            lead: """
                C#5 - E5 - F#5 - E5 - | E5 - - - B4 - - - | B4 - C#5 - D#5 - E5 - | C#5 - - - - - . . |
                C#5 - E5 - F#5 - A5 - | G#5 - - - E5 - - - | F#5 - E5 - D#5 - B4 - | D#5 - - - - - . .
                """,
            shaker: false, fill: pickup),
        Phrase(
            kind: .chorus, chords: chorus,
            lead: """
                C#5 - E5 - F#5 - E5 - | E5 - - - B4 - - - | B4 - C#5 - D#5 - F#5 - | E5 - - - - - . . |
                A5 - G#5 - F#5 - E5 - | G#5 - - - B4 - - - | C#5 - D#5 - E5 - F#5 - | F#5 - - - - - . .
                """,
            shaker: false, fill: "----x-----o-x-oo"),
        Phrase(kind: .bridge, chords: bridge, lead: nil, shaker: true, fill: "----x---o-o-x-xx"),
        Phrase(
            kind: .chorus, chords: chorus,
            lead: """
                C#5 - E5 - F#5 - E5 - | E5 - - - B4 - - - | B4 - C#5 - D#5 - E5 - | C#5 - - - - - . . |
                C#5 - E5 - F#5 - A5 - | G#5 - - - E5 - - - | F#5 - E5 - D#5 - C#5 - | B4 - - - - - . .
                """,
            shaker: true, fill: pickup),
        Phrase(kind: .verse, chords: verse, lead: hooks(verse, high: [0, 1, 2]), shaker: false, fill: pickup),
    ]

    static func score() -> MusicScore {
        precondition(phrases.count * 8 == bars)
        var kick: [ScoreNote] = [], clap: [ScoreNote] = [], closed: [ScoreNote] = [], open: [ScoreNote] = []
        var shaker: [ScoreNote] = [], bass: [ScoreNote] = [], stabs: [ScoreNote] = [], lead: [ScoreNote] = []
        var arpeggio: [ScoreNote] = [], pad: [ScoreNote] = []
        let chords = phrases.flatMap(\.chords)
        for (p, phrase) in phrases.enumerated() {
            let phraseBeat = Double(p * 8 * beatsPerBar)
            if let text = phrase.lead {
                lead += ScoreBuilder.melody(eighths(text), step: 0.5, from: phraseBeat, velocity: 0.7)
            }
            for b in 0..<8 {
                let bar = p * 8 + b
                let beat = Double(bar * beatsPerBar)
                guard let chord = harmony[chords[bar]], let next = harmony[chords[(bar + 1) % bars]] else {
                    preconditionFailure("DriveTheme: no chord \(chords[bar])")
                }
                // The turnaround: the last bar pushes the first chord, its bass, a kick and the hook's first note to its
                // and of 4, tied over the seam, and the first bar does not strike its downbeat again.
                let pushes = bar == bars - 1, pushed = bar == 0
                let kickSteps = pushes ? "X---x---x---x-o-" : pushed ? "----x---x---x---" : "X---x---x---x---"
                kick += drums(phrase.kind == .bridge ? "x---x---x---x---" : kickSteps, at: beat)
                clap += drums(b == 7 ? phrase.fill : "----x-------x---", at: beat)
                if phrase.shaker { shaker += drums("o-goo-goo-goo-go", at: beat) }
                switch phrase.kind {
                case .verse:
                    closed += drums("g-o-g-o-g-o-g-o-", at: beat)
                    // A cymbal on the top, after the push.
                    if pushed { open += drums("o---------------", at: beat) }
                case .chorus:
                    closed += drums("g---g---g---g---", at: beat)
                    open += drums("--o---o---o---o-", at: beat)
                case .bridge:
                    break
                }
                // The bass: eighths of the root (jumping an octave in the chorus), or half notes in the bridge.
                switch phrase.kind {
                case .verse, .chorus:
                    let velocities = [0.9, 0.65, 0.8, 0.65, 0.85, 0.65, 0.8, 0.65]
                    for e in 0..<8 where !(pushed && e < 2) && !(pushes && e == 7) {
                        let octave = phrase.kind == .chorus && (e == 2 || e == 6) ? 12.0 : 0
                        bass.append(
                            ScoreNote(beat: beat + 0.5 * Double(e), beats: 0.42, pitch: chord.root + octave, velocity: velocities[e]))
                    }
                    if pushes { bass.append(ScoreNote(beat: beat + 3.5, beats: 1.5, pitch: next.root, velocity: 0.9)) }
                case .bridge:
                    bass += [
                        ScoreNote(beat: beat, beats: 1.9, pitch: chord.root, velocity: 0.8),
                        ScoreNote(beat: beat + 2, beats: 1.4, pitch: chord.root, velocity: 0.7),
                        ScoreNote(beat: beat + 3.5, beats: 0.45, pitch: chord.root + 12, velocity: 0.6),
                    ]
                }
                // The muted plucks on the off-beats, and the pad held over the bar.
                if phrase.kind != .bridge {
                    for offBeat in [0.5, 1.5, 2.5, 3.5] {
                        let stab = pushes && offBeat == 3.5 ? next.stab : chord.stab
                        stabs += stab.map { ScoreNote(beat: beat + offBeat, beats: 0.3, pitch: $0, velocity: 0.55) }
                    }
                }
                if phrase.kind != .verse {
                    pad += chord.pad.map { ScoreNote(beat: beat, beats: Double(beatsPerBar), pitch: $0, velocity: 0.5) }
                }
            }
            if phrase.kind == .bridge {
                let spans = phrase.chords.enumerated().compactMap { b, name -> ChordSpan? in
                    guard let stab = harmony[name]?.stab, let root = stab.first else { return nil }
                    let chord = Chord(root: root, intervals: stab.map { $0 - root })
                    return ChordSpan(chord: chord, beat: phraseBeat + Double(b * beatsPerBar), beats: Double(beatsPerBar))
                }
                let pattern = ArpeggioPattern(
                    step: 0.5, order: [0, 1, 2, 3, 4, 3, 2, 1], gate: 2.5, velocity: 0.55, accent: 0.1, transpose: 12)
                arpeggio += ScoreBuilder.arpeggio(spans, pattern: pattern)
            }
        }
        // The hook's first note, pushed to the and of 4 of the last bar.
        let and4 = Double(bars * beatsPerBar) - 0.5
        if let first = lead.firstIndex(where: { $0.beat == 0 }) {
            var pushedNote = lead.remove(at: first)
            lead.removeAll { $0.beat == and4 }
            pushedNote.beat = and4
            pushedNote.beats = 1
            lead.append(pushedNote)
        }

        let leadPreset = PluckPreset(brightness: 0.7, damping: 0.35, decay: 1.4, pickPosition: 0.15, release: 0.12, spread: 0.2, level: 1)
        let stabPreset = PluckPreset(brightness: 0.55, damping: 0.7, decay: 0.5, pickPosition: 0.25, release: 0.05, spread: 0.6, level: 1)
        let padPreset = PadPreset(
            oscillators: 5, detune: 16, sub: 0, attack: 0.5, decay: 1.5, sustain: 0.8, release: 0.9, cutoff: 1_800,
            keyTracking: 0.3, resonance: 0.1, envelopeAmount: 0.5, sweepDepth: 0.5, sweepRate: 0.1, level: 1)
        let bassPreset = BassPreset(
            sine: 1, saw: 0.45, cutoff: 550, envelopeAmount: 2, filterDecay: 0.12, resonance: 0.2, attack: 0.003, decay: 0.4,
            sustain: 0.7, release: 0.06, drive: 0.3, level: 1)

        return MusicScore(
            id: "drive", tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: seed,
            parts: [
                ScorePart(instrument: .kick, notes: humanized(kick, 1, timing: 0, velocity: 0.04), gain: 0.72, reverbSend: 0),
                ScorePart(instrument: .clap, notes: humanized(clap, 2, timing: 0.002, velocity: 0.08), gain: 2.4, reverbSend: 0.2),
                ScorePart(
                    instrument: .hat(open: false), notes: humanized(closed, 3, timing: 0.003, velocity: 0.12), gain: 4.2,
                    pan: -0.25, reverbSend: 0.05),
                ScorePart(
                    instrument: .hat(open: true), notes: humanized(open, 4, timing: 0.003, velocity: 0.1), gain: 1.75, pan: 0.2,
                    reverbSend: 0.05),
                ScorePart(
                    instrument: .shaker, notes: humanized(shaker, 5, timing: 0.003, velocity: 0.15), gain: 1.8, pan: 0.35,
                    reverbSend: 0.1),
                ScorePart(
                    instrument: .bass(bassPreset), notes: humanized(bass, 6, timing: 0.003, velocity: 0.05), gain: 0.68,
                    reverbSend: 0),
                ScorePart(
                    instrument: .pluck(stabPreset), notes: humanized(stabs, 7, timing: 0.004, velocity: 0.1), gain: 1.26,
                    pan: 0.1, reverbSend: 0.15),
                ScorePart(
                    instrument: .pluck(leadPreset), notes: humanized(lead, 8, timing: 0.004, velocity: 0.08), gain: 2.26,
                    pan: -0.1, reverbSend: 0.25, delaySend: 0.2),
                ScorePart(
                    instrument: .pluck(.harp), notes: humanized(arpeggio, 9, timing: 0.004, velocity: 0.1), gain: 1.3,
                    reverbSend: 0.3, delaySend: 0.25),
                ScorePart(instrument: .pad(padPreset), notes: pad, gain: 0.22, reverbSend: 0.35, chorus: .gentle),
            ],
            reverb: ReverbSettings(decay: 1.6, size: 0.9, damping: 5_500, preDelay: 0.015, lowCut: 250, width: 1, level: 1),
            delay: DelaySettings(beats: 0.75, feedback: 0.25, pingPong: true, lowCut: 500, highCut: 4_500, level: 1),
            masterGain: 0.616, isPlaceholder: false)
    }

    /// The hook over `chords`, a step higher in the bars `high`.
    static func hooks(_ chords: [String], high: Set<Int>) -> String {
        chords.enumerated().map { b, name in (high.contains(b) ? hookHigh : hook)[name] ?? "" }.joined(separator: " | ")
    }

    /// One bar of a drum part in sixteenths, from `beat`.
    static func drums(_ steps: String, at beat: Double) -> [ScoreNote] {
        ScoreBuilder.drums(DrumPattern(steps: steps, step: 0.25, bars: 1, beatsPerBar: beatsPerBar, from: beat))
    }

    /// `notes` humanized with a seed of their own.
    static func humanized(_ notes: [ScoreNote], _ part: UInt64, timing: Double, velocity: Double) -> [ScoreNote] {
        ScoreBuilder.humanized(notes, seed: SynthRandom.mix(seed, part), timing: timing, velocity: velocity)
    }

    /// `text`, bars of eight eighths apart by `|`; a bar that is not eight eighths stops the program (themes are code,
    /// and their tests build them).
    static func eighths(_ text: String) -> String {
        for bar in text.split(separator: "|") {
            let tokens = bar.split(whereSeparator: { $0 == " " || $0 == "\n" })
            precondition(tokens.count == 8, "DriveTheme: a bar of \(tokens.count) eighths: \(bar)")
        }
        return text
    }
}
