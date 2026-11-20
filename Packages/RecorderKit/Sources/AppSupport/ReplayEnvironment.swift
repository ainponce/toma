// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import Recording

/// A Replay ready to start: what records it, and what the controller needs to know about it.
public struct PreparedReplay {
    /// Its ring, not started yet.
    public var coordinator: ReplayCoordinator
    /// The kind of each track, by track ID.
    public var kinds: [String: TrackKind]
    /// How much of the encoder's budget it would use: past the budget (`over`) it does not start.
    public var load: EncoderLoadVerdict

    public init(coordinator: ReplayCoordinator, kinds: [String: TrackKind], load: EncoderLoadVerdict) {
        self.coordinator = coordinator
        self.kinds = kinds
        self.load = load
    }
}

/// Everything `ReplayController` takes from the system: the app builds the real one, tests their own.
public struct ReplayEnvironment {
    /// Where the working package goes (`ReplayScratch.defaultRoot`), which the launch cleans.
    public var scratchRoot: URL
    /// The library's folder: where a save goes, and where the launch removes the saves a forced quit cut short.
    public var projectsFolder: URL
    /// The start of a saved Replay's name (`ProjectFolder.baseName`): «Repetición», from the app.
    public var namePrefix: String
    /// The connected displays.
    public var displays: @MainActor () -> [DisplayInfo]
    /// The display the window with this `CGWindowID` is on now; `nil` if it is gone.
    public var windowDisplay: @MainActor (UInt32) -> UInt32?
    /// The Replay of a selection (`ReplaySelection.make`) with the quick settings and the permissions granted, recorded
    /// into `scratchRoot` with `configuration` (N, the segments): the sources (`TakePlanner.plan`, which throws its
    /// `TakePlanError`), its `ReplayCoordinator` and its load.
    public var prepare: @MainActor (CaptureSelection, QuickSettings, _ granted: Set<PermissionKind>, ReplayConfiguration) throws -> PreparedReplay
    /// What a save writes with: the app, the clock, the ids and the style of the new projects.
    public var editContext: @MainActor () async -> EditContext
    /// The system's sleep, wake, lock and unlock (`SystemActivityMonitor.live()` in the app), asked for once, at launch.
    public var systemActivity: @MainActor () -> AsyncStream<SystemActivity>
    /// The Replay of `CaptureSelection` records now into the working package: the app saves the wallpapers there.
    public var didStart: @MainActor (ProjectPackage, CaptureSelection) async -> Void
    public var now: @Sendable () -> Date

    public init(
        scratchRoot: URL,
        projectsFolder: URL,
        namePrefix: String,
        displays: @escaping @MainActor () -> [DisplayInfo],
        windowDisplay: @escaping @MainActor (UInt32) -> UInt32?,
        prepare: @escaping @MainActor (CaptureSelection, QuickSettings, _ granted: Set<PermissionKind>, ReplayConfiguration) throws -> PreparedReplay,
        editContext: @escaping @MainActor () async -> EditContext,
        systemActivity: @escaping @MainActor () -> AsyncStream<SystemActivity>,
        didStart: @escaping @MainActor (ProjectPackage, CaptureSelection) async -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.scratchRoot = scratchRoot
        self.projectsFolder = projectsFolder
        self.namePrefix = namePrefix
        self.displays = displays
        self.windowDisplay = windowDisplay
        self.prepare = prepare
        self.editContext = editContext
        self.systemActivity = systemActivity
        self.didStart = didStart
        self.now = now
    }
}
