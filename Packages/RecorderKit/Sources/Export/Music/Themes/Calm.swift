// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Calma (ambient): 64 BPM, 4/4, 32 bars, 2:00. A placeholder until it is composed: a pad holding Cmaj9.
    static func calm() -> MusicScore {
        placeholder(id: "calm", tempo: 64, beatsPerBar: 4, bars: 32, seed: 0x6361_6C6D_0000_0001, chord: Chord("Cmaj9", octave: 3))
    }
}
