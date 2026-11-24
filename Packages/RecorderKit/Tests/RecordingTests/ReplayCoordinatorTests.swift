// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recovery
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

// The Replay's ring (fases 4 y 5 design §10.2, plan 5c decisions 2 to 5), at scale: segments of 1 s, a margin of 1 s and
// N of a few seconds, in real time.

extension RealTimeRecordingTests {
    @Suite struct ReplayCoordinatorTests {
        @Test func scratchIsMarkedLockedAndSkippedByRecovery() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory)
                let package = try await rig.coordinator.start()

                #expect(package.url == rig.package.url)
                #expect(ReplayScratch.isScratch(package))
                #expect(RecordingLock.isHeld(at: package.lockURL(take: ReplayScratch.takeID)))
                let take = try rig.take()
                #expect(take.status == .recording)
                #expect(take.tracks.map(\.id) == ["display-1", "mic"])
                #expect(try rig.manifest().formatVersion == 3)
                #expect(FileManager.default.fileExists(atPath: ReplayScratch.shardURL(of: package, index: 1).path))
                #expect(!FileManager.default.fileExists(atPath: package.eventsURL(take: ReplayScratch.takeID).path))
                // A `recording` take whose lock nobody would hold after a crash, and still never offered for recovery.
                #expect(RecoveryScanner.scan(package: package).isEmpty)
                #expect(RecoveryScanner.scan(directory: rig.root).isEmpty)
                // The first event file has where the display is, once the log writes its buffer.
                #expect(await eventually {
                    (try? rig.shardEvents())?.contains {
                        $0.kind == .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 320, height: 180), scale: 1)
                    } == true
                })
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func ringKeepsAtMostNPlus2Seconds() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 3)
                _ = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(7))
                let snapshot = try await rig.coordinator.freeze()
                let take = try rig.take()

                for track in take.tracks {
                    let kept = try #require(snapshot.take.track(track.id)).segments
                    let first = try #require(kept.map(\.startHostTime).min())
                    let last = try #require(kept.compactMap(\.endHostTime).max())
                    // N + margin + a segment (the design's N + 20 s), and a frame: the freeze prunes first.
                    let span = last.seconds(since: first)
                    #expect(span >= 3 && span <= 5 + 1.0 / 30, "\(track.id) keeps \(span) s")
                    #expect(kept.first?.index ?? 0 > 1, "\(track.id) pruned nothing")
                    // No file without its record, no record without its file.
                    #expect(Set(track.segments.map(\.file)) == rig.segmentFiles(of: track.id), "\(track.id)")
                }
                // Every segment kept has its `segmentStarted` in the event files left: they are pruned a segment later.
                let started = Set(try rig.shardEvents().compactMap { event -> String? in
                    guard case let .segmentStarted(track, index) = event.kind else { return nil }
                    return "\(track) \(index)"
                })
                for track in snapshot.take.tracks {
                    for segment in track.segments {
                        #expect(started.contains("\(track.id) \(segment.index)"), "\(track.id) \(segment.index)")
                    }
                }
                let shards = rig.shardFiles()
                #expect(shards.count <= 8, "\(shards)")
                #expect(!shards.contains("events-0001.jsonl"))
                #expect(snapshot.shards.map(\.lastPathComponent) == shards)
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func prunedShardsKeepTheirState() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 1, input: SyntheticInputRecorder())
                let package = try await rig.coordinator.start()
                let firstShard = ReplayScratch.shardURL(of: package, index: 1)
                #expect(await eventually(timeout: .seconds(10)) { !FileManager.default.fileExists(atPath: firstShard.path) })
                let snapshot = try await rig.coordinator.freeze()

                #expect(!snapshot.shards.contains(firstShard))
                // What the first second said is in force came along: where the display is and the cursor's image.
                #expect(snapshot.carried.contains {
                    $0.kind == .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 320, height: 180), scale: 1)
                })
                let image = try #require(snapshot.carried.compactMap { event -> String? in
                    guard case .cursorImage(let hash, _, _, _) = event.kind else { return nil }
                    return hash
                }.first)
                // Its image is never pruned.
                #expect(FileManager.default.fileExists(atPath: package.cursorImageURL(take: ReplayScratch.takeID, hash: image).path))
                #expect(snapshot.carried.contains { if case .cursor = $0.kind { true } else { false } })
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func freezeStopsPruningUntilThaw() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 1)
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(1500))
                let snapshot = try await rig.coordinator.freeze()
                let kept = snapshot.take.tracks.flatMap(\.segments)
                try #require(!kept.isEmpty)
                // Well past N + margin: all of it would have gone.
                try await Task.sleep(for: .seconds(3))
                let recorded = Set(try rig.take().tracks.flatMap(\.segments).map(\.file))
                for segment in kept {
                    #expect(FileManager.default.fileExists(atPath: package.url.appending(path: segment.file).path), "\(segment.file)")
                    #expect(recorded.contains(segment.file), "\(segment.file)")
                }
                for shard in snapshot.shards {
                    #expect(FileManager.default.fileExists(atPath: shard.path), "\(shard.lastPathComponent)")
                }
                await rig.coordinator.thaw()
                let oldest = package.url.appending(path: try #require(kept.first).file)
                #expect(await eventually { !FileManager.default.fileExists(atPath: oldest.path) })
                #expect(await eventually { !FileManager.default.fileExists(atPath: snapshot.shards[0].path) })
                await rig.coordinator.stopAndDiscard()
            }
        }

        /// Two saves in a row (the shortcut pressed twice): the first one's thaw must not delete what the second one is
        /// still copying.
        @Test func nestedFreezesPruneOnlyAfterTheLastThaw() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 1)
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(1500))
                // A thaw without a freeze undoes nothing later.
                await rig.coordinator.thaw()
                let first = try await rig.coordinator.freeze()
                let second = try await rig.coordinator.freeze()
                await rig.coordinator.thaw()
                // Well past N + margin: the first save's files would have gone.
                try await Task.sleep(for: .seconds(3))
                for segment in first.take.tracks.flatMap(\.segments) + second.take.tracks.flatMap(\.segments) {
                    #expect(FileManager.default.fileExists(atPath: package.url.appending(path: segment.file).path), "\(segment.file)")
                }
                for shard in second.shards {
                    #expect(FileManager.default.fileExists(atPath: shard.path), "\(shard.lastPathComponent)")
                }
                await rig.coordinator.thaw()
                let oldest = package.url.appending(path: try #require(first.take.tracks.first?.segments.first).file)
                #expect(await eventually { !FileManager.default.fileExists(atPath: oldest.path) })
                await rig.coordinator.stopAndDiscard()
                // On a Replay that stopped, a thaw does nothing.
                await rig.coordinator.thaw()
            }
        }

        /// `ReplaySaver` thaws once whatever happens, also after a freeze that threw: that freeze holds the pruning until
        /// then, like one that gave a snapshot.
        @Test func aFailedFreezeHoldsThePruningUntilItsThaw() async throws {
            try await withTemporaryDirectory { directory in
                let still = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                still.pauseFrames(true)
                let mic = SyntheticAudioSource()
                let rig = ReplayRig(in: directory, seconds: 1, sources: [still, mic])
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(1500))
                await #expect(throws: ReplayError.nothingToSave) { try await rig.coordinator.freeze() }
                let oldest = package.segmentURL(take: ReplayScratch.takeID, track: "mic", index: 1)
                try await Task.sleep(for: .seconds(3))
                #expect(FileManager.default.fileExists(atPath: oldest.path))
                await rig.coordinator.thaw()
                #expect(await eventually { !FileManager.default.fileExists(atPath: oldest.path) })
                await rig.coordinator.stopAndDiscard()
            }
        }

        /// A save right after the tracks rotated by duration: the snapshot never leaves out a segment still finishing.
        @Test func freezeWaitsForASegmentStillFinishing() async throws {
            try await withTemporaryDirectory { directory in
                let gate = Gate()
                let rig = ReplayRig(in: directory, seconds: 3, writerFactory: gatedWriter(holding: "seg-0001.mov", until: gate))
                _ = try await rig.coordinator.start()
                // Both tracks rotated by duration: segment 2 is open, segment 1 held finishing.
                #expect(await eventually { rig.hasSegment(2, of: ["display-1", "mic"]) })
                let freeze = Task { try await rig.coordinator.freeze() }
                try await Task.sleep(for: .milliseconds(300))
                gate.open()
                let snapshot = try await freeze.value
                for track in snapshot.take.tracks {
                    #expect(track.segments.map(\.index) == [1, 2], "\(track.id)")
                    #expect(track.segments[0].endHostTime == track.segments[1].startHostTime, "\(track.id)")
                }
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        /// A rotation that never answers (its file never finishes): the freeze gives what closed by its deadline, and never
        /// a segment after one still finishing.
        @Test func freezeGivesWhatClosedWhenARotationHangs() async throws {
            try await withTemporaryDirectory { directory in
                let gate = Gate()
                let display = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                let rig = ReplayRig(
                    in: directory, seconds: 10, sources: [display, SyntheticAudioSource()],
                    writerFactory: gatedWriter(holding: "seg-0002.mov", until: gate))
                _ = try await rig.coordinator.start()
                // The display's segment 2 rotated by duration and hangs finishing; the microphone's did too.
                #expect(await eventually { rig.hasSegment(3, of: ["display-1", "mic"]) })
                let started = ContinuousClock.now
                let snapshot = try await rig.coordinator.freeze()
                let waited = ContinuousClock.now - started
                #expect(waited >= ReplayCoordinator.freezeDeadline && waited < ReplayCoordinator.freezeDeadline + .seconds(3))
                #expect(snapshot.take.track("display-1")?.segments.map(\.index) == [1])
                #expect(snapshot.take.track("mic")?.segments.map(\.index) == [1])
                gate.open()
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func freezeGivesClosedSegmentsThatEndTogether() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 3)
                _ = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(1500))
                let snapshot = try await rig.coordinator.freeze()

                #expect(snapshot.take.id == ReplayScratch.takeID)
                #expect(snapshot.formatVersion == 3)
                var ends: [HostTime] = []
                for track in snapshot.take.tracks {
                    #expect(track.segments.allSatisfy { $0.endHostTime != nil && $0.endReason != nil }, "\(track.id)")
                    let last = try #require(track.segments.last)
                    #expect(last.endReason == .rotated)
                    ends.append(try #require(last.endHostTime))
                    // The rotation opened the next segment where this one ended; the snapshot leaves it out.
                    let live = try #require(try rig.take().track(track.id))
                    #expect(live.segments.contains { $0.index == last.index + 1 && $0.startHostTime == last.endHostTime })
                }
                let spread = try #require(ends.max()).seconds(since: try #require(ends.min()))
                #expect(spread < 0.1, "the tracks end \(spread) s apart")
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func freezeBeforeAnyFrameIsNothingToSave() async throws {
            try await withTemporaryDirectory { directory in
                let still = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                still.pauseFrames(true)
                let rig = ReplayRig(in: directory, sources: [still])
                await #expect(throws: ReplayError.notRunning) { try await rig.coordinator.freeze() }
                _ = try await rig.coordinator.start()
                await #expect(throws: ReplayError.nothingToSave) { try await rig.coordinator.freeze() }
                await rig.coordinator.stopAndDiscard()
                await #expect(throws: ReplayError.notRunning) { try await rig.coordinator.freeze() }
            }
        }

        @Test func stopAndDiscardRemovesEverything() async throws {
            try await withTemporaryDirectory { directory in
                let display = CountingSource(inner: SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30))
                let rig = ReplayRig(in: directory, sources: [display])
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                await rig.coordinator.stopAndDiscard()

                #expect(!FileManager.default.fileExists(atPath: package.url.path))
                #expect(!RecordingLock.isHeld(at: package.lockURL(take: ReplayScratch.takeID)))
                #expect(try FileManager.default.contentsOfDirectory(atPath: rig.root.path).isEmpty)
                let delivered = display.deliveredTimes.count
                try await Task.sleep(for: .milliseconds(300))
                #expect(display.deliveredTimes.count == delivered)
                await rig.warningsDone.value
                // Twice is fine, and it is done for good.
                await rig.coordinator.stopAndDiscard()
                await #expect(throws: ReplayError.notRunning) { try await rig.coordinator.freeze() }
                await #expect(throws: ReplayError.alreadyStarted) { try await rig.coordinator.start() }
                #expect(await rig.coordinator.buffered() == .zero)
            }
        }

        @Test func diskFullDiscardsAndTellsOnce() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory)
                let ends = Mutex<[ReplayEnd]>([])
                await rig.coordinator.setOnAutoStop { end in ends.withLock { $0.append(end) } }
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(500))
                rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)

                #expect(await eventually { ends.withLock { $0 } == [.diskFull] })
                #expect(!FileManager.default.fileExists(atPath: package.url.path))
                try await Task.sleep(for: .milliseconds(300))
                #expect(ends.withLock { $0 } == [.diskFull])
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.stoppedForDiskSpace])
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func refusesToStartWithoutDiskSpace() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory)
                rig.disk.set(importantUsage: 1_000_000_000, available: 1_000_000_000)
                await #expect(throws: RecordingError.notEnoughDiskSpace(availableBytes: 1_000_000_000)) {
                    try await rig.coordinator.start()
                }
                #expect(!FileManager.default.fileExists(atPath: rig.package.url.path))
                #expect(rig.display.startCount == 0)
                await rig.warningsDone.value
            }
        }

        @Test func aSecondReplayOnALiveScratchIsRefused() async throws {
            try await withTemporaryDirectory { directory in
                let first = ReplayRig(in: directory)
                let package = try await first.coordinator.start()
                try await Task.sleep(for: .milliseconds(500))
                let second = ReplayRig(in: directory)
                await #expect(throws: ReplayError.scratchInUse) { try await second.coordinator.start() }
                #expect(second.display.startCount == 0)
                await second.warningsDone.value

                // The first goes on as it was.
                #expect(ReplayScratch.isScratch(package))
                #expect(RecordingLock.isHeld(at: package.lockURL(take: ReplayScratch.takeID)))
                try await Task.sleep(for: .milliseconds(1200))
                let snapshot = try await first.coordinator.freeze()
                #expect(snapshot.take.track("display-1")?.segments.count ?? 0 >= 2)
                await first.coordinator.thaw()
                await first.coordinator.stopAndDiscard()
            }
        }

        @Test func secondsChangeAppliesToThePruning() async throws {
            try await withTemporaryDirectory { directory in
                let rig = ReplayRig(in: directory, seconds: 10)
                let package = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(3500))
                let first = package.segmentURL(take: ReplayScratch.takeID, track: "display-1", index: 1)
                #expect(FileManager.default.fileExists(atPath: first.path))
                let buffered = await rig.coordinator.buffered()
                #expect(buffered > .seconds(3) && buffered < .seconds(10), "\(buffered)")

                await rig.coordinator.setSeconds(1)
                #expect(await eventually { !FileManager.default.fileExists(atPath: first.path) })
                #expect(await rig.coordinator.buffered() <= .seconds(1))
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func cameraStyleChangeIsLoggedAndCarried() async throws {
            try await withTemporaryDirectory { directory in
                let display = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 320, height: 180, framesPerSecond: 30)
                let rig = ReplayRig(in: directory, seconds: 1, sources: [display, camera])
                let package = try await rig.coordinator.start()
                #expect(try rig.take().cameraStyle == .default)
                // The style it started with is no change, and the same style twice is one change.
                await rig.coordinator.setCameraStyle(.default)
                let moved = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
                await rig.coordinator.setCameraStyle(moved)
                await rig.coordinator.setCameraStyle(moved)
                let firstShard = ReplayScratch.shardURL(of: package, index: 1)
                #expect(await eventually(timeout: .seconds(10)) { !FileManager.default.fileExists(atPath: firstShard.path) })
                let snapshot = try await rig.coordinator.freeze()

                #expect(snapshot.take.cameraStyle == .default)
                let styles = snapshot.carried.compactMap { event -> CameraStyle? in
                    guard case .cameraStyle(let style) = event.kind else { return nil }
                    return style
                }
                #expect(styles == [moved])
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }

        @Test func keysRaiseTheScratchTo4() async throws {
            try await withTemporaryDirectory { directory in
                let every: Duration = .milliseconds(50)
                let ticks = ManualTicks()
                let keys = KeyPressRecorder(
                    source: ScriptedKeyEvents(text: "a", every: every, ticks: ticks.ticks), secureInput: { false })
                let rig = ReplayRig(in: directory, input: CompositeInputRecorder([NoInputRecorder(), keys]))
                _ = try await rig.coordinator.start()
                #expect(try rig.manifest().formatVersion == 3)
                await ticks.fire(every: every)
                // Raised on disk as the key is written.
                #expect(try rig.manifest().formatVersion == 4)
                try await Task.sleep(for: .milliseconds(1200))
                let snapshot = try await rig.coordinator.freeze()

                #expect(snapshot.formatVersion == 4)
                #expect(try rig.shardEvents().contains { $0.kind.requiresFormatVersion4 })
                await rig.coordinator.thaw()
                await rig.coordinator.stopAndDiscard()
            }
        }
    }
}

