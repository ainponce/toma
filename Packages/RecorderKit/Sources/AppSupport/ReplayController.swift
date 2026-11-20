// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import Observation
import ProjectFormat
import Recording
import os

/// The Replay (fases 4 y 5 design §10, plan 5c decisions 10 to 17): while it is on, Toma keeps the last N seconds of the
/// sources of the last recording (`ReplaySelection`) in a working package outside the library (`ReplayCoordinator`), and
/// `save()` makes them a new project of the library (`ReplaySaver`).
///
/// It never asks for a permission: without screen recording it stays off and says so (`Problem.noScreenRecording`), and
/// it records the microphone, the camera, system audio, the keys and the focus only when they are allowed already. It
/// never runs with a take: `suspendForTake()` (before the countdown) lets a save in progress finish and deletes the ring,
/// and `resumeAfterTake()` starts afresh. Locking the screen, its displays sleeping or the Mac sleeping delete it too, and
/// unlocking or waking start afresh. Nothing of it outlives the ring: `shutDown()` (quitting) deletes it, and `launch()`
/// deletes whatever a forced quit left, never offered for recovery.
///
/// A problem that stops it (`problem`: the encoder, the disk, sources that do not start) leaves it on in the settings
/// (`isEnabled`) and off until the next take, the user turning it on again, or the next launch.
@MainActor @Observable
public final class ReplayController {
    public enum Phase: Equatable, Sendable {
        /// Not recording: off in the settings, not launched yet, quit, or held off by `problem`.
        case off
        /// Getting its sources and starting them.
        case starting
        /// Recording its ring since this date.
        case on(since: Date)
        /// Recording, and saving its last seconds.
        case saving
        /// On in the settings, and waiting for a take to end, the screen to be unlocked or the Mac to wake: it then starts
        /// afresh.
        case suspended
    }

    public enum Problem: Equatable, Sendable {
        /// Screen recording is not allowed: the Replay never asks for it.
        case noScreenRecording
        /// Its sources would take more than the encoder's budget (`EncoderLoadVerdict.over`).
        case encoderBusy
        /// The volume of the caches is (almost) full: it did not start, or it stopped and was deleted.
        case diskFull
        /// Its sources did not start, the screen alone neither.
        case couldNotStart
        /// The last save failed: nothing was saved.
        case saveFailed
        /// Less than a second was recorded: nothing was saved.
        case tooShort
    }

    public private(set) var phase = Phase.off
    /// Why it is off, or why the last save saved nothing; `nil` once it starts or saves again, or is turned off.
    public private(set) var problem: Problem?
    /// The kind of each track its ring records, in `TrackKind` order; none unless it records.
    public private(set) var recordedKinds: [TrackKind] = []
    /// What the settings remember (`RecorderSettings.replay`).
    private var preferences: ReplayPreferences

    /// On in the settings (`RecorderSettings.replay.enabled`), whether or not it records right now.
    public var isEnabled: Bool { preferences.enabled }
    /// N: the seconds a save keeps (`RecorderSettings.replay.seconds`).
    public var seconds: Int { preferences.seconds }

    /// A save made a project: the island says «Saved: last 30 s». Set by the app delegate.
    @ObservationIgnored public var onSaved: (SavedTake) -> Void = { _ in }
    /// `phase` changed: the app registers the shortcuts again (`HotKeyBindings.activeActions`).
    @ObservationIgnored public var phaseChanged: () -> Void = {}

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Replay")

    /// The ring that records, since it started.
    private struct Ring {
        let coordinator: ReplayCoordinator
        let since: Date
        /// Hears its warnings; ends once it is discarded.
        let warnings: Task<Void, Never>
    }

