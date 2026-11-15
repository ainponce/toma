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
        case .cameraNotRecordedYet:
            String(localized: "In this version the camera is only a preview: this recording doesn't include it.")
        case .cameraAccessOff:
            String(localized: "Camera access is off. Recording without the camera.")
        case .streamInterrupted(let kind):
            switch kind {
            case .display: String(localized: "Screen capture was interrupted. Trying again…")
            case .window: String(localized: "Window capture was interrupted. Trying again…")
            case .camera: String(localized: "Camera capture was interrupted. Trying again…")
            case .microphone: String(localized: "Microphone capture was interrupted. Trying again…")
            case .systemAudio: String(localized: "System audio capture was interrupted. Trying again…")
            }
        case .streamResumed(let kind):
            switch kind {
            case .display: String(localized: "Screen capture resumed.")
            case .window: String(localized: "Window capture resumed.")
            case .camera: String(localized: "Camera capture resumed.")
            case .microphone: String(localized: "Microphone capture resumed.")
            case .systemAudio: String(localized: "System audio capture resumed.")
            }
        case .trackLost(let kind):
            switch kind {
            case .display: String(localized: "The screen stopped recording.")
            case .window: String(localized: "The window stopped recording.")
            case .camera: String(localized: "The camera stopped recording. The recording continues without it.")
            case .microphone: String(localized: "The microphone stopped recording. The recording continues without it.")
            case .systemAudio: String(localized: "System audio stopped recording. The recording continues without it.")
            }
        case .screenPaused:
            String(localized: "Screen capture is paused. Still trying to restart it.")
        case .trackPaused(let kind):
            switch kind {
            // Does not happen: a display that is not the only one is lost, not paused.
            case .display: String(localized: "Screen capture is paused. Still trying to restart it.")
            case .window: String(localized: "Window capture is paused. Still trying to restart it.")
            case .camera: String(localized: "The camera stopped recording. Still trying to bring it back.")
            case .microphone: String(localized: "The microphone stopped recording. Still trying to bring it back.")
            case .systemAudio: String(localized: "System audio stopped recording. Still trying to bring it back.")
            }
        case .writerFailed(let kind):
            switch kind {
            case .display: String(localized: "Saving the screen failed. Continuing in a new file.")
            case .window: String(localized: "Saving the window failed. Continuing in a new file.")
            case .camera: String(localized: "Saving the camera failed. Continuing in a new file.")
            case .microphone: String(localized: "Saving the microphone failed. Continuing in a new file.")
            case .systemAudio: String(localized: "Saving system audio failed. Continuing in a new file.")
            }
        case .samplesDropped(let kind):
            switch kind {
            case .display: String(localized: "Some screen frames couldn't be saved.")
            case .window: String(localized: "Some window frames couldn't be saved.")
            case .camera: String(localized: "Some camera frames couldn't be saved.")
            case .microphone: String(localized: "Some microphone audio couldn't be saved.")
            case .systemAudio: String(localized: "Some system audio couldn't be saved.")
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
        case .couldNotMoveToTrash:
            String(localized: "The take couldn't be moved to the trash. It stays in your projects folder.")
        case .microphoneSilent:
            String(localized: "The microphone isn't picking up any sound.")
        }
    }
}
