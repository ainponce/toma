// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `FrameRenderer.render(at:into:completion:)`'s pixel buffers and
// `frame(of:at:)`, `PreviewEngine`'s hooks and `PreviewPreparation.prepare`'s document.
@testable import Render
import Synchronization
import Testing

/// Each clip of a sequence drawn from its own take (phase 3 design §9, base plan task B7): with one take, the scene of a
/// project is phase 2's scene; with two, each clip draws its take as that take alone does (its screens, its cursor, its
/// zoom, whose path cuts at the border), the frame of another take says which, the renderer reads each take's tracks
/// apart however alike their ids, lists the missing video of every take, and the preview draws what the export draws.

/// The frames per second the frames of these tests are on, the legacy document's.
private let rate = 60

/// The output second of frame `n` of the grid of `rate`.
private func seconds(_ n: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9 }

/// `MultiTakeFixtures.twoTakes` focused on its first take, `take-001`, so `take-002` is the other one.
private func twoTakes(in dir: URL) async throws -> LoadedProject {
    try #require(try await MultiTakeFixtures.twoTakes(in: dir).focused(on: "take-001"))
}

/// Where the legacy clip of take `take` of `project` starts: what `MultiTakeFixtures.sequence(of:_:)` counts from.
private func legacyStart(of take: String, in project: LoadedProject) throws -> HostTime {
    let focused = try #require(project.focused(on: take))
    return try #require(EditDocument.legacy(for: focused).sequence.first?.start)
}

/// A manual zoom block of take `take`, from `from` to `to` s of its legacy clip, at `depth` on a fixed point.
private func zoomBlock(
    _ number: Int, take: String, from: Double, to: Double, depth: Double, at point: SIMD2<Double>, in project: LoadedProject
) throws -> ZoomRegion {
    let start = try legacyStart(of: take, in: project)
    return ZoomRegion(
        id: "z-" + String(format: "%08x", number), take: take, start: start.adding(seconds: from), end: start.adding(seconds: to),
        origin: .user, depth: depth, focus: .fixed(x: point.x, y: point.y), instant: false)
}

@Suite struct MultiTakeRenderTests {
    /// Every case of golden 3 (its recorded document, migrated): the scene of its project (`init(project:document:…)`)
    /// is the scene of its take alone (`init(take:events:document:…)`), frame for frame, at its times and along its
    /// output, at its size and resized; no frame names a take, and the paths are its take's alone.
    @Test func singleTakeSceneIsThePhase2Scene() async throws {
        try await withTemporaryDirectory { dir in
            for golden in GoldenDocuments.golden3Cases {
                let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
                let made = try GoldenDocuments.makeDocument(golden.name, for: project)
                let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
                let size = GoldenDocuments.outputSize(of: golden, document: document, project: project)
                let readable = LayoutTimeline.cameraReadable(take: project.take) {
                    SegmentAvailability.classify($0, in: project.package)
                }
                let alone = FrameEvaluator(
                    take: project.take, events: project.events, document: document, outputSize: size, cameraReadable: readable)
                let scene = FrameEvaluator(
                    project: project, document: document, outputSize: size, cameraReadable: [project.take.id: readable])
                let paths = SequencePaths(project: project, document: document, cameraReadable: [project.take.id: readable])
                let withPaths = FrameEvaluator(
                    project: project, document: document, outputSize: size, paths: paths,
                    cameraReadable: [project.take.id: readable])
                #expect(scene.takes == [project.take.id], "\(golden.name)")
                #expect(Array(paths.byTake.keys) == [project.take.id], "\(golden.name)")
                #expect(Array(scene.sequencePaths.byTake.keys) == [project.take.id], "\(golden.name)")
                let duration = alone.duration
                let along = (0..<8).map { duration * Double($0) / 8 }
                let half = SIMD2(size.x / 2, size.y / 2)
                for time in golden.times + along {
                    let frame = scene.frame(at: time)
                    let at = "\(golden.name) at \(time) s"
                    #expect(frame == alone.frame(at: time), "\(at)")
                    #expect(withPaths.frame(at: time) == frame, "\(at)")
                    #expect(frame.take == nil, "\(at)")
                    #expect(scene.resized(to: half).frame(at: time) == alone.resized(to: half).frame(at: time), "\(at), resized")
                }
            }
        }
    }

