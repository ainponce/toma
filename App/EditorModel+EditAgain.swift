// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation

/// The editor of a project another process held `edit.lock` of as it opened (the `toma` command, the MCP server, another
/// copy of Toma): read-only until the lock is free, then editable again, with the document and its history as the disk
/// has them (`EditSession.openAgainIfFree`; fases 4 y 5, final review I3). It looks again as the window comes to the
/// front, and every few seconds meanwhile.
extension EditorModel {
    /// How often a read-only editor looks at the lock again.
    static let editAgainInterval: Duration = .seconds(3)

    /// Looks once now: the window came to the front.
    func editAgainIfFree() {
        guard !closed, isOpenElsewhere, let session = panelSession else { return }
        Task { _ = await session.openAgainIfFree() }
    }

    /// Looks every `editAgainInterval` while the editor is read-only because of the lock; stops once it is editable, or
    /// closed (`close` cancels it).
    func watchTheLock() {
        guard !closed, isOpenElsewhere, editAgainTask == nil else { return }
        editAgainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.editAgainInterval)
                guard let model = self, !model.closed, model.isOpenElsewhere, let session = model.panelSession else { break }
                if await session.openAgainIfFree() { break }
            }
            self?.editAgainTask = nil
        }
    }
}
