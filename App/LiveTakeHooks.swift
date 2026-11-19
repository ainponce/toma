// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import os

/// What runs around the app's takes: Do Not Disturb with the shortcut chosen in Settings (`FocusTakeHooks`), the
/// covers over the desktop's icons while "Hide Desktop Icons" is on (`DesktopCoverController`), both read at every
/// start, and a picture of the wallpaper of each display a take records (`WallpaperSnapshot`).
@MainActor
final class LiveTakeHooks: TakeHooks {
    private let focus: FocusTakeHooks
    private let store: SettingsStore
    private let covers = DesktopCoverController()

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Wallpaper")

    init(focus: FocusGuard, store: SettingsStore) {
        self.focus = FocusTakeHooks(focus: focus) { store.settings.focusShortcutIdentifier }
        self.store = store
    }

    /// The shortcut and the covers at the same time; the take records the covers. An iPhone's take records nothing of
    /// the Mac's screen: its desktop is left as it is.
    func takeWillStart(_ request: TakeRequest) async -> TakePreparation {
        async let focused = focus.takeWillStart(request)
        let coversDesktop = store.settings.hideDesktopIcons && request.selection.mode != .device
        let coverIDs = coversDesktop ? await covers.show() : []
        var preparation = await focused
        preparation.includedWindowIDs += coverIDs
        return preparation
    }

    /// The take keeps the wallpaper of each display it records (in Window mode, the one with the window now), as the
    /// current desktop shows it (`WallpaperSnapshot.save`). Each capture has `captureTimeLimit`, so a stop, which waits
    /// for this, waits that long at most for each display. One that cannot be taken in time or saved is logged, and the
    /// take goes on.
    func takeDidStart(package: ProjectPackage, takeID: String, request: TakeRequest) async {
        await focus.takeDidStart(package: package, takeID: takeID, request: request)
        let window = request.selection.mode == .window ? request.selection.windowID.flatMap(WindowList.window) : nil
        let displayIDs = WallpaperSnapshot.displayIDs(
            recording: request.selection, displays: LiveTakeEnvironment.displays(), windowFrame: window?.frame)
        let failures = await WallpaperSnapshot.save(displayIDs: displayIDs, in: package, take: takeID)
        for (displayID, error) in failures.sorted(by: { $0.key < $1.key }) {
            Self.logger.error(
                "No wallpaper of display \(displayID, privacy: .public) for \(takeID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func takeDidEnd() async {
        covers.hide()
        await focus.takeDidEnd()
    }
}
