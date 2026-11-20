// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The measures of a theme (plan decision 5) on its loop, stereo interleaved at 48 kHz, for the tests and
/// `recorder-dev music`. Not in the path of the samples, so it may use libm.
public enum MusicMetrics {
    /// 50 ms, and the step between two windows of `quietestWindow`, 10 ms.
    static let windowFrames = 2_400
    static let windowStep = 480

    /// The integrated loudness, in LUFS (`loudness-1`, ITU-R BS.1770-4); `nil` for silence.
    public static func loudness(_ interleaved: [Float]) -> Double? {
        let (left, right) = channels(interleaved)
        return Loudness.integrated(Loudness.blockEnergies([left, right]))
    }

    /// The largest magnitude of a sample.
    public static func peak(_ interleaved: [Float]) -> Float {
        interleaved.reduce(0) { max($0, $1.magnitude) }
    }

    /// The correlation of the left and the right channel, −1 to 1 (Pearson's): 1 is mono, 0 two unrelated sides. 1 for
    /// two silent channels.
    public static func correlation(_ interleaved: [Float]) -> Double {
        let frames = interleaved.count / 2
        guard frames > 0 else { return 1 }
        var sumL = 0.0, sumR = 0.0
        for k in 0..<frames {
            sumL += Double(interleaved[2 * k])
            sumR += Double(interleaved[2 * k + 1])
        }
        let meanL = sumL / Double(frames), meanR = sumR / Double(frames)
        var lr = 0.0, ll = 0.0, rr = 0.0
        for k in 0..<frames {
            let l = Double(interleaved[2 * k]) - meanL, r = Double(interleaved[2 * k + 1]) - meanR
            lr += l * r
            ll += l * l
            rr += r * r
        }
        guard ll > 0, rr > 0 else { return 1 }
        return lr / (ll * rr).squareRoot()
    }

    /// The level of the quietest 50 ms of the loop, in dBFS of the mean square of both channels (a full-scale sine on
    /// both is −3), over windows every 10 ms that also go around the loop's end. −∞ for silence.
    public static func quietestWindow(_ interleaved: [Float]) -> Double {
        let frames = interleaved.count / 2
        guard frames > 0 else { return -.infinity }
        let squares = (0..<frames).map { k -> Double in
            let l = Double(interleaved[2 * k]), r = Double(interleaved[2 * k + 1])
            return (l * l + r * r) / 2
        }
        // A running sum around the loop.
        let window = min(windowFrames, frames)
        var sum = 0.0
        for k in 0..<window { sum += squares[k] }
        var quietest = sum
        var start = 0
        while start + windowStep < frames {
            for k in start..<(start + windowStep) {
                sum -= squares[k]
                sum += squares[(k + window) % frames]
            }
            start += windowStep
            quietest = min(quietest, sum)
        }
        let meanSquare = max(quietest, 0) / Double(window)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity
    }

    /// The energy under `frequency` Hz over the whole energy, in dB (eight one-pole low-passes at `frequency` in a row,
    /// in `Double`: 18 dB down at it, 45 dB at 1.6 times it).
    public static func band(_ interleaved: [Float], below frequency: Double) -> Double {
        band(interleaved, frequency: frequency, low: true)
    }

    /// The energy over `frequency` Hz over the whole energy, in dB (eight one-pole high-passes at `frequency` in a row,
    /// in `Double`).
    public static func band(_ interleaved: [Float], above frequency: Double) -> Double {
        band(interleaved, frequency: frequency, low: false)
    }

    /// The one-pole stages of `band`.
    static let bandStages = 8

    private static func band(_ interleaved: [Float], frequency: Double, low: Bool) -> Double {
        let a = exp(-2 * Double.pi * frequency / Double(MusicFile.sampleRate))
        var total = 0.0, inBand = 0.0
        for channel in 0..<2 {
            var states = [Double](repeating: 0, count: bandStages)
            for k in 0..<(interleaved.count / 2) {
                let x = Double(interleaved[2 * k + channel])
                var y = x
                for s in 0..<bandStages {
                    states[s] = y + a * (states[s] - y)
                    y = low ? states[s] : y - states[s]
                }
                total += x * x
                inBand += y * y
            }
        }
        guard total > 0 else { return -.infinity }
        return inBand > 0 ? 10 * log10(inBand / total) : -.infinity
    }

    /// The loop's seam: the largest step from its last frame to its first (`jump`, over both channels), the largest step
    /// between two frames inside it (`largestInside`), and the level of its first 50 ms over its last 50 ms, in dB
    /// (`windowsAcross`; 0 for two silent windows).
    public static func seam(_ interleaved: [Float]) -> (jump: Float, largestInside: Float, windowsAcross: Double) {
        let frames = interleaved.count / 2
        guard frames > 1 else { return (0, 0, 0) }
        let last = 2 * (frames - 1)
        let jump = max((interleaved[0] - interleaved[last]).magnitude, (interleaved[1] - interleaved[last + 1]).magnitude)
        var largest: Float = 0
        for i in 2..<interleaved.count {
            largest = max(largest, (interleaved[i] - interleaved[i - 2]).magnitude)
        }
        let window = min(windowFrames, frames)
        func meanSquare(_ range: Range<Int>) -> Double {
            var sum = 0.0
            for k in range {
                let l = Double(interleaved[2 * k]), r = Double(interleaved[2 * k + 1])
                sum += l * l + r * r
            }
            return sum / Double(2 * range.count)
        }
        let first = meanSquare(0..<window), end = meanSquare((frames - window)..<frames)
        let across = first > 0 && end > 0 ? 10 * log10(first / end) : (first == end ? 0 : .infinity)
        return (jump, largest, across)
    }

    /// The left and the right channel of `interleaved`.
    static func channels(_ interleaved: [Float]) -> ([Float], [Float]) {
        let frames = interleaved.count / 2
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        for k in 0..<frames {
            left[k] = interleaved[2 * k]
            right[k] = interleaved[2 * k + 1]
        }
        return (left, right)
    }
}
