// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

/// Real-time recordings of a few seconds each, the real disk-full test included, run one at a time
/// so their timing stays predictable.
@Suite(.serialized) struct RealTimeRecordingTests {}

extension RealTimeRecordingTests {
    @Suite struct RecordingCoordinatorTests {
        @Test func startStopProducesCompleteTake() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                let times = MeasuredTake()
                let id = try await times.start(rig.coordinator)
                // The reserve is really allocated while recording, and given back at the end.
                #expect((rig.reserveBytes(id) ?? 0) >= Int64(TakeReserve.size))
                try await Task.sleep(for: .seconds(2))
                let record = try await times.stop(rig.coordinator)

                #expect(rig.reserveBytes(id) == nil)
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
                    let span = try #require(segment.endHostTime).seconds(since: segment.startHostTime)
                    times.expectSpansTheTake(span)
                    #expect(abs(try await rig.duration(of: segment) - span) < 0.15, "\(track.id) lasts \(span) s")
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

        @Test func microphoneKeepsRetryingAfterItsRestartsAreUsedUp() async throws {
            try await withTemporaryDirectory { directory in
                let configuration = RecordingConfiguration(restartBackoff: [.milliseconds(10), .milliseconds(10)])
                let rig = try Rig(in: directory, configuration: configuration)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(500))
                // More failures than restart attempts: a USB microphone that takes long to come back.
                rig.mic.failOnStart = 6
                rig.mic.failNow(domain: "AVFoundationErrorDomain", code: -11819)
                #expect(await eventually { rig.liveTrack(id, "mic")?.segments.count == 2 })
                try await Task.sleep(for: .milliseconds(500))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                #expect(take.status == .complete)
                let mic = try #require(take.track("mic"))
                #expect(mic.segments.map(\.endReason) == [.streamError(domain: "AVFoundationErrorDomain", code: -11819), .stopped])
                #expect(try await rig.duration(of: mic.segments[1]) > 0.3)
                #expect(rig.mic.startCount == 8)
                #expect(take.track("display-1")?.segments.map(\.endReason) == [.stopped])
                #expect(rig.lockIsFree(id))
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.streamInterrupted(track: "mic"), .trackPaused(track: "mic"), .streamRestarted(track: "mic")])
            }
        }

        @Test func exhaustedRestartsMarkASecondDisplayLost() async throws {
            try await withTemporaryDirectory { directory in
                let first = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
                let second = SyntheticVideoSource(trackID: "display-2", width: 320, height: 180, framesPerSecond: 30)
                let configuration = RecordingConfiguration(restartBackoff: [.milliseconds(10), .milliseconds(10)])
                let rig = try Rig(in: directory, sources: [first, second], configuration: configuration)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(500))
                second.failOnStart = 99
                second.failNow(domain: "SCStreamErrorDomain", code: -3815)
                #expect(await eventually { rig.warnings.all.contains(.trackLost(track: "display-2")) })
                #expect(second.startCount == 3)
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                #expect(take.track("display-2")?.segments.map(\.endReason) == [.streamError(domain: "SCStreamErrorDomain", code: -3815)])
                #expect(take.track("display-1")?.segments.map(\.endReason) == [.stopped])
                #expect(second.startCount == 3)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.streamInterrupted(track: "display-2"), .trackLost(track: "display-2")])
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
                for track in take.tracks {
                    // A segment ends at the pause, or at a sample captured before its source stopped.
                    let end = try #require(track.segments[0].endHostTime)
                    #expect(end >= events[paused].t && end.seconds(since: events[paused].t) < 0.05)
                }
                #expect(rig.display.startCount == 2 && rig.mic.startCount == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "screenLocked"), .resumed])
            }
        }

        @Test func noInputIsRecordedWhilePaused() async throws {
            try await withTemporaryDirectory { directory in
                let location = MovingLocation()
                let rig = try Rig(
                    in: directory, tracks: [.display], input: CursorRecorder(location: { location.next() }))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                rig.activity.yield(.screenLocked)
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.map(\.endReason) == [.paused] })
                try await Task.sleep(for: .milliseconds(300))
                rig.activity.yield(.screenUnlocked)
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 2 })
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()

                let events = try rig.events(id)
                let paused = try #require(events.firstIndex { $0.kind == .paused(reason: "screenLocked") })
                let resumed = try #require(events.firstIndex { $0.kind == .resumed })
                let isInput: (InputEvent) -> Bool = { event in
                    switch event.kind {
                    case .cursor, .mouseDown, .mouseUp: true
                    default: false
                    }
                }
                #expect(events[..<paused].contains(where: isInput))
                #expect(!events[paused...resumed].contains(where: isInput))
                #expect(!events.contains { isInput($0) && $0.t > events[paused].t && $0.t < events[resumed].t })
                #expect(events[resumed...].contains(where: isInput))
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "screenLocked"), .resumed])
            }
        }

        @Test func wakeStaysPausedWhileTheScreenIsLocked() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display])
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                rig.activity.yield(.willSleep)
                rig.activity.yield(.screenLocked)
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.map(\.endReason) == [.paused] })
                rig.activity.yield(.didWake)
                // Nothing should happen now; only time can show it.
                try await Task.sleep(for: .milliseconds(300))
                #expect(rig.display.startCount == 1)
                #expect(rig.liveTrack(id, "display-1")?.segments.count == 1)
                rig.activity.yield(.screenUnlocked)
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 2 })
                _ = try await rig.coordinator.stop()

                let events = try rig.events(id)
                #expect(events.filter { $0.kind == .paused(reason: "willSleep") }.count == 1)
                #expect(events.filter { $0.kind == .resumed }.count == 1)
                #expect(rig.display.startCount == 2)
                await rig.warningsDone.value
                // One pause and one resume, however many causes overlapped.
                #expect(rig.warnings.all == [.paused(reason: "willSleep"), .resumed])
            }
        }

        @Test func userPauseClosesSegmentsAndLogsUserReason() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                try await rig.coordinator.pause()
                // `pause()` returns once every track is paused.
                #expect(rig.liveTake(id)?.tracks.allSatisfy { $0.segments.map(\.endReason) == [.paused] } == true)
                try await Task.sleep(for: .seconds(1))
                try await rig.coordinator.resume()
                #expect(await eventually { rig.liveTake(id)?.tracks.allSatisfy { $0.segments.count == 2 } == true })
                try await Task.sleep(for: .seconds(1))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                for track in take.tracks {
                    #expect(track.segments.map(\.endReason) == [.paused, .stopped])
                    #expect(track.segments.map(\.index) == [1, 2])
                }
                let events = try rig.events(id)
                let paused = try #require(events.firstIndex { $0.kind == .paused(reason: "user") })
                let resumed = try #require(events.firstIndex { $0.kind == .resumed })
                #expect(paused < resumed)
                #expect(events.filter { $0.kind == .paused(reason: "user") || $0.kind == .resumed }.count == 2)
                #expect(rig.display.startCount == 2 && rig.mic.startCount == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "user"), .resumed])
            }
        }

        @Test func nothingIsWrittenWhileUserPaused() async throws {
            try await withTemporaryDirectory { directory in
                let location = MovingLocation()
                let rig = try Rig(in: directory, input: CursorRecorder(location: { location.next() }))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                try await rig.coordinator.pause()
                try await Task.sleep(for: .milliseconds(500))
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.addMarker() }
                try await Task.sleep(for: .milliseconds(500))
                try await rig.coordinator.resume()
                #expect(await eventually { rig.liveTake(id)?.tracks.allSatisfy { $0.segments.count == 2 } == true })
                try await Task.sleep(for: .milliseconds(500))
                _ = try await rig.coordinator.stop()

                let events = try rig.events(id)
                let paused = try #require(events.first { $0.kind == .paused(reason: "user") }).t
                let resumed = try #require(events.first { $0.kind == .resumed }).t
                #expect(resumed.seconds(since: paused) > 0.9)
                // A segment ends at the pause, or at a sample captured before its source stopped
                // (`lockPausesAndUnlockResumes`); the next one starts after the resume.
                let pauseEnd = paused.adding(seconds: 0.05)
                for track in try rig.takeOnDisk(id).tracks {
                    try #require(track.segments.count == 2, "\(track.id)")
                    let (first, second) = (track.segments[0], track.segments[1])
                    let end = try #require(first.endHostTime)
                    #expect(end <= pauseEnd, "\(track.id) ends \(end.seconds(since: paused)) s after the pause")
                    #expect(second.startHostTime >= resumed, "\(track.id) starts before the resume")
                    // Its file has nothing past its end either.
                    #expect(abs(try await rig.duration(of: first) - end.seconds(since: first.startHostTime)) < 0.15)
                }
                let isInput: (InputEvent) -> Bool = { event in
                    switch event.kind {
                    case .cursor, .mouseDown, .mouseUp: true
                    default: false
                    }
                }
                #expect(events.contains { isInput($0) && $0.t < paused })
                #expect(!events.contains { isInput($0) && $0.t > paused && $0.t < resumed })
                #expect(events.contains { isInput($0) && $0.t > resumed })
                #expect(!events.contains { $0.kind == .marker })
            }
        }

        @Test func userPauseSurvivesUnlock() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display])
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                try await rig.coordinator.pause()
                rig.activity.yield(.screenLocked)
                rig.activity.yield(.screenUnlocked)
                // Nothing should happen now; only time can show it.
                try await Task.sleep(for: .milliseconds(300))
                #expect(rig.display.startCount == 1)
                #expect(rig.liveTrack(id, "display-1")?.segments.map(\.endReason) == [.paused])
                #expect(rig.warnings.all == [.paused(reason: "user")])
                try await rig.coordinator.resume()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 2 })
                _ = try await rig.coordinator.stop()

                let pauses = try rig.events(id).filter {
                    switch $0.kind {
                    case .paused, .resumed: true
                    default: false
                    }
                }
                #expect(pauses.map(\.kind) == [.paused(reason: "user"), .resumed])
                #expect(rig.display.startCount == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "user"), .resumed])
            }
        }

        @Test func markerIsLoggedAtItsTime() async throws {
            try await withTemporaryDirectory { directory in
                let clock = PinnedClock()
                let rig = try Rig(in: directory, tracks: [.display], clock: clock.now)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                let time = HostTime.now()
                clock.pin(time)
                let marked = try await rig.coordinator.addMarker()
                clock.pin(nil)
                #expect(marked == time)
                try await Task.sleep(for: .milliseconds(100))
                _ = try await rig.coordinator.stop()

                let markers = try rig.events(id).filter { $0.kind == .marker }
                #expect(markers.map(\.t) == [time])
            }
        }

        @Test func pauseWhenNotRecordingThrows() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display])
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.pause() }
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.resume() }
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.addMarker() }
                let id = try await rig.coordinator.start()
                // Resuming what the user did not pause, or pausing twice, does nothing.
                try await rig.coordinator.resume()
                try await rig.coordinator.pause()
                try await rig.coordinator.pause()
                try await rig.coordinator.resume()
                _ = try await rig.coordinator.stop()
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.pause() }
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.resume() }
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.addMarker() }

                let kinds = try rig.events(id).map(\.kind)
                #expect(kinds.filter { $0 == .paused(reason: "user") }.count == 1)
                #expect(kinds.filter { $0 == .resumed }.count == 1)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "user"), .resumed])
            }
        }

        /// 20 rounds: each is a real take with its own 8 MB reserve, and 50 risk the time limit under `make tsan`.
        @Test(.timeLimit(.minutes(1))) func pauseRacingStopNeverHangs() async throws {
            try await withTemporaryDirectory { directory in
                for round in 0..<20 {
                    let folder = directory.appendingPathComponent("\(round)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let rig = try Rig(in: folder, tracks: [.display])
                    let id = try await rig.coordinator.start()
                    async let pausing: Void = rig.coordinator.pause()
                    // From at once to 9.5 ms later: the stop comes before the pause is applied, or while it
                    // pauses the tracks (finishing their files takes longer than that).
                    try await Task.sleep(for: .microseconds(500 * round))
                    async let stopping = rig.coordinator.stop()
                    let paused: Bool
                    do {
                        try await pausing
                        paused = true
                    } catch RecordingError.notRecording {
                        paused = false
                    }
                    let record = try await stopping

                    // The pause was applied before the take closed, or it was refused.
                    let events = try rig.events(id)
                    #expect(events.contains { $0.kind == .paused(reason: "user") } == paused, "round \(round)")
                    let reasons = record.tracks.flatMap { $0.segments.map(\.endReason) }
                    #expect(reasons.allSatisfy { $0 == (paused ? .paused : .stopped) }, "round \(round): \(reasons)")
                    #expect(rig.lockIsFree(id))
                    try FileManager.default.removeItem(at: folder)
                }
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
                let times = MeasuredTake()
                let id = try await times.start(rig.coordinator)
                try await Task.sleep(for: .milliseconds(500))
                rig.display.pauseFrames(true)
                let still = HostTime.now()
                try await Task.sleep(for: .milliseconds(2500))
                _ = try await times.stop(rig.coordinator)

                let segment = try #require(try rig.takeOnDisk(id).track("display-1")?.segments.first)
                // The still screen goes on in heartbeats to the stop: the segment lasts the whole take.
                let span = try #require(segment.endHostTime).seconds(since: segment.startHostTime)
                times.expectSpansTheTake(span)
                #expect(abs(try await rig.duration(of: segment) - span) < 0.15)
                #expect(abs(try await videoMediaEnd(of: rig.url(of: segment)) - span) < 0.25)
                let stillSeconds = times.stopping.seconds(since: still)
                #expect(Double(segment.heartbeatFrames) >= (stillSeconds / 0.5 * 0.6).rounded(.down), "over \(stillSeconds) s")
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

        @Test func heartbeatRunsOnEachManualTick() async throws {
            try await withTemporaryDirectory { directory in
                let ticks = ManualTicks()
                // A heartbeat is stamped `heartbeatSafetyMargin` before `clock()` and must come after the last frame
                // or heartbeat: the clock moves 0.5 s before every tick, as the timer's would.
                let clock = OffsetClock()
                let interval = RecordingConfiguration().heartbeatInterval
                let rig = try Rig(in: directory, tracks: [.display], writerFactory: { url, media in
                    let writer = try FragmentedTrackWriter(url: url, media: media)
                    // The ticks come microseconds apart, not 500 ms: give the encoder the time an interval would,
                    // or a real-time writer skips a heartbeat that finds it busy.
                    writer.inputHasRoom = { input in
                        let deadline = HostTime.now().adding(seconds: 1)
                        while !input.isReadyForMoreMediaData, HostTime.now() < deadline { usleep(1000) }
                        return input.isReadyForMoreMediaData
                    }
                    return writer
                }, clock: clock.now, ticks: ticks.ticks)
                let id = try await rig.coordinator.start()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 1 })
                rig.display.pauseFrames(true)
                // The first tick after frames only sets their count back to 0.
                clock.advance(seconds: 0.5)
                await ticks.fire(every: interval)
                for _ in 0..<3 {
                    clock.advance(seconds: 0.5)
                    await ticks.fire(every: interval)
                }
                let record = try await rig.coordinator.stop()

                #expect(record.track("display-1")?.segments.map(\.heartbeatFrames) == [3])
            }
        }

        @Test func diskFullStopsTakeCleanly() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                let (autoStops, autoStopped) = AsyncStream.makeStream(of: (TakeRecord, (any Error)?).self)
                await rig.coordinator.setOnAutoStop { autoStopped.yield(($0, $1)) }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
                let (record, failure) = try #require(await first(of: autoStops, within: .seconds(3)))
                #expect(failure == nil)
                #expect(rig.reserveBytes(id) == nil)

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

        @Test func refusesToStartBelowTheStopThresholdEvenWithPurgeableSpace() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                rig.disk.set(importantUsage: 9_000_000_000, available: 900_000_000)
                await #expect(throws: RecordingError.notEnoughDiskSpace(availableBytes: 900_000_000)) {
                    try await rig.coordinator.start()
                }
                #expect(try rig.manifestOnDisk().takes.isEmpty)
                #expect(try FileManager.default.contentsOfDirectory(atPath: rig.package.takesURL.path).isEmpty)
                #expect(rig.display.startCount == 0 && rig.mic.startCount == 0)
            }
        }

        @Test func startFailsWhenTheTakeCannotReachTheManifest() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                // The manifest is replaced through a temporary file in the package folder; takes/ stays writable.
                let folder = rig.package.url.path
                try #require(chmod(folder, 0o555) == 0)
                defer { chmod(folder, 0o755) }
                await #expect(throws: POSIXError(.EACCES)) { try await rig.coordinator.start() }
                try #require(chmod(folder, 0o755) == 0)

                #expect(try rig.manifestOnDisk().takes.isEmpty)
                let id = "take-001"
                #expect(rig.lockIsFree(id))
                #expect(rig.reserveBytes(id) == nil)
                #expect(rig.display.startCount == 0 && rig.mic.startCount == 0)
                await rig.warningsDone.value
                #expect(rig.warnings.all.isEmpty)
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.stop() }
            }
        }

        @Test func closeWritesTheLogBeforeMarkingTheTakeComplete() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display])
                let steps = Mutex<[RecordingCoordinator.CloseStep]>([])
                await rig.coordinator.setOnCloseStep { step in steps.withLock { $0.append(step) } }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()
                #expect(steps.withLock { $0 } == [.logClosed, .manifestComplete, .lockReleased])
                #expect(try rig.takeOnDisk(id).status == .complete)
                #expect(try rig.events(id).contains { $0.kind == .segmentStarted(track: "display-1", index: 1) })
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

        @Test func restartWaitsForEachBackoffStepWithoutRealTime() async throws {
            try await withTemporaryDirectory { directory in
                // Default backoff (500 ms first); the other waits are the maintenance's 2 s and the disk watchdog's 50 ms.
                let ticks = ManualTicks()
                let rig = try Rig(in: directory, tracks: [.display], ticks: ticks.ticks)
                let id = try await rig.coordinator.start()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 1 })
                rig.display.failNow(domain: "SCStreamErrorDomain", code: -3821)
                // The error reaches the pipeline's queue asynchronously.
                #expect(await eventually { ticks.pendingSleeps(of: .milliseconds(500)) == 1 })
                #expect(rig.display.startCount == 1)
                await ticks.releaseSleep(of: .milliseconds(500))
                #expect(await eventually { rig.display.startCount == 2 })
                #expect(await eventually { rig.warnings.all.contains(.streamRestarted(track: "display-1")) })
                #expect(ticks.pendingSleeps(of: .seconds(1)) == 0)
                _ = try await rig.coordinator.stop()

                await rig.warningsDone.value
                #expect(rig.warnings.all == [.streamInterrupted(track: "display-1"), .streamRestarted(track: "display-1")])
            }
        }

        /// A stop cancels the restart and waits for it: the manual wait must end on cancellation, or this hangs.
        @Test(.timeLimit(.minutes(1))) func stopDuringAManualRestartWaitReturns() async throws {
            try await withTemporaryDirectory { directory in
                let ticks = ManualTicks()
                let rig = try Rig(in: directory, tracks: [.display], ticks: ticks.ticks)
                let id = try await rig.coordinator.start()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 1 })
                rig.display.failNow(domain: "SCStreamErrorDomain", code: -3821)
                #expect(await eventually { ticks.pendingSleeps(of: .milliseconds(500)) == 1 })
                _ = try await rig.coordinator.stop()

                #expect(ticks.pendingSleeps(of: .milliseconds(500)) == 0)
                #expect(rig.display.startCount == 1)
                #expect(try rig.takeOnDisk(id).track("display-1")?.segments.count == 1)
            }
        }

        @Test func autoStopRacingUserStopClosesOnce() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                let autoStops = Mutex<[TakeRecord]>([])
                await rig.coordinator.setOnAutoStop { record, _ in autoStops.withLock { $0.append(record) } }
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
                #expect(rig.reserveBytes(take.id) == nil)
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

        @Test func writersThatKeepFailingWaitBeforeReopening() async throws {
            try await withTemporaryDirectory { directory in
                let made = Mutex(0)
                let configuration = RecordingConfiguration(restartBackoff: [.milliseconds(1200)])
                let source = CountingSource(inner: SyntheticVideoSource(width: 640, height: 360, framesPerSecond: 30))
                let rig = try Rig(in: directory, sources: [source], configuration: configuration) { url, media in
                    let inner = try FragmentedTrackWriter(url: url, media: media)
                    let count = made.withLock { count in
                        count += 1
                        return count
                    }
                    return count <= 2 ? ScriptedWriter(inner: inner, failAfter: 0) : inner
                }
                let id = try await rig.coordinator.start()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 1 })
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                let display = try #require(take.track("display-1"))
                try #require(display.segments.count == 1)
                let segment = display.segments[0]
                // Two writers failed on their first sample: the first was retried with the next sample,
                // the second waited the backoff. Not a writer per sample, and no file was left behind.
                #expect(made.withLock { $0 } == 3)
                #expect(segment.index == 1 && segment.endReason == .stopped)
                let files = try FileManager.default.contentsOfDirectory(
                    atPath: rig.package.trackDirectory(take: id, track: "display-1").path)
                #expect(files == ["seg-0001.mov"])
                let takeStart = try #require(try rig.events(id).first { if case .displayGeometry = $0.kind { true } else { false } }).t
                #expect(segment.startHostTime.seconds(since: takeStart) > 1.1)
                // Every sample the source delivered before the segment's first frame was dropped, in a row, and
                // is counted in the segment that followed: counted against what the source really delivered, not
                // against the time waited, which a loaded machine fills with fewer frames.
                let delivered = source.deliveredTimes
                let droppedBefore = delivered.filter { $0 < segment.startHostTime }.count
                #expect(droppedBefore >= 2, "\(droppedBefore) samples before the segment")
                #expect(segment.droppedFrames >= droppedBefore && segment.droppedFrames <= delivered.count,
                        "\(segment.droppedFrames) dropped, \(droppedBefore) delivered before the segment")
                await rig.warningsDone.value
                let failures: [RecordingWarning] = [.writerFailed(track: "display-1"), .writerFailed(track: "display-1")]
                if droppedBefore >= SegmentAccounting.warningCount {
                    #expect(rig.warnings.all == failures + [.samplesDropped(track: "display-1")])
                } else {
                    // Fewer in a row than the warning needs: the segment's first frame ended the run, and the few
                    // frames recorded after it cannot make another run that long.
                    #expect(rig.warnings.all == failures)
                }
            }
        }

        @Test func factoryFailureIsRetriedWithTheNextSample() async throws {
            try await withTemporaryDirectory { directory in
                let calls = Mutex(0)
                let rig = try Rig(in: directory, tracks: [.display]) { url, media in
                    let call = calls.withLock { count in
                        count += 1
                        return count
                    }
                    if call == 1 { throw CocoaError(.fileWriteNoPermission) }
                    return try FragmentedTrackWriter(url: url, media: media)
                }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                _ = try await rig.coordinator.stop()

                let segments = try #require(try rig.takeOnDisk(id).track("display-1")?.segments)
                #expect(segments.map(\.index) == [1])
                #expect(segments.map(\.endReason) == [.stopped])
                #expect(segments[0].droppedFrames >= 1)
                #expect(calls.withLock { $0 } == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.writerFailed(track: "display-1")])
            }
        }

        @Test func leftoverSegmentFileIsSkippedAndKept() async throws {
            try await withTemporaryDirectory { directory in
                let leftover = Data("left by an earlier writer".utf8)
                let first = Mutex(true)
                let rig = try Rig(in: directory, tracks: [.display]) { url, media in
                    if first.withLock({ isFirst in defer { isFirst = false }; return isFirst }) {
                        try leftover.write(to: url)
                    }
                    return try FragmentedTrackWriter(url: url, media: media)
                }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(700))
                _ = try await rig.coordinator.stop()

                let segments = try #require(try rig.takeOnDisk(id).track("display-1")?.segments)
                #expect(segments.map(\.file) == ["takes/\(id)/display-1/seg-0002.mov"])
                #expect(try Data(contentsOf: rig.package.segmentURL(take: id, track: "display-1", index: 1)) == leftover)
                await rig.warningsDone.value
                #expect(rig.warnings.all.isEmpty)
            }
        }

        @Test func slowResumeDoesNotStopTheRunARestartStarted() async throws {
            try await withTemporaryDirectory { directory in
                let source = SlowStartSource(inner: SyntheticAudioSource())
                let rig = try Rig(
                    in: directory, sources: [source], configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                rig.activity.yield(.screenLocked)
                #expect(await eventually { rig.liveTrack(id, "mic")?.segments.map(\.endReason) == [.paused] })

                // The resume's `start` runs the source but takes 400 ms to return. Meanwhile the stream
                // fails and the restart starts a newer run, which the late resume must leave running.
                source.delayNextStartReturn(by: .milliseconds(400))
                rig.activity.yield(.screenUnlocked)
                #expect(await eventually { source.inner.startCount == 2 })
                source.inner.failNow(domain: "AVFoundationErrorDomain", code: -11819)
                #expect(await eventually { source.inner.startCount == 3 })
                try await Task.sleep(for: .milliseconds(800))
                #expect(source.inner.activeDeviceUniqueID != nil)
                _ = try await rig.coordinator.stop()

                let mic = try #require(try rig.takeOnDisk(id).track("mic"))
                #expect(mic.segments.map(\.endReason) == [
                    .paused, .streamError(domain: "AVFoundationErrorDomain", code: -11819), .stopped,
                ])
                #expect(try await rig.duration(of: mic.segments[2]) > 0.7)
                #expect(source.inner.startCount == 3)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [
                    .paused(reason: "screenLocked"), .resumed, .streamInterrupted(track: "mic"), .streamRestarted(track: "mic"),
                ])
            }
        }

        @Test func finishFailureOnStaticScreenEndsAtLastHeartbeat() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display]) { url, media in
                    ScriptedWriter(inner: try FragmentedTrackWriter(url: url, media: media), finishError: FinishFailure())
                }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                rig.display.pauseFrames(true)
                try await Task.sleep(for: .milliseconds(1500))
                await #expect(throws: FinishFailure.self) { try await rig.coordinator.stop() }

                let segment = try #require(try rig.takeOnDisk(id).track("display-1")?.segments.first)
                let end = try #require(segment.endHostTime)
                // The heartbeats count: the segment does not end at the last real frame (≈ 0.3 s).
                #expect(end.seconds(since: segment.startHostTime) > 1)
            }
        }

        @Test func failedManifestWriteIsRetriedOnTheSyncTick() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(
                    in: directory, tracks: [.display], configuration: RecordingConfiguration(syncInterval: .milliseconds(200)))
                let id = try await rig.coordinator.start()
                #expect(await eventually { rig.liveTrack(id, "display-1")?.segments.count == 1 })
                // The manifest is replaced through a temporary file in the package folder: make it read-only.
                let folder = rig.package.url.path
                try #require(chmod(folder, 0o555) == 0)
                defer { chmod(folder, 0o755) }
                rig.activity.yield(.screenLocked)
                #expect(await eventually { rig.warnings.all.contains(.manifestWriteFailed) })
                #expect(rig.liveTrack(id, "display-1")?.segments.first?.endReason == nil)
                // Nothing else changes while paused: only the sync tick can write the pending change.
                try #require(chmod(folder, 0o755) == 0)
                #expect(await eventually(timeout: .seconds(2)) {
                    rig.liveTrack(id, "display-1")?.segments.first?.endReason == .paused
                })
                _ = try await rig.coordinator.stop()
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "screenLocked"), .manifestWriteFailed])
            }
        }

        @Test func droppedSamplesAreLoggedWhileRecording() async throws {
            try await withTemporaryDirectory { directory in
                // The encoder has no room for one call in three, so the real-time writer drops frames.
                let rig = try Rig(
                    in: directory, tracks: [.display], configuration: RecordingConfiguration(syncInterval: .milliseconds(300))
                ) { url, media in
                    let writer = try FragmentedTrackWriter(url: url, media: media)
                    let calls = Mutex(0)
                    writer.inputHasRoom = { input in
                        let n = calls.withLock { n in
                            n += 1
                            return n
                        }
                        return n % 3 != 0 && input.isReadyForMoreMediaData
                    }
                    return writer
                }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(1600))
                let record = try await rig.coordinator.stop()

                let counts = try rig.events(id).compactMap { event -> Int? in
                    guard case .droppedSamples("display-1", let count) = event.kind else { return nil }
                    return count
                }
                #expect(counts.count >= 3, "\(counts)")
                #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 < $1 }, "\(counts)")
                #expect((counts.first ?? 0) > 0)
                // The manifest's count at the close includes the drops after the last tick.
                let dropped = try #require(record.track("display-1")?.segments.first?.droppedFrames)
                #expect(dropped >= (counts.last ?? .max), "\(dropped) vs \(counts)")
            }
        }

        @Test func audioClockNamesFramesThatAreInTheFileAfterDrops() async throws {
            try await withTemporaryDirectory { directory in
                // From 1 s to 4.5 s the encoder has no room: the 2 s queue drops the oldest 1.5 s of audio.
                let rig = try Rig(in: directory, tracks: [.mic]) { url, media in
                    let writer = try FragmentedTrackWriter(url: url, media: media)
                    let created = HostTime.now()
                    writer.inputHasRoom = { input in
                        let elapsed = HostTime.now().seconds(since: created)
                        return !(1.0..<4.5).contains(elapsed) && input.isReadyForMoreMediaData
                    }
                    return writer
                }
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(11.5))
                let record = try await rig.coordinator.stop()

                let segment = try #require(record.track("mic")?.segments.first)
                #expect(segment.droppedFrames >= 100, "\(segment.droppedFrames) blocks dropped")
                let anchors = try rig.events(id).compactMap { event -> (frame: Int, t: HostTime)? in
                    guard case .audioClock("mic", let frame) = event.kind else { return nil }
                    return (frame, event.t)
                }
                #expect(anchors.count >= 2)
                // The synthetic microphone stamps block n at start + n × 10 ms, so the sample captured at t
                // is source frame (t − start) × 48 kHz; in the file, the dropped blocks (all before the first
                // anchor) are missing in front of it.
                for anchor in anchors {
                    let captured = Int((anchor.t.seconds(since: segment.startHostTime) * 48_000).rounded())
                    #expect(anchor.frame == captured - 480 * segment.droppedFrames, "anchor \(anchor)")
                }
            }
        }

        // MARK: Window, camera and system audio

        @Test func cameraAndSystemAudioRecordTheirOwnTracks() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display, .mic, .camera, .systemAudio])
                let times = MeasuredTake()
                let id = try await times.start(rig.coordinator)
                // The first audioClock anchor of a segment comes at 5 s of its audio.
                try await Task.sleep(for: .seconds(6))
                let anchored: (InputEvent) -> String? = { event in
                    guard case .audioClock(let track, _) = event.kind else { return nil }
                    return track
                }
                #expect(await eventually(timeout: .seconds(10)) {
                    Set((try? rig.events(id))?.compactMap(anchored) ?? []) == ["mic", "system-audio"]
                })
                let record = try await times.stop(rig.coordinator)

                let take = try rig.takeOnDisk(id)
                #expect(record == take)
                #expect(take.tracks.map(\.id) == ["display-1", "mic", "camera", "system-audio"])
                #expect(take.tracks.map(\.kind) == [.display, .microphone, .camera, .systemAudio])
                #expect(take.track("camera")?.source == TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"))
                #expect(take.track("system-audio")?.source == TrackSource(
                    name: "Synthetic System Audio", excludedBundleIDs: ["dev.toma.Toma"]))
                for track in take.tracks {
                    try #require(track.segments.count == 1, "\(track.id)")
                    #expect(track.segments[0].file == "takes/\(id)/\(track.id)/seg-0001.mov")
                    #expect(track.segments[0].endReason == .stopped, "\(track.id)")
                }
                let camera = try #require(take.track("camera")?.segments.first)
                let span = try #require(camera.endHostTime).seconds(since: camera.startHostTime)
                times.expectSpansTheTake(span)
                #expect(span > 5.5, "the camera recorded \(span) s")
                #expect(abs(try await rig.duration(of: camera) - span) < 0.15)
                let systemAudio = try #require(take.track("system-audio")?.segments.first)
                let format = try await rig.audioFormat(of: systemAudio)
                #expect(format.mSampleRate == 48_000 && format.mChannelsPerFrame == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all.isEmpty)
            }
        }

        @Test func cameraLossFallsBackAndLogsDeviceChanged() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(
                    in: directory, tracks: [.display, .camera], configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                // The camera went away: the restart takes another one.
                rig.camera.deviceUniqueID = "usb-camera"
                rig.camera.failNow(domain: "AVFoundationErrorDomain", code: -11818)
                #expect(await eventually { rig.liveTrack(id, "camera")?.segments.count == 2 })
                try await Task.sleep(for: .milliseconds(500))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                let camera = try #require(take.track("camera"))
                #expect(camera.segments.map(\.endReason) == [
                    .streamError(domain: "AVFoundationErrorDomain", code: -11818), .stopped,
                ])
                #expect(camera.segments.map(\.index) == [1, 2])
                #expect(try await rig.duration(of: camera.segments[1]) > 0.3)
                // The manifest names the camera the take started with; the log, the one it changed to.
                #expect(camera.source.deviceUniqueID == "synthetic-camera")
                let changes = try rig.events(id).filter {
                    if case .deviceChanged = $0.kind { return true }
                    return false
                }
                #expect(changes.map(\.kind) == [.deviceChanged(track: "camera", deviceUniqueID: "usb-camera")])
                #expect(take.track("display-1")?.segments.map(\.endReason) == [.stopped])
                #expect(rig.camera.startCount == 2)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.streamInterrupted(track: "camera"), .streamRestarted(track: "camera")])
            }
        }

        @Test func cameraKeepsRetryingAfterRestartsAreUsedUp() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(
                    in: directory, tracks: [.display, .camera], configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(500))
                rig.camera.failOnStart = 99
                rig.camera.failNow(domain: "AVFoundationErrorDomain", code: -11819)
                #expect(await eventually { rig.warnings.all.contains(.trackPaused(track: "camera")) })
                // It goes on trying at the last interval, well past the one attempt of the backoff.
                #expect(await eventually { rig.camera.startCount >= 6 })
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                #expect(take.track("camera")?.segments.map(\.endReason) == [
                    .streamError(domain: "AVFoundationErrorDomain", code: -11819),
                ])
                // The screen goes on.
                let display = try #require(take.track("display-1"))
                #expect(display.segments.map(\.endReason) == [.stopped])
                #expect(try await rig.duration(of: display.segments[0]) > 0.5)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.streamInterrupted(track: "camera"), .trackPaused(track: "camera")])
            }
        }

        @Test func windowResizeOpensNewSegment() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(
                    in: directory, tracks: [.window, .mic], configuration: RecordingConfiguration(restartBackoff: [.milliseconds(10)]))
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                rig.window.resize(width: 800, height: 600)
                #expect(await eventually { rig.liveTrack(id, "window-4242")?.segments.count == 2 })
                try await Task.sleep(for: .milliseconds(500))
                // The window is the take's only screen: once its attempts are used up it keeps trying, like a sole display.
                rig.window.failOnStart = 3
                rig.window.failNow(domain: "SCStreamErrorDomain", code: -3815)
                #expect(await eventually { rig.warnings.all.contains(.streamRestarted(track: "window-4242")) })
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()

                let take = try rig.takeOnDisk(id)
                let window = try #require(take.track("window-4242"))
                let frame = Rect(x: 100, y: 80, width: 640, height: 360)
                #expect(window.kind == .window)
                #expect(window.source == TrackSource(
                    name: "Synthetic Window", globalFrame: frame, pixelScale: 1, windowID: 4242, bundleIdentifier: "dev.toma.synthetic"))
                try #require(window.segments.count == 3)
                #expect(window.segments.map(\.endReason) == [
                    .formatChanged, .streamError(domain: "SCStreamErrorDomain", code: -3815), .stopped,
                ])
                // The new size starts a segment with its first frame: no gap, no wait.
                let firstEnd = try #require(window.segments[0].endHostTime)
                #expect(abs(window.segments[1].startHostTime.seconds(since: firstEnd)) < 0.001)
                #expect(try await rig.videoSize(of: window.segments[0]) == CGSize(width: 640, height: 360))
                #expect(try await rig.videoSize(of: window.segments[1]) == CGSize(width: 800, height: 600))
                #expect(take.track("mic")?.segments.map(\.endReason) == [.stopped])
                #expect(rig.window.startCount == 5)

                // Where the window was, written as the take starts: before any segment.
                let events = try rig.events(id)
                let isGeometry: (InputEvent) -> Bool = { event in
                    switch event.kind {
                    case .windowGeometry, .displayGeometry: true
                    default: false
                    }
                }
                #expect(events.filter(isGeometry).map(\.kind) == [.windowGeometry(track: "window-4242", frame: frame, onScreen: true)])
                let geometry = try #require(events.firstIndex(where: isGeometry))
                let firstSegment = try #require(events.firstIndex {
                    if case .segmentStarted = $0.kind { return true }
                    return false
                })
                #expect(geometry < firstSegment)
                await rig.warningsDone.value
                // `displayPaused`, which the app shows as the window paused, and its resolution when it comes back.
                #expect(rig.warnings.all == [
                    .streamInterrupted(track: "window-4242"), .displayPaused(track: "window-4242"),
                    .streamRestarted(track: "window-4242"),
                ])
            }
        }

        @Test func takeRecordCarriesTheInitialCameraStyle() async throws {
            try await withTemporaryDirectory { directory in
                let chosen = CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top)
                let cases: [(tracks: [Rig.Track], style: CameraStyle?, expected: CameraStyle?)] = [
                    ([.display, .camera], chosen, chosen),
                    ([.display, .camera], nil, .default),
                    // Without a camera the take has no camera style, whatever was asked.
                    ([.display, .mic], chosen, nil),
                ]
                for (n, (tracks, style, expected)) in cases.enumerated() {
                    let folder = directory.appendingPathComponent("\(n)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let rig = try Rig(in: folder, tracks: tracks, cameraStyle: style)
                    let id = try await rig.coordinator.start()
                    // In the record the manifest has before anything is recorded.
                    #expect(rig.liveTake(id)?.cameraStyle == expected, "case \(n)")
                    try await Task.sleep(for: .milliseconds(200))
                    let record = try await rig.coordinator.stop()
                    #expect(record.cameraStyle == expected, "case \(n)")
                    #expect(try rig.takeOnDisk(id).cameraStyle == expected, "case \(n)")
                }
            }
        }

        @Test func cameraStyleChangesAreLoggedAtTheirTime() async throws {
            try await withTemporaryDirectory { directory in
                let clock = PinnedClock()
                let rig = try Rig(in: directory, tracks: [.display, .camera], clock: clock.now)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(300))
                // The style the take started with is no change.
                try await rig.coordinator.setCameraStyle(.default)
                let moved = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
                let movedAt = HostTime.now()
                clock.pin(movedAt)
                try await rig.coordinator.setCameraStyle(moved)
                clock.pin(nil)
                try await rig.coordinator.setCameraStyle(moved)
                try await Task.sleep(for: .milliseconds(100))
                let resized = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
                let resizedAt = HostTime.now()
                clock.pin(resizedAt)
                try await rig.coordinator.setCameraStyle(resized)
                clock.pin(nil)
                try await Task.sleep(for: .milliseconds(100))
                _ = try await rig.coordinator.stop()

                let styles = try rig.events(id).compactMap { event -> (style: CameraStyle, t: HostTime)? in
                    guard case .cameraStyle(let style) = event.kind else { return nil }
                    return (style, event.t)
                }
                #expect(styles.map(\.style) == [moved, resized])
                #expect(styles.map(\.t) == [movedAt, resizedAt])
            }
        }

        @Test func cameraStyleChangedWhilePausedIsLoggedAtResume() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display, .camera])
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .seconds(1))
                try await rig.coordinator.pause()
                let moved = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
                let last = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .leading)
                try await rig.coordinator.setCameraStyle(moved)
                try await rig.coordinator.setCameraStyle(last)
                try await Task.sleep(for: .seconds(1))
                try await rig.coordinator.resume()
                // A system pause holds a change back too, and one that ends at the style written last is no change.
                rig.activity.yield(.screenLocked)
                #expect(await eventually { rig.warnings.all.contains(.paused(reason: "screenLocked")) })
                try await rig.coordinator.setCameraStyle(moved)
                try await rig.coordinator.setCameraStyle(last)
                rig.activity.yield(.screenUnlocked)
                #expect(await eventually { rig.warnings.all.filter { $0 == .resumed }.count == 2 })
                try await Task.sleep(for: .milliseconds(300))
                _ = try await rig.coordinator.stop()

                let events = try rig.events(id)
                let styles = events.indices.filter {
                    if case .cameraStyle = events[$0].kind { return true }
                    return false
                }
                try #require(styles.count == 1, "\(styles.map { events[$0] })")
                let style = styles[0]
                #expect(events[style].kind == .cameraStyle(last))
                // Right after the first `resumed`, at its time.
                let resumed = try #require(events.firstIndex { $0.kind == .resumed })
                #expect(style == resumed + 1)
                #expect(events[style].t == events[resumed].t)
                let paused = try #require(events.first { $0.kind == .paused(reason: "user") })
                #expect(events[resumed].t.seconds(since: paused.t) > 0.9)
                await rig.warningsDone.value
                #expect(rig.warnings.all == [.paused(reason: "user"), .resumed, .paused(reason: "screenLocked"), .resumed])
            }
        }

        @Test func cameraStyleOutsideATakeThrows() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display, .camera])
                let moved = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.setCameraStyle(moved) }
                let id = try await rig.coordinator.start()
                _ = try await rig.coordinator.stop()
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.setCameraStyle(moved) }
                #expect(!(try rig.events(id)).contains {
                    if case .cameraStyle = $0.kind { return true }
                    return false
                })
            }
        }

        @Test func cameraStyleOfATakeWithoutACameraIsNotLogged() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory, tracks: [.display])
                let id = try await rig.coordinator.start()
                try await rig.coordinator.setCameraStyle(CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading))
                _ = try await rig.coordinator.stop()
                #expect(!(try rig.events(id)).contains {
                    if case .cameraStyle = $0.kind { return true }
                    return false
                })
            }
        }

        @Test func startRefusesAPackageOfAnotherFormatVersion() async throws {
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                // A version 1 package is never given what only version 2 defines: nothing in it changes.
                var manifest = try rig.manifestOnDisk()
                manifest.formatVersion = 1
                let version1 = try ProjectJSON.encoder().encode(manifest)
                try version1.write(to: rig.package.manifestURL)
                await #expect(throws: RecordingError.notCurrentFormatVersion(1)) { try await rig.coordinator.start() }

                #expect(try Data(contentsOf: rig.package.manifestURL) == version1)
                #expect(try FileManager.default.contentsOfDirectory(atPath: rig.package.takesURL.path).isEmpty)
                #expect(rig.display.startCount == 0 && rig.mic.startCount == 0)
                await rig.warningsDone.value
                #expect(rig.warnings.all.isEmpty)
                await #expect(throws: RecordingError.notRecording) { try await rig.coordinator.stop() }
            }
        }

        @Test func recordingAcceptsThreeToFive() async throws {
            #expect(Manifest.recordableFormatVersions == 3...5)
            // A package of version 4 (an earlier take recorded an iPhone) gets more takes, and stays at 4.
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                var manifest = try rig.manifestOnDisk()
                manifest.formatVersion = 4
                try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: rig.package.manifestURL)
                let id = try await rig.coordinator.start()
                try await Task.sleep(for: .milliseconds(600))
                _ = try await rig.coordinator.stop()
                let after = try rig.manifestOnDisk()
                #expect(after.formatVersion == 4)
                #expect(after.projectID == manifest.projectID)
                let take = try rig.takeOnDisk(id)
                #expect(take.status == .complete)
                #expect(take.tracks.map(\.id) == ["mic", "display-1"])
                #expect(!after.needsFormatVersion4)
            }
            // A package of version 2 is refused, as one of version 1: nothing in it changes.
            try await withTemporaryDirectory { directory in
                let rig = try Rig(in: directory)
                var manifest = try rig.manifestOnDisk()
                manifest.formatVersion = 2
                manifest.projectID = nil
                let version2 = try ProjectJSON.encoder().encode(manifest)
                try version2.write(to: rig.package.manifestURL)
                await #expect(throws: RecordingError.notCurrentFormatVersion(2)) { try await rig.coordinator.start() }
                #expect(try Data(contentsOf: rig.package.manifestURL) == version2)
                #expect(try FileManager.default.contentsOfDirectory(atPath: rig.package.takesURL.path).isEmpty)
                #expect(rig.display.startCount == 0 && rig.mic.startCount == 0)
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
}

