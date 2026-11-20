// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Brisa (plucked strings): 96 BPM, 4/4, 48 bars, 2:00, in G major.
    ///
    /// A nylon guitar picks each bar's chord in eighths (the thumb on the bass strings, the fingers on the three highest,
    /// letting them ring), with a warm bass under it, a soft shaker in the middle phrases and a plucked melody over the
    /// third to fifth. Six phrases of 8 bars: the verse (G – D/F♯ – Em7 – Cadd9), the verse again turning to Am7 – G/B,
    /// two that start on Em7 and on Cadd9 and carry the melody, a lighter one that climbs Am7 – Bm7 – Cadd9 – D, and the
    /// verse once more, bare, ending Dsus4 – D into the G of the first.
    static func breeze() -> MusicScore {
        let seed: UInt64 = 0x6272_6565_0000_0001
        // The guitar's chords: its bass string, the other bass string the thumb alternates to, and its three highest.
        let shapes: [String: (bass: String, alternate: String, treble: [String])] = [
            "G": ("G2", "D3", ["G3", "B3", "G4"]),
            "D/F#": ("F#2", "D3", ["A3", "D4", "F#4"]),
            "Em7": ("E2", "B2", ["G3", "D4", "G4"]),
            "Cadd9": ("C3", "E3", ["G3", "D4", "G4"]),
            "D": ("D3", "A2", ["A3", "D4", "F#4"]),
            "Dsus4": ("D3", "A2", ["A3", "D4", "G4"]),
            "Am7": ("A2", "E3", ["G3", "C4", "E4"]),
            "G/B": ("B2", "D3", ["G3", "D4", "G4"]),
            "Bm7": ("B2", "F#3", ["A3", "D4", "F#4"]),
        ]
        // Each phrase: its chords (a bar each; two in a bar are half a bar each), the picking pattern, whether the shaker
        // plays, whether the bass plays on the first and third beats (or holds each chord), and the melody.
        let phrases: [(chords: [[String]], pattern: Int, shaker: Bool, halves: Bool, melody: String?)] = [
            ([["G"], ["D/F#"], ["Em7"], ["Cadd9"], ["G"], ["D/F#"], ["Cadd9"], ["Dsus4"]], 0, false, false, nil),
            ([["G"], ["D/F#"], ["Em7"], ["Cadd9"], ["Am7"], ["G/B"], ["Cadd9"], ["D"]], 0, true, true, nil),
            ([["Em7"], ["Cadd9"], ["G"], ["D"], ["Em7"], ["Cadd9"], ["G"], ["D"]], 0, true, true,
             "B4 - - G4 | E5 - D5 - | D5 - B4 - | A4 - - - | B4 - - G4 | E5 - G5 - | F#5 - D5 - | A4 - - -"),
            ([["Cadd9"], ["D"], ["Bm7"], ["Em7"], ["Cadd9"], ["D"], ["Em7"], ["D"]], 1, true, true,
             "G4 - E5 - | F#5 - D5 - | D5 - - B4 | B4 - - - | G4 - E5 - | F#5 - A5 - | G5 - E5 - | D5 - - -"),
            ([["Am7"], ["Bm7"], ["Cadd9"], ["D"], ["Am7"], ["Bm7"], ["Cadd9"], ["Dsus4"]], 1, true, true,
             ". . E5 - | . . F#5 - | . . G5 - | A5 - F#5 D5 | . . E5 - | . . D5 - | . . E5 - | D5 - - -"),
            ([["G"], ["D/F#"], ["Em7"], ["Cadd9"], ["Am7"], ["G/B"], ["Cadd9"], ["Dsus4", "D"]], 0, false, false, nil),
        ]
        // The picking patterns, in eighths: 0 the bass string, 1 the other bass string, 2…4 the three highest.
        let patterns = [[0, 2, 3, 4, 1, 2, 3, 2], [0, 3, 2, 4, 1, 3, 4, 2]]
        let bar = 4.0
        let phraseBeats = 8 * bar

        var guitar: [ScoreNote] = []
        var bass: [ScoreNote] = []
        var melody: [ScoreNote] = []
        var shaker: [ScoreNote] = []
        for (p, phrase) in phrases.enumerated() {
            let from = Double(p) * phraseBeats
            for (b, symbols) in phrase.chords.enumerated() {
                let start = from + Double(b) * bar
                let length = bar / Double(symbols.count)
                for (s, symbol) in symbols.enumerated() {
                    guard let shape = shapes[symbol] else { preconditionFailure("Breeze: no shape for \(symbol)") }
                    let strings = ([shape.bass, shape.alternate] + shape.treble).map(Pitch.midi)
                    let chordStart = start + Double(s) * length
                    let steps = Int(length / 0.5)
                    let order = patterns[phrase.pattern].prefix(steps)
                    // Each string rings until it is picked again or the chord changes, and a moment after.
                    func end(of string: Int, after k: Int) -> Double {
                        let again = order.enumerated().first { $0.offset > k && $0.element == string }
                        return again.map { chordStart + Double($0.offset) * 0.5 } ?? (chordStart + length + 0.25)
                    }
                    for (k, string) in order.enumerated() {
                        let beat = chordStart + Double(k) * 0.5
                        if p == 0, b == 0, k == 0 {
                            // The verse opens with its chord strummed, low to high, from a little before the downbeat:
                            // the loop's seam falls inside the strum, as the last bar leads into it.
                            let rolled = strings.indices.sorted { strings[$0] < strings[$1] }
                            for (r, s) in rolled.enumerated() {
                                let at = beat - 0.12 + Double(r) * 0.03
                                let velocity = r == 0 ? 0.45 : 0.36
                                guitar.append(
                                    ScoreNote(beat: at, beats: end(of: s, after: 0) - at, pitch: strings[s], velocity: velocity))
                            }
                            continue
                        }
                        let velocity = string == 0 ? 0.5 : (string == 1 ? 0.46 : (string == 4 ? 0.44 : 0.4))
                        guitar.append(ScoreNote(
                            beat: beat, beats: end(of: string, after: k) - beat, pitch: strings[string], velocity: velocity))
                    }
                    // The bass: the guitar's bass an octave down when that is not below A1, held through the chord, or on
                    // the first and third beats.
                    let root = strings[0] - 12 >= Pitch.midi("A1") ? strings[0] - 12 : strings[0]
                    if !phrase.halves || symbols.count > 1 {
                        bass.append(ScoreNote(beat: chordStart, beats: length, pitch: root, velocity: 0.62))
                    } else {
                        bass.append(ScoreNote(beat: chordStart, beats: 2, pitch: root, velocity: 0.62))
                        bass.append(ScoreNote(beat: chordStart + 2, beats: 2, pitch: root, velocity: 0.5))
                    }
                }
            }
            if let text = phrase.melody {
                melody += ScoreBuilder.melody(text, step: 1, from: from, velocity: 0.55)
            }
            if phrase.shaker {
                let pattern = DrumPattern(steps: "ogxg ogxg ogxg ogxg", step: 0.25, bars: 8, from: from)
                shaker += ScoreBuilder.drums(pattern, swing: 0.08)
            }
        }

        // The verse's first chord is pushed in the bass: it comes an eighth early, at the end of the loop, and is held
        // over the seam into the first bar.
        if let first = bass.firstIndex(where: { $0.beat == 0 }) {
            let pushed = bass.remove(at: first)
            bass[bass.count - 1].beats -= 0.5
            let loopEnd = phraseBeats * Double(phrases.count)
            bass.append(ScoreNote(beat: loopEnd - 0.5, beats: pushed.beats + 0.5, pitch: pushed.pitch, velocity: pushed.velocity))
        }

        let nylon = PluckPreset(brightness: 0, damping: 0.95, decay: 2.8, pickPosition: 0.22, release: 0.15, spread: 0.5)
        let lead = PluckPreset(brightness: 0.1, damping: 0.85, decay: 2.4, pickPosition: 0.3, release: 0.2, spread: 0.15)
        let warm = BassPreset(
            sine: 1, saw: 0.2, cutoff: 380, envelopeAmount: 0.8, filterDecay: 0.25, resonance: 0.1, attack: 0.012, decay: 0.8,
            sustain: 0.85, release: 0.12, drive: 0.15)
        let parts = [
            ScorePart(
                instrument: .pluck(nylon),
                notes: ScoreBuilder.humanized(guitar, seed: SynthRandom.mix(seed, 1), timing: 0.012, velocity: 0.1),
                gain: 1.8, pan: -0.1, reverbSend: 0.25),
            ScorePart(
                instrument: .bass(warm),
                notes: ScoreBuilder.humanized(bass, seed: SynthRandom.mix(seed, 2), timing: 0.005, velocity: 0.05),
                gain: 0.4, pan: 0, reverbSend: 0.02),
            ScorePart(
                instrument: .pluck(lead),
                notes: ScoreBuilder.humanized(melody, seed: SynthRandom.mix(seed, 3), timing: 0.01, velocity: 0.08),
                gain: 2.0, pan: 0.25, reverbSend: 0.35, delaySend: 0.25),
            ScorePart(
                instrument: .shaker,
                notes: ScoreBuilder.humanized(shaker, seed: SynthRandom.mix(seed, 4), timing: 0.008, velocity: 0.15),
                gain: 1.0, pan: 0.3, reverbSend: 0.15),
        ]
        return MusicScore(
            id: "breeze", tempo: 96, beatsPerBar: 4, bars: 48, seed: seed, parts: parts,
            reverb: ReverbSettings(decay: 1.6, size: 0.9, damping: 6_000, preDelay: 0.015, lowCut: 220, width: 1, level: 1),
            delay: DelaySettings(beats: 0.75, feedback: 0.25, pingPong: true, lowCut: 400, highCut: 4_000, level: 0.7),
            masterGain: 1.024, isPlaceholder: false)
    }
}
