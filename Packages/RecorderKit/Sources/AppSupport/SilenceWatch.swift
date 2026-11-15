// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether the microphone hears anything: a take whose microphone stays below `thresholdDecibels` for its
/// first `window` seconds recorded is said to be silent (plan decision 14). The time recorded leaves the
/// pauses out, so a pause never brings the warning closer.
public struct SilenceWatch: Equatable, Sendable {
    /// Seconds recorded.
    public static let window = 5.0
    /// A peak above this, in dBFS, is a sound.
    public static let thresholdDecibels: Float = -70

    public enum Verdict: Equatable, Sendable {
        /// Nothing heard yet, and nothing to say.
        case listening
        /// Nothing heard in the first `window` seconds recorded: said once.
        case silent
        /// Something was heard: from the first peak above the threshold on.
        case heard
    }

    private var hasWarned = false
    private var hasHeard = false

    public init() {}

    /// What the microphone's peak now, with `recordedSeconds` recorded so far, says.
    public mutating func observe(peakDecibels: Float, recordedSeconds: Double) -> Verdict {
        if hasHeard || peakDecibels > Self.thresholdDecibels {
            hasHeard = true
            return .heard
        }
        guard !hasWarned, recordedSeconds >= Self.window else { return .listening }
        hasWarned = true
        return .silent
    }
}
