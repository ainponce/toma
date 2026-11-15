// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a level meter moves toward the microphone's peak: it rises fast and falls slowly (notch design
/// §5.3), whatever the frame rate it is drawn at.
public struct MeterBallistics: Equatable, Sendable {
    /// The time constant while rising, in seconds.
    public static let attack = 0.045
    /// The time constant while falling, in seconds.
    public static let release = 0.110
    /// The peak, in dBFS, the meter shows as empty; full scale (0 dBFS) shows it full.
    public static let floorDecibels: Float = -60

    /// From 0 (empty) to 1 (full).
    public private(set) var level = 0.0

    public init() {}

    /// Moves the level `seconds` toward the peak, `clamp((dB − floor) / −floor, 0, 1)`:
    /// `level += (target − level) · (1 − e^(−seconds / τ))`, with τ `attack` while rising and `release`
    /// while falling. Returns the new level.
    public mutating func update(peakDecibels: Float, seconds: Double) -> Double {
        let floor = Double(Self.floorDecibels)
        let target = min(max((Double(peakDecibels) - floor) / -floor, 0), 1)
        let tau = target > level ? Self.attack : Self.release
        level += (target - level) * (1 - exp(-max(seconds, 0) / tau))
        return level
    }
}
