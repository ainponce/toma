// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// A window ScreenCaptureKit can record (`SCWindow`), on this desktop or another.
public struct ShareableWindow: Equatable, Sendable {
    /// Its `CGWindowID`.
    public var windowID: UInt32
    public var ownerPID: Int32
    public var appName: String
    public var title: String?
    /// In global points, with the origin at the top left of the main display.
    public var frame: Rect
    /// Its window level: 0 for an app's ordinary windows.
    public var layer: Int
    /// On the screen now: `false` on another desktop, in another app's full-screen space, minimized or hidden.
    public var isOnScreen: Bool

    public init(windowID: UInt32, ownerPID: Int32, appName: String, title: String?, frame: Rect, layer: Int, isOnScreen: Bool) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

/// The windows Window mode offers without going to them (notch design §5.5, "De otros escritorios").
public enum WindowCatalog {
    /// Of `windows` (`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`), the ones not
    /// on the screen now: on another desktop or in another app's full-screen space (and minimized ones, which cannot
    /// be told apart without private API: recording one says it is hidden). Only an app's ordinary windows (layer 0),
    /// not this app's (`excludingPID`), with both sides of `WindowHitTest.minimumSide` or more and a title, grouped by
    /// app in alphabetical order, and by title within each app.
    public static func otherDesktopWindows(_ windows: [ShareableWindow], excludingPID: Int32) -> [(appName: String, windows: [ShareableWindow])] {
        let offered = windows.filter { window in
            !window.isOnScreen && window.layer == 0 && window.ownerPID != excludingPID
                && window.frame.width >= WindowHitTest.minimumSide && window.frame.height >= WindowHitTest.minimumSide
                && window.title?.isEmpty == false
        }
        let byApp = Dictionary(grouping: offered, by: \.appName)
        return byApp.keys.sorted(by: inOrder).map { app in
            (appName: app, windows: byApp[app, default: []].sorted { inOrder($0.title ?? "", $1.title ?? "") })
        }
    }

    /// Alphabetical, as Finder sorts names; the same names in a fixed order.
    private static func inOrder(_ first: String, _ second: String) -> Bool {
        switch first.localizedStandardCompare(second) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: first < second
        }
    }
}
