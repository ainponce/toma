// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CoreMedia
import Dispatch
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

/// An iPhone or iPad connected by cable, without one: which devices are screens, which one a restart takes, when the
/// shared session runs and what ends a run, over a fake capture. Screen-capture devices are never allowed here
/// (`kCMIOHardwarePropertyAllowScreenCaptureDevices`): recording a real device is an owner check.
@Suite struct ExternalDeviceTests {
    private static let iPhone = ExternalDeviceFormat(
        name: "iPhone", pixelSize: ExternalDeviceFormat.PixelSize(width: 1179, height: 2556))

    // MARK: - Catalog

    @Test func onlyExternalMuxedDevicesAreScreens() {
        #expect(ExternalDeviceCatalog.isScreenDevice(type: .external, hasMuxed: true))
        // A USB camera: external, but only video.
        #expect(!ExternalDeviceCatalog.isScreenDevice(type: .external, hasMuxed: false))
        // An iPhone used as the Mac's camera is not its screen.
        #expect(!ExternalDeviceCatalog.isScreenDevice(type: .continuityCamera, hasMuxed: true))
        #expect(!ExternalDeviceCatalog.isScreenDevice(type: .builtInWideAngleCamera, hasMuxed: false))
    }

    @Test func cameraListLeavesOutScreenDevices() {
        // Once the iPhone mode allows screen devices, an iPhone's screen is an external device too: never a camera.
        #expect(!CameraCatalog.isCamera(hasMuxed: true))
        #expect(CameraCatalog.isCamera(hasMuxed: false))
        #expect(CameraCatalog.discover().allSatisfy { !$0.device.hasMediaType(.muxed) })
    }

