// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// Makes the writer of one segment: the file to create and what the track carries.
public typealias WriterFactory = @Sendable (URL, TrackMedia) throws -> any TrackWriting

public struct RecordingConfiguration: Sendable {
    /// Wait before each restart attempt after a stream error; its length is the number of attempts. The
    /// only screen (display or window), a microphone, a camera and system audio then keep trying at the last
    /// interval; any other track is lost.
    public var restartBackoff: [Duration]
    /// How often a video track checks for a static screen and repeats its last frame.
    public var heartbeatInterval: Duration
    /// How often open segment files are ordered on disk with `F_BARRIERFSYNC`.
    public var syncInterval: Duration

    public init(
        restartBackoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        heartbeatInterval: Duration = .milliseconds(500),
        syncInterval: Duration = .seconds(2)
    ) {
        self.restartBackoff = restartBackoff
        self.heartbeatInterval = heartbeatInterval
        self.syncInterval = syncInterval
    }
}

/// Something the user should hear about while a take goes on.
public enum RecordingWarning: Sendable, Equatable {
    /// The capture stream of `track` failed; its segment was closed and a restart is pending.
    case streamInterrupted(track: String)
    /// The stream of `track` is running again, in a new segment.
    case streamRestarted(track: String)
    /// Restarts of `track` were exhausted: it records nothing more in this take. Never sent for the
    /// only screen or for a microphone, a camera or system audio, which keep trying (`displayPaused`,
    /// `trackPaused`).
    case trackLost(track: String)
    /// The only screen of the take, a display or a window, could not be restarted with the configured
    /// attempts; it keeps trying. `streamRestarted` follows when it comes back.
    case displayPaused(track: String)
    /// The microphone, camera or system audio `track` could not be restarted with the configured attempts:
    /// it records nothing until it comes back, and keeps trying at the last interval (a microphone's or a
    /// camera's restart falls back to the default device). `streamRestarted` follows when it does.
    case trackPaused(track: String)
    /// The writer of `track` failed; its segment was closed and the next sample opens a new one.
    case writerFailed(track: String)
    /// `track` could not write `SegmentAccounting.warningCount` samples in a row (its writer
    /// refused them or could not be opened). They are counted in `droppedFrames` of the segment that
    /// refused them, or of the next segment (the last one if no other follows).
    case samplesDropped(track: String)
    /// The manifest could not be written; the change is kept and written again by the next change or
    /// the next sync tick (every `syncInterval`), at the latest when the take closes.
    case manifestWriteFailed
    /// Little free space left on the recording volume.
    case diskLow(availableBytes: Int64)
    /// The take was stopped because the volume is (almost) full.
    case stoppedForDiskSpace
    /// Free space could not be read for three monitor intervals in a row: the take goes on without
    /// the disk-space stop until it can be read again.
    case diskSpaceUnknown
    /// The take is paused: nothing is recorded until `resumed`. `reason` is the `paused` event's
    /// (`willSleep`, `screenLocked` for a lock or for the displays going to sleep, or
    /// `RecordingCoordinator.userPauseReason` for `pause()`): the cause that paused it, not the ones
    /// that came while it was paused.
    case paused(reason: String)
    /// The take records again after `paused`, in new segments.
    case resumed
}

public enum RecordingError: Error, Equatable {
    case notEnoughDiskSpace(availableBytes: Int64)
    case volumeNotAllowed(VolumeEligibility)
    case alreadyStarted
    case notRecording
    /// The package is of this format version, outside `Manifest.recordableFormatVersions` (3 to 5): a take is only
    /// recorded into a package of those, so an older one never gets what its version does not define.
    case notCurrentFormatVersion(Int)
}