    /// [take-001 0–2 s, take-002 0.5–2.5 s]: every frame of the first clip is the frame of [take-001 0–2] alone, and every
    /// frame of the second the frame of [take-002 0.5–2.5] alone 2 s earlier, marked `take-002`; whichever take the
    /// project is focused on, the frames are the same, but for which they name.
    @Test func twoTakesDrawEachTakeAsAlone() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let size = SIMD2(640, 360)
            let both = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let scene = FrameEvaluator(project: project, document: both, outputSize: size)
            #expect(scene.takes == ["take-001", "take-002"])
            #expect(Set(scene.sequencePaths.byTake.keys) == ["take-001", "take-002"])
            let first = FrameEvaluator(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), outputSize: size)
            let second = FrameEvaluator(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-002", 0.5, 2.5)]), outputSize: size)
            #expect(first.takes == ["take-001"] && second.takes == ["take-001", "take-002"])
            // The other way round: the project focused on take-002, the take of the second clip.
            let other = try #require(project.focused(on: "take-002"))
            let otherScene = FrameEvaluator(project: other, document: both, outputSize: size)
            #expect(otherScene.takes == ["take-002", "take-001"])
            for n in 0..<240 {
                let frame = scene.frame(at: seconds(n))
                let at = "frame \(n)"
                #expect(frame.screen != nil && frame.cursor != nil, "\(at)")
                if n < 120 {
                    #expect(frame == first.frame(at: seconds(n)), "\(at)")
                    #expect(frame.take == nil, "\(at)")
                } else {
                    #expect(frame == second.frame(at: seconds(n - 120)), "\(at)")
                    #expect(frame.take == "take-002", "\(at)")
                }
                var named = otherScene.frame(at: seconds(n))
                #expect(named.take == (n < 120 ? "take-001" : nil), "\(at)")
                named.take = frame.take
                #expect(named == frame, "\(at), focused on take-002")
            }
        }
    }

    /// A zoom block in each take, take-001's still zoomed at the border: the take-002 clip starts at rest, and every frame of
    /// it, its zoom included, is the frame of take-002 alone; take-001's clip is take-001 alone's too.
    @Test func zoomPathCutsAtTheTakeBorder() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let size = SIMD2(640, 360)
            let blocks = [
                try zoomBlock(1, take: "take-001", from: 1.2, to: 2.0, depth: 2, at: [0.3, 0.4], in: project),
                try zoomBlock(2, take: "take-002", from: 1.5, to: 2.5, depth: 2.5, at: [0.7, 0.6], in: project),
            ]
            func document(_ pieces: [(take: String, from: Double, to: Double)]) -> EditDocument {
                var document = MultiTakeFixtures.sequence(of: project, pieces)
                document.zoom.regions = blocks
                return document
            }
            let scene = FrameEvaluator(
                project: project, document: document([("take-001", 0, 2), ("take-002", 0.5, 2.5)]), outputSize: size)
            let first = FrameEvaluator(project: project, document: document([("take-001", 0, 2)]), outputSize: size)
            let second = FrameEvaluator(project: project, document: document([("take-002", 0.5, 2.5)]), outputSize: size)
            // Zoomed in at the end of the first clip, at rest at the start of the second.
            #expect((scene.frame(at: seconds(119)).stage?.depth ?? 1) > 1.5)
            #expect(scene.frame(at: seconds(120)).stage == nil)
            #expect((scene.frame(at: seconds(220)).stage?.depth ?? 1) > 1.5)
            for n in 0..<240 {
                let frame = scene.frame(at: seconds(n))
                let alone = n < 120 ? first.frame(at: seconds(n)) : second.frame(at: seconds(n - 120))
                #expect(frame == alone, "frame \(n)")
            }
        }
    }

    /// Both takes have `display-1`: the renderer of the sequence of both draws at 1 s and at 3 s what a renderer of each
    /// take alone, the project focused on it (phase 2's way: its own take), draws at 1 s, back and forth, and the two
    /// frames differ, so neither take is read through the other's reader; through the export's way of drawing
    /// (`render(at:into:completion:)`, decoding ahead) as well.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func readersAreKeptApartByTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let size = SIMD2(320, 180)
            let both = try FrameRenderer(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)]),
                outputSize: size)
            let first = try FrameRenderer(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), outputSize: size)
            let own = try #require(project.focused(on: "take-002"))
            let second = try FrameRenderer(
                project: own, document: MultiTakeFixtures.sequence(of: own, [("take-002", 0.5, 2.5)]), outputSize: size)
            let (one, three, oneAgain, threeAgain, alone1, alone2) = try await offThePool {
                (
                    try both.renderBytes(at: 1), try both.renderBytes(at: 3), try both.renderBytes(at: 1), try both.renderBytes(at: 3),
                    try first.renderBytes(at: 1), try second.renderBytes(at: 1)
                )
            }
            #expect(one == alone1 && oneAgain == alone1)
            #expect(three == alone2 && threeAgain == alone2)
            #expect(one != three)
            #expect(both.missingVideo.isEmpty)
            // The export's way, over the border: the same frames.
            let exported = try await exportBytes(both, frames: [60, 180], through: 181)
            #expect(exported[60] == alone1 && exported[180] == alone2)
        }
    }

    /// take-002's segment of `display-1` is gone: its gap is listed in the output of the second clip, where it is shown,
    /// and nothing of take-001, whose `display-1` is whole, before or after drawing every frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func missingVideoListsEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let segment = try #require(project.focused(on: "take-002")?.take.track("display-1")?.segments.first)
            try FileManager.default.removeItem(at: project.package.fileURL(segment.file))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [320, 180])
            let gap = MissingVideo(track: "display-1", file: segment.file, start: 2, end: 4, reason: .fileMissing)
            #expect(renderer.missingVideo == [gap])
            try await offThePool {
                for n in stride(from: 0, to: 240, by: 6) { _ = try renderer.renderBytes(at: seconds(n)) }
            }
            #expect(renderer.missingVideo == [gap])
            // Take-001 alone has nothing missing.
            let first = try FrameRenderer(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), outputSize: [320, 180])
            #expect(first.missingVideo.isEmpty)
        }
    }

    /// The preview (`PreviewRenderer.snapshot`) draws at 1.9 s and 2.1 s, either side of the border between the takes, the
    /// bytes the export draws there along the grid (`render(at:into:completion:)`, decoding ahead over the border): those
    /// of each take alone, drawn by a renderer of the project focused on it.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func previewEqualsExportWithTwoTakes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let size = SIMD2(320, 180)
            let export = try FrameRenderer(project: project, document: document, outputSize: size)
            let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, document: document, outputSize: size))
            // 1.9 s and 2.1 s are frames 114 and 126 of the grid of 60 per second.
            let exported = try await exportBytes(export, frames: [114, 126], through: 127)
            let previewed = try await offThePool { (try preview.snapshot(at: seconds(114)), try preview.snapshot(at: seconds(126))) }
            #expect(exported[114] == previewed.0)
            #expect(exported[126] == previewed.1)
            #expect(previewed.0 != previewed.1)
            let own = try #require(project.focused(on: "take-002"))
            let second = try FrameRenderer(
                project: own, document: MultiTakeFixtures.sequence(of: own, [("take-002", 0.5, 2.5)]), outputSize: size)
            let first = try FrameRenderer(
                project: project, document: MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)]), outputSize: size)
            let alone = try await offThePool { (try first.renderBytes(at: seconds(114)), try second.renderBytes(at: seconds(6))) }
            #expect(previewed.0 == alone.0 && previewed.1 == alone.1)
        }
    }

    /// A frame of another take reads its camera's person's mask by a reader id of that take, `personMask:<take>/<file>`:
    /// the caches name every take's mask of a segment alike (`<segment>-personMask-1.mov`), and the frames of the
    /// project's own take keep phase 2's id. Nothing else of the frame changes.
    @Test func anotherTakesMaskIsReadApart() {
        let file = URL(fileURLWithPath: "/caches/masks/take-002/camera-1/0-personMask-1.mov")
        let mask = PersonMaskSource(
            file: file, segmentStart: HostTime(nanoseconds: 0), segmentEnd: nil, time: HostTime(nanoseconds: 5),
            readerID: "personMask:" + file.lastPathComponent)
        var frame = RenderFrame(outputSize: [16, 9], gradientStart: .zero, gradientEnd: .zero, gradientAngleDegrees: 0)
        frame.camera = CameraLayer(
            trackID: "camera-1", sourceTime: HostTime(nanoseconds: 5), rect: Rect(x: 0, y: 0, width: 4, height: 4), cornerRadius: 0,
            background: CameraBackgroundLayer(mode: .blurred, mask: mask, overScene: false))
        let apart = FrameEvaluator.keptApart(frame, take: "take-002")
        #expect(apart.take == "take-002")
        #expect(apart.camera?.background?.mask.readerID == "personMask:take-002/0-personMask-1.mov")
        var same = apart
        same.take = nil
        same.camera?.background?.mask.readerID = mask.readerID
        #expect(same == frame)
    }

    /// A take the edited document shows that is still marked `recording` is refused, whichever take the project is focused
    /// on: the legacy document of take-001, and a document of take-001 alone, are prepared; one that shows take-002 too
    /// is not.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func previewPreparationRefusesEveryTakeShownRecording() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            var manifest = project.manifest
            let index = try #require(manifest.takes.firstIndex { $0.id == "take-002" })
            manifest.takes[index].status = .recording
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: project.package.manifestURL)
            let url = project.package.url
            let both = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            await #expect(throws: PreviewPreparationError.unfinished(takeID: "take-002")) {
                try await PreviewPreparation.prepare(url: url, take: "take-001", outputSize: [320, 180], document: both)
            }
            let legacy = try await PreviewPreparation.prepare(url: url, take: "take-001", outputSize: [320, 180])
            #expect(abs(legacy.duration - 4) < 0.05)
            let first = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            let alone = try await PreviewPreparation.prepare(url: url, take: "take-001", outputSize: [320, 180], document: first)
            #expect(abs(alone.duration - 2) < 0.05)
        }
    }

    /// Only take-002 recorded a cursor image: a frame of its clip draws it (`CursorImageRef.recorded`), read from its own
    /// folder (`takes/take-002/cursors/`), as take-002 alone draws it; take-001's clip draws Toma's arrow.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cursorImagesAreEachTakes() async throws {
        try await withTemporaryDirectory { dir in
            let (project, hash) = try await twoTakesWithACursorImage(in: dir)
            let size = SIMD2(320, 180)
            func systemCursor(_ document: EditDocument) -> EditDocument {
                var document = document
                document.cursor.style = .system
                return document
            }
            let renderer = try FrameRenderer(
                project: project,
                document: systemCursor(MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1.5), ("take-002", 0, 1.5)])),
                outputSize: size)
            let own = try #require(project.focused(on: "take-002"))
            let alone = try FrameRenderer(
                project: own, document: systemCursor(MultiTakeFixtures.sequence(of: own, [("take-002", 0, 1.5)])), outputSize: size)
            let first = try renderer.frame(of: renderer.scene, at: 0.5)
            let second = try renderer.frame(of: renderer.scene, at: 2.0)
            #expect(first.take == nil && first.cursor?.image == .toma(.arrow))
            #expect(second.take == "take-002" && second.cursor?.image == .recorded(hash: hash))
            let (drawn, ownDrawn) = try await offThePool { (try renderer.renderBytes(at: 2.0), try alone.renderBytes(at: 0.5)) }
            #expect(drawn == ownDrawn)
        }
    }

    /// The preview engine, playing over the border between the takes, scrubbing and pausing on either side: every frame of
    /// a take shows that take's video, never the other's of the same track id (the engine's frames last shown and the
    /// prefetchers are by take and track). With take-002's video gone, a frame of it shows none, not the frame of
    /// take-001 shown before it.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func previewEngineShowsEachTakesOwnVideo() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let requests: [PreviewRequest] = [.scrubbing(seconds: 1.5), .scrubbing(seconds: 2.6), .scrubbing(seconds: 1.0)]
                + (100...140).map { .playing(seconds: seconds($0)) } + [.paused(frame: 150), .paused(frame: 60), .scrubbing(seconds: 3.2)]

            let watched = EngineFrames(try FrameRenderer(project: project, document: document, outputSize: [640, 360]))
            try await watched.draw(requests)
            var shownOfTake2 = 0
            for drawn in watched.drawn {
                let take = drawn.frame.take, at = "\(drawn.request), take \(take ?? "take-001")"
                guard let video = drawn.videos["display-1"] else { continue }
                // take-001's frames are blue (200), take-002's inverted (55).
                #expect((centreBlue(of: video) > 128) == (take == nil), "\(at)")
                if take == "take-002" { shownOfTake2 += 1 }
            }
            #expect(shownOfTake2 >= 10, "frames of take-002 with its video: \(shownOfTake2)")

            // take-002's video gone: its frames show none.
            let segment = try #require(project.focused(on: "take-002")?.take.track("display-1")?.segments.first)
            try FileManager.default.removeItem(at: project.package.fileURL(segment.file))
            let gone = EngineFrames(try FrameRenderer(project: project, document: document, outputSize: [640, 360]))
            try await gone.draw(requests)
            #expect(gone.drawn.contains { $0.frame.take == nil && $0.videos["display-1"] != nil })
            for drawn in gone.drawn where drawn.frame.take == "take-002" {
                #expect(drawn.videos["display-1"] == nil, "\(drawn.request)")
            }
            #expect(gone.drawn.filter { $0.frame.take == "take-002" }.count >= 20)
        }
    }

    /// The paths of a scene of both takes, given again: kept for a revision that changes nothing they read, each take's
    /// built again for one that does, and the scene made with them the scene made without.
    @Test func sequencePathsKeepEachTakesPaths() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakes(in: dir)
            let size = SIMD2(320, 180)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let paths = SequencePaths(project: project, document: document, cameraReadable: [:])
            #expect(Set(paths.byTake.keys) == ["take-001", "take-002"] && paths.areThePaths(of: document))
            var shadowed = document
            shadowed.style.shadow = 0.5
            #expect(paths.areThePaths(of: shadowed))
            var cut = document
            cut.sequence[1].end = cut.sequence[1].end.adding(seconds: -0.5)
            #expect(!paths.areThePaths(of: cut))
            let again = SequencePaths(project: project, document: cut, cameraReadable: [:], reusing: paths)
            #expect(again.areThePaths(of: cut))
            let scene = FrameEvaluator(project: project, document: cut, outputSize: size)
            let made = FrameEvaluator(project: project, document: cut, outputSize: size, paths: again)
            for n in stride(from: 0, to: 210, by: 5) {
                #expect(made.frame(at: seconds(n)) == scene.frame(at: seconds(n)), "frame \(n)")
            }
        }
    }
}

