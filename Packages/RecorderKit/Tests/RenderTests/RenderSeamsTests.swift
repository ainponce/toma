// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for the layers' scenes and shader parts, `FrameEvaluator.frame(at:)`, `RenderFrame.isCardMode`,
// `DrawCounts` and the compositor's counting `encode`.
@testable import Render
import Testing

/// The seams of phase 2's layers (phase 2 design §11 and §12, base plan task B3a): with the legacy values every new layer
/// is `nil` or empty, the compositor reaches the overlays' step once on every path and draws nothing new, and the shader
/// is the core's text with the layers' parts after it in the draw order.

/// A case of golden 2 as it is drawn: its take, its document (its recorded JSON decoded, so migrated to version 3) and the
/// times of its frames.
private struct SeamCase: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]

    /// The case's scene at its output size, with the camera readable as the renderer finds it in the package.
    var scene: FrameEvaluator {
        let readable = LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
        return FrameEvaluator(
            take: project.take, events: project.events, document: document, outputSize: GoldenDocuments.outputSize(of: document),
            cameraReadable: readable)
    }
}

/// Every case of `GoldenDocuments.golden2Cases`, written into `dir`, with its document as golden 2 reads it.
private func seamCases(in dir: URL) async throws -> [SeamCase] {
    var cases: [SeamCase] = []
    for golden in GoldenDocuments.golden2Cases {
        let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
        let made = try GoldenDocuments.makeDocument(golden.name, for: project)
        let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
        try #require(document.documentVersion == EditDocument.currentVersion, "\(golden.name) decodes migrated")
        cases.append(SeamCase(name: golden.name, project: project, document: document, times: golden.times))
    }
    return cases
}

/// The cases of golden 2 written once for the suite it is on, into a temporary folder removed after it (`seamCases`):
/// writing them takes the hardware encoder some seconds a case, and the suite's tests share them.
private struct GoldenSeamCases: SuiteTrait, TestScoping {
    @TaskLocal static var cases: [SeamCase] = []

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { dir in
            let cases = try await seamCases(in: dir)
            try await Self.$cases.withValue(cases) { try await function() }
        }
    }
}

extension Trait where Self == GoldenSeamCases {
    fileprivate static var goldenSeamCases: Self { Self() }
}

@Suite(.goldenSeamCases)
struct RenderSeamsTests {
    /// `makeScene` without `analysis:` reads the renderer's own; with it, exactly what it is given (`AnalysisInputs.none`
    /// is no analysis, not "the renderer's"). `AnalysisInputs` has no field yet, so the two cannot differ in value here:
    /// the test pins that both overloads exist and carry their analysis to the scene.
    @Test func makeSceneAnalysisOverloads() throws {
        let c = try #require(GoldenSeamCases.cases.first)
        let size = GoldenDocuments.outputSize(of: c.document)
        let renderer = try FrameRenderer(project: c.project, document: c.document, outputSize: size, analysis: AnalysisInputs())
        let paths = MotionPaths(take: c.project.take, events: c.project.events, document: c.document)
        #expect(renderer.makeScene(document: c.document, paths: paths, outputSize: size).analysis == renderer.analysis)
        #expect(renderer.makeScene(document: c.document, paths: paths, outputSize: size, analysis: AnalysisInputs.none).analysis == .none)
    }

