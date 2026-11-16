// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import RecorderKitTestSupport
import Testing
// @testable only for `ThumbnailCache.generations` and `WaveformCache.decodedSegments`, which count what was decoded: the
// rest is the public API the timeline uses.
@testable import Editing
import ProjectFormat

/// What the tests of the thumbnail and waveform caches share. Nothing here reads video on Swift's cooperative pool: the
/// caches decode off it themselves, and the builder writes without decoding.
enum CacheFixture {
    static let base = HostTime(nanoseconds: 7_000_000_000_000)
    static let screen = Rect(x: 0, y: 0, width: 640, height: 360)

    /// A take of one display (640×360 at 30 fps, `videoSeconds` from `base`) and a microphone playing the builder's
    /// 440 Hz sine at 1/4 of full scale in `audio` (1 s from `base` by default), in a new package of `formatVersion`.
    static func package(
        in dir: URL, formatVersion: Int = 3, videoSeconds: Double = 1, audio: [AudioSegmentSpec]? = nil
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: screen, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: videoSeconds)])
        try await builder.addAudioTrack(
            id: "mic-1", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic"),
            segments: audio ?? [AudioSegmentSpec(start: base, seconds: 1)])
        return try builder.write()
    }

    /// The caches of `project` in `dir/Caches`.
    static func caches(_ project: LoadedProject, in dir: URL) -> ProjectCaches {
        ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
    }

    /// The width and height of `image`, in pixels.
    static func size(of image: CGImage) -> [Int] {
        [image.width, image.height]
    }

    /// The frame of the fixture's recording that `image` shows: the one whose `SampleFactory` colour (R = 32·(i % 8),
    /// G = 32·((i / 8) % 8), B = 200) is nearest to a pixel near its bottom-right corner, away from the moving square.
    static func frame(of image: CGImage) throws -> Int {
        let (width, height) = (image.width, image.height)
        let context = try unwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try unwrap(CGColorSpace(name: CGColorSpace.sRGB), "sRGB"), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            "a context")
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try unwrap(context.data, "the pixels").assumingMemoryBound(to: UInt8.self)
        // The context's first row is the image's top one.
        let at = ((height - 2) * width + width - 2) * 4
        let pixel = SIMD3<Int>(Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
        func distance(_ i: Int) -> Int {
            let d = pixel &- SIMD3(32 * (i % 8), 32 * ((i / 8) % 8), 200)
            return (d &* d).wrappedSum()
        }
        return (0..<64).min { distance($0) < distance($1) }!
    }

    /// The names of the files in `folder`, sorted; none if it is not there.
    static func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

@Test func thumbnailIsGeneratedOnceAndCached() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let cache = ThumbnailCache(project: project, caches: caches)
        let half = CacheFixture.base.adding(seconds: 0.5)

        let first = try #require(await cache.thumbnail(track: "display-1", source: half, height: 90))
        let second = try #require(await cache.thumbnail(track: "display-1", source: half, height: 90))
        #expect(await cache.generations == 1)
        #expect(CacheFixture.size(of: first) == [160, 90])
        #expect(CacheFixture.size(of: second) == [160, 90])
        // The recording's frame 15 (0.5 s at 30 fps) or one up to 0.5 s before it, never one after it.
        #expect((0...15).contains(try CacheFixture.frame(of: first)))
        #expect(try CacheFixture.frame(of: second) == CacheFixture.frame(of: first))
        #expect(CacheFixture.files(in: caches.thumbnails) == ["take-001-display-1-seg-0001-500-90.png"])

        // Another cache of the project (the window opened again) reads it from the file.
        let reopened = ThumbnailCache(project: project, caches: caches)
        let read = try #require(await reopened.thumbnail(track: "display-1", source: half, height: 90))
        #expect(CacheFixture.size(of: read) == [160, 90])
        #expect(await reopened.generations == 0)

        // Two requests at once for one thumbnail decode it once.
        let shared = ThumbnailCache(project: project, caches: caches)
        let later = CacheFixture.base.adding(seconds: 0.8)
        async let a = shared.thumbnail(track: "display-1", source: later, height: 90)
        async let b = shared.thumbnail(track: "display-1", source: later, height: 90)
        let (x, y) = await (a, b)
        #expect(await shared.generations == 1)
        // Frame 24, or one up to 0.5 s (15 frames) before it.
        #expect((9...24).contains(try CacheFixture.frame(of: try #require(x))))
        #expect(try CacheFixture.frame(of: try #require(y)) == CacheFixture.frame(of: try #require(x)))
        #expect(CacheFixture.files(in: caches.thumbnails).contains("take-001-display-1-seg-0001-800-90.png"))
    }
}

