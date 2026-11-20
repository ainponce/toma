// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

// The Replay's rotation in `TrackPipeline` (fases 4 y 5 plan 5c, decision 2), at scale: segments of 1 s. Only a pipeline
// with `PipelineContext.segmentRotation` rotates; a take's never does.

extension RealTimeRecordingTests {
    @Suite struct TrackRotationTests {
        @Test func segmentsRotateWithoutGapsAndStartOnAKeyFrame() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try PipelineRig(
                    in: directory, source: SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30), rotation: .seconds(1))
                try await rig.pipeline.start()
                try await Task.sleep(for: .milliseconds(3500))
                let segments = try await rig.close()

                try #require(segments.count >= 4, "\(segments.count) segments")
                #expect(segments.map(\.index) == Array(1...segments.count))
                #expect(segments.dropLast().allSatisfy { $0.endReason == .rotated })
                #expect(segments.last?.endReason == .stopped)
                for (k, next) in zip(segments, segments.dropFirst()) {
                    // The sample due closes one segment and opens the next at its own time: no gap, no overlap.
                    #expect(k.endHostTime == next.startHostTime, "segment \(k.index) ends where \(next.index) starts")
                }
                let frame = 1.0 / 30
                for segment in segments {
                    let span = try #require(segment.endHostTime).seconds(since: segment.startHostTime)
                    if segment.endReason == .rotated { #expect(span >= 1, "segment \(segment.index) lasts \(span) s") }
                    let duration = try await AVURLAsset(url: rig.url(of: segment)).load(.duration).seconds
                    #expect(abs(duration - span) <= frame + 0.002, "segment \(segment.index): file \(duration) s, span \(span) s")
                    #expect(try await firstVideoSampleIsSync(rig.url(of: segment)), "segment \(segment.index)")
                }
                let started = try EventLogReader.read(rig.log.url).events.compactMap { event -> (Int, HostTime)? in
                    guard case .segmentStarted(_, let index) = event.kind else { return nil }
                    return (index, event.t)
                }
                #expect(started.map(\.0) == segments.map(\.index))
                #expect(started.map(\.1) == segments.map(\.startHostTime))
            }
        }

        @Test func audioRotatesContiguously() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try PipelineRig(in: directory, source: SyntheticAudioSource(), rotation: .seconds(1))
                try await rig.pipeline.start()
                try await Task.sleep(for: .milliseconds(2500))
                let segments = try await rig.close()

                try #require(segments.count >= 3, "\(segments.count) segments")
                #expect(segments.dropLast().allSatisfy { $0.endReason == .rotated })
                for (k, next) in zip(segments, segments.dropFirst()) {
                    #expect(k.endHostTime == next.startHostTime, "segment \(k.index) ends where \(next.index) starts")
                }
                for segment in segments {
                    let span = try #require(segment.endHostTime).seconds(since: segment.startHostTime)
                    if segment.endReason == .rotated { #expect(span >= 1 && span < 1.05, "segment \(segment.index) lasts \(span) s") }
                    let duration = try await AVURLAsset(url: rig.url(of: segment)).load(.duration).seconds
                    #expect(abs(duration - span) < 0.002, "segment \(segment.index): file \(duration) s, span \(span) s")
                }
                // Every segment's clock anchors are logged after its `segmentStarted`, so each file keeps its own.
                let events = try EventLogReader.read(rig.log.url).events
                for segment in segments {
                    #expect(events.contains { $0.kind == .segmentStarted(track: "mic", index: segment.index) })
                }
            }
        }

        @Test func staticScreenRotatesWithItsLastFrame() async throws {
            try await withTemporaryDirectory { directory in
                let ticks = ManualTicks()
                // A heartbeat is stamped `heartbeatSafetyMargin` before `clock()`: the clock moves before every tick, as
                // the timer's would.
                let clock = OffsetClock()
                let source = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30, clock: clock.now)
                let rig = try PipelineRig(
                    in: directory, source: source, rotation: .seconds(1), writerFactory: patientWriter, clock: clock.now,
                    ticks: ticks.ticks)
                try await rig.pipeline.start()
                #expect(await eventually { rig.segments.count == 1 })
                source.pauseFrames(true)
                try await Task.sleep(for: .milliseconds(100))  // the frames on their way arrive
                let interval = RecordingConfiguration().heartbeatInterval
                // The first tick after frames only sets their count back to 0; the next, over a second into the
                // segment, rotates instead of repeating the frame.
                clock.advance(seconds: 0.5)
                await ticks.fire(every: interval)
                #expect(rig.segments.count == 1)
                clock.advance(seconds: 1)
                let before = clock.now()
                await ticks.fire(every: interval)
                let after = clock.now()
                #expect(await eventually { rig.segments.count == 2 && rig.segments[0].endReason == .rotated })
                let segments = try await rig.close(at: clock.now().adding(seconds: 0.3))

                try #require(segments.count == 2)
                let rotatedAt = try #require(segments[0].endHostTime)
                #expect(rotatedAt >= before.adding(seconds: -TrackPipeline.heartbeatSafetyMargin))
                #expect(rotatedAt <= after.adding(seconds: -TrackPipeline.heartbeatSafetyMargin))
                #expect(segments[1].startHostTime == rotatedAt)
                #expect(segments[0].heartbeatFrames == 0)
                #expect(segments[1].endReason == .stopped)
                // The new segment starts with the image the old one ended with.
                let first = try await decodedFrameIndices(of: rig.url(of: segments[0]))
                let second = try await decodedFrameIndices(of: rig.url(of: segments[1]))
                #expect(second.first == first.last)
                #expect(Set(second) == [try #require(first.last)])
                #expect(try await firstVideoSampleIsSync(rig.url(of: segments[1])))
            }
        }

        @Test func forcedRotationClosesAndReturnsTheIndex() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try PipelineRig(
                    in: directory, source: SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30), rotation: .seconds(60))
                try await rig.pipeline.start()
                #expect(await eventually { rig.segments.count == 1 })
                try await Task.sleep(for: .milliseconds(500))
                #expect(await rig.pipeline.rotate() == 1)
                // Durable and in the manifest by then, and the sample that closed it opened the next one.
                var segments = rig.segments
                try #require(segments.count == 2)
                #expect(segments[0].endReason == .rotated)
                #expect(segments[0].endHostTime == segments[1].startHostTime)
                try await Task.sleep(for: .milliseconds(300))
                #expect(await rig.pipeline.rotate() == 2)
                segments = try await rig.close()

                #expect(segments.map(\.endReason) == [.rotated, .rotated, .stopped])
                #expect(segments[1].endHostTime == segments[2].startHostTime)
                for segment in segments {
                    #expect(try await firstVideoSampleIsSync(rig.url(of: segment)), "segment \(segment.index)")
                }
            }
        }

        @Test func forcedRotationOfAStaticScreenSeedsTheNextSegmentAtOnce() async throws {
            try await withTemporaryDirectory { directory in
                let source = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                let rig = try PipelineRig(in: directory, source: source, rotation: .seconds(60))
                try await rig.pipeline.start()
                #expect(await eventually { rig.segments.count == 1 })
                try await Task.sleep(for: .milliseconds(300))
                source.pauseFrames(true)
                try await Task.sleep(for: .milliseconds(300))
                let before = HostTime.now()
                let index = await rig.pipeline.rotate()
                let after = HostTime.now()

                #expect(index == 1)
                // No frame to wait for: it did not wait for `rotationWait`.
                #expect(after.seconds(since: before) < 0.8)
                let live = rig.segments
                try #require(live.count == 2)
                let rotatedAt = try #require(live[0].endHostTime)
                #expect(rotatedAt >= before.adding(seconds: -TrackPipeline.heartbeatSafetyMargin))
                #expect(rotatedAt <= after.adding(seconds: -TrackPipeline.heartbeatSafetyMargin))
                #expect(live[1].startHostTime == rotatedAt)
                try await Task.sleep(for: .milliseconds(200))
                let segments = try await rig.close()

                #expect(segments.map(\.endReason) == [.rotated, .stopped])
                let first = try await decodedFrameIndices(of: rig.url(of: segments[0]))
                let second = try await decodedFrameIndices(of: rig.url(of: segments[1]))
                #expect(second.first == first.last)
            }
        }

        @Test func forcedRotationOfASilentAudioEndsAtItsLastSample() async throws {
            try await withTemporaryDirectory { directory in
                let ticks = ManualTicks()
                let source = ManualAudioSource()
                let rig = try PipelineRig(in: directory, source: source, rotation: .seconds(60), ticks: ticks.ticks)
                try await rig.pipeline.start()
                let start = HostTime.now()
                for block in 0..<5 {
                    await source.emit(pts: start.adding(seconds: Double(block) * 0.01), frames: 480)
                }
                #expect(rig.segments.count == 1)
                let rotation = Task { await rig.pipeline.rotate() }
                // No sample comes: the segment closes once `rotationWait` has passed, not before.
                #expect(await eventually { ticks.pendingSleeps(of: TrackPipeline.rotationWait) == 1 })
                #expect(rig.segments.first?.endHostTime == nil)
                await ticks.releaseSleep(of: TrackPipeline.rotationWait)
                #expect(await rotation.value == 1)
                let closed = try #require(rig.segments.first)
                #expect(closed.endReason == .rotated)
                #expect(closed.endHostTime == start.adding(seconds: 0.05))
                // The next sample opens the next segment at its own time.
                let later = start.adding(seconds: 0.5)
                await source.emit(pts: later, frames: 480)
                let segments = try await rig.close(at: later.adding(seconds: 0.01))

                #expect(segments.map(\.endReason) == [.rotated, .stopped])
                #expect(segments[1].startHostTime == later)
                #expect(ticks.pendingSleeps(of: TrackPipeline.rotationWait) == 0)
            }
        }

        @Test func aPipelineWithoutRotationNeverRotates() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try PipelineRig(
                    in: directory, source: SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30), rotation: nil)
                try await rig.pipeline.start()
                try await Task.sleep(for: .seconds(2))
                // Without `segmentRotation`, asking does nothing.
                #expect(await rig.pipeline.rotate() == nil)
                try await Task.sleep(for: .seconds(1))
                let segments = try await rig.close()

                #expect(segments.map(\.endReason) == [.stopped])
                #expect(try #require(segments.first?.endHostTime).seconds(since: segments[0].startHostTime) > 2.5)
            }
        }

        @Test func rotationDropsAtMostOneFramePerSegment() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try PipelineRig(
                    in: directory, source: SyntheticVideoSource(width: 640, height: 360, framesPerSecond: 30), rotation: .seconds(1))
                try await rig.pipeline.start()
                try await Task.sleep(for: .seconds(4))
                let segments = try await rig.close()

                try #require(segments.count >= 4)
                let dropped = segments.map(\.droppedFrames).reduce(0, +)
                #expect(dropped <= segments.count, "\(dropped) frames dropped in \(segments.count) segments")
            }
        }

        /// The cost of a rotation at 4K 60 fps: frames dropped by each one, and how long the capture queue was held at
        /// each one (the delivery that rotated, and the lag of the frames after it). `TOMA_BENCH=1` only.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
        func replayRotationCost() async throws {
            try await withTemporaryDirectory { directory in
                let timed = TimedSource(inner: SyntheticVideoSource(width: 3840, height: 2160, framesPerSecond: 60))
                let rig = try PipelineRig(in: directory, source: timed, rotation: .seconds(10))
                try await rig.pipeline.start()
                try await Task.sleep(for: .seconds(60))
                let segments = try await rig.close()

                let deliveries = timed.deliveries
                var lines: [String] = []
                for segment in segments.dropFirst() {
                    // The delivery whose sample opened the segment, and the worst lag of the second after it.
                    guard let at = deliveries.firstIndex(where: { $0.pts == segment.startHostTime }) else { continue }
                    let held = deliveries[at].seconds
                    let after = deliveries[at...].prefix { $0.pts.seconds(since: segment.startHostTime) < 1 }
                    let lag = after.map(\.lag).max() ?? 0
                    lines.append(String(
                        format: "segment %d: delivery %.1f ms, worst lag after %.1f ms", segment.index, held * 1000, lag * 1000))
                }
                let typical = deliveries.map(\.seconds).sorted()[deliveries.count / 2]
                print("replayRotationCost: \(segments.count) segments, dropped \(segments.map(\.droppedFrames)), "
                    + "\(deliveries.count) frames, median delivery \(String(format: "%.2f", typical * 1000)) ms")
                for line in lines { print("replayRotationCost: " + line) }
            }
        }
    }
}

