// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// What the screen sources (`DisplayCaptureSource`, `WindowCaptureSource`, `ScreenStreamCapture`) and
/// `DisplayGeometryRecorder` share: which frames carry an image, and how many pixels per point are recorded.
public enum ScreenCapture {
    /// True for a sample whose `SCStreamFrameInfo.status` is `.complete`: the only frames that
    /// carry a new image. Idle, blank, suspended, started and stopped frames are not forwarded.
    public static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// The pixels per point of the recording of a display with `displayScale` pixels per point (`nil`
    /// when unknown): the display's own at `.native`, 1 at `.points`.
    public static func recordedPixelScale(displayScale: Double?, scale: CaptureScale) -> Double? {
        switch scale {
        case .native: displayScale
        case .points: 1
        }
    }

    /// Pixels per point of the display's current mode (2 on Retina), or `nil` if it is not online.
    static func pixelScale(of displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}