/// Records one take: every source into its own track of segment files, plus the event log, the
/// manifest and the recording lock, and closes it cleanly however it ends.
///
/// `idle → starting → recording ⇄ paused → stopping → stopped`. Sleep, screen lock and the user's
/// `pause()` pause every track (closing their segments as `paused`); the take resumes, in new segments,
/// once none of them holds it: wake, unlock and `resume()` each clear only their own cause. A stream
/// or writer failure closes that track's segment and opens a new one once it recovers. The user's
/// `stop()` and the stop for disk space share one closing task, so a take is closed exactly once.
public actor RecordingCoordinator {
    /// The `reason` of the `paused` event of `pause()`.
    public static let userPauseReason = "user"

    /// What a take asks of the system while it records: no idle sleep of the Mac or of the displays.
    /// A display that sleeps on its idle timer would pause the take as if the screen were locked.
    static let takeActivityOptions: ProcessInfo.ActivityOptions = [
        .userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled,
    ]

    private enum State {
        case idle, starting, recording, paused, stopping, stopped
    }

    private enum PauseCause: Hashable {
        case sleep, screenLocked, user
    }

    /// What the user asks of a take in progress.
    private enum UserRequest: Sendable {
        case pause, resume
        case setCameraStyle(CameraStyle)
    }

    /// The work of `activityTask`, one at a time: the system's activity and the user's requests, so a
    /// pause and a lock never interleave. A request names its continuation in `pendingRequests`.
    private enum Command: Sendable {
        case system(SystemActivity)
        case user(UserRequest, id: Int)
    }

    /// The resources of the take being recorded.
    private struct Take {
        let id: String
        let startedAt: Date
        let store: ManifestStore
        let lock: HeldRecordingLock
        let reserve: TakeReserve
        var log: EventLogWriter?
        var diskVerdicts: AsyncStream<DiskSpaceVerdict>.Continuation?
        var activity: (any NSObjectProtocol)?
        var pipelines: [TrackPipeline] = []
        /// The camera's style as the take has it so far: the initial one, then the last `cameraStyle` event
        /// written. `nil` in a take without a camera.
        var cameraStyle: CameraStyle?
        /// The last style asked for while paused, written when the take resumes.
        var pendingCameraStyle: CameraStyle?
    }

    /// The steps of closing a take that are ordered for durability, in the order `closeTake` takes them.
    enum CloseStep: Sendable, Equatable {
        /// `events.jsonl` has its last lines and is full-synced and closed.
        case logClosed
        /// The manifest says the take is `complete` (written, or its write failed and was reported).
        case manifestComplete
        /// The recording lock is released.
        case lockReleased
    }

    private struct CloseOutcome: Sendable {
        var record: TakeRecord
        var error: (any Error)?

        func get() throws -> TakeRecord {
            if let error { throw error }
            return record
        }
    }

    /// Warnings of this take, in order. Finishes when the take is closed (or fails to start).
    public nonisolated let warnings: AsyncStream<RecordingWarning>
    private let warningsContinuation: AsyncStream<RecordingWarning>.Continuation

    private let package: ProjectPackage
    private let sources: [any CaptureSource]
    private let input: any InputRecorder
    private let diskMonitor: DiskSpaceMonitor
    private let systemActivity: AsyncStream<SystemActivity>
    private let configuration: RecordingConfiguration
    private let writerFactory: WriterFactory
    private let clock: @Sendable () -> HostTime
    /// The waits of the maintenance and the disk watchdog, and every track's timers and restart waits.
    private let ticks: RecordingTicks
    /// The camera's style when the take starts, if it has a camera.
    private let initialCameraStyle: CameraStyle?
    private let commands: AsyncStream<Command>
    private let commandsContinuation: AsyncStream<Command>.Continuation

    private var state = State.idle
    private var take: Take?
    private var pauseCauses: Set<PauseCause> = []
    private var closeTask: Task<CloseOutcome, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var autoStopPending = false
    private var onAutoStop: (@Sendable (TakeRecord, (any Error)?) -> Void)?
    /// A write ran out of space or the monitor said stop: the take's reserve was given back.
    private var diskFull = false
    /// The first event-log failure a periodic flush heard, for `stop()` to report.
    private var logFailure: (any Error)?
    /// Runs the `commands`, in order, while recording.
    private var activityTask: Task<Void, Never>?
    /// Passes the system's activity on to `commands`.
    private var systemActivityTask: Task<Void, Never>?
    /// The user's requests not yet answered, by the ID their command carries.
    private var pendingRequests: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextRequestID = 0
    private var maintenanceTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?
    private var diskWatchdog: Task<Void, Never>?
    /// Verdicts received since the watchdog last looked.
    private var diskVerdictCount = 0
    private var diskLowReported = false
    /// Told about each `CloseStep` as `closeTake` takes it; tests set it.
    private var onCloseStep: (@Sendable (CloseStep) -> Void)?

    public init(
        package: ProjectPackage,
        sources: [any CaptureSource],
        input: any InputRecorder,
        diskMonitor: DiskSpaceMonitor,
        systemActivity: AsyncStream<SystemActivity>,
        configuration: RecordingConfiguration = .init(),
        writerFactory: @escaping WriterFactory = { url, media in try FragmentedTrackWriter(url: url, media: media) },
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        ticks: RecordingTicks = .live,
        cameraStyle: CameraStyle? = nil
    ) {
        let ids = sources.map(\.trackID)
        precondition(Set(ids).count == ids.count, "RecordingCoordinator: track IDs must be unique, got \(ids)")
        (warnings, warningsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (commands, commandsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.package = package
        self.sources = sources
        self.input = input
        self.diskMonitor = diskMonitor
        self.systemActivity = systemActivity
        self.configuration = configuration
        self.writerFactory = writerFactory
        self.clock = clock
        self.ticks = ticks
        self.initialCameraStyle = sources.contains { $0.kind == .camera } ? cameraStyle ?? .default : nil
    }

    /// Called once when the take stops by itself because the disk is full, with the closed take and
    /// the first failure of closing it (`nil` when it closed cleanly): the same outcome a later
    /// `stop()` returns or throws. Let go once the take is closed, however it ended.
    public func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord, (any Error)?) -> Void) {
        onAutoStop = handler
    }

    /// For tests: `observer` is told about each `CloseStep` as the take closes.
    func setOnCloseStep(_ observer: @escaping @Sendable (CloseStep) -> Void) {
        onCloseStep = observer
    }

    // MARK: - Start

    /// Starts recording a new take and returns its ID.
    ///
    /// Throws `volumeNotAllowed`, `notEnoughDiskSpace` or `notCurrentFormatVersion` before creating
    /// anything. The take's record must reach the manifest on disk before anything is recorded, in a package
    /// raised in the same write to version 4 if a source's track needs it (`TrackKind.requiresFormatVersion4`), or to 5
    /// if the package has a take already (`Manifest.needsFormatVersion5`; the takes there are never touched): if those
    /// writes fail (after one retry with the reserve's room when they ran out of space), the lock and the
    /// reserve are released and the error is rethrown, leaving at most an empty take folder. If a source
    /// fails to start, the sources already started are stopped, the take is closed as `complete` with what
    /// it has (nothing is deleted), the lock is released and the error is rethrown. Either way this
    /// coordinator is done: it records one take.
    public func start() async throws -> String {
        guard state == .idle else { throw RecordingError.alreadyStarted }
        state = .starting
        defer {
            for waiter in startWaiters { waiter.resume() }
            startWaiters = []
        }
        do {
            let takeID = try await openTake()
            state = .recording
            startMonitoring()
            if autoStopPending { diskFilled() }
            return takeID
        } catch {
            state = .stopped
            warningsContinuation.finish()
            throw error
        }
    }

    private func openTake() async throws -> String {
        let eligibility = try VolumeEligibility.check(package.url)
        guard eligibility == .allowed else { throw RecordingError.volumeNotAllowed(eligibility) }
        switch try diskMonitor.verdict(isRecording: false) {
        case .refuseToStart(let available):
            throw RecordingError.notEnoughDiskSpace(availableBytes: available)
        case .warn(let available):
            diskLowReported = true
            warningsContinuation.yield(.diskLow(availableBytes: available))
        case .ok, .stopNow:
            break
        }

        let store = try ManifestStore(package: package)
        let formatVersion = store.manifest.formatVersion
        guard Manifest.recordableFormatVersions.contains(formatVersion) else {
            throw RecordingError.notCurrentFormatVersion(formatVersion)
        }
        let takeID = package.nextTakeID(existing: store.manifest.takes)
        try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: false)
        // `RecordingLock.isHeld` probes by taking the lock for a moment: try a few times before giving up.
        let lock = try await RecordingLock.acquire(at: package.lockURL(take: takeID), info: .current(now: Date()), retries: 4)
        let reserve: TakeReserve
        do {
            reserve = try TakeReserve.create(at: package.reserveURL(take: takeID))
        } catch {
            lock.release()
            throw error
        }
        let startedAt = Date().roundedToWholeSeconds
        let record = TakeRecord(
            id: takeID, status: .recording, startedAt: startedAt,
            tracks: sources.map { TrackRecord(id: $0.trackID, kind: $0.kind, source: $0.sourceInfo, segments: []) },
            cameraStyle: initialCameraStyle)
        // A take with a track only version 4 defines (an iPhone's) raises the package to 4: the store refuses that
        // record in a package of 3, and a take without one leaves it at 3. A take added to a package that has one raises
        // it to 5 (design §11): the app of phase 2 would open the last take with the first one's document, and says
        // "newer version" instead. The highest version needed, in the same write as the record
        // (`update(raisingTo:_:)`): never a package of one take at a version it does not need. The takes there stay as
        // they are.
        let raisedVersion: Int? =
            if !store.manifest.takes.isEmpty { 5 } else if sources.contains(where: { $0.kind.requiresFormatVersion4 }) { 4 } else { nil }
        let addTake = {
            if let raisedVersion {
                try store.update(raisingTo: raisedVersion) { $0.takes.append(record) }
            } else {
                try store.update { $0.takes.append(record) }
            }
        }
        // A take the manifest does not list is invisible to recovery and the editor: nothing is recorded
        // until it is on disk.
        do {
            do {
                try addTake()
            } catch where isOutOfSpace(error) {
                reserve.release()
                if store.manifest.takes.contains(where: { $0.id == takeID }) {
                    // In memory with its version: written together.
                    try store.flushPending()
                } else {
                    try addTake()
                }
                diskFilled()  // still starting: the take stops as `diskFull` once it has started
            }
        } catch {
            reserve.release()
            lock.release()
            throw error
        }
        take = Take(
            id: takeID, startedAt: startedAt, store: store, lock: lock, reserve: reserve, cameraStyle: initialCameraStyle)

        do {
            for source in sources {
                try FileManager.default.createDirectory(
                    at: package.trackDirectory(take: takeID, track: source.trackID), withIntermediateDirectories: false)
            }
            let log = try EventLogWriter(url: package.eventsURL(take: takeID))
            take?.log = log
            for source in sources {
                let info = source.sourceInfo
                switch source.kind {
                case .display:
                    guard let displayID = info.displayID, let frame = info.globalFrame, let scale = info.pixelScale else { continue }
                    log.append(InputEvent(t: clock(), kind: .displayGeometry(displayID: displayID, frame: frame, scale: scale)))
                case .window:
                    // Where it is as the take starts; the app's window watcher logs every change after this.
                    guard let frame = info.globalFrame else { continue }
                    log.append(InputEvent(t: clock(), kind: .windowGeometry(track: source.trackID, frame: frame, onScreen: true)))
                case .camera, .microphone, .systemAudio, .device, .deviceAudio:
                    break
                }
            }
            // Before its first `keyPress` line, a key recorder raises the package to 4; a take without one stays at 3.
            if let raising = input as? any FormatRaising {
                raising.setFormatRaiser { try store.raiseFormatVersion(to: 4) }
            }
            await input.start(log: log)

            let (verdicts, verdictsContinuation) = AsyncStream.makeStream(
                of: DiskSpaceVerdict.self, bufferingPolicy: .bufferingNewest(16))
            take?.diskVerdicts = verdictsContinuation
            diskMonitor.start { verdictsContinuation.yield($0) }
            diskTask = Task {
                for await verdict in verdicts { self.handleDiskVerdict(verdict) }
            }
            take?.activity = ProcessInfo.processInfo.beginActivity(
                options: Self.takeActivityOptions, reason: "Recording a take")

            let context = PipelineContext(
                package: package, takeID: takeID, store: store, log: log, warnings: warningsContinuation,
                configuration: configuration, writerFactory: writerFactory, clock: clock, ticks: ticks,
                onDiskFull: { [weak self] in
                    reserve.release()  // before the writer's caller writes anything else
                    Task { await self?.diskFilled() }
                },
                freeBytes: { [diskMonitor] in diskMonitor.availableBytes() })
            let screens = sources.filter(\.kind.isScreen).count
            for source in sources {
                let pipeline = TrackPipeline(
                    source: source, context: context, isSoleScreen: source.kind.isScreen && screens == 1)
                take?.pipelines.append(pipeline)
                try await pipeline.start()
                // An iPhone's screen has the size its first run started with, which the record could not know: the
                // device may have turned since, or not told its size before capturing.
                if source.kind == .device {
                    let info = source.sourceInfo
                    if record.tracks.first(where: { $0.id == source.trackID })?.source != info {
                        context.updateTrack(source.trackID) { $0.source = info }
                    }
                }
            }
        } catch {
            _ = await closeTake(reason: .stopped, stopTime: clock())
            throw error
        }
        return takeID
    }

    private func startMonitoring() {
        systemActivityTask = Task { [systemActivity, commandsContinuation] in
            for await activity in systemActivity {
                commandsContinuation.yield(.system(activity))
            }
        }
        activityTask = Task { [commands] in
            for await command in commands {
                await self.run(command)
            }
        }
        diskWatchdog = Task { await self.watchDiskVerdicts() }
        maintenanceTask = Task { await self.maintain() }
    }

    // MARK: - The user's pause and markers

    /// Pauses the take like a lock does, with the `paused` event's `reason` `userPauseReason`: every
    /// track closes its segment as `paused` and nothing is written (samples, input or markers) until
    /// `resume()`. Returns once every track is paused. Does nothing if the user has paused it already, and
    /// only adds the user's cause if something else paused it. Throws `RecordingError.notRecording` unless
    /// the take is recording or paused, also if it starts closing before the pause is applied.
    public func pause() async throws {
        try await send(.pause)
    }

    /// Ends the user's pause; the take records again, in new segments, once nothing else (sleep, lock)
    /// holds it. Returns once every track has started again. Does nothing unless the user paused the
    /// take. Throws like `pause()`.
    public func resume() async throws {
        try await send(.resume)
    }

    /// Writes a `marker` event at `clock()`, and returns that time. Throws `RecordingError.notRecording`
    /// unless the take is recording: nothing is written while it is paused.
    @discardableResult public func addMarker() async throws -> HostTime {
        guard state == .recording, let log = take?.log else { throw RecordingError.notRecording }
        let time = clock()
        log.append(InputEvent(t: time, kind: .marker))
        return time
    }

    /// The camera now looks like `style` (the user dropped the bubble somewhere else, or chose another shape
    /// or size): writes a `cameraStyle` event at `clock()`. While the take is paused, by the user or by the
    /// system, nothing is written: the last style asked for is written when it resumes, at the time of the
    /// `resumed` event and right after it. A style equal to the last one written (or to the take's initial
    /// style) is not written, and neither is anything in a take without a camera. Goes through the same
    /// serial task as `pause()`, so it is applied in order with the pauses. Throws
    /// `RecordingError.notRecording` unless the take is recording or paused.
    public func setCameraStyle(_ style: CameraStyle) async throws {
        try await send(.setCameraStyle(style))
    }

    /// Queues `request` behind the system's activity and the requests before it, and returns once it is done.
    private func send(_ request: UserRequest) async throws {
        guard state == .recording || state == .paused else { throw RecordingError.notRecording }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let id = nextRequestID
            nextRequestID += 1
            pendingRequests[id] = continuation
            if case .terminated = commandsContinuation.yield(.user(request, id: id)) {
                pendingRequests.removeValue(forKey: id)?.resume(throwing: RecordingError.notRecording)
            }
        }
    }

    private func run(_ command: Command) async {
        switch command {
        case .system(let activity):
            await handle(activity)
        case .user(let request, let id):
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            guard state == .recording || state == .paused else {
                continuation.resume(throwing: RecordingError.notRecording)
                return
            }
            switch request {
            case .pause: await pause(for: .user, reason: Self.userPauseReason)
            case .resume: await resume(clearing: .user)
            case .setCameraStyle(let style): cameraStyleChanged(to: style)
            }
            continuation.resume()
        }
    }

    // MARK: - Stop

    /// Stops the take and returns it, closed. Waits for a `start()` in progress first.
    ///
    /// Every track is closed even if one fails; the first failure is thrown after the take is
    /// marked `complete`, the event log closed and the lock released. Once the take is closed (by
    /// this call or by the stop for disk space) every later call returns the same result.
    public func stop() async throws -> TakeRecord {
        while state == .starting {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        switch state {
        case .recording, .paused:
            return try await beginClose(reason: .stopped, automatic: false).value.get()
        case .stopping, .stopped:
            guard let closeTask else { throw RecordingError.notRecording }
            return try await closeTask.value.get()
        case .idle, .starting:
            throw RecordingError.notRecording
        }
    }

    /// The volume is full, or about to be: gives the reserve back so the closing writes fit, and
    /// stops the take as `diskFull` (after `start()` if it is still starting).
    private func diskFilled() {
        take?.reserve.release()
        diskFull = true
        switch state {
        case .starting:
            autoStopPending = true
        case .recording, .paused:
            warningsContinuation.yield(.stoppedForDiskSpace)
            _ = beginClose(reason: .diskFull, automatic: true)
        case .idle, .stopping, .stopped:
            break
        }
    }

    private func beginClose(reason: SegmentEndReason, automatic: Bool) -> Task<CloseOutcome, Never> {
        if let closeTask { return closeTask }
        state = .stopping
        let stopTime = clock()
        let task = Task { await self.closeTake(reason: reason, stopTime: stopTime) }
        closeTask = task
        if automatic, let onAutoStop {
            Task {
                let outcome = await task.value
                onAutoStop(outcome.record, outcome.error)
            }
        }
        return task
    }

    /// Closes whatever part of the take is open: gives the reserve back (room for the final writes,
    /// however the take ended), stops monitoring, the sources and the input, closes every track
    /// (collecting failures), closes the log (its last lines full-synced), then marks the take
    /// `complete`, releases the lock and finishes `warnings`. Also rolls back a failed `start()`.
    ///
    /// The order is the segments' rule: the manifest says the take ended only once what it holds is on
    /// disk. Recovery never touches a `complete` take, so marking it first would lose for good the last
    /// lines of the log if the app died in between.
    private func closeTake(reason: SegmentEndReason, stopTime: HostTime) async -> CloseOutcome {
        guard let take else { preconditionFailure("RecordingCoordinator: closing without a take") }
        var errors: [any Error] = []
        take.reserve.release()
        diskMonitor.stop()
        maintenanceTask?.cancel()
        diskWatchdog?.cancel()
        diskTask?.cancel()
        systemActivityTask?.cancel()
        activityTask?.cancel()
        await activityTask?.value  // a pause or resume in progress finishes first
        // Every request not answered yet gets an answer: none is left waiting.
        commandsContinuation.finish()
        for continuation in pendingRequests.values { continuation.resume(throwing: RecordingError.notRecording) }
        pendingRequests = [:]
        take.diskVerdicts?.finish()

        let pipelines = take.pipelines
        await withDiscardingTaskGroup { group in
            for pipeline in pipelines {
                group.addTask { await pipeline.stopCapture() }
            }
        }
        await input.stop()
        let closed = await withTaskGroup(of: (Int, [any Error]).self) { group in
            for (i, pipeline) in pipelines.enumerated() {
                group.addTask { (i, await pipeline.close(reason: reason, at: stopTime)) }
            }
            var closed = [[any Error]](repeating: [], count: pipelines.count)
            for await (i, failures) in group { closed[i] = failures }
            return closed
        }
        errors += closed.flatMap { $0 }

        if let logFailure { errors.append(logFailure) }
        if let log = take.log {
            if diskFull, let failure = Self.flushAfterDiskFull(log) { errors.append(failure) }
            do { try log.close() } catch { errors.append(error) }
            onCloseStep?(.logClosed)
        }
        let takeID = take.id
        updateManifest(take.store) { manifest in
            guard let i = manifest.takes.firstIndex(where: { $0.id == takeID }) else { return }
            manifest.takes[i].status = .complete
        }
        do { try take.store.flushPending() } catch { errors.append(error) }
        onCloseStep?(.manifestComplete)
        if let failure = take.reserve.releaseError { errors.append(failure) }
        take.lock.release()
        onCloseStep?(.lockReleased)
        if let activity = take.activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.take?.activity = nil
        }
        state = .stopped
        warningsContinuation.finish()
        onAutoStop = nil  // whatever it holds is not kept alive by a closed take

        let record = take.store.manifest.takes.first { $0.id == takeID }
            ?? TakeRecord(id: takeID, status: .complete, startedAt: take.startedAt, tracks: [])
        return CloseOutcome(record: record, error: errors.first)
    }

    // MARK: - System activity

    private func handle(_ activity: SystemActivity) async {
        guard state == .recording || state == .paused else { return }
        switch activity {
        case .willSleep: await pause(for: .sleep, reason: "willSleep")
        case .screenLocked: await pause(for: .screenLocked, reason: "screenLocked")
        case .didWake: await resume(clearing: .sleep)
        case .screenUnlocked: await resume(clearing: .screenLocked)
        }
    }

    /// Stops the input recorder and every source, and closes the segments as `paused`: nothing is
    /// written while paused, and no input event lands between the `paused` and `resumed` events.
    /// Warns `paused` on the transition only. Nothing else changes `state` while this runs:
    /// `closeTake` waits for the activity task before touching the pipelines.
    private func pause(for cause: PauseCause, reason: String) async {
        pauseCauses.insert(cause)
        guard state == .recording, let take else { return }
        state = .paused
        await input.pause()
        let time = clock()
        take.log?.append(InputEvent(t: time, kind: .paused(reason: reason)))
        warningsContinuation.yield(.paused(reason: reason))
        await withDiscardingTaskGroup { group in
            for pipeline in take.pipelines {
                group.addTask { await pipeline.pause(at: time) }
            }
        }
    }

    /// Starts every source and the input recorder again once nothing keeps the take paused, and warns
    /// `resumed`. A camera style asked for during the pause is written right after the `resumed` event, at
    /// its time. Restart attempts start afresh.
    private func resume(clearing cause: PauseCause) async {
        pauseCauses.remove(cause)
        guard state == .paused, pauseCauses.isEmpty, let take else { return }
        state = .recording
        let time = clock()
        take.log?.append(InputEvent(t: time, kind: .resumed))
        if let style = take.pendingCameraStyle {
            self.take?.pendingCameraStyle = nil
            writeCameraStyle(style, at: time)
        }
        warningsContinuation.yield(.resumed)
        await input.resume()
        await withDiscardingTaskGroup { group in
            for pipeline in take.pipelines {
                group.addTask { await pipeline.resume() }
            }
        }
    }

    // MARK: - Camera style

    /// Writes `style` now while recording, or keeps it for `resume` while paused.
    private func cameraStyleChanged(to style: CameraStyle) {
        guard take?.cameraStyle != nil else { return }  // no camera
        switch state {
        case .recording: writeCameraStyle(style, at: clock())
        case .paused: take?.pendingCameraStyle = style
        case .idle, .starting, .stopping, .stopped: break
        }
    }

    /// Logs `style` at `time` unless the take has it already.
    private func writeCameraStyle(_ style: CameraStyle, at time: HostTime) {
        guard let take, let log = take.log, take.cameraStyle != style else { return }
        log.append(InputEvent(t: time, kind: .cameraStyle(style)))
        self.take?.cameraStyle = style
    }

    // MARK: - Disk space

    /// Verdicts start while `start()` is still starting the sources; a stop then waits for it.
    private func handleDiskVerdict(_ verdict: DiskSpaceVerdict) {
        guard state == .starting || state == .recording || state == .paused else { return }
        diskVerdictCount += 1
        switch verdict {
        case .ok:
            diskLowReported = false
        case .warn(let available):
            guard !diskLowReported else { return }
            diskLowReported = true
            warningsContinuation.yield(.diskLow(availableBytes: available))
        case .stopNow:
            diskFilled()
        case .refuseToStart:
            break  // only given before recording
        }
    }

    /// The monitor gives no verdict when it cannot read the free space; warn after three intervals
    /// in a row without one, once per outage.
    private func watchDiskVerdicts() async {
        var missed = 0
        while true {
            do {
                try await ticks.sleep(diskMonitor.interval)
            } catch {
                return
            }
            guard state == .recording || state == .paused else { return }
            missed = diskVerdictCount == 0 ? missed + 1 : 0
            diskVerdictCount = 0
            if missed == 3 { warningsContinuation.yield(.diskSpaceUnknown) }
        }
    }

    /// Every `syncInterval` while recording: writes a manifest change whose write failed, and flushes
    /// the event log so a failed write of its own timer is heard now. Running out of space either way
    /// stops the take as `diskFull`; any other log failure is reported by `stop()`.
    private func maintain() async {
        while true {
            do {
                try await ticks.sleep(configuration.syncInterval)
            } catch {
                return
            }
            guard state == .recording || state == .paused, let take else { return }
            do {
                try take.store.flushPending()
            } catch {
                // Still pending: the next tick or the close writes it again (its update already warned).
                if isOutOfSpace(error) { diskFilled() }
            }
            do {
                try take.log?.flush()
            } catch {
                if isOutOfSpace(error) {
                    diskFilled()  // the log keeps the lines; the close writes them with the reserve's room
                } else if logFailure == nil {
                    logFailure = error
                }
            }
        }
    }

    // MARK: - Helpers

    /// Writes a manifest change. A failed write is reported as `manifestWriteFailed` and retried by
    /// the next write; one that failed for lack of space stops the take and is retried at once with
    /// the reserve's room.
    private func updateManifest(_ store: ManifestStore, _ change: (inout Manifest) -> Void) {
        do {
            try store.update(change)
        } catch {
            if isOutOfSpace(error) {
                diskFilled()
                if (try? store.flushPending()) != nil { return }
            }
            warningsContinuation.yield(.manifestWriteFailed)
        }
    }

    /// After the disk filled, the event log kept the lines it could not write, and the first failure
    /// of its timer stays latched until a flush hears it. With the reserve's room, a flush writes them:
    /// once one succeeds, a latched out-of-space failure from before is not a loss and is not reported.
    /// Returns any other failure; a write that still fails is left for `close()` to report.
    private static func flushAfterDiskFull(_ log: EventLogWriter) -> (any Error)? {
        for _ in 0..<3 {
            do {
                try log.flush()
                return nil
            } catch where isOutOfSpace(error) {
                continue
            } catch {
                return error
            }
        }
        return nil
    }
}

