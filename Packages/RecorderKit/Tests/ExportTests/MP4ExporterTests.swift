// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Render
import Synchronization
import SyntheticCapture
import Testing

@Test func settingsDefaultsAndBitRate() {
    let settings = ExportSettings()
    #expect(settings.outputSize == [1920, 1080])
    #expect(settings.framesPerSecond == 60)
    #expect(settings.failAfterFrames == nil)
    #expect(ExportSettings.bitsPerPixel == 0.08)
    #expect(settings.averageBitRate == 9_953_280)  // 1920 × 1080 × 60 × 0.08
    #expect(ExportSettings(outputSize: [1280, 720], framesPerSecond: 30).averageBitRate == 2_211_840)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportsH264WithRec709AndAudio() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        // A partial file left by an export that died is replaced, not appended to.
        let stale = URL(fileURLWithPath: destination.path + ".partial.mp4")
        try Data("stale".utf8).write(to: stale)

        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [1280, 720], framesPerSecond: 30))
        let summary = try await exporter.export(to: destination) { _ in }
        #expect(summary == ExportSummary())
        #expect(try partialFiles(in: dir).isEmpty)

        let asset = AVURLAsset(url: destination)
        #expect(abs(try await asset.load(.duration).seconds - 3) <= 1.0 / 30)

        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoFormat = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264)
        let size = CMVideoFormatDescriptionGetDimensions(videoFormat)
        #expect(size.width == 1280 && size.height == 720)
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.01)
        func colorTag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(videoFormat, extensionKey: key) as? String
        }
        #expect(colorTag(kCMFormatDescriptionExtension_ColorPrimaries) == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(colorTag(kCMFormatDescriptionExtension_TransferFunction) == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(colorTag(kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        // High profile: profile_idc (the second byte of the avcC record) is 100.
        let atoms = CMFormatDescriptionGetExtension(videoFormat, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        let avcC = try #require(atoms?["avcC"] as? Data)
        #expect(avcC.count > 1 && avcC[avcC.startIndex + 1] == 100)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(abs(Double(try await audio.load(.estimatedDataRate)) - 160_000) < 8_000, "AAC at 160 kbps")
        // It carries the microphone's 440 Hz sine at 1/4 full scale (RMS 0.177).
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.5, to: 2.5) - sineRMS) < 0.02)
    }
}

/// RMS of the `SampleFactory` sine.
private let sineRMS = 0.25 / 2.0.squareRoot()

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func microphoneIsPlacedByHostTimeWithSilenceInGaps() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [
            AudioSegmentSpec(start: base, seconds: 1),
            AudioSegmentSpec(start: base.adding(seconds: 1.01), seconds: 0.49),  // 10 ms gap: closed, it follows on at 1 s
            AudioSegmentSpec(start: base.adding(seconds: 1.8), seconds: 0.6),  // 300 ms gap: silence, then the audio at 1.8 s
            AudioSegmentSpec(start: base.adding(seconds: 2.4), seconds: 0.3, endReason: .unreadable(bytes: 100)),  // marked unreadable: silence
        ])
        try builder.addEmptySegment(  // missing file: silence
            track: micID, index: 5, start: base.adding(seconds: 2.7), end: base.adding(seconds: 3), endReason: .stopped, file: .absent)
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        // The gaps were never recorded; the two segments that were but cannot be used are listed.
        try expectMissing(summary, [
            ("takes/take-001/mic/seg-0004.mov", 2.4, 2.7, .unreadable),
            ("takes/take-001/mic/seg-0005.mov", 2.7, 3.0, .fileMissing),
        ])
        let (start, samples) = try await decodedAudio(of: destination)

        #expect(abs(rms(samples, start: start, from: 0.1, to: 0.9) - sineRMS) < 0.02)
        // No silence where the 10 ms gap was: the longest run of near-zero samples around 1 s is a zero crossing.
        var run = 0, longest = 0
        for i in Int((0.9 - start) * 48_000)..<Int((1.1 - start) * 48_000) {
            run = abs(samples[i]) < 0.02 ? run + 1 : 0
            longest = max(longest, run)
        }
        #expect(longest < 48, "\(longest) silent samples in a row around the closed gap")
        #expect(abs(rms(samples, start: start, from: 1.1, to: 1.45) - sineRMS) < 0.02)
        #expect(rms(samples, start: start, from: 1.55, to: 1.75) < 0.01)
        let onset = try #require((Int((1.6 - start) * 48_000)..<samples.count).first { abs(samples[$0]) > 0.05 })
        #expect(abs(start + Double(onset) / 48_000 - 1.8) < 0.003, "the third segment starts at 1.8 s")
        #expect(abs(rms(samples, start: start, from: 1.9, to: 2.35) - sineRMS) < 0.02)
        #expect(rms(samples, start: start, from: 2.45, to: 2.65) < 0.01)
        #expect(rms(samples, start: start, from: 2.75, to: 2.95) < 0.01)
    }
}

