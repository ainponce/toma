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
