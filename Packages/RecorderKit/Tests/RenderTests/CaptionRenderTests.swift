// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `CaptionScene`, `CaptionTextures`, `DrawCounts`, the compositor's counting `encode` and its layers.
@testable import Render
import Testing

/// The captions drawn (phase 2 design §5.2 and §11, plan 2a Task A8): each preset's look, the word being said, over
/// everything on every path, each texture drawn once, the preview drawing what the export does, and nothing of them in a
/// document without captions.

private let size1080 = SIMD2(1920, 1080)

/// A caption layer of `lines` in `style` placed as the scene places it in an output of `size`.
private func layer(
    _ lines: [String], style: CaptionStyle = .default, highlight: CaptionHighlight? = nil, size: SIMD2<Int> = size1080,
    language: String = "es-MX"
) throws -> CaptionLayer {
    let placed = try #require(CaptionScene.placement(of: lines, style: style, language: language, outputSize: size))
    return CaptionLayer(
        lines: lines, highlight: highlight, style: style, language: language, fontSize: placed.fontSize, box: placed.box)
}

private func style(_ preset: CaptionPreset, size: OverlaySize = .medium, position: CaptionPosition = .bottom, uppercase: Bool = false)
    -> CaptionStyle
{
    var style = CaptionStyle.default
    (style.preset, style.size, style.position, style.uppercase) = (preset, size, position, uppercase)
    style.highlight = preset == .bold
    return style
}

/// A frame of `size` over a flat background of `color` (straight RGBA from 0 to 1), with `captions` and nothing else.
private func flatFrame(_ captions: CaptionLayer?, color: SIMD4<Float>, size: SIMD2<Int> = size1080) -> RenderFrame {
    RenderFrame(outputSize: size, gradientStart: color, gradientEnd: color, gradientAngleDegrees: 0, captions: captions)
}

/// `color` (0 to 1) as the BGRA bytes the target holds.
private func bgra(_ color: SIMD4<Float>) -> SIMD4<UInt8> {
    SIMD4(UInt8((color.z * 255).rounded()), UInt8((color.y * 255).rounded()), UInt8((color.x * 255).rounded()), UInt8((color.w * 255).rounded()))
}

private func close(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>, _ tolerance: Int) -> Bool {
    (0..<4).allSatisfy { abs(Int(a[$0]) - Int(b[$0])) <= tolerance }
}

/// A compositor of the default device to draw caption frames with.
private struct CaptionDrawer: @unchecked Sendable {
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

    var textures: CaptionTextures { compositor.layers.captions.textures }

    func draw(_ frame: RenderFrame, screen: (any MTLTexture)? = nil) throws -> [UInt8] {
        var counts = DrawCounts()
        return try draw(frame, screen: screen, counts: &counts)
    }

    func draw(_ frame: RenderFrame, screen: (any MTLTexture)? = nil, counts: inout DrawCounts) throws -> [UInt8] {
        let target = try StageDrawing.target(device: device, size: frame.outputSize)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try compositor.encode(
            frame, screen: screen ?? self.screen, previousScreen: screen ?? self.screen, camera: camera, cursor: cursor, into: target,
            commandBuffer: commandBuffer, counts: &counts)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw TestSupportError.failed("GPU status \(commandBuffer.status.rawValue)") }
        return StageDrawing.bytes(of: target)
    }

    /// A `.bgra8Unorm` texture of `width` × `height` whose pixel at (`x`, `y`) is `bgra(x, y)`.
    func texture(width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> SIMD4<UInt8>) throws -> any MTLTexture {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = bgra(x, y), i = (y * width + x) * 4
                (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (p.x, p.y, p.z, p.w)
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }
}

