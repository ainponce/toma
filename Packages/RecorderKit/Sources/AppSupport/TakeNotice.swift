// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Something the user should know about the current or the last take. The app says it in a sentence of its own.
public enum TakeNotice: Equatable, Sendable {
    /// The Mac has no microphone: the take is recorded without audio.
    case noMicrophone
    /// Microphone access is not allowed: the take is recorded without audio.
    case microphoneAccessOff
    /// The source of this kind (the camera, the microphone or system audio) did not start: the take is recorded
    /// again, in a new project, without it.
    case optionalSourceFailedToStart(TrackKind)
    /// Camera access is not allowed: the take is recorded without the camera.
    case cameraAccessOff
    /// System audio is chosen but its permission was never asked for (it is asked for when it is turned on in the
    /// island, never as a take starts): the take is recorded without it.
    case systemAudioNotRequested
    /// The window being recorded is minimized or hidden: the take goes on, and records it again once it is back.
    case windowHidden
    /// The capture of a track of this kind failed; it is being restarted.
    case streamInterrupted(TrackKind)
    /// The capture of a track of this kind runs again.
    case streamResumed(TrackKind)
    /// A track of this kind records nothing more in this take.
    case trackLost(TrackKind)
    /// The only screen could not be restarted yet; it keeps trying.
    case screenPaused
    /// A track of this kind could not be restarted yet; it keeps trying.
    case trackPaused(TrackKind)
    /// Saving a track of this kind failed; it goes on in a new file.
    case writerFailed(TrackKind)
    /// Some samples of a track of this kind could not be saved.
    case samplesDropped(TrackKind)
    /// The project file could not be updated; it is written again.
    case manifestWriteFailed
    case diskLow(availableBytes: Int64)
    /// The take stopped because the disk is (almost) full.
    case stoppedForDiskSpace
    /// The free disk space cannot be read.
    case diskSpaceUnknown
    /// Closing the take failed in part (`RecordingController.lastCloseError` says how); it is closed.
    case closedWithError
    /// The take that was restarted could not be moved to the trash: it stays in the projects folder.
    case couldNotMoveToTrash
    /// The microphone has heard nothing in the first seconds recorded (`SilenceWatch`); it goes away once
    /// it hears something.
    case microphoneSilent
    /// The shortcut that turns Do Not Disturb on failed or did not end in time (`FocusGuard`): notifications may sound
    /// during the take. They never appear in the video.
    case focusShortcutFailed
}
