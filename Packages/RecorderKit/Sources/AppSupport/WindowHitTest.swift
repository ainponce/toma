// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat

/// A window on the screen, as the window server lists it (`CGWindowListCopyWindowInfo`).
public struct WindowCandidate: Equatable, Sendable {
    /// Its `CGWindowID`.
    public var windowID: UInt32
    public var ownerPID: Int32
    /// The app's name; empty when the window server does not say.
    public var ownerName: String
    /// `nil` when it has none, or this app may not read it (without Screen Recording).
    public var title: String?
    /// In global points, with the origin at the top left of the main display (`kCGWindowBounds`).
    public var frame: Rect
    /// Its window level: 0 for an app's ordinary windows.
    public var layer: Int

    public init(windowID: UInt32, ownerPID: Int32, ownerName: String, title: String?, frame: Rect, layer: Int) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.layer = layer
    }

    /// One entry of `CGWindowListCopyWindowInfo`; `nil` without its number, owner, layer or bounds. An empty
    /// title is none.
    public init?(windowInfo info: [String: Any]) {
        guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        let title = info[kCGWindowName as String] as? String
        self.init(
            windowID: number, ownerPID: pid, ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
            title: title?.isEmpty == false ? title : nil,
            frame: Rect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)),
            layer: layer)
    }
}

/// The window "Choose on Screen" highlights under the pointer, and a click chooses (notch design §5.2).
public enum WindowHitTest {
    /// A window with a side shorter than this is not chosen: a palette, a tooltip, a sliver at the edge.
    public static let minimumSide = 40.0

    /// The window in front at `point` (global points) among `frontToBack` (as the window server lists them, the
    /// front one first): an app's ordinary window (layer 0), not this app's (`excludingPID`), with both sides of
    /// `minimumSide` or more. `nil` over the desktop.
    public static func topmost(at point: CGPoint, in frontToBack: [WindowCandidate], excludingPID: Int32) -> WindowCandidate? {
        frontToBack.first { window in
            window.layer == 0 && window.ownerPID != excludingPID && window.frame.width >= minimumSide
                && window.frame.height >= minimumSide && CursorGeometry.contains(point, window.frame)
        }
    }
}