/// The texels of `layer`'s bitmap that are opaque white (the inside of a letter), as output pixels.
private func opaqueWhite(of layer: CaptionLayer) throws -> [SIMD2<Int>] {
    let bitmap = try #require(try CaptionTextures.bitmap(of: layer))
    let region = try #require(CaptionTextures.region(of: layer))
    var points: [SIMD2<Int>] = []
    for y in 0..<region.size.y {
        for x in 0..<region.size.x {
            let i = (y * region.size.x + x) * 4
            if bitmap[i] == 255, bitmap[i + 1] == 255, bitmap[i + 2] == 255, bitmap[i + 3] == 255 {
                points.append(region.origin &+ SIMD2(x, y))
            }
        }
    }
    return points
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func classicDrawsItsBox() async throws {
    let caption = try layer(["Hola a todos, ¿cómo están?", "Hoy vamos a grabar la pantalla"], style: style(.classic))
    let background = SIMD4<Float>(0.2, 0.6, 0.8, 1)
    let bytes = try await offThePool { try CaptionDrawer().draw(flatFrame(caption, color: background)) }
    let box = caption.box, em = caption.fontSize
    // In the padding, left and right of the letters and between the lines' tops and the box's: the background through
    // black at 60 %.
    let expected = SIMD4<UInt8>(bgra(background * 0.4).x, bgra(background * 0.4).y, bgra(background * 0.4).z, 255)
    let points = [
        (box.x + 0.3 * em, box.y + box.height / 2), (box.x + box.width - 0.3 * em, box.y + box.height / 2),
        (box.x + box.width / 2, box.y + 0.15 * em), (box.x + box.width / 2, box.y + box.height - 0.1 * em),
    ]
    for (x, y) in points {
        let drawn = pixel(bytes, width: size1080.x, x: Int(x), y: Int(y))
        #expect(close(drawn, expected, 2), "(\(x), \(y)): \(drawn) for \(expected)")
    }
    // Outside the box, the background; the box's edges are on whole pixels, so the pixel just outside is untouched.
    for (x, y) in [(box.x.rounded() - 1, box.y + box.height / 2), (box.x + box.width / 2, box.y.rounded() - 1)] {
        #expect(pixel(bytes, width: size1080.x, x: Int(x), y: Int(y)) == bgra(background), "(\(x), \(y))")
    }
    // The letters are white over it.
    let white = try opaqueWhite(of: caption)
    #expect(white.count > 1000)
    #expect(white.allSatisfy { pixel(bytes, width: size1080.x, x: $0.x, y: $0.y) == [255, 255, 255, 255] })
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func textureIsDrawnOneTexelAPixel() async throws {
    // Over a flat opaque background, every pixel of the region is the texel over it, blended premultiplied "over".
    let background = SIMD4<Float>(0.2, 0.4, 0.6, 1)
    for preset in CaptionPreset.allCases {
        let caption = try layer(
            ["Año nuevo, señal clara", "¿Qué ángulo elegís, Ñuño?"], style: style(preset), highlight: CaptionHighlight(line: 1, range: 4..<10))
        let bytes = try await offThePool { try CaptionDrawer().draw(flatFrame(caption, color: background)) }
        let bitmap = try #require(try CaptionTextures.bitmap(of: caption))
        let region = try #require(CaptionTextures.region(of: caption))
        let under = bgra(background)
        var worst = 0
        for y in 0..<region.size.y {
            for x in 0..<region.size.x {
                let i = (y * region.size.x + x) * 4
                let drawn = pixel(bytes, width: size1080.x, x: region.origin.x + x, y: region.origin.y + y)
                for c in 0..<3 {
                    let texel = Double(bitmap[i + c]), alpha = Double(bitmap[i + 3]) / 255
                    let expected = texel + Double(under[c]) * (1 - alpha)
                    worst = max(worst, Int(abs(Double(drawn[c]) - expected).rounded(.up)))
                }
            }
        }
        #expect(worst <= 1, "\(preset): \(worst)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func boldHighlightsTheWordBeingSaid() async throws {
    let lines = ["Uno dos tres"]
    let caption = try layer(lines, style: style(.bold), highlight: CaptionHighlight(line: 0, range: 4..<7))
    let background = SIMD4<Float>(0.1, 0.1, 0.4, 1)
    let bytes = try await offThePool { try CaptionDrawer().draw(flatFrame(caption, color: background)) }
    // Where each word is: the line centred in the box.
    let font = try #require(CaptionTypography.font(for: caption))
    func width(_ text: String) -> Double { CaptionTypography.width(of: text, font: font, layer: caption) }
    let start = caption.box.x + (caption.box.width - width(lines[0])) / 2
    let said = (start + width("Uno "))...(start + width("Uno dos"))
    let yellow = SIMD4<UInt8>(10, 214, 255, 255)
    let region = try #require(CaptionTextures.region(of: caption))
    var (inside, outside) = (0, 0)
    for y in region.origin.y..<(region.origin.y + region.size.y) {
        for x in region.origin.x..<(region.origin.x + region.size.x) where close(pixel(bytes, width: size1080.x, x: x, y: y), yellow, 3) {
            if said.contains(Double(x)) { inside += 1 } else { outside += 1 }
        }
    }
    #expect(inside > 500 && outside == 0, "\(inside) inside, \(outside) outside")
    // Without the highlight, no yellow at all.
    var plain = caption
    plain.highlight = nil
    let unlitLayer = plain
    let unlit = try await offThePool { try CaptionDrawer().draw(flatFrame(unlitLayer, color: background)) }
    #expect(!stride(from: 0, to: unlit.count, by: 4).contains { close(SIMD4(unlit[$0], unlit[$0 + 1], unlit[$0 + 2], unlit[$0 + 3]), yellow, 3) })
    // The outline: black just outside the letters, left of the first one.
    let white = try opaqueWhite(of: caption)
    let left = try #require(white.min { $0.x < $1.x })
    let outline = pixel(bytes, width: size1080.x, x: left.x - Int((0.05 * caption.fontSize).rounded()), y: left.y)
    #expect(outline.x < 30 && outline.y < 30 && outline.z < 30, "\(outline)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func minimalHasNoBox() async throws {
    let lines = ["Sin caja, solo el texto", "con su sombra suave"]
    let background = SIMD4<Float>(0.5, 0.7, 0.3, 1)
    let minimal = try layer(lines, style: style(.minimal))
    let (bytes, classic, plain) = try await offThePool {
        let drawer = try CaptionDrawer()
        return (
            try drawer.draw(flatFrame(minimal, color: background)),
            try drawer.draw(flatFrame(try layer(lines, style: style(.classic)), color: background)),
            try drawer.draw(flatFrame(nil, color: background)))
    }
    let box = minimal.box, em = minimal.fontSize
    // Along the padding left and right of the letters, far from them and their shadow: the background exactly, where
    // Classic draws its box.
    for x in [box.x + 0.15 * em, box.x + box.width - 0.15 * em] {
        for y in stride(from: box.y + 2, to: box.y + box.height - 2, by: 3) {
            let under = pixel(plain, width: size1080.x, x: Int(x), y: Int(y))
            #expect(pixel(bytes, width: size1080.x, x: Int(x), y: Int(y)) == under, "(\(x), \(y))")
            #expect(pixel(classic, width: size1080.x, x: Int(x), y: Int(y)) != under)
        }
    }
    // The shadow darkens just under the letters.
    let white = try opaqueWhite(of: minimal)
    let lowest = try #require(white.max { $0.y < $1.y })
    let under = pixel(bytes, width: size1080.x, x: lowest.x, y: lowest.y + Int((0.08 * em).rounded()))
    #expect(Int(under.y) < Int(pixel(plain, width: size1080.x, x: lowest.x, y: lowest.y).y) - 10, "\(under)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func captionsDrawOverTheCamera() async throws {
    let size = size1080
    let caption = try layer(["Encima de la cámara", "y de todo lo demás"], style: style(.bold))
    let whole = Rect(x: 0, y: 0, width: Double(size.x), height: Double(size.y))
    let camera = CameraLayer(trackID: cameraID, sourceTime: base, rect: whole, cornerRadius: 0)
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: whole, cornerRadius: 0)
    let center = SIMD2(Double(size.x) / 2, Double(size.y) / 2)
    // The camera over every pixel; a camera over the screen; and the same through the zoom's motion blur, where the
    // captions go over its average (the blur pass's target).
    let frames = [
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, camera: camera,
                    coveredByCamera: true, captions: caption),
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, camera: camera,
                    captions: caption),
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, camera: camera,
                    stage: StageTransform(depth: 1.5, center: center),
                    subframes: [StageSubframe(stage: StageTransform(depth: 1.2, center: center)), StageSubframe(stage: StageTransform(depth: 1.5, center: center))],
                    captions: caption),
    ]
    let white = try opaqueWhite(of: caption)
    #expect(white.count > 1000)
    let drawn = try await offThePool {
        let drawer = try CaptionDrawer()
        return try frames.map { frame -> ([UInt8], [UInt8], DrawCounts) in
            var counts = DrawCounts()
            let with = try drawer.draw(frame, counts: &counts)
            var without = frame
            without.captions = nil
            return (with, try drawer.draw(without), counts)
        }
    }
    for (index, (with, without, counts)) in drawn.enumerated() {
        #expect(counts.captions == 1 && counts.overlaySteps == 1, "frame \(index): \(counts)")
        #expect(white.allSatisfy { pixel(with, width: size.x, x: $0.x, y: $0.y) == [255, 255, 255, 255] }, "frame \(index)")
        // The camera is there under them, and drawn as without the captions outside their region.
        #expect(white.contains { pixel(without, width: size.x, x: $0.x, y: $0.y) != [255, 255, 255, 255] }, "frame \(index)")
        let region = try #require(CaptionTextures.region(of: caption))
        let above = region.origin.y - 1
        #expect((0..<size.x).allSatisfy { pixel(with, width: size.x, x: $0, y: above) == pixel(without, width: size.x, x: $0, y: above) })
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func captionTexturesAreReused() async throws {
    let first = try layer(["Uno dos tres"], style: style(.bold), highlight: CaptionHighlight(line: 0, range: 0..<3))
    var next = first
    next.highlight = CaptionHighlight(line: 0, range: 4..<7)
    let second = next
    let counts = try await offThePool {
        let drawer = try CaptionDrawer()
        for _ in 0..<30 { _ = try drawer.draw(flatFrame(first, color: [0, 0, 0, 1])) }
        let once = drawer.textures.drawCount
        _ = try drawer.draw(flatFrame(second, color: [0, 0, 0, 1]))
        // Back to the first: still kept.
        _ = try drawer.draw(flatFrame(first, color: [0, 0, 0, 1]))
        return (once, drawer.textures.drawCount)
    }
    #expect(counts.0 == 1)
    #expect(counts.1 == 2)
    // Only the last four are kept.
    let textures = CaptionTextures()
    let device = try #require(MTLCreateSystemDefaultDevice())
    var layers: [CaptionLayer] = []
    for word in 0..<5 {
        var next = first
        next.lines = ["Palabra \(word)"]
        layers.append(next)
        _ = try textures.texture(for: next, device: device)
    }
    _ = try textures.texture(for: layers[1], device: device)
    #expect(textures.drawCount == 5)
    _ = try textures.texture(for: layers[0], device: device)
    #expect(textures.drawCount == 6)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func legacyCountsNoCaption() async throws {
    // A document of phase 1 has no captions at any time, and drawing its frames on every path draws none: the calls of
    // phase 1. (The cases of golden 2 are drawn on every path in `RenderSeamsTests.overlayStepRunsOnEveryPath`.)
    let take = StageDrawing.bareTake(seconds: 3)
    var zoomed = EditDocument.legacy(take: take, events: [])
    zoomed.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 1.8)]
    zoomed.zoom.motionBlur = 1
    var transcribed = zoomed
    transcribed.transcript = Transcript(
        language: "es-MX", engine: "speechTranscriber-1",
        takes: [TranscriptTake(take: takeID, track: "microphone-1", words: [TranscriptWord(start: base, end: base.adding(seconds: 1), text: "hola")])])
    var frames: [RenderFrame] = []
    for document in [EditDocument.legacy(take: take, events: []), zoomed, transcribed] {
        #expect(document.captions == .legacy || document.captions.show == false)
        let scene = FrameEvaluator(take: take, events: [], document: document, outputSize: size1080)
        for t in [0.1, 0.6, 1.0, 2.0] {
            let frame = scene.frame(at: t)
            #expect(frame.captions == nil)
            frames.append(frame)
        }
    }
    #expect(frames.contains { !$0.subframes.isEmpty })
    let drawnFrames = frames
    let counts = try await offThePool {
        let drawer = try CaptionDrawer()
        return try drawnFrames.map { frame -> DrawCounts in
            var counts = DrawCounts()
            _ = try drawer.draw(frame, counts: &counts)
            return counts
        }
    }
    #expect(counts.allSatisfy { $0.captions == 0 && $0.overlaySteps == 1 })
}