/// The screen stopped after 2 s (it never came back) while the microphone recorded 6 s: the export lasts
/// the microphone, over the screen's last frame, and none of the audio is left out.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func microphoneRecordedPastTheScreenIsExported() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 2)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 6)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary.missingAudio.isEmpty)

        let asset = AVURLAsset(url: destination)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoSeconds = try await video.load(.timeRange).duration.seconds
        #expect(abs(videoSeconds - 6) <= 1.0 / 30 + 1e-6, "video lasts \(videoSeconds) s")
        let (start, samples) = try await decodedAudio(of: destination)
        let audioSeconds = start + Double(samples.count) / 48_000
        #expect(abs(audioSeconds - 6) <= 1.0 / 30 + 0.025, "audio lasts \(audioSeconds) s")
        #expect(abs(rms(samples, start: start, from: 4.9, to: 5.1) - sineRMS) < 0.02)

        // After 2 s the screen's last frame is held.
        let last = try await videoFrame(of: destination, nearest: 59.0 / 30)
        let earlier = try await videoFrame(of: destination, nearest: 1)
        for time in [2.5, 4.0, 5.9] {
            let held = try await videoFrame(of: destination, nearest: time)
            #expect(ssimLuma(held.bytes, last.bytes, width: 640, height: 360) > 0.98, "frame at \(time) s")
        }
        #expect(ssimLuma(earlier.bytes, last.bytes, width: 640, height: 360) < 0.98)
    }
}

/// 4 channels are recorded as ALAC with the encoder's layout for 4, more than 8 as Float32 LPCM with a
/// discrete layout; either way every channel is mixed in.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [4, 10])
func multichannelMicrophoneIsMixedDownToStereo(channels: Int) async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1, channels: channels)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        let audio = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
        // Every channel at unity gain: the copies of the sine add up louder than one (and clip).
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(rms(samples, start: start, from: 0.2, to: 0.8) > 2 * sineRMS)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportedFrameMatchesRenderBeforeEncoding() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let package = try builder.write().package
        let project = try LoadedProject.load(package.url)
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [1280, 720], framesPerSecond: 30))
            .export(to: destination) { _ in }

        let decoded = try await videoFrame(of: destination, nearest: 1.5)
        #expect(abs(decoded.time - 1.5) < 0.001)
        #expect(decoded.width == 1280 && decoded.height == 720)
        let rendered = try FrameRenderer(project: project, outputSize: [1280, 720]).renderBytes(at: 1.5)
        let ssim = ssimLuma(decoded.bytes, rendered, width: 1280, height: 720)
        #expect(ssim >= 0.98, "SSIM \(ssim)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func failedExportKeepsExistingDestination() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let package = try builder.write().package
        let manifest = try Data(contentsOf: package.manifestURL)
        let projectFiles = try snapshot(of: package.url)
        let destination = dir.appending(path: "out.mp4")
        let sentinel = Data((0..<4096).map { UInt8($0 % 251) })
        try sentinel.write(to: destination)

        var settings = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30)
        settings.failAfterFrames = 10
        let progress = Mutex<[Double]>([])
        let error = await #expect(throws: ExportError.self) {
            try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings)
                .export(to: destination) { value in progress.withLock { $0.append(value) } }
        }
        guard case .writerFailed? = error else {
            Issue.record("expected writerFailed, got \(String(describing: error))")
            return
        }
        #expect(progress.withLock { $0.count } == 10, "it failed after the 10th frame")
        #expect(try Data(contentsOf: destination) == sentinel)
        #expect(try partialFiles(in: dir).isEmpty)
        #expect(try Data(contentsOf: package.manifestURL) == manifest)
        #expect(try snapshot(of: package.url) == projectFiles)
        #expect(!progress.withLock { $0 }.contains(1.0))
    }
}

