// SPDX-License-Identifier: GPL-3.0-or-later

/// Output time ↔ source time over the clips of a sequence (design §6.6): the output plays clip after clip, each
/// clip `k` showing its source `[s_k, e_k)` at its speed `v_k`. Output times are integer nanoseconds from the start of
/// the output; all the arithmetic is on integer nanoseconds, so no error builds up from one clip to the next.
///
/// - Clip `k` lasts `D_k = round((e_k − s_k) / v_k)` ns of output and starts at `O_k`, the sum of the durations before
///   it; the output lasts `D`, the sum of all of them. A clip whose `D_k` rounds to 0 is never shown.
/// - Within each take, the clips are in source order and never overlap (as `EditDocument.sequence` is in 1b), so the
///   mapping is monotonic and each source instant is shown at most once.
/// - A speed is read with `ClipSpeed.clamped(_:)`, in its range from 0.25 to 16 (a speed out of it is clamped, one that
///   is not a number is 1), so a document edited by hand never stops the render. Every mapping here reads it so, also
///   the one of the instants outside the clips (`output(ofSampleAt:take:)`, `output(ofChangeAt:take:)`): the render, the
///   motion paths and the sequence commands share this one rule.
public struct TimeMap: Equatable, Sendable {
    /// `D`, in nanoseconds.
    public let duration: Int64
    /// `O_k` of each clip, in the order of the sequence.
    public let clipOutputStarts: [Int64]
    /// The clips of the sequence, as the mapping reads them.
    private let clips: [Piece]
    /// The indices of the clips of each take that have any source (`s_k < e_k`), in the order of the sequence.
    private let clipsByTake: [String: [Int]]

    private struct Piece: Equatable, Sendable {
        var start: UInt64
        /// Never before `start`.
        var end: UInt64
        /// `ClipSpeed.clamped`.
        var speed: Double
        var length: UInt64 { end - start }
        /// `D_k`: `round(length / speed)`.
        var outputDuration: Int64 { TimeMap.outputOffset(ofSource: length, speed: speed) }

        /// `clip` as the mapping reads it: an end before the start is the start, and the speed is clamped.
        init(_ clip: Clip) {
            start = clip.start.nanoseconds
            end = max(clip.end.nanoseconds, clip.start.nanoseconds)
            speed = ClipSpeed.clamped(clip.speed)
        }
    }

    public init(sequence: [Clip]) {
        clips = sequence.map(Piece.init)
        var starts: [Int64] = []
        var total: Int64 = 0
        for piece in clips {
            starts.append(total)
            total = Self.adding(total, piece.outputDuration)
        }
        duration = total
        clipOutputStarts = starts
        var byTake: [String: [Int]] = [:]
        for (index, clip) in sequence.enumerated() where clips[index].length > 0 {
            byTake[clip.take, default: []].append(index)
        }
        clipsByTake = byTake
    }

    /// `D` in seconds.
    public var durationSeconds: Double { Double(duration) / 1e9 }

    /// `D_k` of `clip`, what it lasts in the output wherever it is in a sequence: `round((e − s) / v)` ns, with its speed
    /// read by `ClipSpeed.clamped(_:)` and an end before its start read as no source.
    public static func outputDuration(of clip: Clip) -> Int64 {
        Piece(clip).outputDuration
    }

    /// The clip and the source instant shown at output time `τ`, clamped to `[0, D)`: in the clip `k` with
    /// `O_k ≤ τ < O_k + D_k` (never one with `D_k == 0`), `s_k + round((τ − O_k) × v_k)` clamped to `[s_k, e_k − 1]`.
    /// `nil` only for an output of 0 ns.
    public func source(atOutput τ: Int64) -> (clip: Int, source: HostTime)? {
        guard duration > 0 else { return nil }
        let t = min(max(τ, 0), duration - 1)
        // The last clip starting at or before `t`: since `t < D`, it ends after `t`, so it has output.
        let k = Self.partitionPoint(clipOutputStarts.count) { clipOutputStarts[$0] <= t } - 1
        let piece = clips[k]
        let offset = Self.roundedNanoseconds(Double(t - clipOutputStarts[k]) * piece.speed)
        return (k, HostTime(nanoseconds: piece.start + min(UInt64(max(offset, 0)), piece.length - 1)))
    }

    /// The output time of source instant `x` of `take`: `O_k + round((x − s_k) / v_k)` in the clip `k` of that take
    /// with `s_k ≤ x < e_k`; `nil` if `x` is cut.
    public func output(atSource x: HostTime, take: String) -> Int64? {
        guard let takeClips = clipsByTake[take] else { return nil }
        let i = lastClip(of: takeClips, startingAtOrBefore: x.nanoseconds)
        guard i >= 0, x.nanoseconds < clips[takeClips[i]].end else { return nil }
        return output(ofSource: x.nanoseconds, inClip: takeClips[i])
    }

    /// The output time of the first instant of `take` at or after `x` that is not cut: `x`'s own if it is kept, the
    /// start of the next clip of that take if it is cut, `nil` if no clip of that take ends after it. This is where a
    /// change at `x` (a camera or screen change) starts to rule.
    public func firstKeptOutput(atOrAfter x: HostTime, take: String) -> Int64? {
        guard let takeClips = clipsByTake[take] else { return nil }
        let i = lastClip(of: takeClips, startingAtOrBefore: x.nanoseconds)
        if i >= 0, x.nanoseconds < clips[takeClips[i]].end { return output(ofSource: x.nanoseconds, inClip: takeClips[i]) }
        return i + 1 < takeClips.count ? clipOutputStarts[takeClips[i + 1]] : nil
    }