@Test func noThumbnailWhereThereIsNoScreenRecording() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let cache = ThumbnailCache(project: project, caches: caches)
        let half = CacheFixture.base.adding(seconds: 0.5)
        #expect(await cache.thumbnail(track: "mic-1", source: half, height: 90) == nil)
        #expect(await cache.thumbnail(track: "display-9", source: half, height: 90) == nil)
        #expect(await cache.thumbnail(track: "display-1", source: CacheFixture.base.adding(seconds: -0.1), height: 90) == nil)
        #expect(await cache.thumbnail(track: "display-1", source: CacheFixture.base.adding(seconds: 1.5), height: 90) == nil)
        #expect(await cache.thumbnail(track: "display-1", source: half, height: 0) == nil)
        #expect(await cache.thumbnail(track: "display-1", source: half, height: ThumbnailCache.maxHeight + 1) == nil)
        #expect(await cache.generations == 0)
        #expect(CacheFixture.files(in: caches.thumbnails).isEmpty)
    }
}

@Test func cachesNeverGoIntoThePackage() async throws {
    try await withTemporaryDirectory { dir in
        // A version 2 package, which nothing may write in until it is edited.
        let project = try await CacheFixture.package(in: dir, formatVersion: 2)
        let caches = CacheFixture.caches(project, in: dir)
        let before = try treeHash(project.package.url)

        let thumbnails = ThumbnailCache(project: project, caches: caches)
        for seconds in [0.1, 0.5, 0.9] {
            #expect(await thumbnails.thumbnail(track: "display-1", source: CacheFixture.base.adding(seconds: seconds), height: 56) != nil)
        }
        #expect(await WaveformCache(project: project, caches: caches).waveform(track: "mic-1").pairs.count == 100)

        #expect(try treeHash(project.package.url) == before)
        #expect(CacheFixture.files(in: caches.thumbnails).count == 3)
        #expect(CacheFixture.files(in: caches.waveforms) == ["take-001-mic-1-seg-0001.bin"])
    }
}

@Test func emptiedCachesAreRegenerated() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let thumbnails = ThumbnailCache(project: project, caches: caches)
        let waveforms = WaveformCache(project: project, caches: caches)
        let half = CacheFixture.base.adding(seconds: 0.5)
        #expect(await thumbnails.thumbnail(track: "display-1", source: half, height: 90) != nil)
        let waveform = await waveforms.waveform(track: "mic-1")
        #expect(waveform.pairs.count == 100)

        // macOS empties the caches folder while the window is open.
        try FileManager.default.removeItem(at: caches.directory)

        #expect(await thumbnails.thumbnail(track: "display-1", source: half, height: 90) != nil)
        #expect(await waveforms.waveform(track: "mic-1") == waveform)
        #expect(await thumbnails.generations == 2)
        #expect(await waveforms.decodedSegments == 2)
        #expect(CacheFixture.files(in: caches.thumbnails) == ["take-001-display-1-seg-0001-500-90.png"])
        #expect(CacheFixture.files(in: caches.waveforms) == ["take-001-mic-1-seg-0001.bin"])
    }
}

@Test func cancelledRequestsGetNothingAndLeaveTheCachesWorking() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let thumbnails = ThumbnailCache(project: project, caches: caches)
        let waveforms = WaveformCache(project: project, caches: caches)
        let half = CacheFixture.base.adding(seconds: 0.5)

        let thumbnail = Task { await thumbnails.thumbnail(track: "display-1", source: half, height: 90) }
        let waveform = Task { await waveforms.waveform(track: "mic-1") }
        thumbnail.cancel()
        waveform.cancel()
        #expect(await thumbnail.value == nil)
        #expect(await waveform.value.pairs.isEmpty)

        // Whatever the cancelled work had done, the next request gets the whole result.
        #expect(await thumbnails.thumbnail(track: "display-1", source: half, height: 90) != nil)
        #expect(await waveforms.waveform(track: "mic-1").pairs.count == 100)
        #expect(CacheFixture.files(in: caches.thumbnails) == ["take-001-display-1-seg-0001-500-90.png"])
        #expect(CacheFixture.files(in: caches.waveforms) == ["take-001-mic-1-seg-0001.bin"])
    }
}

@Test func aTakeWithIDsNoManifestMayHaveGetsNoCaches() async throws {
    try await withTemporaryDirectory { dir in
        var project = try await CacheFixture.package(in: dir)
        // A track id that would name a file outside the cache folder: `LoadedProject.load` refuses such a manifest, and
        // the caches do not trust a take handed to them either.
        for i in project.take.tracks.indices { project.take.tracks[i].id = "../../" + project.take.tracks[i].id }
        let caches = CacheFixture.caches(project, in: dir)
        let half = CacheFixture.base.adding(seconds: 0.5)
        #expect(await ThumbnailCache(project: project, caches: caches).thumbnail(track: "../../display-1", source: half, height: 90) == nil)
        #expect(await WaveformCache(project: project, caches: caches).waveform(track: "../../mic-1").pairs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: caches.directory.path))
    }
}