// MARK: - Support

/// A take recorded from synthetic sources into a fresh package, with a fake disk and an injected
/// system-activity stream.
struct Rig {
    enum Track { case mic, display, camera, systemAudio, window }

    let package: ProjectPackage
    let display = SyntheticVideoSource(width: 640, height: 360, framesPerSecond: 30)
    let mic = SyntheticAudioSource()
    let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 320, height: 180, framesPerSecond: 30)
    let systemAudio = SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2, clockSkewPPM: -1500)
    /// The window's frame in global points: 640 × 360 at (100, 80).
    let window = SyntheticVideoSource(
        trackID: "window-4242", kind: .window, globalOrigin: [100, 80], width: 640, height: 360, framesPerSecond: 30)
    let disk = FakeDisk()
    let activity: AsyncStream<SystemActivity>.Continuation
    let coordinator: RecordingCoordinator
    let warnings = WarningLog()
    /// Ends when the coordinator's `warnings` finishes, after the take closes.
    let warningsDone: Task<Void, Never>

    /// Records `tracks` from the rig's synthetic sources, or `sources` instead when given.
    init(
        in directory: URL,
        tracks: [Track] = [.mic, .display],
        sources custom: [any CaptureSource]? = nil,
        input: any InputRecorder = NoInputRecorder(),
        configuration: RecordingConfiguration = .init(),
        writerFactory: WriterFactory? = nil,
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        ticks: RecordingTicks = .live,
        cameraStyle: CameraStyle? = nil
    ) throws {
        package = try ProjectPackage.create(in: directory, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let (stream, continuation) = AsyncStream.makeStream(of: SystemActivity.self)
        activity = continuation
        let (mic, display, camera, systemAudio, window) = (mic, display, camera, systemAudio, window)
        let sources: [any CaptureSource] = custom ?? tracks.map { track -> any CaptureSource in
            switch track {
            case .mic: mic
            case .display: display
            case .camera: camera
            case .systemAudio: systemAudio
            case .window: window
            }
        }
        coordinator = RecordingCoordinator(
            package: package,
            sources: sources,
            input: input,
            diskMonitor: disk.monitor(volume: directory),
            systemActivity: stream,
            configuration: configuration,
            writerFactory: writerFactory ?? { url, media in try FragmentedTrackWriter(url: url, media: media) },
            clock: clock,
            ticks: ticks,
            cameraStyle: cameraStyle
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

    /// Bytes allocated on disk to the take's reserve file, or `nil` if there is none.
    func reserveBytes(_ id: String) -> Int64? {
        var info = stat()
        guard stat(package.reserveURL(take: id).path, &info) == 0 else { return nil }
        return Int64(info.st_blocks) * 512
    }

    func url(of segment: SegmentRecord) -> URL {
        package.url.appending(path: segment.file)
    }

    func duration(of segment: SegmentRecord) async throws -> Double {
        try await AVURLAsset(url: url(of: segment)).load(.duration).seconds
    }

    func videoSize(of segment: SegmentRecord) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url(of: segment)).loadTracks(withMediaType: .video).first)
        return try await track.load(.naturalSize)
    }

    func audioFormat(of segment: SegmentRecord) async throws -> AudioStreamBasicDescription {
        let track = try #require(try await AVURLAsset(url: url(of: segment)).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    }
}

