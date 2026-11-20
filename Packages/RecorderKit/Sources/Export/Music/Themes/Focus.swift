// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Foco (lo-fi): 80 BPM, 4/4, 40 bars, 2:00, in C major. An electric piano in rolled seventh and ninth chords over a
    /// round bass, a dusty kit whose even sixteenths fall a fifth of a sixteenth late, a nylon pluck that sings in four
    /// of its five phrases, a dark pad under it all and the crackle of a record (`FocusTheme` has the score bar by bar).
    static func focus() -> MusicScore {
        FocusTheme.score()
    }
}

/// Foco, bar by bar: five phrases of 8 bars.
///
/// 1. Fmaj9 Em7 Dm9 Cmaj9, twice: the groove alone.
/// 2. The same, and the pluck's first tune.
/// 3. Am9 Fmaj9 Cmaj9 G9 · Am9 Fmaj9 Dm9 G9: the minor side, a longer tune, the piano on three hits a bar.
/// 4. The same, ending on Em7: the kick rests, the bass and the piano hold, a sparse tune; a pickup brings the kick back.
/// 5. The first progression again with the last tune. Its last bar pushes the Fmaj9 of bar 1 to the and of 4 — the
///    piano, the bass and a kick, tied over the seam — and bar 1 lets it ring instead of striking its downbeat: the
///    turnaround of the form, so the loop's seam is a push, not a jump.
///
/// The low-pass of lo-fi is in the timbres: a piano with little bell and a dark room, a pad and a bass closed low, a
/// pluck with a damped string, soft hats. The kick sits on eighths; the hats and the snare's ghost notes on the second
/// and fourth sixteenths, swung by 0.2 of a sixteenth.
private enum FocusTheme {
    static let tempo = 80.0
    static let beatsPerBar = 4
    static let bars = 40
    static let seed: UInt64 = 0x666F_6375_0000_0002
    static let swing = 0.2

    /// The pitch classes of C major, for the bass's approach notes.
    static let scale: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    /// A chord: the bass's root, in octave 2; the electric piano's voicing, without the root, near middle C; the pad's,
    /// root, fifth and third.
    struct Harmony {
        var root: Double
        var keys: [Double]
        var pad: [Double]
    }

    static let harmony: [String: Harmony] = [
        "Fmaj9": Harmony(root: 41, keys: [57, 60, 64, 67], pad: [53, 60, 69]),
        "Em7": Harmony(root: 40, keys: [55, 59, 62, 64], pad: [52, 59, 67]),
        "Dm9": Harmony(root: 38, keys: [53, 57, 60, 64], pad: [50, 57, 65]),
        "Cmaj9": Harmony(root: 36, keys: [52, 55, 59, 62], pad: [48, 55, 64]),
        "Am9": Harmony(root: 45, keys: [55, 59, 60, 64], pad: [45, 52, 60]),
        "G9": Harmony(root: 43, keys: [53, 57, 59, 62], pad: [43, 50, 59]),
    ]

    enum Drums { case full, light }
    /// The electric piano's hits in a bar.
    enum Comping { case two, three, held }

    struct Phrase {
        var chords: [String]
        var drums: Drums
        var comping: Comping
        /// Eight bars of eighths (see `eighths(_:)`), or none.
        var melody: String?
    }

    static let first = ["Fmaj9", "Em7", "Dm9", "Cmaj9", "Fmaj9", "Em7", "Dm9", "Cmaj9"]
    static let minor = ["Am9", "Fmaj9", "Cmaj9", "G9", "Am9", "Fmaj9", "Dm9", "G9"]
    static let minorToFirst = ["Am9", "Fmaj9", "Cmaj9", "G9", "Am9", "Fmaj9", "Dm9", "Em7"]

    static let phrases: [Phrase] = [
        Phrase(chords: first, drums: .full, comping: .two, melody: nil),
        Phrase(
            chords: first, drums: .full, comping: .two,
            melody: """
                . . A4 C5 E5 - - - | D5 - B4 - G4 - - - | . . F4 A4 C5 - E5 - | D5 - - - . . . . |
                . . A4 C5 E5 - G5 - | E5 D5 B4 - G4 - . . | . A4 C5 D5 E5 - D5 C5 | D5 - - - - - . .
                """),
        Phrase(
            chords: minor, drums: .full, comping: .three,
            melody: """
                E5 - - - D5 - C5 - | A4 - - - . . G4 A4 | B4 - - - G4 - - - | . . D5 - E5 - D5 - |
                E5 - - - G5 - E5 - | A5 - - - G5 - E5 - | F5 - E5 - D5 - C5 - | D5 - - - - - - -
                """),
        Phrase(
            chords: minorToFirst, drums: .light, comping: .held,
            melody: """
                . . . . E5 - D5 - | C5 - - - - - - - | . . . . G4 - A4 - | B4 - - - - - - - |
                . . . . E5 - G5 - | A5 - - - G5 - - - | . . F5 - E5 - D5 - | E5 - - - - - . .
                """),
        Phrase(
            chords: first, drums: .full, comping: .two,
            melody: """
                . . C5 E5 G5 - - - | B4 - - - G4 - E4 - | . . A4 C5 E5 - F5 - | E5 - D5 - . . . . |
                . . C5 E5 A5 - G5 - | E5 - D5 - B4 - . . | . . A4 C5 D5 - C5 - | G4 - - - . . . .
                """),
    ]

