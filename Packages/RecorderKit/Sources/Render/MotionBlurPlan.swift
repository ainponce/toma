// SPDX-License-Identifier: GPL-3.0-or-later

/// How the motion blur of the zoom camera and of the cursor samples a frame (design §7.4 and §7.5): how many subsamples
/// a motion needs, and at which output times they are.
///
/// The times are output times, which the motion paths are in and which `TimeMap` maps to the source: a subsample never
/// reads what a cut left out, as a source time moved by the shutter could.
public enum MotionBlurPlan {
    /// The most subsamples of a frame.
    public static let maxSamples = 16
    /// How far, in output pixels, a motion goes between two subsamples at most.
    public static let pixelsPerSample = 1.5

    /// The subsamples of a motion that goes `d` output pixels over the shutter: `clamp(ceil(d / 1.5), 1, 16)`; 1 for a
    /// distance that is not a number.
    public static func sampleCount(travelPixels d: Double) -> Int {
        guard !d.isNaN else { return 1 }
        return Int(min(max((d / pixelsPerSample).rounded(.up), 1), Double(maxSamples)))
    }

    /// The output times of `count` subsamples of the frame at `t`, over a shutter of `shutter` frames (read from 0 to 1,
    /// 0 if not a number) of `frameDuration` ns: `τ_j = t + (j/(N−1) − ½) × shutter × frameDuration`, rounded to the
    /// nanosecond, in order. Only `t` with a count of 1 or less, a shutter of 0 or a frame of no duration.
    public static func sampleTimes(at t: Int64, shutter: Double, frameDuration: Int64, count: Int) -> [Int64] {
        let shutter = shutter.isNaN ? 0 : min(max(shutter, 0), 1)
        guard count > 1, shutter > 0, frameDuration > 0 else { return [t] }
        let open = shutter * Double(frameDuration)
        return (0..<count).map { j in
            t + Int64(((Double(j) / Double(count - 1) - 0.5) * open).rounded())
        }
    }

    /// `sampleTimes(at:shutter:frameDuration:count:)` held to the side of `t` of each jump the shutter crosses (final
    /// review B-M1). `jumps` are where a path goes at once from one value to another, in order and apart: each from its
    /// last output time at the old value through its first at the new one (an instant zoom block's edge, an unsmoothed
    /// cursor at a cut). A shutter that crosses one samples only `t`'s side: from the jump's new value on when `t` is at
    /// or after it, up to its old value when `t` is before it, so the frame is one image and not the two on either side.
    /// The `count` times are then spread evenly over what is left, `τ_j = a + round(j/(N−1) × (b − a))`, in order; a
    /// shutter that crosses none gives the same times as without `jumps`.
    public static func sampleTimes(
        at t: Int64, shutter: Double, frameDuration: Int64, count: Int, jumps: [ClosedRange<Int64>]
    ) -> [Int64] {
        let times = sampleTimes(at: t, shutter: shutter, frameDuration: frameDuration, count: count)
        guard times.count > 1, let first = times.first, let last = times.last, !jumps.isEmpty else { return times }
        var (low, high) = (first, last)
        // The first jump that ends after the shutter opens: the ones before it are behind it.
        var i = partitionPoint(jumps.count) { jumps[$0].upperBound <= first }
        while i < jumps.count, jumps[i].lowerBound < last {
            let jump = jumps[i]
            if t >= jump.upperBound {
                low = max(low, jump.upperBound)
            } else if t <= jump.lowerBound {
                high = min(high, jump.lowerBound)
            } else {
                // `t` is inside the jump itself (between two steps of a path): only `t`.
                return [t]
            }
            i += 1
        }
        guard low != first || high != last else { return times }
        let span = Double(high - low)
        return (0..<count).map { j in low + Int64((Double(j) / Double(count - 1) * span).rounded()) }
    }

    /// The first index in `0..<count` for which `isPast` is false, with every true one before every false one.
    private static func partitionPoint(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let mid = (low + high) / 2
            if isPast(mid) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