// MARK: - Benchmark

extension RealTimeRecordingTests.ReplayCoordinatorTests {
    /// The cost of the ring on the capture queues, against a take of the same sources without rotation: a display at 4K
    /// 60 fps, a camera at 1080p 30 fps, a microphone and system audio, 60 s each, segments of 10 s. A synthetic source does
    /// not emit the frames that fall due while its queue is held, so a held queue shows as a gap in the PTS it delivered.
    /// `TOMA_BENCH=1` only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func replayRingCost() async throws {
        let seconds = 60
        for rotating in [false, true] {
            try await withTemporaryDirectory { directory in
                let display = TimedSource(inner: SyntheticVideoSource(width: 3840, height: 2160, framesPerSecond: 60))
                let camera = TimedSource(inner: SyntheticVideoSource(
                    trackID: "camera", kind: .camera, width: 1920, height: 1080, framesPerSecond: 30))
                let sources: [any CaptureSource] = [
                    display, camera, SyntheticAudioSource(),
                    SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2),
                ]
                if rotating {
                    let rig = ReplayRig(in: directory, seconds: 30, sources: sources, segmentDuration: .seconds(10))
                    _ = try await rig.coordinator.start()
                    try await Task.sleep(for: .seconds(seconds))
                    await rig.coordinator.stopAndDiscard()
                } else {
                    let rig = try Rig(in: directory, sources: sources)
                    _ = try await rig.coordinator.start()
                    try await Task.sleep(for: .seconds(seconds))
                    _ = try await rig.coordinator.stop()
                }
                for (name, timed, rate) in [("display 4K60", display, 60), ("camera 1080p30", camera, 30)] {
                    print("replayRingCost: \(rotating ? "ring" : "take"), \(name): " + Self.describe(timed.deliveries, rate: rate))
                }
            }
        }
    }

    /// After the first 2 s (the writers' start, the same with or without rotation): frames delivered, the gaps of more
    /// than 1.5 frames between their PTS (and the frames they miss), the longest a delivery held the queue and the 99th
    /// percentile of that.
    static func describe(_ all: [TimedSource.Delivery], rate: Int) -> String {
        guard let first = all.first?.pts else { return "no frames" }
        let deliveries = all.filter { $0.pts.seconds(since: first) >= 2 }
        let interval = 1.0 / Double(rate)
        var gaps = 0, missing = 0
        for (a, b) in zip(deliveries, deliveries.dropFirst()) {
            let gap = b.pts.seconds(since: a.pts)
            if gap > 1.5 * interval {
                gaps += 1
                missing += Int((gap / interval).rounded()) - 1
            }
        }
        let holds = deliveries.map(\.seconds).sorted()
        let worst = (holds.last ?? 0) * 1000
        let p99 = holds.isEmpty ? 0 : holds[min(holds.count - 1, holds.count * 99 / 100)] * 1000
        return String(format: "%d frames, %d gaps missing %d frames, hold p99 %.1f ms, worst %.1f ms",
            deliveries.count, gaps, missing, p99, worst)
    }
}

