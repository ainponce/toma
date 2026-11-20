// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Recording
import os

/// The Replay's environment in the app (fases 4 y 5 design §10, plan 5c): its working package in
/// `~/Library/Caches/dev.toma.Toma/Replay/`, its saves in the projects folder named «Replay <date>», the sources of a take
/// (`LiveTakeEnvironment.sourceFactory`, `TakePlanner` with the encoder's budget) recorded by a `ReplayCoordinator` that
/// watches the free space of the caches' volume, the camera as the settings last left it, the new projects' style, the
/// system's sleep and lock, and the wallpaper of each display it records.
@MainActor
enum LiveReplayEnvironment {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Replay")

    /// The camera is recorded from `cameraHost`, the session the bubble shows, as a take's is.
    static func make(cameraHost: CameraSessionHost, store: SettingsStore) -> ReplayEnvironment {
        let caches = URL.cachesDirectory
        let scratchRoot = ReplayScratch.defaultRoot(cachesDirectory: caches, bundleID: "dev.toma.Toma")
        let app = AppInfo(name: AppIdentity.name, version: AppIdentity.version)
        return ReplayEnvironment(
            scratchRoot: scratchRoot,
            projectsFolder: ProjectFolder.defaultURL(appName: AppIdentity.name),
            namePrefix: String(
                localized: "Replay (project name)", defaultValue: "Replay",
                comment: "A saved replay: the start of its project's name, before its date"),
            displays: { LiveTakeEnvironment.displays() },
            windowDisplay: { windowID in
                // The display with most of the window, as a take's wallpaper is chosen.
                let window = CaptureSelection(mode: .window, displayIDs: [], windowID: windowID, camera: .off, microphone: .off, systemAudio: .off)
                return WallpaperSnapshot.displayIDs(
                    recording: window, displays: LiveTakeEnvironment.displays(), windowFrame: WindowList.window(windowID)?.frame
                ).first
            },
            prepare: { selection, quick, granted, configuration in
                // It never records a window (`ReplaySelection`): nobody hears whether one can be seen.
                let factory = LiveTakeEnvironment.sourceFactory(
                    cameraHost: cameraHost, granted: granted, projectURL: ReplayScratch.package(in: scratchRoot).url,
                    windowVisibilityChanged: { _, _ in })
                let plan = try TakePlanner.plan(
                    selection, settings: quick, displays: LiveTakeEnvironment.displays(), granted: granted, factory: factory,
                    budget: EncoderLoad.budget(defaults: .standard))
                let coordinator = ReplayCoordinator(
                    scratchRoot: scratchRoot, app: app, sources: plan.sources, input: plan.input,
                    diskMonitor: DiskSpaceMonitor(volumeURL: caches), configuration: configuration,
                    cameraStyle: store.settings.cameraStyle)
                let tracks = plan.sources.map(\.trackID).joined(separator: ", ")
                logger.notice("Replay of \(tracks, privacy: .public), the last \(configuration.seconds) s")
                return PreparedReplay(
                    coordinator: coordinator, kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }),
                    load: plan.load)
            },
            editContext: { await EditorModel.editContext() },
            systemActivity: { SystemActivityMonitor.live() },
            didStart: { package, selection in
                // The wallpaper of each display it records, as a take keeps it: a save takes it along.
                let displayIDs = WallpaperSnapshot.displayIDs(
                    recording: selection, displays: LiveTakeEnvironment.displays(), windowFrame: nil)
                let failures = await WallpaperSnapshot.save(displayIDs: displayIDs, in: package, take: ReplayScratch.takeID)
                for (displayID, error) in failures.sorted(by: { $0.key < $1.key }) {
                    logger.error(
                        "No wallpaper of display \(displayID, privacy: .public) for the Replay: \(String(describing: error), privacy: .public)")
                }
            },
            now: { Date() })
    }
}