// MARK: - Preview and export

/// A take of one 3 s display segment from `base`, with the cursor moving over it the whole time, and its legacy document
/// with a transcript spoken over it, its captions shown in `style`, and a zoom in from 1.5 s with the motion blur on.
private func captionedProject(in dir: URL, style: CaptionStyle) async throws -> (LoadedProject, EditDocument) {
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: frame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
    try builder.addEvents(cursorEvents(from: base, seconds: 3, across: frame))
    let project = try builder.write()
    var document = EditDocument.legacy(for: project)
    let words = ["Buenas", "tardes,", "¿cómo", "están?", "Hoy", "vamos", "a", "grabar", "la", "pantalla", "en", "español."]
    document.transcript = Transcript(
        language: "es-MX", engine: "speechTranscriber-1",
        takes: [TranscriptTake(
            take: project.take.id, track: "microphone-1",
            words: words.enumerated().map { index, text in
                TranscriptWord(start: base.adding(seconds: 0.2 + 0.24 * Double(index)), end: base.adding(seconds: 0.4 + 0.24 * Double(index)), text: text)
            })])
    document.captions = CaptionPlan(show: true, style: style)
    document.zoom.regions = [StageDrawing.zoom(1, from: 1.5, to: 3, depth: 1.6)]
    document.zoom.motionBlur = 1
    return (project, document)
}