/// The time limit only catches a hang (the stream's `finish` already keeps the test from waiting forever), so it is
/// generous: what a busy machine slows down is the fixture and the export, not what is tested.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func cancelledExportCleansUp() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
        // The export waits in its progress callback, a third of the way in, until the task has been cancelled.
        let (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
        let cancelled = DispatchSemaphore(value: 0)
        let progress = Mutex<[Double]>([])
        let task = Task {
            defer { reachedContinuation.finish() }  // so the test does not wait forever if it never gets there
            try await exporter.export(to: destination) { value in
                let first = progress.withLock { values in
                    defer { values.append(value) }
                    return value > 1.0 / 3 && !values.contains { $0 > 1.0 / 3 }
                }
                if first {
                    reachedContinuation.yield()
                    cancelled.wait()
                }
            }
        }
        for await _ in reached { break }
        task.cancel()
        cancelled.signal()
        await #expect(throws: ExportError.cancelled) { try await task.value }
        #expect(try partialFiles(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try #require(progress.withLock { $0 }.last) < 1)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func exportRefusesDestinationInsideProject() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        let package = try builder.write().package
        let other = try ProjectPackage.create(in: dir, name: "Other", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.url.appending(path: "takes"))
        let fileLink = dir.appending(path: "manifest-link.mp4")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: package.manifestURL)
        let outside = dir.appending(path: "outside.mp4")
        try Data("outside".utf8).write(to: outside)
        let outsideLink = dir.appending(path: "outside-link.mp4")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
        let before = try snapshot(of: dir)

        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
        for destination in [
            package.url.appending(path: "out.mp4"),
            package.url.appending(path: "takes/take-001/out.mp4"),
            package.manifestURL,
            other.url.appending(path: "out.mp4"),
            link.appending(path: "out.mp4"),  // inside the package through a symlink
            // `..` after a symlink: the kernel goes up from where the link points, inside the package.
            URL(fileURLWithPath: link.path + "/../out.mp4"),
            URL(fileURLWithPath: link.path + "/../manifest.json"),
            fileLink,  // a symlink to a file of the package
            outsideLink,  // any symlink: the file replaced would not be the one named
            dir.appending(path: "no-such-folder/out.mp4"),
            dir,  // a folder
            package.url,
        ] {
            await #expect(throws: ExportError.destinationNotAllowed, "\(destination.path)") {
                try await exporter.export(to: destination) { _ in }
            }
        }
        #expect(try snapshot(of: dir) == before)

        // A symlinked folder outside any package is fine: the export lands where it points.
        let exports = dir.appending(path: "exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        let exportsLink = dir.appending(path: "exports-link")
        try FileManager.default.createSymbolicLink(at: exportsLink, withDestinationURL: exports)
        try await exporter.export(to: exportsLink.appending(path: "out.mp4")) { _ in }
        #expect(FileManager.default.fileExists(atPath: exports.appending(path: "out.mp4").path))
        #expect(try partialFiles(in: exports).isEmpty)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func progressReachesOne() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 2)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
        let package = try builder.write().package
        let progress = Mutex<[Double]>([])
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: dir.appending(path: "out.mp4")) { value in progress.withLock { $0.append(value) } }
        let values = progress.withLock { $0 }
        #expect(values.count > 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "\(values)")
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.last == 1.0)
        #expect(values.dropLast().allSatisfy { $0 < 1 })
    }
}

