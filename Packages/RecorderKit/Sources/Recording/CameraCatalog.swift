// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// A connected camera.
public struct CameraDeviceInfo: Equatable, Sendable {
    /// `AVCaptureDevice.uniqueID`.
    public var uniqueID: String
    public var name: String
    /// An iPhone used as the Mac's camera (Continuity Camera).
    public var isContinuity: Bool
    /// The camera macOS prefers now (`AVCaptureDevice.systemPreferredCamera`): the one last chosen in an app,
    /// or an iPhone that was just mounted.
    public var isSystemPreferred: Bool

    public init(uniqueID: String, name: String, isContinuity: Bool, isSystemPreferred: Bool) {
        self.uniqueID = uniqueID
        self.name = name
        self.isContinuity = isContinuity
        self.isSystemPreferred = isSystemPreferred
    }
}

/// The cameras connected, and which one to use. Listing them needs no permission.
public enum CameraCatalog {
    /// The connected cameras (built-in, Continuity Camera and external), the system's preferred one first, the
    /// others in the system's order. A process without `NSCameraUseContinuityCameraDeviceType` in its
    /// Info.plist (`swift test`, `recorder-dev`) is told an iPhone is a built-in camera: it is listed all the
    /// same, and `isContinuity` still says what it is.
    public static func devices() -> [CameraDeviceInfo] {
        discover().map(\.info)
    }

    /// `preferred` if it is among `available`; otherwise the system's preferred camera; otherwise the first;
    /// `nil` without cameras.
    public static func pick(preferred: String?, among available: [CameraDeviceInfo]) -> String? {
        if let preferred, available.contains(where: { $0.uniqueID == preferred }) { return preferred }
        return (available.first(where: \.isSystemPreferred) ?? available.first)?.uniqueID
    }

    /// The cameras of `discover()` that can capture now: a suspended one (a MacBook's with the lid closed, or one
    /// with its privacy iris closed) gives no frames, so another one is picked while it is.
    static func usable() -> [(info: CameraDeviceInfo, device: AVCaptureDevice)] {
        discover().filter { !$0.device.isSuspended }
    }

    /// The cameras of `devices()`, in its order, with their devices.
    static func discover() -> [(info: CameraDeviceInfo, device: AVCaptureDevice)] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified
        ).devices
        let preferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        let listed = devices.map { device in
            let info = CameraDeviceInfo(
                uniqueID: device.uniqueID, name: device.localizedName, isContinuity: device.isContinuityCamera,
                isSystemPreferred: device.uniqueID == preferredID)
            return (info: info, device: device)
        }
        return listed.filter(\.info.isSystemPreferred) + listed.filter { !$0.info.isSystemPreferred }
    }
}
