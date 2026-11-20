// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreMedia
import CoreVideo
import Editing
import Export
import Foundation
import ProjectFormat
import ProjectJobs
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import ProjectAPI

/// The API's export (fases 4 y 5 design §6.2; plan 4b, Review Focus 2 and 3): the app's preparation, then its exporter,
/// never a byte into the package. None uses Vision or the Audio Unit (no camera, no voice isolation), and the music
/// library is a folder of the test's: its theme `calm` is written there beforehand, so nothing is synthesized.

private let metal = MetalCondition.isAvailable || MetalCondition.isRequired
/// A small video of the whole output: 320 × 180 at 10 fps.
private let small = ExportSettings(outputSize: [320, 180], framesPerSecond: 10)

@MainActor @Suite struct APIExportTests {
    @Test(.enabled(if: metal)) func apiExportIsThePreparedExport() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            try writeTheme("calm", in: environment.musicRoot)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            _ = try await project.apply(.addMusic(theme: "calm", volume: -6))
            // ProRes, whose LPCM sound decodes to the samples mixed, and whose frames hardly depend on which of
            // VideoToolbox's encoders writes them (H.264 at this size has too few bits for that).
            var settings = small
            settings.codec = .proRes422
            let reported = Reports()
            let viaAPI = dir.appending(path: "api.mov")
            let result = try await project.export(to: viaAPI, format: .video(settings)) { reported.add($0) }
            #expect(result == ExportResult(
                path: viaAPI.path, format: "mov", codec: "prores422", width: 320, height: 180, framesPerSecond: 10, duration: 10,
                bytes: result.bytes, chapters: 0, warnings: [], fcpxml: nil, metadata: nil))
            #expect(result.bytes > 0)
            let fractions = reported.all
            #expect(fractions.last == 1 && fractions == fractions.sorted())

            // What the app does: the shared preparation, then the exporter, with what it prepared.
            let caches = ProjectCaches(root: environment.cachesRoot, projectID: project.project.manifest.resolvedProjectID)
            let workers = ExportWorkers.standalone(
                project: project.project, caches: caches, isolator: environment.isolator,
                library: MusicLibrary(root: environment.musicRoot))
            let prepared = try await ExportPreparation.prepared(
                project: project.project, document: project.document, caches: caches, needs: .video, workers: workers) { _ in }
            #expect(prepared.analysis.musicFiles.count == 1)
            let byHand = dir.appending(path: "hand.mov")
            try await MP4Exporter(
                project: project.project, document: project.document, settings: settings, analysis: prepared.analysis,
                remakeMusic: prepared.remakeMusic
            ).export(to: byHand) { _ in }
            await project.close()

            let (api, hand) = (try await videoFrames(of: viaAPI), try await videoFrames(of: byHand))
            #expect(api.count == 100 && sameFrames(api, hand), "\(frameDifference(api, hand))")
            let (apiSound, handSound) = (try await decodedAudioChannels(of: viaAPI), try await decodedAudioChannels(of: byHand))
            #expect(apiSound.channels == handSound.channels && apiSound.samples.count == handSound.samples.count)
            #expect(apiSound.samples == handSound.samples, "the same sound, sample by sample")
            #expect(apiSound.samples.contains { abs($0) > 0.01 })
        }
    }

    @Test(.enabled(if: metal)) func musicIsInTheAPIExport() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            try writeTheme("calm", in: environment.musicRoot)
            // A take without sound of its own: what the export plays is the music.
            let url = try await screenOnly(in: dir)
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            _ = try await project.apply(.addMusic(theme: "calm", volume: nil))
            let destination = dir.appending(path: "music.mp4")
            _ = try await project.export(to: destination, format: .video(small), progress: nil)
            _ = try await project.apply(.removeMusic)
            let silent = dir.appending(path: "silent.mp4")
            _ = try await project.export(to: silent, format: .video(small), progress: nil)
            await project.close()

            // From 2 s to 4 s, past any fade in.
            let sound = try await decodedAudioChannels(of: destination)
            let span = sound.samples.dropFirst(2 * 48_000 * sound.channels).prefix(2 * 48_000 * sound.channels)
            let level = (span.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(span.count, 1))).squareRoot()
            #expect(level > 0.01, "the music sounds: \(level)")
            // Without the music the take has nothing to hear.
            let none = try? await decodedAudioChannels(of: silent)
            #expect(none.map { $0.samples.allSatisfy { abs($0) < 1e-3 } } ?? true)
        }
    }

    @Test(.enabled(if: metal)) func exportWritesNothingIntoThePackage() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let phase3 = try await APIFixtures.version4(in: dir)
            let withoutEdits = try await APIFixtures.package(in: dir, name: "New").package.url
            let gif = GIFSettings(longSide: 480, fps: 10, range: ExportRange(start: 0, end: 1_000_000_000))
            for url in [phase3, withoutEdits] {
                let before = try treeHash(url)
                let name = url.deletingPathExtension().lastPathComponent
                let project = try await TomaProject.open(url, mode: .read, environment: environment)
                _ = try await project.export(to: dir.appending(path: "\(name).mp4"), format: .video(small), progress: nil)
                _ = try await project.export(to: dir.appending(path: "\(name)"), format: .gif(gif), progress: nil)
                await project.close()
                #expect(try treeHash(url) == before, "\(name)")
                #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(name).gif").path))
            }
            #expect(!FileManager.default.fileExists(atPath: ProjectPackage(url: withoutEdits).editURL.path))
        }
    }

    @Test func exportIntoAPackageIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let other = try await APIFixtures.package(in: dir, name: "Other").package.url
            let link = dir.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            let before = (try treeHash(url), try treeHash(other))
            let project = try await TomaProject.open(url, mode: .read, environment: environment)
            for destination in [
                url.appending(path: "out.mp4"), url.appending(path: "takes/out.mp4"), other.appending(path: "out.mp4"),
                link.appending(path: "out.mp4"), dir.appending(path: "x/../Fixture.toma/out.mp4"),
            ] {
                let error = await APIFixtures.apiError {
                    _ = try await project.export(to: destination, format: .video(small), progress: nil)
                }
                #expect(error?.code == .refused, "\(destination.path)")
            }
            await project.close()
            #expect((try treeHash(url), try treeHash(other)) == before)
        }
    }

    @Test(.enabled(if: metal)) func gifNeedsNoSound() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            // Its theme is not in the library: a GIF never asks for it, nor for the voice it would duck under.
            _ = try await project.apply(.addMusic(theme: "calm", volume: nil))
            let format = try await project.format(for: ExportRequest(kind: .gif, size: 480, fps: 10))
            guard case var .gif(settings) = format else { Issue.record("\(format)"); return }
            settings.range = ExportRange(start: 0, end: 2_000_000_000)
            let result = try await project.export(to: dir.appending(path: "clip.gif"), format: .gif(settings), progress: nil)
            await project.close()
            #expect(result.format == "gif" && result.codec == nil && result.framesPerSecond == 10 && result.duration == 2)
            #expect(result.width == 480 && result.height == 270 && result.bytes > 0)
            let projectID = try LoadedProject.load(url).manifest.resolvedProjectID
            let caches = ProjectCaches(root: environment.cachesRoot, projectID: projectID)
            #expect(files(in: environment.musicRoot).allSatisfy { !$0.hasSuffix(".caf") })
            #expect(files(in: caches.folder(.ducking)).isEmpty && files(in: caches.folder(.loudness)).isEmpty)
        }
    }

    @Test(.enabled(if: metal)) func chaptersOfNamedMarkersAreInTheFile() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            _ = try await project.apply(.addMarker(at: 5, name: "Demo"))
            let format = try await project.format(for: ExportRequest())
            guard case var .video(settings) = format else { Issue.record("\(format)"); return }
            #expect(settings.chapters == [Chapter(start: 0, title: "Introducción"), Chapter(start: 5_000_000_000, title: "Demo")])
            #expect(settings.chapterLanguage == "es")
            settings.outputSize = small.outputSize
            settings.framesPerSecond = small.framesPerSecond
            let destination = dir.appending(path: "chapters.mp4")
            let result = try await project.export(to: destination, format: .video(settings), progress: nil)
            await project.close()
            #expect(result.chapters == 2)

            let asset = AVURLAsset(url: destination)
            let locale = try #require(try await asset.load(.availableChapterLocales).first)
            #expect(locale.language.languageCode?.identifier == "es")
            let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
            var titles: [String] = []
            for group in groups {
                let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
                titles.append(try await item?.load(.stringValue) ?? "")
            }
            #expect(titles == ["Introducción", "Demo"])
            #expect(groups.map { $0.timeRange.start.seconds } == [0, 5])
        }
    }

    @Test func requestMapsSizesAndCodecs() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let frameRate = project.document.frameRate

            guard case let .video(alpha) = try await project.format(for: ExportRequest(codec: "hevc-alpha")) else {
                Issue.record("not a video")
                return
            }
            #expect(alpha.codec == .hevcAlpha && alpha.outputSize == [1920, 1080] && alpha.framesPerSecond == frameRate)
            #expect(alpha.quality == .standard && alpha.chapters.isEmpty && alpha.chapterLanguage == nil)
            for (name, codec) in ExportRequest.codecs {
                guard case let .video(settings) = try await project.format(for: ExportRequest(codec: name)) else { continue }
                #expect(settings.codec == codec && ExportRequest.name(of: codec) == name)
            }

            _ = try await project.apply(.setAspect(.portrait))
            let request = ExportRequest(size: 1080, fps: 30, quality: "high")
            guard case let .video(portrait) = try await project.format(for: request) else {
                Issue.record("not a video")
                return
            }
            #expect(portrait.outputSize == [1080, 1920] && portrait.framesPerSecond == 30 && portrait.quality == .high)
            guard case let .gif(gif) = try await project.format(for: ExportRequest(kind: .gif)) else {
                Issue.record("not a GIF")
                return
            }
            // The GIF's size is its longer side: 800 by default, at 15 fps, of the whole output.
            #expect(gif.longSide == 800 && gif.fps == 15 && gif.quality == .balanced)
            #expect(gif.outputSize(project: project.project, document: project.document) == [450, 800])
            #expect(gif.range == ExportRange(start: 0, end: 10_000_000_000))
            guard case .externalEditor = try await project.format(for: ExportRequest(kind: .externalEditor)) else {
                Issue.record("not for an external editor")
                return
            }

            for request in [
                ExportRequest(codec: "vp9"), ExportRequest(size: 999), ExportRequest(fps: 120), ExportRequest(quality: "best"),
                ExportRequest(kind: .gif, size: 1000), ExportRequest(kind: .gif, fps: 60),
            ] {
                let error = await APIFixtures.apiError { _ = try await project.format(for: request) }
                #expect(error?.code == .invalidCommand, "\(request)")
            }
            // An extension that is not the codec's is refused before anything is prepared.
            var proRes = alpha
            proRes.codec = .proRes422
            let wrong = await APIFixtures.apiError {
                _ = try await project.export(to: dir.appending(path: "out.mp4"), format: .video(proRes), progress: nil)
            }
            #expect(wrong?.code == .invalidCommand)
            let gifAsMP4 = await APIFixtures.apiError {
                _ = try await project.export(to: dir.appending(path: "out.mp4"), format: .gif(gif), progress: nil)
            }
            #expect(gifAsMP4?.code == .invalidCommand)
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out.mp4").path))

            // The request as the command line and the MCP server send it: what is missing is its default.
            let decoded = try JSONDecoder().decode(ExportRequest.self, from: Data(#"{"kind":"gif","size":640}"#.utf8))
            #expect(decoded == ExportRequest(kind: .gif, size: 640))
            #expect(try JSONDecoder().decode(ExportRequest.self, from: Data("{}".utf8)) == ExportRequest())
            await project.close()
        }
    }

    /// HEVC with alpha and ProRes 4444 (milestone 4c) through the API: a QuickTime movie whose stage's background is
    /// transparent (Toma's style pads the screen, so a corner is background) and whose screen is opaque.
    @Test(.enabled(if: metal)) func alphaCodecsKeepTheTransparency() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .read, environment: environment)
            for name in ["hevc-alpha", "prores4444"] {
                guard case var .video(settings) = try await project.format(for: ExportRequest(codec: name)) else {
                    Issue.record("\(name): not a video")
                    continue
                }
                settings.outputSize = small.outputSize
                settings.framesPerSecond = small.framesPerSecond
                // Without an extension, the codec's.
                let result = try await project.export(to: dir.appending(path: name), format: .video(settings), progress: nil)
                #expect(result.path == dir.appending(path: "\(name).mov").path)
                #expect(result.format == "mov" && result.codec == name && result.width == 320 && result.height == 180)
                let frame = try #require(try await videoFrames(of: URL(fileURLWithPath: result.path)).first)
                func alpha(_ x: Int, _ y: Int) -> UInt8 { frame.bytes[(y * 320 + x) * 4 + 3] }
                // HEVC's alpha is lossy: at most 2 where there is nothing, at least 253 where the screen is.
                #expect(alpha(2, 2) <= 2 && alpha(317, 177) <= 2, "\(name): the corners are \(alpha(2, 2)), \(alpha(317, 177))")
                #expect(alpha(160, 90) >= 253, "\(name): the middle of the screen is \(alpha(160, 90))")
            }
            await project.close()
        }
    }

    @Test func externalEditorIsNotAvailableYet() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .read, environment: environment)
            let error = await APIFixtures.apiError {
                _ = try await project.export(to: dir.appending(path: "edit.mp4"), format: .externalEditor(small), progress: nil)
            }
            #expect(error?.code == .notAvailable)
            await project.close()
            let closed = await APIFixtures.apiError {
                _ = try await project.export(to: dir.appending(path: "late.mp4"), format: .video(small), progress: nil)
            }
            #expect(closed?.code == .refused)
        }
    }
}

