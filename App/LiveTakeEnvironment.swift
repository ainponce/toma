// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import CoreGraphics
import ProjectFormat
import Recording
import os

/// The take environment of the app: projects in `~/Movies/<app>/`, the main display and the default
/// microphone, the cursor, the free disk space and the system's sleep and lock.
@MainActor
enum LiveTakeEnvironment {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    static func make() -> TakeEnvironment {
        let folder = ProjectFolder.defaultURL(appName: AppIdentity.name)
        return TakeEnvironment(
            projectsFolder: folder,
            app: AppInfo(name: AppIdentity.name, version: AppIdentity.version),
            projectNamePrefix: String(localized: "Recording", comment: "A recording: the start of a new project's name, and the menu bar icon while recording"),
            hasMicrophone: { AVCaptureDevice.default(for: .audio) != nil },
            createPackage: { folder, prefix, app, now in
                try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: now)
            },
            prepareTake: { package, request in prepareTake(in: package, request, volume: folder) },
            termination: ProcessTerminationGuard(),
            now: { Date() })
    }

    private static func prepareTake(in package: ProjectPackage, _ request: TakeRequest, volume: URL) -> PreparedTake {
        let microphone = request.withMicrophone ? StartTrackingSource(MicrophoneCaptureSource(preferredDeviceUniqueID: nil)) : nil
        let sources: [any CaptureSource] = [DisplayCaptureSource(displayID: CGMainDisplayID())] + (microphone.map { [$0] } ?? [])
        let coordinator = RecordingCoordinator(
            package: package, sources: sources, input: CursorRecorder(),
            diskMonitor: DiskSpaceMonitor(volumeURL: volume), systemActivity: SystemActivityMonitor.live())
        let ownWindows = NSApp.windows.filter { $0.isVisible && $0.isOnActiveSpace }.count
        // ScreenCaptureKit only knows an app with an on-screen window: with none, excluding this app's
        // windows from the capture may do nothing. The menu bar is never captured anyway.
        logger.notice("Recording \(package.url.path, privacy: .public) with \(ownWindows) visible windows of our own")
        return PreparedTake(
            recording: coordinator, microphone: microphone,
            kinds: Dictionary(uniqueKeysWithValues: sources.map { ($0.trackID, $0.kind) }))
    }
}
