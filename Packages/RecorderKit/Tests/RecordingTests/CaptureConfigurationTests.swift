// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import ScreenCaptureKit
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

@Suite struct CaptureConfigurationTests {
    @Test func configurationCapturesNativePixelsWithoutCursor() {
        let c = DisplayCaptureSource.makeConfiguration(
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982), pointPixelScale: 2, framesPerSecond: 60)
        #expect(c.width == 3024 && c.height == 1964 && c.showsCursor == false)
        #expect(c.pixelFormat == kCVPixelFormatType_32BGRA && c.minimumFrameInterval == CMTime(value: 1, timescale: 60) && c.queueDepth == 6)
        #expect(c.showMouseClicks == false && c.capturesAudio == false && c.captureResolution == .best)
        #expect(c.colorSpaceName == CGColorSpace.sRGB)
    }

    @Test func displayConfigurationAtPointsScale() {
        let c = DisplayCaptureSource.makeConfiguration(
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982), pointPixelScale: 2, framesPerSecond: 30, scale: .points)
        #expect(c.width == 1512 && c.height == 982 && c.minimumFrameInterval == CMTime(value: 1, timescale: 30))
    }

    @Test func pointsScaleRecordsPixelScaleOne() {
        #expect(DisplayCaptureSource.recordedPixelScale(displayScale: 2, scale: .points) == 1)
        #expect(DisplayCaptureSource.recordedPixelScale(displayScale: nil, scale: .points) == 1)
        #expect(DisplayCaptureSource.recordedPixelScale(displayScale: 2, scale: .native) == 2)
        #expect(DisplayCaptureSource.recordedPixelScale(displayScale: nil, scale: .native) == nil)
        // Whatever the display's own scale, the manifest gets the recorded one.
        #expect(DisplayCaptureSource(displayID: 7, framesPerSecond: 30, scale: .points).sourceInfo.pixelScale == 1)
    }

    @Test func areaDoesNotNarrowTheCapture() {
        // makeConfiguration takes no area: the whole display is recorded, and the area only goes to the manifest.
        let area = Rect(x: 100, y: 100, width: 800, height: 450)
        #expect(DisplayCaptureSource(displayID: 7, framesPerSecond: 30, captureArea: area).sourceInfo.captureArea == area)
        #expect(DisplayCaptureSource(displayID: 7, framesPerSecond: 30).sourceInfo.captureArea == nil)
    }

    @Test func displayExclusionsFindAppsWithoutVisibleWindows() {
        let own = getpid()
        let apps: [(pid: pid_t, bundleID: String?)] = [
            (own, "dev.toma.Toma"), (77, "com.apple.notificationcenterui"), (80, "com.apple.Safari"), (81, nil),
        ]
        let bundleIDs = DisplayExclusions.bundleIdentifiers
        #expect(bundleIDs == ["com.apple.notificationcenterui"])

        let all = DisplayExclusions.excluded(apps: apps, ownPID: own, bundleIDs: bundleIDs)
        #expect(all.pids == [own, 77] && all.missingBundleIDs.isEmpty && !all.ownAppMissing)

        let withoutNotifications = DisplayExclusions.excluded(apps: apps.filter { $0.pid != 77 }, ownPID: own, bundleIDs: bundleIDs)
        #expect(withoutNotifications.pids == [own])
        #expect(withoutNotifications.missingBundleIDs == ["com.apple.notificationcenterui"] && !withoutNotifications.ownAppMissing)

        let withoutOwn = DisplayExclusions.excluded(apps: apps.filter { $0.pid != own }, ownPID: own, bundleIDs: bundleIDs)
        #expect(withoutOwn.pids == [77] && withoutOwn.missingBundleIDs.isEmpty && withoutOwn.ownAppMissing)
    }

    @Test func windowConfigurationMatchesTheWindowBounds() {
        let c = WindowCaptureSource.makeConfiguration(pixelSize: CGSize(width: 1800, height: 1200), framesPerSecond: 30)
        #expect(c.width == 1800 && c.height == 1200 && c.showsCursor == false && c.showMouseClicks == false)
        #expect(c.includeChildWindows && c.ignoreShadowsSingleWindow && c.ignoreGlobalClipSingleWindow)
        #expect(c.pixelFormat == kCVPixelFormatType_32BGRA && c.minimumFrameInterval == CMTime(value: 1, timescale: 30) && c.queueDepth == 6)
        #expect(c.capturesAudio == false && c.captureResolution == .best && c.colorSpaceName == CGColorSpace.sRGB)
    }

    @Test func windowIdentifiesItsTrack() {
        // No window has this ID: the source still names its track, and records nothing until it is found.
        let missing = CGWindowID(0xFFFF_FFF0)
        let window = WindowCaptureSource(windowID: missing, framesPerSecond: 30)
        #expect(window.trackID == "window-\(missing)" && window.kind == .window && window.media == .video(framesPerSecond: 30))
        #expect(window.activeDeviceUniqueID == nil && window.lastCompleteFrameTime == nil)
        #expect(window.sourceInfo == TrackSource(name: "Window \(missing)", windowID: missing))
        #expect(WindowCaptureSource(windowID: missing, scale: .points).sourceInfo.pixelScale == 1)
    }

    @Test func frameGeometryIsReadFromTheFrameInfo() {
        let sample = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 1), frameIndex: 0)
        setFrameInfo(.contentRect, CGRect(x: 0, y: 0, width: 750, height: 500).dictionaryRepresentation, on: sample)
        setFrameInfo(.contentScale, (5.0 / 6.0) as CFNumber, on: sample)
        setFrameInfo(.scaleFactor, 2.0 as CFNumber, on: sample)
        #expect(StreamFrameGeometry(sample) == StreamFrameGeometry(
            contentRect: CGRect(x: 0, y: 0, width: 750, height: 500), contentScale: 5.0 / 6.0, scaleFactor: 2))
        let unmarked = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 2), frameIndex: 1)
        #expect(StreamFrameGeometry(unmarked) == nil)
    }

    @Test func onlyCompleteFramesAreForwarded() {
        let complete = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 1), frameIndex: 0)
        setFrameStatus(.complete, on: complete)
        let idle = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 2), frameIndex: 1)
        setFrameStatus(.idle, on: idle)
        let unmarked = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 3), frameIndex: 2)
        #expect(DisplayCaptureSource.isCompleteFrame(complete))
        #expect(!DisplayCaptureSource.isCompleteFrame(idle))
        #expect(!DisplayCaptureSource.isCompleteFrame(unmarked))
    }

    @Test func displayAndMicrophoneIdentifyTheirTracks() {
        let display = DisplayCaptureSource(displayID: 7, framesPerSecond: 30)
        #expect(display.trackID == "display-7" && display.kind == .display && display.media == .video(framesPerSecond: 30))
        #expect(display.sourceInfo.displayID == 7 && display.activeDeviceUniqueID == nil)
        let microphone = MicrophoneCaptureSource(preferredDeviceUniqueID: nil)
        #expect(microphone.trackID == "mic" && microphone.kind == .microphone && microphone.media == .audio)
        #expect(microphone.activeDeviceUniqueID == nil)
    }

    @Test func microphoneRetimingMovesOnlyTheTimestamps() throws {
        let original = SampleFactory.audioSample(pts: HostTime(nanoseconds: 1_000_000_000), frames: 480, sampleRate: 48_000, channels: 2)
        let retimed = try CaptureClock.retimed(original) { $0 + CMTime(value: 1, timescale: 1) }
        #expect(retimed.presentationTimeStamp == CMTime(value: 2_000_000_000, timescale: 1_000_000_000))
        #expect(retimed.numSamples == 480)
        let originalFormat = try #require(original.formatDescription)
        let retimedFormat = try #require(retimed.formatDescription)
        #expect(CMFormatDescriptionEqual(originalFormat, otherFormatDescription: retimedFormat))
        #expect(original.presentationTimeStamp == CMTime(value: 1_000_000_000, timescale: 1_000_000_000))
    }

    @Test func syntheticSourceDeliversOnGivenQueueInOrder() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.video")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
        #expect(source.trackID == "display-1" && source.kind == .display && source.media == .video(framesPerSecond: 30))
        #expect(source.sourceInfo == TrackSource(
            name: source.sourceInfo.name, displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 64, height: 36), pixelScale: 1))

        let started = HostTime.now()
        try await source.start(on: queue, sink: sink)
        try await Task.sleep(for: .seconds(1))
        await source.stop()
        let elapsed = HostTime.now().seconds(since: started)

        let samples = sink.samples
        // It keeps delivering, never faster than its frame rate. A loaded machine fires its timer less often,
        // so how many arrive in a second is not this test's to check.
        #expect(samples.count >= 3, "\(samples.count) frames in \(elapsed) s")
        #expect(Double(samples.count) <= elapsed * 30 + 2, "\(samples.count) frames in \(elapsed) s")
        #expect(samples.allSatisfy { $0.trackID == "display-1" && $0.width == 64 && $0.height == 36 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.pts < $1.pts })
        #expect(sink.failures.isEmpty)
        #expect(source.startCount == 1)

        // Nothing arrives once stop() has returned.
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.samples.count == samples.count)
    }

    @Test func stopReleasesTheSink() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.release")
        let source = SyntheticAudioSource()
        weak var released: RecordingSink?
        do {
            let sink = RecordingSink(queue: queue)
            released = sink
            try await source.start(on: queue, sink: sink)
            #expect(await eventually { sink.samples.count >= 2 })
            await source.stop()
        }
        #expect(released == nil)
    }

    @Test func syntheticFailureReachesSink() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.failure")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 3 })

        source.failNow(domain: "SCStreamErrorDomain", code: -3821)
        #expect(await eventually { !sink.failures.isEmpty })
        let failures = sink.failures
        #expect(failures.map(\.domain) == ["SCStreamErrorDomain"] && failures.map(\.code) == [-3821])

        // The error is the last delivery of that run.
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.samples.count == failures[0].samplesBefore)

        // start may be called again after an error.
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count > failures[0].samplesBefore })
        await source.stop()
        #expect(source.startCount == 2)
        #expect(sink.failures.count == 1)
    }

    @Test func failOnStartThrowsThenStartsNormally() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.failOnStart")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticAudioSource()
        source.failOnStart = 2
        for _ in 0..<2 {
            await #expect(throws: NSError(domain: "Synthetic", code: -1)) {
                try await source.start(on: queue, sink: sink)
            }
        }
        #expect(source.activeDeviceUniqueID == nil)
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 2 })
        #expect(source.activeDeviceUniqueID == source.deviceUniqueID)
        await source.stop()
        #expect(source.startCount == 3 && source.failOnStart == 0)
        #expect(source.activeDeviceUniqueID == nil)
    }

    @Test func syntheticCameraReportsItsDeviceLikeAMicrophone() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.camera")
        let sink = RecordingSink(queue: queue)
        let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 64, height: 36, framesPerSecond: 30)
        camera.failOnStart = 1
        await #expect(throws: NSError(domain: "Synthetic", code: -1)) { try await camera.start(on: queue, sink: sink) }
        #expect(camera.activeDeviceUniqueID == nil)
        try await camera.start(on: queue, sink: sink)
        #expect(camera.activeDeviceUniqueID == "synthetic-camera")
        // Kept after an error; the next start takes the device it has then.
        camera.failNow(domain: "AVFoundationErrorDomain", code: -11819)
        #expect(await eventually { !sink.failures.isEmpty })
        #expect(camera.activeDeviceUniqueID == "synthetic-camera")
        camera.deviceUniqueID = "usb-camera"
        try await camera.start(on: queue, sink: sink)
        #expect(camera.activeDeviceUniqueID == "usb-camera")
        await camera.stop()
        #expect(camera.activeDeviceUniqueID == nil)

        // The other video kinds have no device.
        let display = SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
        let window = SyntheticVideoSource(trackID: "window-4242", kind: .window, width: 64, height: 36, framesPerSecond: 30)
        for source in [display, window] {
            try await source.start(on: queue, sink: sink)
            #expect(source.activeDeviceUniqueID == nil)
            await source.stop()
        }
    }

    @Test func resizeChangesTheNextFrames() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.resize")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticVideoSource(trackID: "window-4242", kind: .window, width: 64, height: 36, framesPerSecond: 30)
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 3 })
        source.resize(width: 80, height: 60)
        #expect(await eventually { sink.samples.contains { $0.width == 80 } })
        await source.stop()

        let samples = sink.samples
        let resized = try #require(samples.firstIndex { $0.width == 80 })
        #expect(samples[..<resized].allSatisfy { $0.width == 64 && $0.height == 36 })
        #expect(samples[resized...].allSatisfy { $0.width == 80 && $0.height == 60 })
        #expect(source.sourceInfo.globalFrame == Rect(x: 0, y: 0, width: 80, height: 60))
    }

    @Test func clockSkewShiftsAudioPTS() async throws {
        async let skewed = ptsAdvanceAfterOneSecond(clockSkewPPM: 2000)
        async let exact = ptsAdvanceAfterOneSecond(clockSkewPPM: 0)
        // 1 s of samples (48 000 frames) moves the PTS 1 s × (1 + 2000 / 1e6): ≈ 2 ms ahead.
        let (skewedAdvance, exactAdvance) = try await (skewed, exact)
        #expect(abs(skewedAdvance - 1.002) < 0.000_001)
        #expect(abs(exactAdvance - 1.0) < 0.000_001)
    }

    @Test func switchFormatChangesLaterAudioSamples() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.switchFormat")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticAudioSource(channels: 1)
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 3 })
        source.switchFormat(sampleRate: 44_100, channels: 2)
        #expect(await eventually { sink.samples.contains { $0.sampleRate == 44_100 } })
        await source.stop()

        let samples = sink.samples
        let switchIndex = try #require(samples.firstIndex { $0.sampleRate == 44_100 })
        #expect(samples[..<switchIndex].allSatisfy { $0.sampleRate == 48_000 && $0.channels == 1 && $0.frames == 480 })
        #expect(samples[switchIndex...].allSatisfy { $0.sampleRate == 44_100 && $0.channels == 2 && $0.frames == 441 })
        // The timeline continues: the first new block starts where the last old one ended.
        let gap = samples[switchIndex].pts.seconds(since: samples[switchIndex - 1].pts)
        #expect(abs(gap - 0.010) < 0.000_001)
    }

    @Test func pausedFramesKeepTheSourceRunning() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.pause")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 3 })

        source.pauseFrames(true)
        try await Task.sleep(for: .milliseconds(50))
        let paused = sink.samples.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.samples.count == paused)

        source.pauseFrames(false)
        #expect(await eventually { sink.samples.count > paused })
        await source.stop()
        #expect(sink.failures.isEmpty && source.startCount == 1)
    }

    @Test func stopWaitsForAnErrorBeingDelivered() async throws {
        let video = SyntheticVideoSource(width: 16, height: 16, framesPerSecond: 30)
        let audio = SyntheticAudioSource()
        let sources: [(any CaptureSource, @Sendable () -> Void)] = [
            (video, { video.failNow(domain: "Test", code: 1) }),
            (audio, { audio.failNow(domain: "Test", code: 1) }),
        ]
        for (source, failNow) in sources {
            let queue = DispatchSerialQueue(label: "test.synthetic.stopRace")
            let progress = SlowErrorSink.Progress()
            weak var released: SlowErrorSink?
            do {
                let sink = SlowErrorSink(progress: progress)
                released = sink
                try await source.start(on: queue, sink: sink)
                failNow()
            }
            #expect(await eventually { progress.state.withLock { $0.entered } })
            await source.stop()
            // stop() returned only after the error delivery finished and the sink was released.
            #expect(progress.state.withLock { $0.finished })
            #expect(released == nil)
        }
    }

    @Test func startWhileRunningReplacesRun() async throws {
        let firstQueue = DispatchSerialQueue(label: "test.synthetic.replace.1")
        let secondQueue = DispatchSerialQueue(label: "test.synthetic.replace.2")
        let first = RecordingSink(queue: firstQueue)
        let second = RecordingSink(queue: secondQueue)
        let source = SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30)
        try await source.start(on: firstQueue, sink: first)
        #expect(await eventually { first.samples.count >= 3 })

        try await source.start(on: secondQueue, sink: second)
        let firstCount = first.samples.count
        #expect(await eventually { second.samples.count >= 3 })
        try await Task.sleep(for: .milliseconds(150))
        // The old run's timer is gone: its sink gets nothing after the second start returned.
        #expect(first.samples.count == firstCount)
        await source.stop()

        #expect(first.failures.isEmpty && second.failures.isEmpty)
        #expect(source.startCount == 2)
        let lastOfFirst = try #require(first.samples.last?.pts)
        let firstOfSecond = try #require(second.samples.first?.pts)
        #expect(firstOfSecond > lastOfFirst)
    }

    @Test func restartNeverMovesPTSBackwards() async throws {
        // A clock that goes 1 s back on every read.
        let reads = Mutex(0)
        let backwards: @Sendable () -> HostTime = {
            let n = reads.withLock { n in
                defer { n += 1 }
                return n
            }
            return HostTime(nanoseconds: UInt64(1_000_000 - n) * 1_000_000_000)
        }
        let sources: [any CaptureSource] = [
            SyntheticVideoSource(width: 16, height: 16, framesPerSecond: 30, clock: backwards),
            SyntheticAudioSource(clock: backwards),
        ]
        for source in sources {
            let queue = DispatchSerialQueue(label: "test.synthetic.restartPTS")
            let sink = RecordingSink(queue: queue)
            for run in 1...2 {
                try await source.start(on: queue, sink: sink)
                #expect(await eventually { sink.samples.count >= 3 * run })
                await source.stop()
            }
            let pts = sink.samples.map(\.pts)
            #expect(pts.count >= 6)
            #expect(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 }, "\(source.trackID)")
        }
    }

    @Test func audioSampleRateBelow100HzIsRejected() async {
        await #expect(processExitsWith: .failure) {
            _ = SyntheticAudioSource(sampleRate: 50)
        }
        await #expect(processExitsWith: .failure) {
            SyntheticAudioSource().switchFormat(sampleRate: 99, channels: 1)
        }
    }

    /// How far the PTS of the block that starts after 48 000 frames is from the first PTS.
    private func ptsAdvanceAfterOneSecond(clockSkewPPM: Double) async throws -> Double {
        let queue = DispatchSerialQueue(label: "test.synthetic.skew.\(clockSkewPPM)")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticAudioSource(sampleRate: 48_000, channels: 1, clockSkewPPM: clockSkewPPM)
        try await source.start(on: queue, sink: sink)
        let delivered = await eventually(timeout: .seconds(5)) { sink.samples.count > 100 }
        await source.stop()
        try #require(delivered)
        let samples = sink.samples
        #expect(samples.prefix(100).allSatisfy { $0.frames == 480 })
        return samples[100].pts.seconds(since: samples[0].pts)
    }
}

/// Sets `SCStreamFrameInfo.status` on the first sample attachment, as ScreenCaptureKit does.
private func setFrameStatus(_ status: SCFrameStatus, on sample: CMSampleBuffer) {
    setFrameInfo(.status, status.rawValue as CFNumber, on: sample)
}

/// Sets `key` to `value` on the first sample attachment, as ScreenCaptureKit does.
private func setFrameInfo(_ key: SCStreamFrameInfo, _ value: CFTypeRef, on sample: CMSampleBuffer) {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    let key = key.rawValue as CFString
    CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
}

/// A sink whose error delivery takes 300 ms, to catch a `stop()` that does not wait for it.
final class SlowErrorSink: CaptureSink {
    final class Progress: Sendable {
        let state = Mutex((entered: false, finished: false))
    }

    let progress: Progress

    init(progress: Progress) {
        self.progress = progress
    }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {}

    func source(_ trackID: String, didStopWithError error: any Error) {
        progress.state.withLock { $0.entered = true }
        Thread.sleep(forTimeInterval: 0.3)
        progress.state.withLock { $0.finished = true }
    }
}
