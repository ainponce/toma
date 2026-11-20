// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `AnnotationRaster`, the compositor's counting `encode`, its annotations' bitmaps and `DrawCounts`.
@testable import Render
import simd
import Testing

// The annotations drawn (`annotation-1`, phase 3 design §5.1 and §12, steps 5 and 7, plan 3a task A6): those stuck to the
// recording in the stage, through the zoom and cut to the screen's card, under the camera; those of the output over it,
// one texel a pixel; once over the motion blur, sharp; nothing at all without them; the preview the export. Frames made
// here are 1280 × 720 over `StageDrawing`'s smooth screen (what a pixel shows says where it is) unless said otherwise.

private let size = SIMD2(1280, 720)
private let output = Rect(x: 0, y: 0, width: 1280, height: 720)
private let gradientStart: SIMD4<Float> = [0.25, 0.35, 0.55, 1], gradientEnd: SIMD4<Float> = [0.65, 0.45, 0.25, 1]
private let green = RGBA(0, 1, 0, 1), magenta = RGBA(1, 0, 1, 1)

/// A frame of the output with the screen in `screen` (the whole output by default) on a gradient, and the annotations.
private func frame(
    screen: Rect = output, content: [AnnotationLayer] = [], output annotations: [AnnotationLayer] = [], camera: CameraLayer? = nil
) -> RenderFrame {
    RenderFrame(
        outputSize: size, gradientStart: gradientStart, gradientEnd: gradientEnd, gradientAngleDegrees: 30,
        screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: screen, cornerRadius: 0), camera: camera,
        contentAnnotations: content, outputAnnotations: annotations)
}

/// A layer of `content` in `rect` of `space` (the output's by default), at `opacity`, popped to `scale`, turned by
/// `rotation`.
private func layer(
    _ content: AnnotationLayer.Content, rect: Rect, space: Rect = output, opacity: Double = 1, scale: Double = 1,
    rotation: Double = 0
) -> AnnotationLayer {
    AnnotationLayer(
        id: "a-00000001", content: content, rect: rect, space: space, unit: space.height, rotation: rotation, opacity: opacity,
        scale: scale, drawn: 1)
}

/// A filled rectangle of `color`, without a border.
private func box(_ color: RGBA) -> AnnotationLayer.Content {
    .shape(ShapeAnnotation(shape: .rect, width: 0, fill: color))
}

/// A Label `string` 400 wide at (`x`, `y`) of the output, red over blue.
private func label(_ string: String, x: Double, y: Double) -> AnnotationLayer {
    let text = TextAnnotation(string: string, preset: .label, size: 0.06, color: RGBA(1, 0, 0, 1), fill: RGBA(0, 0, 1, 1))
    let height = AnnotationTypography.box(of: text, width: 400, unit: 720).y
    return layer(.text(text), rect: Rect(x: x, y: y, width: 400, height: height))
}

/// A camera in the bottom-right corner, opaque.
private let cameraLayer = CameraLayer(
    trackID: cameraID, sourceTime: base, rect: Rect(x: 900, y: 450, width: 300, height: 200), cornerRadius: 0)

/// A compositor of the default device with `StageDrawing`'s smooth screen, a camera and Toma's arrow.
private final class AnnotationDrawer: @unchecked Sendable {
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

    /// `frame` drawn into a new target of its output size, as BGRA bytes, with what was drawn counted in `counts`.
    func draw(_ frame: RenderFrame, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen, previousScreen: screen, camera: camera, cursor: cursor, into: target,
            commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        return StageDrawing.bytes(of: target)
    }

    func draw(_ frame: RenderFrame) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, counts: &counts)
    }

    var rasters: AnnotationRasters { compositor.layers.annotations.rasters }
}

/// Pixel (`x`, `y`) of an image of the output's width, BGRA.
private func at(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int = size.x) -> SIMD4<Int> {
    let p = pixel(bytes, width: width, x: x, y: y)
    return SIMD4(Int(p.x), Int(p.y), Int(p.z), Int(p.w))
}

private func at(_ bytes: [UInt8], _ p: SIMD2<Double>) -> SIMD4<Int> {
    at(bytes, Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
}

/// BGRA of `color`, opaque.
private func bgra(_ color: RGBA) -> SIMD4<Int> {
    SIMD4(Int((color.b * 255).rounded()), Int((color.g * 255).rounded()), Int((color.r * 255).rounded()), 255)
}

private func close(_ a: SIMD4<Int>, _ b: SIMD4<Int>, _ tolerance: Int = 1) -> Bool {
    let d = a &- b
    return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= tolerance
}

/// The pixels where `a` and `b` differ.
private func differing(_ a: [UInt8], _ b: [UInt8], width: Int = size.x) -> [(x: Int, y: Int)] {
    stride(from: 0, to: a.count, by: 4).compactMap { i in
        a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] ? (i / 4 % width, i / 4 / width) : nil
    }
}

/// Whether pixel (`x`, `y`) touches `rect`.
private func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
    Double(x + 1) > rect.x && Double(x) < rect.x + rect.width && Double(y + 1) > rect.y && Double(y) < rect.y + rect.height
}