    @Test func legacyFramesFillNoNewLayer() throws {
        let cases = GoldenSeamCases.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        for c in cases {
            let scene = c.scene
            #expect(scene.analysis == .none, "\(c.name)")
            for time in c.times {
                let frame = scene.frame(at: time)
                let at = "\(c.name) at \(time) s"
                #expect(frame.captions == nil && frame.keys == nil && frame.deviceFrame == nil, "\(at)")
                #expect(frame.screen?.privacy ?? [] == [] && frame.previousScreen?.privacy ?? [] == [], "\(at)")
                if let camera = frame.camera {
                    #expect(camera.crop == Rect(x: 0, y: 0, width: 1, height: 1), "\(at)")
                    #expect(camera.look == nil && camera.background == nil, "\(at)")
                }
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func overlayStepRunsOnEveryPath() async throws {
        let cases = GoldenSeamCases.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        let drawer = try SeamDrawer()
        var frames: [(at: String, path: DrawPath, frame: RenderFrame)] = []
        for c in cases {
            let scene = c.scene
            for time in c.times {
                let frame = scene.frame(at: time)
                let path = DrawPath(frame)
                frames.append(("\(c.name) at \(time) s (\(path.rawValue))", path, frame))
            }
        }
        let drawn = frames.map(\.frame)
        let counts = try await offThePool { try drawn.map { try drawer.counts(of: $0) } }
        for ((at, _, _), (counts, completed)) in zip(frames, counts) {
            #expect(completed, "\(at)")
            #expect(counts.overlaySteps == 1, "\(at): \(counts)")
            #expect(
                counts.deviceFrames == 0 && counts.privacyScreens == 0 && counts.cameraLooks == 0 && counts.keyOverlays == 0
                    && counts.captions == 0, "\(at): \(counts)")
        }
        // The cases of golden 2 go through every path but the cursor's blur alone.
        let paths = Set(frames.map(\.path))
        let expected: Set<DrawPath> = [.direct, .subframes, .card, .coveredByCamera]
        #expect(paths.isSuperset(of: expected), "the paths drawn: \(paths.map(\.rawValue).sorted())")
    }
}

/// How the compositor draws a frame: the paths of `Compositor.encode`.
private enum DrawPath: String, CaseIterable {
    /// One drawing of the stage straight into the target.
    case direct
    /// The zoom camera's motion blur (`RenderFrame.subframes`).
    case subframes
    /// The cursor's motion blur with the camera still (`RenderFrame.cursorSamples`).
    case cursorSamples
    /// The zoom inside the screen's card (`RenderFrame.card`).
    case card
    /// The camera over every pixel (`RenderFrame.coveredByCamera`).
    case coveredByCamera

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
private struct SeamDrawer: @unchecked Sendable {
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

@Test func shaderSourceIsTheCoreThenTheLayersInDrawOrder() {
    let layers = [
        ShaderSource.deviceFrameMetal, ShaderSource.privacyMetal, ShaderSource.cameraLookMetal, ShaderSource.keysMetal,
        ShaderSource.captionsMetal,
    ]
    #expect(ShaderSource.metal == ShaderSource.coreMetal + layers.joined())
    // The base adds no shader of its own: the library is phase 1's. Milestone 2c's privacy has its part (`privacy-1`).
    #expect(layers.filter { $0 != ShaderSource.privacyMetal }.allSatisfy { $0.isEmpty })
    #expect(!ShaderSource.privacyMetal.isEmpty)
}

@Test func cameraSyncAtZeroIsTheSameInstant() throws {
    let take = StageDrawing.bareTake(seconds: 4)
    let document = EditDocument.legacy(take: take, events: [])
    #expect(document.camera.syncOffset == 0)
    let clip = try #require(document.sequence.first)
    let sync = CameraSyncScene(document: document, take: take)
    let middle = HostTime(nanoseconds: clip.start.nanoseconds + (clip.end.nanoseconds - clip.start.nanoseconds) / 2)
    for t in [clip.start, middle, clip.end] {
        #expect(sync.cameraTime(atSource: t) == t)
    }
}

@Test func emptySeamsAddNothing() {
    // What each layer's scene gives with the legacy document: nothing, and the identity.
    let take = StageDrawing.bareTake()
    let document = EditDocument.legacy(take: take, events: [])
    let timeMap = TimeMap(sequence: document.sequence)
    let size = SIMD2(1280, 720)
    #expect(CaptionScene(document: document, timeMap: timeMap, outputSize: size).layer(atOutput: 0) == nil)
    #expect(KeyOverlayScene(document: document, events: [], timeMap: timeMap, outputSize: size).layer(atOutput: 0) == nil)
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: Rect(x: 10, y: 20, width: 300, height: 200), cornerRadius: 4)
    #expect(
        DeviceFrameGeometry.placement(
            contentAspect: 16.0 / 9, padding: 0.1, outputSize: SIMD2(1280, 720), frame: DeviceFrame(model: .iPhone, finish: .dark))
            == nil)
    let privacy = PrivacyScene(document: document, take: take, events: [])
    #expect(privacy.regions(atSource: base, trackID: trackID).isEmpty)
    var drawn = screen
    privacy.apply(to: &drawn, atSource: base)
    #expect(drawn == screen)
    // The device frame and the camera's look act on the whole frame (milestone 2b's seams): neither changes it.
    let cameraLayer = CameraLayer(trackID: cameraID, sourceTime: base, rect: Rect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 50)
    var frame = RenderFrame(
        outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, camera: cameraLayer,
        shadow: ShadowLayer(rect: screen.rect, cornerRadius: 4, opacity: 0.5, sigma: 8, offsetY: 4))
    let before = frame
    DeviceFrameScene(document: document, outputSize: size).apply(to: &frame)
    let layouts = LayoutTimeline(document: document, take: take, timeMap: timeMap, cameraReadable: true)
    CameraLookScene(document: document, take: take, analysis: .none, layouts: layouts).apply(to: &frame, atSource: base, output: 0)
    #expect(frame == before)
}

@Test func cameraCropFillsFromItsPart() {
    let picture = SIMD2<Double>(640, 480), square = Rect(x: 0, y: 0, width: 100, height: 100)
    // The whole picture as a crop is the fill of 1b.
    let whole = Compositor.aspectFill(picture, cropped: Rect(x: 0, y: 0, width: 1, height: 1), in: square)
    let legacy = Compositor.aspectFill(picture, in: square)
    #expect(whole.origin == legacy.origin && whole.size == legacy.size)
    // The right half (320 × 480) fills a square with its middle 320 × 320: x from 0.5, y from 1/6, 1/2 × 2/3 of the picture.
    let half = Compositor.aspectFill(picture, cropped: Rect(x: 0.5, y: 0, width: 0.5, height: 1), in: square)
    #expect(half.origin.x == 0.5 && abs(half.origin.y - 1.0 / 6) < 1e-6)
    #expect(half.size.x == 0.5 && abs(half.size.y - 2.0 / 3) < 1e-6)
    // A crop of no size is the whole picture.
    let empty = Compositor.aspectFill(picture, cropped: Rect(x: 0.2, y: 0.2, width: 0, height: 0.5), in: square)
    #expect(empty.origin == legacy.origin && empty.size == legacy.size)
}