// MARK: - Helpers

/// The progress an export reported, in order.
private final class Reports: Sendable {
    private let values = Mutex<[Double]>([])
    var all: [Double] { values.withLock { $0 } }
    func add(_ value: Double) { values.withLock { $0.append(value) } }
}

/// Writes theme `id` of the music library at `root` as the library keeps it (`MusicFile`, its 120 s at 48 kHz): a square
/// wave of 480 Hz, so the library has it and never synthesizes it.
private func writeTheme(_ id: String, in root: URL) throws {
    let library = MusicLibrary(root: root)
    let url = library.url(for: id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var samples = [Float](repeating: 0, count: MusicThemes.loopFrames * MusicFile.channels)
    samples.withUnsafeMutableBufferPointer { samples in
        for n in 0..<MusicThemes.loopFrames {
            let value: Float = (n / 50) % 2 == 0 ? 0.3 : -0.3
            samples[2 * n] = value
            samples[2 * n + 1] = value
        }
    }
    try MusicFile.write(interleaved: samples, to: url)
    #expect(library.cachedFile(for: id) == url)
}

/// A package of 10 s of one display and nothing else, as `APIFixtures.package` makes it without its microphone.
@concurrent private func screenOnly(in dir: URL) async throws -> URL {
    let builder = try TakeBuilder(in: dir, name: "Screen")
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    try await builder.addVideoTrack(
        id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
        segments: [VideoSegmentSpec(start: APIFixtures.base, seconds: 10, framesPerSecond: 10, width: 320, height: 180)])
    try builder.addEvents([
        InputEvent(t: APIFixtures.base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1)),
    ])
    return try builder.write().package.url
}

