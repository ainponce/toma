// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// How far the music goes down while someone speaks (`ducking-1`, design §7.5, plan 3c decision 8), as a gain for every
/// output frame.
///
/// `voiced` are the output frames with voice, in any order. They are joined, the gaps under 0.4 s are closed and the
/// stretches under 0.15 s are ignored (a cough or a key does not lower the music): what is left are the `runs`. The
/// envelope, in dB, is the whole amount during each run, a descent of `attack` before it (the mix knows the future: the
/// first word already sounds over low music) and a climb of `release` after it, both straight lines in dB; where two
/// runs overlap, the deeper one. It only ever lowers the music.
public struct DuckingEnvelope: Sendable {
    public static let algorithm = "ducking-1"
    /// 0.4 s at 48 kHz: a gap shorter than this between two voices is closed.
    public static let closedGapFrames: Int64 = 19_200
    /// 0.15 s at 48 kHz: a voice shorter than this is ignored.
    public static let shortestVoiceFrames: Int64 = 7_200

    /// The settings as they are used: `amount` in −40…0 dB, `attack` 0.05…2 s, `release` 0.1…4 s; a value that is not a
    /// number is the one of `Ducking.default`.
    static func held(_ ducking: Ducking) -> Ducking {
        func hold(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
        }
        let standard = Ducking.default
        return Ducking(
            enabled: ducking.enabled, amount: hold(ducking.amount, -40...0, standard.amount),
            attack: hold(ducking.attack, 0.05...2, standard.attack), release: hold(ducking.release, 0.1...4, standard.release))
    }

    /// The stretches that lower the music, in output frames: in order, apart from one another, none shorter than
    /// `shortestVoiceFrames`. Empty if the ducking is off or has nothing to lower.
    public let runs: [Range<Int64>]
    private let amount: Double
    private let attackFrames: Int64
    private let releaseFrames: Int64

    /// `true` when the gain is 1 at every frame: nothing to lower, or it is off.
    public var isUnity: Bool { runs.isEmpty }

    public init(voiced: [Range<Int64>], ducking: Ducking) {
        let settings = Self.held(ducking)
        amount = settings.amount
        attackFrames = max(1, Int64((settings.attack * 48_000).rounded()))
        releaseFrames = max(1, Int64((settings.release * 48_000).rounded()))
        guard settings.enabled, settings.amount < 0 else {
            runs = []
            return
        }
        // Frames are kept well inside Int64 so the sums below never overflow.
        let limit: Int64 = 1 << 60
        let sorted = voiced
            .map { max(-limit, $0.lowerBound)..<max(-limit, min(limit, $0.upperBound)) }
            .filter { !$0.isEmpty }
            .sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var joined: [Range<Int64>] = []
        for range in sorted {
            if let last = joined.last, range.lowerBound - last.upperBound < Self.closedGapFrames {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        runs = joined.filter { $0.count >= Self.shortestVoiceFrames }
    }

    /// The envelope at output frame `f`, in dB: 0 or less.
    public func decibels(atFrame f: Int64) -> Double {
        guard !runs.isEmpty else { return 0 }
        // The first run that starts after `f`; the one before it is the last that starts at or before.
        var low = 0, high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if runs[middle].lowerBound > f { high = middle } else { low = middle + 1 }
        }
        var depth = 0.0
        if low > 0 {
            let run = runs[low - 1]
            if f < run.upperBound {
                depth = amount
            } else if f - run.upperBound < releaseFrames {
                depth = min(depth, amount * Double(releaseFrames - (f - run.upperBound)) / Double(releaseFrames))
            }
        }
        if low < runs.count, runs[low].lowerBound - f <= attackFrames {
            depth = min(depth, amount * Double(attackFrames - (runs[low].lowerBound - f)) / Double(attackFrames))
        }
        return depth
    }

    /// The gain at output frame `f`: 10^(dB / 20), exactly 1 at 0 dB.
    public func gain(atFrame f: Int64) -> Float {
        let dB = decibels(atFrame: f)
        return dB == 0 ? 1 : Float(pow(10, dB / 20))
    }

    /// The gain of every frame of `frames`, into `gains`, which then holds `frames.count` values: each is `gain(atFrame:)`.
    public func gains(_ frames: Range<Int64>, into gains: inout [Float]) {
        gains.removeAll(keepingCapacity: true)
        gains.reserveCapacity(frames.count)
        if isUnity {
            gains.append(contentsOf: repeatElement(1, count: frames.count))
            return
        }
        for frame in frames { gains.append(gain(atFrame: frame)) }
    }
}
