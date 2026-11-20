// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for the renderer's readers, prefetchers and drawing along the grid, and the preview engine's hooks.
@testable import Render
import Synchronization
import Testing

/// The videos of other takes than the project's own are let go once the frames drawn and coming no longer show them
/// (phase 3 design §9; the final review of the render): each one's prefetcher with its frames, and its reader's
/// `AVAssetReader` with the frames read ahead, as the export draws on, frame by frame and in the preview; the reader
/// itself stays, for what it could not read (`FrameRenderer.missingVideo`). The project's own take is never let go, so a
/// single take draws as ever and the preview does not open its readers again on every frame.

/// The frames per second these tests draw at.
private let rate = 30

/// The output second of frame `n`.
private func seconds(_ n: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9 }

/// `MultiTakeFixtures.twoTakes` with two more takes appended, `take-003` and `take-004` (2 s of `display-1` each, 60 s
/// apart), focused on the last one, `take-004`, as the editor is after re-recording: the sequence A|B|C|D shows a second of
/// each, the project's own last.
private func fourTakes(in dir: URL) async throws -> LoadedProject {
    let two = try await MultiTakeFixtures.twoTakes(in: dir)
    let screen = Rect(x: 0, y: 0, width: 640, height: 360)
    for (k, take) in ["take-003", "take-004"].enumerated() {
        let builder = try TakeBuilder(appendingTo: two.package, take: take)
        let start = HostTime(nanoseconds: 5_000_000_000_000).adding(seconds: 120 + 60 * Double(k))
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display 1", displayID: 1, globalFrame: screen, pixelScale: 1),
            segments: [VideoSegmentSpec(start: start, seconds: 2)])
        try builder.addEvents([
            InputEvent(t: start.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: screen, scale: 1))
        ])
        _ = try builder.write()
    }
    return try LoadedProject.load(two.package.url)
}

/// The sequence of a second of each take, in order: A (take-001) 0–1 s, B 1–2 s, C 2–3 s and D, the project's own, 3–4 s.
private func everyTake(_ project: LoadedProject) -> EditDocument {
    MultiTakeFixtures.sequence(
        of: project, [("take-001", 0, 1), ("take-002", 0.5, 1.5), ("take-003", 0, 1), ("take-004", 0.5, 1.5)])
}

