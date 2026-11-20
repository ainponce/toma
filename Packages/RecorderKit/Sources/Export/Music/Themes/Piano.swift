// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Piano (minimal piano): 72 BPM, 3/4, 48 bars, 2:00, in A minor and its relative C major, a felt piano alone.
    ///
    /// The left hand breaks each bar's chord in eighths (root, fifth, octave, tenth and back), held by the pedal to the
    /// bar line; the right hand sings a simple melody in phrases of 8 bars. Six phrases: the theme (Am – F – C – G), the
    /// theme again ending on Em, two in C major, the theme an octave fuller, and a quiet close (Fmaj7 – C/E – Dm7 – G)
    /// whose last bar climbs B – C – D into the E that opens the theme.
    static func piano() -> MusicScore {
        let seed: UInt64 = 0x7069_616E_0000_0001
        // The left hand of each chord: the four pitches it breaks, from the lowest.
        let hands: [String: [String]] = [
            "Am": ["A2", "E3", "A3", "C4"], "F": ["F2", "C3", "F3", "A3"], "Fmaj7": ["F2", "C3", "E3", "A3"],
            "C": ["C3", "G3", "C4", "E4"], "C/E": ["E2", "C3", "G3", "C4"], "G": ["G2", "D3", "G3", "B3"],
            "Dm": ["D2", "A2", "D3", "F3"], "Dm7": ["D2", "A2", "C3", "F3"], "Em": ["E2", "B2", "E3", "G3"],
        ]
        // Six phrases of 8 bars: the chord of each bar, the melody in quarters (as `ScoreBuilder.melody`), how hard it
        // is played, and whether an octave below doubles it.
        let phrases: [(chords: [String], melody: String, velocity: Double, doubled: Bool)] = [
            (["Am", "F", "C", "G", "Am", "F", "C", "G"],
             "E5 - - | C5 - D5 | E5 - G5 | D5 - - | E5 - - | C5 - A4 | G4 - C5 | B4 - -", 0.52, false),
            (["Am", "F", "C", "G", "Am", "F", "Dm7", "Em"],
             "E5 - - | C5 - D5 | E5 - G5 | A5 - G5 | E5 - - | F5 E5 D5 | D5 - C5 | B4 - -", 0.56, false),
            (["F", "G", "Em", "Am", "Dm", "G", "C", "C"],
             "A4 - C5 | B4 - D5 | B4 - G4 | C5 - E5 | F5 - E5 | D5 - B4 | C5 - - | - - .", 0.55, false),
            (["F", "G", "Em", "Am", "Dm", "Em", "F", "G"],
             "A4 - C5 | D5 - - | G5 - E5 | E5 - - | F5 - A5 | G5 - E5 | C5 - D5 | B4 - -", 0.6, false),
            (["Am", "F", "C", "G", "Am", "F", "C", "Em"],
             "E5 - - | C5 - D5 | E5 - G5 | D5 - - | C5 - E5 | A5 - G5 | E5 - D5 | E5 - -", 0.6, true),
            (["Fmaj7", "C/E", "Dm7", "Am", "Fmaj7", "C/E", "Dm7", "G"],
             "C5 - - | . . . | F5 - E5 | C5 - - | A4 - - | G4 - - | F4 - A4 | B4 C5 D5", 0.48, false),
        ]
        let bar = 3.0
        let phraseBeats = 8 * bar
        // The left hand's patterns over the four pitches: 1 5 8 10 8 5 in eighths, and in the close only 1 8 10 in
        // quarters, as it calms down, until its last bar takes up the eighths again into the theme.
        let flowing = (order: [0, 1, 2, 3, 2, 1], step: 0.5)
        let calming = (order: [0, 2, 3], step: 1.0)

        var left: [ScoreNote] = []
        var right: [ScoreNote] = []
        for (p, phrase) in phrases.enumerated() {
            let from = Double(p) * phraseBeats
            for (b, symbol) in phrase.chords.enumerated() {
                guard let names = hands[symbol] else { preconditionFailure("Piano: no left hand for \(symbol)") }
                let pitches = names.map(Pitch.midi)
                let start = from + Double(b) * bar
                let pattern = p == phrases.count - 1 && b < phrase.chords.count - 1 ? calming : flowing
                for (k, index) in pattern.order.enumerated() {
                    let beat = start + Double(k) * pattern.step
                    // The pedal holds every note to the bar line, and a moment after it.
                    let velocity = k == 0 ? 0.5 : (index == 3 ? 0.42 : 0.38)
                    left.append(
                        ScoreNote(beat: beat, beats: start + bar + 0.15 - beat, pitch: pitches[index], velocity: velocity))
                }
            }
            let melody = ScoreBuilder.melody(phrase.melody, step: 1, from: from, velocity: phrase.velocity)
            right += melody
            if phrase.doubled {
                right += ScoreBuilder.transposed(melody, by: -12).map { note in
                    var note = note
                    note.velocity *= 0.6
                    return note
                }
            }
        }

        let preset = PianoPreset(
            partials: 10, inharmonicity: 0.0003, brightness: 0.6, decay: 3, damping: 1.1, strings: 2, detune: 0.9,
            hammer: 0.2, release: 0.35, width: 0.45)
        let parts = [
            ScorePart(
                instrument: .piano(preset),
                notes: ScoreBuilder.humanized(left, seed: SynthRandom.mix(seed, 1), timing: 0.012, velocity: 0.08),
                gain: 0.65, pan: -0.05, reverbSend: 0.3),
            ScorePart(
                instrument: .piano(preset),
                notes: ScoreBuilder.humanized(right, seed: SynthRandom.mix(seed, 2), timing: 0.015, velocity: 0.06),
                gain: 1.05, pan: 0.05, reverbSend: 0.3),
        ]
        return MusicScore(
            id: "piano", tempo: 72, beatsPerBar: 3, bars: 48, seed: seed, parts: parts,
            reverb: ReverbSettings(decay: 2.4, size: 1.2, damping: 5_000, preDelay: 0.025, lowCut: 200, width: 1, level: 1),
            delay: nil, masterGain: 1.033, isPlaceholder: false)
    }
}
