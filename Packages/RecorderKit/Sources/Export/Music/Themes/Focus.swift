// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Foco (lo-fi): 80 BPM, 4/4, 40 bars, 2:00. A placeholder until it is composed: a pad holding Am7.
    static func focus() -> MusicScore {
        placeholder(id: "focus", tempo: 80, beatsPerBar: 4, bars: 40, seed: 0x666F_6375_0000_0001, chord: Chord("Am7", octave: 3))
    }
}
