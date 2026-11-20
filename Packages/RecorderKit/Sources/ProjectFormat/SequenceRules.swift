// SPDX-License-Identifier: GPL-3.0-or-later

/// The rules of a sequence with several takes and clips with content (phase 3 design §9 and §7.3, base plan decision 7),
/// shared by the time map, the document's validation (`DocumentRules`), the commands and the mix.
///
/// - **The invariant** (§9): within each take, the clips advance in the order of the sequence and never overlap: each
///   one starts at or after the end of every clip of its take before it. A clip with content is a point (its start; its
///   end is not read) that keeps that order too, so a frozen frame at the edge between two clips of its take is in
///   order, and one inside a clip of its take before it is not. A clip is read as `TimeMap` reads it: an end before its
///   start is its start.
/// - **The cut of the sound** (`Clip.audioShift`, §7.3): the edge at the start of clip `k` can move its sound by at most
///   half of the shorter of the two clips at that edge, `±min(D_{k−1}, D_k) / 2` ns of output (truncated); never at the
///   first clip, at a clip with content or at the one after a clip with content, which are silent or start the sound.
public enum SequenceRules {
    /// The first clip of `sequence` that breaks the invariant: one that starts before the end of a clip of its take
    /// before it. `nil` when every take is in order.
    public static func firstOutOfOrder(in sequence: [Clip]) -> Int? {
        outOfOrder(in: sequence).first
    }

    /// Every clip of `sequence` that starts before the end of a clip of its take before it, in order.
    static func outOfOrder(in sequence: [Clip]) -> [Int] {
        var ends: [String: UInt64] = [:]
        var found: [Int] = []
        for (k, clip) in sequence.enumerated() {
            let (start, end) = extent(of: clip)
            let last = ends[clip.take]
            if let last, start < last { found.append(k) }
            ends[clip.take] = max(last ?? 0, end)
        }
        return found
    }

    /// The `audioShift`s clip `k` of `sequence` can have, in ns of output: `0...0` for the first clip, a clip with
    /// content and the one after a clip with content (and for an index out of the sequence); otherwise
    /// `−h...h` with `h = min(D_{k−1}, D_k) / 2` (`TimeMap.outputDuration(of:)`, truncated).
    ///
    /// With `takeBounds` (each take's source the sound can be read in, by take ID), also what there is of the take: a J
    /// cut (negative) never has clip `k` heard from before the start of its take's bounds, and an L cut (positive) never
    /// has clip `k − 1` heard past the end of its own, each as `TimeMap.audioSource(ofClip:atOutput:)` reads it at the cut
    /// of the sound. A take without bounds there is not limited by them.
    public static func audioShiftRange(
        of sequence: [Clip], at k: Int, takeBounds: [String: ClosedRange<HostTime>]? = nil
    ) -> ClosedRange<Int64> {
        guard k > 0, k < sequence.count, sequence[k].content == nil, sequence[k - 1].content == nil else { return 0...0 }
        let (before, clip) = (sequence[k - 1], sequence[k])
        let shorter = min(TimeMap.outputDuration(of: before), TimeMap.outputDuration(of: clip))
        let half = shorter / 2
        guard let takeBounds else { return -half...half }
        var (lower, upper) = (-half, half)
        if let bounds = takeBounds[clip.take] {
            // Clip `k` heard `n` ns sooner reads from `s_k − round(n × v_k)` on.
            let speed = ClipSpeed.clamped(clip.speed)
            let room = Int64(clamping: clip.start.nanoseconds) - Int64(clamping: bounds.lowerBound.nanoseconds)
            lower = -largest(upTo: half) { TimeMap.roundedNanoseconds(Double($0) * speed) <= room }
        }
        if let bounds = takeBounds[before.take] {
            // Clip `k − 1` heard `n` ns longer reads up to `s_{k−1} + round((D_{k−1} + n) × v_{k−1})`.
            let speed = ClipSpeed.clamped(before.speed)
            let (start, end) = (Int64(clamping: before.start.nanoseconds), Int64(clamping: bounds.upperBound.nanoseconds))
            let duration = Double(TimeMap.outputDuration(of: before))
            upper = largest(upTo: half) { n in
                let (heard, overflow) = start.addingReportingOverflow(TimeMap.roundedNanoseconds((duration + Double(n)) * speed))
                return !overflow && heard <= end
            }
        }
        return lower...upper
    }

    /// The cut of the sound at the start of clip `k` as everything reads it: its `audioShift` held to
    /// `audioShiftRange(of:at:)`; 0 for an index out of the sequence.
    public static func audioShift(of sequence: [Clip], at k: Int) -> Int64 {
        audioShift(of: sequence, at: k, takeBounds: nil)
    }

    /// The cut of the sound at the start of clip `k` held to `audioShiftRange(of:at:takeBounds:)`: to the clips at its
    /// edge and to what each take of `takeBounds` has (none: the clips alone). The one rule of the mix (`AudioCuts`) and
    /// of the commands that write the sequence, so a document they write is one `audioShift(of:at:)` reads as the mix
    /// hears it. 0 for an index out of the sequence.
    public static func audioShift(of sequence: [Clip], at k: Int, takeBounds: [String: ClosedRange<HostTime>]?) -> Int64 {
        guard sequence.indices.contains(k) else { return 0 }
        let shift = sequence[k].audioShift
        // 0 is always in the range: a cut not moved needs nothing else of the sequence.
        guard shift != 0 else { return 0 }
        let range = audioShiftRange(of: sequence, at: k, takeBounds: takeBounds)
        return min(max(shift, range.lowerBound), range.upperBound)
    }

    // MARK: - Private

    /// The source a clip takes in its take, as `TimeMap` reads it: `[start, end)`, its start alone for a clip with content
    /// or an end before its start.
    private static func extent(of clip: Clip) -> (start: UInt64, end: UInt64) {
        let start = clip.start.nanoseconds
        return (start, clip.content == nil ? max(clip.end.nanoseconds, start) : start)
    }

    /// The largest `n` in `0...limit` for which `fits` holds, given that it holds up to some `n` and not after; 0 when it
    /// does not hold at 0 either.
    private static func largest(upTo limit: Int64, _ fits: (Int64) -> Bool) -> Int64 {
        guard limit > 0, fits(0) else { return 0 }
        var (low, high) = (Int64(0), limit)
        while low < high {
            let middle = low + (high - low + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
