// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import CoreGraphics
import ProjectFormat
import Recording
import os

/// The take environment of the app: projects in `~/Movies/<app>/`, the displays and microphone chosen
/// (`TakePlanner` with `LiveCaptureSourceFactory`), the cursor, the free disk space and the system's sleep
/// and lock.
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
            prepareTake: { package, request, granted in try prepareTake(in: package, request, granted: granted, volume: folder) },
            termination: ProcessTerminationGuard(),
            now: { Date() })
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

    private static func prepareTake(
        in package: ProjectPackage, _ request: TakeRequest, granted: Set<PermissionKind>, volume: URL
    ) throws -> PreparedTake {
        let plan = try TakePlanner.plan(
            request.selection, settings: request.settings, displays: displays(), granted: granted,
            factory: LiveCaptureSourceFactory())
        let coordinator = RecordingCoordinator(
            package: package, sources: plan.sources, input: plan.input,
            diskMonitor: DiskSpaceMonitor(volumeURL: volume), systemActivity: SystemActivityMonitor.live())
        let tracks = plan.sources.map(\.trackID).joined(separator: ", ")
        logger.notice("Recording \(package.url.path, privacy: .public): \(tracks, privacy: .public)")
        return PreparedTake(
            recording: coordinator, microphone: plan.optional.first,
            kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }))
    }
}