    /// The output time of a sample of `take` taken at source instant `x` (a pointer position): its own in a clip
    /// (`output(atSource:take:)`); before the take's first clip and from the end of its last one on,
    /// `O_k + round((x − s_k) / v_k)` through that clip (negative, or past `D`), so a sample the recorder took before the
    /// sources started counts at output 0, as it always did. `nil` in a cut between two clips of the take, and for a
    /// take without clips.
    public func output(ofSampleAt x: HostTime, take: String) -> Int64? {
        guard let takeClips = clipsByTake[take], let first = takeClips.first, let last = takeClips.last else { return nil }
        if x.nanoseconds < clips[first].start { return extrapolated(x.nanoseconds, clip: first) }
        if x.nanoseconds >= clips[last].end { return extrapolated(x.nanoseconds, clip: last) }
        return output(atSource: x, take: take)
    }

    /// Where a change of `take` at source instant `x` (of the camera) starts to rule: before the take's first clip, at
    /// its time through that clip's mapping (negative: it is under way at output 0, as it always was); otherwise from
    /// the first instant kept at or after it (`firstKeptOutput(atOrAfter:take:)`), so one in a cut rules from the next
    /// clip on and one after the last clip never rules. `nil` for a take without clips.
    public func output(ofChangeAt x: HostTime, take: String) -> Int64? {
        guard let first = clipsByTake[take]?.first else { return nil }
        if x.nanoseconds < clips[first].start { return extrapolated(x.nanoseconds, clip: first) }
        return firstKeptOutput(atOrAfter: x, take: take)
    }

    /// The output range in which source range `range` of `take` is seen, with the cuts inside it closed: from the
    /// output of its first kept instant to the end of the output of its last one (each end mapped in its clip as
    /// `O_k + round((x − s_k) / v_k)`), so a block split by a cut is still one block in the output. `nil` if nothing in
    /// `range` is kept; the range is empty when what is kept lasts 0 ns of output.
    public func outputRange(ofSource range: Range<HostTime>, take: String) -> Range<Int64>? {
        guard !range.isEmpty, let takeClips = clipsByTake[take] else { return nil }
        let (a, b) = (range.lowerBound.nanoseconds, range.upperBound.nanoseconds)
        // The first clip ending after `a` and the last one starting before `b`; ends are in order, like starts.
        let first = Self.partitionPoint(takeClips.count) { clips[takeClips[$0]].end <= a }
        let last = Self.partitionPoint(takeClips.count) { clips[takeClips[$0]].start < b } - 1
        guard first < takeClips.count, last >= 0, first <= last else { return nil }
        let (firstClip, lastClip) = (takeClips[first], takeClips[last])
        let lower = output(ofSource: max(a, clips[firstClip].start), inClip: firstClip)
        let upper = output(ofSource: min(b, clips[lastClip].end), inClip: lastClip)
        return lower..<upper
    }

    /// The output time of frame `n` at `frameRate`: `round(n / frameRate × 10⁹)` ns, in `Double` as the export
    /// has always counted it.
    public static func frameTime(_ n: Int, frameRate: Int) -> Int64 {
        roundedNanoseconds(Double(n) / Double(frameRate) * 1e9)
    }

    /// `seconds` of output in nanoseconds, rounded the way `HostTime.adding(seconds:)` counts them.
    public static func outputNanoseconds(seconds: Double) -> Int64 {
        roundedNanoseconds(seconds * 1e9)
    }

    /// The frames of the output at `frameRate`: `round(D / 10⁹ × frameRate)`, at least 1.
    public func frameCount(frameRate: Int) -> Int {
        max(1, Int((durationSeconds * Double(frameRate)).rounded()))
    }

    // MARK: - Private

    /// `O_k + round((x − s_k) / v_k)` for clip `k`, with `s_k ≤ x` (past `e_k` too); at `x == e_k` it is `O_k + D_k`.
    private func output(ofSource x: UInt64, inClip k: Int) -> Int64 {
        Self.adding(clipOutputStarts[k], Self.outputOffset(ofSource: x - clips[k].start, speed: clips[k].speed))
    }

    /// `O_k + round((x − s_k) / v_k)` for an instant `x` on either side of clip `k`, rounded as inside it (halves away
    /// from zero, so an instant before the clip is the negative of one as far after its start), saturating at the ends
    /// of `Int64`.
    private func extrapolated(_ x: UInt64, clip k: Int) -> Int64 {
        let piece = clips[k]
        if x >= piece.start { return output(ofSource: x, inClip: k) }
        // `O_k` is never negative and the offset at most `Int64.max`: the difference never overflows.
        return clipOutputStarts[k] - Self.outputOffset(ofSource: piece.start - x, speed: piece.speed)
    }

    /// The index in `takeClips` of the last clip whose start is at or before `x`; -1 if there is none.
    private func lastClip(of takeClips: [Int], startingAtOrBefore x: UInt64) -> Int {
        Self.partitionPoint(takeClips.count) { clips[takeClips[$0]].start <= x } - 1
    }

    /// `round(length / speed)`: the output nanoseconds that `length` nanoseconds of source last at `speed`.
    private static func outputOffset(ofSource length: UInt64, speed: Double) -> Int64 {
        roundedNanoseconds(Double(length) / speed)
    }

    /// `x` rounded to the nearest integer (halves away from zero), saturating at the ends of `Int64`; 0 if not a number.
    private static func roundedNanoseconds(_ x: Double) -> Int64 {
        let rounded = x.rounded()
        if rounded.isNaN { return 0 }
        // `Double(Int64.max)` is 2⁶³, one past it.
        if rounded >= Double(Int64.max) { return .max }
        if rounded <= Double(Int64.min) { return .min }
        return Int64(rounded)
    }

    /// `a + b`, saturating at `Int64.max` (both are never negative here).
    private static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    private static func partitionPoint(_ count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
