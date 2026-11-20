// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, `StageTransform.outputRect(ofStage:outputSize:)` and `CalmZoomLook`.
@testable import Render
import simd
import Testing

/// Every frame with its calm zoom, drawn (phase 3 design §6 and §12, step 4, plan 3b Task Z4): the same bytes in the
/// preview and the export and on every drawing, the loupe magnifying the frame as drawn (the privacy on it, never the
/// screen's texture), and in a split the focus in the screen's card. Over takes of golden 3 (`GoldenDocuments`), with
/// calm blocks added to their documents.

/// The takes of `zoomWithBlur`, `privacyManual` and `portraitSplit`, written once for the suite into a temporary folder
/// removed after it: writing them takes the hardware encoder some seconds each.
private struct CalmZoomProjects: SuiteTrait, TestScoping {
    @TaskLocal static var projects: [String: LoadedProject] = [:]

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { dir in
            var projects: [String: LoadedProject] = [:]
            for name in ["zoomWithBlur", "privacyManual", "portraitSplit"] {
                projects[name] = try await GoldenDocuments.makeProject(name, in: dir)
            }
            try await Self.$projects.withValue(projects) { try await function() }
        }
    }
}

extension Trait where Self == CalmZoomProjects {
    fileprivate static var calmZoomProjects: Self { Self() }
}

/// The project of golden case `name` and its document, with `change` made to it.
private func golden(
    _ name: String, _ change: (inout EditDocument, _ take: String, _ source: (Double) -> HostTime) -> Void = { _, _, _ in }
) throws -> (project: LoadedProject, document: EditDocument) {
    let project = try #require(CalmZoomProjects.projects[name])
    var document = try GoldenDocuments.makeDocument(name, for: project)
    let start = try #require(document.sequence.first).start
    change(&document, project.take.id) { start.adding(seconds: $0) }
    return (project, document)
}

/// A block of the user's in `mode` over [`from`, `to`) s of the take at the fixed point (`x`, `y`) of the screen.
private func calmBlock(
    _ mode: ZoomMode?, take: String, _ source: (Double) -> HostTime, from: Double, to: Double, depth: Double = 2,
    x: Double = 0.5, y: Double = 0.5
) -> ZoomRegion {
    var region = ZoomRegion(
        id: "z-0000c0de", take: take, start: source(from), end: source(to), origin: .user, depth: depth,
        focus: .fixed(x: x, y: y), instant: false)
    region.mode = mode
    return region
}

/// `zoomWithBlur` with its block in `mode`.
private func zoomWithBlur(_ mode: ZoomMode) throws -> (project: LoadedProject, document: EditDocument) {
    try golden("zoomWithBlur") { document, _, _ in document.zoom.regions[0].mode = mode }
}

/// `renderer`'s frame at `t` drawn through the export path, `render(at:into:)` into a new pixel buffer of its size, as
/// its bytes.
private func exported(_ renderer: FrameRenderer, at t: Double) async throws -> [UInt8] {
    let size = renderer.outputSize
    return try await offThePool {
        var created: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw TestSupportError.failed("no pixel buffer of \(size): \(status)")
        }
        try renderer.render(at: t, into: pixelBuffer)
        return packedBytes(of: pixelBuffer)
    }
}

