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
}
