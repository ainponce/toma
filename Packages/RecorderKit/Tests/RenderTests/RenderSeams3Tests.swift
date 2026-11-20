// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for the layers' scenes and shader parts, `FrameEvaluator.frame(at:)` and `takeFrame`, `RenderFrame.isCardMode`,
// `DrawCounts` and the compositor's counting `encode`.
@testable import Render
import Testing

/// The seams of phase 3's layers (phase 3 design §12 and §14, base plan task B6): with the legacy values every new layer
/// is `nil` or empty, the compositor reaches the stage's overlays (step 4) once on every path but the camera's alone and
/// draws nothing new, and the shader is the core's text with every layer's part after it in the draw order. A frozen
/// frame is the frame of its instant without the motion blur (plan decision 8), and a title card and an imported clip
/// draw the background alone in the base.

/// A case of golden 3 as it is drawn: its take, its document (its recorded JSON decoded, so migrated to version 4), the
/// times of its frames and their size.
private struct Seam3Case: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]
    var size: SIMD2<Int>

    /// The case's scene at its output size, with the camera readable as the renderer finds it in the package.
    var scene: FrameEvaluator {
        let readable = LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
        return FrameEvaluator(
            take: project.take, events: project.events, document: document, outputSize: size, cameraReadable: readable)
    }
}

/// The cases of golden 3 written once for the suite, into a temporary folder removed after it: writing them takes the
/// hardware encoder some seconds a case, and the suite's tests share them.
private struct GoldenSeam3Cases: SuiteTrait, TestScoping {
    @TaskLocal static var cases: [Seam3Case] = []

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { dir in
            var cases: [Seam3Case] = []
            for golden in GoldenDocuments.golden3Cases {
                let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
                let made = try GoldenDocuments.makeDocument(golden.name, for: project)
                let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
                try #require(document.documentVersion == EditDocument.currentVersion, "\(golden.name) decodes migrated")
                cases.append(Seam3Case(
                    name: golden.name, project: project, document: document, times: golden.times,
                    size: GoldenDocuments.outputSize(of: golden, document: document, project: project)))
            }
            try await Self.$cases.withValue(cases) { try await function() }
        }
    }
}

extension Trait where Self == GoldenSeam3Cases {
    fileprivate static var goldenSeam3Cases: Self { Self() }
}

@Suite(.goldenSeam3Cases)
struct RenderSeams3Tests {
    @Test func legacyFramesFillNoPhase3Layer() throws {
        let cases = GoldenSeam3Cases.cases
        try #require(cases.count == GoldenDocuments.golden3Cases.count)
        for c in cases {
            let scene = c.scene
            for time in c.times {
                let frame = scene.frame(at: time)
                let at = "\(c.name) at \(time) s"
                #expect(frame.media == nil && frame.calmZoom == nil && frame.titleCard == nil, "\(at)")
                #expect(frame.contentAnnotations.isEmpty && frame.outputAnnotations.isEmpty, "\(at)")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func stageOverlayStepRunsOnEveryPath() async throws {
        let cases = GoldenSeam3Cases.cases
        try #require(cases.count == GoldenDocuments.golden3Cases.count)
        let drawer = try Seam3Drawer()
        var frames: [(at: String, path: Draw3Path, frame: RenderFrame)] = []
        for c in cases {
            let scene = c.scene
            for time in c.times {
                let frame = scene.frame(at: time)
                let path = Draw3Path(frame)
                frames.append(("\(c.name) at \(time) s (\(path.rawValue))", path, frame))
            }
        }
        let drawn = frames.map(\.frame)
        let counts = try await offThePool { try drawn.map { try drawer.counts(of: $0) } }
        for ((at, path, _), (counts, completed)) in zip(frames, counts) {
            #expect(completed, "\(at)")
            // The camera over every pixel has no stage, so nothing goes over one; every other path reaches step 4 once.
            #expect(counts.stageOverlaySteps == (path == .coveredByCamera ? 0 : 1), "\(at): \(counts)")
            #expect(counts.overlaySteps == 1, "\(at): \(counts)")
            #expect(
                counts.mediaClips == 0 && counts.calmZooms == 0 && counts.contentAnnotations == 0 && counts.outputAnnotations == 0
                    && counts.titleCards == 0, "\(at): \(counts)")
        }
        // The cases of golden 3 go through every path but the cursor's blur alone.
        let paths = Set(frames.map(\.path))
        let expected: Set<Draw3Path> = [.direct, .subframes, .card, .coveredByCamera]
        #expect(paths.isSuperset(of: expected), "the paths drawn: \(paths.map(\.rawValue).sorted())")
    }
}

/// How the compositor draws a frame: the paths of `Compositor.encode`.
private enum Draw3Path: String, CaseIterable {
    case direct, subframes, cursorSamples, card, coveredByCamera

