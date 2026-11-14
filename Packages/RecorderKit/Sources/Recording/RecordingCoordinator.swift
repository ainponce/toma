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
    /// only display and a microphone then keep trying at the last interval; any other track is lost.
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
    /// only display or for a microphone, which keep trying (`displayPaused`, `trackPaused`).
    case trackLost(track: String)
    /// The only display could not be restarted with the configured attempts; it keeps trying.
    case displayPaused(track: String)
    /// The microphone `track` could not be restarted with the configured attempts: it records nothing
    /// until it comes back, and keeps trying at the last interval (each restart falls back to the default
    /// input). `streamRestarted` follows when it does.
    case trackPaused(track: String)
    /// The writer of `track` failed; its segment was closed and the next sample opens a new one.
    case writerFailed(track: String)
    /// `track` could not write `TrackPipeline.droppedSamplesWarningCount` samples in a row (its writer
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
    /// (`willSleep`, or `screenLocked` for a lock or for the displays going to sleep).
    case paused(reason: String)
    /// The take records again after `paused`, in new segments.
    case resumed
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
    /// What a take asks of the system while it records: no idle sleep of the Mac or of the displays.
    /// A display that sleeps on its idle timer would pause the take as if the screen were locked.
    static let takeActivityOptions: ProcessInfo.ActivityOptions = [
        .userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled,
    ]

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
        let reserve: TakeReserve
        var log: EventLogWriter?
        var diskVerdicts: AsyncStream<DiskSpaceVerdict>.Continuation?
        var activity: (any NSObjectProtocol)?
        var pipelines: [TrackPipeline] = []
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
    private var activityTask: Task<Void, Never>?
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

    /// Called once when the take stops by itself because the disk is full, with the closed take and
    /// the first failure of closing it (`nil` when it closed cleanly): the same outcome a later
    /// `stop()` returns or throws.
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
    /// Throws `volumeNotAllowed` or `notEnoughDiskSpace` before creating anything. The take's record
    /// must reach the manifest on disk before anything is recorded: if that write fails (after one retry
    /// with the reserve's room when it ran out of space), the lock and the reserve are released and the
    /// error is rethrown, leaving at most an empty take folder. If a source fails to start, the sources
    /// already started are stopped, the take is closed as `complete` with what it has (nothing is
    /// deleted), the lock is released and the error is rethrown. Either way this coordinator is done: it
    /// records one take.
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
            tracks: sources.map { TrackRecord(id: $0.trackID, kind: $0.kind, source: $0.sourceInfo, segments: []) })
        // A take the manifest does not list is invisible to recovery and the editor: nothing is recorded
        // until it is on disk.
        do {
            do {
                try store.update { $0.takes.append(record) }
            } catch where isOutOfSpace(error) {
                reserve.release()
                try store.flushPending()
                diskFilled()  // still starting: the take stops as `diskFull` once it has started
            }
        } catch {
            reserve.release()
            lock.release()
            throw error
        }
        take = Take(id: takeID, startedAt: startedAt, store: store, lock: lock, reserve: reserve)

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
                options: Self.takeActivityOptions, reason: "Recording a take")

            let context = PipelineContext(
                package: package, takeID: takeID, store: store, log: log, warnings: warningsContinuation,
                configuration: configuration, writerFactory: writerFactory, clock: clock,
                onDiskFull: { [weak self] in
                    reserve.release()  // before the writer's caller writes anything else
                    Task { await self?.diskFilled() }
                },
                freeBytes: { [diskMonitor] in diskMonitor.availableBytes() })
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

    private func startMonitoring() {
        activityTask = Task { [systemActivity] in
            for await activity in systemActivity {
                await self.handle(activity)
            }
        }
        diskWatchdog = Task { await self.watchDiskVerdicts() }
        maintenanceTask = Task { await self.maintain() }
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
        if automatic {
            Task {
                let outcome = await task.value
                self.onAutoStop?(outcome.record, outcome.error)
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
    /// `resumed`. Restart attempts start afresh.
    private func resume(clearing cause: PauseCause) async {
        pauseCauses.remove(cause)
        guard state == .paused, pauseCauses.isEmpty, let take else { return }
        state = .recording
        take.log?.append(InputEvent(t: clock(), kind: .resumed))
        warningsContinuation.yield(.resumed)
        await input.resume()
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

    /// Every `syncInterval` while recording: writes a manifest change whose write failed, and flushes
    /// the event log so a failed write of its own timer is heard now. Running out of space either way
    /// stops the take as `diskFull`; any other log failure is reported by `stop()`.
    private func maintain() async {
        while true {
            do {
                try await Task.sleep(for: configuration.syncInterval)
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
