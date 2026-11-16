// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Export
import Foundation
import ProjectFormat
import QuartzCore
import RecorderKitTestSupport
// @testable for the engine's hooks and `drawnBytes()`.
@testable import Render
import Synchronization
import Testing

// A take without a screen in the editor (design §5.9 and §7.6): what `EditorModel` does to show a project — the renderer
// at the export's size, the preview engine's paused and playing frames, the scene of a revision on the builder's path,
// and the project's mix — works for a take of a camera and a microphone, whose document's clip spans what they recorded
// (Task 27). The frames are the background with the camera, never black.

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread (drawing decodes, and
/// blocks while it does).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func theEditorsPreviewShowsATakeWithoutAScreen() async throws {
    try await withTemporaryDirectory { dir in
        // The microphone for 2 s and the camera from 0.5 s to 2.5 s.
        let builder = try TakeBuilder(in: dir)
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
        let camera = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: camera, segments: [VideoSegmentSpec(start: base.adding(seconds: 0.5), seconds: 2)])
        let project = try builder.write()
        // What the editor shows of a project of an earlier version: its clip is all the take recorded.
        let document = EditDocument.legacy(for: project)
        #expect(TimeMap(sequence: document.sequence).duration == 2_500_000_000)

        // The renderer at the export's size, off the main thread, and the engine on a layer, as the model makes them.
        let size = StageLayout.outputSize(aspect: document.aspect, shortSide: 1080)
        let renderer = try await offThePool { try FrameRenderer(project: project, document: document, outputSize: size) }
        let layer = CAMetalLayer()
        CATransaction.begin()
        layer.drawableSize = CGSize(width: 640, height: 360)
        CATransaction.commit()
        let engine = PreviewEngine(renderer: renderer, layer: layer)
        let drawn = Mutex<[PreviewEngine.DrawnFrame]>([])
        engine.hooks.onDrawn = { frame in drawn.withLock { $0.append(frame) } }
        func waitForDrawn(_ count: Int) async throws -> PreviewEngine.DrawnFrame {
            #expect(await eventually(timeout: .seconds(30)) { drawn.withLock { $0.count } >= count }, "\(count) frames drawn")
            return try #require(drawn.withLock { $0.last })
        }
        func centre() async throws -> SIMD4<UInt8> {
            let bytes = try await engine.drawnBytes()
            return pixel(bytes, width: size.x, x: size.x / 2, y: size.y / 2)
        }

        // Paused at 1 s: no screen, the camera, over the background.
        engine.request(.paused(frame: 60))
        let paused = try await waitForDrawn(1)
        #expect(paused.frame.screen == nil && paused.frame.previousScreen == nil)
        #expect(Set(paused.videos.keys) == ["camera"])
        let gradient = try await centre()
        #expect(Int(gradient.x) + Int(gradient.y) + Int(gradient.z) > 150, "\(gradient)")

        // An edit: the scene the editor builds for a revision (its paths, then the scene) draws the paused frame again.
        var edited = document
        edited.style.background = .color(RGBA(0.9, 0.1, 0.1, 1))
        let paths = MotionPaths(take: project.take, events: project.events, document: edited)
        engine.setScene(renderer.makeScene(document: edited, paths: paths, outputSize: size))
        _ = try await waitForDrawn(2)
        let red = try await centre()
        #expect(Int(red.z) > Int(red.x) + 100, "\(red) (BGRA)")

        // Playing on from there.
        engine.request(.playing(seconds: 1.5))
        let playing = try await waitForDrawn(3)
        #expect(playing.request == .playing(seconds: 1.5) && playing.frame.screen == nil)
        #expect(renderer.missingVideo.isEmpty)

        // The project's mix: the microphone, as long as the clip at the document's frames per second.
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: document.frameRate)
        #expect(mix.totalFrames == 120_000)
        #expect(mix.missingAudio.isEmpty)
    }
}
