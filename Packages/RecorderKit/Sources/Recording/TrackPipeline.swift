// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Darwin
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// What every pipeline of a take shares with the coordinator.
struct PipelineContext: Sendable {
    let package: ProjectPackage
    let takeID: String
    let store: ManifestStore
    let log: EventLogWriter
    let warnings: AsyncStream<RecordingWarning>.Continuation
    let configuration: RecordingConfiguration
    let writerFactory: WriterFactory
    let clock: @Sendable () -> HostTime
    let ticks: RecordingTicks
    /// A write ran out of disk space. Gives the take's reserve back before returning, so the writes
    /// that follow have room, and has the coordinator close the take as `diskFull`.
    let onDiskFull: @Sendable () -> Void
    /// Space free right now on the recording volume, `nil` if it cannot be read.
    let freeBytes: @Sendable () -> Int64?
    /// Only the Replay's (fases 4 y 5 design §10.2): every segment of the track closes `rotated` once it lasts this long,
    /// and the next one opens at once (`TrackPipeline.rotate()`). `nil` in every take: `RecordingCoordinator` never
    /// passes it, and a pipeline without it never rotates.
    var segmentRotation: Duration? = nil

    /// Below this much free space, a writer failure of any shape is taken as the disk filling up: room
    /// for the take's reserve twice over.
    static let fullVolumeBytes = 2 * Int64(TakeReserve.size)

    /// Whether a writer's `failure` means the volume is full: recognized as out of space
    /// (`isOutOfSpace`), or of a shape AVFoundation also reports a full disk with (a bare -11800, say)
    /// while the volume has less than `fullVolumeBytes` free.
    func isDiskFull(_ failure: any Error) -> Bool {
        if isOutOfSpace(failure) { return true }
        guard let free = freeBytes() else { return false }
        return free < Self.fullVolumeBytes
    }

    /// Changes one track of the take in the manifest. A failed write is reported as
    /// `manifestWriteFailed`; the change stays in memory and the next write retries it. A write that
    /// failed for lack of space is retried at once, after the reserve is given back.
    ///
    /// With `segmentRotation` (the Replay's working package, never recovered) the change is only staged in memory
    /// (`ManifestStore.stage`): the Replay writes it, off the capture queues.
    func updateTrack(_ trackID: String, _ change: (inout TrackRecord) -> Void) {
        let body = { (manifest: inout Manifest) in
            guard let take = manifest.takes.firstIndex(where: { $0.id == takeID }),
                  let track = manifest.takes[take].tracks.firstIndex(where: { $0.id == trackID })
            else { return }
            change(&manifest.takes[take].tracks[track])
        }
        do {
            if segmentRotation != nil {
                try store.stage(body)
            } else {
                try store.update(body)
            }
        } catch {
            if isOutOfSpace(error) {
                onDiskFull()
                if (try? store.flushPending()) != nil { return }
            }
            warnings.yield(.manifestWriteFailed)
        }
    }
}

