// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// Makes the writer of one segment: the file to create and what the track carries.
public typealias WriterFactory = @Sendable (URL, TrackMedia) throws -> any TrackWriting

public struct RecordingConfiguration: Sendable {
    /// Wait before each restart attempt after a stream error; its length is the number of attempts.
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
    /// Restarts of `track` were exhausted: it records nothing more in this take.
    case trackLost(track: String)
    /// The only display could not be restarted with the configured attempts; it keeps trying.
    case displayPaused(track: String)
    /// The writer of `track` failed; its segment was closed and the next sample opens a new one.
    case writerFailed(track: String)
    /// The manifest could not be written; the change is kept and written with the next change.
    case manifestWriteFailed
    /// Little free space left on the recording volume.
    case diskLow(availableBytes: Int64)
    /// The take was stopped because the volume is (almost) full.
    case stoppedForDiskSpace
    /// Free space could not be read for three monitor intervals in a row: the take goes on without
    /// the disk-space stop until it can be read again.
    case diskSpaceUnknown
}

public enum RecordingError: Error, Equatable {
    case notEnoughDiskSpace(availableBytes: Int64)
    case volumeNotAllowed(VolumeEligibility)
    case alreadyStarted
    case notRecording
}

/// Records one take: every source into its own track of segment files, plus the event log, the
/// manifest and the recording lock, and closes it cleanly however it ends.
///
/// `idle → starting → recording ⇄ paused → stopping → stopped`. Sleep and screen lock pause every
/// track (closing their segments as `paused`); wake and unlock resume them in new segments. A stream
/// or writer failure closes that track's segment and opens a new one once it recovers. The user's
/// `stop()` and the stop for disk space share one closing task, so a take is closed exactly once.
public actor RecordingCoordinator {
    private enum State {
        case idle, starting, recording, paused, stopping, stopped
    }

    private enum PauseCause: Hashable {
        case sleep, screenLocked
    }

    /// The resources of the take being recorded.
    private struct Take {
        let id: String
        let startedAt: Date
        let store: ManifestStore
        let lock: HeldRecordingLock
        var log: EventLogWriter?
        var diskVerdicts: AsyncStream<DiskSpaceVerdict>.Continuation?
        var activity: (any NSObjectProtocol)?
        var pipelines: [TrackPipeline] = []
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

    private var state = State.idle
    private var take: Take?
    private var pauseCauses: Set<PauseCause> = []
    private var closeTask: Task<CloseOutcome, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var autoStopPending = false
    private var onAutoStop: (@Sendable (TakeRecord) -> Void)?
    private var activityTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?
    private var diskWatchdog: Task<Void, Never>?
    /// Verdicts received since the watchdog last looked.
    private var diskVerdictCount = 0
    private var diskLowReported = false

    public init(
        package: ProjectPackage,
        sources: [any CaptureSource],
        input: any InputRecorder,
        diskMonitor: DiskSpaceMonitor,
        systemActivity: AsyncStream<SystemActivity>,
        configuration: RecordingConfiguration = .init(),
        writerFactory: @escaping WriterFactory = { url, media in try FragmentedTrackWriter(url: url, media: media) },
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        let ids = sources.map(\.trackID)
        precondition(Set(ids).count == ids.count, "RecordingCoordinator: track IDs must be unique, got \(ids)")
        (warnings, warningsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.package = package
        self.sources = sources
        self.input = input
        self.diskMonitor = diskMonitor
        self.systemActivity = systemActivity
        self.configuration = configuration
        self.writerFactory = writerFactory
        self.clock = clock
    }

    /// Called once with the closed take when the take stops by itself (the disk is full).
    public func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord) -> Void) {
        onAutoStop = handler
    }

    // MARK: - Start

    /// Starts recording a new take and returns its ID.
    ///
    /// Throws `volumeNotAllowed` or `notEnoughDiskSpace` before creating anything. If a source fails
    /// to start, the sources already started are stopped, the take is closed as `complete` with what
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
            if autoStopPending { requestAutoStop() }
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
        let takeID = package.nextTakeID(existing: store.manifest.takes)
        try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: false)
        let lock = try await acquireLock(at: package.lockURL(take: takeID))
        let startedAt = Date().roundedToWholeSeconds
        let record = TakeRecord(
            id: takeID, status: .recording, startedAt: startedAt,
            tracks: sources.map { TrackRecord(id: $0.trackID, kind: $0.kind, source: $0.sourceInfo, segments: []) })
        updateManifest(store) { $0.takes.append(record) }
        take = Take(id: takeID, startedAt: startedAt, store: store, lock: lock)

        do {
            for source in sources {
                try FileManager.default.createDirectory(
                    at: package.trackDirectory(take: takeID, track: source.trackID), withIntermediateDirectories: false)
            }
            let log = try EventLogWriter(url: package.eventsURL(take: takeID))
            take?.log = log
            for source in sources where source.kind == .display {
                let info = source.sourceInfo
                guard let displayID = info.displayID, let frame = info.globalFrame, let scale = info.pixelScale else { continue }
                log.append(InputEvent(t: clock(), kind: .displayGeometry(displayID: displayID, frame: frame, scale: scale)))
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
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a take")

            let context = PipelineContext(
                package: package, takeID: takeID, store: store, log: log, warnings: warningsContinuation,
                configuration: configuration, writerFactory: writerFactory, clock: clock,
                onDiskFull: { [weak self] in
                    Task { await self?.requestAutoStop() }
                })
            let displays = sources.filter { $0.kind == .display }.count
            for source in sources {
                let pipeline = TrackPipeline(
                    source: source, context: context, isSoleDisplay: source.kind == .display && displays == 1)
                take?.pipelines.append(pipeline)
                try await pipeline.start()
            }
        } catch {
            _ = await closeTake(reason: .stopped, stopTime: clock())
            throw error
        }
        return takeID
    }

    /// `RecordingLock.isHeld` probes by taking the lock for a moment, so an `acquire` that races
    /// it can fail with `EWOULDBLOCK`: try a few times before giving up.
    private func acquireLock(at url: URL) async throws -> HeldRecordingLock {
        var attempt = 1
        while true {
            do {
                return try RecordingLock.acquire(at: url, info: .current(now: Date()))
            } catch let error as POSIXError where error.code == .EWOULDBLOCK && attempt < 5 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func startMonitoring() {
        activityTask = Task { [systemActivity] in
            for await activity in systemActivity {
                await self.handle(activity)
            }
        }
        diskWatchdog = Task { await self.watchDiskVerdicts() }
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

    private func requestAutoStop() {
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
        if automatic {
            Task {
                let outcome = await task.value
                self.onAutoStop?(outcome.record)
            }
        }
        return task
    }

    /// Closes whatever part of the take is open: stops monitoring, the sources and the input, closes
    /// every track (collecting failures), marks the take `complete`, closes the log, releases the lock
    /// and finishes `warnings`. Also rolls back a failed `start()`.
    private func closeTake(reason: SegmentEndReason, stopTime: HostTime) async -> CloseOutcome {
        guard let take else { preconditionFailure("RecordingCoordinator: closing without a take") }
        var errors: [any Error] = []
        diskMonitor.stop()
        diskWatchdog?.cancel()
        diskTask?.cancel()
        activityTask?.cancel()
        await activityTask?.value  // a pause or resume in progress finishes first
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

        let takeID = take.id
        updateManifest(take.store) { manifest in
            guard let i = manifest.takes.firstIndex(where: { $0.id == takeID }) else { return }
            manifest.takes[i].status = .complete
        }
        do { try take.store.flushPending() } catch { errors.append(error) }
        do { try take.log?.close() } catch { errors.append(error) }
        take.lock.release()
        if let activity = take.activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.take?.activity = nil
        }
        state = .stopped
        warningsContinuation.finish()

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

    /// Stops every source and closes their segments as `paused`. Nothing else changes `state` while
    /// this runs: `closeTake` waits for the activity task before touching the pipelines.
    private func pause(for cause: PauseCause, reason: String) async {
        pauseCauses.insert(cause)
        guard state == .recording, let take else { return }
        state = .paused
        let time = clock()
        take.log?.append(InputEvent(t: time, kind: .paused(reason: reason)))
        await withDiscardingTaskGroup { group in
            for pipeline in take.pipelines {
                group.addTask { await pipeline.pause(at: time) }
            }
        }
    }

    /// Starts every source again once nothing keeps the take paused. Restart attempts start afresh.
    private func resume(clearing cause: PauseCause) async {
        pauseCauses.remove(cause)
        guard state == .paused, pauseCauses.isEmpty, let take else { return }
        state = .recording
        take.log?.append(InputEvent(t: clock(), kind: .resumed))
        await withDiscardingTaskGroup { group in
            for pipeline in take.pipelines {
                group.addTask { await pipeline.resume() }
            }
        }
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
            requestAutoStop()
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
                try await Task.sleep(for: diskMonitor.interval)
            } catch {
                return
            }
            guard state == .recording || state == .paused else { return }
            missed = diskVerdictCount == 0 ? missed + 1 : 0
            diskVerdictCount = 0
            if missed == 3 { warningsContinuation.yield(.diskSpaceUnknown) }
        }
    }

    // MARK: - Helpers

    private func updateManifest(_ store: ManifestStore, _ change: (inout Manifest) -> Void) {
        do {
            try store.update(change)
        } catch {
            warningsContinuation.yield(.manifestWriteFailed)
        }
    }
}
