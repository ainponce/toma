// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectAPI

/// The editor's side of the control socket (fases 4 y 5 design §6.4): a change that `toma` or an agent asks for while
/// this editor has the project open (and so its `edit.lock`) is made here, as the editor's own gestures make it
/// (`perform`, `applyStyle`), so it shows at once and Edit ▸ Undo undoes it; the answer waits for it to be on the disk.
extension EditorModel {
    /// The answer to `request`, for this editor's package (`ControlHandling`). Not handled while the editor opens, after
    /// it closed, or while it cannot edit (open for viewing only: the one with `edit.lock` is another app).
    func control(_ request: ControlRequest) async -> ControlResponse {
        guard !closed, let session = panelSession else { return .notHandled }
        let editor = ControlEditor(
            session: session,
            project: { [weak self] in self?.overlayProject ?? session.project },
            takeBounds: { [weak self] in self?.takeBounds ?? [:] },
            canEdit: { [weak self] in self.map { !$0.closed && $0.canEdit } ?? false },
            perform: { [weak self] step in self?.perform(step) ?? .refused },
            applyStyle: { [weak self] style, directory in
                await self?.applyStyle(style, imageDirectory: directory).outcome ?? .refused
            },
            stylesFolder: StyleLibrary.defaultDirectory, tomaStyleName: StyleCatalog.toma.name,
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
        return await ControlHandling.handle(request, editor: editor)
    }
}
