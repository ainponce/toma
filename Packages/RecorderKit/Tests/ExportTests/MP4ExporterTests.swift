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

@Test(.enabled(if: metalAvailable))
func microphoneIsPlacedByHostTimeWithSilenceInGaps() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3, mic: [
            MicSegment(start: 0, seconds: 1),
            MicSegment(start: 1.01, seconds: 0.49),  // 10 ms gap: closed, it follows on at 1 s
            MicSegment(start: 1.8, seconds: 0.6),  // 300 ms gap: silence, then the audio at 1.8 s
            MicSegment(start: 2.4, seconds: 0.3, endReason: .unreadable(bytes: 100)),  // marked unreadable: silence
            MicSegment(start: 2.7, seconds: 0.3, contents: .none),  // missing file: silence
        ])
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
@Test(.enabled(if: metalAvailable))
func microphoneRecordedPastTheScreenIsExported() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 2, mic: [MicSegment(start: 0, seconds: 6)])
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
@Test(.enabled(if: metalAvailable), arguments: [4, 10])
func multichannelMicrophoneIsMixedDownToStereo(channels: Int) async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1, mic: [MicSegment(start: 0, seconds: 1, channels: channels)])
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

@Test(.enabled(if: metalAvailable))
func summaryListsMicrophoneAudioThatCouldNotBeUsed() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 3, mic: [
            MicSegment(start: 0, seconds: 1),
            MicSegment(start: 1, seconds: 1, contents: .garbage),  // a file that is not a movie
            MicSegment(start: 2, seconds: 0.5, endReason: .empty, contents: .none),
            MicSegment(start: 2.5, seconds: 0.5),
        ])
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

/// `summary.missingAudio` is exactly `expected` (file, start, end, reason), times within 1 µs.
private func expectMissing(_ summary: ExportSummary, _ expected: [(String, Double, Double, MissingAudio.Reason)]) throws {
    try #require(summary.missingAudio.count == expected.count, "\(summary.missingAudio)")
    for (missing, (file, start, end, reason)) in zip(summary.missingAudio, expected) {
        #expect(missing.file == file)
        #expect(abs(missing.start - start) < 1e-6 && abs(missing.end - end) < 1e-6, "\(missing)")
        #expect(missing.reason == reason)
    }
}

/// Random pixels at 1280×720, 30 fps: content the encoder cannot compress below its target, so the file's
/// data rate is the formula's (width × height × fps × 0.08), within what VideoToolbox's rate control holds.
/// Off in CI: the H.264 rate control of the runners' virtual machines differs.
@Test(
    .enabled(if: metalAvailable),
    .disabled(if: ProcessInfo.processInfo.environment["TOMA_CI"] == "1", "VM H.264 rate control differs"))
func videoDataRateFollowsTheFormula() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 4, noise: true)
        let settings = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30)
        let destination = dir.appending(path: "out.mp4")
        try await MP4Exporter(project: try LoadedProject.load(package.url), settings: settings).export(to: destination) { _ in }
        let video = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let rate = Double(try await video.load(.estimatedDataRate))
        #expect(abs(rate / Double(settings.averageBitRate) - 1) <= 0.2, "\(rate) bit/s for \(settings.averageBitRate)")
    }
}

@Test(.enabled(if: metalAvailable))
func takeWithoutMicrophoneExportsWithoutAudio() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1, microphone: false)
        let destination = dir.appending(path: "out.mp4")
        let summary = try await MP4Exporter(project: try LoadedProject.load(package.url), settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary.missingAudio.isEmpty)
        let asset = AVURLAsset(url: destination)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }
}

@Test(.enabled(if: metalAvailable))
func takeWithoutScreenIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await makeSyntheticPackage(in: dir, seconds: 1)
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