/// Wraps a real writer: fails its appends from `failAfter` seconds after creation, or after
/// `failAfterAppends` appends went through (with `failure`, by default `NSError(domain: "TestWriter", code: 7)`),
/// or throws `finishError` after finishing the file.
final class ScriptedWriter: TrackWriting {
    private let inner: FragmentedTrackWriter
    private let failAt: HostTime?
    private let failAfterAppends: Int?
    private let failureToInject: NSError
    private let finishError: (any Error)?
    private var injected: NSError?
    private var appends = 0

    init(
        inner: FragmentedTrackWriter, failAfter seconds: Double? = nil, failAfterAppends: Int? = nil,
        failure: NSError = NSError(domain: "TestWriter", code: 7), finishError: (any Error)? = nil
    ) {
        self.inner = inner
        self.failAt = seconds.map { HostTime.now().adding(seconds: $0) }
        self.failAfterAppends = failAfterAppends
        self.failureToInject = failure
        self.finishError = finishError
    }

    var onStart: ((HostTime) -> Void)? {
        get { inner.onStart }
        set { inner.onStart = newValue }
    }

    var formatDescription: CMFormatDescription? { inner.formatDescription }
    var failure: NSError? { injected ?? inner.failure }
    var droppedSampleCount: Int { inner.droppedSampleCount }
    var lastWrittenAudio: AudioFilePosition? { inner.lastWrittenAudio }

