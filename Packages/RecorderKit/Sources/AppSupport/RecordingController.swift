// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import ProjectFormat
import Recording
import os

/// Records takes, one at a time, each into a new project in `environment.projectsFolder`, with the
/// microphone when there is one and it is allowed. Opens the editor on the take once it is closed.
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
    /// The take is paused (the screen is locked or the Mac sleeps): nothing is recorded until it resumes.
    public private(set) var isPaused = false
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
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Set by a stop that came before the take had a recording: the start gives up.
    @ObservationIgnored private var startCancelled = false
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

    public func startRecording() {
        guard phase == .idle else { return }
        startCancelled = false
        setPhase(.starting)
        startTask = Task { await start() }
    }

    private func start() async {
        let hasMicrophone = environment.hasMicrophone()
        var preflight = RecordingPreflight.evaluate(probe: probe, wantsMicrophone: hasMicrophone)
        guard preflight.canRecord else {
            setPhase(.idle)
            openOnboarding()
            return
        }
        // Never asked: the system asks now, and the take starts with the answer.
        if hasMicrophone, probe.state(of: .microphone) == .notDetermined {
            _ = await probe.request(.microphone)
            preflight = RecordingPreflight.evaluate(probe: probe, wantsMicrophone: hasMicrophone)
        }
        guard preflight.canRecord, !startCancelled else {
            setPhase(.idle)
            return
        }

        notices = []
        lastCloseError = nil
        if !hasMicrophone {
            addNotice(.noMicrophone)
        } else if !preflight.recordMicrophone {
            addNotice(.microphoneAccessOff)
        }

        var withMicrophone = preflight.recordMicrophone
        while true {
            switch await attempt(withMicrophone: withMicrophone) {
            case .started, .handedToStop:
                return
            case .cancelled:
                setPhase(.idle)
                return
            case .failed(let error, let microphoneFailed):
                // A broken microphone must not keep the screen from being recorded: once, in a new
                // project, with the display alone. The failed project is left as it is.
                if withMicrophone, microphoneFailed, !startCancelled {
                    Self.logger.notice("The microphone could not start; recording the display alone in a new project")
                    addNotice(.microphoneFailedToStart)
                    withMicrophone = false
                    continue
                }
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

    /// Creates a new project and starts recording a take in it.
    private func attempt(withMicrophone: Bool) async -> AttemptOutcome {
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
            do {
                try ProjectFolder.removeIfUnused(package)
            } catch {
                Self.logger.error("Cannot remove the unused project \(package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return .cancelled
        }

        // From here to `take = …` nothing suspends, so a stop either cancelled the start above or finds the take.
        let prepared = environment.prepareTake(package, TakeRequest(withMicrophone: withMicrophone))
        let recording = prepared.recording
        let kinds = prepared.kinds
        let starting = Task { [weak self] in
            // Stopped for disk space: close it like a stop from the menu.
            await recording.setOnAutoStop { _, _ in
                Task { @MainActor in await self?.stop(openingEditor: true) }
            }
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
    /// so is a start still checking permissions or creating the project, which then gives up. Safe to call
    /// at any time, also while quitting.
    public func stop(openingEditor: Bool) async {
        if let stopTask {
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
        // Whichever way the start ends; the start logs its own failure.
        let takeID = try? await take.starting.value
        var opened = true
        var closeError: (any Error)?
        do {
            let record = try await take.recording.stop()
            Self.logger.notice("Closed \(record.id, privacy: .public) of \(take.package.url.path, privacy: .public)")
        } catch RecordingError.notRecording {
            opened = false  // its start failed: nothing was recorded
        } catch {
            // The take is closed and marked complete; only part of the closing failed.
            Self.logger.error("The take closed with an error: \(String(describing: error), privacy: .public)")
            closeError = error
        }
        // Its warnings end once it is closed: every one is heard before the take is let go.
        await take.warnings.value
        if let closeError {
            lastCloseError = closeError
            addNotice(.closedWithError)
        }
        endTake()
        stopTask = nil
        guard opened else { return }
        lastProjectURL = take.package.url
        if openingEditor { openEditor(take.package.url, takeID) }
    }

    /// Releases what the take held once it is closed (or failed to start), and goes back to idle.
    private func endTake() {
        releaseTake()
        setPhase(.idle)
    }

    private func releaseTake() {
        isPaused = false
        recordedTime = RecordedTime()
        take = nil
        environment.termination.takeEnded()
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
        case .stoppedForDiskSpace: notice = .stoppedForDiskSpace
        case .diskSpaceUnknown: notice = .diskSpaceUnknown
        case .paused:
            isPaused = true  // the menu says so while it lasts
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
