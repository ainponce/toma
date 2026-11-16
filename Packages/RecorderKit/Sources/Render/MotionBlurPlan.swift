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
}
