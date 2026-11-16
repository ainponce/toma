// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// "Avoid clipping" (design §7.7): a peak limiter with 5 ms of lookahead, a release of 50 ms and a ceiling of −1 dBFS,
/// on interleaved 48 kHz Float32 frames, every channel at the same gain.
///
/// Each frame needs the gain that brings its largest sample down to `ceiling` (1 when it is under it). The gain applied
/// is the smallest needed over the lookahead (`lookaheadFrames + 1` frames), recovering from it towards 1 with a time
/// constant of `releaseFrames`, then averaged over the lookahead again so it moves smoothly; the sound goes out
/// `lookaheadFrames` later, so that averaged gain is already down when a peak comes out, and no sample ever passes the
/// ceiling. Under the ceiling it changes nothing: every sample comes out as it went in, `lookaheadFrames` frames later.
///
/// Deterministic: a function of the frames given since it was made, whatever blocks they came in; the average adds
/// fixed-point integers, so it never drifts. The release lands exactly on the gain needed once it is within
/// `releaseSnap` of it, so a limiter forgets where it started: two limiters in different states given the same frames
/// come together when their envelopes land on the same gain (at the first peak that needs less than both, or when the
/// release lands, within `settleFrames`), and give the same bits 241 frames later. That is how a mix started in the
/// middle sounds as the one played from the start (`EditedMix`).
public struct PeakLimiter: Sendable {
    /// −1 dBFS: 10^(−1/20).
    public static let ceiling: Float = 0.8912509
    /// 5 ms at 48 kHz: how far ahead it looks, and how late the sound comes out.
    public static let lookaheadFrames = 240
    /// 50 ms at 48 kHz: the time constant of the release.
    public static let releaseFrames = 2_400
    /// How close the release gets to the gain needed before it lands on it: −120 dB, inaudible.
    static let releaseSnap = 1e-6
    /// 1 s at 48 kHz: what a limiter needs of the frames before one to give it as one that saw them all would. The
    /// release lands from any gain in under 33 200 frames (`releaseFrames × ln(1 / releaseSnap)`), and the lookahead
    /// and the average forget what came before it in 241 more.
    static let settleFrames = 48_000

    /// The frames each gain is taken over: the lookahead and the frame itself.
    private static let span = lookaheadFrames + 1
    /// A gain of 1 in the fixed point of the average.
    private static let unit = 1 << 30
    /// What the release closes of the distance to the gain needed, per frame.
    private static let releaseStep = 1 - exp(-1 / Double(releaseFrames))

    public let channels: Int
    /// The last `lookaheadFrames` frames given, interleaved, the oldest at `delayIndex`.
    private var delay: [Float]
    private var delayIndex = 0
    /// The gains needed over the last `span` frames that can still be the smallest, oldest first, from `windowHead`:
    /// both the frames and the gains increase.
    private var windowFrames: [Int64]
    private var windowGains: [Double]
    private var windowHead = 0
    private var windowCount = 0
    /// The smallest gain needed, released towards 1.
    private var envelope = 1.0
    /// `envelope` of the last `span` frames in fixed point (`unit` is 1), from `averageIndex`, and their sum.
    private var recent: [Int]
    private var averageIndex = 0
    private var recentSum: Int
    /// The frames given so far.
    private var frame: Int64 = 0

    /// A limiter for `channels` interleaved channels, its delay silent.
    public init(channels: Int) {
        precondition(channels > 0, "PeakLimiter: \(channels) channels")
        self.channels = channels
        delay = [Float](repeating: 0, count: Self.lookaheadFrames * channels)
        windowFrames = [Int64](repeating: 0, count: Self.span)
        windowGains = [Double](repeating: 1, count: Self.span)
        recent = [Int](repeating: Self.unit, count: Self.span)
        recentSum = Self.unit * Self.span
    }

    /// Replaces the frames of `samples` (interleaved, `channels` per frame) by the limited ones that come out as they go
    /// in: the frame given `lookaheadFrames` frames before each.
    /// - Precondition: `samples.count` is a multiple of `channels`.
    public mutating func process(_ samples: inout [Float]) {
        precondition(samples.count % channels == 0, "PeakLimiter: \(samples.count) samples for \(channels) channels")
        for first in stride(from: 0, to: samples.count, by: channels) {
            processFrame(&samples, at: first)
        }
    }

    private mutating func processFrame(_ samples: inout [Float], at first: Int) {
        var peak: Float = 0
        for c in 0..<channels { peak = max(peak, abs(samples[first + c])) }
        let needed = peak > Self.ceiling ? Double(Self.ceiling) / Double(peak) : 1

        // The smallest gain needed over the last `span` frames, this one included.
        while windowCount > 0, windowFrames[windowHead] <= frame - Int64(Self.span) {
            windowHead = (windowHead + 1) % Self.span
            windowCount -= 1
        }
        while windowCount > 0, windowGains[(windowHead + windowCount - 1) % Self.span] >= needed { windowCount -= 1 }
        let back = (windowHead + windowCount) % Self.span
        windowFrames[back] = frame
        windowGains[back] = needed
        windowCount += 1
        let smallest = windowGains[windowHead]

        // Down at once, back up with the release, landing on it at the end; never above what the frames ahead need.
        if smallest < envelope || smallest - envelope < Self.releaseSnap {
            envelope = smallest
        } else {
            envelope += (smallest - envelope) * Self.releaseStep
        }
        // Rounded down, so the average is never above the gain any frame of its span needs.
        let fixed = Int((envelope * Double(Self.unit)).rounded(.down))
        recentSum += fixed - recent[averageIndex]
        recent[averageIndex] = fixed
        averageIndex = (averageIndex + 1) % Self.span
        let gain = Float(Double(recentSum) / Double(Self.unit * Self.span))

        let held = delayIndex * channels
        for c in 0..<channels {
            let late = delay[held + c]
            delay[held + c] = samples[first + c]
            samples[first + c] = min(max(late * gain, -Self.ceiling), Self.ceiling)
        }
        delayIndex = (delayIndex + 1) % Self.lookaheadFrames
        frame += 1
    }
}
