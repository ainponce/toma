// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The volume of each track over the ranges of its source the user set apart (phase 3 design §7.2 and §13, step 1:
/// `TrackGain.ranges`; plan 3c decision 9), as a gain for each output frame: `EditedMix` multiplies each track's frames by
/// it, after its own gain and the fades between clips, unless the plan `isEmpty`.
///
/// - `keys` are `AudioPlan.key` of the tracks of each of the mix's sources (`keys[take][track]`), as `gain(take:track:…)`
///   names them. A track hears the ranges of its own key only (`audio.tracks["<take>/<track>"].ranges`, never those of
///   the key its gain may be found by in another take), each in the source of its `take`: in the clips of that take, it
///   is heard where their sound plays the source it covers (`AudioCuts`, with the J and L cuts), so a range follows the
///   sound through the cuts, the speeds and the cuts of the sound moved, and the picture never.
/// - A range of `g` dB is the amplitude `10^(g / 20)`, held to +12 dB, and silence at `GainRange.silence` (−∞) or below,
///   reached linearly in amplitude over `fadeNanoseconds` of source inside each of its edges, from 1 at the edge: in a
///   range shorter than twice that the two ramps meet in its middle. Two that overlap (a document edited by hand)
///   multiply; one whose gain is not a number, or that is empty, does not count, and one at 0 dB changes nothing.
/// - The gain at an output frame is that of the source instant its clip is heard at there
///   (`AudioCuts.sourceNanoseconds(ofClip:atOutputFrame:)`), 1 outside every range. It is planned once, as spans of
///   output frames of each (take, track, clip) where the same ranges are heard, found by binary search: a range over the
///   whole of a take (`0 ..< UInt64.max`, the solo's) is flat over all of it without overflowing.
/// - Without ranges (the documents of phases 1 and 2), the plan `isEmpty` and the loop of the tracks mixes what phase 2
///   mixed.
struct GainRangePlan: Sendable {
    /// The ramps at the edges of a range: 50 ms of source.
    static let fadeNanoseconds: Int64 = 50_000_000

    /// Whether no range changes the volume of any track: every gain is 1.
    let isEmpty: Bool

    /// Where the sound of each clip plays and the source it is heard at.
    private let cuts: AudioCuts
    /// The spans of each track of each source (`keys[take][track]`), in the order of their frames, which never overlap.
    private let spans: [[[Span]]]

    /// One range as the mix hears it: over the source `[start, end)` of its take (host ns), `amplitude` (0 to 4) once
    /// past its ramps.
    private struct Ramp: Sendable {
        var start: Double
        var end: Double
        var amplitude: Double

        /// The gain at source instant `x` (host ns): 1 out of the range and at its edges, `amplitude` once
        /// `fadeNanoseconds` inside both, linearly in between.
        func gain(at x: Double) -> Double {
            let inside = min(x - start, end - x)
            guard inside > 0 else { return 1 }
            let reached = min(inside / Double(GainRangePlan.fadeNanoseconds), 1)
            return (1 - reached) + amplitude * reached
        }
    }

    /// Output frames of one clip's sound where the same ranges are heard.
    private struct Span: Sendable {
        var frames: Range<Int64>
        var clip: Int
        var ramps: [Ramp]
    }

    init(document: EditDocument, timeMap: TimeMap, keys: [[String]], cuts: AudioCuts? = nil) {
        let cuts = cuts ?? AudioCuts(document: document, timeMap: timeMap)
        self.cuts = cuts
        let sequence = document.sequence
        // The clips with a sound of their own that plays any frame.
        let heard = sequence.indices.filter { sequence[$0].content == nil && !cuts.window(ofClip: $0).isEmpty }
        var ramps: [String: [(take: String, ramp: Ramp)]] = [:]
        for key in Set(keys.joined()) {
            ramps[key] = (document.audio.tracks[key]?.ranges ?? []).compactMap { range in
                guard let ramp = Self.ramp(of: range) else { return nil }
                return (range.take, ramp)
            }
        }
        spans = keys.map { trackKeys in
            trackKeys.map { key in
                let own = ramps[key] ?? []
                guard !own.isEmpty else { return [] }
                return heard.flatMap { k in
                    Self.spans(of: own.filter { $0.take == sequence[k].take }.map(\.ramp), clip: k, sequence[k], timeMap, cuts)
                }
            }
        }
        isEmpty = spans.allSatisfy { $0.allSatisfy(\.isEmpty) }
    }

