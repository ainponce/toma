// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport

extension Duration {
    /// For AppKit and SwiftUI animations.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

extension NSScreen {
    /// Its `CGDirectDisplayID`.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension PermissionSettingsOpener {
    /// Opens System Settings with NSWorkspace, and tells a prompt by the app in front changing.
    static func live(probe: any PermissionProbe) -> PermissionSettingsOpener {
        PermissionSettingsOpener(
            probe: probe,
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            openURL: { NSWorkspace.shared.open($0) })
    }
}
