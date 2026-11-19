// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat

/// What the Frame tab does to the document (phase 2 design §6.5 and §6.7): the frame around the screen and how the screen
/// fills the stage, each one step.
extension EditorModel {
    /// The frame around the screen (`/style/frame`, `.frame`): none, a macOS window or a device.
    func setFrame(_ frame: WindowFrame) {
        guard let document, let step = StyleCommands.set(document, "/style/frame", frame, label: .frame) else { return }
        perform(step)
    }

    /// Fit, or Follow the Cursor (`/style/reframe`, `.styleReframe`).
    func setReframe(_ reframe: Reframe) {
        guard let document, let step = StyleCommands.setReframe(document, reframe) else { return }
        perform(step)
    }

    /// Whether Follow the Cursor is offered for `document` (`FrameTabRules.reframeOffer`): its content in its format.
    func reframeOffer(of document: EditDocument) -> ReframeOffer {
        let content = contentRatio(of: document)
        return FrameTabRules.reframeOffer(
            contentRatio: content, outputRatio: document.aspect.ratio(contentRatio: content), isDeviceTake: isDeviceTake)
    }
}
