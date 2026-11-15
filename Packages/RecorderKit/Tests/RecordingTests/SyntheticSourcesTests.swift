// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import SyntheticCapture
import Testing

import Recording

/// What the synthetic sources of every kind say about themselves, and how the synthetic microphone paces itself.
@Suite struct SyntheticSourcesTests {
    @Test func syntheticSourcesReportTheirKind() {
        let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 64, height: 36, framesPerSecond: 30)
        #expect(camera.kind == .camera && camera.media == .video(framesPerSecond: 30))
        #expect(camera.sourceInfo == TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"))
        camera.deviceUniqueID = "usb-camera"
        #expect(camera.sourceInfo.deviceUniqueID == "usb-camera")

        let window = SyntheticVideoSource(
            trackID: "window-4242", kind: .window, globalOrigin: [100, 80], width: 64, height: 36, framesPerSecond: 30)
        #expect(window.kind == .window)
        #expect(window.sourceInfo == TrackSource(
            name: "Synthetic Window", globalFrame: Rect(x: 100, y: 80, width: 64, height: 36), pixelScale: 1, windowID: 4242,
            bundleIdentifier: "dev.toma.synthetic"))

        let second = SyntheticVideoSource(
            trackID: "display-2", displayID: 2, globalOrigin: [-64, 0], width: 64, height: 36, framesPerSecond: 30)
        #expect(second.kind == .display)
        #expect(second.sourceInfo == TrackSource(
            name: "Synthetic Display", displayID: 2, globalFrame: Rect(x: -64, y: 0, width: 64, height: 36), pixelScale: 1))

        let systemAudio = SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2)
        #expect(systemAudio.kind == .systemAudio && systemAudio.media == .audio)
        #expect(systemAudio.sourceInfo == TrackSource(name: "Synthetic System Audio", excludedBundleIDs: ["dev.toma.Toma"]))
        #expect(SyntheticAudioSource().kind == .microphone)
        #expect(SyntheticAudioSource().sourceInfo == TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"))
    }

    @Test func sourcesRefuseAKindOfTheOtherMedia() async {
        await #expect(processExitsWith: .failure) {
            _ = SyntheticVideoSource(kind: .microphone, width: 16, height: 16, framesPerSecond: 30)
        }
        await #expect(processExitsWith: .failure) {
            _ = SyntheticAudioSource(kind: .camera)
        }
    }

    /// Residue of the backlog (`maximumBlocksPerTick`): a delivery queue held for 1 s gets 0.5 s of audio on the next
    /// tick, not the whole second, so a starved process never holds its queue catching up.
    @Test func syntheticMicCatchesUpAtMostHalfASecond() async throws {
        let queue = DispatchSerialQueue(label: "test.synthetic.catchUp")
        let sink = RecordingSink(queue: queue)
        let source = SyntheticAudioSource()
        try await source.start(on: queue, sink: sink)
        #expect(await eventually { sink.samples.count >= 5 })

        // The timer fires while the queue is held, so its one tick is queued before the marker.
        let (before, after) = await withCheckedContinuation { continuation in
            queue.async {
                let before = sink.samples.count
                Thread.sleep(forTimeInterval: 1)
                queue.async { continuation.resume(returning: (before, sink.samples.count)) }
            }
        }
        await source.stop()
        #expect(after - before == 50)
    }
}
