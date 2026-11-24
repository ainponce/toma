// SPDX-License-Identifier: GPL-3.0-or-later
import Render

extension EditorModel {
    /// The export sheet has (or no longer has) a codec with alpha: the preview draws the stage's transparency over a
    /// checkerboard, in the drawable only (4c design §7.1; never in the export).
    func setPreviewShowsAlpha(_ on: Bool) {
        engine?.showsAlpha = on
    }
}
