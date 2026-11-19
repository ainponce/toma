// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation

/// The name of an undo step, as Edit ▸ Undo and Redo show it ("Undo Split"): the undo labels of design §5.11, one for each
/// `EditLabel`. The switch is whole, so a new label does not build without its name.
func localizedTitle(_ label: EditLabel) -> String {
    switch label {
    case .split: String(localized: "Split", comment: "An undo step: splitting a part at the playhead (Edit ▸ Undo Split)")
    case .delete: String(localized: "Delete", comment: "An undo step: deleting parts or a range (Edit ▸ Undo Delete)")
    case .trim: String(localized: "Trim", comment: "An undo step: trimming a part (Edit ▸ Undo Trim)")
    case .speed: String(localized: "Change Speed", comment: "An undo step: a part's speed (Edit ▸ Undo Change Speed)")
    case .zoomAdd: String(localized: "Add Zoom", comment: "An undo step: a zoom added (Edit ▸ Undo Add Zoom)")
    case .zoomMove: String(localized: "Move Zoom", comment: "An undo step: a zoom moved or trimmed on the timeline")
    case .zoomChange: String(localized: "Change Zoom", comment: "An undo step: a zoom's depth, focus or animation")
    case .zoomDelete: String(localized: "Delete Zoom", comment: "The Zoom tab: a button")
    case .zoomRegenerate: String(localized: "Regenerate Zooms", comment: "An undo step: the automatic zooms planned again")
    case .background: String(localized: "Change Background", comment: "An undo step: the background")
    case .padding: String(localized: "Change Padding", comment: "An undo step: the padding around the screen")
    case .cornerRadius: String(localized: "Change Corners", comment: "An undo step: the screen's corners")
    case .shadow: String(localized: "Change Shadow", comment: "An undo step: the screen's shadow")
    case .frame: String(localized: "Change Frame", comment: "An undo step: the frame around the screen")
    case .cursor: String(localized: "Change Cursor", comment: "An undo step: the cursor's look")
    case .camera: String(localized: "Change Camera", comment: "An undo step: the camera bubble or its changes")
    case .screen: String(localized: "Change Screen", comment: "An undo step: which screen is shown")
    case .volume: String(localized: "Change Volume", comment: "An undo step: a track's volume or mute")
    case .aspect: String(localized: "Change Format", comment: "An undo step: the project's format (16:9, 9:16, 1:1)")
    case .frameRate: String(localized: "Change Frame Rate", comment: "An undo step: the project's frames per second")
    case .applyDefaultStyle: String(localized: "Apply Default Style", comment: "The banner of a project of an earlier version")
    // 1c: the camera's layouts and look, and the named styles.
    case .layoutAdd:
        String(localized: "Add Layout Block", comment: "Undo label (Edit ▸ Undo «…»): a camera layout block was added")
    case .layoutChange:
        String(
            localized: "Change Layout",
            comment: "Undo label (Edit ▸ Undo «…»): a camera layout block's layout, transition or bubble style was changed; also the VoiceOver action on a block")
    case .layoutMove:
        String(localized: "Move Layout Block", comment: "Undo label (Edit ▸ Undo «…»): a camera layout block was moved")
    case .layoutTrim:
        String(localized: "Trim Layout Block", comment: "Undo label (Edit ▸ Undo «…»): an edge of a camera layout block was trimmed")
    case .layoutDelete:
        String(localized: "Delete Layout Block", comment: "Undo label (Edit ▸ Undo «…»): camera layout blocks were deleted")
    case .cameraLayout:
        String(localized: "Change Project Layout", comment: "Undo label (Edit ▸ Undo «…»): the project's camera layout was changed")
    case .cameraSplit:
        String(
            localized: "Change Camera Split",
            comment: "Undo label (Edit ▸ Undo «…»): the camera's side or size in a split screen was changed")
    case .cameraMirror:
        String(localized: "Mirror Camera", comment: "Undo label (Edit ▸ Undo «…»): the camera's mirroring was turned on or off")
    case .cameraBorder:
        String(localized: "Change Camera Border", comment: "Undo label (Edit ▸ Undo «…»): the camera's border width or color was changed")
    case .cameraShadow:
        String(localized: "Change Camera Shadow", comment: "Undo label (Edit ▸ Undo «…»): the camera's shadow was changed")
    case .cameraChangesDeleteAll:
        String(
            localized: "Delete All Camera Changes",
            comment: "Undo label (Edit ▸ Undo «…»): all the camera changes of the recording were deleted")
    case .styleApply:
        String(localized: "Apply a Style", comment: "Undo label (Edit ▸ Undo «…»): a named style was applied to the project")
    // Phase 2 (design §8, plan decision 19).
    case .transcriptCreate:
        String(
            localized: "Transcribe",
            comment: "Undo label (Edit ▸ Undo «…»): the project's speech was transcribed, or transcribed again")
    case .transcriptCut:
        String(
            localized: "Cut Words",
            comment: "Undo label (Edit ▸ Undo «…»): words were cut from the transcription, and their time from the video")
    case .transcriptRestore:
        String(
            localized: "Restore Words",
            comment: "Undo label (Edit ▸ Undo «…»): words cut from the transcription were brought back")
    case .transcriptWord:
        String(localized: "Correct a Word", comment: "Undo label (Edit ▸ Undo «…»): a word of the transcription was corrected")
    case .transcriptBreak:
        String(
            localized: "Start a Caption Here",
            comment: "Undo label (Edit ▸ Undo «…»): a caption was made to start at a word, or no longer")
    case .transcriptFillers:
        String(localized: "Remove Filler Words", comment: "Undo label (Edit ▸ Undo «…»): the filler words (um, uh) were cut")
    case .transcriptPauses:
        String(localized: "Shorten Pauses", comment: "Undo label (Edit ▸ Undo «…»): the long pauses between words were shortened")
    case .captionsShow:
        String(localized: "Show or Hide Captions", comment: "Undo label (Edit ▸ Undo «…»): the captions were shown or hidden")
    case .captionsStyle:
        String(
            localized: "Change Caption Style",
            comment: "Undo label (Edit ▸ Undo «…»): the captions' preset, size, position, capitals or highlight was changed")
    case .cameraHideSilences:
        String(
            localized: "Hide During Silences",
            comment: "Undo label (Edit ▸ Undo «…»): the camera was set to hide while nobody speaks")
    case .cameraBackground:
        String(
            localized: "Change Camera Background",
            comment: "Undo label (Edit ▸ Undo «…»): the background behind the person in the camera was changed")
    case .cameraFraming:
        String(
            localized: "Change Camera Framing",
            comment: "Undo label (Edit ▸ Undo «…»): the part of the camera's picture that is shown was changed")
    case .cameraLook:
        String(
            localized: "Change Camera Color",
            comment: "Undo label (Edit ▸ Undo «…»): the camera's color look or its intensity was changed")
    case .cameraSync:
        String(
            localized: "Change Camera Sync",
            comment: "Undo label (Edit ▸ Undo «…»): the camera's picture was moved earlier or later against the sound")
    case .audioCleanup:
        String(
            localized: "Change Noise Cleanup",
            comment: "Undo label (Edit ▸ Undo «…»): the noise cleanup of a microphone track was changed")
    case .audioNormalize:
        String(
            localized: "Normalize Volume",
            comment: "Undo label (Edit ▸ Undo «…»): the volume normalization was turned on or off")
    case .styleReframe:
        String(
            localized: "Change Screen Framing",
            comment: "Undo label (Edit ▸ Undo «…»): the screen was set to show whole or to follow the cursor")
    case .privacyAdd: String(localized: "Add Blur", comment: "Undo label (Edit ▸ Undo «…»): a blur block was added")
    case .privacyChange:
        String(
            localized: "Change Blur",
            comment: "Undo label (Edit ▸ Undo «…»): a blur block's effect, strength, color or rectangle was changed")
    case .privacyMove:
        String(localized: "Move Blur", comment: "Undo label (Edit ▸ Undo «…»): a blur block was moved on the timeline")
    case .privacyTrim:
        String(localized: "Trim Blur", comment: "Undo label (Edit ▸ Undo «…»): an edge of a blur block was trimmed")
    case .privacyDelete: String(localized: "Delete Blur", comment: "Undo label (Edit ▸ Undo «…»): blur blocks were deleted")
    case .privacyAuto:
        String(
            localized: "Blur Sensitive Data",
            comment: "Undo label (Edit ▸ Undo «…»): the sensitive data found on the screen was blurred")
    case .keysOverlay:
        String(
            localized: "Change Keys on Screen",
            comment: "Undo label (Edit ▸ Undo «…»): how the pressed keys are shown on the output was changed")
    case .speedTyping:
        String(localized: "Speed Up Typing", comment: "Undo label (Edit ▸ Undo «…»): the parts where the user types were sped up")
    }
}

/// Edit ▸ Undo: "Undo" and the name of what it undoes ("Undo Split"), or alone when it is not offered or the step has no
/// name.
func editMenuUndoTitle(_ item: UndoMenuItem) -> String {
    guard let label = item.label else { return String(localized: "Undo", comment: "Edit menu: undoes the last edit") }
    return String(localized: "Undo \(localizedTitle(label))", comment: "Edit menu: undoes the named step (Undo Split)")
}

/// Edit ▸ Redo: "Redo" and the name of what it redoes, or alone.
func editMenuRedoTitle(_ item: UndoMenuItem) -> String {
    guard let label = item.label else { return String(localized: "Redo", comment: "Edit menu: redoes the last undone edit") }
    return String(localized: "Redo \(localizedTitle(label))", comment: "Edit menu: redoes the named step (Redo Split)")
}