    func append(_ sample: CMSampleBuffer) throws {
        if injected == nil, failAt.map({ HostTime.now() >= $0 }) ?? false || failAfterAppends.map({ appends >= $0 }) ?? false {
            injected = failureToInject
        }
        if injected == nil { appends += 1 }
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

/// The host times around a take's `start()` and `stop()`, so a test measures against the time that
/// really passed, not the time it slept: under load a sleep lasts longer than asked.
final class MeasuredTake: @unchecked Sendable {
    private(set) var beforeStart = HostTime(nanoseconds: 0)
    private(set) var started = HostTime(nanoseconds: 0)
    private(set) var stopping = HostTime(nanoseconds: 0)
    private(set) var stopped = HostTime(nanoseconds: 0)

    func start(_ coordinator: RecordingCoordinator) async throws -> String {
        beforeStart = HostTime.now()
        defer { started = HostTime.now() }
        return try await coordinator.start()
    }

    func stop(_ coordinator: RecordingCoordinator) async throws -> TakeRecord {
        stopping = HostTime.now()
        defer { stopped = HostTime.now() }
        return try await coordinator.stop()
    }

    /// A segment recorded the whole take lasts no longer than from before `start()` to after `stop()`, and
    /// at least from `start()`'s return to the `stop()` call, less what its first and last samples take.
    func expectSpansTheTake(_ span: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let outer = stopped.seconds(since: beforeStart), inner = stopping.seconds(since: started)
        #expect(span <= outer + 0.05, "\(span) s, longer than the \(outer) s measured", sourceLocation: sourceLocation)
        #expect(span >= inner - 0.3, "\(span) s, shorter than the \(inner) s measured", sourceLocation: sourceLocation)
    }
}

/// A synthetic display that records the presentation time of every sample it delivers.
final class CountingSource: CaptureSource {
    let inner: SyntheticVideoSource
    private let delivered = Mutex<[HostTime]>([])

    init(inner: SyntheticVideoSource) {
        self.inner = inner
    }

    var trackID: String { inner.trackID }
    var kind: TrackKind { inner.kind }
    var media: TrackMedia { inner.media }
    var sourceInfo: TrackSource { inner.sourceInfo }
    var activeDeviceUniqueID: String? { inner.activeDeviceUniqueID }
    /// The PTS of every sample delivered so far, in order.
    var deliveredTimes: [HostTime] { delivered.withLock { $0 } }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await inner.start(on: queue, sink: CountingSink(sink: sink) { [weak self] time in self?.record(time) })
    }

    private func record(_ time: HostTime) {
        delivered.withLock { $0.append(time) }
    }

    func stop() async {
        await inner.stop()
    }
}

/// Passes every call on to `sink`, telling `record` the PTS of each sample first.
private final class CountingSink: CaptureSink {
    private let sink: any CaptureSink
    private let record: @Sendable (HostTime) -> Void