// MARK: - Support

/// One track recorded by a `TrackPipeline` straight into a fresh package, rotating every `rotation` as the Replay's do.
struct PipelineRig {
    let package: ProjectPackage
    let store: ManifestStore
    let log: EventLogWriter
    let pipeline: TrackPipeline
    let trackID: String
    let clock: @Sendable () -> HostTime

    init(
        in directory: URL, source: any CaptureSource, rotation: Duration?, configuration: RecordingConfiguration = .init(),
        writerFactory: WriterFactory? = nil, clock: @escaping @Sendable () -> HostTime = HostTime.now,
        ticks: RecordingTicks = .live
    ) throws {
        package = try ProjectPackage.create(in: directory, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let takeID = "take-001"
        trackID = source.trackID
        self.clock = clock
        try FileManager.default.createDirectory(
            at: package.trackDirectory(take: takeID, track: source.trackID), withIntermediateDirectories: true)
        store = try ManifestStore(package: package)
        try store.update {
            $0.takes.append(TakeRecord(
                id: takeID, status: .recording, startedAt: Date(), tracks: [SystemAudioTracks.trackRecord(of: source)]))
        }
        log = try EventLogWriter(url: package.eventsURL(take: takeID))
        let (_, warnings) = AsyncStream.makeStream(of: RecordingWarning.self)
        var context = PipelineContext(
            package: package, takeID: takeID, store: store, log: log, warnings: warnings, configuration: configuration,
            writerFactory: writerFactory ?? { url, media in try FragmentedTrackWriter(url: url, media: media) },
            clock: clock, ticks: ticks, onDiskFull: {}, freeBytes: { nil })
        context.segmentRotation = rotation
        pipeline = TrackPipeline(source: source, context: context, isSoleScreen: source.kind.isScreen)
    }

    /// The track's segments as the manifest has them now.
    var segments: [SegmentRecord] {
        store.manifest.takes.first?.tracks.first?.segments ?? []
    }

    func url(of segment: SegmentRecord) -> URL {
        package.url.appending(path: segment.file)
    }

    /// Closes the pipeline at `time` (`clock()` by default) and the log, and returns the segments.
    func close(at time: HostTime? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [SegmentRecord] {
        let failures = await pipeline.close(reason: .stopped, at: time ?? clock())
        #expect(failures.isEmpty, "\(failures)", sourceLocation: sourceLocation)
        try log.close()
        return segments
    }
}

/// A real-time writer that waits up to a second for the encoder instead of skipping: manual ticks come microseconds
/// apart, not a heartbeat interval.
let patientWriter: WriterFactory = { url, media in
    let writer = try FragmentedTrackWriter(url: url, media: media)
    writer.inputHasRoom = { input in
        let deadline = HostTime.now().adding(seconds: 1)
        while !input.isReadyForMoreMediaData, HostTime.now() < deadline { usleep(1000) }
        return input.isReadyForMoreMediaData
    }
    return writer
}

/// Whether the first video sample of the movie at `url` is a sync sample (a key frame), read without decoding.
func firstVideoSampleIsSync(_ url: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let flags = try await readTrack(track, of: asset, outputSettings: nil, into: [Bool]()) { flags, sample in
        guard flags.isEmpty, CMSampleBufferGetNumSamples(sample) > 0 else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        flags.append(!(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false))
    }
    return flags.first ?? false
}

/// A microphone that delivers only what the test emits, when it emits it.
final class ManualAudioSource: CaptureSource {
    let trackID = "mic"
    let kind = TrackKind.microphone
    let media = TrackMedia.audio
    var sourceInfo: TrackSource { TrackSource(name: "Manual Microphone", deviceUniqueID: "manual-mic") }
    var activeDeviceUniqueID: String? { nil }

    private let run = Mutex<(queue: DispatchSerialQueue, sink: any CaptureSink)?>(nil)

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        run.withLock { $0 = (queue, sink) }
    }

    func stop() async {
        let queue = run.withLock { run in
            defer { run = nil }
            return run?.queue
        }
        await queue?.drain()
    }

    /// Delivers a block of `frames` at 48 kHz presenting at `pts`, and returns once the sink has it.
    func emit(pts: HostTime, frames: Int) async {
        guard let current = run.withLock({ $0 }) else { return }
        let trackID = trackID
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            current.queue.async {
                current.sink.source(trackID, didOutput: SampleFactory.audioSample(pts: pts, frames: frames, sampleRate: 48_000, channels: 1))
                done.resume()
            }
        }
    }
}

