// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
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

@Test(.enabled(if: metalAvailable))
func exportsH264WithRec709AndAudio() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3)
        let destination = dir.appending(path: "out.mp4")
        // A partial file left by an export that died is replaced, not appended to.
        let stale = URL(fileURLWithPath: destination.path + ".partial.mp4")
        try Data("stale".utf8).write(to: stale)

        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [1280, 720], framesPerSecond: 30))
        try await exporter.export(to: destination) { _ in }
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
        // It carries the microphone's 440 Hz sine at 1/4 full scale (RMS 0.177).
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.5, to: 2.5) - sineRMS) < 0.02)
    }
}

/// RMS of the `SampleFactory` sine.
private let sineRMS = 0.25 / 2.0.squareRoot()

@Test(.enabled(if: metalAvailable))
func microphoneIsPlacedByHostTimeWithSilenceInGaps() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3, mic: [
            MicSegment(start: 0, seconds: 1),
            MicSegment(start: 1.01, seconds: 0.49),  // 10 ms gap: closed, it follows on at 1 s
            MicSegment(start: 1.8, seconds: 0.6),  // 300 ms gap: silence, then the audio at 1.8 s
            MicSegment(start: 2.4, seconds: 0.3, endReason: .unreadable(bytes: 100)),  // marked unreadable: silence
            MicSegment(start: 2.7, seconds: 0.3, writesFile: false),  // missing file: silence
        ])
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
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

@Test(.enabled(if: metalAvailable))
func multichannelMicrophoneIsMixedDownToStereo() async throws {
    try await withTemporaryDirectory { dir in
        // More than 8 channels are recorded as Float32 LPCM with a discrete layout.
        let package = try await makeSyntheticPackage(in: dir, seconds: 1, mic: [MicSegment(start: 0, seconds: 1, channels: 10)])
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        let audio = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
        // Every channel at unity gain: ten copies of the sine add up louder than one (and clip).
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(rms(samples, start: start, from: 0.2, to: 0.8) > 2 * sineRMS)
    }
}

@Test(.enabled(if: metalAvailable))
func exportedFrameMatchesRenderBeforeEncoding() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3)
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

@Test(.enabled(if: metalAvailable))
func failedExportKeepsExistingDestination() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3)
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

@Test(.enabled(if: metalAvailable), .timeLimit(.minutes(1)))
func cancelledExportCleansUp() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3)
        let destination = dir.appending(path: "out.mp4")
        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [1280, 720], framesPerSecond: 30))
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

@Test(.enabled(if: metalAvailable))
func exportRefusesDestinationInsideProject() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1)
        let other = try ProjectPackage.create(in: dir, name: "Other", app: AppInfo(name: "Tests", version: "0"), now: Date())
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.url.appending(path: "takes"))
        let fileLink = dir.appending(path: "manifest-link.mp4")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: package.manifestURL)
        let before = try snapshot(of: dir)

        let exporter = MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
        for destination in [
            package.url.appending(path: "out.mp4"),
            package.url.appending(path: "takes/take-001/out.mp4"),
            package.manifestURL,
            other.url.appending(path: "out.mp4"),
            link.appending(path: "out.mp4"),  // inside the package through a symlink
            fileLink,  // a symlink to a file of the package
            dir,  // a folder
            package.url,
        ] {
            await #expect(throws: ExportError.destinationNotAllowed, "\(destination.path)") {
                try await exporter.export(to: destination) { _ in }
            }
        }
        #expect(try snapshot(of: dir) == before)
    }
}

@Test(.enabled(if: metalAvailable))
func progressReachesOne() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 2)
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

/// 30 s recorded in real time from synthetic sources whose microphone clock runs 2000 ppm fast. A white
/// flash in the video and a click in the audio are at the same host time, 28 s in; in the MP4 the click
/// must be within 17 ms of the flash (about one frame at 60 fps, the export's frame quantization).
@Test(.enabled(if: metalAvailable), .timeLimit(.minutes(3)))
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
        let coordinator = RecordingCoordinator(
            package: package,
            sources: [
                flashing(video, width: 320, height: 180, from: flash, seconds: 0.5),
                clicking(SyntheticAudioSource(clockSkewPPM: skew), at: flash, skewPPM: skew),
            ],
            input: NoInputRecorder(),
            diskMonitor: DiskSpaceMonitor(volumeURL: dir),
            systemActivity: AsyncStream { $0.finish() },
            writerFactory: { url, media in try FragmentedTrackWriter(url: url, media: media, realTime: false) })
        _ = try await coordinator.start()
        try await Task.sleep(for: .seconds(30))
        _ = try await coordinator.stop()

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