/// Draws frames `0..<count` of `renderer`'s scene as the export does (`render(at:into:completion:)`: queued one after the
/// other along the grid of `rate`, each decoded ahead through the prefetchers), waiting for each, and returns the bytes of
/// those of `frames`.
private func exportBytes(_ renderer: FrameRenderer, frames: Set<Int>, through count: Int) async throws -> [Int: [UInt8]] {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    #expect(status == kCVReturnSuccess)
    let target = MultiTakePixelBuffer(try #require(created))
    var bytes: [Int: [UInt8]] = [:]
    for n in 0..<count {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            renderer.render(at: seconds(n), into: target.pixelBuffer) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
        if frames.contains(n) { bytes[n] = packedBytes(of: target.pixelBuffer) }
    }
    return bytes
}

private final class MultiTakePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// Two takes of `display-1` (4 s and 3 s of `SampleFactory`'s pattern, 60 s apart) with the cursor moving over it, the
/// project focused on take-001; only take-002 recorded a cursor image (a red one of 24 × 32 pt, as it starts), whose hash
/// is returned.
private func twoTakesWithACursorImage(in dir: URL) async throws -> (LoadedProject, String) {
    let screen = Rect(x: 0, y: 0, width: 640, height: 360)
    let start = HostTime(nanoseconds: 5_000_000_000_000)
    func record(into builder: TakeBuilder, from start: HostTime, seconds: Double) async throws {
        try await builder.addVideoTrack(
            id: "display-1", source: displaySource(globalFrame: screen), segments: [VideoSegmentSpec(start: start, seconds: seconds)])
        try builder.addEvents([
            InputEvent(t: start.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: screen, scale: 1))
        ])
        try builder.addEvents(cursorEvents(from: start, seconds: seconds, across: screen))
    }
    let first = try TakeBuilder(in: dir, name: "Cursors")
    try await record(into: first, from: start, seconds: 4)
    _ = try first.write()
    let second = try TakeBuilder(appendingTo: first.package, take: "take-002")
    let secondStart = start.adding(seconds: 60)
    try await record(into: second, from: secondStart, seconds: 3)
    let hash = try second.addCursorImage(try solidPNG(width: 48, height: 64), hotspot: [0.5, 0.5], size: [24, 32], at: secondStart)
    _ = try second.write()
    return (try LoadedProject.load(first.package.url, take: "take-001"), hash)
}

