// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Recording

/// What a take is asked to record.
public struct TakeRequest: Equatable, Sendable {
    /// What the user chose.
    public var selection: CaptureSelection
    public var settings: QuickSettings
    /// Windows of this app the displays' recording keeps (`DisplayCaptureSource(includedWindowIDs:)`).
    public var includedWindowIDs: [UInt32] = []
    /// The optional sources left out of this take: the kinds that failed to start in the attempt before
    /// (`OptionalSourceFallback`).
    public var skipping: Set<TrackKind> = []
    /// How the camera looks as the take starts (`RecordingCoordinator(cameraStyle:)`).
    public var cameraStyle: CameraStyle = .default

    public init(
        selection: CaptureSelection, settings: QuickSettings, includedWindowIDs: [UInt32] = [], skipping: Set<TrackKind> = [],
        cameraStyle: CameraStyle = .default
    ) {
        self.selection = selection
        self.settings = settings
        self.includedWindowIDs = includedWindowIDs
        self.skipping = skipping
        self.cameraStyle = cameraStyle
    }
}

/// A take ready to start in its project: what records it, and what the controller needs to know about it.
public struct PreparedTake {
    public var recording: any TakeRecording
    /// The sources the take can do without (`TakePlan.optional`): they tell whether the take failed because one
    /// of them did not start (`OptionalSourceFallback`).
    public var optional: [StartTrackingSource] = []
    /// The kind of each track, by track ID, to say which one a warning is about.
    public var kinds: [String: TrackKind]
    /// How much of the encoder's budget the take would use (`TakePlan.load`).
    public var load: EncoderLoadVerdict = .ok(ratio: 0)
    /// The microphone, metered (`TakePlan.microphoneMeter`): how loud it is, while the take records.
    public var microphoneMeter: MeteredSource? = nil

    public init(
        recording: any TakeRecording, optional: [StartTrackingSource] = [], kinds: [String: TrackKind],
        load: EncoderLoadVerdict = .ok(ratio: 0), microphoneMeter: MeteredSource? = nil
    ) {
        self.recording = recording
        self.optional = optional
        self.kinds = kinds
        self.load = load
        self.microphoneMeter = microphoneMeter
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
    /// The sources of a take, with the permissions granted after the start asked for them, and what records them
    /// into the project: the connected displays and `TakePlanner.plan` (with the request's `skipping`,
    /// `includedWindowIDs` and the encoder's budget), whose `TakePlanError` it throws, recorded by a coordinator
    /// that starts with the request's `cameraStyle`.
    public var prepareTake: @MainActor (ProjectPackage, TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake
    public var termination: any TerminationGuarding
    public var now: @Sendable () -> Date
    /// Waits, for the countdown: `Task.sleep` in the app. Throws `CancellationError` once the task waiting
    /// is cancelled (a stop during the countdown).
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        projectsFolder: URL,
        app: AppInfo,
        projectNamePrefix: String,
        hasMicrophone: @escaping @MainActor () -> Bool,
        createPackage: @escaping @Sendable (URL, String, AppInfo, Date) throws -> ProjectPackage,
        prepareTake: @escaping @MainActor (ProjectPackage, TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake,
        termination: any TerminationGuarding,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.projectsFolder = projectsFolder
        self.app = app
        self.projectNamePrefix = projectNamePrefix
        self.hasMicrophone = hasMicrophone
        self.createPackage = createPackage
        self.prepareTake = prepareTake
        self.termination = termination
        self.now = now
        self.sleep = sleep
    }
}