// MARK: - Support

/// A Replay of synthetic sources (by default a display and a microphone) into `<directory>/Replay`, at scale: segments
/// of 1 s and a margin of 1 s, with a fake disk.
struct ReplayRig {
    let root: URL
    let display = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
    let mic = SyntheticAudioSource()
    let disk = FakeDisk()
    let coordinator: ReplayCoordinator
    let warnings = WarningLog()
    /// Ends when the coordinator's `warnings` finishes.
    let warningsDone: Task<Void, Never>

    init(
        in directory: URL, seconds: Int = 3, sources custom: [any CaptureSource]? = nil,
        input: any InputRecorder = NoInputRecorder(), cameraStyle: CameraStyle? = nil,
        segmentDuration: Duration = .seconds(1), writerFactory: WriterFactory? = nil
    ) {
        root = directory.appending(path: "Replay", directoryHint: .isDirectory)
        let configuration = ReplayConfiguration(
            seconds: seconds, segmentDuration: segmentDuration, pruneMargin: segmentDuration)
        coordinator = ReplayCoordinator(
            scratchRoot: root, app: AppInfo(name: "Tests", version: "0"), sources: custom ?? [display, mic], input: input,
            diskMonitor: disk.monitor(volume: directory), configuration: configuration,
            writerFactory: writerFactory ?? { url, media in try FragmentedTrackWriter(url: url, media: media) },
            cameraStyle: cameraStyle)
        warningsDone = Task { [warnings, coordinator] in
            for await warning in coordinator.warnings { warnings.append(warning) }
        }
    }

