// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import ProjectFormat
import Recording
import os

/// Records takes of what the user chose, one at a time, each into a new project in
/// `environment.projectsFolder`, with the chosen microphone when there is one and it is allowed. Opens
/// the editor on the take once it is closed. While recording, the user can pause the take, mark moments
/// of it, and restart it: the take goes to the trash and a new one starts.
@MainActor @Observable
public final class RecordingController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Checking permissions and starting the sources.
        case starting
        case recording(since: Date)
        /// Closing the take.
        case stopping
    }

    public private(set) var phase = Phase.idle
    /// The system paused the take (the screen is locked or the Mac sleeps): nothing is recorded until it
    /// resumes. The user's own pause is `isUserPaused`.
    public private(set) var isPaused = false
    /// The user paused the take (`togglePause()`): nothing is recorded until they resume it.
    public private(set) var isUserPaused = false
    /// What the user should know about the current or the last take, oldest first: at most
    /// `maximumNotices`, never the same one twice in a row.
    public private(set) var notices: [TakeNotice] = []
    /// Why closing the current or the last take failed in part (`TakeNotice.closedWithError`).
    public private(set) var lastCloseError: (any Error)?
    /// The project of the last take recorded or recovered.
    public private(set) var lastProjectURL: URL? {
        didSet { defaults.set(lastProjectURL?.path, forKey: Self.lastProjectKey) }
    }

    /// From the moment a take is asked for until it is closed.
    public var isRecording: Bool { phase != .idle }

    public var hasLastProject: Bool {
        lastProjectURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The folder new projects go to, and recovery looks in.
    public var projectsFolder: URL { environment.projectsFolder }

    /// Set by the app delegate.
    @ObservationIgnored public var openEditor: (URL, String?) -> Void = { _, _ in }
    @ObservationIgnored public var openOnboarding: () -> Void = {}
    @ObservationIgnored public var recordingStateChanged: () -> Void = {}
    /// A take could not start, and nobody stopped it: says why.
    @ObservationIgnored public var showStartFailure: (any Error) -> Void = { _ in }

    private static let lastProjectKey = "lastProjectPath"
    private static let maximumNotices = 6
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    /// What closing a take found.
    private struct ClosedTake {
        /// The take's ID, if its start returned one.
        var takeID: String?
        /// The take started, so something was recorded.
        var opened = true
        /// The take as it was closed, unless closing it failed.
        var record: TakeRecord?
        var error: (any Error)?
    }

    /// What a take holds while it is open.
    private struct Take {
        let recording: any TakeRecording
        let package: ProjectPackage
        /// The take's `start()`, which a stop waits for before stopping.
        let starting: Task<String, any Error>
        /// Hears the take's warnings; ends when they do, once the take is closed or has failed to start.
        let warnings: Task<Void, Never>
    }

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let environment: TakeEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var take: Take?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Closes the take: a stop's, or a restart's until the new take starts.
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Set by a stop that came before the take had a recording: the start gives up.
    @ObservationIgnored private var startCancelled = false
    /// What the take was asked to record, from the start until the controller is idle again. A restart
    /// records it again.
    @ObservationIgnored private var currentRequest: TakeRequest?
    /// The take's pause, resume and marker requests, each sent once the one before has returned.
    @ObservationIgnored private var userRequests: Task<Void, Never>?
    /// The current take stopped by itself because the disk is full.
    @ObservationIgnored private var autoStopped = false
    /// `stopTask` is a restart closing its take.
    @ObservationIgnored private var isRestarting = false
    /// A stop came while a restart closed its take: the restart ends as that stop, opening the editor if
    /// every stop that came asked to (`nil`: no stop came). Quitting asks for none, and wins.
    @ObservationIgnored private var stopDuringRestart: Bool?
    private var recordedTime = RecordedTime()

    public init(probe: any PermissionProbe, environment: TakeEnvironment, defaults: UserDefaults = .standard) {
        self.probe = probe
        self.environment = environment
        self.defaults = defaults
        lastProjectURL = defaults.string(forKey: Self.lastProjectKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The time the take in progress has recorded by `date`, in whole seconds and without its pauses;
    /// zero when no take is recording.
    public func elapsed(at date: Date) -> Duration {
        guard case .recording = phase else { return .zero }
        return recordedTime.elapsed(at: date)
    }

    // MARK: - Start

    /// Records `selection` with `settings`. A microphone that is `.off` is neither asked for nor missed.
    public func startRecording(selection: CaptureSelection, settings: QuickSettings) {
        guard phase == .idle else { return }
        begin(TakeRequest(selection: selection, settings: settings), carrying: [])
    }

    /// Starts a take of `request`; `carried` is what the user should still know about the take it restarts.
    private func begin(_ request: TakeRequest, carrying carried: [TakeNotice]) {
        startCancelled = false
        currentRequest = request
        setPhase(.starting)
        startTask = Task { await start(request, carrying: carried) }
    }

    /// The notices of the take start as `carried`, which stay whether or not it starts.
    private func start(_ request: TakeRequest, carrying carried: [TakeNotice]) async {
        let wantsMicrophone = request.selection.microphone != .off
        // Chosen, and the Mac has one.
        let usesMicrophone = wantsMicrophone && environment.hasMicrophone()
        var preflight = RecordingPreflight.evaluate(probe: probe, wantsMicrophone: usesMicrophone)
        guard preflight.canRecord else {
            setPhase(.idle)
            openOnboarding()
            return
        }
        // Never asked: the system asks now, and the take starts with the answer.
        if usesMicrophone, probe.state(of: .microphone) == .notDetermined {
            _ = await probe.request(.microphone)
            preflight = RecordingPreflight.evaluate(probe: probe, wantsMicrophone: usesMicrophone)
        }
        guard preflight.canRecord, !startCancelled else {
            setPhase(.idle)
            return
        }

        notices = carried
        if !carried.contains(.closedWithError) { lastCloseError = nil }
        if wantsMicrophone, !usesMicrophone {
            addNotice(.noMicrophone)
        } else if usesMicrophone, !preflight.recordMicrophone {
            addNotice(.microphoneAccessOff)
        }
        // The camera is only a preview in this version: the take goes on without it.
        if request.selection.camera != .off { addNotice(.cameraNotRecordedYet) }

        var granted: Set<PermissionKind> = [.screenRecording]
        if preflight.recordMicrophone { granted.insert(.microphone) }
        var request = request
        while true {
            switch await attempt(request, granted: granted) {
            case .started, .handedToStop:
                return
            case .cancelled:
                // No take was recorded: nothing said about it applies.
                notices = carried
                setPhase(.idle)
                return
            case .failed(let error, let microphoneFailed):
                // A broken microphone must not keep the screen from being recorded: once, in a new
                // project, without it. The failed project is left as it is.
                if request.selection.microphone != .off, microphoneFailed, !startCancelled {
                    Self.logger.notice("The microphone could not start; recording without it in a new project")
                    addNotice(.microphoneFailedToStart)
                    request.selection.microphone = .off
                    continue
                }
                // No take was recorded: the failure says why, and nothing said about the take applies.
                notices = carried
                setPhase(.idle)
                if !startCancelled { showStartFailure(error) }
                return
            }
        }
    }

    private enum AttemptOutcome {
        /// Recording.
        case started
        /// A stop came first; nothing was recorded and nothing is left to release.
        case cancelled
        /// A stop came while starting: it closes the take.
        case handedToStop
        /// The take did not start and its resources are released. `microphoneFailed`: because the
        /// microphone did not start.
        case failed(any Error, microphoneFailed: Bool)
    }

    /// Creates a new project and starts recording a take of `request` in it.
    private func attempt(_ request: TakeRequest, granted: Set<PermissionKind>) async -> AttemptOutcome {
        let folder = environment.projectsFolder
        let (create, prefix, app, now) = (environment.createPackage, environment.projectNamePrefix, environment.app, environment.now())
        let package: ProjectPackage
        do {
            // Creating the package syncs it to disk: off the main thread.
            package = try await Task.detached { try create(folder, prefix, app, now) }.value
        } catch {
            Self.logger.error("Cannot create a project in \(folder.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(error, microphoneFailed: false)
        }
        guard !startCancelled else {
            // Stopped while the project was being created: nothing was recorded in it.
            removeIfUnused(package)
            return .cancelled
        }

        // From here to `take = …` nothing suspends, so a stop either cancelled the start above or finds the take.
        let prepared: PreparedTake
        do {
            prepared = try environment.prepareTake(package, request, granted)
        } catch {
            // Nothing was recorded in the project.
            Self.logger.error("The take cannot be recorded: \(String(describing: error), privacy: .public)")
            removeIfUnused(package)
            return .failed(error, microphoneFailed: false)
        }
        let recording = prepared.recording
        let kinds = prepared.kinds
        // Both weakly: the coordinator keeps its handler until the take is closed, and in the app it is the
        // recording itself.
        let onAutoStop: @Sendable (TakeRecord, (any Error)?) -> Void = { [weak self, weak recording] _, _ in
            Task { @MainActor in
                guard let recording else { return }
                await self?.diskStopped(recording)
            }
        }
        let starting = Task {
            await recording.setOnAutoStop(onAutoStop)
            return try await recording.start()
        }
        let warnings = Task { [weak self] in
            for await warning in recording.warnings {
                self?.received(warning, from: recording, kinds: kinds)
            }
        }
        take = Take(recording: recording, package: package, starting: starting, warnings: warnings)
        environment.termination.takeBegan()

        Self.logger.notice("Starting a take in \(package.url.path, privacy: .public)")
        do {
            _ = try await starting.value
            // A stop that came while starting has the take now, or has already closed it.
            guard stopTask == nil, take?.recording === recording else { return .handedToStop }
            let since = environment.now()
            recordedTime.began(at: since)
            if isPaused { recordedTime.paused(at: since) }
            setPhase(.recording(since: since))
            return .started
        } catch {
            Self.logger.error("The take could not start: \(String(describing: error), privacy: .public)")
            // Its warnings end with the failed start: every one is heard before the take is let go.
            await warnings.value
            guard stopTask == nil, take?.recording === recording else { return .handedToStop }
            releaseTake()
            return .failed(error, microphoneFailed: MicrophoneFallback.shouldRetryWithoutMicrophone(after: error, microphone: prepared.microphone))
        }
    }

    // MARK: - Stop

    public func stopRecording() {
        Task { await stop(openingEditor: true) }
    }

    /// Closes the take, if any, and returns once it is closed; a stop already in progress is waited for, and
    /// so is a start still checking permissions or creating the project, which then gives up. A restart
    /// still closing its take ends as this stop: the take is kept and no new one starts. Safe to call at
    /// any time, also while quitting.
    public func stop(openingEditor: Bool) async {
        if let stopTask {
            if isRestarting { stopDuringRestart = openingEditor && stopDuringRestart != false }
            await stopTask.value
            return
        }
        guard let take else {
            if phase == .starting {
                startCancelled = true
                await startTask?.value
            }
            return
        }
        let task = Task { await close(take, openingEditor: openingEditor) }
        stopTask = task
        await task.value
    }

    private func close(_ take: Take, openingEditor: Bool) async {
        setPhase(.stopping)
        let closed = await closeAndHear(take)
        finish(take, closed, openingEditor: openingEditor)
    }

    /// Closes the take and hears all its warnings; does not let it go.
    private func closeAndHear(_ take: Take) async -> ClosedTake {
        var closed = ClosedTake()
        // Whichever way the start ends; the start logs its own failure.
        closed.takeID = try? await take.starting.value
        do {
            let record = try await take.recording.stop()
            closed.record = record
            Self.logger.notice("Closed \(record.id, privacy: .public) of \(take.package.url.path, privacy: .public)")
        } catch RecordingError.notRecording {
            closed.opened = false  // its start failed: nothing was recorded
        } catch {
            // The take is closed and marked complete; only part of the closing failed.
            Self.logger.error("The take closed with an error: \(String(describing: error), privacy: .public)")
            closed.error = error
        }
        // Its warnings end once it is closed: every one is heard before the take is let go.
        await take.warnings.value
        return closed
    }

    /// Says how closing went, lets the take go and goes back to idle; opens the editor on the take when asked.
    private func finish(_ take: Take, _ closed: ClosedTake, openingEditor: Bool) {
        if let error = closed.error {
            lastCloseError = error
            addNotice(.closedWithError)
        }
        endTake()
        stopTask = nil
        guard closed.opened else { return }
        lastProjectURL = take.package.url
        if openingEditor { openEditor(take.package.url, closed.takeID) }
    }

    /// The take stopped by itself because the disk is full: closed like a stop from the menu, unless it was
    /// let go already (a later take is not this call's to stop).
    private func diskStopped(_ recording: any TakeRecording) async {
        guard take?.recording === recording else { return }
        autoStopped = true
        await stop(openingEditor: true)
    }

    /// Releases what the take held once it is closed (or failed to start), and goes back to idle.
    private func endTake() {
        releaseTake()
        setPhase(.idle)
    }

    private func releaseTake() {
        isPaused = false
        isUserPaused = false
        autoStopped = false
        userRequests = nil
        recordedTime = RecordedTime()
        take = nil
        environment.termination.takeEnded()
    }

    /// Removes a project of a start that recorded nothing in it.
    private func removeIfUnused(_ package: ProjectPackage) {
        do {
            try ProjectFolder.removeIfUnused(package)
        } catch {
            Self.logger.error("Cannot remove the unused project \(package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Pause, markers and restart

    /// Pauses the take being recorded, or resumes it if the user paused it. The time recorded stops when
    /// the take really pauses (`RecordedTime` follows the take's `paused` and `resumed`).
    public func togglePause() {
        guard case .recording = phase, let recording = take?.recording else { return }
        let pausing = !isUserPaused
        isUserPaused = pausing
        send(to: recording, pausing ? "pause" : "resume") { recording in
            if pausing { try await recording.pause() } else { try await recording.resume() }
        }
    }

    /// Marks this moment of the take being recorded. Nothing is written while the take is paused.
    public func addMarker() {
        guard case .recording = phase, !isUserPaused, !isPaused, let recording = take?.recording else { return }
        send(to: recording, "marker") { recording in _ = try await recording.addMarker() }
    }

    /// Sends `request` once the requests sent before it have returned, so they reach the take in order. A
    /// take that is closing refuses it.
    private func send(
        to recording: any TakeRecording, _ name: String, _ request: @escaping @Sendable (any TakeRecording) async throws -> Void
    ) {
        let previous = userRequests
        userRequests = Task {
            await previous?.value
            do {
                try await request(recording)
            } catch {
                Self.logger.notice("The take refused the \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes the take being recorded without opening it, moves its project to the trash and records a new
    /// take of the same request, in a new project. What the restart could not do is said in the notices:
    /// a take that closed with an error is kept (`closedWithError`), and so is one that could not be moved
    /// (`couldNotMoveToTrash`); the new take starts either way. A take the disk stopped is kept and opened,
    /// and nothing new starts; so does a stop that comes while the take closes.
    public func restartTake() {
        guard case .recording = phase, stopTask == nil, let take, let request = currentRequest else { return }
        isRestarting = true
        stopDuringRestart = nil
        stopTask = Task { await restart(take, request: request) }
    }

    private func restart(_ take: Take, request: TakeRequest) async {
        setPhase(.stopping)
        let closed = await closeAndHear(take)
        isRestarting = false
        // The disk won if it stopped the take, whichever close came first.
        let endedForDiskSpace = autoStopped
            || closed.record?.tracks.contains { $0.segments.contains { $0.endReason == .diskFull } } == true
        if endedForDiskSpace || stopDuringRestart != nil {
            // Kept, as a stop would: the stops that came waited for this one, so the editor opens here, once,
            // if they asked for it (the disk's own stop does), or for the disk when none came. Quitting asks
            // for no editor, also when the disk stopped the take.
            finish(take, closed, openingEditor: stopDuringRestart ?? endedForDiskSpace)
            return
        }
        // From here to the new start nothing suspends, so a stop either came before or finds the new start.
        releaseTake()
        var carried: [TakeNotice] = []
        if let error = closed.error {
            // Closed in part: kept where it is.
            lastCloseError = error
            carried.append(.closedWithError)
            lastProjectURL = take.package.url
        } else if closed.opened {
            do {
                // A rename on the same volume: quick enough for the main actor.
                let trashed = try ProjectTrash.move(take.package, projectsFolder: environment.projectsFolder)
                Self.logger.notice("Moved the restarted take to \(trashed.path, privacy: .public)")
            } catch {
                Self.logger.error("Cannot move \(take.package.url.path, privacy: .public) to the trash: \(String(describing: error), privacy: .public)")
                carried.append(.couldNotMoveToTrash)
                lastProjectURL = take.package.url
            }
        }
        notices = carried
        stopTask = nil
        begin(request, carrying: carried)
    }

    // MARK: - Other actions

    public func openLastProject() {
        guard let lastProjectURL, hasLastProject else { return }
        openEditor(lastProjectURL, nil)
    }

    /// A project was recovered: it becomes the last project.
    public func noteRecovered(_ url: URL) {
        lastProjectURL = url
    }

    // MARK: - Helpers

    private func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        let wasRecording = isRecording
        self.phase = phase
        if phase == .idle { currentRequest = nil }
        if wasRecording != isRecording { recordingStateChanged() }
    }

    private func addNotice(_ notice: TakeNotice) {
        guard notices.last != notice else { return }
        notices.append(notice)
        if notices.count > Self.maximumNotices { notices.removeFirst(notices.count - Self.maximumNotices) }
    }

    private func received(_ warning: RecordingWarning, from recording: any TakeRecording, kinds: [String: TrackKind]) {
        // A take already let go says nothing about the current one.
        guard take?.recording === recording else { return }
        Self.logger.notice("Warning: \(String(describing: warning), privacy: .public)")
        let kind: (String) -> TrackKind = { kinds[$0] ?? .display }
        let notice: TakeNotice
        switch warning {
        case .streamInterrupted(let track): notice = .streamInterrupted(kind(track))
        case .streamRestarted(let track): notice = .streamResumed(kind(track))
        case .trackLost(let track): notice = .trackLost(kind(track))
        case .displayPaused: notice = .screenPaused
        case .trackPaused(let track): notice = .trackPaused(kind(track))
        case .writerFailed(let track): notice = .writerFailed(kind(track))
        case .samplesDropped(let track): notice = .samplesDropped(kind(track))
        case .manifestWriteFailed: notice = .manifestWriteFailed
        case .diskLow(let available): notice = .diskLow(availableBytes: available)
        case .stoppedForDiskSpace:
            autoStopped = true  // heard before the take is let go, whoever closes it
            notice = .stoppedForDiskSpace
        case .diskSpaceUnknown: notice = .diskSpaceUnknown
        case .paused(let reason):
            // The menu says so while it lasts; the user's own pause is `isUserPaused`, set when asked for.
            if reason != RecordingCoordinator.userPauseReason { isPaused = true }
            // One `paused` per pause, whatever paused the take.
            recordedTime.paused(at: environment.now())
            return
        case .resumed:
            isPaused = false
            recordedTime.resumed(at: environment.now())
            return
        }
        addNotice(notice)
    }
}
