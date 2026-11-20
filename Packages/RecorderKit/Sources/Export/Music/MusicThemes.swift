// SPDX-License-Identifier: GPL-3.0-or-later

/// The music library (design §7.6): six themes of `music-1`, made by code, two minutes each, stereo at 48 kHz, that
/// repeat without a seam. A theme is a `MusicScore` in `Themes/`, rendered by `MusicSynth` and kept by `MusicLibrary`
/// (`ProjectJobs`) in the app's cache. A document names one by its source, `library:music-1/<id>`.
///
/// The music is dedicated to the public domain with CC0 1.0 (`docs/music.md`).
public enum MusicThemes {
    /// The id of the algorithm, with its version. It changes when anything a theme sounds like changes (after the merge
    /// of phase 3 into `main`): a document's `library:music-1/calm` always sounds the same.
    public static let algorithm = "music-1"
    /// Calma (ambient), Foco (lo-fi), Impulso (happy pop), Piano (minimal piano), Pulso (electronic) and Brisa (plucked
    /// strings), in the order the list shows them (plan decision 2).
    public static let ids = ["calm", "focus", "drive", "piano", "pulse", "breeze"]
    /// Every theme lasts exactly this: 120 s at 48 kHz.
    public static let loopFrames = 5_760_000

    /// The score of theme `id`; `nil` for an id that is not one of `ids`.
    public static func score(_ id: String) -> MusicScore? {
        switch id {
        case "calm": calm()
        case "focus": focus()
        case "drive": drive()
        case "piano": piano()
        case "pulse": pulse()
        case "breeze": breeze()
        default: nil
        }
    }

    /// The source a document names theme `id` by: `library:music-1/<id>`.
    public static func source(_ id: String) -> String {
        "library:\(algorithm)/\(id)"
    }

    /// The theme a source names, if it is `library:music-1/<id>` with `id` one of `ids`; `nil` for anything else (a
    /// file, another version of the library, an id that is not a theme).
    public static func id(ofSource source: String) -> String? {
        let prefix = "library:\(algorithm)/"
        guard source.hasPrefix(prefix) else { return nil }
        let id = String(source.dropFirst(prefix.count))
        return ids.contains(id) ? id : nil
    }

    /// A stand-in for a theme not composed yet: `chord` held by a warm pad over the whole loop, in a hall. Each theme of
    /// `Themes/` uses it until its task composes it (milestone 3c, U2 and U3).
    static func placeholder(id: String, tempo: Double, beatsPerBar: Int, bars: Int, seed: UInt64, chord: Chord) -> MusicScore {
        let beats = Double(bars * beatsPerBar)
        let notes = chord.pitches.map { ScoreNote(beat: 0, beats: beats, pitch: $0, velocity: 0.7) }
        return MusicScore(
            id: id, tempo: tempo, beatsPerBar: beatsPerBar, bars: bars, seed: seed,
            parts: [ScorePart(instrument: .pad(.warm), notes: notes, gain: 1, pan: 0, reverbSend: 0.35)],
            reverb: .hall, delay: nil, masterGain: placeholderGain, isPlaceholder: true)
    }

    /// Brings a placeholder near −16 LUFS.
    static let placeholderGain = 0.33
}