    private enum Attempt {
        case started(Ring, package: ProjectPackage, kinds: [String: TrackKind])
        /// It cannot start, and starting it again now would not help.
        case refused(Problem)
        /// Its sources did not start: without the optional ones they might.
        case sourcesFailed
    }

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let environment: ReplayEnvironment
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var ring: Ring?
    /// The ring `attempt` is starting, and how it ended if it stopped by itself before its start returned.
    @ObservationIgnored private var startingRing: (coordinator: ReplayCoordinator, end: ReplayEnd?)?
    /// Starts or stops the ring until it is as it should be (`wantsRing`); one at a time.
    @ObservationIgnored private var driver: Task<Void, Never>?
    /// The save in progress: a stop waits for it.
    @ObservationIgnored private var saving: Task<SavedTake?, Never>?
    /// N given to the ring, each change after the one before.
    @ObservationIgnored private var secondsUpdates: Task<Void, Never>?
    /// Hears the system's sleep, wake, lock and unlock.
    @ObservationIgnored private var activity: Task<Void, Never>?
    @ObservationIgnored private var launched = false
    /// The launch removed what was left: the ring may start.
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var takeInProgress = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var locked = false
    /// A problem stopped it: off until the next take, the user turning it on again, or the next launch.
    @ObservationIgnored private var heldOff = false

    public init(probe: any PermissionProbe, environment: ReplayEnvironment, store: SettingsStore) {
        self.probe = probe
        self.environment = environment
        self.store = store
        preferences = store.settings.replay
    }

    // MARK: - Turning it on and off

    /// Deletes what a forced quit left (`ReplayScratch.discardLeftovers` and `ReplaySaver.removeAbandonedSaves`, off the
    /// main thread), starts hearing the system's activity, and starts the ring if it is on; returns once it records or
    /// cannot. Once; nothing records before it.
    public func launch() async {
        guard !launched, !isShutDown else { return }
        launched = true
        await Self.removeLeftovers(scratchRoot: environment.scratchRoot, projectsFolder: environment.projectsFolder)
        guard !isShutDown else { return }
        ready = true
        let events = environment.systemActivity()
        activity = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        reconcile()
        await driver?.value
    }

    /// Turns it on or off in the settings, at once: on, it starts (again, after a problem); off, the ring is deleted (once
    /// a save in progress has finished).
    public func setEnabled(_ enabled: Bool) {
        preferences.enabled = enabled
        var settings = store.settings
        settings.replay.enabled = enabled
        store.settings = settings
        heldOff = false
        problem = nil
        reconcile()
    }

    /// N, in the settings and in the ring at once: the next pruning keeps the last `seconds`, and the next save saves them.
    /// Only a length the settings offer (`ReplayPreferences.validSeconds`).
    public func setSeconds(_ seconds: Int) {
        guard ReplayPreferences.validSeconds.contains(seconds) else { return }
        preferences.seconds = seconds
        var settings = store.settings
        settings.replay.seconds = seconds
        store.settings = settings
        pushSeconds()
    }

    // MARK: - Saving

    /// Saves the last N seconds as a new project «<prefix> <date>» of the library, while it records (`.on`), off the main
    /// thread (`ReplaySaver`); the ring goes on recording. Returns the saved project, also given to `onSaved`, with the
    /// seconds it kept (`SavedTake.replaySeconds`, fewer than N when less was recorded). Nothing while it saves already,
    /// or does not record; with less than a second recorded, nothing and `Problem.tooShort`; a failure is
    /// `Problem.saveFailed`.
    @discardableResult public func save() async -> SavedTake? {
        guard case .on(let since) = phase, let ring, saving == nil else { return nil }
        setPhase(.saving)
        problem = nil
        let coordinator = ring.coordinator
        let task = Task { await self.performSave(coordinator, since: since) }
        saving = task
        return await task.value
    }

    private func performSave(_ coordinator: ReplayCoordinator, since: Date) async -> SavedTake? {
        var saved: SavedTake?
        if await coordinator.buffered() < .seconds(1) {
            problem = .tooShort
        } else {
            let context = await environment.editContext()
            let request = ReplaySaveRequest(
                seconds: preferences.seconds, projectsFolder: environment.projectsFolder,
                name: ProjectFolder.baseName(prefix: environment.namePrefix, date: environment.now()), context: context)
            do {
                let result = try await ReplaySaver.save(from: coordinator, request)
                saved = SavedTake(
                    projectURL: result.projectURL, duration: result.duration, markers: 0, trackKinds: result.trackKinds,
                    openedEditor: false, replaySeconds: max(1, Int(result.duration.seconds.rounded())))
                Self.logger.notice("Saved the Replay as \(result.projectURL.path, privacy: .public)")
            } catch ReplayError.nothingToSave {
                problem = .tooShort
            } catch {
                Self.logger.error("Cannot save the Replay: \(String(describing: error), privacy: .public)")
                // A full disk that stopped the ring meanwhile says more.
                if problem != .diskFull { problem = .saveFailed }
            }
        }
        saving = nil
        if phase == .saving {
            setPhase(ring?.coordinator === coordinator ? .on(since: since) : restingPhase)
        }
        if let saved { onSaved(saved) }
        return saved
    }

