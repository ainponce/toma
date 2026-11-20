// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the sound of each clip of a sequence starts in the mix, in output frames at 48 kHz, and how far from the
/// clip's own start its source is read there (phase 3 design §7.3 and §13, step 1: the cut of the sound moved, a J or an
/// L cut): `EditedMix` plays clip `k` from output frame `starts[k]` to `starts[k + 1]` (the last one to the end of the
/// content), from the frame of its take at its start moved by `sourceShift[k]`.
///
/// The base of phase 3 moves no cut (base plan task B9): `starts` are the clips' own starts (`TimeMap.clipOutputStarts`,
/// `EditedMix.frames(ofNanoseconds:)`) and every `sourceShift` is 0, so the mix plays what phase 2 played. Plan 3c (U5)
/// reads `Clip.audioShift` here, held to what the take has and to half of each clip next to it.
struct AudioCuts: Sendable {
    /// The output frame where the sound of each clip starts, in the order of the sequence.
    let starts: [Int64]
    /// How many frames of its take's timeline before (negative) or after its start the sound of each clip is read from
    /// where it starts, in the order of the sequence.
    let sourceShift: [Int64]

    init(document: EditDocument, timeMap: TimeMap) {
        starts = timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:))
        sourceShift = Array(repeating: 0, count: starts.count)
    }
}
