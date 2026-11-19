// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for the layers' scenes, `FrameEvaluator.frame(at:)` and `cameraLook`, `FrameRenderer.videos(of:)`,
// `reader(for:)` and `frame(of:at:)`, `RenderFrame.isCardMode`, `CameraLookTextures`, `DrawCounts` and the compositor's
// counting `encode`.
@testable import Render
import Testing

/// The seams of milestone 2b in the core of the render (plan 2b task I2): with the legacy values the device frame, the
/// camera's look and its background are `nil`, the renderer decodes the videos of before and nothing more, the compositor
/// reaches 2b's steps on every path and draws nothing of them, and handing it what the camera's look is drawn with, empty,
/// draws the same bytes as not handing it.

/// A case of golden 2 as it is drawn: its take, its document (its recorded JSON decoded, so migrated to version 3) and the
/// times of its frames.
private struct Case2b: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]

    /// Whether some camera track of the take has a segment the renderer can read in the package.
    var cameraReadable: Bool {
        LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
    }

    /// The case's scene at its output size, with the camera readable as given (as the renderer finds it, by default).
    func scene(cameraReadable readable: Bool? = nil) -> FrameEvaluator {
        FrameEvaluator(
            take: project.take, events: project.events, document: document, outputSize: GoldenDocuments.outputSize(of: document),
            cameraReadable: readable ?? cameraReadable)
    }
}

/// The cases of golden 2 written once for the suite, into a temporary folder removed after it: writing them takes the
/// hardware encoder some seconds a case, and the suite's tests share them.
private struct GoldenCases2b: SuiteTrait, TestScoping {
    @TaskLocal static var cases: [Case2b] = []

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { dir in
            var cases: [Case2b] = []
            for golden in GoldenDocuments.golden2Cases {
                let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
                let made = try GoldenDocuments.makeDocument(golden.name, for: project)
                let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
                try #require(document.documentVersion == EditDocument.currentVersion, "\(golden.name) decodes migrated")
                cases.append(Case2b(name: golden.name, project: project, document: document, times: golden.times))
            }
            try await Self.$cases.withValue(cases) { try await function() }
        }
    }
}

extension Trait where Self == GoldenCases2b {
    fileprivate static var goldenCases2b: Self { Self() }
}

/// Every frame of the cases, at its times, as its scene works it out.
private func frames(of cases: [Case2b]) -> [(at: String, frame: RenderFrame)] {
    cases.flatMap { c in
        let scene = c.scene()
        return c.times.map { time in ("\(c.name) at \(time) s", scene.frame(at: time)) }
    }
}