/// Records one capture source into segment files, opening a new segment at every interruption.
///
/// The source delivers on `queue`, which is also this actor's executor, so the sink calls enter the
/// actor with `assumeIsolated`. Restarts and their waits (`RecordingTicks.sleep`), `finish` and the
/// coordinator's commands are actor methods and resume on the same queue.
///
/// Every access to `state` runs inside a dispatch block on `queue`: the sink calls, the timers
/// (`RecordingTicks.every` runs them on `queue`), and `onQueue` for the actor's jobs. Jobs and blocks
/// are serialized by the queue either way, but ThreadSanitizer models that ordering only between
/// dispatch blocks, not for Swift jobs on the same queue, and can report state they share as a race (a
/// standalone reproduction does). So jobs never touch `state` directly. A writer handed to a finishing
/// task has left `state`; only that task uses it.
actor TrackPipeline: CaptureSink {
    /// How far behind the clock a heartbeat is stamped, so it never lands after a frame that was
    /// captured but not delivered yet (the writer would reject that frame).
    static let heartbeatSafetyMargin = 0.1

    let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let trackID: String
    private let source: any CaptureSource
    private let media: TrackMedia
    private let context: PipelineContext
    /// The only screen of the take (its one display or window): it keeps retrying instead of being given up,
    /// and warns `displayPaused` once its attempts are used up.
    private let isSoleScreen: Bool
    /// The track keeps retrying once its restart attempts are used up (`RestartPolicy.keepsRetrying`).
    private let keepsRetrying: Bool
    private let heartbeatTimer: (any RecordingTimer)?
    private let syncTimer: any RecordingTimer
    private var state: State

    private enum Phase: Equatable {
        /// Not started yet.
        case idle
        /// Run `run` of the source was started (or is starting): samples are written.
        case running(run: Int)
        /// The stream failed; the restart task is bringing it back.
        case restarting
        /// Restarts were exhausted; nothing is written until a resume.
        case lost
        case paused
        /// The take is closing; nothing restarts and samples are dropped.
        case closing
    }

    private struct State {
        var phase = Phase.idle
        var runs = 0
        var segment: OpenSegment?
        var nextIndex = 1
        var restartTask: Task<Void, Never>?
        /// Bumped for every restart task, so one that ends only clears its own handle.
        var restartTasks = 0
        /// Segments being finished, by finishing number.
        var finishing: [Int: Task<Void, Never>] = [:]
        var finishCount = 0
        /// Failures for `close` to report: finishing, syncing or opening the segment file.
        var errors: [any Error] = []
        var syncFailed = false
        var deviceUniqueID: String?
        /// A writer hit ENOSPC: samples are dropped until the take closes.
        var outOfDiskSpace = false
        var writerBackoff: WriterFailureBackoff
        /// No segment opens before this time: `clock()` when a writer failed, plus the wait
        /// `writerBackoff` gave; `nil` when the next sample may open one.
        var reopenNotBefore: HostTime?
        var accounting = SegmentAccounting()
    }

    /// The segment being written. Owned by `state` until it is closed, then by its finishing task.
    private final class OpenSegment {
        let writer: any TrackWriting
        let index: Int
        let url: URL
        let file: String
        let startSignal: StartSignal
        var startHostTime: HostTime?
        /// Read-only descriptor of the file, for the periodic `barrierSync`; -1 if not open.
        var fd: Int32 = -1
        /// Where the newest sample taken ends: its PTS, plus its duration when it has one (audio).
        var lastSampleEnd: HostTime?
        /// Newest PTS the writer took, frame or heartbeat. The next heartbeat must come after it.
        var lastTakenPTS: HostTime?
        var framesSinceHeartbeatTick = 0
        /// Samples this pipeline dropped that belong to this segment, beyond the writer's own count.
        var dropped = 0
        /// The running total last logged as `droppedSamples`.
        var loggedDropped = 0
        /// Made once the segment's start is known.
        var audioClock: AudioClockAnchors?
        /// Only with `segmentRotation`: `rotate()` asked this segment to close; the next sample (or the wait) does it.
        var rotationRequested = false
        /// The `rotate()` calls waiting for this segment to close, answered by its finishing task.
        var rotationWaiters: [CheckedContinuation<Int?, Never>] = []
        /// Closes the segment after `rotationWait` if no sample came first; cancelled when it closes.
        var rotationWait: Task<Void, Never>?

        init(writer: any TrackWriting, index: Int, url: URL, file: String, startSignal: StartSignal) {
            self.writer = writer
            self.index = index
            self.url = url
            self.file = file
            self.startSignal = startSignal
        }

        /// The latest time the segment holds: its last sample's end or its last heartbeat.
        var latestTime: HostTime? {
            switch (lastSampleEnd, lastTakenPTS) {
            case let (end?, taken?): max(end, taken)
            case let (end, taken): end ?? taken
            }
        }
    }

    /// Set by the writer's `onStart`. Separate from `OpenSegment` so the writer does not retain it.
    private final class StartSignal {
        var hostTime: HostTime?
    }

    /// How the timers, made in `init` before the pipeline exists, reach it: weakly, so they never keep it alive.
    private final class TimerTarget: Sendable {
        private struct Reference {
            weak var pipeline: TrackPipeline?
        }

        private let reference = Mutex(Reference())

        var pipeline: TrackPipeline? {
            get { reference.withLock { $0.pipeline } }
            set { reference.withLock { $0.pipeline = newValue } }
        }
    }

    private struct ClosingSegment {
        let segment: OpenSegment
        let reason: SegmentEndReason
        let stopTime: HostTime
        /// The writer failure behind `reason` was already reported.
        let failureReported: Bool
    }

    enum RunOutcome: Sendable {
        case started
        /// The run failed while starting, or another run owns the source now: the restart task, if
        /// any, takes it from here, and the source must not be stopped.
        case failed
        /// The pipeline was paused, closed or never started meanwhile: the source must be stopped.
        case superseded
    }

    init(source: any CaptureSource, context: PipelineContext, isSoleScreen: Bool) {
        let queue = DispatchSerialQueue(label: "dev.toma.TrackPipeline.\(source.trackID)", qos: .userInitiated)
        self.queue = queue
        self.trackID = source.trackID
        self.source = source
        self.media = source.media
        self.context = context
        self.isSoleScreen = isSoleScreen
        self.keepsRetrying = RestartPolicy.keepsRetrying(kind: source.kind, isSoleScreen: isSoleScreen)
        self.state = State(writerBackoff: WriterFailureBackoff(backoff: context.configuration.restartBackoff))
        let target = TimerTarget()
        if case .video = source.media {
            heartbeatTimer = context.ticks.every(context.configuration.heartbeatInterval, queue) {
                target.pipeline?.heartbeatTimerFired()
            }
        } else {
            heartbeatTimer = nil
        }
        syncTimer = context.ticks.every(context.configuration.syncInterval, queue) { target.pipeline?.syncTimerFired() }
        target.pipeline = self
    }

    deinit {
        heartbeatTimer?.cancel()
        syncTimer.cancel()
    }

    // MARK: - Commands from the coordinator (jobs: `state` only through `onQueue`)

    /// Starts the source for the first time. Throws, leaving the pipeline idle, if it does not start.
    func start() async throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let run = await onQueue({ $0.beginRun(from: .idle) }) else { return }
        do {
            try await source.start(on: queue, sink: self)
        } catch {
            await onQueue { $0.runFailedToStart(run, restartOnFailure: false, error: error) }
            throw error
        }
        if await onQueue({ $0.runDidStart(run, endsRestart: false) }) == .superseded {
            await source.stop()
        }
    }

    /// Stops the source and closes the open segment with `paused` at `time`. Does not use the
    /// restart budget: a pending restart is dropped, and `resume()` starts afresh.
    func pause(at time: HostTime) async {
        dispatchPrecondition(condition: .onQueue(queue))
        let (entered, restart) = await onQueue { $0.enter(.paused) }
        guard entered else { return }
        restart?.cancel()
        await restart?.value
        await source.stop()
        await onQueue { $0.closeSegment(reason: .paused, at: time) }
        await waitForFinishing()
    }

    /// Starts the source again after `pause(at:)`. If it does not start, the restart backoff takes over.
    func resume() async {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let run = await onQueue({ $0.beginRun(from: .paused) }) else { return }
        do {
            try await source.start(on: queue, sink: self)
        } catch {
            await onQueue { $0.runFailedToStart(run, restartOnFailure: true, error: error) }
            return
        }
        if await onQueue({ $0.runDidStart(run, endsRestart: false) }) == .superseded {
            await source.stop()
        }
    }

    /// First step of closing: no more restarts or samples, and the source is stopped.
    func stopCapture() async {
        dispatchPrecondition(condition: .onQueue(queue))
        let (_, restart) = await onQueue { $0.enter(.closing) }
        restart?.cancel()
        await restart?.value
        await source.stop()
    }

    /// Closes the open segment with `reason` at `time`, waits for every segment being finished and
    /// returns the failures the pipeline collected. Stops capture first if `stopCapture()` did not.
    /// Samples dropped after the last segment ended are added to that segment's `droppedFrames`.
    func close(reason: SegmentEndReason, at time: HostTime) async -> [any Error] {
        dispatchPrecondition(condition: .onQueue(queue))
        await stopCapture()
        await onQueue { $0.closeSegment(reason: reason, at: time) }
        heartbeatTimer?.cancel()
        syncTimer.cancel()
        await waitForFinishing()
        let dropped = await onQueue { $0.state.accounting.takePending() }
        if dropped > 0 {
            context.updateTrack(trackID) { track in
                guard !track.segments.isEmpty else { return }
                track.segments[track.segments.count - 1].droppedFrames += dropped
            }
        }
        return await onQueue { pipeline in
            defer { pipeline.state.errors = [] }
            return pipeline.state.errors
        }
    }

    // MARK: - Rotation (only with `segmentRotation`: the Replay's)

    /// How long a forced rotation (`rotate()`) waits for the next sample of an audio track before it closes the segment
    /// at its last sample anyway (fases 4 y 5 plan 5c, decision 2).
    static let rotationWait: Duration = .seconds(1)

    /// Only with `segmentRotation` (the Replay's freeze): closes the open segment `rotated`, waits until it and every
    /// segment of the track closed before it are finished (each one's end in the manifest) and returns its index; `nil` if
    /// no segment had started (after the segments being finished are), and always without `segmentRotation`. A segment
    /// closed a moment earlier by a rotation by duration, still finishing its file, is never left out of what it answers.
    /// The files are not synced here: the Replay syncs the ones a save clones (`ReplayCoordinator.freeze()`).
    ///
    /// The next sample closes it and opens the next segment at its time, as a rotation by duration does. A video track
    /// that took no frame since `clock() − heartbeatSafetyMargin` (a still screen) closes there at once and seeds the next
    /// segment with its last frame at that instant. A segment the next sample does not close within `rotationWait` closes
    /// anyway: a video one seeded the same way, an audio one at the end of its last sample, the next segment opening
    /// with the next sample. A segment that closes for another reason first (a stream error, the close) answers too.
    func rotate() async -> Int? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard context.segmentRotation != nil else { return nil }
        let rotated = await withCheckedContinuation { (answer: CheckedContinuation<Int?, Never>) in
            queue.async {
                self.assumeIsolated { $0.requestRotation(answer) }
            }
        }
        // Each close finishes in a task of its own, and a short segment can finish before a long one closed earlier.
        await waitForFinishing()
        return rotated
    }

    // MARK: - Jobs

    /// Brings the source back after a stream error, following a `RestartPolicy` of `restartBackoff`.
    /// Once the list is used up the sole screen, a microphone, a camera and system audio keep trying at its
    /// last interval, warning once `displayPaused` (the sole screen) or `trackPaused` (the others); any other
    /// track is lost. Stops as soon as a pause or the close takes over (it cancels this task).
    private func restart() async {
        dispatchPrecondition(condition: .onQueue(queue))
        var policy = RestartPolicy(backoff: context.configuration.restartBackoff, keepsRetrying: keepsRetrying)
        while true {
            let delay: Duration
            switch policy.next() {
            case .wait(let wait):
                delay = wait
            case .warnPausedThenWait(let wait):
                context.warnings.yield(isSoleScreen ? .displayPaused(track: trackID) : .trackPaused(track: trackID))
                delay = wait
            case .giveUp:
                if await onQueue({ $0.restartsExhausted() }) {
                    context.warnings.yield(.trackLost(track: trackID))
                }
                return
            }
            do {
                try await context.ticks.sleep(delay)
            } catch {
                return
            }
            guard let run = await onQueue({ $0.beginRun(from: .restarting) }) else { return }
            do {
                try await source.start(on: queue, sink: self)
            } catch {
                guard await onQueue({ $0.restartAttemptFailed(run) }) else { return }
                continue
            }
            switch await onQueue({ $0.runDidStart(run, endsRestart: true) }) {
            case .started:
                context.warnings.yield(.streamRestarted(track: trackID))
                return
            case .failed:
                continue
            case .superseded:
                await source.stop()
                return
            }
        }
    }

    /// Finishes a closed segment's writer, makes the file durable and then records how it ended.
    private func finish(_ closing: ClosingSegment, number: Int) async {
        dispatchPrecondition(condition: .onQueue(queue))
        let segment = closing.segment
        var errors: [any Error] = []
        var reason = closing.reason
        var end: HostTime?
        var dropped = segment.dropped
        var heartbeats = 0
        do {
            let result = try await segment.writer.finish(at: closing.stopTime)
            if result.startHostTime != nil {
                end = result.endHostTime
                dropped += result.droppedSampleCount
                heartbeats = result.heartbeatSampleCount
            }
        } catch {
            errors.append(error)
            let failure = error as NSError
            if context.isDiskFull(failure) {
                reason = .diskFull
                context.onDiskFull()
            } else {
                reason = .writerError(domain: failure.domain, code: failure.code)
            }
            if let start = segment.startHostTime {
                end = segment.latestTime ?? start
            }
        }
        if !closing.failureReported, let failure = segment.writer.failure {
            let diskFull = context.isDiskFull(failure)
            reason = diskFull ? .diskFull : .writerError(domain: failure.domain, code: failure.code)
            context.warnings.yield(.writerFailed(track: trackID))
            if diskFull { context.onDiskFull() }
        }
        // The manifest only says the segment ended once what it says is on the disk. Not the Replay's working package,
        // which is never recovered: its capture queues never wait for a sync, and a save syncs what it clones.
        if segment.fd >= 0 {
            if context.segmentRotation == nil {
                do { try DurableFile.fullSync(segment.fd) } catch { errors.append(error) }
            }
            Darwin.close(segment.fd)
        }
        if let end, segment.startHostTime != nil {
            let index = segment.index
            context.updateTrack(trackID) { track in
                guard let i = track.segments.firstIndex(where: { $0.index == index }) else { return }
                track.segments[i].endHostTime = end
                track.segments[i].endReason = reason
                track.segments[i].droppedFrames = dropped
                track.segments[i].heartbeatFrames = heartbeats
            }
        }
        let failures = errors
        await onQueue { pipeline in
            pipeline.state.finishing[number] = nil
            pipeline.state.errors.append(contentsOf: failures)
        }
        // `rotate()` answers once the segment's file is finished and the manifest says how it ended (durable in a take; in
        // the Replay's working package, synced by its freeze).
        let rotated = segment.startHostTime != nil ? segment.index : nil
        for waiter in segment.rotationWaiters { waiter.resume(returning: rotated) }
    }

    private func waitForFinishing() async {
        while true {
            let tasks = await onQueue { Array($0.state.finishing.values) }
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    /// Runs `body` isolated to this actor inside a dispatch block on `queue`. See the type's comment.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (isolated TrackPipeline) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.assumeIsolated { body($0) })
            }
        }
    }

    // MARK: - Sink and timers (dispatch blocks on `queue`)

    nonisolated func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        nonisolated(unsafe) let sample = sample
        assumeIsolated { $0.write(sample) }
    }

    nonisolated func source(_ trackID: String, didStopWithError error: any Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        assumeIsolated { $0.streamDidFail(error) }
    }

    private nonisolated func heartbeatTimerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        assumeIsolated { $0.heartbeat() }
    }

    private nonisolated func syncTimerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        assumeIsolated { pipeline in
            pipeline.logDroppedSamples()
            pipeline.syncSegmentFile()
        }
    }

    // MARK: - State (only ever called inside a dispatch block on `queue`)

    /// Writes one sample. A sample that cannot be written while capture runs is counted as dropped:
    /// in the open segment if it refused it, otherwise in the next segment.
    private func write(_ sample: CMSampleBuffer) {
        guard case .running = state.phase, !state.outOfDiskSpace else { return }
        guard let format = CMSampleBufferGetFormatDescription(sample), sample.presentationTimeStamp.isNumeric else {
            countDropped(in: nil)
            return
        }
        let pts = HostTime(sample.presentationTimeStamp)
        if let segment = state.segment, let current = segment.writer.formatDescription,
           !Self.continuesSegment(format, after: current, media: media) {
            closeSegment(reason: .formatChanged, at: pts)
        }
        // Only with `segmentRotation`: the sample due closes the segment at its time and opens the next one, no gap.
        if let segment = state.segment, rotationIsDue(segment, at: pts) {
            closeSegment(reason: .rotated, at: pts)
        }
        guard let segment = state.segment ?? openSegment() else {
            countDropped(in: nil)
            return
        }
        var appended = false
        do {
            try segment.writer.append(sample)
            appended = true
            state.accounting.written()
            segment.lastTakenPTS = pts
            segment.lastSampleEnd = max(segment.lastSampleEnd ?? pts, Self.end(of: sample, at: pts))
            switch media {
            case .video: segment.framesSinceHeartbeatTick += 1
            case .audio: logAudioClock(segment)
            }
        } catch {
            // Either the writer skipped this sample (its time is not after the previous one, or the
            // encoder stayed busy) and the next one goes on, or it failed, which is handled below.
        }
        if segment.startHostTime == nil, let start = segment.startSignal.hostTime {
            segmentDidStart(segment, at: start)
        }
        if let failure = segment.writer.failure {
            if !appended { countDropped(in: nil) }
            writerDidFail(segment, failure)
        } else if !appended {
            countDropped(in: segment)
        }
    }

    /// After an audio append, logs the `audioClock` anchor `AudioClockAnchors` gives for the sample the
    /// writer wrote last (`lastWrittenAudio`): the frame of the segment's file it starts at and its host time.
    private func logAudioClock(_ segment: OpenSegment) {
        guard let start = segment.startHostTime ?? segment.startSignal.hostTime,
              let written = segment.writer.lastWrittenAudio
        else { return }
        if segment.audioClock == nil { segment.audioClock = AudioClockAnchors(segmentStart: start) }
        guard let anchor = segment.audioClock?.anchor(for: written) else { return }
        context.log.append(InputEvent(t: anchor.hostTime, kind: .audioClock(track: trackID, frame: anchor.frame)))
    }

    /// Counts a sample that was not written, and warns once it has happened many times in a row.
    private func countDropped(in segment: OpenSegment?) {
        segment?.dropped += 1
        if state.accounting.dropped(withOpenSegment: segment != nil) {
            context.warnings.yield(.samplesDropped(track: trackID))
        }
    }

    /// Creates the writer of the next segment; its file appears with the first sample.
    private func openSegment() -> OpenSegment? {
        if let notBefore = state.reopenNotBefore, context.clock() < notBefore { return nil }
        while true {
            let index = state.nextIndex
            let url = context.package.segmentURL(take: context.takeID, track: trackID, index: index)
            do {
                let file = try context.package.relativePath(of: url)
                let writer = try context.writerFactory(url, media)
                state.nextIndex += 1
                let signal = StartSignal()
                writer.onStart = { [signal] in signal.hostTime = $0 }
                let segment = OpenSegment(writer: writer, index: index, url: url, file: file, startSignal: signal)
                segment.dropped = state.accounting.takePending()
                state.segment = segment
                return segment
            } catch WriterError.fileExists {
                // Left by a writer that never got going; it is never touched. Take the next number.
                state.nextIndex += 1
            } catch {
                context.warnings.yield(.writerFailed(track: trackID))
                noteWriterFailure(segmentSeconds: nil)
                return nil
            }
        }
    }

    private func segmentDidStart(_ segment: OpenSegment, at start: HostTime) {
        segment.startHostTime = start
        let record = SegmentRecord(
            index: segment.index, file: segment.file, startHostTime: start, droppedFrames: 0, heartbeatFrames: 0)
        context.updateTrack(trackID) { $0.segments.append(record) }
        context.log.append(InputEvent(t: start, kind: .segmentStarted(track: trackID, index: segment.index)))
        let fd = open(segment.url.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            segment.fd = fd
        } else {
            state.errors.append(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func writerDidFail(_ segment: OpenSegment, _ failure: NSError) {
        let diskFull = context.isDiskFull(failure)
        let reason: SegmentEndReason = diskFull ? .diskFull : .writerError(domain: failure.domain, code: failure.code)
        closeSegment(reason: reason, at: segment.latestTime ?? context.clock(), failureReported: true)
        context.warnings.yield(.writerFailed(track: trackID))
        if diskFull {
            state.outOfDiskSpace = true
            context.onDiskFull()
        } else {
            let lasted = segment.startHostTime.flatMap { start in segment.latestTime.map { $0.seconds(since: start) } }
            noteWriterFailure(segmentSeconds: lasted)
        }
    }

    /// Holds the next segment back for as long as `writerBackoff` says after a writer that held
    /// `segmentSeconds` of media failed (`nil`: it never started, or could not be created).
    private func noteWriterFailure(segmentSeconds: Double?) {
        state.reopenNotBefore = state.writerBackoff.writerFailed(segmentSeconds: segmentSeconds)
            .map { context.clock().adding(seconds: $0.seconds) }
    }

    /// Hands the open segment, if any, to a task that finishes it at `time`. A segment that never
    /// started has no record: its dropped samples go to the next segment, and so does its number
    /// when it left no file.
    private func closeSegment(reason: SegmentEndReason, at time: HostTime, failureReported: Bool = false) {
        guard let segment = state.segment else { return }
        state.segment = nil
        segment.rotationWait?.cancel()
        segment.rotationWait = nil
        if segment.startHostTime == nil {
            state.accounting.addPending(segment.dropped)
            segment.dropped = 0
            var existing = stat()
            if state.nextIndex == segment.index + 1, lstat(segment.url.path, &existing) != 0 {
                state.nextIndex = segment.index
            }
        } else if !failureReported, segment.writer.failure == nil {
            state.writerBackoff.segmentClosedNormally()
            state.reopenNotBefore = nil
        }
        let number = state.finishCount
        state.finishCount += 1
        let closing = ClosingSegment(segment: segment, reason: reason, stopTime: time, failureReported: failureReported)
        state.finishing[number] = Task { await self.finish(closing, number: number) }
    }

    private func streamDidFail(_ error: any Error) {
        guard case .running = state.phase else { return }
        let failure = error as NSError
        let now = context.clock()
        closeSegment(
            reason: .streamError(domain: failure.domain, code: failure.code),
            at: state.segment?.latestTime ?? now)
        context.log.append(InputEvent(
            t: now, kind: .streamInterrupted(track: trackID, domain: failure.domain, code: failure.code)))
        context.warnings.yield(.streamInterrupted(track: trackID))
        state.phase = .restarting
        startRestartingIfNeeded()
    }

    /// Starts the restart task unless one is running already (it notices the new failure itself).
    /// However the task ends, it clears its own handle, so a later failure always gets a new one.
    private func startRestartingIfNeeded() {
        guard state.restartTask == nil else { return }
        state.restartTasks += 1
        let id = state.restartTasks
        state.restartTask = Task {
            await self.restart()
            await self.onQueue { pipeline in
                if pipeline.state.restartTasks == id { pipeline.state.restartTask = nil }
            }
        }
    }

    /// Writes a repeat of the last frame when no frame came during the last interval, so a static
    /// screen keeps producing fragments.
    private func heartbeat() {
        guard case .running = state.phase, let segment = state.segment, segment.startHostTime != nil else { return }
        defer { segment.framesSinceHeartbeatTick = 0 }
        guard segment.framesSinceHeartbeatTick == 0, let last = segment.lastTakenPTS else { return }
        let time = context.clock().adding(seconds: -Self.heartbeatSafetyMargin)
        guard time > last else { return }
        // Only with `segmentRotation`: a still screen rotates on its heartbeat.
        if rotationIsDue(segment, at: time) {
            rotateSeeding(segment, at: time)
            return
        }
        do {
            try segment.writer.appendHeartbeat(at: time)
            segment.lastTakenPTS = time
        } catch {
            // Skipped (the encoder is busy, or a frame got there first); a failure is handled below.
        }
        if let failure = segment.writer.failure {
            writerDidFail(segment, failure)
        }
    }

    /// Every `syncInterval`: logs the open segment's running total of dropped samples (its own and its
    /// writer's) as `droppedSamples` when it changed, without touching the manifest. A crash then
    /// loses at most the drops of the last interval: recovery takes `droppedFrames` from the last one.
    private func logDroppedSamples() {
        guard let segment = state.segment, segment.startHostTime != nil else { return }
        let count = segment.dropped + segment.writer.droppedSampleCount
        guard count != segment.loggedDropped else { return }
        segment.loggedDropped = count
        context.log.append(InputEvent(t: context.clock(), kind: .droppedSamples(track: trackID, count: count)))
    }

    private func syncSegmentFile() {
        // Not the Replay's: its working package is never recovered.
        guard context.segmentRotation == nil, let segment = state.segment, segment.fd >= 0 else { return }
        do {
            try DurableFile.barrierSync(segment.fd)
        } catch {
            // Reported once by `close`; the full sync at the end of the segment is tried anyway.
            if !state.syncFailed {
                state.syncFailed = true
                state.errors.append(error)
            }
        }
    }

    /// Moves to `phase` unless closing already, and takes the pending restart task, which the
    /// caller cancels and waits for.
    private func enter(_ phase: Phase) -> (entered: Bool, restart: Task<Void, Never>?) {
        guard state.phase != .closing || phase == .closing else { return (false, nil) }
        state.phase = phase
        defer { state.restartTask = nil }
        return (true, state.restartTask)
    }

    private func beginRun(from expected: Phase) -> Int? {
        guard state.phase == expected else { return nil }
        state.runs += 1
        state.phase = .running(run: state.runs)
        return state.runs
    }

    /// The source's `start` threw. A failed resume goes to the restart backoff; a failed first start
    /// goes back to idle for the coordinator to roll back.
    private func runFailedToStart(_ run: Int, restartOnFailure: Bool, error: any Error) {
        guard state.phase == .running(run: run) else { return }
        guard restartOnFailure else {
            state.phase = .idle
            return
        }
        let failure = error as NSError
        context.log.append(InputEvent(
            t: context.clock(), kind: .streamInterrupted(track: trackID, domain: failure.domain, code: failure.code)))
        context.warnings.yield(.streamInterrupted(track: trackID))
        state.phase = .restarting
        startRestartingIfNeeded()
    }

    /// A restart attempt's `start` threw. Returns whether the restart task should go on.
    private func restartAttemptFailed(_ run: Int) -> Bool {
        guard state.phase == .running(run: run) else { return false }
        state.phase = .restarting
        return true
    }

    private func restartsExhausted() -> Bool {
        guard state.phase == .restarting else { return false }
        state.phase = .lost
        state.restartTask = nil
        return true
    }

    /// The source's `start` for `run` returned. Logs `deviceChanged` if it now captures another
    /// device. Only a pause, the close or an idle pipeline makes the caller stop the source: a later
    /// run (a restart that overtook a slow resume) owns it and must keep it.
    private func runDidStart(_ run: Int, endsRestart: Bool) -> RunOutcome {
        switch state.phase {
        case .running(run: run):
            if let device = source.activeDeviceUniqueID {
                if let previous = state.deviceUniqueID, previous != device {
                    context.log.append(InputEvent(
                        t: context.clock(), kind: .deviceChanged(track: trackID, deviceUniqueID: device)))
                }
                state.deviceUniqueID = device
            }
            if endsRestart { state.restartTask = nil }
            return .started
        case .running, .restarting:
            // The stream failed before `start` returned (`streamDidFail` already handled it), or a
            // restart started a newer run since.
            return .failed
        case .paused, .closing, .idle, .lost:
            return .superseded
        }
    }

    // MARK: - Rotation state (only with `segmentRotation`; dispatch blocks on `queue`)

    /// Whether `segment` closes `rotated` at `time`: only with `segmentRotation`, once it has started and `rotate()` asked
    /// or it lasts `segmentRotation` by `time`, and only at a time after everything it took, where the next one starts.
    private func rotationIsDue(_ segment: OpenSegment, at time: HostTime) -> Bool {
        guard let rotation = context.segmentRotation, let start = segment.startHostTime else { return false }
        guard segment.rotationRequested || time.nanoseconds >= start.nanoseconds &+ Self.nanoseconds(of: rotation) else {
            return false
        }
        return time > (segment.lastTakenPTS ?? start)
    }

    /// Closes `segment` `rotated` at `time` and opens the next segment there with the segment's last frame
    /// (`TrackWriting.lastVideoFrame`), so a still screen goes on without a gap. A writer without a last frame only closes.
    private func rotateSeeding(_ segment: OpenSegment, at time: HostTime) {
        let seed = segment.writer.lastVideoFrame.flatMap { try? SampleRetiming.sample($0, at: time) }
        closeSegment(reason: .rotated, at: time)
        guard let seed, let next = openSegment() else { return }
        do {
            try next.writer.append(seed)
            next.lastTakenPTS = time
            next.lastSampleEnd = time
        } catch {
            // Skipped (the encoder is busy): the next frame or heartbeat goes on; a failure is handled below.
        }
        if next.startHostTime == nil, let start = next.startSignal.hostTime {
            segmentDidStart(next, at: start)
        }
        if let failure = next.writer.failure {
            writerDidFail(next, failure)
        }
    }

    /// A video `segment` that took nothing after `clock() − heartbeatSafetyMargin` (a still screen) rotates there now,
    /// seeded with its last frame. Returns whether it did.
    private func rotateIfStill(_ segment: OpenSegment) -> Bool {
        guard let start = segment.startHostTime else { return false }
        let time = context.clock().adding(seconds: -Self.heartbeatSafetyMargin)
        guard time > (segment.lastTakenPTS ?? start) else { return false }
        rotateSeeding(segment, at: time)
        return true
    }

    /// `rotate()`'s request: `answer` gets the index of the segment it closes once that one is finished, or `nil` at once
    /// without a started segment.
    private func requestRotation(_ answer: CheckedContinuation<Int?, Never>) {
        guard case .running = state.phase, let segment = state.segment, segment.startHostTime != nil else {
            answer.resume(returning: nil)
            return
        }
        segment.rotationWaiters.append(answer)
        guard !segment.rotationRequested else { return }
        segment.rotationRequested = true
        if case .video = media, rotateIfStill(segment) { return }
        let index = segment.index
        segment.rotationWait = Task { [ticks = context.ticks] in
            do {
                try await ticks.sleep(Self.rotationWait)
            } catch {
                return  // the segment closed first
            }
            await self.onQueue { $0.rotationWaitEnded(segment: index) }
        }
    }

    /// No sample closed segment `index` within `rotationWait` of `rotate()`: a still video rotates seeded, anything else
    /// closes at its last sample and the next sample opens the next segment.
    private func rotationWaitEnded(segment index: Int) {
        // Never while closing: a rotation then would open a writer and its file as the track comes down.
        guard case .running = state.phase, let segment = state.segment, segment.index == index, segment.rotationRequested
        else { return }
        segment.rotationWait = nil
        if case .video = media, rotateIfStill(segment) { return }
        closeSegment(reason: .rotated, at: segment.latestTime ?? context.clock())
    }

    private static func nanoseconds(of duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }

    // MARK: - Helpers

    /// Whether a sample with `format` can go on in the segment that started with `current`: equal
    /// descriptions always can; otherwise the writer must accept it (`FragmentedTrackWriter.isCompatible`)
    /// and the media subtype must match, so an extension-only difference does not split the track but
    /// a sample the writer would refuse always opens a new segment.
    static func continuesSegment(_ format: CMFormatDescription, after current: CMFormatDescription, media: TrackMedia) -> Bool {
        if CMFormatDescriptionEqual(current, otherFormatDescription: format) { return true }
        return CMFormatDescriptionGetMediaSubType(current) == CMFormatDescriptionGetMediaSubType(format)
            && FragmentedTrackWriter.isCompatible(format, with: current, media: media)
    }

    /// Where `sample` ends: its PTS plus its duration when it has one.
    private static func end(of sample: CMSampleBuffer, at pts: HostTime) -> HostTime {
        let duration = sample.duration
        guard duration.isNumeric, duration > .zero else { return pts }
        return pts.adding(seconds: duration.seconds)
    }
}
