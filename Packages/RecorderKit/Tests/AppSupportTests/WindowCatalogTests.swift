// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct WindowCatalogTests {
    private static let ownPID: Int32 = 99

    private static func window(
        _ id: UInt32, _ app: String, _ title: String?, pid: Int32, onScreen: Bool, side: Double = 600, layer: Int = 0
    ) -> ShareableWindow {
        ShareableWindow(
            windowID: id, ownerPID: pid, appName: app, title: title, frame: Rect(x: 0, y: 0, width: side, height: side), layer: layer,
            isOnScreen: onScreen)
    }

    @Test func otherDesktopWindowsAreGroupedByApp() {
        let windows = [
            Self.window(1, "Keynote", "Lanzamiento", pid: 10, onScreen: false),
            Self.window(2, "Safari", "Inicio", pid: 11, onScreen: true),
            Self.window(3, "Safari", "Docs", pid: 11, onScreen: false),
            Self.window(4, "Toma", "Editor", pid: Self.ownPID, onScreen: false),
            Self.window(5, "Notas", "Lista", pid: 12, onScreen: false, side: 20),
            Self.window(6, "Finder", nil, pid: 13, onScreen: false),
        ]
        let groups = WindowCatalog.otherDesktopWindows(windows, excludingPID: Self.ownPID)
        #expect(groups.map(\.appName) == ["Keynote", "Safari"])
        #expect(groups.map { $0.windows.map(\.title) } == [["Lanzamiento"], ["Docs"]])
    }

    @Test func otherDesktopWindowsAreSortedAndSkipWhatCannotBeChosen() {
        let windows = [
            Self.window(1, "Safari", "Zeta", pid: 11, onScreen: false),
            Self.window(2, "keynote", "Uno", pid: 10, onScreen: false),
            Self.window(3, "Safari", "Alfa", pid: 11, onScreen: false),
            // Over the menu bar, untitled, and with one side under 40 pt: none can be chosen.
            Self.window(4, "Control Center", "Panel", pid: 14, onScreen: false, layer: 25),
            Self.window(5, "Mail", "", pid: 15, onScreen: false),
            ShareableWindow(
                windowID: 6, ownerPID: 16, appName: "Music", title: "Mini", frame: Rect(x: 0, y: 0, width: 300, height: 39), layer: 0,
                isOnScreen: false),
            // Exactly 40 pt is enough.
            ShareableWindow(
                windowID: 7, ownerPID: 16, appName: "Music", title: "Player", frame: Rect(x: 0, y: 0, width: 40, height: 40), layer: 0,
                isOnScreen: false),
        ]
        let groups = WindowCatalog.otherDesktopWindows(windows, excludingPID: Self.ownPID)
        #expect(groups.map(\.appName) == ["keynote", "Music", "Safari"])
        #expect(groups.map { $0.windows.map(\.windowID) } == [[2], [7], [3, 1]])
        #expect(WindowCatalog.otherDesktopWindows([], excludingPID: Self.ownPID).isEmpty)
    }

    @Test func aSavedWindowIsRestoredOnlyIfItIsStillTheAppsWindow() {
        let safari = WindowOwner(bundleID: "com.apple.Safari", name: "Safari")
        let window = WindowCandidate(
            windowID: 42, ownerPID: 11, ownerName: "Safari", title: "Inicio", frame: Rect(x: 0, y: 0, width: 800, height: 600), layer: 0)
        func restored(_ candidate: WindowCandidate?, bundleID: String?, saved: WindowOwner? = safari) -> WindowCandidate? {
            WindowOwner.restored(candidate, bundleID: bundleID, saved: saved, ownPID: Self.ownPID)
        }
        // The same app's window: restored, whatever its title says now.
        var retitled = window
        retitled.title = "Docs"
        #expect(restored(window, bundleID: "com.apple.Safari") == window)
        #expect(restored(retitled, bundleID: "com.apple.Safari") == retitled)

        // After a restart the number can be another app's, the menu bar's or this app's: none is chosen.
        var other = window
        other.ownerName = "Mensajes"
        #expect(restored(other, bundleID: "com.apple.MobileSMS") == nil)
        var menuBar = window
        menuBar.ownerName = "Window Server"
        menuBar.layer = 24
        #expect(restored(menuBar, bundleID: nil) == nil)
        var own = window
        own.ownerPID = Self.ownPID
        #expect(restored(own, bundleID: "com.apple.Safari") == nil)
        // A closed window, or one saved without its app.
        #expect(restored(nil, bundleID: nil) == nil)
        #expect(restored(window, bundleID: "com.apple.Safari", saved: nil) == nil)

        // An app without a bundle ID is known by its name.
        let tool = WindowOwner(bundleID: nil, name: "Safari")
        #expect(restored(window, bundleID: nil, saved: tool) == window)
        #expect(restored(other, bundleID: nil, saved: tool) == nil)
        #expect(restored(window, bundleID: "com.apple.Safari", saved: tool) == nil)
    }
}