/// About 30 s recorded in real time from synthetic sources whose microphone clock runs 2000 ppm fast. A white
/// flash in the video and a click in the audio are at the same host time, 28 s in; in the MP4 the click
/// must be within 17 ms of the flash (about one frame at 60 fps, the export's frame quantization).
///
/// The sources stamp their samples by their count, not by the clock: on a busy machine their timers fall behind and
/// fewer samples come in 30 s, never samples at other times. So the recording goes on until it holds a second of video
/// after the flash and half a second of audio after the click, however long that takes, and nothing may be dropped.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func exportKeepsAVSyncUnderClockSkew() async throws {
    try await withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Sync", app: AppInfo(name: "Tests", version: "0"), now: Date())
        // Frame k is stamped origin + k / 24 s whenever it comes, so the flash's host time is known ahead.
        // At 24 fps the flash (frame 673, 28.04 s) falls halfway between two frames of the 60 fps export.
        let origin = HostTime.now()
        let fps = 24, flashFrame = 673
        let flash = origin.adding(seconds: Double(flashFrame) / Double(fps))
        let counter = Mutex(0)
        let video = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: fps) {
            let k = counter.withLock { k in
                defer { k += 1 }
                return k
            }
            return origin.adding(seconds: Double(k) / Double(fps))
        }
        let skew = 2000.0
        // The presentation time of the last block of audio the source gave.
        let lastAudio = Mutex<HostTime?>(nil)
        let audio = TransformingSource(clicking(SyntheticAudioSource(clockSkewPPM: skew), at: flash, skewPPM: skew)) { sample in
            lastAudio.withLock { $0 = HostTime(sample.presentationTimeStamp) }
            return sample
        }
        let coordinator = RecordingCoordinator(
            package: package,
            sources: [flashing(video, width: 320, height: 180, from: flash, seconds: 0.5), audio],
            input: NoInputRecorder(),
            diskMonitor: DiskSpaceMonitor(volumeURL: dir),
            systemActivity: AsyncStream { $0.finish() },
            writerFactory: { url, media in try FragmentedTrackWriter(url: url, media: media, realTime: false) })
        _ = try await coordinator.start()
        let recorded = await eventually(timeout: .seconds(300)) {
            counter.withLock { $0 } > flashFrame + fps && (lastAudio.withLock { $0 }.map { $0.seconds(since: flash) > 0.5 } ?? false)
        }
        let take = try await coordinator.stop()
        try #require(recorded, "\(counter.withLock { $0 }) frames and audio up to \(String(describing: lastAudio.withLock { $0 }))")
        // A sample lost to the load would read as a sync error; it reads as what it is.
        for track in take.tracks {
            #expect(track.segments.allSatisfy { $0.droppedFrames == 0 }, "\(track.id): \(track.segments.map(\.droppedFrames)) dropped")
        }

        let project = try LoadedProject.load(package.url)
        // The first frame is frame 0, so output time t is host time origin + t.
        #expect(project.take.track(displayID)?.segments.first?.startHostTime == origin)
        // Every 5 s of audio the recording logged which frame of the file was captured when: frame n at
        // n / 48 kHz × (1 + 2000 ppm) after the segment's start.
        let mic = try #require(project.take.track(micID)?.segments.first)
        let anchors = project.events.compactMap { event -> (frame: Int, t: HostTime)? in
            guard case let .audioClock(track, frame) = event.kind, track == micID else { return nil }
            return (frame, event.t)
        }
        #expect(anchors.count >= 5)
        var previous = mic.startHostTime
        for anchor in anchors {
            #expect(anchor.frame % 480 == 0)
            let expected = Double(anchor.frame) / 48_000 * (1 + skew / 1_000_000)
            #expect(abs(anchor.t.seconds(since: mic.startHostTime) - expected) < 0.001)
            #expect((5.0..<5.1).contains(anchor.t.seconds(since: previous)))
            previous = anchor.t
        }
        let destination = dir.appending(path: "sync.mp4")
        try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 60))
            .export(to: destination) { _ in }

        let flashSeconds = try await flashTime(in: destination)
        #expect(abs(flashSeconds - flash.seconds(since: origin)) <= 1.0 / 60 + 0.001, "the flash is the frame at 28.05 s")
        let clickSeconds = try await clickTime(in: destination, near: flashSeconds)
        let offset = clickSeconds - flashSeconds
        print("A/V offset under \(skew) ppm skew: \(String(format: "%.2f", offset * 1000)) ms (click \(clickSeconds) s, flash \(flashSeconds) s)")
        #expect(abs(offset) <= 0.017, "click \(clickSeconds) s, flash \(flashSeconds) s")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func summaryListsMicrophoneAudioThatCouldNotBeUsed() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(  // a file that is not a movie
            track: micID, index: 2, start: base.adding(seconds: 1), end: base.adding(seconds: 2), endReason: .stopped,
            file: .garbage(bytes: 4096))
        try builder.addEmptySegment(
            track: micID, index: 3, start: base.adding(seconds: 2), end: base.adding(seconds: 2.5), endReason: .empty, file: .absent)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base.adding(seconds: 2.5), seconds: 0.5)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary.missingAudio.count == 2)
        let unopened = try #require(summary.missingAudio.first)
        #expect(unopened.file == "takes/take-001/mic/seg-0002.mov")
        #expect(abs(unopened.start - 1) < 1e-6 && abs(unopened.end - 2) < 1e-6)
        guard case .cannotOpen(let why) = unopened.reason else {
            Issue.record("expected cannotOpen, got \(unopened.reason)")
            return
        }
        #expect(!why.isEmpty)
        try expectMissing(ExportSummary(missingAudio: Array(summary.missingAudio.dropFirst())), [
            ("takes/take-001/mic/seg-0003.mov", 2, 2.5, .empty),
        ])
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.1, to: 0.9) - sineRMS) < 0.02)
        #expect(rms(samples, start: start, from: 1.1, to: 2.4) < 0.01)
        #expect(abs(rms(samples, start: start, from: 2.6, to: 2.9) - sineRMS) < 0.02)
    }
}

