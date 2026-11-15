// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Export
import Foundation
import ProjectFormat
import Recording
import Recovery
import Render

/// A description of `error` to show: this app's errors in the user's language, the system's own text for
/// errors that carry one, and a generic sentence otherwise. Never a type or case name; callers log the
/// error itself.
func userFacingDescription(of error: any Error) -> String {
    if let text = appErrorDescription(error) { return text }
    let bridged = error as NSError
    let systemDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain]
    if bridged.userInfo[NSLocalizedDescriptionKey] != nil || systemDomains.contains(bridged.domain) {
        return bridged.localizedDescription
    }
    return String(localized: "An unexpected error occurred.")
}

private func appErrorDescription(_ error: any Error) -> String? {
    switch error {
    case let error as RecordingError: description(of: error)
    case let error as CaptureSourceError: description(of: error)
    case let error as TakePlanError: description(of: error)
    case let error as WriterError: description(of: error)
    case let error as RecoveryError: description(of: error)
    case let error as LoadedProjectError: description(of: error)
    case let error as ExportError: description(of: error)
    case let error as RenderError: description(of: error)
    case is ProjectPackageError: String(localized: "A file isn't inside the project.")
    case is CancellationError: String(localized: "The operation was canceled.")
    default: nil
    }
}

private func description(of error: RecordingError) -> String {
    switch error {
    case .notEnoughDiskSpace(let available):
        String(localized: "There isn't enough free disk space to record (\(available.formatted(.byteCount(style: .file))) available).")
    case .volumeNotAllowed:
        String(localized: "Recordings can't be saved to a network or synced folder.")
    case .alreadyStarted:
        String(localized: "A recording is already in progress.")
    case .notRecording:
        String(localized: "Nothing is being recorded.")
    case .notCurrentFormatVersion:
        String(localized: "New recordings can't be added to a project saved by another version.")
    }
}

private func description(of error: CaptureSourceError) -> String {
    switch error {
    case .displayNotFound:
        String(localized: "The display isn't available.")
    case .windowNotFound:
        String(localized: "The window can't be found. It may have been closed.")
    case .microphoneNotFound:
        String(localized: "No microphone found.")
    case .sessionConfigurationFailed:
        String(localized: "The capture device couldn't be set up.")
    case .sessionDidNotStart:
        String(localized: "The capture device didn't start.")
    case .cameraNotFound:
        String(localized: "No camera was found.")
    case .cameraFormatUnavailable:
        String(localized: "The camera can't record at the chosen quality.")
    case .cameraDisconnected:
        String(localized: "The camera was disconnected.")
    case .cameraInterrupted:
        String(localized: "The camera stopped: another app is using it, or the lid is closed.")
    case .systemAudioUnavailable(let status):
        String(localized: "System audio can't be recorded (error \(status)).")
    }
}

private func description(of error: TakePlanError) -> String {
    switch error {
    case .noScreenChosen:
        String(localized: "No display is chosen to record.")
    case .displayNotFound:
        String(localized: "The chosen display isn't available.")
    case .notAvailableYet:
        String(localized: "This recording setup isn't available yet.")
    }
}

private func description(of error: WriterError) -> String {
    switch error {
    case .unsupportedFormat:
        String(localized: "The recording's format can't be saved.")
    case .appendFailed:
        String(localized: "Part of the recording couldn't be saved.")
    case .alreadyFinished:
        String(localized: "The recording file was already closed.")
    case .fileExists:
        String(localized: "A recording file with the same name already exists. It was left untouched.")
    }
}

private func description(of error: RecoveryError) -> String {
    switch error {
    case .lockHeld:
        String(localized: "The recording is still in progress.")
    case .anotherTakeRecording:
        String(localized: "Another recording in this project is in progress.")
    case .takeNotFound:
        String(localized: "The recording isn't in this project.")
    case .unsupportedFormatVersion:
        String(localized: "This project was saved by a newer version and can't be opened.")
    case .invalidPath:
        String(localized: "This project has files in unexpected places. It was left untouched.")
    }
}

private func description(of error: LoadedProjectError) -> String {
    switch error {
    case .unsupportedFormatVersion:
        String(localized: "This project was saved by a newer version and can't be opened.")
    case .noTakes:
        String(localized: "This project has no recordings.")
    case .takeNotFound:
        String(localized: "The recording isn't in this project.")
    case .invalidPath:
        String(localized: "This project has files in unexpected places. It was left untouched.")
    }
}

private func description(of error: ExportError) -> String {
    switch error {
    case .cancelled:
        String(localized: "The export was canceled.")
    case .writerFailed:
        String(localized: "The video file couldn't be written.")
    case .noDisplayTrack:
        String(localized: "This recording has no screen to export.")
    case .destinationNotAllowed:
        String(localized: "The video can't be saved there. Choose a folder outside the project.")
    }
}

private func description(of error: RenderError) -> String {
    switch error {
    case .noMetalDevice:
        String(localized: "This Mac has no graphics device to draw the video.")
    case .invalidOutputSize, .targetSizeMismatch, .unsupportedPixelFormat, .metalResourceUnavailable,
         .missingShaderFunction, .textureCreationFailed, .gpuFailed:
        String(localized: "The video couldn't be drawn.")
    }
}
