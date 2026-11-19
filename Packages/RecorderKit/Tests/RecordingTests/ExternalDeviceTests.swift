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

        // The size is the one at the start: turning the device while it records does not change it.
        let queue = DispatchSerialQueue(label: "test.device.info")
        try await video.start(on: queue, sink: Sink(queue: queue))
        engine.setFormat(ExternalDeviceFormat(name: "iPhone", pixelSize: ExternalDeviceFormat.PixelSize(width: 2556, height: 1179)))
        #expect(video.sourceInfo == screen)
        await video.stop()

        // Not connected: its name is not known, nor its size.
        engine.setFormat(nil)
        #expect(video.sourceInfo == TrackSource(name: "iPhone or iPad", deviceUniqueID: "iphone-1"))
        #expect(audio.sourceInfo == TrackSource(name: "iPhone or iPad", deviceUniqueID: "iphone-1"))
        // A size the device does not tell: no frame.
        engine.setFormat(ExternalDeviceFormat(name: "iPad", pixelSize: nil))
        #expect(video.sourceInfo == TrackSource(name: "iPad", deviceUniqueID: "iphone-1"))
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
        var stopsRightAfterStarting = false
        var counts = Counts()
        var deliveries: [ExternalDeviceSession.Output: ExternalDeviceSession.Delivery] = [:]
        var onStop: (@Sendable (ExternalDeviceSession.StopCause) -> Void)?
    }

    private let state: Mutex<State>

    init(format: ExternalDeviceFormat?) {
        state = Mutex(State(format: format))
    }

    var counts: Counts { state.withLock { $0.counts } }

    func setFormat(_ format: ExternalDeviceFormat?) {
        state.withLock { $0.format = format }
    }

    func setStopsRightAfterStarting(_ stops: Bool) {
        state.withLock { $0.stopsRightAfterStarting = stops }
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

    /// What the capture tells when it stops by itself.
    func report(_ cause: ExternalDeviceSession.StopCause) {
        state.withLock { $0.onStop }?(cause)
    }

    // MARK: - ExternalDeviceEngine

    var isRunning: Bool { state.withLock { $0.running } }
    var clock: CMClock? { nil }

    func setOnStop(_ handler: @escaping @Sendable (ExternalDeviceSession.StopCause) -> Void) {
        state.withLock { $0.onStop = handler }
    }

    func describe() -> ExternalDeviceFormat? {
        state.withLock { $0.connected ? $0.format : nil }
    }

    func prepare(for output: ExternalDeviceSession.Output) throws -> ExternalDeviceFormat {
        try state.withLock { state in
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
            return state.running ? nil : .interrupted
        }
    }
}
