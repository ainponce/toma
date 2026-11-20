// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Piano (minimal piano): 72 BPM, 3/4, 48 bars, 2:00. A placeholder until it is composed: a pad holding Fmaj7.
    static func piano() -> MusicScore {
        placeholder(id: "piano", tempo: 72, beatsPerBar: 3, bars: 48, seed: 0x7069_616E_0000_0001, chord: Chord("Fmaj7", octave: 3))
    }
}
