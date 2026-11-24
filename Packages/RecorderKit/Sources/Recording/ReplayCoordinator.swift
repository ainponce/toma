// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// How the Replay records (fases 4 y 5 design §10.2, plan 5c decisions 2 to 5).
public struct ReplayConfiguration: Sendable {
    /// N: the seconds a save keeps (15 s to 5 min in the app).
    public var seconds: Int
    /// Every track rotates its segment this often, and the event log its file.
    public var segmentDuration: Duration
    /// What ended more than N plus this ago is deleted.
    public var pruneMargin: Duration
    /// The restarts, heartbeats and syncs of the tracks, as in a take; `syncInterval` also paces the writes of what the
    /// manifest and the event log have pending.
    public var recording: RecordingConfiguration

    public init(
        seconds: Int, segmentDuration: Duration = .seconds(10), pruneMargin: Duration = .seconds(10),
        recording: RecordingConfiguration = .init()
    ) {
        self.seconds = seconds
        self.segmentDuration = segmentDuration
        self.pruneMargin = pruneMargin
        self.recording = recording
    }
}

/// Why the Replay stopped by itself.
public enum ReplayEnd: Equatable, Sendable {
    /// The volume is (almost) full: the working package was deleted.
    case diskFull
}

/// Records the Replay's rolling take (fases 4 y 5 design §10.2): the sibling of `RecordingCoordinator`, which it never
/// touches, over the same parts (`TrackPipeline`, `EventLogWriter`, `ManifestStore`, `RecordingLock`, `DiskSpaceMonitor`).
///
/// It records every source into the working package (`ReplayScratch`, marked so it is never recovered nor shown), take
/// `take-001`, `recording` and its lock held while it runs. Every track rotates its segment every `segmentDuration`
/// (`PipelineContext.segmentRotation`), and the event log its file (`events-NNNN.jsonl`, `EventLogWriter.rotate(to:)`).
/// What ended more than N + `pruneMargin` ago is deleted, a closed segment's file and record, and an event file once the
/// next one opened before then, after its state is folded into memory (`ReplayEventState`): the geometry, the camera's
/// style and the cursor of the start are never lost. A save freezes it (`freeze()`): every track rotated at once,
/// nothing deleted until `thaw()`.
///
/// It is never a project: `stopAndDiscard()` and a full disk delete the whole package; a forced quit leaves it for
/// `ReplayScratch.discardLeftovers` when Toma opens. It reserves no space and keeps no activity assertion (plan 5c,
/// decision 5): the app deletes it when the Mac sleeps.
public actor ReplayCoordinator: ReplaySource {
    private enum State {
        case idle, starting, recording, discarding, stopped
    }

    /// An event file of the working take, from the time it was opened.
    private struct Shard {
        let index: Int
        let url: URL
        let openedAt: HostTime
    }

    /// What `start()` made, as far as it got.
    private struct Ring {
        let package: ProjectPackage
        var lock: HeldRecordingLock?
        var store: ManifestStore?
        var log: EventLogWriter?
        /// Oldest first; the last is the one the log appends to.
        var shards: [Shard] = []
        var pipelines: [TrackPipeline] = []
        var diskVerdicts: AsyncStream<DiskSpaceVerdict>.Continuation?
        var inputStarted = false
        var diskMonitorStarted = false
    }

    /// Warnings of the Replay, in order. Finishes once it is discarded (or fails to start).
    public nonisolated let warnings: AsyncStream<RecordingWarning>
    private let warningsContinuation: AsyncStream<RecordingWarning>.Continuation

    private let scratchRoot: URL
    private let app: AppInfo
    private let sources: [any CaptureSource]
    private let input: any InputRecorder
    private let diskMonitor: DiskSpaceMonitor
    private var configuration: ReplayConfiguration
    private let writerFactory: WriterFactory
    private let clock: @Sendable () -> HostTime
    private let ticks: RecordingTicks
    private let initialCameraStyle: CameraStyle?

    private var state = State.idle
    private var ring: Ring?
    /// Freezes not thawed yet: nothing is deleted while there is one.
    private var freezes = 0
    /// The state of the event files deleted so far.
    private var eventState: ReplayEventState
    /// The camera's style as the take has it: the initial one, then the last `cameraStyle` event. `nil` without a camera.
    private var cameraStyle: CameraStyle?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var discardTask: Task<Void, Never>?
    private var onAutoStop: (@Sendable (ReplayEnd) -> Void)?
    /// The disk filled while starting: the Replay is discarded as soon as it has started.
    private var diskFullPending = false
    private var diskLowReported = false
    private var ringTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?

    public init(
        scratchRoot: URL,
        app: AppInfo,
        sources: [any CaptureSource],
        input: any InputRecorder,
        diskMonitor: DiskSpaceMonitor,
        configuration: ReplayConfiguration,
        writerFactory: @escaping WriterFactory = { url, media in try FragmentedTrackWriter(url: url, media: media) },
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        ticks: RecordingTicks = .live,
        cameraStyle: CameraStyle? = nil
    ) {
        let ids = sources.map(\.trackID)
        precondition(Set(ids).count == ids.count, "ReplayCoordinator: track IDs must be unique, got \(ids)")
        (warnings, warningsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.scratchRoot = scratchRoot
        self.app = app
        self.sources = sources
        self.input = input
        self.diskMonitor = diskMonitor
        self.configuration = configuration
        self.writerFactory = writerFactory
        self.clock = clock
        self.ticks = ticks
        let style = sources.contains { $0.kind == .camera } ? cameraStyle ?? .default : nil
        self.initialCameraStyle = style
        self.cameraStyle = style
        self.eventState = ReplayEventState(cameraStyle: style)
    }

    /// Called once if the Replay stops by itself (`ReplayEnd`), after its package is deleted.
    public func setOnAutoStop(_ handler: @escaping @Sendable (ReplayEnd) -> Void) {
        onAutoStop = handler
    }

    // MARK: - Start

    /// Starts recording into a fresh working package in `scratchRoot` and returns it.
    ///
    /// Throws `ReplayError.alreadyStarted` unless it is new, `RecordingError.notEnoughDiskSpace` before creating anything,
    /// and `ReplayError.scratchInUse` if another Replay records into the working package (which is left alone). Any other
    /// failure (a source that does not start, say) stops what started and deletes the package before it is rethrown.
    /// Either way this coordinator is done: it records one ring.
    public func start() async throws -> ProjectPackage {
        guard state == .idle else { throw ReplayError.alreadyStarted }
        state = .starting
        defer {
            for waiter in startWaiters { waiter.resume() }
            startWaiters = []
        }
        do {
            let package = try await openRing()
            state = .recording
            ringTask = Task { await self.runRing() }
            maintenanceTask = Task { await self.maintain() }
            if diskFullPending { diskFilled() }
            return package
        } catch {
            await tearDown()
            throw error
        }
    }

    private func openRing() async throws -> ProjectPackage {
        switch try diskMonitor.verdict(isRecording: false) {
        case .refuseToStart(let available):
            throw RecordingError.notEnoughDiskSpace(availableBytes: available)
        case .warn(let available):
            diskLowReported = true
            warningsContinuation.yield(.diskLow(availableBytes: available))
        case .ok, .stopNow:
            break
        }

        let package = try ReplayScratch.create(in: scratchRoot, app: app, now: Date())
        ring = Ring(package: package)
        let takeID = ReplayScratch.takeID
        try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: false)
        // `RecordingLock.isHeld` probes by taking the lock for a moment: try a few times before giving up.
        ring?.lock = try await RecordingLock.acquire(at: package.lockURL(take: takeID), info: .current(now: Date()), retries: 4)
        let store = try ManifestStore(package: package)
        ring?.store = store
        let record = TakeRecord(
            id: takeID, status: .recording, startedAt: Date().roundedToWholeSeconds,
            tracks: sources.map(SystemAudioTracks.trackRecord(of:)), cameraStyle: initialCameraStyle)
        // A track only version 4 defines (an iPhone's) raises the working package to 4 in the same write.
        if sources.contains(where: { $0.kind.requiresFormatVersion4 }) {
            try store.update(raisingTo: 4) { $0.takes.append(record) }
        } else {
            try store.update { $0.takes.append(record) }
        }
        for source in sources {
            try FileManager.default.createDirectory(
                at: package.trackDirectory(take: takeID, track: source.trackID), withIntermediateDirectories: false)
        }
        let firstShard = ReplayScratch.shardURL(of: package, index: 1)
        let log = try EventLogWriter(url: firstShard)
        ring?.log = log
        ring?.shards = [Shard(index: 1, url: firstShard, openedAt: clock())]
        // Where the screens are as it starts, as `RecordingCoordinator.openTake` logs it; the app's watchers log every
        // change after this.
        for source in sources {
            let info = source.sourceInfo
            switch source.kind {
            case .display:
                guard let displayID = info.displayID, let frame = info.globalFrame, let scale = info.pixelScale else { continue }
                log.append(InputEvent(t: clock(), kind: .displayGeometry(displayID: displayID, frame: frame, scale: scale)))
            case .window:
                guard let frame = info.globalFrame else { continue }
                log.append(InputEvent(t: clock(), kind: .windowGeometry(track: source.trackID, frame: frame, onScreen: true)))
            case .camera, .microphone, .systemAudio, .device, .deviceAudio:
                break
            }
        }
        // Before its first `keyPress` line, a key recorder raises the working package to 4.
        if let raising = input as? any FormatRaising {
            raising.setFormatRaiser { try store.raiseFormatVersion(to: 4) }
        }
        ring?.inputStarted = true
        await input.start(log: log)

        let (verdicts, verdictsContinuation) = AsyncStream.makeStream(
            of: DiskSpaceVerdict.self, bufferingPolicy: .bufferingNewest(16))
        ring?.diskVerdicts = verdictsContinuation
        ring?.diskMonitorStarted = true
        diskMonitor.start { verdictsContinuation.yield($0) }
        diskTask = Task {
            for await verdict in verdicts { self.handleDiskVerdict(verdict) }
        }

        var context = PipelineContext(
            package: package, takeID: takeID, store: store, log: log, warnings: warningsContinuation,
            configuration: configuration.recording, writerFactory: writerFactory, clock: clock, ticks: ticks,
            onDiskFull: { [weak self] in Task { await self?.diskFilled() } },
            freeBytes: { [diskMonitor] in diskMonitor.availableBytes() })
        context.segmentRotation = configuration.segmentDuration
        let screens = sources.filter(\.kind.isScreen).count
        for source in sources {
            let pipeline = TrackPipeline(source: source, context: context, isSoleScreen: source.kind.isScreen && screens == 1)
            ring?.pipelines.append(pipeline)
            try await pipeline.start()
            // An iPhone's screen has the size its first run started with, which the record could not know.
            if source.kind == .device {
                let info = source.sourceInfo
                if record.tracks.first(where: { $0.id == source.trackID })?.source != info {
                    context.updateTrack(source.trackID) { $0.source = info }
                }
            }
        }
        return package
    }

    // MARK: - While it records

    /// N changes now: the next pruning keeps the last `seconds` (plus the margin).
    public func setSeconds(_ seconds: Int) {
        configuration.seconds = max(0, seconds)
    }

    /// The camera now looks like `style`: logs a `cameraStyle` event at `clock()` when it differs from the last one (or
    /// the initial style), as `RecordingCoordinator` does. Nothing without a camera, or unless it is recording.
    public func setCameraStyle(_ style: CameraStyle) {
        guard state == .recording, cameraStyle != nil, cameraStyle != style, let log = ring?.log else { return }
        log.append(InputEvent(t: clock(), kind: .cameraStyle(style)))
        cameraStyle = style
    }

    /// How much of the screen the ring holds, at most N: from the start of its oldest segment of a screen to now. Zero
    /// unless it is recording and a screen has started.
    public func buffered() -> Duration {
        guard state == .recording, let take = ring?.store?.manifest.takes.first(where: { $0.id == ReplayScratch.takeID })
        else { return .zero }
        guard let oldest = take.tracks.filter(\.kind.isScreen).flatMap({ $0.segments.map(\.startHostTime) }).min() else {
            return .zero
        }
        let seconds = min(Double(configuration.seconds), max(0, clock().seconds(since: oldest)))
        return .nanoseconds(Int64((seconds * 1_000_000_000).rounded()))
    }

    // MARK: - Freeze

    /// Stops deleting until `thaw()`, rotates every track at once (`TrackPipeline.rotate()`), writes the event log's
    /// buffer to its file and returns what a save takes: of each track, the segments closed by that rotation and before
    /// (the ones it opened are left out), the event files left and the state of the ones deleted. Every segment it lists
    /// is full-synced (`F_FULLFSYNC`) before the manifest says it closed, so a save may clone it as it is.
    ///
    /// Freezes nest: nothing is deleted until each one is thawed, so a second save that starts while the first one copies
    /// keeps its files. Each call made while recording counts, also one that throws: its caller thaws it as after a save
    /// (`ReplaySaver` thaws once whatever happens). Throws `ReplayError.notRunning` unless it is recording (also if it is
    /// discarded meanwhile; such a call does not count) and `nothingToSave` when no segment of a screen closed.
    public func freeze() async throws -> ReplaySnapshot {
        guard state == .recording, let pipelines = ring?.pipelines else { throw ReplayError.notRunning }
        // What is too old goes now, unless another save holds it: the ring never keeps more than it needs to.
        prune()
        freezes += 1
        let rotated = await Self.rotations(of: pipelines, within: Self.freezeDeadline)
        guard state == .recording, let ring, let store = ring.store, let log = ring.log else {
            throw ReplayError.notRunning
        }
        do {
            try log.flush()
            try store.flushPending()
        } catch where isOutOfSpace(error) {
            diskFilled()
            throw ReplayError.notRunning
        } catch {
            // Reported once and gone: the files hold what they could, and the save goes on with it.
        }
        let manifest = store.manifest
        guard var take = manifest.takes.first(where: { $0.id == ReplayScratch.takeID }) else {
            throw ReplayError.nothingToSave
        }
        for i in take.tracks.indices {
            let limit = rotated[take.tracks[i].id] ?? nil
            // Never a segment after one still open or finishing (a rotation that did not answer in time): the save would
            // have a hole there. A rotation that answered left none before its segment.
            let unclosed = take.tracks[i].segments.filter { $0.endHostTime == nil || $0.endReason == nil }.map(\.index).min()
            take.tracks[i].segments.removeAll { segment in
                segment.endHostTime == nil || segment.endReason == nil || limit.map { segment.index > $0 } ?? false
                    || unclosed.map { segment.index > $0 } ?? false
            }
        }
        guard take.tracks.contains(where: { $0.kind.isScreen && !$0.segments.isEmpty }) else {
            throw ReplayError.nothingToSave
        }
        // The capture queues never sync a segment: the ones a save clones are synced here, off them.
        try await Self.fullSync(take.tracks.flatMap { track in
            track.segments.map { ring.package.url.appending(path: $0.file, directoryHint: .notDirectory) }
        })
        return ReplaySnapshot(
            package: ring.package, take: take, formatVersion: manifest.formatVersion, shards: ring.shards.map(\.url),
            carried: eventState.events)
    }

    /// How long a freeze waits for the tracks to rotate before it gives what closed so far: a rotation that waits for the
    /// next sample answers within `TrackPipeline.rotationWait`, plus the time to finish the files.
    static let freezeDeadline: Duration = TrackPipeline.rotationWait + .seconds(5)

    /// Each track's `rotate()`, by track: those that answered within `deadline` (an answer may be `nil`). One still waiting
    /// then is left to finish on its own, and its track is missing.
    private static func rotations(of pipelines: [TrackPipeline], within deadline: Duration) async -> [String: Int?] {
        guard !pipelines.isEmpty else { return [:] }
        let (answers, continuation) = AsyncStream.makeStream(of: (String, Int?).self)
        for pipeline in pipelines {
            Task { continuation.yield((pipeline.trackID, await pipeline.rotate())) }
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.finish()
        }
        var rotated: [String: Int?] = [:]
        for await (track, index) in answers {
            rotated[track] = index
            if rotated.count == pipelines.count { break }
        }
        timer.cancel()
        continuation.finish()
        return rotated
    }

    /// Opens each file (never through a link), full-syncs it (`F_FULLFSYNC`) and closes it, off the caller's actor.
    @concurrent private static func fullSync(_ urls: [URL]) async throws {
        for url in urls {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            try DurableFile.fullSync(fd)
        }
    }

    /// Undoes one `freeze()`: once the last one is thawed, what is too old is deleted again from the next tick on. Does
    /// nothing without a freeze to undo, and on a Replay that is not recording.
    public func thaw() async {
        guard state == .recording else { return }
        freezes = max(0, freezes - 1)
    }

    // MARK: - Stop

    /// Stops the sources and the input, closes every track and the event log, releases the lock and deletes the working
    /// package, then finishes `warnings`. Waits for a `start()` in progress first. Idempotent; a coordinator that never
    /// started is done too.
    ///
    /// It does not wait for a save in progress (a `freeze()` not thawed), and neither does a full disk: that save then
    /// fails cleanly, its files gone, and leaves nothing. Whoever wants the save to finish waits for it first, when a take
    /// starts and also when the Mac sleeps, the screen locks or Toma quits.
    public func stopAndDiscard() async {
        while state == .starting {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        switch state {
        case .idle:
            state = .stopped
            warningsContinuation.finish()
        case .recording:
            await beginDiscard(end: nil).value
        case .discarding:
            await discardTask?.value
        case .starting, .stopped:
            break
        }
    }

    private func beginDiscard(end: ReplayEnd?) -> Task<Void, Never> {
        if let discardTask { return discardTask }
        state = .discarding
        let task = Task { await self.tearDown() }
        discardTask = task
        if let end, let onAutoStop {
            self.onAutoStop = nil
            Task {
                await task.value
                onAutoStop(end)
            }
        }
        return task
    }

    /// Undoes whatever part of the ring is there: stops the ticks and the disk monitor, the sources and the input, closes
    /// every track and the log, releases the lock and deletes the working package. Ends `stopped`, `warnings` finished.
    private func tearDown() async {
        ringTask?.cancel()
        maintenanceTask?.cancel()
        diskTask?.cancel()
        if ring?.diskMonitorStarted == true { diskMonitor.stop() }
        ring?.diskVerdicts?.finish()
        let pipelines = ring?.pipelines ?? []
        await withDiscardingTaskGroup { group in
            for pipeline in pipelines {
                group.addTask { await pipeline.stopCapture() }
            }
        }
        if ring?.inputStarted == true { await input.stop() }
        let stopTime = clock()
        await withDiscardingTaskGroup { group in
            for pipeline in pipelines {
                group.addTask { _ = await pipeline.close(reason: .stopped, at: stopTime) }
            }
        }
        if let ring {
            // Nothing of it is kept: whatever these fail to do, the package goes, or the next start or launch deletes it.
            try? ring.log?.close()
            ring.lock?.release()
            try? ReplayScratch.discard(ring.package)
        }
        ring = nil
        state = .stopped
        onAutoStop = nil
        warningsContinuation.finish()
    }

    // MARK: - The ring

    /// How often the ring looks for what to delete and whether the event log is due a new file: a tenth of a segment.
    /// `prune()` takes it off the margin, so nothing outlives N + `pruneMargin` (the design's N + 20 s on disk).
    static func ringTick(of configuration: ReplayConfiguration) -> Duration {
        configuration.segmentDuration / 10
    }

    private func runRing() async {
        let tick = Self.ringTick(of: configuration)
        while true {
            do {
                try await ticks.sleep(tick)
            } catch {
                return
            }
            guard state == .recording else { return }
            rotateShardIfDue()
            prune()
        }
    }

    /// A new event file once the current one has been open `segmentDuration`. One that cannot be created leaves the log in
    /// the current file, and the next tick tries again.
    private func rotateShardIfDue() {
        guard let ring, let log = ring.log, let current = ring.shards.last,
              clock() >= current.openedAt.adding(seconds: configuration.segmentDuration.seconds)
        else { return }
        let url = ReplayScratch.shardURL(of: ring.package, index: current.index + 1)
        var failure: (any Error)?
        do {
            try log.rotate(to: url)
        } catch {
            failure = error
        }
        // It moves to the new file unless creating it failed; a failure of the old one is thrown after the move.
        if log.url == url {
            self.ring?.shards.append(Shard(index: current.index + 1, url: url, openedAt: clock()))
        }
        if let failure, isOutOfSpace(failure) { diskFilled() }
    }

    /// Unless frozen: deletes each closed segment that ended before N + `pruneMargin` − a tick of the ring ago, its record
    /// first (a save never sees a record without its file), then its file; and each event file whose next one opened
    /// before then, after folding its events into `eventState`. The tick less makes up for the tick a segment waits to be
    /// deleted: on disk there is never more than N + `pruneMargin` + a segment (the design's N + 20 s); a save needs only
    /// what ended after N ago. The tick never takes a margin below zero; a margin already below it (the tests', to delete
    /// inside N without waiting N) is taken as it is.
    private func prune() {
        guard freezes == 0, let ring, let store = ring.store else { return }
        let configured = configuration.pruneMargin.seconds
        let margin = configured > 0 ? max(0, configured - Self.ringTick(of: configuration).seconds) : configured
        let threshold = clock().adding(seconds: -(Double(configuration.seconds) + margin))
        let takeID = ReplayScratch.takeID
        let old = Set(store.manifest.takes.first { $0.id == takeID }?.tracks.flatMap { track in
            track.segments.filter { segment in
                guard let end = segment.endHostTime, segment.endReason != nil else { return false }
                return end < threshold
            }.map(\.file)
        } ?? [])
        if !old.isEmpty {
            updateManifest(store) { manifest in
                guard let take = manifest.takes.firstIndex(where: { $0.id == takeID }) else { return }
                for track in manifest.takes[take].tracks.indices {
                    manifest.takes[take].tracks[track].segments.removeAll { old.contains($0.file) }
                }
            }
            for file in old.sorted() {
                unlink(ring.package.url.appendingPathComponent(file, isDirectory: false).path)
            }
        }
        var shards = ring.shards
        while shards.count >= 2, shards[1].openedAt < threshold {
            let shard = shards.removeFirst()
            if let events = try? EventLogReader.read(shard.url).events {
                eventState.fold(events)
            }
            unlink(shard.url.path)
        }
        self.ring?.shards = shards
    }

    /// Every `syncInterval`: writes a manifest change whose write failed, and the event log's buffer. Running out of
    /// space either way discards the Replay.
    private func maintain() async {
        while true {
            do {
                try await ticks.sleep(configuration.recording.syncInterval)
            } catch {
                return
            }
            guard state == .recording, let ring else { return }
            do {
                try ring.store?.flushPending()
            } catch {
                if isOutOfSpace(error) { diskFilled() }
            }
            do {
                try ring.log?.flush()
            } catch {
                if isOutOfSpace(error) { diskFilled() }
            }
        }
    }

    // MARK: - Disk space

    private func handleDiskVerdict(_ verdict: DiskSpaceVerdict) {
        guard state == .starting || state == .recording else { return }
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

    /// The volume is (almost) full: the Replay is deleted whole, once, and says `ReplayEnd.diskFull` (after `start()` if it
    /// is still starting).
    private func diskFilled() {
        switch state {
        case .starting:
            diskFullPending = true
        case .recording:
            warningsContinuation.yield(.stoppedForDiskSpace)
            _ = beginDiscard(end: .diskFull)
        case .idle, .discarding, .stopped:
            break
        }
    }

    // MARK: - Helpers

    /// Changes the manifest in memory (`ManifestStore.stage`): `maintain` writes it every `syncInterval`, and `freeze()`
    /// before it answers. Out of space, the Replay is discarded.
    private func updateManifest(_ store: ManifestStore, _ change: (inout Manifest) -> Void) {
        do {
            try store.stage(change)
        } catch {
            if isOutOfSpace(error) {
                diskFilled()
            } else {
                warningsContinuation.yield(.manifestWriteFailed)
            }
        }
    }
}