/// Every name under `folder`; none if it is not there.
private func files(in folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    return (enumerator.allObjects as? [String] ?? []).sorted()
}

/// A decoded frame: its time and its BGRA bytes, without the rows' padding.
private struct VideoFrame: Sendable {
    var time: Double
    var bytes: [UInt8]
}

/// Every decoded frame of the movie at `url`, in presentation order.
private func videoFrames(of url: URL) async throws -> [VideoFrame] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let settings: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    return try await readTrack(track, of: asset, outputSettings: settings, into: [VideoFrame]()) { frames, sample in
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { bytes.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: y * row), count: width * 4)) }
        frames.append(VideoFrame(time: sample.presentationTimeStamp.seconds, bytes: bytes))
    }
}

/// Where `a` and `b` first differ, for the message of a failed comparison.
private func frameDifference(_ a: [VideoFrame], _ b: [VideoFrame]) -> String {
    guard a.count == b.count else { return "\(a.count) frames and \(b.count)" }
    var worst = (frame: -1, mean: 0.0, times: (0.0, 0.0))
    for (k, (a, b)) in zip(a, b).enumerated() where a.bytes != b.bytes || a.time != b.time {
        let difference = zip(a.bytes, b.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        let mean = Double(difference) / Double(max(a.bytes.count, 1))
        if mean >= worst.mean { worst = (k, mean, (a.time, b.time)) }
    }
    return worst.frame < 0 ? "the same" : "most apart: frame \(worst.frame) at \(worst.times), mean difference \(worst.mean)"
}

/// Whether `a` and `b` are the same frames decoded: at the same times and alike to a level on average. Not byte for byte:
/// two exports of the same frames can get VideoToolbox's hardware encoder or its software one (when the media engine
/// has no session left, as when many tests export at once), whose bitstreams decode a level or a few apart.
private func sameFrames(_ a: [VideoFrame], _ b: [VideoFrame]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { a, b in
        guard a.time == b.time, a.bytes.count == b.bytes.count else { return false }
        if a.bytes == b.bytes { return true }
        let difference = zip(a.bytes, b.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(a.bytes.count) < 1
    }
}
