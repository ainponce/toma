// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import ProjectFormat

/// The calm zoom's edits from the Zoom tab (phase 3 design §6, plan 3b decisions 1 and 2): the mode of the selected block,
/// its loupe, and the mode of the automatic blocks.
extension EditorModel {
    /// "Mode" of the selected zoom (`ZoomCommands.setMode`): an automatic block becomes the user's with it.
    func setZoomMode(_ id: String, _ mode: ZoomMode) {
        guard canEdit, let document, let step = ZoomCommands.setMode(document, id: id, mode: mode) else { return }
        perform(step)
    }

    /// "Loupe Size" and "Shape" of the selected zoom (`ZoomCommands.setLoupe`): `nil` leaves a field alone.
    func setLoupe(_ id: String, radius: Double? = nil, shape: LoupeShape? = nil) {
        guard canEdit, let document, let step = ZoomCommands.setLoupe(document, id: id, radius: radius, shape: shape) else { return }
        perform(step)
    }

    /// "Mode" of the automatic zooms: a step of its own that plans nothing (`ZoomCommands.setAutoMode`); while the
    /// automatic zooms are being planned again it joins that plan (`regenerate` writes `/zoom/auto` whole, with the mode),
    /// so the plan that lands does not take it back.
    func setAutoZoomMode(_ mode: ZoomMode) {
        guard canEdit else { return }
        if autoZoomPending != nil {
            changeAutoZoom { $0.mode = mode }
            return
        }
        guard let document, let step = ZoomCommands.setAutoMode(document, mode) else { return }
        perform(step)
    }
}
