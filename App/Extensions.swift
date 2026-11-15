// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

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