// MARK: - Microphone and system audio

/// A mono microphone at 440 Hz and stereo system audio at 1000 Hz: the MP4 has one stereo AAC track that carries both.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func microphoneAndSystemAudioAreMixed() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 1000)])
        let project = try builder.write()
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary == ExportSummary())

        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        try #require(tracks.count == 1)
        let format = try #require(try await tracks[0].load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
        let (start, samples) = try await decodedAudio(of: destination)
        func level(_ frequency: Double) -> Double {
            toneAmplitude(samples, start: start, frequency: frequency, from: 0.5, to: 2.5)
        }
        let microphone = level(440), systemAudio = level(1000), between = level(700)
        for (name, tone) in [("440 Hz", microphone), ("1000 Hz", systemAudio)] {
            #expect(20 * log10(tone / between) > 20, "\(name): \(tone), 700 Hz: \(between)")
            #expect(abs(tone - 0.25) < 0.02, "\(name) at unity gain: \(tone)")
        }
    }
}

/// 30 s of a microphone whose clock runs 2000 ppm fast and of system audio whose clock runs 1500 ppm slow, written
/// with their anchors. A white flash in the video and a burst in each audio track, 440 Hz in the microphone and
/// 1000 Hz in system audio, are at the same host time, 28 s in: at 24 fps the flash (frame 673, 28.04 s) falls
/// halfway between two frames of the 60 fps export. In the MP4 each burst, found by its own frequency, must be
/// within 17 ms of the flash (about one frame at 60 fps); placed at the nominal rate, the microphone's would be 56 ms
/// early and system audio's 42 ms late, and system audio placed by the microphone's anchors 98 ms late. The time limit
/// only catches a hang: on a busy machine the fixture and the export of 30 s take minutes.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func eachAudioTrackIsPlacedByItsOwnAnchors() async throws {
    try await withTemporaryDirectory { dir in
        let fps = 24, flashFrame = 673
        let flash = base.adding(seconds: Double(flashFrame) / Double(fps))
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 30, framesPerSecond: fps) { frame, sample in
                (flashFrame..<flashFrame + fps / 2).contains(frame)
                    ? whiteVideoSample(width: 640, height: 360, pts: sample.presentationTimeStamp) : sample
            },
        ])
        let micSkew = 2000.0, systemSkew = -1500.0
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [
            AudioSegmentSpec(
                start: base, seconds: 30, amplitude: 0, clockSkewPPM: micSkew,
                transform: toneBurst(at: flash, start: base, skewPPM: micSkew, frequency: 440, channels: 1)),
        ])
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: [
            AudioSegmentSpec(
                start: base, seconds: 30, channels: 2, amplitude: 0, clockSkewPPM: systemSkew,
                transform: toneBurst(at: flash, start: base, skewPPM: systemSkew, frequency: 1000, channels: 2)),
        ])
        let project = try builder.write()
        for track in [micID, systemAudioID] {
            let anchors = project.events.filter { if case .audioClock(track, _) = $0.kind { true } else { false } }
            #expect(anchors.count >= 5, "\(track) has its own anchors")
        }
        let destination = dir.appending(path: "sync.mp4")
        try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 60))
            .export(to: destination) { _ in }

        let flashSeconds = try await flashTime(in: destination)
        #expect(abs(flashSeconds - flash.seconds(since: base)) <= 1.0 / 60 + 0.001, "the flash is the frame at 28.05 s")
        for (track, frequency) in [(micID, 440.0), (systemAudioID, 1000.0)] {
            let onset = try await toneOnset(in: destination, frequency: frequency, near: flashSeconds)
            let offset = onset - flashSeconds
            print("\(track): \(frequency) Hz burst \(String(format: "%.2f", offset * 1000)) ms from the flash (\(onset) s, flash \(flashSeconds) s)")
            #expect(abs(offset) <= 0.017, "\(track): burst at \(onset) s, flash at \(flashSeconds) s")
        }
    }
}

