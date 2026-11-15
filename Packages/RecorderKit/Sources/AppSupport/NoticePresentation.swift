// SPDX-License-Identifier: GPL-3.0-or-later

/// How the island shows a notice (notch design §5.1, plan decision 29).
public enum NoticePresentation: Equatable, Sendable {
    /// A short confirmation: a capsule under the island for `IslandConfirmation.displayDuration`.
    case confirmation
    /// Asks for attention: an amber icon on the right wing, and the compact notice for a few seconds.
    case attention
    /// The take stopped by itself or closed with an error: the same, in red.
    case stopped
}

extension TakeNotice {
    /// How the island shows this notice. Every new notice chooses one: there is no default.
    public var presentation: NoticePresentation {
        switch self {
        case .stoppedForDiskSpace, .closedWithError:
            .stopped
        case .streamResumed:
            .confirmation
        case .noMicrophone, .microphoneAccessOff, .optionalSourceFailedToStart, .cameraAccessOff, .systemAudioNotRequested,
            .windowHidden, .streamInterrupted, .trackLost, .screenPaused, .trackPaused, .writerFailed, .samplesDropped,
            .manifestWriteFailed, .diskLow, .diskSpaceUnknown, .couldNotMoveToTrash, .microphoneSilent:
            .attention
        }
    }
}

/// What the user just did, as the capsule under the island confirms it (`RecordingController.onConfirmation`).
public enum IslandConfirmation: Equatable, Sendable {
    /// A marker was written.
    case markerAdded
    /// The user's pause is on.
    case paused
    /// A restart moved the take it closed to the trash.
    case movedToTrash
    /// A stop ended the countdown: nothing was recorded.
    case countdownCancelled

    /// How long the capsule shows.
    public static let displayDuration: Duration = .seconds(2)
}
