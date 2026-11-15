// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import ProjectFormat
import Recording
import os

/// Records takes of what the user chose, one at a time, each into a new project in
/// `environment.projectsFolder`, with the chosen microphone when there is one and it is allowed. Once a
/// stop has closed the take it is saved (`lastSaved`), and the editor opens on it unless
/// `RecorderSettings.afterStop` says to stay. Every take is counted down first (`RecorderSettings.countdown`).
/// While recording, the user can pause the take, mark moments of it, and restart it: the take goes to the
/// trash and a new one starts.
@MainActor @Observable
public final class RecordingController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Counting down before the take: nothing is recorded, nor any project made, until it is over. The
        /// seconds left.
        case countingDown(remaining: Int)
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
    public internal(set) var isUserPaused = false
    /// What the user should know about the current or the last take, oldest first: at most
    /// `maximumNotices`, never the same one twice in a row.
    public internal(set) var notices: [TakeNotice] = []
    /// Why closing the current or the last take failed in part (`TakeNotice.closedWithError`).
    public internal(set) var lastCloseError: (any Error)?
    /// The project of the last take recorded or recovered.
    public internal(set) var lastProjectURL: URL? {
        didSet { defaults.set(lastProjectURL?.path, forKey: Self.lastProjectKey) }
    }
    /// The last take a stop closed and kept: the user's stop or the disk's, also when closing it failed in
    /// part (`closedWithError`). Not a take that was restarted, nor one closed to quit.
    public private(set) var lastSaved: SavedTake?
    /// What the take was asked to record, from the countdown until the controller is idle again. A restart
    /// records it again, and does not change it.
    public private(set) var currentRequest: TakeRequest?
    /// The start waits for the answer to a system permission prompt: the island makes room for it.
    public private(set) var isAskingPermission = false
    /// Goes up by one each time a take starts recording, also the new take of each restart: the teleprompter
    /// goes back to the top of the script when it changes.
    public private(set) var takeSerial = 0

    /// From the moment a take is asked for (its countdown included) until it is closed.
    public var isRecording: Bool { phase != .idle }

    /// Whether the take records a microphone: from the moment it starts with one (also while it starts,
    /// once the permissions say it will) until the microphone is lost or the take ends.
    public private(set) var recordsMicrophone = false

    /// The peak of the microphone's last block, in dBFS, while a take records it; `AudioPeak.silence`
    /// otherwise. Read it as often as it is drawn: it is not observed.
    public var microphoneLevel: Float {
        take?.microphoneMeter?.peakDecibels ?? AudioPeak.silence
    }

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
    /// Confirms what the user just did: a marker written, a pause on, a restarted take in the trash, a
    /// countdown cancelled.
    @ObservationIgnored public var onConfirmation: (IslandConfirmation) -> Void = { _ in }

    private static let lastProjectKey = "lastProjectPath"
    private static let maximumNotices = 6
    /// How often the microphone is checked for silence.
    private static let silenceCheckInterval = Duration.milliseconds(250)
    static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    /// What closing a take found.
    struct ClosedTake {
        /// The take's ID, if its start returned one.
        var takeID: String?
        /// The take started, so something was recorded.
        var opened = true
        /// The take as it was closed, unless closing it failed.
        var record: TakeRecord?
        var error: (any Error)?
    }

    /// What a take holds while it is open.
    struct Take {
        let recording: any TakeRecording
        let package: ProjectPackage
        /// The take's `start()`, which a stop waits for before stopping.
        let starting: Task<String, any Error>
        /// Hears the take's warnings; ends when they do, once the take is closed or has failed to start.
        let warnings: Task<Void, Never>
        /// The take's microphone, metered.
        let microphoneMeter: MeteredSource?
        /// The kind of each of its sources, by track ID: what a saved take says it recorded if closing it
        /// failed before it could say so.
        let trackKinds: [TrackKind]
    }

    /// What happens once a stop has closed its take.
    enum StopOutcome: Equatable {
        /// Quitting or powering off: nothing opens, and the take is not saved for the island.
        case quit
        /// The take is saved (`lastSaved`), and its editor opens if `opensEditor`.
        case save(opensEditor: Bool)

        /// Two stops came for one take: quitting wins, and the editor opens only if both asked for it.
        func joined(with other: StopOutcome?) -> StopOutcome {
            switch (self, other) {
            case (.quit, _), (_, .quit?): .quit
            case (.save(let opens), .save(let otherOpens)?): .save(opensEditor: opens && otherOpens)
            case (.save, nil): self
            }
        }
    }

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored let environment: TakeEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var take: Take?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Closes the take: a stop's, or a restart's until the new take starts.
    @ObservationIgnored var stopTask: Task<Void, Never>?
    /// Set by a stop that came before the take had a recording: the start gives up.
    @ObservationIgnored private var startCancelled = false
    /// The take's pause, resume and marker requests, each sent once the one before has returned.
    @ObservationIgnored var userRequests: Task<Void, Never>?
    /// The pauses and resumes sent to the take that have not returned yet.
    @ObservationIgnored var pendingPauseRequests = 0
    /// Whether the user's pause is on, as the take last accepted it.
    @ObservationIgnored var acceptedUserPause = false
    /// Tells the take's notices when its microphone hears nothing (`SilenceWatch`).
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    /// The current take stopped by itself because the disk is full.
    @ObservationIgnored var autoStopped = false
    /// `stopTask` is a restart closing its take.
    @ObservationIgnored var isRestarting = false
    /// A stop came while a restart closed its take: the restart ends as that stop (`nil`: no stop came), or
    /// as all of them joined (`StopOutcome.joined`).
    @ObservationIgnored var stopDuringRestart: StopOutcome?
    /// The markers the take has written.
    @ObservationIgnored var markersWritten = 0
    private(set) var recordedTime = RecordedTime()

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

    /// Records `selection` with `settings`, once the countdown is over. A microphone that is `.off` is
    /// neither asked for nor missed. Without screen recording the permissions open, and nothing counts down.
    public func startRecording(selection: CaptureSelection, settings: QuickSettings) {
        guard phase == .idle else { return }
        let request = TakeRequest(selection: selection, settings: settings)
        let wanted = wantedPermissions(usesMicrophone: usesMicrophone(request))
        guard RecordingPreflight.evaluate(probe: probe, wanted: wanted).canRecord else {
            openOnboarding()
            return
        }
        begin(request, carrying: [], restarting: false)
    }

    /// Starts a take of `request`, counting down `RecorderSettings.countdown` seconds first (read now, so a
    /// change applies from the next take or restart); `carried` is what the user should still know about the
    /// take it restarts. A restart does not ask for permissions again.
    func begin(_ request: TakeRequest, carrying carried: [TakeNotice], restarting: Bool) {
        startCancelled = false
        currentRequest = request
        // From the countdown on, what was said about the last take no longer applies: its notices go, so a
        // new take that says the same again is heard as new (the island shows new notices).
        notices = carried
        if !carried.contains(.closedWithError) { lastCloseError = nil }
        let countdown = SettingsStore(defaults: defaults).settings.countdown
        setPhase(countdown > 0 ? .countingDown(remaining: countdown) : .starting)
        startTask = Task { await start(request, carrying: carried, countdown: countdown, restarting: restarting) }
    }

    /// Chosen, and the Mac has one.
    private func usesMicrophone(_ request: TakeRequest) -> Bool {
        request.selection.microphone != .off && environment.hasMicrophone()
    }

    /// What the preflight asks about: screen recording, and the microphone when the take uses one. The camera is
    /// not recorded yet (`TakeNotice.cameraNotRecordedYet`).
    private func wantedPermissions(usesMicrophone: Bool) -> Set<PermissionKind> {
        usesMicrophone ? [.screenRecording, .microphone] : [.screenRecording]
    }

    /// The notices of the take start as `carried`, which stay whether or not it starts.
    private func start(_ request: TakeRequest, carrying carried: [TakeNotice], countdown: Int, restarting: Bool) async {
        let wantsMicrophone = request.selection.microphone != .off
        let usesMicrophone = usesMicrophone(request)
        // Never asked: the system asks now, while the countdown shows its first second, and the take
        // starts with the answer.
        if !restarting, usesMicrophone, probe.state(of: .microphone) == .notDetermined {
            isAskingPermission = true
            _ = await probe.request(.microphone)
            isAskingPermission = false
        }
        // Task 17a: `takeWillStart` goes here, once the permissions are answered and before the countdown;
        // a restart skips it, as it skips the permissions.

        // A stop during the countdown cancels this task: the wait in progress ends at once.
        do {
            for remaining in stride(from: countdown, to: 0, by: -1) {
                guard !startCancelled else { throw CancellationError() }
                try await environment.sleep(.seconds(1))
                guard !startCancelled, !Task.isCancelled else { throw CancellationError() }
                if remaining > 1 { setPhase(.countingDown(remaining: remaining - 1)) }
            }
        } catch {
            // Stopped while counting down: nothing was made.
            setPhase(.idle)
            onConfirmation(.countdownCancelled)
            return
        }
        let preflight = RecordingPreflight.evaluate(probe: probe, wanted: wantedPermissions(usesMicrophone: usesMicrophone))
        guard preflight.canRecord, !startCancelled else {
            setPhase(.idle)
            // Screen recording was turned off meanwhile.
            if !startCancelled { openOnboarding() }
            return
        }
        // What the take is about to record, until its sources say (`attempt`).
        recordsMicrophone = preflight.recordMicrophone
        setPhase(.starting)

        if wantsMicrophone, !usesMicrophone {
            addNotice(.noMicrophone)
        } else if usesMicrophone, !preflight.recordMicrophone {
            addNotice(.microphoneAccessOff)
        }
        // The camera is only a preview in this version: the take goes on without it.
        if request.selection.camera != .off { addNotice(.cameraNotRecordedYet) }

        var request = request
        while true {
            switch await attempt(request, granted: preflight.granted) {
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
        take = Take(
            recording: recording, package: package, starting: starting, warnings: warnings, microphoneMeter: prepared.microphoneMeter,
            trackKinds: kinds.sorted { $0.key < $1.key }.map(\.value))
        recordsMicrophone = prepared.microphoneMeter != nil
        environment.termination.takeBegan()

        Self.logger.notice("Starting a take in \(package.url.path, privacy: .public)")
        do {
            _ = try await starting.value
            // A stop that came while starting has the take now, or has already closed it.
            guard stopTask == nil, take?.recording === recording else { return .handedToStop }
            let since = environment.now()
            recordedTime.began(at: since)
            if isPaused { recordedTime.paused(at: since) }
            takeSerial += 1
            setPhase(.recording(since: since))
            if let meter = prepared.microphoneMeter { watchForSilence(of: meter, in: recording) }
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

    /// The user's stop (Stop, the shortcut, the menu): the take is saved, and its editor opens if
    /// `RecorderSettings.afterStop`, read now, says so.
    public func stopRecording() {
        let outcome = savingAsTheSettingsSay()
        Task { await stop(outcome) }
    }

    /// Closes the take, if any, and returns once it is closed; a stop already in progress is waited for, and
    /// so is a start still checking permissions or creating the project, which then gives up. A countdown
    /// ends at once, without waiting for the second in progress, and nothing is recorded. A restart still
    /// closing its take ends as this stop: the take is kept and no new one starts. Safe to call at any
    /// time, also while quitting. With `openingEditor` the take is saved and opened; without it (quitting)
    /// it is neither.
    public func stop(openingEditor: Bool) async {
        await stop(openingEditor ? .save(opensEditor: true) : .quit)
    }

    /// Saving the take, opening its editor if `RecorderSettings.afterStop` says so.
    func savingAsTheSettingsSay() -> StopOutcome {
        .save(opensEditor: SettingsStore(defaults: defaults).settings.afterStop == .openEditor)
    }

    private func stop(_ outcome: StopOutcome) async {
        if let stopTask {
            if isRestarting { stopDuringRestart = outcome.joined(with: stopDuringRestart) }
            await stopTask.value
            return
        }
        guard let take else {
            switch phase {
            case .countingDown:
                startCancelled = true
                startTask?.cancel()
                await startTask?.value
            case .starting:
                startCancelled = true
                await startTask?.value
            case .idle, .recording, .stopping:
                break
            }
            return
        }
        let task = Task { await close(take, as: outcome) }
        stopTask = task
        await task.value
    }

    private func close(_ take: Take, as outcome: StopOutcome) async {
        // Before the phase leaves `.recording`.
        let recorded = recordedTime.elapsed(at: environment.now())
        setPhase(.stopping)
        let closed = await closeAndHear(take)
        finish(take, closed, as: outcome, recorded: recorded)
    }

    /// Closes the take, hears all its warnings and the answers to the user's requests sent to it (a marker
    /// it wrote counts); does not let it go.
    func closeAndHear(_ take: Take) async -> ClosedTake {
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
        // The take refuses what comes once it is closed, so they all return.
        await userRequests?.value
        return closed
    }

    /// Says how closing went, lets the take go and goes back to idle. A take that recorded something is
    /// the last project and, unless closed to quit, saved for the island with the time it had `recorded`;
    /// its editor opens if `outcome` says so.
    func finish(_ take: Take, _ closed: ClosedTake, as outcome: StopOutcome, recorded: Duration) {
        if let error = closed.error {
            lastCloseError = error
            addNotice(.closedWithError)
        }
        let markers = markersWritten
        endTake()
        stopTask = nil
        guard closed.opened else { return }
        lastProjectURL = take.package.url
        guard case .save(let opensEditor) = outcome else { return }
        lastSaved = SavedTake(
            projectURL: take.package.url, duration: recorded, markers: markers,
            trackKinds: closed.record?.tracks.map(\.kind) ?? take.trackKinds, openedEditor: opensEditor)
        if opensEditor { openEditor(take.package.url, closed.takeID) }
    }

    /// The take stopped by itself because the disk is full: closed like a stop from the menu, unless it was
    /// let go already (a later take is not this call's to stop).
    private func diskStopped(_ recording: any TakeRecording) async {
        guard take?.recording === recording else { return }
        autoStopped = true
        await stop(savingAsTheSettingsSay())
    }

    /// Releases what the take held once it is closed (or failed to start), and goes back to idle.
    private func endTake() {
        releaseTake()
        setPhase(.idle)
    }

    func releaseTake() {
        isPaused = false
        isUserPaused = false
        acceptedUserPause = false
        pendingPauseRequests = 0
        recordsMicrophone = false
        autoStopped = false
        markersWritten = 0
        userRequests = nil
        silenceWatch?.cancel()
        silenceWatch = nil
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

    // MARK: - Other actions

    public func openLastProject() {
        guard let lastProjectURL, hasLastProject else { return }
        openEditor(lastProjectURL, nil)
    }

    /// A project was recovered: it becomes the last project.
    public func noteRecovered(_ url: URL) {
        lastProjectURL = url
    }

    // MARK: - Microphone

    /// Every `silenceCheckInterval`, while `recording` is the take, tells `SilenceWatch` how loud `meter`
    /// is and how long the take has recorded: `microphoneSilent` comes once if it hears nothing, and goes
    /// once it hears something.
    private func watchForSilence(of meter: MeteredSource, in recording: any TakeRecording) {
        silenceWatch?.cancel()
        silenceWatch = Task { [weak self] in
            var watch = SilenceWatch()
            while true {
                try? await Task.sleep(for: Self.silenceCheckInterval)
                guard !Task.isCancelled, let self, take?.recording === recording else { return }
                let recorded = recordedTime.elapsed(at: environment.now())
                switch watch.observe(peakDecibels: meter.peakDecibels, recordedSeconds: Double(recorded.components.seconds)) {
                case .listening:
                    break
                case .silent:
                    addNotice(.microphoneSilent)
                case .heard:
                    notices.removeAll { $0 == .microphoneSilent }
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        let wasRecording = isRecording
        self.phase = phase
        if phase == .idle {
            currentRequest = nil
            recordsMicrophone = false
        }
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
        case .streamInterrupted(let track):
            // That it came back no longer holds.
            notices.removeAll { $0 == .streamResumed(kind(track)) }
            notice = .streamInterrupted(kind(track))
        case .streamRestarted(let track):
            // What it came back from is resolved: the warning goes, and so does the island's icon.
            let resumed = kind(track)
            notices.removeAll { $0 == .streamInterrupted(resumed) || $0 == .trackPaused(resumed) || (resumed == .display && $0 == .screenPaused) }
            notice = .streamResumed(resumed)
        case .trackLost(let track):
            notice = .trackLost(kind(track))
            if kind(track) == .microphone { recordsMicrophone = false }
        case .displayPaused(let track):
            // The only screen of a take recorded in Window mode is its window.
            notice = kind(track) == .window ? .trackPaused(.window) : .screenPaused
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