    init(_ frame: RenderFrame) {
        if frame.coveredByCamera {
            self = .coveredByCamera
        } else if frame.isCardMode {
            self = .card
        } else if !frame.subframes.isEmpty {
            self = .subframes
        } else if !frame.cursorSamples.isEmpty {
            self = .cursorSamples
        } else {
            self = .direct
        }
    }
}

/// A compositor of the default device with a screen, a camera and Toma's arrow to draw frames with.
private struct Seam3Drawer: @unchecked Sendable {
    let device: any MTLDevice
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let screen: any MTLTexture
    let camera: any MTLTexture
    let cursor: any MTLTexture

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        compositor = try Compositor(device: device)
        queue = try #require(device.makeCommandQueue())
        screen = try StageDrawing.screenTexture(device: device)
        camera = try StageDrawing.screenTexture(device: device, width: 64, height: 48)
        cursor = try CursorSprite.makeTexture(device: device)
    }

    /// What drawing `frame` drew (the screen being left with the screen's texture too), and whether the GPU completed it.
    func counts(of frame: RenderFrame) throws -> (counts: DrawCounts, completed: Bool) {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, previousScreen: screen, camera: camera, cursor: cursor, into: target, commandBuffer: commandBuffer,
            counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (counts, commandBuffer.status == .completed)
    }
}

@Test func shaderSourceIsTheCoreThenEveryLayerInDrawOrder() {
    let phase2 = [
        ShaderSource.deviceFrameMetal, ShaderSource.privacyMetal, ShaderSource.cameraLookMetal, ShaderSource.keysMetal,
        ShaderSource.captionsMetal,
    ]
    let phase3 = [ShaderSource.mediaClipMetal, ShaderSource.calmZoomMetal, ShaderSource.annotationsMetal, ShaderSource.titleCardMetal]
    #expect(ShaderSource.metal == ShaderSource.coreMetal + (phase2 + phase3).joined())
    // The base adds no shader of its own: phase 3's parts are their milestones' (3a's and 3b's), empty in the base; 3b's
    // calm zoom has its own (plan 3b Task Z3), and 3a's annotations theirs (plan 3a Task A6).
    #expect([ShaderSource.mediaClipMetal, ShaderSource.titleCardMetal].allSatisfy { $0.isEmpty })
    #expect(!ShaderSource.calmZoomMetal.isEmpty && !ShaderSource.annotationsMetal.isEmpty)
}

/// The scenes of phase 3's layers with a document that has none of them: nothing, and the background as it is.
@Test func emptyPhase3SeamsAddNothing() {
    let take = StageDrawing.bareTake()
    let document = EditDocument.legacy(take: take, events: [])
    let timeMap = TimeMap(sequence: document.sequence)
    let size = SIMD2(1280, 720)
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 10, y: 20, width: 300, height: 200), cornerRadius: 4)
    let frame = RenderFrame(
        outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen,
        stage: StageTransform(depth: 2, center: [300, 200]))
    let background = RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0)
    #expect(MediaClipScene(document: document, timeMap: timeMap, outputSize: size).frame(clip: 0, offset: 0, background: background) == background)
    let card = TitleCardScene(document: document, timeMap: timeMap, outputSize: size)
    #expect(card.frame(clip: 0, offset: 0, background: background) { _ in frame } == background)
    let paths = MotionPaths(take: take, events: [], document: document)
    #expect(CalmZoomScene(document: document, take: take, timeMap: timeMap, paths: paths).layer(atOutput: 0, frame: frame) == nil)
    let annotations = AnnotationScene(document: document, take: take, events: [], timeMap: timeMap, outputSize: size)
    #expect(annotations.content(atSource: base, output: 0, frame: frame).isEmpty)
    #expect(annotations.output(atOutput: 0).isEmpty)
}

