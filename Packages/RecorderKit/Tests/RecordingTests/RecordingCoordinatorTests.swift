// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

/// Real-time recordings of a few seconds each, run one at a time so their timing stays predictable.
@Suite(.serialized) struct RecordingCoordinatorTests {
    @Test func startStopProducesCompleteTake() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(2))
            let record = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            #expect(record == take)
            #expect(take.status == .complete)
            #expect(take.tracks.map(\.id) == ["mic", "display-1"])
            for track in take.tracks {
                try #require(track.segments.count == 1)
                let segment = track.segments[0]
                #expect(segment.index == 1)
                #expect(segment.endReason == .stopped)
                #expect(segment.file == "takes/\(id)/\(track.id)/seg-0001.mov")
                let end = try #require(segment.endHostTime)
                #expect(abs(end.seconds(since: segment.startHostTime) - 2) < 0.3)
                #expect(abs(try await rig.duration(of: segment) - 2) < 0.3)
            }
            #expect(rig.lockIsFree(id))
            let events = try rig.events(id)
            #expect(events.contains {
                $0.kind == .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 640, height: 360), scale: 1)
            })
            for track in take.tracks {
                #expect(events.contains {
                    $0.kind == .segmentStarted(track: track.id, index: 1) && $0.t == track.segments[0].startHostTime
                })
            }
            await rig.warningsDone.value
            #expect(rig.warnings.all.isEmpty)
        }
    }

    @Test func streamFailureOpensNewSegment() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(1))
            rig.display.failNow(domain: "SCStreamErrorDomain", code: -3821)
            try await Task.sleep(for: .seconds(2))
            _ = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            let display = try #require(take.track("display-1"))
            try #require(display.segments.count == 2)
            #expect(display.segments[0].endReason == .streamError(domain: "SCStreamErrorDomain", code: -3821))
            #expect(display.segments[1].index == 2 && display.segments[1].endReason == .stopped)
            let firstEnd = try #require(display.segments[0].endHostTime)
            #expect(display.segments[1].startHostTime >= firstEnd)
            #expect(try await rig.duration(of: display.segments[1]) > 1)
            #expect(take.track("mic")?.segments.map(\.endReason) == [.stopped])
            #expect(rig.display.startCount == 2)

            let events = try rig.events(id)
            #expect(events.contains {
                $0.kind == .streamInterrupted(track: "display-1", domain: "SCStreamErrorDomain", code: -3821)
            })
            #expect(events.contains { $0.kind == .segmentStarted(track: "display-1", index: 2) })
            await rig.warningsDone.value
            #expect(rig.warnings.all == [.streamInterrupted(track: "display-1"), .streamRestarted(track: "display-1")])
        }
    }

    @Test func soleDisplayKeepsRetryingUntilItReturns() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.display.failOnStart = 3
            rig.display.failNow(domain: "SCStreamErrorDomain", code: -3815)
            #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 2 })
            try await Task.sleep(for: .milliseconds(300))
            _ = try await rig.coordinator.stop()

            let display = try #require(try rig.takeOnDisk(id).track("display-1"))
            #expect(display.segments.map(\.endReason) == [.streamError(domain: "SCStreamErrorDomain", code: -3815), .stopped])
            #expect(rig.display.startCount == 5)
            await rig.warningsDone.value
            let warnings = rig.warnings.all
            #expect(warnings.contains(.displayPaused(track: "display-1")))
            #expect(warnings.contains(.streamRestarted(track: "display-1")))
            #expect(!warnings.contains(.trackLost(track: "display-1")))
        }
    }

    @Test func exhaustedRestartsMarkTrackLost() async throws {
        try await withTemporaryDirectory { directory in
            let configuration = RecordingConfiguration(restartBackoff: [.milliseconds(10), .milliseconds(10)])
            let rig = try Rig(in: directory, configuration: configuration)
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.mic.failOnStart = 99
            rig.mic.failNow(domain: "AVFoundationErrorDomain", code: -11819)
            #expect(await eventually { rig.warnings.all.contains(.trackLost(track: "mic")) })
            #expect(rig.mic.startCount == 3)
            try await Task.sleep(for: .milliseconds(500))
            _ = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            #expect(take.status == .complete)
            #expect(take.track("mic")?.segments.map(\.endReason) == [.streamError(domain: "AVFoundationErrorDomain", code: -11819)])
            let display = try #require(take.track("display-1"))
            #expect(display.segments.map(\.endReason) == [.stopped])
            #expect(try await rig.duration(of: display.segments[0]) > 0.9)
            #expect(rig.mic.startCount == 3)
            #expect(rig.lockIsFree(id))
        }
    }

    @Test func lockPausesAndUnlockResumes() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(1))
            rig.activity.yield(.screenLocked)
            #expect(await eventually {
                rig.liveTake(id)?.tracks.allSatisfy { $0.segments.map(\.endReason) == [.paused] } == true
            })
            try await Task.sleep(for: .seconds(1))
            rig.activity.yield(.screenUnlocked)
            #expect(await eventually { rig.liveTake(id)?.tracks.allSatisfy { $0.segments.count == 2 } == true })
            try await Task.sleep(for: .seconds(1))
            _ = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            for track in take.tracks {
                #expect(track.segments.map(\.endReason) == [.paused, .stopped])
                #expect(track.segments.map(\.index) == [1, 2])
                let pausedAt = try #require(track.segments[0].endHostTime)
                #expect(track.segments[1].startHostTime.seconds(since: pausedAt) > 0.8)
            }
            let events = try rig.events(id)
            let paused = try #require(events.firstIndex { $0.kind == .paused(reason: "screenLocked") })
            let resumed = try #require(events.firstIndex { $0.kind == .resumed })
            #expect(paused < resumed)
            #expect(events[paused].t == take.tracks[0].segments[0].endHostTime)
            #expect(rig.display.startCount == 2 && rig.mic.startCount == 2)
            await rig.warningsDone.value
            #expect(rig.warnings.all.isEmpty)
        }
    }

    @Test func wakeStaysPausedWhileTheScreenIsLocked() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(300))
            rig.activity.yield(.willSleep)
            rig.activity.yield(.screenLocked)
            rig.activity.yield(.didWake)
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.liveTrack(id, "display-1")?.segments.map(\.endReason) == [.paused])
            #expect(rig.display.startCount == 1)
            rig.activity.yield(.screenUnlocked)
            #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 2 })
            _ = try await rig.coordinator.stop()

            let events = try rig.events(id)
            #expect(events.filter { $0.kind == .paused(reason: "willSleep") }.count == 1)
            #expect(events.filter { $0.kind == .resumed }.count == 1)
            #expect(rig.display.startCount == 2)
        }
    }

    @Test func micRestartOnOtherDeviceLogsDeviceChanged() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.mic.deviceUniqueID = "usb-mic"
            rig.mic.failNow(domain: "AVFoundationErrorDomain", code: -11819)
            #expect(await eventually { rig.liveTrack(id, "mic")?.segments.count == 2 })
            _ = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            #expect(take.track("mic")?.source.deviceUniqueID == "synthetic-mic")
            let changes = try rig.events(id).filter {
                if case .deviceChanged = $0.kind { return true }
                return false
            }
            #expect(changes.map(\.kind) == [.deviceChanged(track: "mic", deviceUniqueID: "usb-mic")])
        }
    }

    @Test func writerFailureOpensNewSegment() async throws {
        try await withTemporaryDirectory { directory in
            let videoWriters = Mutex(0)
            let rig = try Rig(in: directory) { url, media in
                let inner = try FragmentedTrackWriter(url: url, media: media)
                guard case .video = media else { return inner }
                let first = videoWriters.withLock { count in
                    count += 1
                    return count == 1
                }
                return ScriptedWriter(inner: inner, failAfter: first ? 1 : nil)
            }
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(2500))
            _ = try await rig.coordinator.stop()

            let take = try rig.takeOnDisk(id)
            let display = try #require(take.track("display-1"))
            try #require(display.segments.count == 2)
            #expect(display.segments[0].endReason == .writerError(domain: "TestWriter", code: 7))
            #expect(display.segments[1].endReason == .stopped)
            #expect(abs(try await rig.duration(of: display.segments[0]) - 1) < 0.2)
            #expect(try await rig.duration(of: display.segments[1]) > 1)
            #expect(take.track("mic")?.segments.map(\.endReason) == [.stopped])
            await rig.warningsDone.value
            #expect(rig.warnings.all == [.writerFailed(track: "display-1")])
        }
    }

    @Test func micFormatChangeOpensNewSegment() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(1))
            rig.mic.switchFormat(sampleRate: 44_100, channels: 2)
            try await Task.sleep(for: .seconds(1))
            _ = try await rig.coordinator.stop()

            let mic = try #require(try rig.takeOnDisk(id).track("mic"))
            try #require(mic.segments.count == 2)
            #expect(mic.segments.map(\.endReason) == [.formatChanged, .stopped])
            let firstEnd = try #require(mic.segments[0].endHostTime)
            // The new segment starts with the sample that changed format: no gap, no wait.
            #expect(abs(mic.segments[1].startHostTime.seconds(since: firstEnd)) < 0.001)
            let format = try await rig.audioFormat(of: mic.segments[1])
            #expect(format.mSampleRate == 44_100 && format.mChannelsPerFrame == 2)
            #expect(try rig.takeOnDisk(id).track("display-1")?.segments.count == 1)
        }
    }

    @Test func staticScreenDoesNotTruncateDuration() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.display.pauseFrames(true)
            try await Task.sleep(for: .milliseconds(2500))
            _ = try await rig.coordinator.stop()

            let segment = try #require(try rig.takeOnDisk(id).track("display-1")?.segments.first)
            #expect(abs(try await rig.duration(of: segment) - 3) < 0.25)
            #expect(abs(try await videoMediaEnd(of: rig.url(of: segment)) - 3) < 0.25)
            #expect(segment.heartbeatFrames >= 3)
        }
    }

    @Test func staticScreenKeepsFragmentsFlowing() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.display.pauseFrames(true)
            try await Task.sleep(for: .seconds(3))
            let open = rig.package.segmentURL(take: id, track: "display-1", index: 1)
            let readable = await readableDuration(of: open, reaching: 2.4, timeout: .milliseconds(300))
            #expect(readable >= 2.4)
            _ = try await rig.coordinator.stop()
        }
    }

    @Test func diskFullStopsTakeCleanly() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let (autoStops, autoStopped) = AsyncStream.makeStream(of: TakeRecord.self)
            await rig.coordinator.setOnAutoStop { autoStopped.yield($0) }
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(1))
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            let record = try #require(await first(of: autoStops, within: .seconds(3)))

            #expect(record == (try rig.takeOnDisk(id)))
            #expect(record.status == .complete)
            for track in record.tracks {
                #expect(track.segments.map(\.endReason) == [.diskFull])
                let segment = try #require(track.segments.first)
                #expect(try await rig.duration(of: segment) > 0.8)
            }
            #expect(rig.lockIsFree(id))
            #expect(try await rig.coordinator.stop() == record)
            await rig.warningsDone.value
            #expect(rig.warnings.all == [.stoppedForDiskSpace])
        }
    }

    @Test func diskLowWarnsOnce() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            _ = try await rig.coordinator.start()
            rig.disk.set(importantUsage: 3_000_000_000, available: 3_000_000_000)
            try await Task.sleep(for: .milliseconds(400))
            _ = try await rig.coordinator.stop()
            await rig.warningsDone.value
            #expect(rig.warnings.all == [.diskLow(availableBytes: 3_000_000_000)])
        }
    }

    @Test func missingDiskVerdictsWarn() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            _ = try await rig.coordinator.start()
            rig.disk.failQueries(true)
            #expect(await eventually { rig.warnings.all.contains(.diskSpaceUnknown) })
            try await Task.sleep(for: .milliseconds(300))
            _ = try await rig.coordinator.stop()
            await rig.warningsDone.value
            #expect(rig.warnings.all == [.diskSpaceUnknown])
        }
    }

    @Test func refusesToStartWithoutDiskSpace() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            rig.disk.set(importantUsage: 1_000_000_000, available: 1_000_000_000)
            await #expect(throws: RecordingError.notEnoughDiskSpace(availableBytes: 1_000_000_000)) {
                try await rig.coordinator.start()
            }
            #expect(try rig.manifestOnDisk().takes.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.package.url.appending(path: "takes").path).isEmpty)
            #expect(rig.display.startCount == 0 && rig.mic.startCount == 0)
            await rig.warningsDone.value
            await #expect(throws: RecordingError.alreadyStarted) { try await rig.coordinator.start() }
        }
    }

    @Test func stopDuringRestartBackoffDoesNotReopen() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, configuration: RecordingConfiguration(restartBackoff: [.seconds(1)]))
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.display.failNow(domain: "SCStreamErrorDomain", code: -3821)
            #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.first?.endReason != nil })
            try await Task.sleep(for: .milliseconds(100))
            _ = try await rig.coordinator.stop()
            try await Task.sleep(for: .milliseconds(1500))

            #expect(rig.display.startCount == 1)
            #expect(try rig.takeOnDisk(id).track("display-1")?.segments.count == 1)
            #expect(!FileManager.default.fileExists(atPath: rig.package.segmentURL(take: id, track: "display-1", index: 2).path))
        }
    }

    @Test func autoStopRacingUserStopClosesOnce() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            let autoStops = Mutex<[TakeRecord]>([])
            await rig.coordinator.setOnAutoStop { record in autoStops.withLock { $0.append(record) } }
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .milliseconds(500))
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            // The monitor has just measured the full disk: its stop races the user's.
            await rig.disk.nextLowQuery()
            async let first = rig.coordinator.stop()
            async let second = rig.coordinator.stop()
            let (a, b) = try await (first, second)
            #expect(a == b)
            #expect(try await rig.coordinator.stop() == a)
            try await Task.sleep(for: .milliseconds(200))

            let automatic = autoStops.withLock { $0 }
            #expect(automatic.count <= 1)
            if let record = automatic.first { #expect(record == a) }
            let take = try rig.takeOnDisk(id)
            #expect(take == a && take.status == .complete)
            let reasons = take.tracks.map { $0.segments.map(\.endReason) }
            #expect(reasons == [[.stopped], [.stopped]] || reasons == [[.diskFull], [.diskFull]])
            #expect(rig.lockIsFree(id))
        }
    }

    @Test func stopImmediatelyAfterStart() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            rig.display.pauseFrames(true)
            let id = try await rig.coordinator.start()
            let record = try await rig.coordinator.stop()

            #expect(record.status == .complete)
            #expect(record.tracks.map(\.segments) == [[]])
            #expect(record == (try rig.takeOnDisk(id)))
            #expect(rig.lockIsFree(id))
            #expect(try await rig.coordinator.stop() == record)
        }
    }

    @Test func startFailureRollsBack() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory)
            rig.display.failOnStart = 99
            let error = await #expect(throws: NSError.self) { try await rig.coordinator.start() }
            #expect(error?.domain == "Synthetic" && error?.code == -1)

            #expect(rig.mic.startCount == 1 && rig.display.startCount == 1)
            #expect(rig.mic.activeDeviceUniqueID == nil)  // stopped
            let take = try #require(try rig.manifestOnDisk().takes.first)
            #expect(take.status == .complete)
            #expect(take.tracks.flatMap(\.segments).allSatisfy { $0.endReason == .stopped })
            #expect(rig.lockIsFree(take.id))
            #expect(FileManager.default.fileExists(atPath: rig.package.eventsURL(take: take.id).path))
            #expect(FileManager.default.fileExists(atPath: rig.package.trackDirectory(take: take.id, track: "mic").path))
            await rig.warningsDone.value
            await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.stop() }
            await #expect(throws: RecordingError.alreadyStarted) { try await rig.coordinator.start() }
        }
    }

    @Test func stopFinishesOtherTracksWhenOneFinishThrows() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory) { url, media in
                let inner = try FragmentedTrackWriter(url: url, media: media)
                guard media == .audio else { return inner }
                return ScriptedWriter(inner: inner, finishError: FinishFailure())
            }
            let id = try await rig.coordinator.start()
            try await Task.sleep(for: .seconds(1))
            await #expect(throws: FinishFailure.self) { try await rig.coordinator.stop() }

            let take = try rig.takeOnDisk(id)
            #expect(take.status == .complete)
            #expect(take.track("display-1")?.segments.map(\.endReason) == [.stopped])
            let mic = try #require(take.track("mic")?.segments.first)
            let failure = FinishFailure() as NSError
            #expect(mic.endReason == .writerError(domain: failure.domain, code: failure.code))
            #expect(mic.endHostTime != nil)
            #expect(rig.lockIsFree(id))
            await rig.warningsDone.value
        }
    }

    @Test func stateErrors() async throws {
        try await withTemporaryDirectory { directory in
            let rig = try Rig(in: directory, tracks: [.display])
            await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.stop() }
            _ = try await rig.coordinator.start()
            await #expect(throws: RecordingError.alreadyStarted) { try await rig.coordinator.start() }
            _ = try await rig.coordinator.stop()
        }
    }
}

