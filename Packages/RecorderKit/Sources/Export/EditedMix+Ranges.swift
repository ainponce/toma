// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The volume of each track over the ranges of its source the user set apart (phase 3 design §7.2 and §13, step 1:
/// `TrackGain.ranges`, with fades of 50 ms at their edges), as a gain for each output frame: `EditedMix` multiplies each
/// track's frames by it, after its own gain and the fades between clips, unless the plan `isEmpty`.
///
/// `keys` are `AudioPlan.key` of the tracks of each of the mix's sources (`keys[take][track]`), as `gain(take:track:…)`
/// names them. The base of phase 3 plans no range (base plan task B9): it is always empty, so the loop of the tracks
/// mixes what phase 2 mixed. Plan 3c (U5) fills it.
struct GainRangePlan: Sendable {
    /// Whether no range changes the volume of any track: every gain is 1.
    let isEmpty: Bool

    init(document: EditDocument, timeMap: TimeMap, keys: [[String]]) {
        isEmpty = true
    }

    /// The gain of track `track` of source `take` (`keys[take][track]`) at output frame `frame`: 1 out of its ranges.
    func gain(take: Int, track: Int, atOutputFrame frame: Int64) -> Float {
        1
    }
}