@Suite struct AnnotationRenderTests {
    /// The cases of golden 3 as the app opens them (their recorded JSON decoded, so migrated), drawn: no annotation of
    /// either group drawn, nor a bitmap made, at any of their times, on any path.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func legacyDrawsNoAnnotation() async throws {
        try await withTemporaryDirectory { dir in
            let projects = try await withThrowingTaskGroup(of: (String, LoadedProject).self) { group in
                for golden in GoldenDocuments.golden3Cases {
                    let folder = dir.appending(path: golden.name, directoryHint: .isDirectory)
                    group.addTask {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        return (golden.name, try await GoldenDocuments.makeProject(golden.name, in: folder))
                    }
                }
                return try await group.reduce(into: [String: LoadedProject]()) { $0[$1.0] = $1.1 }
            }
            var frames: [(at: String, frame: RenderFrame)] = []
            for golden in GoldenDocuments.golden3Cases {
                let project = try #require(projects[golden.name])
                let made = try GoldenDocuments.makeDocument(golden.name, for: project)
                let document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
                let readable = LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
                let scene = FrameEvaluator(
                    take: project.take, events: project.events, document: document,
                    outputSize: GoldenDocuments.outputSize(of: golden, document: document, project: project), cameraReadable: readable)
                for time in golden.times { frames.append(("\(golden.name) at \(time) s", scene.frame(at: time))) }
            }
            let drawer = try AnnotationDrawer()
            let drawn = frames.map(\.frame)
            let counts = try await offThePool {
                try drawn.map { frame -> DrawCounts in
                    var counts = DrawCounts()
                    _ = try drawer.draw(frame, counts: &counts)
                    return counts
                }
            }
            for ((at, frame), counts) in zip(frames, counts) {
                #expect(frame.contentAnnotations.isEmpty && frame.outputAnnotations.isEmpty && frame.annotationsAhead.isEmpty, "\(at)")
                #expect(counts.contentAnnotations == 0 && counts.outputAnnotations == 0, "\(at): \(counts)")
                #expect(counts.overlaySteps == 1, "\(at): \(counts)")
            }
            #expect(drawer.rasters.drawCount == 0)
            #expect(drawer.rasters.keptCount.textures == 0)
        }
    }

    /// A Label of the output drawn exactly as its bitmap says, one texel a pixel over the frame, and nothing outside its
    /// region; one stuck to the recording, at rest, the same over the stage.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func textIsDrawnWhereTheLayerSays() throws {
        let drawer = try AnnotationDrawer()
        let plain = try drawer.draw(frame())
        let text = label("Hello", x: 300.4, y: 200.7)
        for (name, drawn) in [("output", frame(output: [text])), ("content", frame(content: [text]))] {
            var counts = DrawCounts()
            let bytes = try drawer.draw(drawn, counts: &counts)
            #expect(counts.outputAnnotations + counts.contentAnnotations == 1, "\(name): \(counts)")
            let bitmap = try #require(try AnnotationRaster.bitmap(of: text, scale: 1))
            let region = bitmap.region
            let columns = Int(region.width), left = Int(region.x), top = Int(region.y)
            // Inside its region, the bitmap over the frame, premultiplied: within a level.
            var worst = 0
            for y in 0..<Int(region.height) {
                for x in 0..<columns {
                    let i = (y * columns + x) * 4
                    let under = at(plain, left + x, top + y), over = at(bytes, left + x, top + y)
                    let alpha = Int(bitmap.bytes[i + 3])
                    for c in 0..<3 {
                        let expected = Double(bitmap.bytes[i + c]) + Double(under[c]) * Double(255 - alpha) / 255
                        worst = max(worst, abs(Int(expected.rounded()) - over[c]))
                    }
                }
            }
            #expect(worst <= 1, "\(name): \(worst)")
            // Its pill in blue, its text in red, and nothing outside its region.
            let em = 0.06 * 720.0
            let inThePill = SIMD2(text.rect.x + 0.3 * em, text.rect.y + 0.15 * em)
            #expect(close(at(bytes, inThePill), bgra(RGBA(0, 0, 1, 1))), "\(name)")
            #expect(differing(bytes, plain).allSatisfy { touches($0.x, $0.y, region) }, "\(name)")
            var red = false
            for y in Int(text.rect.y)..<Int(text.rect.y + text.rect.height) {
                for x in Int(text.rect.x)..<Int(text.rect.x + text.rect.width) where close(at(bytes, x, y), bgra(RGBA(1, 0, 0, 1))) {
                    red = true
                }
            }
            #expect(red, "\(name)")
        }
        // The same text drawn twice made one bitmap: the second frame binds it.
        #expect(drawer.rasters.drawCount == 1)
    }

    /// Under the camera bubble, one stuck to the recording is hidden by it and one of the output is drawn over it.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func contentUnderTheCameraOutputOver() throws {
        let drawer = try AnnotationDrawer()
        let content = layer(box(green), rect: Rect(x: 820, y: 400, width: 200, height: 150))
        let over = layer(box(magenta), rect: Rect(x: 1100, y: 600, width: 150, height: 100))
        let plain = try drawer.draw(frame(camera: cameraLayer))
        var counts = DrawCounts()
        let bytes = try drawer.draw(frame(content: [content], output: [over], camera: cameraLayer), counts: &counts)
        #expect(counts.contentAnnotations == 1 && counts.outputAnnotations == 1 && counts.cameras == 1, "\(counts)")
        #expect(at(bytes, 950, 500) == at(plain, 950, 500), "the camera over the one stuck to the recording")
        #expect(close(at(bytes, 850, 420), bgra(green)), "where the camera is not")
        #expect(close(at(bytes, 1150, 620), bgra(magenta)), "the output's over the camera")
        #expect(close(at(bytes, 1220, 690), bgra(magenta)), "and outside it")
    }

    /// Through a zoom of 2×, an arrow stuck to the recording points at the pixel of the content it points at in the
    /// stage: its tip drawn where the zoom draws that point. A zoom that moves draws its bitmap again only at each step
    /// of √2 of its depth, and one drawn before is kept.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func zoomedArrowStaysOnThePixel() throws {
        let take = StageDrawing.bareTake(seconds: 4)
        let events = cursorEvents(from: base, seconds: 4, across: Rect(x: 0, y: 0, width: 640, height: 360))
        var document = EditDocument.legacy(take: take, events: events)
        let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0.3, y: 0.3), to: NormalizedPoint(x: 0.55, y: 0.45), head: .filled)
        document.annotations = AnnotationPlan(items: [Annotation(
            id: "a-00000001", anchor: .content(take: takeID, start: base, end: base.adding(seconds: 4)), layer: 0, kind: .arrow(arrow),
            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1), enter: .none, exit: .none)])
        document.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 3.5, depth: 2, focus: .fixed(x: 0.5, y: 0.5))]
        var zoomed = FrameEvaluator(take: take, events: events, document: document, outputSize: size).frame(at: 2)
        // Drawn alone, without what the frames after it would draw ahead.
        zoomed.annotationsAhead = []
        let stage = try #require(zoomed.stage)
        #expect(stage.depth > 1.9 && stage.depth <= 2, "\(stage)")
        let screen = try #require(zoomed.screen)
        let annotation = try #require(zoomed.contentAnnotations.first)
        guard case let .arrow(_, path) = annotation.content else { Issue.record("not an arrow"); return }
        // The content's point (0.55, 0.45): on the screen's rect in the stage, then where the zoom draws it.
        let point = SIMD2(screen.rect.x + 0.55 * screen.rect.width, screen.rect.y + 0.45 * screen.rect.height)
        #expect(simd_distance(path.end, point) < 1e-6)
        let tip = stage.outputPoint(ofStage: point, outputSize: size)
        let direction = simd_normalize(path.end - path.start)
        let w = arrow.width * annotation.unit * stage.depth
        let drawer = try AnnotationDrawer()
        var plainFrame = zoomed
        plainFrame.contentAnnotations = []
        let plain = try drawer.draw(plainFrame)
        var counts = DrawCounts()
        let bytes = try drawer.draw(zoomed, counts: &counts)
        #expect(counts.contentAnnotations == 1)
        #expect(close(at(bytes, tip - direction * 1.5 * w), bgra(.annotationRed)), "just behind the tip")
        #expect(at(bytes, tip + direction * 3 * w) == at(plain, tip + direction * 3 * w), "just past it, the content")
        #expect(at(bytes, tip - direction * 3 * w + SIMD2(-direction.y, direction.x) * 3 * w) == at(plain, tip - direction * 3 * w + SIMD2(-direction.y, direction.x) * 3 * w))
        // Drawn at 2: never magnified.
        #expect(drawer.rasters.drawCount == 1)
        // A zoom moving through 1, 1.2, 1.4, 1.42, 1.9, 2, back to 1.2 and on to 2.9: a bitmap at 1 and √2 (the one at 2
        // kept), then at 4, no more.
        zoomed.subframes = []
        zoomed.cursorSamples = []
        var made: [Int] = []
        for depth in [1, 1.2, 1.4, 1.42, 1.9, 2, 1.2, 2.9] {
            zoomed.stage = StageTransform(depth: depth, center: stage.center)
            _ = try drawer.draw(zoomed)
            made.append(drawer.rasters.drawCount)
        }
        #expect(made == [2, 3, 3, 3, 3, 3, 3, 4], "\(made)")
    }

    /// In a Split, the screen's card cuts what is stuck to the recording, which goes past the content into the margin on
    /// the stage; as the cursor, by the card's strength (`CardPlacement.mix`).
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func splitCardCutsContentAnnotations() throws {
        let card = CardPlacement(
            rect: Rect(x: 100, y: 100, width: 600, height: 400), cornerRadius: 12,
            content: StageTransform(depth: 1.5, center: [400, 300]), mix: 1)
        // The screen drawn on the card's content, and a green box from inside it to well past its left edge.
        let screen = Rect(x: 200, y: 150, width: 400, height: 300)
        let greenBox = layer(box(green), rect: Rect(x: 0, y: 250, width: 250, height: 100), space: screen)
        var drawn = frame(screen: screen, content: [greenBox])
        drawn.card = card
        drawn.backgroundTransform = .identity(outputSize: size)
        var plainFrame = drawn
        plainFrame.contentAnnotations = []
        let drawer = try AnnotationDrawer()
        let plain = try drawer.draw(plainFrame)
        var counts = DrawCounts()
        let bytes = try drawer.draw(drawn, counts: &counts)
        #expect(counts.contentAnnotations == 1)
        // Where the card's content draws the box: from (0, 250) at (40, 285), left of the card's edge at 100.
        let inside = card.content.outputPoint(ofStage: [200, 300], outputSize: size)
        let outside = card.content.outputPoint(ofStage: [20, 300], outputSize: size)
        #expect(inside.x > 110 && outside.x < 95, "\(inside), \(outside)")
        #expect(close(at(bytes, inside), bgra(.init(0, 1, 0, 1))), "inside the card")
        #expect(at(bytes, outside) == at(plain, outside), "cut outside it")
        // At the start of the transition (mix 0) nothing is cut.
        drawn.card?.mix = 0
        plainFrame.card?.mix = 0
        let uncut = try drawer.draw(drawn)
        #expect(close(at(uncut, outside), bgra(.init(0, 1, 0, 1))), "not cut at the transition's start")
    }

    /// With the zoom's motion blur (its subframes) or the cursor's (its samples), they are drawn once, through the frame's
    /// stage, over the average: as sharp as without the blur.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func motionBlurDrawsThemOnceSharp() throws {
        let drawer = try AnnotationDrawer()
        let stage = StageTransform(depth: 1.5, center: [640, 360])
        let content = [layer(box(green), rect: Rect(x: 500, y: 300, width: 200, height: 100))]
        let over = [label("Over", x: 100, y: 100)]
        var sharp = frame(content: content, output: over)
        sharp.stage = stage
        let still = try drawer.draw(sharp)
        var blurred = sharp
        blurred.subframes = [
            StageSubframe(stage: StageTransform(depth: 1.4, center: [630, 350])), StageSubframe(stage: stage),
            StageSubframe(stage: StageTransform(depth: 1.6, center: [650, 370])),
        ]
        var sampled = sharp
        sampled.cursorSamples = [
            CursorLayer(hotspot: [300, 300], height: 30), CursorLayer(hotspot: [310, 305], height: 30),
        ]
        for (name, drawnFrame) in [("subframes", blurred), ("cursor samples", sampled)] {
            var counts = DrawCounts()
            let bytes = try drawer.draw(drawnFrame, counts: &counts)
            #expect(counts.contentAnnotations == 1 && counts.outputAnnotations == 1, "\(name): \(counts)")
            // The box's inside, through the frame's stage, and the label: the same pixels as without the blur.
            let centre = stage.outputPoint(ofStage: [600, 350], outputSize: size)
            #expect(at(bytes, centre) == at(still, centre) && close(at(bytes, centre), bgra(green)), "\(name)")
            // The label's pill inside its corners, opaque.
            for y in 115..<160 {
                for x in 115..<485 where at(bytes, x, y) != at(still, x, y) {
                    Issue.record("\(name): the label at (\(x), \(y))")
                    return
                }
            }
        }
    }

    /// Nothing of one at opacity 0, nor of one outside the frame, nor of one with nothing to draw: no bitmap and the frame
    /// as without it. A translucent one blends at its opacity; one turned or popped turns or shrinks about its box.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func opacityRotationPopAndWhatIsNotDrawn() throws {
        let drawer = try AnnotationDrawer()
        let plain = try drawer.draw(frame())
        let unseen = [
            layer(box(green), rect: Rect(x: 500, y: 300, width: 200, height: 100), opacity: 0),
            layer(box(green), rect: Rect(x: 500, y: 300, width: 200, height: 100), opacity: .nan),
            layer(box(green), rect: Rect(x: 1400, y: 300, width: 200, height: 100)),
            layer(box(green), rect: Rect(x: 500, y: -300, width: 200, height: 100)),
            layer(.text(TextAnnotation(string: "", preset: .plain)), rect: Rect(x: 500, y: 300, width: 200, height: 0)),
            layer(.image(ImageAnnotation(asset: "assets/none.png", fit: .fit)), rect: Rect(x: 500, y: 300, width: 200, height: 100)),
        ]
        var counts = DrawCounts()
        #expect(try drawer.draw(frame(content: unseen, output: unseen), counts: &counts) == plain)
        #expect(counts.contentAnnotations == 0 && counts.outputAnnotations == 0, "\(counts)")
        // Only the empty text was looked at (it has nothing to draw), once for both groups.
        #expect(drawer.rasters.drawCount == 1)
        // At 50 %: half of green over the screen.
        let half = try drawer.draw(frame(output: [layer(box(green), rect: Rect(x: 500, y: 300, width: 200, height: 100), opacity: 0.5)]))
        let under = at(plain, 600, 350), blended = at(half, 600, 350)
        #expect(abs(blended.y - (128 + under.y / 2)) <= 2 && abs(blended.z - under.z / 2) <= 2, "\(blended) over \(under)")
        // Turned 90° about its centre (640, 360): 200 × 50 becomes 50 × 200.
        let bar = layer(box(green), rect: Rect(x: 540, y: 335, width: 200, height: 50), rotation: 90)
        let turned = try drawer.draw(frame(output: [bar]))
        #expect(close(at(turned, 640, 440), bgra(green)) && at(turned, 720, 360) == at(plain, 720, 360))
        // Popped to 0.9 about its centre: 180 × 45.
        var popped = bar
        popped.rotation = 0
        popped.scale = 0.9
        let small = try drawer.draw(frame(output: [popped]))
        #expect(close(at(small, 552, 360), bgra(green)) && at(small, 545, 360) == at(plain, 545, 360))
        #expect(close(at(small, 640, 360), bgra(green)) && at(small, 640, 336) == at(plain, 640, 336))
    }

    /// The preview (`PreviewRenderer.snapshot`) draws the export's bytes with a text of each style, an arrow, a shape, a
    /// speech bubble and a step, stuck to the recording (through a zoom) and of the output, as they come in (fading,
    /// popping, being drawn) and once they are in.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func previewEqualsExportWithAnnotations() async throws {
        try await withTemporaryDirectory { dir in
            let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
            let builder = try TakeBuilder(in: dir)
            try await builder.addVideoTrack(
                id: trackID, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
            try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
            let project = try builder.write()
            var document = EditDocument.legacy(for: project)
            let take = project.take.id
            let stuck = AnnotationAnchor.content(take: take, start: base.adding(seconds: 0.2), end: base.adding(seconds: 2.8))
            let over = AnnotationAnchor.output(start: TimeMap.outputNanoseconds(seconds: 0.2), end: TimeMap.outputNanoseconds(seconds: 2.8))
            func text(_ string: String, _ preset: TextPreset) -> AnnotationKind {
                .text(TextAnnotation(string: string, preset: preset, font: preset == .title ? .serif : .system))
            }
            let kinds: [(AnnotationKind, NormalizedRect, AnnotationEnter)] = [
                (text("Plain text", .plain), NormalizedRect(x: 0.05, y: 0.05, width: 0.3, height: 0.1), .fade),
                (text("A label", .label), NormalizedRect(x: 0.4, y: 0.05, width: 0.25, height: 0.1), .pop),
                (text("Ana Pérez\nDesign", .lowerThird), NormalizedRect(x: 0.05, y: 0.7, width: 0.3, height: 0.1), .fade),
                (text("Title", .title), NormalizedRect(x: 0.6, y: 0.4, width: 0.3, height: 0.1), .pop),
                (.arrow(ArrowAnnotation(
                    from: NormalizedPoint(x: 0.2, y: 0.4), to: NormalizedPoint(x: 0.45, y: 0.55), curve: 0.3, head: .filled)),
                 NormalizedRect(x: 0, y: 0, width: 1, height: 1), .draw),
                (.shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(1, 1, 0, 0.3))), NormalizedRect(x: 0.5, y: 0.6, width: 0.3, height: 0.25), .draw),
                (.callout(CalloutAnnotation(
                    text: TextAnnotation(string: "Here", preset: .label, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1)),
                    target: NormalizedPoint(x: 0.75, y: 0.35))), NormalizedRect(x: 0.7, y: 0.1, width: 0.2, height: 0.1), .pop),
                (.step(StepAnnotation()), NormalizedRect(x: 0.46, y: 0.44, width: 0.07, height: 0.07), .fade),
            ]
            var items: [Annotation] = []
            for (index, (kind, rect, enter)) in kinds.enumerated() {
                for (group, anchor) in [(0, stuck), (1, over)] {
                    var moved = rect
                    moved.y += group == 1 ? 0.02 : 0
                    items.append(Annotation(
                        id: String(format: "a-%08x", 2 * index + group), anchor: anchor, layer: index, kind: kind, rect: moved,
                        rotation: index == 0 && group == 1 ? 8 : 0, enter: enter, exit: .fade))
                }
            }
            document.annotations = AnnotationPlan(items: items)
            document.zoom.regions = [StageDrawing.zoom(1, from: 1, to: 2.8, depth: 1.6, focus: .fixed(x: 0.4, y: 0.5))]
            // The export's renderer draws its frames in order, so it draws ahead what the next ones show; the preview's is
            // another, which draws each in its frame: fresh bitmaps, the same bytes.
            let renderer = try FrameRenderer(project: project, document: document, outputSize: [1280, 720])
            let legacy = try FrameRenderer(project: project, outputSize: [1280, 720])
            let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, document: document, outputSize: [1280, 720]))
            #expect(!renderer.scene.frame(at: 0).annotationsAhead.isEmpty, "the annotations coming in at 0.2 s")
            for t in [0, 0.3, 0.42, 1.2, 1.9] {
                let exported = try await offThePool {
                    var created: CVPixelBuffer?
                    let attributes = [
                        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
                    ] as CFDictionary
                    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, attributes, &created)
                    let pixelBuffer = try #require(created)
                    try renderer.render(at: t, into: pixelBuffer)
                    return packedBytes(of: pixelBuffer)
                }
                let previewed = try await offThePool { try preview.snapshot(at: t) }
                let without = try await offThePool { try legacy.renderBytes(at: t) }
                #expect(exported == previewed, "at \(t) s")
                #expect(t == 0 || exported != without, "at \(t) s, the annotations drawn")
            }
            let frame = renderer.scene.frame(at: 0.3)
            #expect(frame.contentAnnotations.count == kinds.count && frame.outputAnnotations.count == kinds.count)
        }
    }

    /// Ten annotations (five stuck to the recording, five of the output) coming in together, an arrow and a shape drawn in,
    /// and a zoom of 2.4× coming in over five of them: every bitmap of every frame drawn ahead by the frames before it
    /// (`RenderFrame.annotationsAhead`), none in a frame's encoding, and the same bytes as drawn in the frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func annotationBitmapsAreDrawnAhead() throws {
        let (take, events, document) = Self.comingInTogether()
        let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
        let fps = scene.frameRate
        let drawer = try AnnotationDrawer()
        let fresh = try AnnotationDrawer()
        var shown = 0, depths: Set<Double> = [], inline: [Int] = []
        for n in (6 * fps / 10)...(26 * fps / 10) {
            let frame = scene.frame(at: Double(TimeMap.frameTime(n, frameRate: fps)) / 1e9)
            let before = drawer.rasters.inlineDrawCount
            let bytes = try drawer.draw(frame)
            if drawer.rasters.inlineDrawCount != before { inline.append(n) }
            drawer.rasters.waitUntilDrawnAhead()
            shown = max(shown, frame.contentAnnotations.count + frame.outputAnnotations.count)
            depths.insert(AnnotationRaster.contentDepth(of: frame))
            if n % 7 == 0 {
                var alone = frame
                alone.annotationsAhead = []
                #expect(try fresh.draw(alone) == bytes, "frame \(n)")
            }
        }
        #expect(shown == 10)
        #expect(depths.contains(1) && depths.contains { $0 > 2 }, "\(depths.sorted())")
        #expect(drawer.rasters.inlineDrawCount == 0, "\(drawer.rasters.inlineDrawCount) of \(drawer.rasters.drawCount) drawn in frames \(inline)")
        #expect(drawer.rasters.drawCount > 10)
        #expect(fresh.rasters.inlineDrawCount == fresh.rasters.drawCount)
    }

    /// A frame that shows 40 layers, more than `AnnotationRasters.kept`, keeps them all: the next frame draws none again.
    /// So do eight bitmaps of a deep zoom, more than `maxBytes`; once the frames go on to others, they go.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func visibleBitmapsAreNeverDropped() throws {
        let drawer = try AnnotationDrawer()
        var forty: [AnnotationLayer] = []
        for i in 0..<40 {
            let f = Double(i) / 40
            let rect = Rect(x: Double(i % 8) * 155 + 20, y: Double(i / 8) * 135 + 20, width: 120, height: 100)
            forty.append(layer(box(RGBA(f, 0.5, 1 - f, 1)), rect: rect))
        }
        for _ in 0..<3 { _ = try drawer.draw(frame(output: forty)) }
        #expect(drawer.rasters.drawCount == 40 && drawer.rasters.inlineDrawCount == 40)
        #expect(drawer.rasters.keptCount.textures == 40)
        // Eight layers of 1000 × 600 at 4×, about 38 MB each.
        var large: [AnnotationLayer] = []
        for i in 0..<8 {
            large.append(layer(box(RGBA(1, Double(i) / 8, 0, 1)), rect: Rect(x: 140, y: 60, width: 1000, height: 600)))
        }
        var deep = frame(content: large)
        deep.stage = StageTransform(depth: 3.5, center: [640, 360])
        for _ in 0..<3 { _ = try drawer.draw(deep) }
        #expect(drawer.rasters.drawCount == 48, "\(drawer.rasters.drawCount)")
        #expect(drawer.rasters.keptCount.bytes > AnnotationRasters.maxBytes, "\(drawer.rasters.keptCount)")
        // The forty, which those frames did not use, went while they were kept past `maxBytes`; frames of four of them draw
        // those again, and the eight large ones, which no frame uses any more, go.
        for _ in 0..<3 { _ = try drawer.draw(frame(output: Array(forty.prefix(4)))) }
        #expect(drawer.rasters.drawCount == 52, "\(drawer.rasters.drawCount)")
        #expect(drawer.rasters.keptCount.bytes <= AnnotationRasters.maxBytes, "\(drawer.rasters.keptCount)")
        #expect(drawer.rasters.keptCount.textures <= AnnotationRasters.kept)
    }

    /// Five kinds coming in together at 1 s, stuck to the recording and of the output, and a zoom of 2.4× from 1.6 s: the
    /// take, its events and the document of `annotationBitmapsAreDrawnAhead` and its measure.
    static func comingInTogether(allStuck: Bool = false) -> (take: TakeRecord, events: [InputEvent], document: EditDocument) {
        let take = StageDrawing.bareTake(seconds: 4)
        let events = cursorEvents(from: base, seconds: 4, across: Rect(x: 0, y: 0, width: 640, height: 360))
        var document = EditDocument.legacy(take: take, events: events)
        let stuck = AnnotationAnchor.content(take: takeID, start: base.adding(seconds: 1), end: base.adding(seconds: 3.8))
        let over = AnnotationAnchor.output(start: TimeMap.outputNanoseconds(seconds: 1), end: TimeMap.outputNanoseconds(seconds: 3.8))
        let label: AnnotationKind = .text(TextAnnotation(string: "Open the settings", preset: .label))
        let arrow: AnnotationKind = .arrow(ArrowAnnotation(
            from: NormalizedPoint(x: 0.2, y: 0.6), to: NormalizedPoint(x: 0.45, y: 0.45), curve: 0.3, head: .filled))
        let shape: AnnotationKind = .shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(1, 1, 0, 0.3)))
        let bubbleText = TextAnnotation(string: "Here", preset: .label, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1))
        let callout: AnnotationKind = .callout(CalloutAnnotation(text: bubbleText, target: NormalizedPoint(x: 0.75, y: 0.35)))
        let step: AnnotationKind = .step(StepAnnotation())
        var kinds: [(AnnotationKind, NormalizedRect, AnnotationEnter)] = []
        kinds.append((label, NormalizedRect(x: 0.05, y: 0.05, width: 0.35, height: 0.1), .fade))
        kinds.append((arrow, NormalizedRect(x: 0, y: 0, width: 1, height: 1), .draw))
        kinds.append((shape, NormalizedRect(x: 0.5, y: 0.55, width: 0.3, height: 0.25), .draw))
        kinds.append((callout, NormalizedRect(x: 0.7, y: 0.1, width: 0.2, height: 0.1), .pop))
        kinds.append((step, NormalizedRect(x: 0.46, y: 0.4, width: 0.07, height: 0.07), .fade))
        var items: [Annotation] = []
        for (index, (kind, rect, enter)) in kinds.enumerated() {
            for (group, anchor) in [(0, stuck), (1, allStuck ? stuck : over)] {
                var moved = rect
                moved.y += group == 1 ? 0.03 : 0
                items.append(Annotation(
                    id: String(format: "a-%08x", 2 * index + group), anchor: anchor, layer: index, kind: kind, rect: moved, enter: enter,
                    exit: .fade))
            }
        }
        document.annotations = AnnotationPlan(items: items)
        document.zoom.regions = [StageDrawing.zoom(1, from: 1.6, to: 3.6, depth: 2.4, focus: .fixed(x: 0.4, y: 0.5))]
        return (take, events, document)
    }

    /// The preview's budget at 1080p with ten annotations (phase 3 design §15): what the CPU takes to encode a frame with
    /// them and what the GPU takes to draw it, against the frame without them, once their bitmaps are made, and the first
    /// frame that makes them; and a frame of an arrow and a shape being drawn in (a bitmap each, every frame).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func tenAnnotationsWithinTheFrameBudget() throws {
        let size1080 = SIMD2(1920, 1080)
        let whole = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let drawer = try AnnotationDrawer()
        let screen = try StageDrawing.screenTexture(device: drawer.device, width: 1920, height: 1080)
        let target = try StageDrawing.target(device: drawer.device, size: size1080)
        func textLayer(_ text: TextAnnotation, _ rect: Rect) -> AnnotationLayer {
            var rect = rect
            rect.height = AnnotationTypography.box(of: text, width: rect.width, unit: 1080).y
            return layer(.text(text), rect: rect, space: whole)
        }
        func arrowLayer(_ arrow: ArrowAnnotation, drawn: Double = 1) -> AnnotationLayer {
            var made = layer(
                .arrow(arrow, path: AnnotationGeometry.arrow(arrow, in: whole)),
                rect: AnnotationGeometry.pixels(AnnotationGeometry.arrowRect(arrow, aspect: 16.0 / 9), in: whole), space: whole)
            made.drawn = drawn
            return made
        }
        let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.6), to: NormalizedPoint(x: 0.5, y: 0.4), curve: 0.3, head: .filled)
        var shape = layer(.shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(1, 1, 0, 0.2))), rect: Rect(x: 1100, y: 500, width: 500, height: 300), space: whole)
        let callout = CalloutAnnotation(
            text: TextAnnotation(string: "Click here to start", preset: .label, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1)),
            target: NormalizedPoint(x: 0.6, y: 0.5))
        let calloutBox = Rect(
            x: 1300, y: 150, width: 400,
            height: AnnotationTypography.box(of: callout.text, width: 400, unit: 1080, padding: .label).y)
        let tail = AnnotationGeometry.calloutTail(
            bubble: calloutBox, cornerRadius: 0.35 * 0.05 * 1080, target: SIMD2(0.6 * 1920, 0.5 * 1080), em: 0.05 * 1080)
        let content = [
            textLayer(TextAnnotation(string: "Step one: open the settings", preset: .plain), Rect(x: 100, y: 80, width: 700, height: 0)),
            textLayer(TextAnnotation(string: "New", preset: .label), Rect(x: 900, y: 80, width: 200, height: 0)),
            arrowLayer(arrow), shape,
            layer(.callout(callout, tail: tail), rect: calloutBox, space: whole),
            layer(.step(StepAnnotation(), number: 1), rect: Rect(x: 880, y: 470, width: 76, height: 76), space: whole),
            layer(.step(StepAnnotation(), number: 2), rect: Rect(x: 1000, y: 700, width: 76, height: 76), space: whole),
        ]
        let overlays = [
            textLayer(TextAnnotation(string: "Ana Pérez\nProduct design", preset: .lowerThird), Rect(x: 100, y: 820, width: 640, height: 0)),
            textLayer(TextAnnotation(string: "Getting started", preset: .title, size: 0.08), Rect(x: 560, y: 380, width: 800, height: 0)),
            textLayer(TextAnnotation(string: "Toma", preset: .label, size: 0.04), Rect(x: 1700, y: 40, width: 180, height: 0)),
        ]
        /// `layer` 7 pixels lower: another bitmap of the same.
        func moved(_ layer: AnnotationLayer) -> AnnotationLayer {
            var moved = layer
            moved.rect.y += 7
            if case let .arrow(arrow, path) = layer.content {
                let down = SIMD2(0.0, 7)
                moved.content = .arrow(
                    arrow, path: AnnotationGeometry.ArrowPath(
                        start: path.start + down, control: path.control + down, end: path.end + down,
                        shaftEnd: path.shaftEnd + down, head: path.head.map { $0 + down }))
            }
            return moved
        }
        func frame(_ content: [AnnotationLayer], _ overlays: [AnnotationLayer]) -> RenderFrame {
            RenderFrame(
                outputSize: size1080, gradientStart: gradientStart, gradientEnd: gradientEnd, gradientAngleDegrees: 30,
                screen: ScreenLayer(trackID: trackID, sourceTime: base, rect: whole, cornerRadius: 0),
                contentAnnotations: content, outputAnnotations: overlays)
        }
        /// What the CPU took to encode `frame` and what the GPU took to draw it, in ms.
        func time(_ frame: RenderFrame) throws -> (cpu: Double, gpu: Double) {
            let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
            let start = DispatchTime.now().uptimeNanoseconds
            try drawer.compositor.encode(frame, screen: screen, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer)
            let cpu = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return (cpu, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        let ten = frame(content, overlays)
        #expect(ten.contentAnnotations.count + ten.outputAnnotations.count == 10)
        let first = try time(ten)
        // Ten others, all new, once the fonts are loaded: what a jump to them costs in a session already drawing.
        let others = frame(content.map { moved($0) }, overlays.map { moved($0) })
        let fresh = try time(others)
        func medians(_ frames: [() -> RenderFrame]) throws -> [(cpu: Double, gpu: Double)] {
            var times = Array(repeating: [(cpu: Double, gpu: Double)](), count: frames.count)
            for round in 0..<65 {
                for (i, frame) in frames.enumerated() {
                    let measured = try time(frame())
                    if round >= 5 { times[i].append(measured) }
                }
            }
            return times.map { ($0.map(\.cpu).sorted()[$0.count / 2], $0.map(\.gpu).sorted()[$0.count / 2]) }
        }
        var step = 0
        let m = try medians([
            { frame([], []) }, { ten },
            {
                // An arrow and a shape being drawn in: a new fraction every frame.
                step += 1
                let drawn = 0.2 + 0.6 * Double(step % 97) / 97
                shape.drawn = drawn
                var drawing = content
                drawing[2] = arrowLayer(arrow, drawn: drawn)
                drawing[3] = shape
                return frame(drawing, overlays)
            },
        ])
        print(String(
            format: "Annotations at 1080p, ms (CPU encode / GPU): none %.3f / %.3f; ten %.3f / %.3f; first frame with ten %.3f / %.3f; "
                + "ten new, fonts loaded, %.3f / %.3f; ten with an arrow and a shape being drawn %.3f / %.3f; bitmaps made %d",
            m[0].cpu, m[0].gpu, m[1].cpu, m[1].gpu, first.cpu, first.gpu, fresh.cpu, fresh.gpu, m[2].cpu, m[2].gpu,
            drawer.rasters.drawCount))
        #expect(m[1].cpu + m[1].gpu < 1000.0 / 60, "\(m[1])")
        #expect(m[2].cpu + m[2].gpu < 1000.0 / 60, "\(m[2])")
    }

    /// What drawing ahead saves at 1080p (A6's review): the most a frame's encoding takes on the CPU (and the GPU its
    /// drawing), frames drawn one after the other at the frame rate, while ten annotations come in together (five stuck to
    /// the recording, five of the output, two of them drawn in) and while a zoom of 2.4× comes in over ten stuck to the
    /// recording; with the frames' annotations ahead, and without them (every bitmap in its frame).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func drawingAheadKeepsTheFrames() throws {
        let size1080 = SIMD2(1920, 1080)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let screen = try StageDrawing.screenTexture(device: device, width: 1920, height: 1080)
        let cursor = try CursorSprite.makeTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let target = try StageDrawing.target(device: device, size: size1080)
        /// The most a frame took over `range` (seconds), CPU and GPU, in ms, the frames of `scene` drawn in order by a new
        /// compositor at the frame rate, ahead or not, after its first (which draws what it shows, as after a jump); and
        /// how many bitmaps were drawn in a frame after the first.
        func worst(_ scene: FrameEvaluator, _ range: ClosedRange<Double>, ahead: Bool) throws -> (cpu: Double, gpu: Double, inline: Int) {
            let compositor = try Compositor(device: device)
            let fps = scene.frameRate
            var cpu = 0.0, gpu = 0.0, first = 0
            let frames = Int(range.lowerBound * Double(fps))...Int(range.upperBound * Double(fps))
            for n in frames {
                if n == frames.lowerBound + 1 { (cpu, gpu, first) = (0, 0, compositor.layers.annotations.rasters.inlineDrawCount) }
                let start = DispatchTime.now().uptimeNanoseconds
                var frame = scene.frame(at: Double(TimeMap.frameTime(n, frameRate: fps)) / 1e9)
                if !ahead { frame.annotationsAhead = [] }
                let commandBuffer = try #require(queue.makeCommandBuffer())
                let encode = DispatchTime.now().uptimeNanoseconds
                try compositor.encode(frame, screen: screen, camera: nil, cursor: cursor, into: target, commandBuffer: commandBuffer)
                cpu = max(cpu, Double(DispatchTime.now().uptimeNanoseconds - encode) / 1e6)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                gpu = max(gpu, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
                // The next frame at the frame rate.
                let spent = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if spent < 1 / Double(fps) { Thread.sleep(forTimeInterval: 1 / Double(fps) - spent) }
            }
            return (cpu, gpu, compositor.layers.annotations.rasters.inlineDrawCount - first)
        }
        let together = Self.comingInTogether()
        let entering = FrameEvaluator(take: together.take, events: together.events, document: together.document, outputSize: size1080)
        let stuck = Self.comingInTogether(allStuck: true)
        let zooming = FrameEvaluator(take: stuck.take, events: stuck.events, document: stuck.document, outputSize: size1080)
        // The fonts loaded once, as in an editor already drawing.
        _ = try worst(entering, 0.9...1.1, ahead: false)
        var lines: [String] = []
        for (name, scene, range) in [("ten coming in", entering, 0.6...1.4), ("a zoom over ten", zooming, 1.4...2.8)] {
            let with = try worst(scene, range, ahead: true), without = try worst(scene, range, ahead: false)
            lines.append(String(
                format: "%@: ahead %.3f / %.3f ms (%d in a frame), without %.3f / %.3f ms (%d in a frame)", name, with.cpu, with.gpu,
                with.inline, without.cpu, without.gpu, without.inline))
            #expect(with.cpu + with.gpu < 1000.0 / 60, "\(name): \(with)")
        }
        print("Annotations drawn ahead at 1080p, the worst frame (CPU encode / GPU): " + lines.joined(separator: "; "))
    }
}