// MARK: - Support

/// A take recorded from synthetic sources into a fresh package, with a fake disk and an injected
/// system-activity stream.
struct Rig {
    enum Track { case mic, display }

    let package: ProjectPackage
    let display = SyntheticVideoSource(width: 640, height: 360, framesPerSecond: 30)
    let mic = SyntheticAudioSource()
    let disk = FakeDisk()
    let activity: AsyncStream<SystemActivity>.Continuation
    let coordinator: RecordingCoordinator
    let warnings = WarningLog()
    /// Ends when the coordinator's `warnings` finishes, after the take closes.
    let warningsDone: Task<Void, Never>

    init(
        in directory: URL,
        tracks: [Track] = [.mic, .display],
        configuration: RecordingConfiguration = .init(),
        writerFactory: WriterFactory? = nil
    ) throws {
        package = try ProjectPackage.create(in: directory, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let (stream, continuation) = AsyncStream.makeStream(of: SystemActivity.self)
        activity = continuation
        let (mic, display) = (mic, display)
        let sources: [any CaptureSource] = tracks.map { $0 == .mic ? mic as any CaptureSource : display }
        coordinator = RecordingCoordinator(
            package: package,
            sources: sources,
            input: NoInputRecorder(),
            diskMonitor: disk.monitor(volume: directory),
            systemActivity: stream,
            configuration: configuration,
            writerFactory: writerFactory ?? { url, media in try FragmentedTrackWriter(url: url, media: media) }
        )
        warningsDone = Task { [warnings, coordinator] in
            for await warning in coordinator.warnings { warnings.append(warning) }
        }
    }

    func manifestOnDisk() throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    func takeOnDisk(_ id: String) throws -> TakeRecord {
        try #require(try manifestOnDisk().takes.first { $0.id == id })
    }

    /// The take as written so far, or `nil` if the manifest cannot be read right now.
    func liveTake(_ id: String) -> TakeRecord? {
        (try? manifestOnDisk())?.takes.first { $0.id == id }
    }

    func liveTrack(_ id: String, _ track: String) -> TrackRecord? {
        liveTake(id)?.track(track)
    }

    func events(_ id: String) throws -> [InputEvent] {
        try EventLogReader.read(package.eventsURL(take: id)).events
    }

    func lockIsFree(_ id: String) -> Bool {
        let url = package.lockURL(take: id)
        return !RecordingLock.isHeld(at: url) && !FileManager.default.fileExists(atPath: url.path)
    }

    func url(of segment: SegmentRecord) -> URL {
        package.url.appending(path: segment.file)
    }

    func duration(of segment: SegmentRecord) async throws -> Double {
        try await AVURLAsset(url: url(of: segment)).load(.duration).seconds
    }

    func audioFormat(of segment: SegmentRecord) async throws -> AudioStreamBasicDescription {
        let track = try #require(try await AVURLAsset(url: url(of: segment)).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    }
}

/// The free space a `DiskSpaceMonitor` sees, set by the test.
final class FakeDisk: Sendable {
    private struct State {
        var capacity = DiskCapacity(importantUsage: 100_000_000_000, available: 100_000_000_000)
        var failing = false
        var lowQueryWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func set(importantUsage: Int64, available: Int64) {
        state.withLock { $0.capacity = DiskCapacity(importantUsage: importantUsage, available: available) }
    }

    func failQueries(_ failing: Bool) {
        state.withLock { $0.failing = failing }
    }

    /// Returns right after the monitor next reads less than 1 GB available.
    func nextLowQuery() async {
        await withCheckedContinuation { continuation in
            state.withLock { $0.lowQueryWaiters.append(continuation) }
        }
    }

    func monitor(volume: URL) -> DiskSpaceMonitor {
        DiskSpaceMonitor(volumeURL: volume, interval: .milliseconds(50)) { [self] _ in try query() }
    }

    private func query() throws -> DiskCapacity {
        let (capacity, failing, waiters) = state.withLock { state in
            let low = state.capacity.available < 1_000_000_000
            defer { if low { state.lowQueryWaiters = [] } }
            return (state.capacity, state.failing, low ? state.lowQueryWaiters : [])
        }
        defer { for waiter in waiters { waiter.resume() } }
        if failing { throw CocoaError(.fileReadUnknown) }
        return capacity
    }
}

final class WarningLog: Sendable {
    private let items = Mutex<[RecordingWarning]>([])

    var all: [RecordingWarning] { items.withLock { $0 } }

    func append(_ warning: RecordingWarning) {
        items.withLock { $0.append(warning) }
    }
}

/// Wraps a real writer: fails its appends from `failAfter` seconds after creation (with
/// `NSError(domain: "TestWriter", code: 7)`), or throws `finishError` after finishing the file.
final class ScriptedWriter: TrackWriting {
    private let inner: FragmentedTrackWriter
    private let failAt: HostTime?
    private let finishError: (any Error)?
    private var injected: NSError?

    init(inner: FragmentedTrackWriter, failAfter seconds: Double? = nil, finishError: (any Error)? = nil) {
        self.inner = inner
        self.failAt = seconds.map { HostTime.now().adding(seconds: $0) }
        self.finishError = finishError
    }

    var onStart: ((HostTime) -> Void)? {
        get { inner.onStart }
        set { inner.onStart = newValue }
    }

    var formatDescription: CMFormatDescription? { inner.formatDescription }
    var failure: NSError? { injected ?? inner.failure }

    func append(_ sample: CMSampleBuffer) throws {
        if injected == nil, let failAt, HostTime(sample.presentationTimeStamp) >= failAt {
            injected = NSError(domain: "TestWriter", code: 7)
        }
        if let injected { throw WriterError.appendFailed(injected.localizedDescription) }
        try inner.append(sample)
    }

    func appendHeartbeat(at time: HostTime) throws {
        if let injected { throw WriterError.appendFailed(injected.localizedDescription) }
        try inner.appendHeartbeat(at: time)
    }

    nonisolated(nonsending) func finish(at stopTime: HostTime) async throws -> SegmentResult {
        let result = try await inner.finish(at: stopTime)
        if let finishError { throw finishError }
        return result
    }
}

struct FinishFailure: Error {}

/// The first element of `stream`, or `nil` if none comes within `timeout`.
func first<T: Sendable>(of stream: AsyncStream<T>, within timeout: Duration) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
