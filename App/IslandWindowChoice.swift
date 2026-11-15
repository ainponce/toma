// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import CoreGraphics
import ProjectFormat
import ScreenCaptureKit
import SwiftUI
import os

// Window mode (notch design §5.2 and §5.5): the window chosen, "Choose on Screen", the windows of other desktops
// that can be chosen without going to them, and the suggestion of plan decision 3.

/// The windows of one app on other desktops, as Window mode lists them.
struct AppWindows: Identifiable {
    let appName: String
    let windows: [ShareableWindow]
    var id: String { appName }
    /// The app's process, for its icon.
    var ownerPID: Int32? { windows.first?.ownerPID }
}

/// What the window server says about windows, read on the main thread (each read takes about a millisecond).
enum WindowList {
    /// The windows on the screen now, front to back (`CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)`).
    static func onScreen() -> [WindowCandidate] {
        candidates(CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID))
    }

    /// The window `id` wherever it is (on another desktop, minimized), with its frame now; `nil` once it is closed.
    static func window(_ id: UInt32) -> WindowCandidate? {
        candidates(CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id))).first { $0.windowID == id }
    }

    private static func candidates(_ list: CFArray?) -> [WindowCandidate] {
        (list as? [[String: Any]] ?? []).compactMap(WindowCandidate.init(windowInfo:))
    }
}

/// The windows ScreenCaptureKit can record that are not on the screen now, by app (`WindowCatalog`).
enum OtherDesktopWindows {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Selection")

    /// None without Screen Recording: asking ScreenCaptureKit then would show the system's prompt.
    nonisolated static func read() async -> [AppWindows] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        let windows: [ShareableWindow]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            windows = content.windows.map { window in
                ShareableWindow(
                    windowID: window.windowID, ownerPID: window.owningApplication?.processID ?? -1,
                    appName: window.owningApplication?.applicationName ?? "", title: window.title,
                    frame: Rect(
                        x: Double(window.frame.minX), y: Double(window.frame.minY), width: Double(window.frame.width),
                        height: Double(window.frame.height)),
                    layer: window.windowLayer, isOnScreen: window.isOnScreen)
            }
        } catch {
            logger.error("Cannot list the windows of other desktops: \(String(describing: error), privacy: .public)")
            return []
        }
        return WindowCatalog.otherDesktopWindows(windows, excludingPID: ProcessInfo.processInfo.processIdentifier)
            .map { AppWindows(appName: $0.appName, windows: $0.windows) }
    }
}

extension OpenPanelModel {
    /// The window clicked on the screen, or chosen among the other desktops'.
    func choose(window: WindowCandidate) {
        chosenWindow = window
        selection.windowID = window.windowID
    }

    func choose(window: ShareableWindow) {
        choose(window: WindowCandidate(
            windowID: window.windowID, ownerPID: window.ownerPID, ownerName: window.appName, title: window.title,
            frame: window.frame, layer: window.layer))
    }

    /// Reads the windows of other desktops again.
    func refreshOtherDesktopWindows() async {
        let groups = await OtherDesktopWindows.read()
        otherDesktopWindows = groups
    }

    /// The pixels a window records at, as "1440 × 900": its display's pixels per point at Native, one at Points.
    func pixelSize(of window: WindowCandidate) -> String {
        let center = CGPoint(x: window.frame.x + window.frame.width / 2, y: window.frame.y + window.frame.height / 2)
        let display = displays.first { CursorGeometry.contains(center, $0.info.frame) } ?? displays.first { $0.info.isMain }
        let scale = quick.displayScale == .points ? 1 : display?.info.scale ?? 1
        return formattedSize(width: window.frame.width * scale, height: window.frame.height * scale)
    }
}

/// "Safari — Start", or the app alone when the window has no title.
func windowName(app: String, title: String?) -> String {
    guard let title else { return app }
    return String(format: String(localized: "%1$@ — %2$@", comment: "A window to record: its app, and its title"), app, title)
}

/// The icon of the app that runs `pid`.
@MainActor
func appIcon(pid: Int32?) -> NSImage? {
    pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
}

/// Window mode's column: the window chosen, "Choose on Screen", the windows of other desktops, and why Area or
/// Display may be better.
struct WindowChoiceColumn: View {
    @Bindable var panel: OpenPanelModel
    let send: (IslandEvent) -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let window = panel.chosenWindow {
                ChoiceRow(
                    title: Text(verbatim: windowName(app: window.ownerName, title: window.title)),
                    subtitle: Text(verbatim: panel.pixelSize(of: window)), icon: appIcon(pid: window.ownerPID).map { .image($0) },
                    isChosen: true, choose: {})
                .transition(.opacity)
            }
            Button { send(.beganChoosing) } label: {
                Label("Choose on Screen", systemImage: "macwindow")
            }
            .buttonStyle(GlassButtonStyle())
            if panel.otherDesktopWindows.isEmpty {
                Spacer(minLength: 0)
            } else {
                ColumnSubtitle(text: Text("From Other Desktops"), icon: "rectangle.3.group")
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(panel.otherDesktopWindows) { group in
                            OtherDesktopGroup(group: group, chosenID: panel.selection.windowID) { panel.choose(window: $0) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            Label {
                Text("With many menus, Area or Display works better.")
            } icon: {
                Image(systemName: "info.circle").symbolRenderingMode(.hierarchical)
            }
            .font(.system(size: 11))
            .opacity(0.62)
            .fixedSize(horizontal: false, vertical: true)
            .help(String(localized: "Menus don't appear in a window recording, and popovers may not either."))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: panel.chosenWindow?.windowID)
        // Each time the column shows: the other desktops change while the island is closed.
        .task { await panel.refreshOtherDesktopWindows() }
    }
}

/// One app's windows on other desktops: its icon and name, then a row for each window, by title.
private struct OtherDesktopGroup: View {
    let group: AppWindows
    let chosenID: UInt32?
    let choose: (ShareableWindow) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon = appIcon(pid: group.ownerPID) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(verbatim: group.appName).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .opacity(0.62)
        .padding(.top, 4)
        .padding(.leading, 2)
        ForEach(group.windows, id: \.windowID) { window in
            ChoiceRow(
                title: Text(verbatim: window.title ?? group.appName), isChosen: chosenID == window.windowID, choose: { choose(window) })
        }
    }
}
