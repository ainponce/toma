// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

@testable import Recording

/// Real capture: needs Screen Recording and Microphone permission for the process running the tests (and Camera
/// and System Audio Recording for those tests).
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

    /// Needs Camera permission and a camera (the built-in one, an iPhone by Continuity Camera or a USB one).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func capturesDefaultCameraForTwoSeconds() async throws {
        let queue = DispatchSerialQueue(label: "test.capture.camera")
        let sink = RecordingSink(queue: queue)
        let host = CameraSessionHost()
        let source = CameraCaptureSource(host: host, preferredDeviceUniqueID: nil)
        #expect(source.trackID == "camera")

        try await source.start(on: queue, sink: sink)
        let device = try #require(source.activeDeviceUniqueID)
        #expect(source.sourceInfo.deviceUniqueID == device)
        #expect(host.activeDeviceUniqueID == device)
        try await Task.sleep(for: .seconds(2))
        await source.stop()

        let samples = sink.samples
        #expect(samples.count >= 1)
        #expect(samples.allSatisfy { abs($0.lag) < 1 && $0.trackID == "camera" && $0.width != nil })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.pts < $1.pts })
        #expect(sink.failures.isEmpty)
        #expect(source.activeDeviceUniqueID == nil)
        // The run's lease was the only one: the session stopped with it.
        #expect(await eventually { host.activeDeviceUniqueID == nil })
    }

    /// Needs System Audio Recording permission (the first run makes macOS ask; a refused permission records
    /// silence, about -160 dBFS here) and an output device. Plays a 440 Hz tone with `afplay`, which the tap of
    /// every app records.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RECORDER_INTEGRATION"] == "1"))
    func capturesSystemAudioForTwoSeconds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toma-tone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = folder.appendingPathComponent("tone.wav")
        try writeTone(to: tone, frequency: 440, seconds: 4)

        let queue = DispatchSerialQueue(label: "test.capture.systemAudio")
        let sink = RecordingSink(queue: queue)
        let peaks = PeakSink(queue: queue, forwardingTo: sink)
        let source = ProcessTapSource(scope: .all)
        #expect(source.trackID == "system-audio")

        try await source.start(on: queue, sink: peaks)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try player.run()
        try await Task.sleep(for: .seconds(2))
        await source.stop()
        player.terminate()

        let samples = sink.samples
        #expect(samples.count >= 1)
        #expect(samples.allSatisfy { abs($0.lag) < 1 && $0.trackID == "system-audio" && $0.channels == 2 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.pts < $1.pts })
        #expect(sink.failures.isEmpty)
        let peak = peaks.peak
        let dBFS = 20 * log10(max(Double(peak), 1e-8))
        // -40 dBFS; at -160 the permission was refused.
        #expect(peak > 0.01, "peak \(String(format: "%.1f", dBFS)) dBFS")
    }
}

/// Forwards to `sink` and keeps the largest absolute sample value of the Float32 audio it sees.
private final class PeakSink: CaptureSink {
    let queue: DispatchSerialQueue
    private let sink: RecordingSink
    private let largest = Mutex<Float>(0)

    init(queue: DispatchSerialQueue, forwardingTo sink: RecordingSink) {
        self.queue = queue
        self.sink = sink
    }

    var peak: Float { largest.withLock { $0 } }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        if let format = sample.formatDescription?.audioStreamBasicDescription,
           format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            try? sample.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let values = UnsafeBufferPointer(start: data, count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    let top = values.reduce(Float(0)) { max($0, abs($1)) }
                    largest.withLock { $0 = max($0, top) }
                }
            }
        }
        sink.source(trackID, didOutput: sample)
    }

    func source(_ trackID: String, didStopWithError error: any Error) {
        sink.source(trackID, didStopWithError: error)
    }
}

/// A mono 48 kHz WAV of a sine at half of full scale.
private func writeTone(to url: URL, frequency: Double, seconds: Double) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let frames = AVAudioFrameCount(48_000 * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for n in 0..<Int(frames) {
        samples[n] = Float(0.5 * sin(2 * Double.pi * frequency * Double(n) / 48_000))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
