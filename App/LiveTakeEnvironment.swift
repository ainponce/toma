// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import CoreGraphics
import ProjectFormat
import Recording
import os

/// The take environment of the app: projects in `~/Movies/<app>/`, the displays, window or area, camera,
/// microphone and system audio chosen (`TakePlanner` with `LiveCaptureSourceFactory`), the cursor and the geometry
/// of what is recorded, the free disk space and the system's sleep and lock.
@MainActor
enum LiveTakeEnvironment {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    /// The camera is recorded from `cameraHost`, the session the bubble shows; `windowVisibilityChanged` hears, on the
    /// main actor, whether the window recorded can be seen (`RecordingController.windowVisibilityChanged`).
    static func make(
        cameraHost: CameraSessionHost, windowVisibilityChanged: @escaping @MainActor (WindowVisibility) -> Void
    ) -> TakeEnvironment {
        let folder = ProjectFolder.defaultURL(appName: AppIdentity.name)
        return TakeEnvironment(
            projectsFolder: folder,
            app: AppInfo(name: AppIdentity.name, version: AppIdentity.version),
            projectNamePrefix: String(localized: "Recording", comment: "A recording: the start of a new project's name, and the menu bar icon while recording"),
            hasMicrophone: { AVCaptureDevice.default(for: .audio) != nil },
            createPackage: { folder, prefix, app, now in
                try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: now)
            },
            prepareTake: { package, request, granted in
                let factory = LiveCaptureSourceFactory(cameraHost: cameraHost) { visibility in
                    Task { @MainActor in windowVisibilityChanged(visibility) }
                }
                return try prepareTake(in: package, request, granted: granted, factory: factory, volume: folder)
            },
            termination: ProcessTerminationGuard(),
            now: { Date() },
            sleep: { duration in try await Task.sleep(for: duration) })
    }

    /// The connected displays, from `NSScreen.screens`.
    static func displays() -> [DisplayInfo] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
            let bounds = CGDisplayBounds(id)
            return DisplayInfo(
                id: id,
                frame: Rect(x: Double(bounds.minX), y: Double(bounds.minY), width: Double(bounds.width), height: Double(bounds.height)),
                scale: Double(screen.backingScaleFactor),
                isMain: id == CGMainDisplayID(),
                maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }
    }

    /// The encoder's budget can be changed in the defaults (`EncoderLoad.budget(defaults:)`).
    private static func prepareTake(
        in package: ProjectPackage, _ request: TakeRequest, granted: Set<PermissionKind>, factory: LiveCaptureSourceFactory,
        volume: URL
    ) throws -> PreparedTake {
        let plan = try TakePlanner.plan(
            request.selection, settings: request.settings, displays: displays(), granted: granted, skipping: request.skipping,
            includedWindowIDs: request.includedWindowIDs, factory: factory, budget: EncoderLoad.budget(defaults: .standard))
        let coordinator = RecordingCoordinator(
            package: package, sources: plan.sources, input: plan.input,
            diskMonitor: DiskSpaceMonitor(volumeURL: volume), systemActivity: SystemActivityMonitor.live(),
            cameraStyle: request.cameraStyle)
        let tracks = plan.sources.map(\.trackID).joined(separator: ", ")
        logger.notice("Recording \(package.url.path, privacy: .public): \(tracks, privacy: .public)")
        return PreparedTake(
            recording: coordinator, optional: plan.optional,
            kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }), load: plan.load,
            microphoneMeter: plan.microphoneMeter)
    }
}
