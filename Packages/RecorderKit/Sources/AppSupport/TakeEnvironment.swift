// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Recording

/// What a take is asked to record.
public struct TakeRequest: Equatable, Sendable {
    /// What the user chose, with the microphone `.off` once it has failed to start for this take.
    public var selection: CaptureSelection
    public var settings: QuickSettings

    public init(selection: CaptureSelection, settings: QuickSettings) {
        self.selection = selection
        self.settings = settings
    }
}

/// A take ready to start in its project: what records it, and what the controller needs to know about it.
public struct PreparedTake {
    public var recording: any TakeRecording
    /// The microphone source, when the take has one: it tells whether the take failed because the
    /// microphone did not start (`MicrophoneFallback`).
    public var microphone: StartTrackingSource?
    /// The kind of each track, by track ID, to say which one a warning is about.
    public var kinds: [String: TrackKind]

    public init(recording: any TakeRecording, microphone: StartTrackingSource? = nil, kinds: [String: TrackKind]) {
        self.recording = recording
        self.microphone = microphone
        self.kinds = kinds
    }
}

/// Told when a take begins and ends, once each: from the moment it has sources until it is let go.
public protocol TerminationGuarding: Sendable {
    func takeBegan()
    func takeEnded()
}

/// Keeps macOS from ending the app on its own (sudden or automatic termination) while a take is open.
public struct ProcessTerminationGuard: TerminationGuarding {
    private static let reason = "Recording a take"

    public init() {}

    public func takeBegan() {
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination(Self.reason)
    }

    public func takeEnded() {
        ProcessInfo.processInfo.enableAutomaticTermination(Self.reason)
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}

/// Everything `RecordingController` takes from the system: the app builds the real one, tests their own.
public struct TakeEnvironment {
    /// The folder new projects go to, and recovery looks in.
    public var projectsFolder: URL
    /// Written into every new project.
    public var app: AppInfo
    /// The start of a new project's name (`ProjectFolder.baseName`).
    public var projectNamePrefix: String
    /// Whether the Mac has a microphone to record.
    public var hasMicrophone: @MainActor () -> Bool
    /// Creates a new project: the folder, the prefix, the app and the time it is named after. Called off
    /// the main thread (creating a package syncs it to disk).
    public var createPackage: @Sendable (URL, String, AppInfo, Date) throws -> ProjectPackage
    /// The sources of a take, with the permissions granted, and what records them into the project: the
    /// connected displays and `TakePlanner.plan`, whose `TakePlanError` it throws.
    public var prepareTake: @MainActor (ProjectPackage, TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake
    public var termination: any TerminationGuarding
    public var now: @Sendable () -> Date

    public init(
        projectsFolder: URL,
        app: AppInfo,
        projectNamePrefix: String,
        hasMicrophone: @escaping @MainActor () -> Bool,
        createPackage: @escaping @Sendable (URL, String, AppInfo, Date) throws -> ProjectPackage,
        prepareTake: @escaping @MainActor (ProjectPackage, TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake,
        termination: any TerminationGuarding,
        now: @escaping @Sendable () -> Date
    ) {
        self.projectsFolder = projectsFolder
        self.app = app
        self.projectNamePrefix = projectNamePrefix
        self.hasMicrophone = hasMicrophone
        self.createPackage = createPackage
        self.prepareTake = prepareTake
        self.termination = termination
        self.now = now
    }
}
