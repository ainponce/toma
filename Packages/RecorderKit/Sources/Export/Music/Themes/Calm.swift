// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Calma (ambient): 64 BPM, 4/4, 32 bars, 2:00, in D lydian (D major with its raised fourth, G♯).
    ///
    /// Wide pads that change every 2 bars over a soft sine bass, a bell motif at the start of every 8 bars, in a long
    /// reverb. Four phrases of 8 bars, an arc: the first states the harmony (D – E/D – Bm – A), the second moves away
    /// (F♯m – E – D – C♯m) and brings a high pad, the third goes deepest (the bass walks down from B to F♯) with a slow harp,
    /// and the fourth thins out again and ends on A, which leads back to the D of the first.
    static func calm() -> MusicScore {
        let seed: UInt64 = 0x6361_6C6D_0000_0001
        // Each chord: its bass and its upper voices, voiced so that the voices move as little as they can.
        let chords: [(bass: String, upper: [String])] = [
            // 1: the harmony and its lydian II.
            ("D2", ["F#3", "A3", "C#4", "E4"]), // Dmaj9
            ("D2", ["G#3", "B3", "E4", "F#4"]), // E/D
            ("B1", ["F#3", "A3", "C#4", "D4"]), // Bm9
            ("A1", ["F#3", "B3", "C#4", "E4"]), // A6/9
            // 2: away.
            ("F#2", ["F#3", "A3", "C#4", "E4"]), // F♯m7
            ("E2", ["G#3", "B3", "C#4", "E4"]), // E6
            ("D2", ["F#3", "A3", "C#4", "G#4"]), // Dmaj7♯11
            ("C#2", ["G#3", "B3", "C#4", "E4"]), // C♯m7
            // 3: the bass walks down.
            ("B1", ["F#3", "A3", "C#4", "D4"]), // Bm9
            ("A1", ["G#3", "B3", "C#4", "E4"]), // Amaj9
            ("G#1", ["G#3", "B3", "E4", "F#4"]), // E/G♯
            ("F#1", ["A3", "B3", "C#4", "E4"]), // F♯m11
            // 4: home again, and A to lead back to D.
            ("E2", ["G#3", "B3", "E4", "F#4"]), // Eadd9
            ("D2", ["F#3", "A3", "C#4", "E4"]), // Dmaj9
            ("B1", ["A3", "D4", "E4", "F#4"]), // Bm11
            ("A1", ["A3", "B3", "C#4", "E4"]), // Aadd9
        ]
        let span = 8.0 // beats: two bars
        let phrase = 32.0

        var pad: [ScoreNote] = []
        var bass: [ScoreNote] = []
        var air: [ScoreNote] = []
        var harp: [ScoreNote] = []
        for (c, chord) in chords.enumerated() {
            let beat = Double(c) * span
            let upper = chord.upper.map(Pitch.midi)
            // Held a little into the next chord, so one fades in while the other is still there.
            for pitch in upper {
                pad.append(ScoreNote(beat: beat, beats: span + 1, pitch: pitch, velocity: 0.55))
            }
            bass.append(ScoreNote(beat: beat, beats: span + 0.5, pitch: Pitch.midi(chord.bass), velocity: 0.7))
            let section = c / 4
            // The high pad of the second and third phrases: the two upper voices an octave up.
            if section == 1 || section == 2 {
                for pitch in upper.suffix(2) {
                    let velocity = section == 1 ? 0.4 : 0.5
                    air.append(ScoreNote(beat: beat, beats: span + 1, pitch: pitch + 12, velocity: velocity))
                }
            }
            // The slow harp of the third phrase: the chord's voices an octave up, one a beat, rising and turning.
            if section == 2 {
                let order = [0, 1, 2, 3, 2, 3, 1, 2]
                for (k, index) in order.enumerated() {
                    let velocity = k == 0 ? 0.55 : 0.45
                    harp.append(ScoreNote(beat: beat + Double(k), beats: 3, pitch: upper[index] + 12, velocity: velocity))
                }
            }
        }

        // The bell: one motif at the start of each phrase, after its downbeat; the last phrase answers it at its end.
        var bell: [ScoreNote] = []
        let motifs: [(beat: Double, text: String)] = [
            (1, "E5 - F#5 - A5 - - - - - G#5 - - - - -"),
            (phrase + 1, "C#5 - E5 - F#5 - - - - - E5 - - - - -"),
            (2 * phrase + 1, "D5 - F#5 - A5 - - - C#6 - - - B5 - - - - -"),
            (3 * phrase + 1, "B4 - E5 - F#5 - - - - - E5 - - - - -"),
            (3 * phrase + 25, "C#5 - - - E5 - - - - -"),
        ]
        for motif in motifs {
            bell += ScoreBuilder.melody(motif.text, step: 0.5, from: motif.beat, velocity: 0.6)
        }

        let padPreset = PadPreset(
            oscillators: 5, detune: 16, sub: 0, attack: 2.4, decay: 3, sustain: 0.85, release: 2, cutoff: 1_300,
            keyTracking: 0.35, resonance: 0.08, envelopeAmount: 0.35, sweepDepth: 0.5, sweepRate: 1.0 / 30)
        let airPreset = PadPreset(
            oscillators: 6, detune: 22, sub: 0, attack: 3, decay: 3, sustain: 0.9, release: 2, cutoff: 2_200,
            keyTracking: 0.2, resonance: 0.1, envelopeAmount: 0.2, sweepDepth: 0.8, sweepRate: 1.0 / 60)
        let bassPreset = BassPreset(
            sine: 1, saw: 0.12, cutoff: 260, envelopeAmount: 0.3, filterDecay: 1, resonance: 0.05, attack: 1.2, decay: 2,
            sustain: 1, release: 2, drive: 0.05)
        let bellPreset = EPianoPreset(
            ratio: 3.5, index: 1.3, indexDecay: 1.2, tine: 0.1, decay: 3, release: 1.5, tremoloDepth: 0.12, tremoloRate: 0.5)
        let harpPreset = PluckPreset(
            brightness: 0.15, damping: 0.8, decay: 3.5, pickPosition: 0.25, release: 0.5, spread: 0.6)

        let parts = [
            ScorePart(instrument: .pad(padPreset), notes: pad, gain: 0.5, pan: 0, reverbSend: 0.45, chorus: .lush),
            ScorePart(instrument: .bass(bassPreset), notes: bass, gain: 0.4, pan: 0, reverbSend: 0.05),
            ScorePart(instrument: .pad(airPreset), notes: air, gain: 0.25, pan: 0, reverbSend: 0.6, chorus: .gentle),
            ScorePart(
                instrument: .electricPiano(bellPreset),
                notes: ScoreBuilder.humanized(bell, seed: SynthRandom.mix(seed, 3), timing: 0.01, velocity: 0.08),
                gain: 0.55, pan: 0.2, reverbSend: 0.6, delaySend: 0.35),
            ScorePart(
                instrument: .pluck(harpPreset),
                notes: ScoreBuilder.humanized(harp, seed: SynthRandom.mix(seed, 4), timing: 0.015, velocity: 0.1),
                gain: 1.2, pan: -0.2, reverbSend: 0.6, delaySend: 0.15),
        ]
        return MusicScore(
            id: "calm", tempo: 64, beatsPerBar: 4, bars: 32, seed: seed, parts: parts,
            reverb: ReverbSettings(decay: 3, size: 1.8, damping: 4_000, preDelay: 0.04, lowCut: 180, width: 1, level: 1),
            delay: DelaySettings(beats: 1.5, feedback: 0.35, pingPong: true, lowCut: 400, highCut: 3_500, level: 0.8),
            masterGain: 0.573, isPlaceholder: false)
    }
}
