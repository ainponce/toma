// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import Testing

@testable import Recording

/// Real capture: needs Screen Recording and Microphone permission for the process running the tests.
/// `RECORDER_INTEGRATION=1 swift test --package-path Packages/RecorderKit --filter CaptureIntegrationTests`
@Suite struct CaptureIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func capturesMainDisplayForTwoSeconds() async throws {
        let displayID = CGMainDisplayID()
        let queue = DispatchSerialQueue(label: "test.capture.display")
        let sink = RecordingSink(queue: queue)
        let source = DisplayCaptureSource(displayID: displayID)
        #expect(source.trackID == "display-\(displayID)")
        let bounds = CGDisplayBounds(displayID)
        #expect(source.sourceInfo.globalFrame == Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))

        try await source.start(on: queue, sink: sink)
        try await Task.sleep(for: .seconds(2))
        await source.stop()

        let samples = sink.samples
        #expect(samples.count >= 1)
        #expect(samples.allSatisfy { $0.isCompleteFrame && $0.trackID == source.trackID })
        #expect(samples.allSatisfy { abs($0.lag) < 1 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.pts < $1.pts })
        let scale = try #require(source.sourceInfo.pixelScale)
        #expect(samples.allSatisfy { $0.width == Int((bounds.width * scale).rounded()) })
        #expect(sink.failures.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func capturesDefaultMicrophone() async throws {
        let queue = DispatchSerialQueue(label: "test.capture.microphone")
        let sink = RecordingSink(queue: queue)
        let source = MicrophoneCaptureSource(preferredDeviceUniqueID: nil)
        #expect(source.trackID == "mic")

        try await source.start(on: queue, sink: sink)
        #expect(source.activeDeviceUniqueID != nil)
        #expect(source.sourceInfo.deviceUniqueID == source.activeDeviceUniqueID)
        try await Task.sleep(for: .seconds(1))
        await source.stop()

        let samples = sink.samples
        #expect(samples.count >= 1)
        #expect(samples.allSatisfy { abs($0.lag) < 1 && $0.trackID == "mic" && $0.sampleRate != nil })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.pts < $1.pts })
        #expect(sink.failures.isEmpty)
        #expect(source.activeDeviceUniqueID == nil)
    }
}
