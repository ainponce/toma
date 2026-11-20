// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Recording

/// The app's sources for one take: ScreenCaptureKit displays and windows, an iPhone or iPad connected by cable (its
/// screen and its sound, on one `AVCaptureSession`), the camera of the shared
/// `CameraSessionHost`, the Core Audio microphone and system audio, the cursor (its position and its images), the
/// scroll, when keys are typed and which keys go down (each if the settings say so) and the geometry of what is
/// recorded. Make one for each take:
/// it remembers the windows and the display scales it made the sources with, for `input`.
public final class LiveCaptureSourceFactory: CaptureSourceFactory {
    private let cameraHost: CameraSessionHost
    /// `RecorderSettings.noteKeyActivity`: whether `input` notes when keys are typed.
    private let noteKeyActivity: Bool
    /// Whether `input` records which keys go down: `RecorderSettings.recordKeys`, with Input Monitoring allowed.
    private let recordKeys: Bool
    private let onWindowVisibilityChange: @Sendable (WindowVisibility) -> Void
    /// The windows `window` made, by window ID.
    private var windows: [UInt32: WindowCaptureSource] = [:]
    /// The scale of each display `display` made, by display ID.
    private var displayScales: [UInt32: CaptureScale] = [:]

    /// `cameraHost` is the app's one camera session, also the bubble's (plan decision 28); `noteKeyActivity` is
    /// `RecorderSettings.noteKeyActivity`; `recordKeys` is `RecorderSettings.recordKeys` once Input Monitoring is allowed
    /// (off otherwise); `onWindowVisibilityChange` hears, from any thread, each change of whether a recorded window can
    /// be seen (`WindowGeometryRecorder`).
    public init(
        cameraHost: CameraSessionHost, noteKeyActivity: Bool, recordKeys: Bool = false,
        onWindowVisibilityChange: @escaping @Sendable (WindowVisibility) -> Void
    ) {
        self.cameraHost = cameraHost
        self.noteKeyActivity = noteKeyActivity
        self.recordKeys = recordKeys
        self.onWindowVisibilityChange = onWindowVisibilityChange
    }

    public func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale, area: Rect?, includedWindowIDs: [UInt32]) -> any CaptureSource {
        displayScales[id] = scale
        return DisplayCaptureSource(
            displayID: id, framesPerSecond: framesPerSecond, scale: scale, captureArea: area, includedWindowIDs: includedWindowIDs)
    }

    public func window(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource {
        let window = WindowCaptureSource(windowID: id, framesPerSecond: framesPerSecond, scale: scale)
        windows[id] = window
        return window
    }

    /// A chosen camera that is not connected falls back to the system's preferred one (`CameraCatalog.pick`).
    public func camera(_ choice: DeviceChoice, preset: CameraPreset, framesPerSecond: Int) -> any CaptureSource {
        CameraCaptureSource(
            host: cameraHost, preferredDeviceUniqueID: Self.uniqueID(of: choice, kind: "camera"), preset: preset,
            framesPerSecond: framesPerSecond)
    }

    public func microphone(_ choice: DeviceChoice) -> any CaptureSource {
        Self.microphone(choice)
    }

    /// The microphone a take records for `choice`, also outside a take (the open panel's level): a chosen device that
    /// is not connected falls back to the default input (`MicrophoneCaptureSource`). Never called with `.off`.
    public static func microphone(_ choice: DeviceChoice) -> any CaptureSource {
        MicrophoneCaptureSource(preferredDeviceUniqueID: uniqueID(of: choice, kind: "microphone"))
    }

    /// A tap of its own for each track, which leaves the processes of the other tracks' apps to them; an app's track is
    /// named after the app as the Finder shows it (`NSWorkspace.urlForApplication(withBundleIdentifier:)` and
    /// `FileManager.displayName(atPath:)`), or its bundle ID if it is not installed.
    public func systemAudio(_ track: SystemAudioTrackPlan) -> any CaptureSource {
        ProcessTapSource(
            scope: track.scope, trackID: track.trackID,
            appName: track.appBundleID.map(SystemAudioTracks.installedAppName(bundleID:)),
            otherApplications: track.otherApplications)
    }

    /// The iPhone or iPad `uniqueID`: its screen at `TakePlanner.deviceFramesPerSecond` and its sound, sharing one capture
    /// session. Nothing is asked of the device here (on the main actor): the session finds it, and allows the screens of
    /// iPhones to be seen if the island has not, on its own queue as the take starts; only that same device, ever.
    public func device(uniqueID: String) -> (video: any CaptureSource, audio: any CaptureSource) {
        let video = ExternalDeviceCaptureSource(deviceUniqueID: uniqueID, framesPerSecond: TakePlanner.deviceFramesPerSecond)
        return (video, ExternalDeviceAudioSource(video: video))
    }

    /// The cursor and the images of its shapes, the scroll, with `noteKeyActivity` when keys are typed, with `recordKeys`
    /// which keys go down (`KeyPressRecorder`, alongside the other; the coordinator gives it the raise to 4), the geometry of
    /// `displayIDs` (with the pixels per point their tracks record: one at `.points`, as their first `displayGeometry`
    /// says) and, with a window, where the window `window` made is and whether it can be seen, which goes to
    /// `onWindowVisibilityChange`.
    public func input(windowTrack: (trackID: String, windowID: UInt32)?, displayIDs: [UInt32]) -> any InputRecorder {
        var recorders: [any InputRecorder] = [CursorRecorder(), CursorImageRecorder(), ScrollRecorder()]
        if noteKeyActivity { recorders.append(KeyActivityRecorder()) }
        if recordKeys { recorders.append(KeyPressRecorder()) }
        if !displayIDs.isEmpty {
            let scales = displayScales
            recorders.append(DisplayGeometryRecorder(displayIDs: displayIDs, query: { displayID in
                DisplayGeometryRecorder.liveQuery(displayID).flatMap { geometry in
                    ScreenCapture.recordedPixelScale(displayScale: geometry.scale, scale: scales[displayID] ?? .native)
                        .map { (geometry.frame, $0) }
                }
            }))
        }
        if let windowTrack {
            let window = windows[windowTrack.windowID]
            recorders.append(WindowGeometryRecorder(
                trackID: windowTrack.trackID, windowID: windowTrack.windowID,
                lastCompleteFrame: { window?.lastCompleteFrameTime }, onVisibilityChange: onWindowVisibilityChange))
        }
        return CompositeInputRecorder(recorders)
    }

    /// The device `choice` names; `nil` for the system's default. Never called with `.off`.
    private static func uniqueID(of choice: DeviceChoice, kind: String) -> String? {
        switch choice {
        case .systemDefault: nil
        case .device(let uniqueID): uniqueID
        case .off: preconditionFailure("LiveCaptureSourceFactory: a \(kind) that is off is never made")
        }
    }
}