/// Pixel (`x`, `y`) of an image of `width`, its four channels as numbers.
private func at(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> SIMD4<Double> {
    let p = pixel(bytes, width: width, x: x, y: y)
    return SIMD4(Double(p.x), Double(p.y), Double(p.z), Double(p.w))
}

private func near(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ tolerance: Double) -> Bool {
    (0..<4).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
}

/// The image `bytes` of `size` read bilinearly at `q` (output pixels, the centre of pixel (0, 0) at (0.5, 0.5)).
private func bilinear(_ bytes: [UInt8], at q: SIMD2<Double>, size: SIMD2<Int>) -> SIMD4<Double> {
    let p = q - 0.5, x0 = Int(p.x.rounded(.down)), y0 = Int(p.y.rounded(.down))
    let fx = p.x - Double(x0), fy = p.y - Double(y0)
    func texel(_ x: Int, _ y: Int) -> SIMD4<Double> {
        at(bytes, min(max(x, 0), size.x - 1), min(max(y, 0), size.y - 1), width: size.x)
    }
    let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
    let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
    return top * (1 - fy) + bottom * fy
}

@Suite(.calmZoomProjects)
struct CalmZoomRenderTests {
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func previewEqualsExportWithEachCalmMode() async throws {
        let (project, plain) = try zoomWithBlur(.classic)
        var none = plain
        none.zoom.regions = []
        let size = GoldenDocuments.outputSize(of: plain)
        let unzoomed = try FrameRenderer(project: project, document: none, outputSize: size)
        for mode: ZoomMode in [.highlight, .dim, .loupe] {
            let (_, document) = try zoomWithBlur(mode)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let preview = PreviewRenderer(renderer: renderer)
            for t in [0.7, 1.5, 2.6] {
                #expect(renderer.scene.frame(at: t).calmZoom != nil, "\(mode) at \(t) s")
                let export = try await exported(renderer, at: t)
                #expect(export == (try await offThePool { try preview.snapshot(at: t) }), "\(mode) at \(t) s")
                // The effect is drawn: the stage itself is the frame without a zoom.
                #expect(export != (try await exported(unzoomed, at: t)), "\(mode) at \(t) s")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func everyCalmModeRendersTheSameTwice() async throws {
        for mode: ZoomMode in [.highlight, .dim, .loupe] {
            let (project, document) = try zoomWithBlur(mode)
            let size = GoldenDocuments.outputSize(of: document)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let other = try FrameRenderer(project: project, document: document, outputSize: size)
            for t in [1.0, 2.6] {
                let (first, second, third) = try await offThePool {
                    (try renderer.renderBytes(at: t), try renderer.renderBytes(at: t), try other.renderBytes(at: t))
                }
                #expect(first == second && first == third, "\(mode) at \(t) s")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func loupeMagnifiesThePrivacyNotTheScreen() async throws {
        // The lens over the blur at the top left ([0.06, 0.40] × [0.08, 0.34] of the screen), 3× at its middle, from
        // 0.3 s on: at 2 s it has settled.
        let (project, lensed) = try golden("privacyManual") { document, take, source in
            document.zoom.regions = [calmBlock(.loupe, take: take, source, from: 0.3, to: 3.6, depth: 3, x: 0.23, y: 0.21)]
        }
        var plain = lensed
        plain.zoom.regions = []
        var bare = plain
        bare.privacy.blocks = []
        let size = SIMD2(1280, 720), t = 2.0
        func draw(_ document: EditDocument) async throws -> [UInt8] {
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            return try await offThePool { try renderer.renderBytes(at: t) }
        }
        let frame = FrameEvaluator(
            take: project.take, events: project.events, document: lensed, outputSize: size).frame(at: t)
        let layer = try #require(frame.calmZoom)
        let lens = try #require(layer.loupe)
        #expect(frame.stage == nil && layer.amount > 0.999 && abs(lens.magnification - 3) < 1e-3, "\(layer)")
        let screen = try #require(frame.screen?.rect)
        let c = SIMD2(layer.focus.x + layer.focus.width / 2, layer.focus.y + layer.focus.height / 2)
        // What the lens shows is inside the blurred block.
        let block = Rect(
            x: screen.x + 0.06 * screen.width, y: screen.y + 0.08 * screen.height, width: 0.34 * screen.width,
            height: 0.26 * screen.height)
        let shown = lens.radius / lens.magnification
        #expect(
            c.x - shown > block.x && c.x + shown < block.x + block.width && c.y - shown > block.y
                && c.y + shown < block.y + block.height, "\(c) ± \(shown) in \(block)")

        let (drawn, under, unblurred) = (try await draw(lensed), try await draw(plain), try await draw(bare))
        var inside = 0, unlike = 0
        for y in stride(from: Int(c.y - lens.radius), through: Int(c.y + lens.radius), by: 2) {
            for x in stride(from: Int(c.x - lens.radius), through: Int(c.x + lens.radius), by: 2) {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                guard simd_length(p - c) < 0.8 * lens.radius else { continue }
                let q = c + (p - c) / lens.magnification
                let expected = bilinear(under, at: q, size: size)
                let shown = at(drawn, x, y, width: size.x)
                #expect(near(shown, expected, 2), "(\(x), \(y)): \(shown) \(expected)")
                inside += 1
                if !near(shown, bilinear(unblurred, at: q, size: size), 24) { unlike += 1 }
            }
        }
        #expect(inside > 2000, "\(inside)")
        // The checkered screen under it, unblurred, is something else.
        #expect(unlike > inside / 4, "\(unlike) of \(inside)")
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aSplitShowsTheFocusInTheCard() async throws {
        // Highlight at 2× over [0.3, 1.9) s, at a point left of the screen's middle, under the Split of [0, 2) s.
        let (project, lit) = try golden("portraitSplit") { document, take, source in
            document.zoom.regions = [calmBlock(.highlight, take: take, source, from: 0.3, to: 1.9, x: 0.3, y: 0.6)]
        }
        var plain = lit
        plain.zoom.regions = []
        let size = GoldenDocuments.outputSize(of: lit), t = 1.5
        let readable = LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
        let evaluator = FrameEvaluator(
            take: project.take, events: project.events, document: lit, outputSize: size, cameraReadable: readable)
        let frame = evaluator.frame(at: t)
        let card = try #require(frame.card)
        let content = try #require(frame.screen?.rect)
        let layer = try #require(frame.calmZoom)
        let depth = try #require(evaluator.paths.calmZoom?.state(atOutput: TimeMap.outputNanoseconds(seconds: t))).depth
        #expect(layer.mode == .highlight && layer.amount > 0.99 && card.mix == 1 && abs(depth - 2) < 1e-3, "\(layer) \(card)")
        // The crop the card's zoom would show: the content over the depth, about the point, inside the card.
        let focus = layer.focus
        #expect(
            abs(focus.width - content.width / depth) < 1e-6 && abs(focus.height - content.height / depth) < 1e-6,
            "\(focus) \(content)")
        let middle = SIMD2(focus.x + focus.width / 2, focus.y + focus.height / 2)
        #expect(
            abs(middle.x - (content.x + 0.3 * content.width)) < 1 && abs(middle.y - (content.y + 0.6 * content.height)) < 1,
            "\(middle) \(content)")
        let hole = card.content.outputRect(ofStage: focus, outputSize: size)
        #expect(
            hole.x >= card.rect.x && hole.y >= card.rect.y && hole.x + hole.width <= card.rect.x + card.rect.width
                && hole.y + hole.height <= card.rect.y + card.rect.height, "\(hole) in \(card.rect)")

        func draw(_ document: EditDocument) async throws -> [UInt8] {
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            return try await offThePool { try renderer.renderBytes(at: t) }
        }
        let (drawn, under) = (try await draw(lit), try await draw(plain))
        let pt = Double(min(size.x, size.y)) / 1080
        let corner = min(12 * pt, min(hole.width, hole.height) / 2)
        var inHole = 0, darkened = 0
        for y in stride(from: 0, to: size.y, by: 4) {
            for x in stride(from: 0, to: size.x, by: 4) {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                let inCard = p.x > card.rect.x + 2 && p.x < card.rect.x + card.rect.width - 2 && p.y > card.rect.y + 2
                    && p.y < card.rect.y + card.rect.height - 2
                guard inCard else { continue }
                let half = SIMD2(hole.width, hole.height) / 2
                let d = CalmZoomLook.roundedRectDistance(p - SIMD2(hole.x, hole.y) - half, halfSize: half, radius: corner)
                let shown = at(drawn, x, y, width: size.x), plainly = at(under, x, y, width: size.x)
                if d < -1 {
                    #expect(near(shown, plainly, 1), "hole at (\(x), \(y))")
                    inHole += 1
                } else if d > (3 + 6 * 6) * pt + 1 {
                    let expected = SIMD4(plainly.x * 0.8, plainly.y * 0.8, plainly.z * 0.8, plainly.w)
                    #expect(near(shown, expected, 1.5), "darkened at (\(x), \(y)): \(shown) \(expected)")
                    darkened += 1
                }
            }
        }
        #expect(inHole > 500 && darkened > 500, "\(inHole) \(darkened)")
    }
}