/// Space a take holds on its volume from the start, `takes/<take>/.reserve`, given back when the disk
/// fills so the take can still be closed: the last segment writes, the manifest marked `complete` and
/// the event log. It is scratch, never take data.
final class TakeReserve: Sendable {
    static let size = 8 << 20

    let url: URL
    private let state = Mutex<(held: Bool, error: (any Error)?)>((true, nil))

    private init(url: URL) {
        self.url = url
    }

    /// Writes `size` bytes of zeros (so the blocks are really allocated) and full-syncs them.
    static func create(at url: URL) throws -> TakeReserve {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let chunk = [UInt8](repeating: 0, count: 1 << 20)
            for _ in 0..<(size / chunk.count) {
                try chunk.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        offset += written
                    }
                }
            }
            try DurableFile.fullSync(fd)
        } catch {
            close(fd)
            unlink(url.path)
            throw error
        }
        guard close(fd) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(url.path)
            throw error
        }
        return TakeReserve(url: url)
    }

    /// Deletes the file and syncs its folder so the space is free right away. Only the first call
    /// does anything; safe from any thread.
    func release() {
        state.withLock { state in
            guard state.held else { return }
            state.held = false
            if unlink(url.path) != 0, errno != ENOENT {
                state.error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                return
            }
            do {
                try DurableFile.syncDirectory(url.deletingLastPathComponent())
            } catch {
                state.error = error
            }
        }
    }

    /// Why `release()` could not delete the file or sync its folder, if it could not.
    var releaseError: (any Error)? {
        state.withLock { $0.error }
    }
}

/// Whether `error` means the volume is full, looking through underlying errors.
func isOutOfSpace(_ error: any Error, depth: Int = 0) -> Bool {
    let error = error as NSError
    switch (error.domain, error.code) {
    case (NSPOSIXErrorDomain, Int(ENOSPC)),
         (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
         (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
         (NSOSStatusErrorDomain, -34):  // dskFulErr
        return true
    default:
        break
    }
    guard depth < 8 else { return false }
    var underlying: [NSError] = []
    if let error = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(error) }
    if let errors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { underlying += errors }
    return underlying.contains { isOutOfSpace($0, depth: depth + 1) }
}