private func exported(_ renderer: FrameRenderer, at t: Double, size: SIMD2<Int>) async throws -> [UInt8] {
    try await offThePool {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size.x, size.y, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else { throw TestSupportError.failed("no pixel buffer: \(status)") }
        try renderer.render(at: t, into: pixelBuffer)
        return packedBytes(of: pixelBuffer)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewEqualsExportWithCaptions() async throws {
    try await withTemporaryDirectory { dir in
        for preset in CaptionPreset.allCases {
            let folder = dir.appendingPathComponent(preset.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (project, document) = try await captionedProject(in: folder, style: style(preset))
            let size = SIMD2(1280, 720)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            let uncaptioned = try FrameRenderer(project: project, document: { var plain = document; plain.captions.show = false; return plain }(), outputSize: size)
            let preview = PreviewRenderer(renderer: renderer)
            let scene = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            for t in [0.5, 1.7, 2.9] {
                let frame = scene.frame(at: t)
                #expect(frame.captions != nil, "\(preset) at \(t) s")
                if t == 1.7 { #expect(!frame.subframes.isEmpty, "the zoom's blur at \(t) s") }
                let export = try await exported(renderer, at: t, size: size)
                let previewed = try await offThePool { try preview.snapshot(at: t) }
                #expect(export == previewed, "\(preset) at \(t) s")
                // And they are drawn: the frame without them differs.
                let plain = try await exported(uncaptioned, at: t, size: size)
                #expect(plain != export, "\(preset) at \(t) s")
            }
        }
    }
}

// MARK: - Measures and shots

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func captionFrameCostBench() async throws {
    // 600 frames of 1080p (10 s at 60 fps) with a caption that changes every 0.4 s, its word highlighted (Bold), drawn into
    // one target as the preview does: the CPU time of each frame's encoding (with a new caption's texture drawn in it)
    // and the GPU time, with and without the captions, after 8 frames to warm up.
    let words = (0..<40).map { ["Hoy", "vamos", "a", "grabar", "la", "pantalla", "con", "subtítulos", "en", "español."][$0 % 10] }
    let take = StageDrawing.bareTake(seconds: 12)
    var document = EditDocument.legacy(take: take, events: [])
    document.transcript = Transcript(
        language: "es-MX", engine: "speechTranscriber-1",
        takes: [TranscriptTake(
            take: takeID, track: "microphone-1",
            words: words.enumerated().map { index, text in
                TranscriptWord(start: base.adding(seconds: 0.4 * Double(index)), end: base.adding(seconds: 0.4 * Double(index) + 0.3), text: text)
            })])
    document.captions = CaptionPlan(show: true, style: .default)
    let scene = FrameEvaluator(take: take, events: [], document: document, outputSize: size1080)
    let frames = (0..<608).map { scene.frame(at: Double($0) / 60) }
    struct Times: Sendable { var cpu: [Double] = [], gpu: [Double] = [] }
    let (with, without, textures) = try await offThePool { () -> (Times, Times, Int) in
        let drawer = try CaptionDrawer()
        let target = try StageDrawing.target(device: drawer.device, size: size1080)
        func measure(_ frames: [RenderFrame]) throws -> Times {
            var times = Times()
            for (index, frame) in frames.enumerated() {
                let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
                let start = DispatchTime.now().uptimeNanoseconds
                try drawer.compositor.encode(
                    frame, screen: drawer.screen, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer)
                let encoded = DispatchTime.now().uptimeNanoseconds
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                guard index >= 8 else { continue }
                times.cpu.append(Double(encoded - start) / 1e6)
                times.gpu.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1e3)
            }
            return times
        }
        let without = try measure(frames.map { var plain = $0; plain.captions = nil; return plain })
        let before = drawer.textures.drawCount
        let with = try measure(frames)
        return (with, without, drawer.textures.drawCount - before)
    }
    func p(_ values: [Double], _ q: Double) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * q))] }
    print(String(
        format: "captions 1080p, %d frames: CPU encode p50 %.3f ms, p95 %.3f, max %.3f (without: p50 %.3f, max %.3f); "
            + "GPU p50 %.3f ms, p95 %.3f, max %.3f (without: p50 %.3f, p95 %.3f); %d textures in 10 s (%d a minute)",
        with.cpu.count, p(with.cpu, 0.5), p(with.cpu, 0.95), with.cpu.max() ?? 0, p(without.cpu, 0.5), without.cpu.max() ?? 0,
        p(with.gpu, 0.5), p(with.gpu, 0.95), with.gpu.max() ?? 0, p(without.gpu, 0.5), p(without.gpu, 0.95), textures, textures * 6))
    #expect(textures >= 20)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func captionSceneOfAnHourBench() {
    // The captions of an hour of speech (9 000 words, one every 0.4 s, a pause every 20), laid out for a scene at 1080p as
    // each new scene does (`FrameEvaluator.init`, `resized(to:)`): median of 5 after one to warm up.
    let seconds = 3600.0
    let take = StageDrawing.bareTake(seconds: seconds + 2)
    var document = EditDocument.legacy(take: take, events: [])
    let texts = ["Hoy", "vamos", "a", "grabar", "la", "pantalla", "con", "subtítulos", "en", "español,"]
    document.transcript = Transcript(
        language: "es-MX", engine: "speechTranscriber-1",
        takes: [TranscriptTake(
            take: takeID, track: "microphone-1",
            words: (0..<9000).map { index in
                let start = 0.4 * Double(index)
                return TranscriptWord(
                    start: base.adding(seconds: start), end: base.adding(seconds: start + 0.3), text: texts[index % 10],
                    breakBefore: index % 20 == 0)
            })])
    document.captions = CaptionPlan(show: true, style: .default)
    let timeMap = TimeMap(sequence: document.sequence)
    var times: [Double] = []
    var count = 0
    for run in 0..<6 {
        let start = DispatchTime.now().uptimeNanoseconds
        let scene = CaptionScene(document: document, timeMap: timeMap, outputSize: size1080)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        if run > 0 { times.append(elapsed) }
        count = (0..<3600).filter { scene.layer(atOutput: TimeMap.outputNanoseconds(seconds: Double($0) + 0.1)) != nil }.count
    }
    print(String(format: "caption scene of an hour at 1080p: median %.1f ms (runs %@); %d of 3600 seconds captioned", times.sorted()[2],
                 times.map { String(format: "%.1f", $0) }.joined(separator: ", "), count))
    #expect(count > 3000)
    // The CPU time of drawing one caption's texture of two lines, by preset, at 1080p and at 4K: median of 5 after one.
    for size in [size1080, SIMD2(3840, 2160)] {
        var row: [String] = []
        for preset in CaptionPreset.allCases {
            var drawn = style(preset)
            drawn.highlight = true
            let lines = ["Hoy vamos a grabar la pantalla con", "subtítulos en español, ¿cómo están?"]
            guard let placed = CaptionScene.placement(of: lines, style: drawn, language: "es-MX", outputSize: size) else { continue }
            let layer = CaptionLayer(
                lines: lines, highlight: CaptionHighlight(line: 0, range: 4..<9), style: drawn, language: "es-MX",
                fontSize: placed.fontSize, box: placed.box)
            var times: [Double] = []
            for run in 0..<6 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try? CaptionTextures.bitmap(of: layer)
                if run > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            row.append(String(format: "%@ %.2f ms", preset.rawValue, times.sorted()[2]))
        }
        print("caption texture at \(size.x)×\(size.y): " + row.joined(separator: ", "))
    }
}

