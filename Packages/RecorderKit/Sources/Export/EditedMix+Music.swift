// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The music under the video (phase 3 design §7.4 to §7.6 and §13, step 3: `EditDocument.music`), with its fades and its
/// loops, lowered while someone speaks by the envelope of the ducking (`ducking-1`, `DuckingEnvelope`), each piece read
/// from the file `analysis.musicFiles` has for its source. Anchored to the output: the cuts never move it. `EditedMix`
/// adds it after the tracks, the clicks and the imported clips, before the limiter.
///
/// The base of phase 3 plays none (base plan task B9): `make` gives `none`, which has no sound, so the mix is phase 2's.
/// Plan 3c (U7) fills it.
struct MusicMix: Sendable {
    /// No music to hear.
    static let none = MusicMix()

    private init() {}

    /// The music of `document` of `project` at the output frames `timeMap` gives, with `channels` channels (the mix's),
    /// its files and the voice that ducks it read from `analysis`: opens the files, off the main thread.
    static func make(
        project: LoadedProject, document: EditDocument, timeMap: TimeMap, analysis: AnalysisInputs, channels: Int
    ) async -> MusicMix {
        .none
    }

    /// Whether any piece of music sounds: without, `add` adds nothing.
    var hasSound: Bool { false }

    /// Adds the music over output frames `frames` into `samples`, which holds those frames, interleaved with `channels`
    /// channels, from `frames.lowerBound`. The mix keeps only what falls within its content. Called with
    /// `EditedMix.render`'s lock held.
    func add(_ frames: Range<Int64>, into samples: inout [Float], channels: Int) {}
}
