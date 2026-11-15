// SPDX-License-Identifier: GPL-3.0-or-later
import Recording

/// The app's sources: ScreenCaptureKit displays, the Core Audio microphone and the cursor.
public final class LiveCaptureSourceFactory: CaptureSourceFactory {
    public init() {}

    public func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource {
        DisplayCaptureSource(displayID: id, framesPerSecond: framesPerSecond, scale: scale)
    }

    /// A chosen device that is not connected falls back to the default input (`MicrophoneCaptureSource`).
    public func microphone(_ choice: DeviceChoice) -> any CaptureSource {
        switch choice {
        case .systemDefault:
            MicrophoneCaptureSource(preferredDeviceUniqueID: nil)
        case .device(let uniqueID):
            MicrophoneCaptureSource(preferredDeviceUniqueID: uniqueID)
        case .off:
            preconditionFailure("LiveCaptureSourceFactory: a microphone that is off is never made")
        }
    }

    public func input(displayIDs: [UInt32]) -> any InputRecorder {
        CursorRecorder()
    }
}
