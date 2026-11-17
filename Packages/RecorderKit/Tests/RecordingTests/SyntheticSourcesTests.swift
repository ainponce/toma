// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import SyntheticCapture
import Testing

import Recording

/// What the synthetic sources of every kind say about themselves, how the synthetic microphone paces itself, and what
/// the synthetic input of `synth-record` logs.
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

    /// `synth-record`'s input in a take of 5 s: the arrow from the start and the I-beam at 1 s with their images, a
    /// click a second, a scroll at 2 s and the windows from 3 to 4 s with a key.
    ///
    /// The input's own start is the first click's time less 0.5 s: clicks, the scroll and the keys are logged at times
    /// computed from it, exactly, however late its timer is. The cursor's images are not: they come from a poll on the
    /// main queue, which every test of the bundle shares, so under load the arrow's may come late, or after 1 s, when
    /// only the I-beam is seen.
    @Test func synthRecordWritesTheNewEvents() async throws {
        try await withTemporaryDirectory { dir in
            let package = try ProjectPackage.create(in: dir, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
            let coordinator = RecordingCoordinator(
                package: package, sources: [SyntheticVideoSource(width: 64, height: 36, framesPerSecond: 30), SyntheticAudioSource()],
                input: SyntheticInputRecorder(),
                diskMonitor: DiskSpaceMonitor(volumeURL: dir, query: { _ in DiskCapacity(importantUsage: 1 << 40, available: 1 << 40) }),
                systemActivity: AsyncStream { $0.finish() })
            let take = try await coordinator.start()
            try await Task.sleep(for: .seconds(5))
            _ = try await coordinator.stop()
            let events = try EventLogReader.read(package.eventsURL(take: take)).events

            let downs = events.filter { if case .mouseDown(.left, _, _) = $0.kind { true } else { false } }
            let start = try #require(downs.first).t.adding(seconds: -0.5)

            let images = events.compactMap { event -> (t: HostTime, hash: String, kind: CursorKind?)? in
                guard case let .cursorImage(hash, _, _, kind) = event.kind else { return nil }
                return (event.t, hash, kind)
            }
            #expect([[.arrow, .iBeam], [.iBeam]].contains(images.map(\.kind)), "\(images.map(\.kind))")
            #expect(Set(images.map(\.hash)).count == images.count)
            for image in images {
                let url = package.cursorImageURL(take: take, hash: image.hash)
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent)")
                #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
            }
            #expect(try #require(images.last?.t).seconds(since: start) >= 1)

            let scrolls = events.filter { if case .scroll = $0.kind { true } else { false } }
            #expect(scrolls.map { $0.t } == [start.adding(seconds: 2)])

            let windows = events.filter { $0.kind == .keyActivity }.map(\.t)
            #expect(windows.count == 4)
            #expect(windows.allSatisfy { $0 == KeyActivityRecorder.windowStart(of: $0) })
            #expect(zip(windows, windows.dropFirst()).allSatisfy { $1.nanoseconds - $0.nanoseconds == KeyActivityRecorder.window })
            let first = try #require(windows.first).seconds(since: start)
            #expect(first >= 3 && first < 3.25, "the first window starts \(first) s in")

            let ups = events.filter { if case .mouseUp(.left, _, _) = $0.kind { true } else { false } }
            #expect(downs.count >= 4 && ups.count >= 4)
            #expect(events.count { if case .cursor = $0.kind { true } else { false } } > 100)
        }
    }
}
