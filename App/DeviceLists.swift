// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// The capture devices the island lists. Listing them needs no permission.
enum DeviceLists {
    /// The connected microphones, in the system's order.
    static func microphones() -> [(uniqueID: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { (uniqueID: $0.uniqueID, name: $0.localizedName) }
    }
}
