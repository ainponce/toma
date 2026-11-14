// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import CoreGraphics
import Observation
import ProjectFormat
import Recording
import os

/// Records takes of the main display, and of the microphone when it is allowed, one at a time, each into a
/// new project in `~/Movies/<app>/`. Opens the editor on the take once it is closed.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        /// Checking permissions and starting the sources.
        case starting
        case recording(since: Date)
        /// Closing the take.
        case stopping
    }

    private(set) var phase = Phase.idle
    /// Time since the take started, in whole seconds, while recording.
    private(set) var elapsed = Duration.zero
    /// The take is paused (the screen is locked or the Mac sleeps): nothing is recorded until it resumes.
    private(set) var isPaused = false
    /// What the user should know about the current or the last take, oldest first.
    private(set) var warnings: [String] = []
    /// The project of the last take recorded or recovered.
    private(set) var lastProjectURL: URL? {
        didSet { defaults.set(lastProjectURL?.path, forKey: Self.lastProjectKey) }
    }

    /// From the moment a take is asked for until it is closed.
    var isRecording: Bool { phase != .idle }

    var hasLastProject: Bool {
        lastProjectURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Set by the app delegate.
    @ObservationIgnored var openEditor: (URL, String?) -> Void = { _, _ in }
    @ObservationIgnored var openOnboarding: () -> Void = {}
    @ObservationIgnored var recordingStateChanged: () -> Void = {}

    /// The folder new projects go to, and recovery looks in.
    static let projectsFolder = ProjectFolder.defaultURL(appName: AppIdentity.name)
    private static let lastProjectKey = "lastProjectPath"
    private static let maximumWarnings = 6
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    /// What a take holds while it is open.
    private struct Take {
        let coordinator: RecordingCoordinator
        let package: ProjectPackage
        /// The coordinator's `start()`, which a stop waits for before stopping.
        let starting: Task<String, any Error>
    }

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var take: Take?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Set by a stop that came before the take had a coordinator: the start gives up.
    @ObservationIgnored private var startCancelled = false
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(probe: any PermissionProbe = SystemPermissionProbe(), defaults: UserDefaults = .standard) {
        self.probe = probe
        self.defaults = defaults
        lastProjectURL = defaults.string(forKey: Self.lastProjectKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Start

    func startRecording() {
        guard phase == .idle else { return }
        startCancelled = false
        setPhase(.starting)
        Task { await start() }
    }

    private func start() async {
        let hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
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

        warnings = []
        if !hasMicrophone {
            addWarning(String(localized: "No microphone found. Recording without audio."))
        } else if !preflight.recordMicrophone {
            addWarning(String(localized: "Microphone access is off. Recording without audio."))
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
                    addWarning(String(localized: "The microphone couldn't start. Recording the screen without audio."))
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
        let folder = Self.projectsFolder
        let prefix = String(localized: "Recording", comment: "A recording: the start of a new project's name, and the menu bar icon while recording")
        let app = AppInfo(name: AppIdentity.name, version: AppIdentity.version)
        let package: ProjectPackage
        do {
            // Creating the package syncs it to disk: off the main thread.
            package = try await Task.detached {
                try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: Date())
            }.value
        } catch {
            Self.logger.error("Cannot create a project in \(folder.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(error, microphoneFailed: false)
        }
        guard !startCancelled else { return .cancelled }

        // From here to `take = …` nothing suspends, so a stop either cancelled the start above or finds the take.
        let microphone = withMicrophone ? StartTrackingSource(MicrophoneCaptureSource(preferredDeviceUniqueID: nil)) : nil
        let sources: [any CaptureSource] = [DisplayCaptureSource(displayID: CGMainDisplayID())] + (microphone.map { [$0] } ?? [])
        let kinds = Dictionary(uniqueKeysWithValues: sources.map { ($0.trackID, $0.kind) })
        let coordinator = RecordingCoordinator(
            package: package, sources: sources, input: CursorRecorder(),
            diskMonitor: DiskSpaceMonitor(volumeURL: folder), systemActivity: SystemActivityMonitor.live())
        let starting = Task { [weak self] in
            // Stopped for disk space: close it like a stop from the menu.
            await coordinator.setOnAutoStop { _, _ in
                Task { @MainActor in await self?.stop(openingEditor: true) }
            }
            return try await coordinator.start()
        }
        take = Take(coordinator: coordinator, package: package, starting: starting)
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination(Self.terminationReason)
        Task { [weak self] in
            for await warning in coordinator.warnings {
                self?.received(warning, kinds: kinds)
            }
        }

        let ownWindows = NSApp.windows.filter { $0.isVisible && $0.isOnActiveSpace }.count
        // ScreenCaptureKit only knows an app with an on-screen window: with none, excluding this app's
        // windows from the capture may do nothing. The menu bar is never captured anyway.
        Self.logger.notice("Starting a take in \(package.url.path, privacy: .public) with \(ownWindows) visible windows of our own")
        do {
            _ = try await starting.value
            // A stop that came while starting has the take now, or has already closed it.
            guard stopTask == nil, take?.coordinator === coordinator else { return .handedToStop }
            let since = Date()
            setPhase(.recording(since: since))
            startTicker(since: since)
            return .started
        } catch {
            Self.logger.error("The take could not start: \(String(describing: error), privacy: .public)")
            guard stopTask == nil, take?.coordinator === coordinator else { return .handedToStop }
            releaseTake()
            return .failed(error, microphoneFailed: MicrophoneFallback.shouldRetryWithoutMicrophone(after: error, microphone: microphone))
        }
    }

    // MARK: - Stop

    func stopRecording() {
        Task { await stop(openingEditor: true) }
    }

    /// Closes the take, if any, and returns once it is closed; a stop already in progress is waited for.
    /// Safe to call at any time, also while quitting.
    func stop(openingEditor: Bool) async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard let take else {
            // Still checking permissions or creating the project: the start gives up.
            if phase == .starting { startCancelled = true }
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
        do {
            let record = try await take.coordinator.stop()
            Self.logger.notice("Closed \(record.id, privacy: .public) of \(take.package.url.path, privacy: .public)")
        } catch RecordingError.notRecording {
            opened = false  // its start failed: nothing was recorded
        } catch {
            // The take is closed and marked complete; only part of the closing failed.
            Self.logger.error("The take closed with an error: \(String(describing: error), privacy: .public)")
            addWarning(String(localized: "The recording closed with an error: \(userFacingDescription(of: error))"))
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
        ticker?.cancel()
        ticker = nil
        elapsed = .zero
        isPaused = false
        take = nil
        ProcessInfo.processInfo.enableAutomaticTermination(Self.terminationReason)
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    private static let terminationReason = "Recording a take"

    // MARK: - Other actions

    func openLastProject() {
        guard let lastProjectURL, hasLastProject else { return }
        openEditor(lastProjectURL, nil)
    }

    /// A project was recovered: it becomes the last project.
    func noteRecovered(_ url: URL) {
        lastProjectURL = url
    }

    // MARK: - Helpers

    private func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        let wasRecording = isRecording
        self.phase = phase
        if wasRecording != isRecording { recordingStateChanged() }
    }

    private func startTicker(since: Date) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Duration.seconds(Int(Date().timeIntervalSince(since)))
                if elapsed != now { elapsed = now }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func addWarning(_ message: String) {
        guard warnings.last != message else { return }
        warnings.append(message)
        if warnings.count > Self.maximumWarnings { warnings.removeFirst(warnings.count - Self.maximumWarnings) }
    }

    private func received(_ warning: RecordingWarning, kinds: [String: TrackKind]) {
        Self.logger.notice("Warning: \(String(describing: warning), privacy: .public)")
        let microphone: (String) -> Bool = { kinds[$0] == .microphone }
        let message: String
        switch warning {
        case .streamInterrupted(let track):
            message = microphone(track)
                ? String(localized: "Microphone capture was interrupted. Trying again…")
                : String(localized: "Screen capture was interrupted. Trying again…")
        case .streamRestarted(let track):
            message = microphone(track)
                ? String(localized: "Microphone capture resumed.")
                : String(localized: "Screen capture resumed.")
        case .trackLost(let track):
            message = microphone(track)
                ? String(localized: "The microphone stopped recording. The recording continues without it.")
                : String(localized: "The screen stopped recording.")
        case .displayPaused:
            message = String(localized: "Screen capture is paused. Still trying to restart it.")
        case .trackPaused:
            message = String(localized: "The microphone stopped recording. Still trying to bring it back.")
        case .writerFailed(let track):
            message = microphone(track)
                ? String(localized: "Saving the microphone failed. Continuing in a new file.")
                : String(localized: "Saving the screen failed. Continuing in a new file.")
        case .samplesDropped(let track):
            message = microphone(track)
                ? String(localized: "Some microphone audio couldn't be saved.")
                : String(localized: "Some screen frames couldn't be saved.")
        case .manifestWriteFailed:
            message = String(localized: "Couldn't update the project file. Trying again.")
        case .diskLow(let available):
            message = String(localized: "Low disk space: \(available.formatted(.byteCount(style: .file))) left.")
        case .stoppedForDiskSpace:
            message = String(localized: "Recording stopped: the disk is almost full.")
        case .diskSpaceUnknown:
            message = String(localized: "Can't check the free disk space.")
        case .paused:
            isPaused = true  // the menu says so while it lasts
            return
        case .resumed:
            isPaused = false
            return
        }
        addWarning(message)
    }

    private func showStartFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't start recording")
        alert.informativeText = userFacingDescription(of: error)
        NSApp.activate()
        alert.runModal()
    }
}

/// The app's name and version, from its Info.plist.
enum AppIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