    var package: ProjectPackage { ReplayScratch.package(in: root) }

    func manifest() throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    func take() throws -> TakeRecord {
        try #require(try manifest().takes.first { $0.id == ReplayScratch.takeID })
    }

    /// The segment files of `track` on disk, as the manifest names them.
    func segmentFiles(of track: String) -> Set<String> {
        let folder = package.trackDirectory(take: ReplayScratch.takeID, track: track)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { "takes/\(ReplayScratch.takeID)/\(track)/\($0)" })
    }

    /// Whether segment `index` of every track of `tracks` has its file.
    func hasSegment(_ index: Int, of tracks: [String]) -> Bool {
        tracks.allSatisfy { FileManager.default.fileExists(atPath: package.segmentURL(take: ReplayScratch.takeID, track: $0, index: index).path) }
    }

    /// The event files of the take on disk, by name, in order.
    func shardFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: package.takeDirectory(ReplayScratch.takeID).path)) ?? []
        return names.filter { $0.hasPrefix("events-") }.sorted()
    }

    /// Every event of the event files on disk, file by file.
    func shardEvents() throws -> [InputEvent] {
        try shardFiles().flatMap { name in
            try EventLogReader.read(package.takeDirectory(ReplayScratch.takeID).appending(path: name)).events
        }
    }
}