    /// The gain of track `track` of source `take` (`keys[take][track]`) at output frame `frame`: the product of the
    /// ranges heard there, 1 out of them.
    func gain(take: Int, track: Int, atOutputFrame frame: Int64) -> Float {
        guard take < spans.count, track < spans[take].count else { return 1 }
        let list = spans[take][track]
        // The last span that starts at or before the frame.
        var (low, high) = (0, list.count)
        while low < high {
            let middle = low + (high - low) / 2
            if list[middle].frames.lowerBound <= frame { low = middle + 1 } else { high = middle }
        }
        guard low > 0, list[low - 1].frames.contains(frame) else { return 1 }
        let span = list[low - 1]
        let x = Double(cuts.sourceNanoseconds(ofClip: span.clip, atOutputFrame: frame))
        var gain = 1.0
        for ramp in span.ramps { gain *= ramp.gain(at: x) }
        return Float(gain)
    }

    // MARK: - Private

    /// `range` as the mix hears it: `nil` for one that is empty, whose gain is not a number or that is 0 dB.
    private static func ramp(of range: GainRange) -> Ramp? {
        guard !range.gain.isNaN, range.start < range.end else { return nil }
        let decibels = min(range.gain, 12)
        let amplitude = decibels <= GainRange.silence ? 0 : pow(10, decibels / 20)
        guard amplitude != 1 else { return nil }
        return Ramp(start: Double(range.start.nanoseconds), end: Double(range.end.nanoseconds), amplitude: amplitude)
    }

    /// The spans of `ramps` (all of `clip`'s take) in the window of clip `k`: its frames cut where any of them starts or
    /// ends to be heard, each with the ramps heard in it, in order; none where none is heard.
    private static func spans(of ramps: [Ramp], clip k: Int, _ clip: Clip, _ timeMap: TimeMap, _ cuts: AudioCuts) -> [Span] {
        let window = cuts.window(ofClip: k)
        guard !ramps.isEmpty, !window.isEmpty else { return [] }
        let (lowest, highest) = (Double(window.lowerBound), Double(window.upperBound))
        let start = Double(clip.start.nanoseconds), speed = ClipSpeed.clamped(clip.speed)
        let origin = Double(timeMap.clipOutputStarts[k])
        /// The output frame, fractional, where the clip is heard at source instant `x`, held to the window.
        func frame(_ x: Double) -> Double {
            min(max((origin + (x - start) / speed) * 48_000 / 1e9, lowest), highest)
        }
        // The source heard at the window's first frame and at its last.
        let first = Double(cuts.sourceNanoseconds(ofClip: k, atOutputFrame: window.lowerBound))
        let last = Double(cuts.sourceNanoseconds(ofClip: k, atOutputFrame: window.upperBound - 1))
        // Each ramp heard in the window over the frames it may be heard in: a frame more on each side than the source
        // maps to, which its own gain, 1 at and out of its edges, makes exact.
        let placed = ramps.compactMap { ramp -> (frames: Range<Int64>, ramp: Ramp)? in
            guard ramp.end > first, ramp.start < last else { return nil }
            let lower = Int64(max(frame(ramp.start).rounded(.down) - 1, lowest))
            let upper = Int64(min(frame(ramp.end).rounded(.up) + 1, highest))
            return lower < upper ? (lower..<upper, ramp) : nil
        }
        let edges = Set(placed.flatMap { [$0.frames.lowerBound, $0.frames.upperBound] }).sorted()
        var spans: [Span] = []
        for (lower, upper) in zip(edges, edges.dropFirst()) {
            let heard = placed.filter { $0.frames.lowerBound <= lower && $0.frames.upperBound >= upper }.map(\.ramp)
            if !heard.isEmpty { spans.append(Span(frames: lower..<upper, clip: k, ramps: heard)) }
        }
        return spans
    }
}