    @Test func aRestartFindsOnlyTheSameDevice() throws {
        let mine = ExternalDeviceInfo(uniqueID: "iphone-1", name: "iPhone", modelID: "iPhone15,2")
        let other = ExternalDeviceInfo(uniqueID: "iphone-2", name: "Another iPhone", modelID: "iPhone16,1")
        #expect(try ExternalDeviceCatalog.pick("iphone-1", among: [(other, "other"), (mine, "mine")]) == "mine")
        // Another iPhone connected when it comes back is not taken instead.
        #expect(throws: CaptureSourceError.deviceNotFound(uniqueID: "iphone-1")) {
            try ExternalDeviceCatalog.pick("iphone-1", among: [(other, "other")])
        }
        #expect(throws: CaptureSourceError.deviceNotFound(uniqueID: "not-connected")) {
            try ExternalDeviceCatalog.resolve("not-connected")
        }
    }

    @Test func allowingScreenDevicesTwiceIsOnce() {
        let calls = Atomic(0)
        let setting = OneTimeSetting {
            calls.add(1, ordering: .relaxed)
            return true
        }
        #expect(setting.apply() && setting.apply())
        #expect(calls.load(ordering: .relaxed) == 1)
        // One that failed is tried again, until it holds.
        let tries = Atomic(0)
        let flaky = OneTimeSetting { tries.add(1, ordering: .relaxed).newValue > 1 }
        #expect(!flaky.apply())
        #expect(flaky.apply() && flaky.apply())
        #expect(tries.load(ordering: .relaxed) == 2)
    }

    @Test @MainActor func allowingFromTheMainActorMakesItOffIt() async {
        let calls = Atomic(0)
        let onMain = Atomic(false)
        let gate = DispatchSemaphore(value: 0)
        let setting = OneTimeSetting {
            if Thread.isMainThread { onMain.store(true, ordering: .relaxed) }
            calls.add(1, ordering: .relaxed)
            // CoreMediaIO takes its time. Never for ever, even if this were the main thread.
            _ = gate.wait(timeout: .now() + 5)
            return true
        }
        // The iPhone mode opens, twice in a row: the main actor goes on while it is made, and it is made once.
        let first = Task { await setting.apply() }
        let second = Task { await setting.apply() }
        #expect(await eventually { calls.load(ordering: .relaxed) == 1 })
        gate.signal()
        let applied = (await first.value, await second.value)
        #expect(applied == (true, true))
        #expect(await setting.apply())
        #expect(calls.load(ordering: .relaxed) == 1 && !onMain.load(ordering: .relaxed))

        // One that failed is tried again, until it holds; the session's queue waits for it the same way.
        let tries = Atomic(0)
        let flaky = OneTimeSetting { tries.add(1, ordering: .relaxed).newValue > 1 }
        #expect(!(await flaky.apply()))
        #expect(await Task.detached { flaky.apply() }.value)
        #expect(await flaky.apply())
        #expect(tries.load(ordering: .relaxed) == 2)
    }

    // MARK: - Policy and errors

    @Test func deviceTracksKeepRetrying() {
        // The device's screen is the take's only screen; its sound comes back with it.
        #expect(RestartPolicy.keepsRetrying(kind: .device, isSoleScreen: true))
        #expect(RestartPolicy.keepsRetrying(kind: .deviceAudio, isSoleScreen: false))
    }

    @Test func stopErrorsByCause() {
        #expect(ExternalDeviceSession.stopError(for: .disconnected) as? CaptureSourceError == .deviceDisconnected)
        #expect(ExternalDeviceSession.stopError(for: .interrupted) as? CaptureSourceError == .deviceInterrupted)
        #expect(ExternalDeviceSession.stopError(for: .stoppedRunning) as? CaptureSourceError == .deviceInterrupted)
        let runtime = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.deviceWasDisconnected.rawValue)
        #expect(ExternalDeviceSession.stopError(for: .failed(runtime)) as NSError == runtime)
    }

    // MARK: - Sources

    @Test func sourcesIdentifyTheirTracks() {
        let video = ExternalDeviceCaptureSource(deviceUniqueID: "iphone-1")
        #expect(video.trackID == "device" && video.kind == .device && video.media == .video(framesPerSecond: 60))
        let audio = ExternalDeviceAudioSource(video: video)
        #expect(audio.trackID == "deviceAudio" && audio.kind == .deviceAudio && audio.media == .audio)
        #expect(audio.session === video.session)
        #expect(video.activeDeviceUniqueID == nil && audio.activeDeviceUniqueID == nil)
        #expect(ExternalDeviceCaptureSource(deviceUniqueID: "iphone-1", framesPerSecond: 30).media == .video(framesPerSecond: 30))
    }

    @Test func sourceInfoHasThePixelSizeAtScale1() async throws {
        let screen = TrackSource(
            name: "iPhone", deviceUniqueID: "iphone-1", globalFrame: Rect(x: 0, y: 0, width: 1179, height: 2556), pixelScale: 1)
        #expect(Self.iPhone.trackSource(uniqueID: "iphone-1") == screen)

        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let audio = ExternalDeviceAudioSource(video: video)
        #expect(video.sourceInfo == screen)
        #expect(audio.sourceInfo == TrackSource(name: "iPhone", deviceUniqueID: "iphone-1"))
        // A take asks four times as it starts: the device is looked for once.
        #expect(video.sourceInfo == screen && audio.sourceInfo.name == "iPhone")
        #expect(engine.describes == 1)

        // Turned after the take asked and before its first run: the size is the one that run starts with, the size of
        // the first segment.
        let landscape = ExternalDeviceFormat(name: "iPhone", pixelSize: ExternalDeviceFormat.PixelSize(width: 2556, height: 1179))
        engine.setFormat(landscape)
        let queue = DispatchSerialQueue(label: "test.device.info")
        try await video.start(on: queue, sink: Sink(queue: queue))
        #expect(video.sourceInfo == landscape.trackSource(uniqueID: "iphone-1"))
        // Turning it again while it records, or after a restart, does not change it.
        engine.setFormat(Self.iPhone)
        #expect(video.sourceInfo == landscape.trackSource(uniqueID: "iphone-1"))
        try await video.start(on: queue, sink: Sink(queue: queue))
        await video.stop()
        #expect(video.sourceInfo == landscape.trackSource(uniqueID: "iphone-1"))
        #expect(engine.describes == 1)

        // Not connected when asked: its name is not known, nor its size, and it is looked for again next time.
        let away = FakeEngine(format: nil)
        let awayVideo = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: away))
        #expect(awayVideo.sourceInfo == TrackSource(name: "iPhone or iPad", deviceUniqueID: "iphone-1"))
        #expect(ExternalDeviceAudioSource(video: awayVideo).sourceInfo == TrackSource(name: "iPhone or iPad", deviceUniqueID: "iphone-1"))
        // A device that does not tell its size before it captures: no frame until its first run.
        away.setFormat(Self.iPhone)
        away.setTellsSizeBeforeCapturing(false)
        #expect(awayVideo.sourceInfo == TrackSource(name: "iPhone", deviceUniqueID: "iphone-1"))
        try await awayVideo.start(on: queue, sink: Sink(queue: queue))
        #expect(awayVideo.sourceInfo == screen)
        await awayVideo.stop()
    }

    @Test func theTrackHasTheSizeItsFirstRunStartedWith() async throws {
        // The take writes its tracks before any run starts: the device turned right after, or did not tell its size
        // yet. Once the screen's run has started, its track has the size of the first segment.
        try await withTemporaryDirectory { directory in
            let portrait = ExternalDeviceFormat(name: "iPhone", pixelSize: ExternalDeviceFormat.PixelSize(width: 390, height: 844))
            let landscape = ExternalDeviceFormat(name: "iPhone", pixelSize: ExternalDeviceFormat.PixelSize(width: 844, height: 390))
            let engine = FakeEngine(format: portrait)
            engine.setTurnsAfterDescribing(to: landscape)
            let video = ExternalDeviceCaptureSource(
                session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine), framesPerSecond: 30)
            let rig = try Rig(in: directory, sources: [video])
            let id = try await rig.coordinator.start()
            await engine.deliverFrames(width: 844, height: 390, count: 10)
            _ = try await rig.coordinator.stop()

            let track = try #require(try rig.takeOnDisk(id).track("device"))
            #expect(track.source == landscape.trackSource(uniqueID: "iphone-1"))
            try #require(track.segments.count == 1)
            #expect(try await rig.videoSize(of: track.segments[0]) == CGSize(width: 844, height: 390))
        }
    }

    @Test func sessionRunsWhileEitherSourceRuns() async throws {
        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let audio = ExternalDeviceAudioSource(video: video)
        let videoQueue = DispatchSerialQueue(label: "test.device.video")
        let audioQueue = DispatchSerialQueue(label: "test.device.audio")
        let videoSink = Sink(queue: videoQueue)
        let audioSink = Sink(queue: audioQueue)

        try await video.start(on: videoQueue, sink: videoSink)
        #expect(engine.counts == FakeEngine.Counts(starts: 1, stops: 0) && engine.isRunning)
        #expect(video.activeDeviceUniqueID == "iphone-1")
        try await audio.start(on: audioQueue, sink: audioSink)
        // The audio shares the running session.
        #expect(engine.counts == FakeEngine.Counts(starts: 1, stops: 0))
        #expect(audio.activeDeviceUniqueID == "iphone-1")

        // Each output goes to its own source, on its own queue, on the host clock.
        let pts = HostTime(nanoseconds: 7_000_000_000)
        #expect(engine.deliver(SampleFactory.videoSample(width: 32, height: 64, pts: pts, frameIndex: 0), to: .video))
        #expect(engine.deliver(SampleFactory.audioSample(pts: pts, frames: 480, sampleRate: 48_000, channels: 2), to: .audio))
        #expect(await eventually { videoSink.pts == [pts] && audioSink.pts == [pts] })

        await video.stop()
        #expect(engine.isRunning && engine.counts.stops == 0)
        #expect(!engine.deliver(SampleFactory.videoSample(width: 32, height: 64, pts: pts, frameIndex: 1), to: .video))
        #expect(video.activeDeviceUniqueID == nil)
        await audio.stop()
        #expect(!engine.isRunning && engine.counts == FakeEngine.Counts(starts: 1, stops: 1))
        #expect(videoSink.errors.isEmpty && audioSink.errors.isEmpty)

        // Again, audio first.
        try await audio.start(on: audioQueue, sink: audioSink)
        try await video.start(on: videoQueue, sink: videoSink)
        await audio.stop()
        #expect(engine.isRunning)
        await video.stop()
        #expect(!engine.isRunning && engine.counts == FakeEngine.Counts(starts: 2, stops: 2))
    }

    @Test func aDisconnectEndsBothRunsAndOnlyTheSameDeviceComesBack() async throws {
        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let audio = ExternalDeviceAudioSource(video: video)
        let videoQueue = DispatchSerialQueue(label: "test.device.video")
        let audioQueue = DispatchSerialQueue(label: "test.device.audio")
        let videoSink = Sink(queue: videoQueue)
        let audioSink = Sink(queue: audioQueue)
        try await video.start(on: videoQueue, sink: videoSink)
        try await audio.start(on: audioQueue, sink: audioSink)

        engine.disconnect()
        #expect(await eventually { videoSink.errors == [.deviceDisconnected] && audioSink.errors == [.deviceDisconnected] })
        // Both runs let go of the session: it stopped.
        #expect(await eventually { !engine.isRunning })
        #expect(video.activeDeviceUniqueID == "iphone-1")  // kept after an error

        // A restart while it is away does not start anything.
        await #expect(throws: CaptureSourceError.deviceNotFound(uniqueID: "iphone-1")) {
            try await video.start(on: videoQueue, sink: videoSink)
        }
        #expect(!engine.isRunning && engine.counts.starts == 1)

        engine.reconnect()
        try await video.start(on: videoQueue, sink: videoSink)
        try await audio.start(on: audioQueue, sink: audioSink)
        #expect(engine.isRunning && engine.counts.starts == 2)
        await video.stop()
        await audio.stop()
        #expect(!engine.isRunning)
        #expect(videoSink.errors == [.deviceDisconnected] && audioSink.errors == [.deviceDisconnected])
    }

    @Test func aStopFromBeforeTheSessionRanAgainEndsNothing() async throws {
        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let queue = DispatchSerialQueue(label: "test.device.video")
        let sink = Sink(queue: queue)
        try await video.start(on: queue, sink: sink)
        // The notice of the last run's stop arrives late, with the session running again: the run goes on, and the
        // frame handed over after it gets there.
        engine.report(.stoppedRunning)
        let pts = HostTime(nanoseconds: 3_000_000_000)
        #expect(engine.deliver(SampleFactory.videoSample(width: 32, height: 64, pts: pts, frameIndex: 0), to: .video))
        #expect(await eventually { sink.pts == [pts] })
        #expect(sink.errors.isEmpty)
        // An interruption now ends it.
        engine.report(.interrupted)
        #expect(await eventually { sink.errors == [.deviceInterrupted] })
        await video.stop()
    }

    @Test func anInterruptedCaptureGivesNoSamplesEvenRunning() {
        // AVFoundation on macOS has no `isInterrupted`, and a session may still say it runs while it is interrupted.
        #expect(CaptureSessionEngine.stopCause(disconnected: false, interrupted: true, running: true) == .interrupted)
        #expect(CaptureSessionEngine.stopCause(disconnected: false, interrupted: true, running: false) == .interrupted)
        #expect(CaptureSessionEngine.stopCause(disconnected: true, interrupted: true, running: true) == .disconnected)
        #expect(CaptureSessionEngine.stopCause(disconnected: false, interrupted: false, running: false) == .stoppedRunning)
        #expect(CaptureSessionEngine.stopCause(disconnected: false, interrupted: false, running: true) == nil)
    }

    @Test func anInterruptedCaptureStartsNoRunUntilItEnds() async throws {
        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let audio = ExternalDeviceAudioSource(video: video)
        let videoQueue = DispatchSerialQueue(label: "test.device.video")
        let audioQueue = DispatchSerialQueue(label: "test.device.audio")
        let videoSink = Sink(queue: videoQueue)
        let audioSink = Sink(queue: audioQueue)
        try await video.start(on: videoQueue, sink: videoSink)
        try await audio.start(on: audioQueue, sink: audioSink)

        engine.interrupt()
        #expect(await eventually { videoSink.errors == [.deviceInterrupted] && audioSink.errors == [.deviceInterrupted] })
        // The restart policy tries again at once: while the interruption lasts, no run starts and the session is not
        // touched, so the policy waits and tries again, as after any other stop.
        let prepares = engine.prepares
        await #expect(throws: CaptureSourceError.deviceInterrupted) {
            try await video.start(on: videoQueue, sink: videoSink)
        }
        await #expect(throws: CaptureSourceError.deviceInterrupted) {
            try await audio.start(on: audioQueue, sink: audioSink)
        }
        #expect(engine.prepares == prepares && !engine.isRunning)

        // Once it ends, both come back, on the same session.
        engine.endInterruption()
        try await video.start(on: videoQueue, sink: videoSink)
        try await audio.start(on: audioQueue, sink: audioSink)
        #expect(engine.isRunning && engine.counts == FakeEngine.Counts(starts: 2, stops: 1))
        let pts = HostTime(nanoseconds: 9_000_000_000)
        #expect(engine.deliver(SampleFactory.videoSample(width: 32, height: 64, pts: pts, frameIndex: 0), to: .video))
        #expect(await eventually { videoSink.pts == [pts] })
        await video.stop()
        await audio.stop()
        #expect(videoSink.errors == [.deviceInterrupted] && audioSink.errors == [.deviceInterrupted])
    }

    @Test func aRestartDoesNotShareAnInterruptedSession() async throws {
        // The interruption has come, but its notice has not reached the runs yet: the session still says it runs, and
        // the sound's run still holds it. A restart of the screen would share a session that gives nothing.
        let engine = FakeEngine(format: Self.iPhone)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let audio = ExternalDeviceAudioSource(video: video)
        let videoQueue = DispatchSerialQueue(label: "test.device.video")
        let audioQueue = DispatchSerialQueue(label: "test.device.audio")
        let videoSink = Sink(queue: videoQueue)
        try await video.start(on: videoQueue, sink: videoSink)
        try await audio.start(on: audioQueue, sink: Sink(queue: audioQueue))

        engine.interrupt(notifying: false)
        let prepares = engine.prepares
        await #expect(throws: CaptureSourceError.deviceInterrupted) {
            try await video.start(on: videoQueue, sink: videoSink)
        }
        #expect(engine.prepares == prepares && engine.isRunning)

        engine.endInterruption()
        try await video.start(on: videoQueue, sink: videoSink)
        #expect(video.activeDeviceUniqueID == "iphone-1" && engine.counts == FakeEngine.Counts(starts: 1, stops: 0))
        await video.stop()
        await audio.stop()
        #expect(!engine.isRunning)
    }

    @Test func aStartThatFindsTheSessionStoppedFails() async throws {
        // What ended the capture before the run could hear it.
        let engine = FakeEngine(format: Self.iPhone)
        engine.setStopsRightAfterStarting(true)
        let video = ExternalDeviceCaptureSource(session: ExternalDeviceSession(deviceUniqueID: "iphone-1", engine: engine))
        let queue = DispatchSerialQueue(label: "test.device.video")
        await #expect(throws: CaptureSourceError.deviceInterrupted) {
            try await video.start(on: queue, sink: Sink(queue: queue))
        }
        await video.stop()
        #expect(engine.counts.stops == 1)
    }
}