/// A PNG of `width` × `height` opaque red pixels.
private func solidPNG(width: Int, height: Int) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// The blue of the pixel at the centre of `pixelBuffer` (32BGRA): away from the white square of `SampleFactory`'s
/// pattern, which runs along the top row.
private func centreBlue(of pixelBuffer: CVPixelBuffer) -> UInt8 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
    let x = CVPixelBufferGetWidth(pixelBuffer) / 2, y = CVPixelBufferGetHeight(pixelBuffer) / 2
    return base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4).assumingMemoryBound(to: UInt8.self).pointee
}

/// What the engine's callbacks take first, so ThreadSanitizer sees them ordered after the engine was made (as
/// `PreviewEngineTests`' `Watched` does).
private let engineFramesPublished = Mutex(())

/// A preview engine of `renderer`, drawing into a layer of 320 × 180, and the frames it drew.
private final class EngineFrames: @unchecked Sendable {
    let engine: PreviewEngine
    let layer = CAMetalLayer()
    private let lock = NSLock()
    private var frames: [PreviewEngine.DrawnFrame] = []

    init(_ renderer: FrameRenderer) {
        CATransaction.begin()
        layer.drawableSize = CGSize(width: 320, height: 180)
        CATransaction.commit()
        engine = PreviewEngine(renderer: renderer, layer: layer)
        engine.hooks.onDrawn = { [self] frame in
            engineFramesPublished.withLock { _ in }
            lock.withLock { frames.append(frame) }
        }
        engineFramesPublished.withLock { _ in }
    }

    var drawn: [PreviewEngine.DrawnFrame] { lock.withLock { frames } }

    /// Asks for each of `requests` in order, once the one before it is drawn.
    func draw(_ requests: [PreviewRequest]) async throws {
        for (k, request) in requests.enumerated() {
            engine.request(request)
            try #require(await eventually(timeout: .seconds(30)) { self.drawn.count > k }, "\(request) drawn")
        }
    }
}
