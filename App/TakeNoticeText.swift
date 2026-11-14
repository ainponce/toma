// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat

extension TakeNotice {
    /// The sentence the menu shows for this notice. `closeError` is what `closedWithError` is about
    /// (`RecordingController.lastCloseError`).
    func text(closeError: (any Error)?) -> String {
        switch self {
        case .noMicrophone:
            String(localized: "No microphone found. Recording without audio.")
        case .microphoneAccessOff:
            String(localized: "Microphone access is off. Recording without audio.")
        case .microphoneFailedToStart:
            String(localized: "The microphone couldn't start. Recording the screen without audio.")
        case .streamInterrupted(let kind):
            switch kind {
            case .display: String(localized: "Screen capture was interrupted. Trying again…")
            case .microphone: String(localized: "Microphone capture was interrupted. Trying again…")
            }
        case .streamResumed(let kind):
            switch kind {
            case .display: String(localized: "Screen capture resumed.")
            case .microphone: String(localized: "Microphone capture resumed.")
            }
        case .trackLost(let kind):
            switch kind {
            case .display: String(localized: "The screen stopped recording.")
            case .microphone: String(localized: "The microphone stopped recording. The recording continues without it.")
            }
        case .screenPaused:
            String(localized: "Screen capture is paused. Still trying to restart it.")
        case .trackPaused(let kind):
            switch kind {
            // Does not happen: a display that is not the only one is lost, not paused.
            case .display: String(localized: "Screen capture is paused. Still trying to restart it.")
            case .microphone: String(localized: "The microphone stopped recording. Still trying to bring it back.")
            }
        case .writerFailed(let kind):
            switch kind {
            case .display: String(localized: "Saving the screen failed. Continuing in a new file.")
            case .microphone: String(localized: "Saving the microphone failed. Continuing in a new file.")
            }
        case .samplesDropped(let kind):
            switch kind {
            case .display: String(localized: "Some screen frames couldn't be saved.")
            case .microphone: String(localized: "Some microphone audio couldn't be saved.")
            }
        case .manifestWriteFailed:
            String(localized: "Couldn't update the project file. Trying again.")
        case .diskLow(let available):
            String(localized: "Low disk space: \(available.formatted(.byteCount(style: .file))) left.")
        case .stoppedForDiskSpace:
            String(localized: "Recording stopped: the disk is almost full.")
        case .diskSpaceUnknown:
            String(localized: "Can't check the free disk space.")
        case .closedWithError:
            String(localized: "The recording closed with an error: \(closeError.map(userFacingDescription(of:)) ?? String(localized: "An unexpected error occurred."))")
        }
    }
}
