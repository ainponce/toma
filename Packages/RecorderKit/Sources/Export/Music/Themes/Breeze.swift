// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Brisa (plucked strings): 96 BPM, 4/4, 48 bars, 2:00. A placeholder until it is composed: a pad holding Esus2.
    static func breeze() -> MusicScore {
        placeholder(id: "breeze", tempo: 96, beatsPerBar: 4, bars: 48, seed: 0x6272_6565_0000_0001, chord: Chord("Esus2", octave: 3))
    }
}
