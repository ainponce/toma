// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import ProjectFormat
import SyntheticCapture
import Testing

@testable import Recording

/// The camera's rules that need no camera: which format, which device, when the shared session runs, and what
/// ends a run. Capturing a real camera is `CaptureIntegrationTests.capturesDefaultCameraForTwoSeconds`.
@Suite struct CameraTests {
    // MARK: - Format

    @Test func formatChoicePicksSmallestFormatCoveringPresetAtRate() {
        let f = [fmt(640, 480, 30), fmt(1920, 1080, 30, v420: false), fmt(1920, 1080, 30), fmt(3840, 2160, 30)]
        #expect(CameraFormatChoice.best(among: f, preset: .p1080, framesPerSecond: 30) == 2)
    }

    @Test func formatChoiceFallsBackToTheLargestBelowThePreset() {
        let f = [fmt(640, 480, 30), fmt(1280, 720, 30)]
        #expect(CameraFormatChoice.best(among: f, preset: .p1080, framesPerSecond: 30) == 1)
    }

    @Test func formatChoiceNeedsTheRate() {
        #expect(CameraFormatChoice.best(among: [fmt(1920, 1080, 30)], preset: .p1080, framesPerSecond: 60) == nil)
        #expect(CameraFormatChoice.best(among: [], preset: .p720, framesPerSecond: 30) == nil)
    }

    @Test func formatChoiceSkipsFormatsTooSlowForTheRate() {
        // The 4K format only reaches 15 fps: at 30 the 1080p one is the best there is.
        let f = [fmt(3840, 2160, 15), fmt(1920, 1080, 30), fmt(1280, 720, 60)]
        #expect(CameraFormatChoice.best(among: f, preset: .p2160, framesPerSecond: 30) == 1)
        #expect(CameraFormatChoice.best(among: f, preset: .p2160, framesPerSecond: 15) == 0)
        // A camera that says 29.97 gives 30.
        #expect(CameraFormatChoice.best(among: [fmt(1280, 720, 29.97)], preset: .p720, framesPerSecond: 30) == 0)
    }

    @Test func presetsAreTheirSizes() {
        #expect(CameraPreset.allCases.map { [$0.width, $0.height] } == [[1280, 720], [1920, 1080], [3840, 2160]])
    }