@Suite(.goldenCases2b)
struct Seams2bTests {
    @Test func legacyFramesFill2bLayersWithNothing() throws {
        let cases = GoldenCases2b.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        var cameras = 0
        for (at, frame) in frames(of: cases) {
            #expect(frame.deviceFrame == nil, "\(at)")
            if let camera = frame.camera {
                cameras += 1
                #expect(camera.look == nil && camera.background == nil, "\(at)")
            }
        }
        // The cases draw a camera, so its look and background were looked at.
        #expect(cameras > 0)
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func legacyFramesDecodeTheVideosOfBefore() async throws {
        let cases = GoldenCases2b.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        for c in cases {
            let size = GoldenDocuments.outputSize(of: c.document)
            let renderer = try FrameRenderer(project: c.project, document: c.document, outputSize: size)
            for time in c.times {
                let frame = try renderer.frame(of: renderer.scene, at: time)
                // The screen, the screen being left, the camera: nothing of the camera's look after them.
                let before = [
                    frame.screen.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime) },
                    frame.previousScreen.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime) },
                    frame.camera.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime) },
                ].compactMap { $0 }
                #expect(renderer.videos(of: frame) == before, "\(c.name) at \(time) s")
            }
            // An id that is no track of the take has no reader: no person's mask.
            #expect(renderer.reader(for: "personMask:segment-1.mp4") == nil, "\(c.name)")
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func drawCountsOf2bAreZeroOnEveryPath() async throws {
        let cases = GoldenCases2b.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        let drawer = try Drawer2b()
        let all = frames(of: cases)
        let drawn = all.map(\.frame)
        let counts = try await offThePool {
            try drawn.map { frame in
                (
                    try drawer.draw(frame, cameraLook: nil, bytes: false),
                    try drawer.draw(frame, cameraLook: CameraLookTextures(), bytes: false)
                )
            }
        }
        var paths: Set<String> = []
        for ((at, frame), (without, with)) in zip(all, counts) {
            paths.insert(Self.path(of: frame))
            for drawing in [without, with] {
                #expect(drawing.completed, "\(at)")
                let counts = drawing.counts
                #expect(counts.renderPasses == 1 && counts.overlaySteps == 1, "\(at): \(counts)")
                #expect(
                    counts.deviceFrames == 0 && counts.deviceOverlays == 0 && counts.cameraLooks == 0 && counts.cameraBackgrounds == 0,
                    "\(at): \(counts)")
            }
            #expect(with.counts == without.counts, "\(at)")
        }
        // The cases of golden 2 go through every path but the cursor's blur alone.
        #expect(paths.isSuperset(of: ["direct", "subframes", "card", "coveredByCamera"]), "the paths drawn: \(paths.sorted())")
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func noCameraLookTexturesIsTheSameBytes() async throws {
        let cases = GoldenCases2b.cases
        try #require(cases.count == GoldenDocuments.golden2Cases.count)
        let drawer = try Drawer2b()
        let all = frames(of: cases)
        // The camera in a card (Camera only) among them.
        let cameraOnly = try #require(all.first { $0.at == "layoutBlocks at 2.3 s" })
        try #require(cameraOnly.frame.camera != nil)
        let drawn = all.map(\.frame)
        let same = try await offThePool {
            try drawn.map { frame in
                let without = try drawer.draw(frame, cameraLook: nil, bytes: true)
                let with = try drawer.draw(frame, cameraLook: CameraLookTextures(), bytes: true)
                return without.completed && with.completed && !without.bytes.isEmpty && without.bytes == with.bytes
            }
        }
        for ((at, _), same) in zip(all, same) {
            #expect(same, "\(at)")
        }
    }

    @Test func cameraLookSceneSeesTheEvaluatorsLayouts() throws {
        let c = try #require(GoldenCases2b.cases.first { $0.name == "layoutBlocks" })
        try #require(c.cameraReadable)
        let τ = TimeMap.outputNanoseconds(seconds: 2.3)
        var kinds: [Bool: LayoutKind] = [:]
        for readable in [true, false] {
            let scene = c.scene(cameraReadable: readable)
            let layouts = LayoutTimeline(document: c.document, take: c.project.take, timeMap: scene.timeMap, cameraReadable: readable)
            #expect(scene.cameraLook.layouts.spans == layouts.spans, "readable \(readable)")
            #expect(scene.cameraLook.layouts.span(atOutput: τ) == layouts.span(atOutput: τ), "readable \(readable)")
            // A scene of another size keeps them.
            #expect(scene.resized(to: SIMD2(640, 360)).cameraLook.layouts.spans == layouts.spans, "readable \(readable)")
            kinds[readable] = scene.cameraLook.layouts.span(atOutput: τ).kind
        }
        // Camera only where the camera can be read, Screen only where it cannot: the scene's own layouts.
        #expect(kinds[true] == .cameraOnly)
        #expect(kinds[false] == .screenOnly)
    }

    /// The path of `Compositor.encode` `frame` takes.
    private static func path(of frame: RenderFrame) -> String {
        if frame.coveredByCamera { return "coveredByCamera" }
        if frame.isCardMode { return "card" }
        if !frame.subframes.isEmpty { return "subframes" }
        if !frame.cursorSamples.isEmpty { return "cursorSamples" }
        return "direct"
    }
}

/// A compositor of the default device with a screen, a camera and Toma's arrow to draw frames with. It checks nothing
/// itself: it runs off the cooperative pool.
private struct Drawer2b: @unchecked Sendable {
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

    /// `frame` drawn with `cameraLook` (the screen being left with the screen's texture too): what was drawn, the bytes
    /// (with `bytes`; none otherwise), and whether the GPU completed it.
    func draw(
        _ frame: RenderFrame, cameraLook: CameraLookTextures?, bytes: Bool
    ) throws -> (counts: DrawCounts, bytes: [UInt8], completed: Bool) {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        var counts = DrawCounts()
        try compositor.encode(
            frame, screen: screen, previousScreen: screen, camera: camera, cursor: cursor, cameraLook: cameraLook, into: target,
            commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (counts, bytes ? StageDrawing.bytes(of: target) : [], commandBuffer.status == .completed)
    }
}
