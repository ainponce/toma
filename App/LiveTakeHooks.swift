// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat

/// What runs around the app's takes: Do Not Disturb with the shortcut chosen in Settings (`FocusTakeHooks`, read at
/// every start). Task 17b adds the desktop covers and the wallpaper snapshot.
@MainActor
final class LiveTakeHooks: TakeHooks {
    private let focus: FocusTakeHooks

    init(focus: FocusGuard, store: SettingsStore) {
        self.focus = FocusTakeHooks(focus: focus) { store.settings.focusShortcutIdentifier }
    }

    func takeWillStart(_ request: TakeRequest) async -> TakePreparation {
        await focus.takeWillStart(request)
    }

    func takeDidStart(package: ProjectPackage, takeID: String, request: TakeRequest) async {
        await focus.takeDidStart(package: package, takeID: takeID, request: request)
    }

    func takeDidEnd() async {
        await focus.takeDidEnd()
    }
}