    static func score() -> MusicScore {
        precondition(phrases.count * 8 == bars)
        let chords = phrases.flatMap(\.chords)
        var kick: [ScoreNote] = [], snare: [ScoreNote] = [], hats: [ScoreNote] = []
        var bass: [ScoreNote] = [], keys: [ScoreNote] = [], pad: [ScoreNote] = [], melody: [ScoreNote] = []
        for (p, phrase) in phrases.enumerated() {
            let phraseBeat = Double(p * 8 * beatsPerBar)
            if let text = phrase.melody {
                melody += ScoreBuilder.melody(eighths(text), step: 0.5, from: phraseBeat, velocity: 0.6)
            }
            for b in 0..<8 {
                let bar = p * 8 + b
                let beat = Double(bar * beatsPerBar)
                guard let chord = harmony[chords[bar]], let next = harmony[chords[(bar + 1) % bars]] else {
                    preconditionFailure("FocusTheme: no chord \(chords[bar])")
                }
                // The turnaround: the last bar pushes the first chord, its bass and a kick to its and of 4, tied over
                // the seam, and the first bar does not strike its downbeat again.
                let pushes = bar == bars - 1, pushed = bar == 0
                let second = b % 2 == 1
                switch phrase.drums {
                case .full:
                    let steps = pushes ? "X---------x-x-x-" : pushed ? "------x---x-----" : second ? "X---------x-x---" : "X-----x---x-----"
                    kick += drums(steps, at: beat)
                    snare += drums(second && !pushes ? "----x-------x--g" : "----x-------x---", at: beat)
                    hats += drums(pushed ? "--ogo-ogo-ogo-og" : second ? "o-ogo-ogo-ogo-o-" : "o-ogo-ogo-ogo-og", at: beat)
                case .light:
                    if b == 7 { kick += drums("--------------o-", at: beat) }
                    snare += drums("----o-------o---", at: beat)
                    hats += drums(second ? "o-o-o-ogo-o-o-o-" : "o-o-o-ogo-o-o-og", at: beat)
                }
                let approach = approach(from: chord.root, to: next.root)
                let leading = pushes
                    ? ScoreNote(beat: beat + 3.5, beats: 1.75, pitch: next.root, velocity: 0.85)
                    : ScoreNote(beat: beat + 3.5, beats: 0.45, pitch: approach, velocity: phrase.drums == .full ? 0.6 : 0.55)
                switch phrase.drums {
                case .full:
                    if !pushed { bass.append(ScoreNote(beat: beat, beats: 1.25, pitch: chord.root, velocity: 0.85)) }
                    bass += [
                        ScoreNote(beat: beat + 1.5, beats: 0.4, pitch: chord.root, velocity: 0.6),
                        ScoreNote(beat: beat + 2.5, beats: 0.75, pitch: chord.root + 7, velocity: 0.7),
                        leading,
                    ]
                case .light:
                    bass += [ScoreNote(beat: beat, beats: 3.4, pitch: chord.root, velocity: 0.7), leading]
                }
                var hits: [(at: Double, beats: Double, velocity: Double)] = switch phrase.comping {
                case .two: [(0, 2.25, 0.55), (2.5, 1.25, 0.42)]
                case .three: [(0, 1.25, 0.55), (1.5, 0.9, 0.4), (2.5, 1.25, 0.45)]
                case .held: [(0, 3.75, 0.5)]
                }
                if pushed { hits.removeAll { $0.at == 0 } }
                if pushes { hits = hits.map { ($0.at, min($0.beats, 3.5 - $0.at), $0.velocity) } }
                for hit in hits {
                    keys += rolled(chord.keys, at: beat + hit.at, beats: hit.beats, velocity: hit.velocity)
                }
                if pushes { keys += rolled(next.keys, at: beat + 3.5, beats: 2.75, velocity: 0.55) }
                let padVelocity = phrase.drums == .light ? 0.65 : 0.5
                let padStart = pushed ? -0.5 : 0, padEnd = pushes ? 3.5 : Double(beatsPerBar)
                pad += chord.pad.map { ScoreNote(beat: beat + padStart, beats: padEnd - padStart, pitch: $0, velocity: padVelocity) }
            }
        }
        let vinyl = [ScoreNote(beat: 0, beats: Double(bars * beatsPerBar), pitch: 60, velocity: 1)]

        let keysPreset = EPianoPreset(
            ratio: 1, index: 0.9, indexDecay: 0.5, tine: 0.12, decay: 2.2, release: 0.3, tremoloDepth: 0.22,
            tremoloRate: 8.0 / 3, level: 1)
        let bassPreset = BassPreset(
            sine: 1, saw: 0.25, cutoff: 380, envelopeAmount: 1.5, filterDecay: 0.15, resonance: 0.15, attack: 0.006,
            decay: 0.9, sustain: 0.7, release: 0.1, drive: 0.25, level: 1)
        let padPreset = PadPreset(
            oscillators: 3, detune: 12, sub: 0, attack: 0.8, decay: 2, sustain: 0.8, release: 1.4, cutoff: 650,
            keyTracking: 0.3, resonance: 0.05, envelopeAmount: 0.4, sweepDepth: 0.35, sweepRate: 1.0 / 24, level: 1)
        let melodyPreset = PluckPreset(
            brightness: 0.45, damping: 0.55, decay: 2.2, pickPosition: 0.25, release: 0.15, spread: 0.3, level: 1)

        return MusicScore(
            id: "focus", tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: seed,
            parts: [
                ScorePart(instrument: .kick, notes: humanized(kick, 1, timing: 0, velocity: 0.06), gain: 0.8, reverbSend: 0),
                ScorePart(
                    instrument: .snare, notes: humanized(snare, 2, timing: 0.004, velocity: 0.1), gain: 1.4, pan: 0.05,
                    reverbSend: 0.15),
                ScorePart(
                    instrument: .hat(open: false), notes: humanized(hats, 3, timing: 0.004, velocity: 0.18), gain: 3,
                    pan: -0.2, reverbSend: 0.05),
                ScorePart(
                    instrument: .bass(bassPreset), notes: humanized(bass, 4, timing: 0.006, velocity: 0.08), gain: 0.85,
                    reverbSend: 0),
                ScorePart(
                    instrument: .electricPiano(keysPreset), notes: humanized(keys, 5, timing: 0.006, velocity: 0.1), gain: 0.72,
                    reverbSend: 0.25, chorus: .gentle),
                ScorePart(instrument: .pad(padPreset), notes: pad, gain: 0.26, reverbSend: 0.3),
                ScorePart(
                    instrument: .pluck(melodyPreset), notes: humanized(melody, 7, timing: 0.008, velocity: 0.12), gain: 2,
                    pan: 0.15, reverbSend: 0.3, delaySend: 0.25),
                ScorePart(instrument: .vinyl, notes: vinyl, gain: 1.2, reverbSend: 0),
            ],
            reverb: ReverbSettings(decay: 1.5, size: 0.7, damping: 3_200, preDelay: 0.02, lowCut: 250, width: 0.9, level: 1),
            delay: DelaySettings(beats: 0.75, feedback: 0.3, pingPong: true, lowCut: 400, highCut: 2_800, level: 1),
            masterGain: 0.535, isPlaceholder: false)
    }