/// Draws frames `frames` along the grid as the export does (`render(at:into:completion:)`), waiting for each.
private func export(_ renderer: FrameRenderer, frames: ClosedRange<Int>) async throws {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    #expect(CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
        == kCVReturnSuccess)
    let target = ReleasePixelBuffer(try #require(created))
    for n in frames {
        let error: (any Error)? = await withCheckedContinuation { continuation in
            renderer.render(at: seconds(n), into: target.pixelBuffer) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }
}

private final class ReleasePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// The frames a preview engine drew, from its hook.
private final class ReleaseDrawnFrames: Sendable {
    private let frames = Mutex<[PreviewEngine.DrawnFrame]>([])
    func append(_ frame: PreviewEngine.DrawnFrame) { frames.withLock { $0.append(frame) } }
    var count: Int { frames.withLock { $0.count } }
}

@Suite struct OtherTakesReleaseTests {
    /// A|B|C|D drawn as the export draws it: at 1.5 s (in B), A's screen is let go (its prefetcher dropped, its
    /// `AVAssetReader` closed) while B's and C's (a second ahead) are read; at the end only the project's own take, D, is
    /// read, the reader of each other take kept but closed; frame by frame the same. And the frames are those of each
    /// take alone.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func earlierTakesAreLetGoAsTheExportGoesOn() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await fourTakes(in: dir)
            #expect(project.take.id == "take-004" && project.takes.count == 4)
            let document = everyTake(project)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [320, 180], frameRate: rate)
            func key(_ take: String) -> TrackKey { TrackKey(take: take, track: "display-1") }
            let a = try #require(renderer.reader(for: key("take-001")))
            try await export(renderer, frames: 0...45)
            #expect(!renderer.isAwake(key("take-001")) && renderer.isAwake(key("take-002")) && renderer.isAwake(key("take-003")))
            #expect(await eventually { !a.isOpen })
            #expect(renderer.withAhead { ahead in Set(ahead.prefetchers.keys) }.isDisjoint(with: [key("take-001")]))
            try await export(renderer, frames: 46...119)
            for take in ["take-001", "take-002", "take-003"] {
                #expect(!renderer.isAwake(key(take)), "\(take)")
                let reader = try #require(renderer.reader(for: key(take)))
                #expect(await eventually { !reader.isOpen }, "\(take)")
                _ = renderer.releaseVideos(keeping: [])
            }
            let kept = renderer.withAhead { Set($0.prefetchers.keys) }
            #expect(kept == [TrackKey(take: nil, track: "display-1")], "\(kept)")
            #expect(try #require(renderer.reader(for: TrackKey(take: nil, track: "display-1"))).isOpen)

            // Frame by frame: the frame of C, then of D; C is let go after D.
            let alone = try FrameRenderer(project: project, document: document, outputSize: [320, 180], frameRate: rate)
            _ = try await offThePool { try alone.renderBytes(at: 2.5) }
            let c = try #require(alone.reader(for: key("take-003")))
            #expect(c.isOpen && alone.isAwake(key("take-003")))
            _ = try await offThePool { try alone.renderBytes(at: 3.5) }
            #expect(!alone.isAwake(key("take-003")))
            #expect(await eventually { !c.isOpen })
        }
    }

    /// A|B|C|D played through in the preview, frame after frame: past the end, the frames it keeps shown and the
    /// prefetchers are the project's own take's alone, and the other takes' readers are closed; while D plays, its
    /// prefetcher and reader stay the same ones from frame to frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func earlierTakesAreLetGoAsThePreviewPlays() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await fourTakes(in: dir)
            let renderer = try FrameRenderer(project: project, document: everyTake(project), outputSize: [320, 180], frameRate: rate)
            let layer = CAMetalLayer()
            CATransaction.begin()
            layer.drawableSize = CGSize(width: 320, height: 180)
            CATransaction.commit()
            let engine = PreviewEngine(renderer: renderer, layer: layer)
            let drawn = ReleaseDrawnFrames()
            engine.hooks.onDrawn = { drawn.append($0) }
            engine.hooks.playbackSize = [320, 180]
            let own = TrackKey(take: nil, track: "display-1")
            var ownPrefetchers: [ObjectIdentifier] = []
            for n in 0...119 {
                let before = drawn.count
                engine.request(.playing(seconds: seconds(n)))
                #expect(await eventually(timeout: .seconds(30)) { drawn.count > before }, "frame \(n) drawn")
                if n >= 95, let prefetcher = renderer.withAhead({ $0.prefetchers[own] }) {
                    ownPrefetchers.append(ObjectIdentifier(prefetcher))
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(Set(ownPrefetchers).count == 1, "D's prefetcher is not made again while D plays")
            #expect(try await engine.shownTracks() == [own])
            #expect(renderer.withAhead { Set($0.prefetchers.keys) } == [own])
            for take in ["take-001", "take-002", "take-003"] {
                let reader = try #require(renderer.reader(for: TrackKey(take: take, track: "display-1")))
                #expect(await eventually { !reader.isOpen }, "\(take)")
            }
        }
    }

    /// One take, as every project of phases 1 and 2: the export and the preview never let its reader go (it stays open,
    /// with the same prefetcher from frame to frame) and nothing is awake to let go.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
    func oneTakeIsNeverLetGo() async throws {
        try await withTemporaryDirectory { dir in
            let project = try #require(try await MultiTakeFixtures.twoTakes(in: dir).focused(on: "take-001"))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [320, 180], frameRate: rate)
            let own = TrackKey(take: nil, track: "display-1")
            try await export(renderer, frames: 0...30)
            let prefetcher = try #require(renderer.withAhead { $0.prefetchers[own] })
            try await export(renderer, frames: 31...100)
            #expect(renderer.withAhead { $0.prefetchers[own] } === prefetcher)
            #expect(renderer.releaseVideos(keeping: []).isEmpty)
            #expect(renderer.withAhead { $0.prefetchers[own] } === prefetcher)
            #expect(try #require(renderer.reader(for: own)).isOpen)
            #expect(!renderer.isAwake(TrackKey(take: "take-002", track: "display-1")))
        }
    }
}