/// Writes the frames of the presets in each size, 16:9 and 9:16, with Spanish text, to `TOMA_CAPTION_SHOTS` as PNG.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_CAPTION_SHOTS"] != nil))
func captionShots() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOMA_CAPTION_SHOTS"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let words = ["¿Señor", "Ñúñez,", "qué", "ángulo", "elegís", "para", "grabar", "la", "pantalla", "del", "año?"]
    var shots: [(name: String, frame: RenderFrame)] = []
    for (orientation, size) in [("16x9", size1080), ("9x16", SIMD2(1080, 1920)), ("4k", SIMD2(3840, 2160))] {
        for preset in CaptionPreset.allCases {
            for overlay in OverlaySize.allCases where orientation != "4k" || overlay == .medium {
                for uppercase in [false, true] where !uppercase || overlay == .medium {
                    var drawn = style(preset, size: overlay, position: uppercase ? .top : .bottom, uppercase: uppercase)
                    drawn.highlight = true
                    var document = EditDocument.legacy(take: StageDrawing.bareTake(seconds: 8), events: [])
                    document.transcript = Transcript(
                        language: "es-MX", engine: "speechTranscriber-1",
                        takes: [TranscriptTake(
                            take: takeID, track: "microphone-1",
                            words: words.enumerated().map { index, text in
                                TranscriptWord(start: base.adding(seconds: 0.3 * Double(index)), end: base.adding(seconds: 0.3 * Double(index) + 0.25), text: text)
                            })])
                    document.captions = CaptionPlan(show: true, style: drawn)
                    let scene = CaptionScene(document: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
                    let caption = try #require(scene.layer(atOutput: TimeMap.outputNanoseconds(seconds: 0.95)))
                    let whole = Rect(x: 0, y: 0, width: Double(size.x), height: Double(size.y))
                    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: whole, cornerRadius: 0)
                    let frame = RenderFrame(
                        outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, captions: caption)
                    shots.append(("\(orientation)-\(preset.rawValue)-\(overlay.rawValue)\(uppercase ? "-caps-top" : "")", frame))
                }
            }
        }
    }
    let drawnShots = shots
    let images = try await offThePool {
        let drawer = try CaptionDrawer()
        // Half white, half a dark photo-like gradient, with grey bars like text: the captions over both.
        let screen = try drawer.texture(width: 960, height: 540) { x, y in
            if x < 480 {
                let bar = y % 36 < 8 && x > 40 && x < 440 && (y / 36) % 3 != 2
                return bar ? [90, 90, 90, 255] : [255, 255, 255, 255]
            }
            let t = Double(y) / 540, u = Double(x - 480) / 480
            return [UInt8(120 + 80 * u), UInt8(60 + 90 * t), UInt8(30 + 160 * (1 - t) * u), 255]
        }
        return try drawnShots.map { ($0.name, $0.frame.outputSize, try drawer.draw($0.frame, screen: screen)) }
    }
    for (name, size, bytes) in images {
        let url = folder.appendingPathComponent("\(name).png")
        try writePNG(bytes, size: size, to: url)
    }
}

/// BGRA bytes of `size` written to `url` as a PNG.
private func writePNG(_ bytes: [UInt8], size: SIMD2<Int>, to url: URL) throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}