    /// The electric piano's chord, rolled from the lowest, 9 ms a note.
    static func rolled(_ pitches: [Double], at beat: Double, beats: Double, velocity: Double) -> [ScoreNote] {
        pitches.enumerated().map { i, pitch in
            let roll = 0.012 * Double(i)
            return ScoreNote(beat: beat + roll, beats: beats - roll, pitch: pitch, velocity: velocity)
        }
    }

    /// One bar of a drum part in sixteenths, from `beat`, swung.
    static func drums(_ steps: String, at beat: Double) -> [ScoreNote] {
        ScoreBuilder.drums(DrumPattern(steps: steps, step: 0.25, bars: 1, beatsPerBar: beatsPerBar, from: beat), swing: swing)
    }

    /// `notes` humanized with a seed of their own.
    static func humanized(_ notes: [ScoreNote], _ part: UInt64, timing: Double, velocity: Double) -> [ScoreNote] {
        ScoreBuilder.humanized(notes, seed: SynthRandom.mix(seed, part), timing: timing, velocity: velocity)
    }

    /// `text`, bars of eight eighths apart by `|`, as `ScoreBuilder.melody` reads it; a bar that is not eight eighths
    /// stops the program (themes are code, and their tests build them).
    static func eighths(_ text: String) -> String {
        for bar in text.split(separator: "|") {
            let tokens = bar.split(whereSeparator: { $0 == " " || $0 == "\n" })
            precondition(tokens.count == 8, "FocusTheme: a bar of \(tokens.count) eighths: \(bar)")
        }
        return text
    }

    /// The note that leads the bass from `root` to `next`: the next root's neighbour in the key, from the side it comes
    /// from (its fifth, for the same root).
    static func approach(from root: Double, to next: Double) -> Double {
        guard next != root else { return root + 7 }
        let step = next > root ? -1.0 : 1.0
        var pitch = next + step
        while !scale.contains((Int(pitch) % 12 + 12) % 12) { pitch += step }
        return pitch
    }
}
