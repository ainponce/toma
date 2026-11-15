// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// How a track whose stream failed comes back: wait `backoff[n]` before attempt `n`; once the list is used
/// up, a track that keeps retrying goes on at its last interval (1 s with an empty list), and any other
/// track gives up. One restart, from the failure to the stream running again, walks one policy.
struct RestartPolicy: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        /// Wait this long, then try to start the source again.
        case wait(Duration)
        /// The backoff is used up: warn that the track is paused, once, then wait like `wait`.
        case warnPausedThenWait(Duration)
        /// The backoff is used up and the track does not keep retrying: it is lost.
        case giveUp
    }

    private let backoff: [Duration]
    private let keepsRetrying: Bool
    private var attempt = 0
    private var warnedPaused = false

    init(backoff: [Duration], keepsRetrying: Bool) {
        self.backoff = backoff
        self.keepsRetrying = keepsRetrying
    }

    /// What to do before the next attempt.
    mutating func next() -> Step {
        if attempt < backoff.count {
            defer { attempt += 1 }
            return .wait(backoff[attempt])
        }
        guard keepsRetrying else { return .giveUp }
        let delay = backoff.last ?? .seconds(1)
        guard warnedPaused else {
            warnedPaused = true
            return .warnPausedThenWait(delay)
        }
        return .wait(delay)
    }

    /// Whether a track keeps retrying once its restart attempts are used up: the only screen of the take (its
    /// one display or window), a microphone or a camera (a USB, Bluetooth or Continuity device can take far
    /// longer than the backoff to come back, or another app can hold it for a while), or system audio.
    static func keepsRetrying(kind: TrackKind, isSoleScreen: Bool) -> Bool {
        isSoleScreen || kind == .microphone || kind == .camera || kind == .systemAudio
    }
}
