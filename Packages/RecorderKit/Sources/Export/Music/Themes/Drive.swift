// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Impulso (happy pop): 112 BPM, 4/4, 56 bars, 2:00. A placeholder until it is composed: a pad holding Gadd9.
    static func drive() -> MusicScore {
        placeholder(id: "drive", tempo: 112, beatsPerBar: 4, bars: 56, seed: 0x6472_6976_0000_0001, chord: Chord("Gadd9", octave: 3))
    }
}