    init(sink: any CaptureSink, record: @escaping @Sendable (HostTime) -> Void) {
        self.sink = sink
        self.record = record
    }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        record(HostTime(sample.presentationTimeStamp))
        sink.source(trackID, didOutput: sample)
    }

    func source(_ trackID: String, didStopWithError error: any Error) {
        sink.source(trackID, didStopWithError: error)
    }
}

/// The host clock, or the time the test pinned while it is pinned.
final class PinnedClock: Sendable {
    private let pinned = Mutex<HostTime?>(nil)

    func now() -> HostTime {
        pinned.withLock { $0 } ?? HostTime.now()
    }

    /// `now()` returns `time` until it is pinned to `nil`.
    func pin(_ time: HostTime?) {
        pinned.withLock { $0 = time }
    }
}

/// The host clock moved ahead by what the test added.
final class OffsetClock: Sendable {
    private let offset = Mutex(0.0)

    func now() -> HostTime {
        HostTime.now().adding(seconds: offset.withLock { $0 })
    }

    func advance(seconds: Double) {
        offset.withLock { $0 += seconds }
    }
}

/// A cursor location that moves on every call, so every sample is recorded.
final class MovingLocation: Sendable {
    private let calls = Mutex(0)

    func next() -> CGPoint {
        CGPoint(x: Double(calls.withLock { $0 += 1; return $0 }), y: 7)
    }
}

/// A synthetic microphone whose `start` can be made to return late, after its run already delivers.
final class SlowStartSource: CaptureSource {
    let inner: SyntheticAudioSource
    private let pendingDelay = Mutex<Duration?>(nil)

    init(inner: SyntheticAudioSource) {
        self.inner = inner
    }

    var trackID: String { inner.trackID }
    var kind: TrackKind { inner.kind }
    var media: TrackMedia { inner.media }
    var sourceInfo: TrackSource { inner.sourceInfo }
    var activeDeviceUniqueID: String? { inner.activeDeviceUniqueID }

    /// The next `start` returns `delay` after the source started.
    func delayNextStartReturn(by delay: Duration) {
        pendingDelay.withLock { $0 = delay }
    }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        let delay = pendingDelay.withLock { delay in
            defer { delay = nil }
            return delay
        }
        try await inner.start(on: queue, sink: sink)
        if let delay { try? await Task.sleep(for: delay) }
    }

    func stop() async {
        await inner.stop()
    }
}