/// System audio that starts 2 s into the screen, without a microphone: silence before it, its sine after. The AAC's
/// pre-echo of about 21 ms is why the spans keep 0.1 s from the change, as in the phase 0 tests.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func systemAudioStartingLateIsSilentBefore() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base.adding(seconds: 2), seconds: 1, channels: 2)])
        let project = try builder.write()
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary == ExportSummary())
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(rms(samples, start: start, from: 0.1, to: 1.9) < 0.01)
        #expect(abs(rms(samples, start: start, from: 2.1, to: 2.9) - sineRMS) < 0.02)
    }
}

/// Two tracks with the same sine at 0.9 of full scale add up to 1.8: the mix, read before the encoder (a decoded
/// AAC goes past 1 by itself), is clipped to [−1, 1] instead of wrapping around, so it keeps the sine's sign.
@Test func mixedAudioClipsInsteadOfWrapping() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1, amplitude: 0.9)])
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base, seconds: 1, amplitude: 0.9)])
        let project = try builder.write()
        let totalFrames: Int64 = 48_000
        // The second of both tracks, at unity gain.
        var document = EditDocument.legacy(for: project)
        document.sequence = [Clip(id: "c-00000001", take: project.take.id, start: base, end: base.adding(seconds: 1), speed: 1)]
        let mix = try AudioMix(mix: try await EditedMix.make(project: project, document: document, framesPerSecond: 60))
        #expect(mix.channels == 1 && mix.totalFrames == totalFrames)
        var mixed: [Float] = []
        while let block = try mix.nextBlock() {
            let data = try #require(CMSampleBufferGetDataBuffer(block))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            mixed += values
        }
        try #require(mixed.count == Int(totalFrames))
        #expect(mixed.allSatisfy { abs($0) <= 1 })
        // `SampleFactory`'s sine, whose phase comes from the host time: frame n is at base + n / 48 kHz.
        let first = Double(base.nanoseconds) / 1_000_000_000
        var compared = 0
        for (n, x) in mixed.enumerated() {
            let cycles = 440 * (first + Double(n) / 48_000)
            let sine = 0.9 * sin(2 * Double.pi * (cycles - cycles.rounded(.down)))
            guard abs(sine) > 0.5 else { continue }
            compared += 1
            #expect((x > 0) == (sine > 0), "frame \(n): \(x) for a sine of \(sine)")
            if (x > 0) != (sine > 0) { break }
        }
        #expect(compared > 20_000)
    }
}

/// A system audio segment that holds nothing is listed with its track; the microphone's audio is all there.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func summaryNamesTheTrackOfMissingAudio() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: [])
        try builder.addEmptySegment(
            track: systemAudioID, index: 1, start: base, end: base.adding(seconds: 3), endReason: .stopped, file: .zeroBytes)
        let project = try builder.write()
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        try #require(summary.missingAudio.count == 1, "\(summary.missingAudio)")
        let missing = summary.missingAudio[0]
        #expect(missing.track == systemAudioID)
        #expect(missing.file == "takes/take-001/system-audio/seg-0001.mov")
        #expect(abs(missing.start - 0) < 1e-6 && abs(missing.end - 3) < 1e-6, "\(missing)")
        #expect(missing.reason == .empty)
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.5, to: 2.5) - sineRMS) < 0.02)
    }
}

