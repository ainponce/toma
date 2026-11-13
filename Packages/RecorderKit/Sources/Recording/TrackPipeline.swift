// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Dispatch
import Foundation
import ProjectFormat

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
    /// A writer ran out of disk space: the coordinator closes the take as `diskFull`.
    let onDiskFull: @Sendable () -> Void

    /// Changes one track of the take in the manifest. A failed write is reported as
    /// `manifestWriteFailed`; the change stays in memory and the next write retries it.
    func updateTrack(_ trackID: String, _ change: (inout TrackRecord) -> Void) {
        do {
            try store.update { manifest in
                guard let take = manifest.takes.firstIndex(where: { $0.id == takeID }),
                      let track = manifest.takes[take].tracks.firstIndex(where: { $0.id == trackID })
                else { return }
                change(&manifest.takes[take].tracks[track])
            }
        } catch {
            warnings.yield(.manifestWriteFailed)
        }
    }
}

/// Records one capture source into segment files, opening a new segment at every interruption.
///
/// The source delivers on `queue`, which is also this actor's executor, so the sink calls enter the
/// actor with `assumeIsolated`. Restarts, `Task.sleep`, `finish` and the coordinator's commands are
/// actor methods and resume on the same queue.
///
/// Every access to `state` runs inside a dispatch block on `queue`: the sink calls, the timers, and
/// `onQueue` for the actor's jobs. Jobs and blocks are serialized by the queue either way, but
/// ThreadSanitizer models that ordering only between dispatch blocks, not for Swift jobs on the same
/// queue, and can report state they share as a race (a standalone reproduction does). So jobs never
/// touch `state` directly. A writer handed to a finishing task has left `state`; only that task uses it.
actor TrackPipeline: CaptureSink {
    /// How far behind the clock a heartbeat is stamped, so it never lands after a frame that was
    /// captured but not delivered yet (the writer would reject that frame).
    static let heartbeatSafetyMargin = 0.1
    /// A segment that lasted at least this long before its writer failed does not count towards
    /// the backoff that repeated writer failures get.
    static let healthySegmentSeconds = 1.0

    let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let trackID: String
    private let source: any CaptureSource
    private let media: TrackMedia
    private let context: PipelineContext
    /// The only display of the take: it keeps retrying instead of being given up.
    private let isSoleDisplay: Bool
    private let heartbeatTimer: (any DispatchSourceTimer)?
    private let syncTimer: any DispatchSourceTimer
    private var state = State()

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
        /// Segments being finished, by finishing number.
        var finishing: [Int: Task<Void, Never>] = [:]
        var finishCount = 0
        /// Failures for `close` to report: finishing, syncing or opening the segment file.
        var errors: [any Error] = []
        var syncFailed = false
        var deviceUniqueID: String?
        /// A writer hit ENOSPC: samples are dropped until the take closes.
        var outOfDiskSpace = false
        /// Writers in a row that failed early or could not be created.
        var writerFailures = 0
        var reopenNotBefore: HostTime?
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

        init(writer: any TrackWriting, index: Int, url: URL, file: String, startSignal: StartSignal) {
            self.writer = writer
            self.index = index
            self.url = url
            self.file = file
            self.startSignal = startSignal
        }
    }

    /// Set by the writer's `onStart`. Separate from `OpenSegment` so the writer does not retain it.
    private final class StartSignal {
        var hostTime: HostTime?
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
        /// The run failed while starting; whoever owns restarts takes it from here.
        case failed
        /// The pipeline was paused or closed while the run started.
        case superseded
    }

    init(source: any CaptureSource, context: PipelineContext, isSoleDisplay: Bool) {
        let queue = DispatchSerialQueue(label: "dev.toma.TrackPipeline.\(source.trackID)", qos: .userInitiated)
        self.queue = queue
        self.trackID = source.trackID
        self.source = source
        self.media = source.media
        self.context = context
        self.isSoleDisplay = isSoleDisplay
        if case .video = source.media {
            heartbeatTimer = DispatchSource.makeTimerSource(queue: queue)
        } else {
            heartbeatTimer = nil
        }
        syncTimer = DispatchSource.makeTimerSource(queue: queue)

        let heartbeat = context.configuration.heartbeatInterval.dispatchInterval
        heartbeatTimer?.setEventHandler { [weak self] in self?.heartbeatTimerFired() }
        heartbeatTimer?.schedule(deadline: .now() + heartbeat, repeating: heartbeat, leeway: .milliseconds(10))
        heartbeatTimer?.activate()
        let sync = context.configuration.syncInterval.dispatchInterval
        syncTimer.setEventHandler { [weak self] in self?.syncTimerFired() }
        syncTimer.schedule(deadline: .now() + sync, repeating: sync, leeway: .milliseconds(50))
        syncTimer.activate()
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
    func close(reason: SegmentEndReason, at time: HostTime) async -> [any Error] {
        dispatchPrecondition(condition: .onQueue(queue))
        await stopCapture()
        await onQueue { $0.closeSegment(reason: reason, at: time) }
        heartbeatTimer?.cancel()
        syncTimer.cancel()
        await waitForFinishing()
        return await onQueue { pipeline in
            defer { pipeline.state.errors = [] }
            return pipeline.state.errors
        }
    }

    // MARK: - Jobs

    /// Brings the source back after a stream error, waiting `restartBackoff[n]` before attempt `n`.
    /// Once the list is used up the sole display keeps trying at its last interval; any other track
    /// is lost. Stops as soon as a pause or the close takes over (it cancels this task).
    private func restart() async {
        dispatchPrecondition(condition: .onQueue(queue))
        let backoff = context.configuration.restartBackoff
        var attempt = 0
        var reportedPaused = false
        while true {
            let delay: Duration
            if attempt < backoff.count {
                delay = backoff[attempt]
            } else if isSoleDisplay {
                if !reportedPaused {
                    reportedPaused = true
                    context.warnings.yield(.displayPaused(track: trackID))
                }
                delay = backoff.last ?? .seconds(1)
            } else {
                if await onQueue({ $0.restartsExhausted() }) {
                    context.warnings.yield(.trackLost(track: trackID))
                }
                return
            }
            attempt += 1
            do {
                try await Task.sleep(for: delay)
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

    /// Finishes a closed segment's writer and records how the segment ended.
    private func finish(_ closing: ClosingSegment, number: Int) async {
        dispatchPrecondition(condition: .onQueue(queue))
        let segment = closing.segment
        var errors: [any Error] = []
        var reason = closing.reason
        var end: HostTime?
        var dropped = 0
        var heartbeats = 0
        do {
            let result = try await segment.writer.finish(at: closing.stopTime)
            if result.startHostTime != nil {
                end = result.endHostTime
                dropped = result.droppedSampleCount
                heartbeats = result.heartbeatSampleCount
            }
        } catch {
            errors.append(error)
            let failure = error as NSError
            reason = .writerError(domain: failure.domain, code: failure.code)
            if let start = segment.startHostTime {
                end = segment.lastSampleEnd ?? start
            }
        }
        if !closing.failureReported, let failure = segment.writer.failure {
            let diskFull = Self.isDiskFull(failure)
            reason = diskFull ? .diskFull : .writerError(domain: failure.domain, code: failure.code)
            context.warnings.yield(.writerFailed(track: trackID))
            if diskFull { context.onDiskFull() }
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
        if segment.fd >= 0 {
            do { try DurableFile.fullSync(segment.fd) } catch { errors.append(error) }
            Darwin.close(segment.fd)
        }
        let failures = errors
        await onQueue { pipeline in
            pipeline.state.finishing[number] = nil
            pipeline.state.errors.append(contentsOf: failures)
        }
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
        assumeIsolated { $0.syncSegmentFile() }
    }

    // MARK: - State (only ever called inside a dispatch block on `queue`)

    private func write(_ sample: CMSampleBuffer) {
        guard case .running = state.phase, !state.outOfDiskSpace,
              let format = CMSampleBufferGetFormatDescription(sample),
              sample.presentationTimeStamp.isNumeric
        else { return }
        let pts = HostTime(sample.presentationTimeStamp)
        if let segment = state.segment, let current = segment.writer.formatDescription,
           !Self.isSameFormat(current, format) {
            closeSegment(reason: .formatChanged, at: pts)
        }
        guard let segment = state.segment ?? openSegment() else { return }
        do {
            try segment.writer.append(sample)
            segment.lastTakenPTS = pts
            segment.lastSampleEnd = max(segment.lastSampleEnd ?? pts, Self.end(of: sample, at: pts))
            if case .video = media { segment.framesSinceHeartbeatTick += 1 }
        } catch {
            // Either the writer skipped this sample (its time is not after the previous one, or the
            // encoder stayed busy) and the next one goes on, or it failed, which is handled below.
        }
        if segment.startHostTime == nil, let start = segment.startSignal.hostTime {
            segmentDidStart(segment, at: start)
        }
        if let failure = segment.writer.failure {
            writerDidFail(segment, failure)
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
                state.segment = segment
                return segment
            } catch WriterError.fileExists {
                // Left by a writer that never got going; it is never touched. Take the next number.
                state.nextIndex += 1
            } catch {
                context.warnings.yield(.writerFailed(track: trackID))
                noteWriterFailure(healthy: false)
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
        let diskFull = Self.isDiskFull(failure)
        let reason: SegmentEndReason = diskFull ? .diskFull : .writerError(domain: failure.domain, code: failure.code)
        closeSegment(reason: reason, at: segment.lastSampleEnd ?? context.clock(), failureReported: true)
        context.warnings.yield(.writerFailed(track: trackID))
        if diskFull {
            state.outOfDiskSpace = true
            context.onDiskFull()
        } else {
            let lasted = segment.startHostTime.flatMap { start in segment.lastSampleEnd.map { $0.seconds(since: start) } } ?? 0
            noteWriterFailure(healthy: lasted >= Self.healthySegmentSeconds)
        }
    }

    /// The next sample opens a new segment at once after a writer that ran fine for a while; writers
    /// that keep failing early wait `restartBackoff[n]` between attempts, so a broken writer does not
    /// spin out a file per sample.
    private func noteWriterFailure(healthy: Bool) {
        state.writerFailures = healthy ? 1 : state.writerFailures + 1
        let backoff = context.configuration.restartBackoff
        guard state.writerFailures > 1, !backoff.isEmpty else {
            state.reopenNotBefore = nil
            return
        }
        let delay = backoff[min(state.writerFailures - 2, backoff.count - 1)]
        state.reopenNotBefore = context.clock().adding(seconds: delay.seconds)
    }

    /// Hands the open segment, if any, to a task that finishes it at `time`.
    private func closeSegment(reason: SegmentEndReason, at time: HostTime, failureReported: Bool = false) {
        guard let segment = state.segment else { return }
        state.segment = nil
        if !failureReported, segment.startHostTime != nil, segment.writer.failure == nil {
            state.writerFailures = 0
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
            at: state.segment?.lastSampleEnd ?? now)
        context.log.append(InputEvent(
            t: now, kind: .streamInterrupted(track: trackID, domain: failure.domain, code: failure.code)))
        context.warnings.yield(.streamInterrupted(track: trackID))
        state.phase = .restarting
        startRestartingIfNeeded()
    }

    /// Starts the restart task unless one is running already (it notices the new failure itself).
    private func startRestartingIfNeeded() {
        guard state.restartTask == nil else { return }
        state.restartTask = Task { await self.restart() }
    }

    /// Writes a repeat of the last frame when no frame came during the last interval, so a static
    /// screen keeps producing fragments.
    private func heartbeat() {
        guard case .running = state.phase, let segment = state.segment, segment.startHostTime != nil else { return }
        defer { segment.framesSinceHeartbeatTick = 0 }
        guard segment.framesSinceHeartbeatTick == 0, let last = segment.lastTakenPTS else { return }
        let time = context.clock().adding(seconds: -Self.heartbeatSafetyMargin)
        guard time > last else { return }
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

    private func syncSegmentFile() {
        guard let segment = state.segment, segment.fd >= 0 else { return }
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

    /// The source's `start` returned. Logs `deviceChanged` if it now captures another device.
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
        case .restarting:
            // The stream failed before `start` returned (`streamDidFail` already handled it).
            return .failed
        default:
            return .superseded
        }
    }

    // MARK: - Helpers

    /// Whether `format` can go on in the segment that started with `current`. Equal descriptions
    /// always can; otherwise what the writer configures from must match (media type and subtype, plus
    /// dimensions for video or the stream description for audio), so an extension-only difference does
    /// not split the track.
    static func isSameFormat(_ current: CMFormatDescription, _ format: CMFormatDescription) -> Bool {
        if CMFormatDescriptionEqual(current, otherFormatDescription: format) { return true }
        let mediaType = CMFormatDescriptionGetMediaType(current)
        guard mediaType == CMFormatDescriptionGetMediaType(format),
              CMFormatDescriptionGetMediaSubType(current) == CMFormatDescriptionGetMediaSubType(format)
        else { return false }
        switch mediaType {
        case kCMMediaType_Video:
            let a = CMVideoFormatDescriptionGetDimensions(current)
            let b = CMVideoFormatDescriptionGetDimensions(format)
            return a.width == b.width && a.height == b.height
        case kCMMediaType_Audio:
            guard let a = CMAudioFormatDescriptionGetStreamBasicDescription(current)?.pointee,
                  let b = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { return false }
            return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
                && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
                && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
                && a.mBitsPerChannel == b.mBitsPerChannel
        default:
            return false
        }
    }

    /// Whether a writer failed because the volume is full, looking through underlying errors.
    static func isDiskFull(_ error: NSError, depth: Int = 0) -> Bool {
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
        return underlying.contains { isDiskFull($0, depth: depth + 1) }
    }

    /// Where `sample` ends: its PTS plus its duration when it has one.
    private static func end(of sample: CMSampleBuffer, at pts: HostTime) -> HostTime {
        let duration = sample.duration
        guard duration.isNumeric, duration > .zero else { return pts }
        return pts.adding(seconds: duration.seconds)
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(max(1, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)))
    }
}