    // MARK: - Takes, and quitting

    /// A take is about to start (before its countdown): a save in progress finishes, then the ring is deleted. Returns
    /// once it is gone; nothing starts again until `resumeAfterTake()`.
    public func suspendForTake() async {
        takeInProgress = true
        reconcile()
        await driver?.value
    }

    /// The take is over: if it is on, the ring starts afresh, also after a problem had stopped it.
    public func resumeAfterTake() {
        takeInProgress = false
        heldOff = false
        reconcile()
    }

    /// Toma quits: the ring is deleted (once a save in progress has finished) and nothing starts again. The setting stays.
    public func shutDown() async {
        isShutDown = true
        activity?.cancel()
        activity = nil
        reconcile()
        await driver?.value
    }

    // MARK: - The ring

    /// Whether the ring should record now.
    private var wantsRing: Bool {
        ready && !isShutDown && preferences.enabled && !heldOff && !takeInProgress && !asleep && !locked
    }

    /// The phase without a ring.
    private var restingPhase: Phase {
        let waits = takeInProgress || asleep || locked
        return ready && !isShutDown && preferences.enabled && !heldOff && waits ? .suspended : .off
    }

    private func handle(_ event: SystemActivity) {
        switch event {
        case .willSleep: asleep = true
        case .didWake: asleep = false
        case .screenLocked: locked = true
        case .screenUnlocked: locked = false
        }
        reconcile()
    }

    private func reconcile() {
        guard driver == nil else { return }
        driver = Task { await self.drive() }
    }

    /// Starts or stops the ring until it is as `wantsRing` says, whatever changes meanwhile. A start ends with a ring or
    /// held off by its problem, so this ends.
    private func drive() async {
        while true {
            if wantsRing, ring == nil {
                await startRing()
            } else if !wantsRing, let ring {
                await stopRing(ring)
            } else {
                break
            }
        }
        driver = nil
        if ring == nil { setPhase(restingPhase) }
    }

    private func startRing() async {
        setPhase(.starting)
        problem = nil
        // Never asked: a system prompt would come by itself, out of the blue.
        guard probe.state(of: .screenRecording) == .granted else { return refuse(.noScreenRecording) }
        let settings = store.settings
        let last = settings.selection
        var wanted: Set<PermissionKind> = [.screenRecording]
        if let last {
            if last.microphone != .off { wanted.insert(.microphone) }
            if last.camera != .off { wanted.insert(.camera) }
            if last.systemAudio != .off { wanted.insert(.systemAudio) }
        }
        if settings.recordKeys { wanted.insert(.inputMonitoring) }
        if settings.recordFocus { wanted.insert(.accessibility) }
        let granted = RecordingPreflight.evaluate(probe: probe, wanted: wanted).granted
        var selection = ReplaySelection.make(
            last: last, displays: environment.displays(), windowDisplay: environment.windowDisplay, granted: granted)

        var outcome = await attempt(selection, settings.quick, granted: granted)
        // A broken camera, microphone or system audio must not keep the screen from being recorded: once more, the screen
        // alone.
        if case .sourcesFailed = outcome, selection.camera != .off || selection.microphone != .off || selection.systemAudio != .off {
            Self.logger.notice("Could not start the Replay's sources; again with the screen alone")
            selection.camera = .off
            selection.microphone = .off
            selection.systemAudio = .off
            outcome = await attempt(selection, settings.quick, granted: granted.subtracting([.microphone, .camera, .systemAudio]))
        }
        switch outcome {
        case .started(let ring, let package, let kinds):
            self.ring = ring
            let order = Dictionary(uniqueKeysWithValues: TrackKind.allCases.enumerated().map { ($0.element, $0.offset) })
            recordedKinds = kinds.sorted { (order[$0.value] ?? 0, $0.key) < (order[$1.value] ?? 0, $1.key) }.map(\.value)
            setPhase(.on(since: ring.since))
            // N may have changed while it started.
            pushSeconds()
            await environment.didStart(package, selection)
        case .refused(let problem):
            refuse(problem)
        case .sourcesFailed:
            refuse(.couldNotStart)
        }
    }