/// `summary.missingAudio` is exactly `expected` (file, start, end, reason), times within 1 µs.
private func expectMissing(_ summary: ExportSummary, _ expected: [(String, Double, Double, MissingAudio.Reason)]) throws {
    try #require(summary.missingAudio.count == expected.count, "\(summary.missingAudio)")
    for (missing, (file, start, end, reason)) in zip(summary.missingAudio, expected) {
        #expect(missing.file == file)
        #expect(abs(missing.start - start) < 1e-6 && abs(missing.end - end) < 1e-6, "\(missing)")
        #expect(missing.reason == reason)
    }
}

/// The H.264 writer of an export is asked for the formula's data rate (`averageBitRate`, width × height × fps × 0.08),
/// with the export's other settings.
@Test func videoSettingsAskForTheFormulasDataRate() throws {
    let settings = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30)
    let video = MP4Exporter.videoSettings(settings)
    #expect(video[AVVideoCodecKey] as? AVVideoCodecType == .h264)
    #expect(video[AVVideoWidthKey] as? Int == 1280 && video[AVVideoHeightKey] as? Int == 720)
    let compression = try #require(video[AVVideoCompressionPropertiesKey] as? [String: Any])
    #expect(compression[AVVideoAverageBitRateKey] as? Int == settings.averageBitRate)
    #expect(compression[AVVideoExpectedSourceFrameRateKey] as? Int == 30)
}

/// Random pixels at 1280×720, 30 fps: content the encoder cannot compress below its target, so the file's
/// data rate is the formula's (width × height × fps × 0.08), within what VideoToolbox's rate control holds.
///
/// A measure of VideoToolbox, not of Toma's code (which `videoSettingsAskForTheFormulasDataRate` checks), so it runs
/// only with `TOMA_BENCH=1`, on a Mac whose media engine is free: the export takes whichever H.264 encoder is free, and
/// while other processes hold the hardware one the software encoder controls the rate otherwise (49 % over it once, at
/// load 37), as the runners' virtual machines do.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && MetalCondition.isAvailable))
func videoDataRateFollowsTheFormula() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 4) { frame, sample in
                noiseVideoSample(width: 640, height: 360, pts: sample.presentationTimeStamp, seed: UInt64(frame))
            },
        ])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 4)])
        let package = try builder.write().package
        let settings = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30)
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings).export(to: destination) { _ in }
        let video = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let rate = Double(try await video.load(.estimatedDataRate))
        #expect(abs(rate / Double(settings.averageBitRate) - 1) <= 0.2, "\(rate) bit/s for \(settings.averageBitRate)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func takeWithoutMicrophoneExportsWithoutAudio() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        let package = try builder.write().package
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary.missingAudio.isEmpty)
        let asset = AVURLAsset(url: destination)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }
}

/// A window is a screen too: a take of a window and the microphone exports.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func takeOfAWindowExports() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        let window = TrackSource(
            name: "Synthetic Window", globalFrame: Rect(x: 100, y: 100, width: 640, height: 360), pixelScale: 1, windowID: 7)
        try await builder.addVideoTrack(id: "window-7", kind: .window, source: window, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        let project = try builder.write()
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary == ExportSummary())
        #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).count == 1)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func takeWithoutScreenIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        let package = try builder.write().package
        let loaded = try LoadedProject.load(package.url)
        let mic = try #require(loaded.take.track(micID))
        var display = try #require(loaded.take.track(displayID))
        display.segments = []
        for tracks in [[mic], [display, mic]] {  // no display track; a display track that recorded nothing
            var project = loaded
            project.take.tracks = tracks
            await #expect(throws: ExportError.noDisplayTrack) {
                try await MP4Exporter(project: project).export(to: dir.appending(path: "out.mp4")) { _ in }
            }
        }
        #expect(try partialFiles(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out.mp4").path))
    }
}
