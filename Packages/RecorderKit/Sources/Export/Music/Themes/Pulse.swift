// SPDX-License-Identifier: GPL-3.0-or-later

extension MusicThemes {
    /// Pulso (electronic): 128 BPM, 4/4, 64 bars, 2:00. A placeholder until it is composed: a pad holding Dm9.
    static func pulse() -> MusicScore {
        placeholder(id: "pulse", tempo: 128, beatsPerBar: 4, bars: 64, seed: 0x7075_6C73_0000_0001, chord: Chord("Dm9", octave: 3))
    }
}