/// A take of 4 s with the cursor moving over its screen, and a zoom of the user from 1 s to 3.5 s of it, 2× at its
/// centre, the camera's and the cursor's blur on: at 1.5 s of the source the camera is still moving in.
private func zoomingDocument() -> (take: TakeRecord, events: [InputEvent], document: EditDocument) {
    let take = StageDrawing.bareTake(seconds: 4)
    let events = cursorEvents(from: base, seconds: 4, across: Rect(x: 0, y: 0, width: 640, height: 360))
    var document = EditDocument.legacy(take: take, events: events)
    document.zoom.regions = [StageDrawing.zoom(1, from: 1, to: 3.5, depth: 2)]
    document.zoom.motionBlur = 1
    document.cursor.motionBlur = 1
    return (take, events, document)
}

@Test func freezeIsTheFrameOfItsInstant() throws {
    let (take, events, plain) = zoomingDocument()
    let point = base.adding(seconds: 1.5)
    var frozen = plain
    frozen.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: point, speed: 1),
        Clip(id: "c-00000002", take: takeID, start: point, end: point, speed: 1, content: .freeze(duration: 2_000_000_000)),
        Clip(id: "c-00000003", take: takeID, start: point, end: base.adding(seconds: 4), speed: 1),
    ]
    let size = SIMD2(1280, 720)
    let scene = FrameEvaluator(take: take, events: events, document: frozen, outputSize: size, frameRate: 60)
    let start = scene.timeMap.clipOutputStarts[1]
    #expect(start == 1_500_000_000 && scene.timeMap.duration == 6_000_000_000)
    let still = scene.takeFrame(atOutput: start, source: point, blurs: false) { _ in true }
    // The instant itself, drawn as any other, blurs: the camera moves in, and the cursor moves.
    let moving = scene.takeFrame(atOutput: start, source: point, blurs: true) { _ in true }
    #expect(!moving.subframes.isEmpty)
    #expect(still.subframes.isEmpty && still.cursorSamples.isEmpty)
    #expect(still.stage.map { $0.depth > 1 } == true && still.screen?.sourceTime == point && still.cursor != nil)
    // Every output instant of the frozen frame is that frame.
    for seconds in [1.5, 1.9, 2.75, 3.4999] {
        #expect(scene.frame(at: seconds) == still, "\(seconds) s")
    }
    // Every other one is the take's frame of its instant, as before.
    for seconds in [0.4, 1.2, 1.4999, 3.5, 4.1, 5.9] {
        let τ = TimeMap.outputNanoseconds(seconds: seconds)
        let shown = try #require(scene.timeMap.source(atOutput: τ))
        #expect(scene.timeMap.contentOffset(atOutput: τ) == nil, "\(seconds) s")
        #expect(scene.frame(at: seconds) == scene.takeFrame(atOutput: τ, source: shown.source, blurs: true) { _ in true }, "\(seconds) s")
    }
    // Before it, the frames of the take without it.
    let unfrozen = FrameEvaluator(take: take, events: events, document: plain, outputSize: size, frameRate: 60)
    for seconds in [0.4, 1.2] {
        #expect(scene.frame(at: seconds) == unfrozen.frame(at: seconds), "\(seconds) s")
    }
}

@Test func cardAndMediaDrawTheBackgroundInTheBase() {
    let (take, events, plain) = zoomingDocument()
    let point = base.adding(seconds: 1)
    let card = TitleCard(title: "Toma", subtitle: "Phase 3", style: .centered, background: .blurredFrame)
    let media = MediaClip(asset: "assets/0123456789abcdef0123456789abcdef.mov", start: 0, end: 1_000_000_000)
    var document = plain
    document.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: point, speed: 1),
        Clip(id: "c-00000002", take: takeID, start: point, end: point, speed: 1, content: .card(card, duration: 1_000_000_000)),
        Clip(id: "c-00000003", take: takeID, start: point, end: point, speed: 1, content: .media(media)),
        Clip(id: "c-00000004", take: "take-002", start: base, end: point, speed: 1),
        Clip(id: "c-00000005", take: takeID, start: point, end: base.adding(seconds: 2), speed: 1),
    ]
    let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: SIMD2(1280, 720), frameRate: 60)
    // A clip of another take: the background alone, as today.
    let background = scene.frame(at: 3.5)
    #expect(background.screen == nil && background.cursor == nil && background.camera == nil && background.stage == nil)
    #expect(background.subframes.isEmpty && background.cursorSamples.isEmpty && background.clickEffects.isEmpty)
    for seconds in [1.0, 1.5, 1.9999, 2.0, 2.5, 2.9999] {
        #expect(scene.frame(at: seconds) == background, "\(seconds) s")
    }
    #expect(scene.frame(at: 0.5).screen != nil && scene.frame(at: 4.5).screen != nil)
}