/// A source whose every delivery is timed: how long the sink took with it, and how late it came after its PTS.
final class TimedSource: CaptureSource {
    struct Delivery: Sendable {
        var pts: HostTime
        /// How long the sink call took.
        var seconds: Double
        /// When it was delivered, after its PTS.
        var lag: Double
    }

    let inner: SyntheticVideoSource
    private let log = Mutex<[Delivery]>([])

    init(inner: SyntheticVideoSource) {
        self.inner = inner
    }

    var trackID: String { inner.trackID }
    var kind: TrackKind { inner.kind }
    var media: TrackMedia { inner.media }
    var sourceInfo: TrackSource { inner.sourceInfo }
    var activeDeviceUniqueID: String? { inner.activeDeviceUniqueID }
    var deliveries: [Delivery] { log.withLock { $0 } }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await inner.start(on: queue, sink: TimingSink(sink: sink) { [weak self] delivery in
            self?.log.withLock { $0.append(delivery) }
        })
    }

    func stop() async {
        await inner.stop()
    }
}

private final class TimingSink: CaptureSink {
    private let sink: any CaptureSink
    private let record: @Sendable (TimedSource.Delivery) -> Void

    init(sink: any CaptureSink, record: @escaping @Sendable (TimedSource.Delivery) -> Void) {
        self.sink = sink
        self.record = record
    }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        let pts = HostTime(sample.presentationTimeStamp)
        let start = HostTime.now()
        sink.source(trackID, didOutput: sample)
        record(TimedSource.Delivery(pts: pts, seconds: HostTime.now().seconds(since: start), lag: start.seconds(since: pts)))
    }

    func source(_ trackID: String, didStopWithError error: any Error) {
        sink.source(trackID, didStopWithError: error)
    }
}
