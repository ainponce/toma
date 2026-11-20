// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat

/// The volume line of an audio row, as a height (phase 3 plan 3c, decision 13): +12 dB at the top, −48 dB at 8 % of the
/// row's height above its bottom edge, and −∞ below that. Every gain here is in dB, `GainRange.silence` (−120) for −∞.
public enum AudioRowGeometry {
    public static let topGain = 12.0
    public static let floorGain = -48.0
    /// How far above the bottom edge the floor is drawn, as a fraction of the row's height.
    public static let floorFraction = 0.08
    /// The line sticks to 0 dB within this many dB.
    public static let snap = 0.75

    /// Where the line of `dB` is drawn in a row `height` tall, from its top edge down: 0 at +12 dB (more is held there),
    /// `height × (1 − floorFraction)` at −48 dB, and the bottom edge for −∞ and for anything under the floor. A value that
    /// is not a number is 0 dB.
    public static func y(ofGain dB: Double, height: Double) -> Double {
        guard height > 0 else { return 0 }
        let gain = dB.isNaN ? 0 : min(dB, topGain)
        guard gain >= floorGain else { return height }
        let floorY = height * (1 - floorFraction)
        return (topGain - gain) / (topGain - floorGain) * floorY
    }

    /// The gain at height `y` of a row `height` tall, the inverse of `y(ofGain:height:)`: from +12 at the top (and above
    /// it) to −48 at the floor, and −∞ (`GainRange.silence`) below the floor; within `snap` of 0 dB it is 0.
    public static func gain(atY y: Double, height: Double) -> Double {
        guard height > 0, !y.isNaN else { return 0 }
        let floorY = height * (1 - floorFraction)
        if y > floorY { return GainRange.silence }
        let gain = topGain - max(y, 0) / floorY * (topGain - floorGain)
        return abs(gain) <= snap ? 0 : gain
    }

    /// A track's gain (0 to 2) in dB: 0 is −∞, and a value that is not a number is 0 dB (the gain of 1).
    public static func decibels(ofTrackGain gain: Double) -> Double {
        guard !gain.isNaN else { return 0 }
        guard gain > 0 else { return GainRange.silence }
        return max(20 * log10(min(gain, 2)), GainRange.silence)
    }

    /// The track's gain (0 to 2) of `dB`: −∞ (−120 or less) is 0, and +6.02 dB or more is 2.
    public static func trackGain(ofDecibels dB: Double) -> Double {
        guard !dB.isNaN else { return 1 }
        guard dB > GainRange.silence else { return 0 }
        return min(pow(10, dB / 20), 2)
    }
}

/// What is under the pointer in an audio row.
public enum AudioRowHit: Equatable, Sendable {
    /// With ⌥: the cut of the sound at the start of clip `clip` (a J or L cut).
    case audioCut(clip: Int)
    /// An edge of a stretch at another volume.
    case rangeEdge(id: String, edge: ClipEdge)
    /// The volume line of a stretch.
    case rangeLine(id: String)
    /// The volume line of the whole row, outside the stretches.
    case rowLine
    case empty
}

/// What an audio row of the timeline does where it is pointed at (plan 3c, decisions 13 and 14).
public enum AudioRowRules {
    /// How far from a line or an edge, in points, it is still pointed at.
    public static let grab = 4.0

    /// The edges of `doc`'s sequence where the sound can be cut J or L: those whose `audioShift` has a range other than
    /// 0 (`SequenceRules.audioShiftRange`: never the first clip, a clip with content or the one after it), with the
    /// output time of the picture's cut and of the sound's, in order.
    public static func cuts(_ doc: EditDocument, timeMap: TimeMap) -> [(clip: Int, picture: Int64, audio: Int64)] {
        var found: [(clip: Int, picture: Int64, audio: Int64)] = []
        let sequence = doc.sequence
        guard sequence.count > 1, timeMap.clipOutputStarts.count == sequence.count, timeMap.audioStarts.count == sequence.count
        else { return found }
        for k in 1..<sequence.count {
            let range = SequenceRules.audioShiftRange(of: sequence, at: k)
            guard range.lowerBound < range.upperBound else { continue }
            found.append((k, timeMap.clipOutputStarts[k], timeMap.audioStarts[k]))
        }
        return found
    }

    /// What is at (`x`, `y`) of a row `height` tall; `x` and the `x`s of `ranges` and `cuts` are in the same points, and
    /// every gain is in dB (`AudioRowGeometry.decibels(ofTrackGain:)` for the row's own).
    ///
    /// With `option` (⌥), a cut within `grab` of `x` is the cut of the sound (the nearest one). Otherwise: the edge of a
    /// stretch within `grab` (the nearest), then the volume line of the stretch `x` is in, then the row's volume line
    /// (outside the stretches), and nothing else.
    public static func hit(
        x: Double, y: Double, option: Bool, height: Double, ranges: [(id: String, x: ClosedRange<Double>, gain: Double)],
        cuts: [(clip: Int, x: Double)], rowGain: Double
    ) -> AudioRowHit {
        if option, let cut = cuts.filter({ abs($0.x - x) <= grab }).min(by: { abs($0.x - x) < abs($1.x - x) }) {
            return .audioCut(clip: cut.clip)
        }
        var edge: (id: String, edge: ClipEdge, distance: Double)?
        for range in ranges {
            for (side, at) in [(ClipEdge.start, range.x.lowerBound), (.end, range.x.upperBound)] {
                let distance = abs(at - x)
                if distance <= grab, distance < (edge?.distance ?? .infinity) { edge = (range.id, side, distance) }
            }
        }
        if let edge { return .rangeEdge(id: edge.id, edge: edge.edge) }
        for range in ranges where range.x.contains(x) {
            if abs(AudioRowGeometry.y(ofGain: range.gain, height: height) - y) <= grab { return .rangeLine(id: range.id) }
        }
        let inRange = ranges.contains { $0.x.contains(x) }
        if !inRange, abs(AudioRowGeometry.y(ofGain: rowGain, height: height) - y) <= grab { return .rowLine }
        return .empty
    }
}