/// Counts what reaches it, on its queue.
private final class Sink: CaptureSink {
    let queue: DispatchSerialQueue
    private let log = Mutex<(pts: [HostTime], errors: [CaptureSourceError])>(([], []))

    init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    var pts: [HostTime] { log.withLock { $0.pts } }
    var errors: [CaptureSourceError] { log.withLock { $0.errors } }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        let pts = HostTime(sample.presentationTimeStamp)
        log.withLock { $0.pts.append(pts) }
    }

    func source(_ trackID: String, didStopWithError error: any Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        log.withLock { $0.errors.append(error as? CaptureSourceError ?? .sessionConfigurationFailed) }
    }
}

/// A capture that runs when it is prepared, delivers what a test hands it, and stops by itself when a test says so.
private final class FakeEngine: ExternalDeviceEngine {
    struct Counts: Equatable {
        var starts = 0
        var stops = 0
    }

    private struct State {
        var format: ExternalDeviceFormat?
        var connected = true
        var running = false
        var interrupted = false
        var stopsRightAfterStarting = false
        var tellsSizeBeforeCapturing = true
        var turnsAfterDescribing: ExternalDeviceFormat?
        var counts = Counts()
        var prepares = 0
        var describes = 0
        var deliveries: [ExternalDeviceSession.Output: ExternalDeviceSession.Delivery] = [:]
        var onStop: (@Sendable (ExternalDeviceSession.StopCause) -> Void)?
    }