    private func attempt(_ selection: CaptureSelection, _ quick: QuickSettings, granted: Set<PermissionKind>) async -> Attempt {
        let prepared: PreparedReplay
        do {
            prepared = try environment.prepare(selection, quick, granted, ReplayConfiguration(seconds: preferences.seconds))
        } catch {
            Self.logger.error("Cannot prepare the Replay: \(String(describing: error), privacy: .public)")
            return .refused(.couldNotStart)
        }
        let coordinator = prepared.coordinator
        if case .over = prepared.load {
            await coordinator.stopAndDiscard()
            return .refused(.encoderBusy)
        }
        await coordinator.setOnAutoStop { [weak self] end in
            Task { @MainActor in self?.stoppedByItself(coordinator, end: end) }
        }
        let warnings = Task {
            for await warning in coordinator.warnings {
                Self.logger.notice("Replay: \(String(describing: warning), privacy: .public)")
            }
        }
        startingRing = (coordinator, nil)
        do {
            let package = try await coordinator.start()
            // The disk filled while it started, and it has deleted itself already.
            if let end = startingRing?.end {
                startingRing = nil
                await warnings.value
                switch end {
                case .diskFull: return .refused(.diskFull)
                }
            }
            startingRing = nil
            return .started(Ring(coordinator: coordinator, since: environment.now(), warnings: warnings), package: package, kinds: prepared.kinds)
        } catch {
            startingRing = nil
            await warnings.value
            Self.logger.error("Cannot start the Replay: \(String(describing: error), privacy: .public)")
            switch error {
            case RecordingError.notEnoughDiskSpace: return .refused(.diskFull)
            // Another Toma records into the working package.
            case ReplayError.scratchInUse: return .refused(.couldNotStart)
            default: return .sourcesFailed
            }
        }
    }

    private func refuse(_ problem: Problem) {
        self.problem = problem
        heldOff = true
        setPhase(.off)
    }

    /// Deletes `ring` once a save in progress has finished; nothing if it went by itself meanwhile.
    private func stopRing(_ ring: Ring) async {
        if let saving { _ = await saving.value }
        guard self.ring?.coordinator === ring.coordinator else { return }
        self.ring = nil
        recordedKinds = []
        await ring.coordinator.stopAndDiscard()
        await ring.warnings.value
    }

    /// The ring stopped and deleted itself (`ReplayEnd`): off, with the problem, until the next take. One whose start has
    /// not returned yet is told to `attempt`.
    private func stoppedByItself(_ coordinator: ReplayCoordinator, end: ReplayEnd) {
        if startingRing?.coordinator === coordinator {
            startingRing?.end = end
            return
        }
        guard ring?.coordinator === coordinator else { return }
        ring = nil
        recordedKinds = []
        switch end {
        case .diskFull: problem = .diskFull
        }
        heldOff = true
        reconcile()
    }

    /// Gives the ring N, after the changes before.
    private func pushSeconds() {
        guard let coordinator = ring?.coordinator else { return }
        let previous = secondsUpdates
        let seconds = preferences.seconds
        secondsUpdates = Task {
            await previous?.value
            await coordinator.setSeconds(seconds)
        }
    }

    private func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        phaseChanged()
    }

    @concurrent private nonisolated static func removeLeftovers(scratchRoot: URL, projectsFolder: URL) async {
        let leftovers = ReplayScratch.discardLeftovers(in: scratchRoot)
        let saves = ReplaySaver.removeAbandonedSaves(in: projectsFolder)
        if !leftovers.isEmpty || !saves.isEmpty {
            logger.notice("Removed what a forced quit left of the Replay: \(leftovers.count + saves.count) items")
        }
    }
}