    @Test func frameDurationStaysInsideTheSupportedRanges() {
        let thirty = CMTime(value: 1, timescale: 30)
        let sixty = CMTime(value: 1, timescale: 60)
        let ntsc = CMTime(value: 1001, timescale: 30_000)
        let second = CMTime(value: 1, timescale: 1)
        let fixed30 = CameraFormatChoice.RateRange(minRate: 30, maxRate: 30, minDuration: thirty, maxDuration: thirty)
        let upTo60 = CameraFormatChoice.RateRange(minRate: 1, maxRate: 60, minDuration: sixty, maxDuration: second)
        let upToNTSC = CameraFormatChoice.RateRange(minRate: 1, maxRate: 29.97, minDuration: ntsc, maxDuration: second)
        let fixed60 = CameraFormatChoice.RateRange(minRate: 60, maxRate: 60, minDuration: sixty, maxDuration: sixty)
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: [fixed30]) == thirty)
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: [upTo60]) == thirty)
        // Asked for more than a range gives, or less than a fixed rate: the range's own end, never a value outside it.
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: [upToNTSC]) == ntsc)
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: [fixed60]) == sixty)
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: [fixed60, upToNTSC]) == ntsc)
        #expect(CameraFormatChoice.frameDuration(framesPerSecond: 30, ranges: []) == nil)
    }

    @Test func deviceStepsChangeOnlyWhatDiffers() {
        let thirty = CMTime(value: 1, timescale: 30)
        let current = CameraFormatChoice.DeviceSettings(
            formatIndex: 2, minFrameDuration: thirty, maxFrameDuration: thirty, autoFrameRateEnabled: false)
        #expect(CameraFormatChoice.steps(from: current, format: 2, frameDuration: thirty) == [])
        // The same duration in another timescale is no change.
        #expect(CameraFormatChoice.steps(from: current, format: 2, frameDuration: CMTime(value: 2, timescale: 60)) == [])
        // Another format: the rate is set again after it.
        #expect(CameraFormatChoice.steps(from: current, format: 3, frameDuration: thirty) == [.setFormat(3), .setFrameDuration(thirty)])
        var unknown = current
        unknown.formatIndex = nil
        #expect(CameraFormatChoice.steps(from: unknown, format: 2, frameDuration: thirty) == [.setFormat(2), .setFrameDuration(thirty)])
        // The session (or another app) changed the rate: only the rate.
        var faster = current
        faster.minFrameDuration = CMTime(value: 1, timescale: 60)
        #expect(CameraFormatChoice.steps(from: faster, format: 2, frameDuration: thirty) == [.setFrameDuration(thirty)])
        var slower = current
        slower.maxFrameDuration = CMTime(value: 1, timescale: 15)
        #expect(CameraFormatChoice.steps(from: slower, format: 2, frameDuration: thirty) == [.setFrameDuration(thirty)])
    }

    @Test func autoFrameRateIsTurnedOffBeforeTheRateIsPinned() {
        let thirty = CMTime(value: 1, timescale: 30)
        let automatic = CameraFormatChoice.DeviceSettings(
            formatIndex: 2, minFrameDuration: thirty, maxFrameDuration: thirty, autoFrameRateEnabled: true)
        // Setting a frame duration with it on raises an exception: off first, then the rate, even if it reads the same.
        #expect(CameraFormatChoice.steps(from: automatic, format: 2, frameDuration: thirty) == [.disableAutoFrameRate, .setFrameDuration(thirty)])
        // A new format turns it off by itself.
        #expect(CameraFormatChoice.steps(from: automatic, format: 0, frameDuration: thirty) == [.setFormat(0), .setFrameDuration(thirty)])
    }

    @Test func targetIsTheBestFormatAtAFrameDurationItSupports() {
        let thirty = CMTime(value: 1, timescale: 30)
        let ntsc = CMTime(value: 1001, timescale: 30_000)
        let second = CMTime(value: 1, timescale: 1)
        let formats = [fmt(1280, 720, 30), fmt(1920, 1080, 29.97)]
        let ranges = [
            [CameraFormatChoice.RateRange(minRate: 1, maxRate: 30, minDuration: thirty, maxDuration: second)],
            [CameraFormatChoice.RateRange(minRate: 1, maxRate: 29.97, minDuration: ntsc, maxDuration: second)],
        ]
        #expect(CameraFormatChoice.target(formats: formats, rateRanges: ranges, preset: .p1080, framesPerSecond: 30)
            == CameraFormatChoice.Target(format: 1, frameDuration: ntsc))
        #expect(CameraFormatChoice.target(formats: formats, rateRanges: ranges, preset: .p720, framesPerSecond: 30)
            == CameraFormatChoice.Target(format: 0, frameDuration: thirty))
        #expect(CameraFormatChoice.target(formats: formats, rateRanges: ranges, preset: .p720, framesPerSecond: 60) == nil)
    }

    // MARK: - Shared session

    @Test func sessionStartsWithTheFirstLeaseAndStopsWithTheLast() {
        var counter = CameraLeaseCounter()
        #expect(counter.acquire() == true)
        #expect(counter.acquire() == false)
        #expect(counter.release() == false)
        #expect(counter.release() == true)
        // A release with no lease left changes nothing.
        #expect(counter.release() == false)
        #expect(counter == CameraLeaseCounter())
    }

    @Test func aRecordingLeasePinsTheSession() {
        // While a take records, a new lease shares the session as it is, whatever it asks for, even with no camera
        // to pick: the capture never changes in the middle of a take.
        let pinned = snapshot(pinned: true)
        for pick in [Result<String, CaptureSourceError>.success("usb-1"), .success("builtin"), .failure(.cameraNotFound)] {
            #expect(CameraLeaseRules.plan(pinned, pick: pick, preset: .p720, framesPerSecond: 60)
                == .success(CameraLeasePlan(camera: .share, startsSession: false)))
        }
        // Pinned with no input to share (it cannot happen) is configured like any other.
        var empty = snapshot(pinned: true)
        empty.inputDeviceUniqueID = nil
        #expect(CameraLeaseRules.plan(empty, pick: .success("builtin"), preset: .p1080, framesPerSecond: 30)
            == .success(CameraLeasePlan(camera: .configure(configuration("builtin")), startsSession: false)))
    }

    @Test func anUnchangedSessionIsKept() {
        #expect(CameraLeaseRules.plan(snapshot(), pick: .success("builtin"), preset: .p1080, framesPerSecond: 30)
            == .success(CameraLeasePlan(camera: .keep, startsSession: false)))
    }

    @Test func anyChangeReconfiguresTheSession() {
        let session = snapshot()
        let reconfigured = { (pick: String, preset: CameraPreset, fps: Int) in
            CameraLeaseRules.plan(session, pick: .success(pick), preset: preset, framesPerSecond: fps)
                == .success(CameraLeasePlan(camera: .configure(configuration(pick, preset, fps)), startsSession: false))
        }
        #expect(reconfigured("usb-1", .p1080, 30))  // another camera
        #expect(reconfigured("builtin", .p720, 30))  // another quality
        #expect(reconfigured("builtin", .p1080, 60))  // another rate
        // The same request, but the session cannot be trusted to have it.
        var disconnected = session
        disconnected.inputConnected = false
        var drifted = session
        drifted.deviceMatchesConfiguration = false
        var unknown = session
        unknown.configuration = nil
        var noInput = session
        noInput.inputDeviceUniqueID = nil
        for changed in [disconnected, drifted, unknown, noInput] {
            #expect(CameraLeaseRules.plan(changed, pick: .success("builtin"), preset: .p1080, framesPerSecond: 30)
                == .success(CameraLeasePlan(camera: .configure(configuration("builtin")), startsSession: false)))
        }
    }

    @Test func withoutACameraToPickTheLeaseFails() {
        for error in [CaptureSourceError.cameraNotFound, .cameraInterrupted] {
            #expect(CameraLeaseRules.plan(snapshot(), pick: .failure(error), preset: .p1080, framesPerSecond: 30) == .failure(error))
        }
    }

    @Test func aStoppedSessionIsStarted() {
        // The first lease starts it; a later one finds it running, unless it stopped by itself (an error, an
        // interruption): then it starts it again, also when it only shares it.
        var first = snapshot(running: false)
        first.isFirstLease = true
        first.configuration = nil
        #expect(CameraLeaseRules.plan(first, pick: .success("builtin"), preset: .p1080, framesPerSecond: 30)
            == .success(CameraLeasePlan(camera: .configure(configuration("builtin")), startsSession: true)))
        #expect(CameraLeaseRules.plan(snapshot(running: false), pick: .success("builtin"), preset: .p1080, framesPerSecond: 30)
            == .success(CameraLeasePlan(camera: .keep, startsSession: true)))
        #expect(CameraLeaseRules.plan(snapshot(pinned: true, running: false), pick: .success("usb-1"), preset: .p1080, framesPerSecond: 30)
            == .success(CameraLeasePlan(camera: .share, startsSession: true)))
    }

    // MARK: - Device

    @Test func pickFallsBackToSystemPreferred() {
        let builtIn = CameraDeviceInfo(uniqueID: "builtin", name: "FaceTime HD Camera", isContinuity: false, isSystemPreferred: false)
        let continuity = CameraDeviceInfo(uniqueID: "iphone", name: "iPhone Camera", isContinuity: true, isSystemPreferred: true)
        let usb = CameraDeviceInfo(uniqueID: "usb-1", name: "USB Camera", isContinuity: false, isSystemPreferred: false)
        #expect(CameraCatalog.pick(preferred: "usb-1", among: [builtIn, continuity]) == "iphone")
        #expect(CameraCatalog.pick(preferred: nil, among: [builtIn, continuity]) == "iphone")
        var unpreferred = continuity
        unpreferred.isSystemPreferred = false
        #expect(CameraCatalog.pick(preferred: "usb-1", among: [builtIn, unpreferred]) == "builtin")
        #expect(CameraCatalog.pick(preferred: "usb-1", among: [builtIn, continuity, usb]) == "usb-1")
    }

    @Test func pickWithoutCamerasIsNil() {
        #expect(CameraCatalog.pick(preferred: "x", among: []) == nil)
        #expect(CameraCatalog.pick(preferred: nil, among: []) == nil)
    }

    @Test func suspendedCamerasAreSkippedAndAllSuspendedIsAnInterruption() throws {
        let builtIn = CameraDeviceInfo(uniqueID: "builtin", name: "FaceTime HD Camera", isContinuity: false, isSystemPreferred: true)
        let usb = CameraDeviceInfo(uniqueID: "usb-1", name: "USB Camera", isContinuity: false, isSystemPreferred: false)
        #expect(try CameraCatalog.pick(preferred: "builtin", among: [builtIn, usb], suspended: []) == "builtin")
        // The lid is closed: the built-in camera is skipped, preferred or not.
        #expect(try CameraCatalog.pick(preferred: "builtin", among: [builtIn, usb], suspended: ["builtin"]) == "usb-1")
        #expect(try CameraCatalog.pick(preferred: nil, among: [builtIn, usb], suspended: ["builtin"]) == "usb-1")
        // Every camera suspended: it may come back (the lid opens), unlike a Mac without cameras.
        #expect(throws: CaptureSourceError.cameraInterrupted) {
            try CameraCatalog.pick(preferred: nil, among: [builtIn], suspended: ["builtin"])
        }
        #expect(throws: CaptureSourceError.cameraNotFound) {
            try CameraCatalog.pick(preferred: "builtin", among: [], suspended: [])
        }
    }

    // MARK: - Source

    @Test func cameraInterruptionEndsTheRun() {
        let interrupting: [CameraCaptureSource.StopCause] = [.interrupted, .stoppedRunning, .suspended]
        for cause in interrupting {
            #expect(CameraCaptureSource.stopError(for: cause, runActive: true) == .cameraInterrupted, "\(cause)")
        }
        #expect(CameraCaptureSource.stopError(for: .disconnected, runActive: true) == .cameraDisconnected)
        for cause in interrupting + [.disconnected] {
            #expect(CameraCaptureSource.stopError(for: cause, runActive: false) == nil, "\(cause)")
        }
    }

    @Test func cameraSourceIdentifiesItsTrack() {
        let source = CameraCaptureSource(host: CameraSessionHost(), preferredDeviceUniqueID: nil)
        #expect(source.trackID == "camera" && source.kind == .camera && source.media == .video(framesPerSecond: 30))
        #expect(source.activeDeviceUniqueID == nil)
        let fast = CameraCaptureSource(
            host: CameraSessionHost(), preferredDeviceUniqueID: "usb-1", preset: .p720, framesPerSecond: 60)
        #expect(fast.media == .video(framesPerSecond: 60))
    }

    @Test func retimingFromTheHostClockKeepsTheTimestamps() throws {
        let original = SampleFactory.videoSample(width: 32, height: 32, pts: HostTime(nanoseconds: 5_000_000_000), frameIndex: 0)
        for clock in [CMClockGetHostTimeClock(), nil] {
            let retimed = try CaptureClock.retimed(original, from: clock)
            #expect(HostTime(retimed.presentationTimeStamp) == HostTime(nanoseconds: 5_000_000_000))
            #expect(retimed.imageBuffer === original.imageBuffer)
        }
    }

    private func fmt(_ width: Int, _ height: Int, _ fps: Double, v420: Bool = true) -> CameraFormatInfo {
        CameraFormatInfo(width: width, height: height, maxFramesPerSecond: fps, isVideoRange420: v420)
    }

    private func configuration(_ device: String, _ preset: CameraPreset = .p1080, _ fps: Int = 30) -> CameraSessionConfiguration {
        CameraSessionConfiguration(deviceUniqueID: device, preset: preset, framesPerSecond: fps)
    }

    /// A session with leases, capturing the connected `builtin` camera at 1080p and 30 fps, as configured.
    private func snapshot(pinned: Bool = false, running: Bool = true) -> CameraSessionSnapshot {
        CameraSessionSnapshot(
            isFirstLease: false, isRunning: running, isPinned: pinned, inputDeviceUniqueID: "builtin", inputConnected: true,
            configuration: configuration("builtin"), deviceMatchesConfiguration: true)
    }
}