    private let state: Mutex<State>

    init(format: ExternalDeviceFormat?) {
        state = Mutex(State(format: format))
    }

    var counts: Counts { state.withLock { $0.counts } }
    /// How many times a lease asked it to capture.
    var prepares: Int { state.withLock { $0.prepares } }
    /// How many times it was asked to describe the device.
    var describes: Int { state.withLock { $0.describes } }

    func setFormat(_ format: ExternalDeviceFormat?) {
        state.withLock { $0.format = format }
    }

    func setStopsRightAfterStarting(_ stops: Bool) {
        state.withLock { $0.stopsRightAfterStarting = stops }
    }

    /// `false`: like a muxed device, its size is known only once it captures.
    func setTellsSizeBeforeCapturing(_ tells: Bool) {
        state.withLock { $0.tellsSizeBeforeCapturing = tells }
    }

    /// Right after the next description, the device turns to `format`.
    func setTurnsAfterDescribing(to format: ExternalDeviceFormat) {
        state.withLock { $0.turnsAfterDescribing = format }
    }

    /// `count` frames of `width` × `height` to the screen's source, one every 33 ms, at the host time they are made.
    func deliverFrames(width: Int, height: Int, count: Int) async {
        for index in 0..<count {
            _ = deliver(SampleFactory.videoSample(width: width, height: height, pts: HostTime.now(), frameIndex: index), to: .video)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    /// Hands `sample` to the source of `output`, on its queue; `false` if no source has it.
    func deliver(_ sample: CMSampleBuffer, to output: ExternalDeviceSession.Output) -> Bool {
        guard let delivery = state.withLock({ $0.deliveries[output] }) else { return false }
        nonisolated(unsafe) let unsafeSample = sample
        delivery.queue.async { delivery.receive(unsafeSample) }
        return true
    }

    func disconnect() {
        state.withLock { $0.connected = false }
        report(.disconnected)
    }

    func reconnect() {
        state.withLock { $0.connected = true }
    }

    /// Interrupted, still saying it runs (as an `AVCaptureSession` may); `notifying`, the runs are told.
    func interrupt(notifying: Bool = true) {
        state.withLock { $0.interrupted = true }
        if notifying { report(.interrupted) }
    }

    func endInterruption() {
        state.withLock { $0.interrupted = false }
    }

    /// What the capture tells when it stops by itself.
    func report(_ cause: ExternalDeviceSession.StopCause) {
        state.withLock { $0.onStop }?(cause)
    }

    // MARK: - ExternalDeviceEngine

    var isRunning: Bool { state.withLock { $0.running } }
    var isInterrupted: Bool { state.withLock { $0.interrupted } }
    var clock: CMClock? { nil }

    func setOnStop(_ handler: @escaping @Sendable (ExternalDeviceSession.StopCause) -> Void) {
        state.withLock { $0.onStop = handler }
    }

    func describe() -> ExternalDeviceFormat? {
        state.withLock { state in
            state.describes += 1
            guard state.connected, var format = state.format else { return nil }
            if let turned = state.turnsAfterDescribing {
                state.format = turned
                state.turnsAfterDescribing = nil
            }
            if !state.tellsSizeBeforeCapturing { format.pixelSize = nil }
            return format
        }
    }

    func prepare(for output: ExternalDeviceSession.Output) throws -> ExternalDeviceFormat {
        try state.withLock { state in
            state.prepares += 1
            guard state.connected, let format = state.format else { throw CaptureSourceError.deviceNotFound(uniqueID: "iphone-1") }
            if !state.running {
                state.counts.starts += 1
                state.running = !state.stopsRightAfterStarting
            }
            return format
        }
    }

    func setDelivery(_ delivery: ExternalDeviceSession.Delivery?, for output: ExternalDeviceSession.Output) {
        state.withLock { $0.deliveries[output] = delivery }
    }

    func stop() {
        state.withLock { state in
            state.counts.stops += 1
            state.running = false
        }
    }

    func currentStopCause() -> ExternalDeviceSession.StopCause? {
        state.withLock { state in
            if !state.connected { return .disconnected }
            if state.interrupted { return .interrupted }
            return state.running ? nil : .stoppedRunning
        }
    }
}
