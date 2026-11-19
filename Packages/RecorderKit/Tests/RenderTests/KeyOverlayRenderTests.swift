// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `KeyOverlayScene`, `KeyOverlayMetrics`, `KeyOverlayTexture`, `DrawCounts`, the compositor's counting
// `encode` and its layers.
@testable import Render
import Testing

/// The keys on screen drawn (phase 2 design §7.4 and §11, plan 2c Task P11, `keyOverlay-1`): the layer of each frame
/// from the timeline and the placement, the box and its key caps or its pill, over the camera and under the captions on
/// every path, each texture drawn once, the preview drawing what the export does, and nothing of them with the keys off.

private let size1080 = SIMD2(1920, 1080)

/// ⌘ ⇧ ⌥ ⌃ as `InputEvent.Kind.keyPress`' `mods`.
private let command = KeyLabels.commandBit, shift = KeyLabels.shiftBit, option = KeyLabels.optionBit, control = KeyLabels.controlBit

/// A key pressed `seconds` into the take: its virtual key code, what it types and its modifiers.
private func press(_ seconds: Double, code: UInt16, chars: String?, mods: UInt32 = 0, isRepeat: Bool = false) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: .keyPress(code: code, chars: chars, mods: mods, isRepeat: isRepeat, key: chars))
}

/// ⌘C at `seconds`.
private func copy(_ seconds: Double) -> InputEvent { press(seconds, code: 8, chars: "c", mods: command) }

/// The legacy document of a bare take of `seconds`, with the keys shown as `keys` and the captions as `captions`.
private func document(
    seconds: Double = 6, keys: KeyOverlayPlan = KeyOverlayPlan(mode: .shortcuts, position: .bottomCenter, size: .medium),
    captions: CaptionPlan = .legacy
) -> (TakeRecord, EditDocument) {
    let take = StageDrawing.bareTake(seconds: seconds)
    var document = EditDocument.legacy(take: take, events: [])
    document.keys = keys
    document.captions = captions
    return (take, document)
}

/// An item of `content` at the height of a key of `size` in an output of `outputSize`, placed as the scene places it.
private func item(
    _ content: KeyOverlayContent, size: OverlaySize = .medium, outputSize: SIMD2<Int> = size1080, opacity: Double = 1,
    position: KeyOverlayPosition = .bottomCenter, captions: CaptionPlan = .legacy
) -> KeyOverlayLayer.Item {
    let capHeight = KeyOverlayPlacement.capHeight(size, outputSize: outputSize)
    let box = KeyOverlayMetrics.size(of: content, capHeight: capHeight)
    let rect = KeyOverlayPlacement.rect(
        boxSize: box, keys: KeyOverlayPlan(mode: .all, position: position, size: size), captions: captions, outputSize: outputSize)
    return KeyOverlayLayer.Item(content: content, rect: rect, capHeight: capHeight, opacity: opacity)
}

/// A frame of `size` over a flat background of `color` (straight RGBA from 0 to 1), with `keys` and nothing else.
private func flatFrame(_ keys: KeyOverlayLayer?, color: SIMD4<Float>, size: SIMD2<Int> = size1080) -> RenderFrame {
    RenderFrame(outputSize: size, gradientStart: color, gradientEnd: color, gradientAngleDegrees: 0, keys: keys)
}

/// `color` (0 to 1) as the BGRA bytes the target holds.
private func bgra(_ color: SIMD4<Float>) -> SIMD4<UInt8> {
    SIMD4(UInt8((color.z * 255).rounded()), UInt8((color.y * 255).rounded()), UInt8((color.x * 255).rounded()), UInt8((color.w * 255).rounded()))
}

private func close(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>, _ tolerance: Int) -> Bool {
    (0..<4).allSatisfy { abs(Int(a[$0]) - Int(b[$0])) <= tolerance }
}

/// A compositor of the default device to draw frames with keys.
private struct KeyDrawer: @unchecked Sendable {
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

    var textures: KeyOverlayTexture { compositor.layers.keys.textures }

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

// MARK: - The layer

@Test func noKeysOrModeOffIsNoLayer() async throws {
    let events = [copy(1), press(1.5, code: 0, chars: "a"), press(1.6, code: 11, chars: "b")]
    // The legacy document (the keys off) with keys pressed; the keys shown with none pressed; and off again.
    let (take, legacy) = document()
    var off = legacy
    off.keys = .legacy
    for (document, events) in [(off, events), (legacy, [InputEvent]()), (off, [])] {
        let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size1080)
        for t in [0.5, 1.05, 1.55, 2.0, 3.0] {
            #expect(scene.frame(at: t).keys == nil, "\(document.keys) at \(t) s")
        }
    }
    // Only typing, with the shortcuts alone shown: nothing either.
    let typed = [press(1, code: 0, chars: "a"), press(1.1, code: 11, chars: "b")]
    let scene = FrameEvaluator(take: take, events: typed, document: legacy, outputSize: size1080)
    #expect([1.05, 1.5].allSatisfy { scene.frame(at: $0).keys == nil })
}

@Test func layerFollowsTheTimeline() async throws {
    let events = [copy(1)]
    let height = Double(size1080.y), short = Double(min(size1080.x, size1080.y))
    for position in KeyOverlayPosition.allCases {
        let (take, document) = document(keys: KeyOverlayPlan(mode: .shortcuts, position: position, size: .medium))
        let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size1080)
        #expect(scene.frame(at: 0.9).keys == nil)
        // Halfway into its fade in, then held, then gone.
        let fading = try #require(scene.frame(at: 1.05).keys)
        try #require(fading.items.count == 1)
        let shown = fading.items[0]
        #expect(shown.content == .keys(["⌘", "C"]))
        #expect(abs(shown.opacity - 0.5) < 1e-9)
        #expect(shown.capHeight == 0.06 * short)
        #expect(shown.rect.width == shown.rect.width.rounded() && shown.rect.height == shown.rect.height.rounded())
        #expect(SIMD2(shown.rect.width, shown.rect.height) == KeyOverlayMetrics.size(of: shown.content, capHeight: shown.capHeight))
        #expect(scene.frame(at: 1.5).keys?.items.map(\.opacity) == [1])
        #expect(scene.frame(at: 2.25).keys == nil)
        let rect = shown.rect
        switch position {
        case .bottomCenter:
            #expect(abs(rect.y + rect.height - 0.9 * height) < 1e-9)
            #expect(abs(rect.x + rect.width / 2 - Double(size1080.x) / 2) < 1e-9)
        case .bottomLeading:
            #expect(abs(rect.y + rect.height - 0.9 * height) < 1e-9)
            #expect(abs(rect.x - 0.1 * short) < 1e-9)
        case .bottomTrailing:
            #expect(abs(rect.y + rect.height - 0.9 * height) < 1e-9)
            #expect(abs(rect.x + rect.width - (Double(size1080.x) - 0.1 * short)) < 1e-9)
        case .top:
            #expect(abs(rect.y - 0.1 * height) < 1e-9)
            #expect(abs(rect.x + rect.width / 2 - Double(size1080.x) / 2) < 1e-9)
        }
    }
}

@Test func aboveBottomCaptions() async throws {
    let events = [copy(1)]
    let size = SIMD2(1080, 1920)
    let short = Double(size.x)
    for captionSize in OverlaySize.allCases {
        var style = CaptionStyle.default
        style.size = captionSize
        let captions = CaptionPlan(show: true, style: style)
        let (take, document) = document(keys: KeyOverlayPlan(mode: .shortcuts, position: .bottomCenter, size: .large), captions: captions)
        let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
        let rect = try #require(scene.frame(at: 1.5).keys?.items.first?.rect)
        let reserved = CaptionMetrics.reservedHeight(style, outputSize: size) + KeyOverlayPlacement.captionGap * short
        #expect(rect.y + rect.height <= Double(size.y) - reserved + 1e-9, "\(captionSize)")
        #expect(rect.y + rect.height <= 0.9 * Double(size.y) + 1e-9, "\(captionSize)")
        // At the top with the captions at the top: under them.
        var top = document
        top.keys.position = .top
        top.captions.style.position = .top
        let below = try #require(FrameEvaluator(take: take, events: events, document: top, outputSize: size).frame(at: 1.5).keys?.items.first?.rect)
        #expect(below.y >= reserved - 1e-9, "\(captionSize)")
    }
}

@Test func theLayerWaitsForTheTakesKeys() {
    // Keys of another take are not this take's, even at the same source instants.
    let (take, document) = document()
    let timeMap = TimeMap(sequence: document.sequence)
    let scene = KeyOverlayScene(document: document, take: "take-other", events: [copy(1)], timeMap: timeMap, outputSize: size1080)
    #expect(scene.layer(atOutput: TimeMap.outputNanoseconds(seconds: 1.5)) == nil)
    let own = KeyOverlayScene(document: document, take: take.id, events: [copy(1)], timeMap: timeMap, outputSize: size1080)
    #expect(own.layer(atOutput: TimeMap.outputNanoseconds(seconds: 1.5))?.items.count == 1)
}

// MARK: - The measures

@Test func boxesAreWholePixelsOfTheDesignsMeasures() throws {
    let h = KeyOverlayPlacement.capHeight(.medium, outputSize: size1080)
    let one = KeyOverlayMetrics.size(of: .keys(["C"]), capHeight: h)
    let two = KeyOverlayMetrics.size(of: .keys(["⌘", "C"]), capHeight: h)
    let four = KeyOverlayMetrics.size(of: .keys(["⌘", "⇧", "⌥", "4"]), capHeight: h)
    for size in [one, two, four] {
        #expect(size.x == size.x.rounded() && size.y == size.y.rounded())
        // 1.36 h high: the key and 0.18 h above and below.
        #expect(abs(size.y - 1.36 * h) <= 1.5, "\(size)")
    }
    // Square keys of one character, 0.15 h apart.
    #expect(abs(two.x - one.x - (h + 0.15 * h)) <= 1.5)
    #expect(abs((four.x - two.x) - 2 * (h + 0.15 * h)) <= 2)
    // A longer label is never narrower than a square key; the pill grows with what is typed.
    #expect(KeyOverlayMetrics.size(of: .keys(["esc"]), capHeight: h).x >= one.x)
    let short = KeyOverlayMetrics.size(of: .text("hola"), capHeight: h)
    let long = KeyOverlayMetrics.size(of: .text("hola mundo"), capHeight: h)
    #expect(short.y == one.y && long.y == one.y)
    #expect(long.x > short.x)
    let layout = try #require(KeyOverlayMetrics.layout(of: .keys(["⌘", "C"]), capHeight: h))
    #expect(abs(layout.radius - 0.22 * Double(layout.size.y)) < 1e-9)
    // The caps are the same size, inside the padding, their corners concentric with the box's.
    #expect(Set(layout.caps.map(\.size)).count == 1)
    for cap in layout.caps {
        #expect(cap.origin.y == layout.caps[0].origin.y)
        #expect(abs(cap.radius - (layout.radius - Double(cap.origin.y))) < 1e-9)
    }
}

@Test func labelsShareABaselineAndAreCentredInTheirKeys() throws {
    let h = KeyOverlayPlacement.capHeight(.large, outputSize: SIMD2(3840, 2160))
    let layout = try #require(KeyOverlayMetrics.layout(of: .keys(["⌘", "⇧", "⌥", "⌃", "4"]), capHeight: h))
    let caps = layout.caps
    try #require(caps.count == 5)
    // ⌘ ⇧ ⌥ and the key's own label on one baseline, of whole pixels.
    let baselines = caps.map(\.label.origin.y)
    #expect(baselines.allSatisfy { $0 == $0.rounded() })
    #expect(Set([baselines[0], baselines[1], baselines[2], baselines[4]]).count == 1, "\(baselines)")
    // Each label's ink centred across its key (within a pixel), and ⌃, which sits high on the baseline, centred down it.
    for cap in caps {
        let ink = try #require(KeyOverlayMetrics.inkBounds(of: cap.label))
        let middle = Double(cap.origin.x) + Double(cap.size.x) / 2
        #expect(abs(ink.midX - middle) <= 1, "\(cap.label.text): \(ink.midX) vs \(middle)")
        if cap.label.text != "⌃" { continue }
        #expect(abs(ink.midY - (Double(cap.origin.y) + Double(cap.size.y) / 2)) <= 1, "⌃: \(ink.midY)")
    }
}

// MARK: - Drawn

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func drawsTheBoxAndText() async throws {
    let background: SIMD4<Float> = [0.9, 0.5, 0.2, 1]
    let shortcut = item(.keys(["⌘", "⇧", "4"]))
    let pill = item(.text("Hola, ¿qué tal?"), position: .top)
    let layout = try #require(KeyOverlayMetrics.layout(of: shortcut.content, capHeight: shortcut.capHeight))
    let pillLayout = try #require(KeyOverlayMetrics.layout(of: pill.content, capHeight: pill.capHeight))
    let (with, plain, counts) = try await offThePool { () -> ([UInt8], [UInt8], DrawCounts) in
        let drawer = try KeyDrawer()
        var counts = DrawCounts()
        let with = try drawer.draw(flatFrame(KeyOverlayLayer(items: [shortcut, pill]), color: background), counts: &counts)
        return (with, try drawer.draw(flatFrame(nil, color: background)), counts)
    }
    #expect(counts.keyOverlays == 2 && counts.overlaySteps == 1)
    let width = size1080.x
    let origin = SIMD2(Int(shortcut.rect.x.rounded()), Int(shortcut.rect.y.rounded()))
    // A pixel of the box between its edge and the keys: #1C1C1E at 85 % over the background.
    let boxColor = SIMD4<Float>(0x1C, 0x1C, 0x1E, 0) / 255 * 0.85 + background * 0.15
    let inBox = origin &+ SIMD2(layout.caps[0].origin.x / 2, layout.size.y / 2)
    #expect(close(pixel(with, width: width, x: inBox.x, y: inBox.y), bgra(SIMD4(boxColor.x, boxColor.y, boxColor.z, 1)), 1),
            "\(pixel(with, width: width, x: inBox.x, y: inBox.y))")
    // A key's colour, #3A3A3C, between its edge and its label, halfway down.
    for cap in layout.caps {
        let side = origin &+ cap.origin &+ SIMD2(max(cap.size.x / 8, 2), cap.size.y / 2)
        #expect(close(pixel(with, width: width, x: side.x, y: side.y), [0x3C, 0x3A, 0x3A, 255], 2),
                "\(cap.label.text): \(pixel(with, width: width, x: side.x, y: side.y))")
        // Its label is white.
        let ink = try #require(KeyOverlayMetrics.inkBounds(of: cap.label))
        let labelRegion = (Int(ink.minX)..<Int(ink.maxX.rounded(.up)), Int(ink.minY)..<Int(ink.maxY.rounded(.up)))
        let white = labelRegion.1.contains { y in
            labelRegion.0.contains { x in pixel(with, width: width, x: origin.x + x, y: origin.y + y) == [255, 255, 255, 255] }
        }
        #expect(white, "\(cap.label.text)")
    }
    // The pill: its box and white text, at the top.
    let pillOrigin = SIMD2(Int(pill.rect.x.rounded()), Int(pill.rect.y.rounded()))
    let pillBox = pillOrigin &+ SIMD2(4, pillLayout.size.y / 2)
    #expect(close(pixel(with, width: width, x: pillBox.x, y: pillBox.y), bgra(SIMD4(boxColor.x, boxColor.y, boxColor.z, 1)), 1))
    let textRows = pillOrigin.y..<(pillOrigin.y + pillLayout.size.y)
    let textColumns = pillOrigin.x..<(pillOrigin.x + pillLayout.size.x)
    #expect(textRows.contains { y in textColumns.contains { pixel(with, width: width, x: $0, y: y) == [255, 255, 255, 255] } })
    // Outside the boxes the frame is as without them.
    let regions = [shortcut, pill].compactMap(KeyOverlayTexture.region(of:))
    var outside = 0
    for y in stride(from: 0, to: size1080.y, by: 7) {
        for x in stride(from: 0, to: size1080.x, by: 7)
        where !regions.contains(where: { x >= $0.origin.x && x < $0.origin.x + $0.size.x && y >= $0.origin.y && y < $0.origin.y + $0.size.y }) {
            outside += 1
            #expect(pixel(with, width: width, x: x, y: y) == pixel(plain, width: width, x: x, y: y))
        }
    }
    #expect(outside > 10_000)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func crossfadeDrawsBoth() async throws {
    // In "All", "hola" typed, then ⌘S: 50 ms into the shortcut, the pill is going and the shortcut coming, half each.
    let events = [
        press(1, code: 4, chars: "h"), press(1.1, code: 31, chars: "o"), press(1.2, code: 37, chars: "l"), press(1.3, code: 0, chars: "a"),
        press(2, code: 1, chars: "s", mods: command),
    ]
    let (take, document) = document(keys: KeyOverlayPlan(mode: .all, position: .bottomCenter, size: .medium))
    let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size1080)
    let frame = scene.frame(at: 2.05)
    let layer = try #require(frame.keys)
    #expect(layer.items.map(\.content) == [.text("hola"), .keys(["⌘", "S"])])
    #expect(layer.items.allSatisfy { abs($0.opacity - 0.5) < 1e-6 })
    let both = flatFrame(layer, color: [0, 0, 0, 1])
    let first = flatFrame(KeyOverlayLayer(items: [layer.items[0]]), color: [0, 0, 0, 1])
    let second = flatFrame(KeyOverlayLayer(items: [layer.items[1]]), color: [0, 0, 0, 1])
    let (drawn, counts) = try await offThePool { () -> ([[UInt8]], DrawCounts) in
        let drawer = try KeyDrawer()
        var counts = DrawCounts()
        let together = try drawer.draw(both, counts: &counts)
        return ([together, try drawer.draw(first), try drawer.draw(second)], counts)
    }
    #expect(counts.keyOverlays == 2)
    #expect(drawn[0] != drawn[1] && drawn[0] != drawn[2])
    // Where both cover the frame, the second is drawn over the first: brighter than either alone at its half opacity.
    let a = try #require(KeyOverlayTexture.region(of: layer.items[0])), b = try #require(KeyOverlayTexture.region(of: layer.items[1]))
    let y = max(a.origin.y, b.origin.y) + min(a.size.y, b.size.y) / 2
    let x = max(a.origin.x, b.origin.x) + 3
    let together = pixel(drawn[0], width: size1080.x, x: x, y: y), alone = pixel(drawn[2], width: size1080.x, x: x, y: y)
    #expect(together.x >= alone.x, "\(together) \(alone)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func textureIsDrawnOncePerContent() async throws {
    let pill = item(.text("Escribiendo"))
    let (once, again, frames) = try await offThePool { () -> (Int, Int, [[UInt8]]) in
        let drawer = try KeyDrawer()
        var frames: [[UInt8]] = []
        for n in 0..<30 {
            var faded = pill
            faded.opacity = Double(n + 1) / 30
            let bytes = try drawer.draw(flatFrame(KeyOverlayLayer(items: [faded]), color: [1, 1, 1, 1]))
            if n == 29 { frames.append(bytes) }
        }
        let once = drawer.textures.drawnCount
        // Another pill, then back to the first: still kept.
        _ = try drawer.draw(flatFrame(KeyOverlayLayer(items: [item(.text("Escribiendo."))]), color: [1, 1, 1, 1]))
        frames.append(try drawer.draw(flatFrame(KeyOverlayLayer(items: [pill]), color: [1, 1, 1, 1])))
        return (once, drawer.textures.drawnCount, frames)
    }
    #expect(once == 1)
    #expect(again == 2)
    #expect(frames[0] == frames[1])
    // Only the last four are kept, by content and size.
    let device = try #require(MTLCreateSystemDefaultDevice())
    let textures = KeyOverlayTexture(device: device)
    let items = (0..<5).map { item(.text("Tecla \($0)")) }
    for item in items { _ = try textures.texture(for: item) }
    _ = try textures.texture(for: items[1])
    #expect(textures.drawnCount == 5)
    _ = try textures.texture(for: items[0])
    #expect(textures.drawnCount == 6)
    // The same content at another size is another texture.
    _ = try textures.texture(for: item(.text("Tecla 4"), size: .large))
    #expect(textures.drawnCount == 7)
}

@Test func bitmapsAreDeterministicAndOfTheOutputsResolution() throws {
    // The same content draws the same bytes; at 4K it is drawn at 4K, twice as many pixels across as at 1080p.
    let content = KeyOverlayContent.keys(["⌘", "⇧", "4"])
    let h1080 = KeyOverlayPlacement.capHeight(.medium, outputSize: size1080)
    let h4k = KeyOverlayPlacement.capHeight(.medium, outputSize: SIMD2(3840, 2160))
    let a = try #require(try KeyOverlayTexture.bitmap(of: content, capHeight: h4k))
    let b = try #require(try KeyOverlayTexture.bitmap(of: content, capHeight: h4k))
    #expect(a.bytes == b.bytes)
    let small = try #require(try KeyOverlayTexture.bitmap(of: content, capHeight: h1080))
    // Each whole-pixel part (the keys, the padding, the spacing) is rounded at each size.
    #expect(abs(a.size.x - 2 * small.size.x) <= 6 && abs(a.size.y - 2 * small.size.y) <= 2, "\(a.size) \(small.size)")
    #expect(a.bytes.count == a.size.x * a.size.y * 4)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func keysDrawOverTheCameraAndUnderTheCaptions() async throws {
    let size = size1080
    let keys = KeyOverlayLayer(items: [item(.keys(["⌘", "K"]))])
    let whole = Rect(x: 0, y: 0, width: Double(size.x), height: Double(size.y))
    let camera = CameraLayer(trackID: cameraID, sourceTime: base, rect: whole, cornerRadius: 0)
    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: whole, cornerRadius: 0)
    let center = SIMD2(Double(size.x) / 2, Double(size.y) / 2)
    let region = try #require(KeyOverlayTexture.region(of: keys.items[0]))
    let layout = try #require(KeyOverlayMetrics.layout(of: keys.items[0].content, capHeight: keys.items[0].capHeight))
    let capPixel = region.origin &+ layout.caps[0].origin &+ SIMD2(layout.caps[0].size.x / 8, layout.caps[0].size.y / 2)
    // The camera over every pixel; over the screen; and the same through the zoom's motion blur (the blur pass's target).
    let frames = [
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, camera: camera,
                    coveredByCamera: true, keys: keys),
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, camera: camera,
                    keys: keys),
        RenderFrame(outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, camera: camera,
                    stage: StageTransform(depth: 1.5, center: center),
                    subframes: [StageSubframe(stage: StageTransform(depth: 1.2, center: center)), StageSubframe(stage: StageTransform(depth: 1.5, center: center))],
                    keys: keys),
    ]
    let drawn = try await offThePool {
        let drawer = try KeyDrawer()
        return try frames.map { frame -> ([UInt8], DrawCounts) in
            var counts = DrawCounts()
            return (try drawer.draw(frame, counts: &counts), counts)
        }
    }
    for (index, (bytes, counts)) in drawn.enumerated() {
        #expect(counts.keyOverlays == 1 && counts.overlaySteps == 1, "frame \(index): \(counts)")
        #expect(close(pixel(bytes, width: size.x, x: capPixel.x, y: capPixel.y), [0x3C, 0x3A, 0x3A, 255], 2), "frame \(index)")
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func legacyDrawsNoKeys() async throws {
    let take = StageDrawing.bareTake(seconds: 3)
    var zoomed = EditDocument.legacy(take: take, events: [])
    zoomed.zoom.regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 1.8)]
    zoomed.zoom.motionBlur = 1
    let events = [copy(1), press(1.4, code: 0, chars: "a")]
    var frames: [RenderFrame] = []
    for document in [EditDocument.legacy(take: take, events: []), zoomed] {
        #expect(document.keys == .legacy)
        let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size1080)
        for t in [0.1, 1.05, 1.5, 2.0] { frames.append(scene.frame(at: t)) }
    }
    #expect(frames.allSatisfy { $0.keys == nil })
    let drawnFrames = frames
    let counts = try await offThePool {
        let drawer = try KeyDrawer()
        return try drawnFrames.map { frame -> DrawCounts in
            var counts = DrawCounts()
            _ = try drawer.draw(frame, counts: &counts)
            return counts
        }
    }
    #expect(counts.allSatisfy { $0.keyOverlays == 0 && $0.overlaySteps == 1 })
}

// MARK: - Preview and export

/// A take of one 4 s display segment from `base` with the cursor moving over it, shortcuts and typing, and its legacy
/// document with the keys shown in "All" at the bottom over Classic captions at the bottom, and a zoom in from 2 s with
/// the motion blur on.
private func keyedProject(in dir: URL) async throws -> (LoadedProject, EditDocument) {
    let frame = Rect(x: 0, y: 0, width: 640, height: 360)
    let builder = try TakeBuilder(in: dir, formatVersion: 4)
    try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: frame), segments: [VideoSegmentSpec(start: base, seconds: 4)])
    let typing = Array("hola").enumerated().map { press(0.3 + 0.1 * Double($0.offset), code: 0, chars: String($0.element)) }
    try builder.addEvents(
        (cursorEvents(from: base, seconds: 4, across: frame) + typing + [copy(1.2), press(2.2, code: 1, chars: "s", mods: command | shift)])
            .sorted { $0.t < $1.t })
    let project = try builder.write()
    var document = EditDocument.legacy(for: project)
    document.keys = KeyOverlayPlan(mode: .all, position: .bottomCenter, size: .medium)
    var style = CaptionStyle.default
    style.preset = .classic
    document.captions = CaptionPlan(show: true, style: style)
    document.transcript = Transcript(
        language: "es-MX", engine: "speechTranscriber-1",
        takes: [TranscriptTake(
            take: project.take.id, track: "microphone-1",
            words: ["Guardar", "con", "comando", "ese"].enumerated().map { index, text in
                TranscriptWord(start: base.adding(seconds: 0.2 + 0.6 * Double(index)), end: base.adding(seconds: 0.7 + 0.6 * Double(index)), text: text)
            })])
    document.zoom.regions = [StageDrawing.zoom(1, from: 2, to: 4, depth: 1.6)]
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
func previewIsTheExportWithKeys() async throws {
    try await withTemporaryDirectory { dir in
        let (project, document) = try await keyedProject(in: dir)
        let size = SIMD2(1280, 720)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        var plain = document
        plain.keys = .legacy
        let keyless = try FrameRenderer(project: project, document: plain, outputSize: size)
        let preview = PreviewRenderer(renderer: renderer)
        let scene = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
        // The pill; the cross-fade to ⌘C; ⌘⇧S through the zoom's blur.
        for t in [0.55, 1.25, 2.6] {
            let frame = scene.frame(at: t)
            #expect(frame.keys != nil, "at \(t) s")
            if t == 1.25 { #expect(frame.keys?.items.count == 2, "the cross-fade at \(t) s") }
            if t == 2.6 { #expect(!frame.subframes.isEmpty, "the zoom's blur at \(t) s") }
            let export = try await exported(renderer, at: t, size: size)
            let previewed = try await offThePool { try preview.snapshot(at: t) }
            #expect(export == previewed, "at \(t) s")
            let without = try await exported(keyless, at: t, size: size)
            #expect(without != export, "at \(t) s")
        }
    }
}

// MARK: - Measures and shots

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func keyOverlayPreviewBench() async throws {
    // 600 frames of 1080p (10 s at 60 fps) with a shortcut a second (⌘ ⇧ and a key that changes) and the pill of what is
    // typed between them in "All", drawn into one target as the preview does, after 8 frames to warm up: the CPU time of
    // the frame's layer (`FrameEvaluator.frame`), of its encoding (with a new texture drawn in it) and the GPU time, with
    // and without the keys.
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    var events: [InputEvent] = []
    for second in 0..<11 {
        let s = Double(second)
        events.append(press(s + 0.1, code: UInt16(second), chars: String(letters[second]), mods: command | shift))
        for (index, letter) in "hola".enumerated() { events.append(press(s + 0.4 + 0.08 * Double(index), code: 0, chars: String(letter))) }
    }
    let take = StageDrawing.bareTake(seconds: 12)
    var document = EditDocument.legacy(take: take, events: [])
    document.keys = KeyOverlayPlan(mode: .all, position: .bottomCenter, size: .medium)
    let scene = FrameEvaluator(take: take, events: events, document: document, outputSize: size1080)
    var layerTimes: [Double] = []
    var frames: [RenderFrame] = []
    for n in 0..<608 {
        let start = DispatchTime.now().uptimeNanoseconds
        let frame = scene.frame(at: Double(n) / 60)
        if n >= 8 { layerTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
        frames.append(frame)
    }
    #expect(frames.filter { $0.keys != nil }.count > 400)
    let drawnFrames = frames
    struct Times: Sendable { var cpu: [Double] = [], gpu: [Double] = [] }
    let (with, without, textures) = try await offThePool { () -> (Times, Times, Int) in
        let drawer = try KeyDrawer()
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
        let without = try measure(drawnFrames.map { var plain = $0; plain.keys = nil; return plain })
        let before = drawer.textures.drawnCount
        let with = try measure(drawnFrames)
        return (with, without, drawer.textures.drawnCount - before)
    }
    func p(_ values: [Double], _ q: Double) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * q))] }
    print(String(
        format: "keys 1080p, %d frames: layer p50 %.3f ms, p95 %.3f, max %.3f; CPU encode p50 %.3f ms, p95 %.3f, max %.3f "
            + "(without: p50 %.3f, max %.3f); GPU p50 %.3f ms, p95 %.3f, max %.3f (without: p50 %.3f, p95 %.3f); %d textures in 10 s",
        with.cpu.count, p(layerTimes, 0.5), p(layerTimes, 0.95), layerTimes.max() ?? 0, p(with.cpu, 0.5), p(with.cpu, 0.95),
        with.cpu.max() ?? 0, p(without.cpu, 0.5), without.cpu.max() ?? 0, p(with.gpu, 0.5), p(with.gpu, 0.95), with.gpu.max() ?? 0,
        p(without.gpu, 0.5), p(without.gpu, 0.95), textures))
    // The CPU time of one texture, a shortcut of three keys and a pill of 20 characters, at 1080p and at 4K: median of 5
    // after one.
    for outputSize in [size1080, SIMD2(3840, 2160)] {
        var row: [String] = []
        for content in [KeyOverlayContent.keys(["⌘", "⇧", "4"]), .text("…grabando la pantalla")] {
            let h = KeyOverlayPlacement.capHeight(.large, outputSize: outputSize)
            var times: [Double] = []
            for run in 0..<6 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try? KeyOverlayTexture.bitmap(of: content, capHeight: h)
                if run > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            row.append(String(format: "%.2f ms", times.sorted()[2]))
        }
        print("key texture, large, at \(outputSize.x)×\(outputSize.y): shortcut \(row[0]), pill \(row[1])")
    }
    #expect(textures >= 10)
}

/// Writes frames of shortcuts and pills in each size and position, 16:9 and 9:16 and 4K, the keys above Classic captions
/// at the bottom, over light and dark content, to `TOMA_KEY_SHOTS` as PNG.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_KEY_SHOTS"] != nil))
func keyShots() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOMA_KEY_SHOTS"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let contents: [(String, KeyOverlayContent)] = [
        ("shortcut", .keys(["⌘", "⇧", "4"])), ("modifiers", .keys(["⌘", "⇧", "⌥", "⌃", "Z"])), ("tab", .keys(["⌘", "⇥"])),
        ("space", .keys(["⌘", "␣"])), ("arrows", .keys(["⌥", "←"])), ("words", .keys(["⌃", "F12"])), ("esc", .keys(["esc"])),
        ("return", .keys(["⌘", "↩"])), ("pill", .text("Hola, ¿qué tal?")), ("pill-long", .text("…ndo la pantalla en vivo")),
    ]
    var shots: [(name: String, frame: RenderFrame)] = []
    for (orientation, size) in [("16x9", size1080), ("9x16", SIMD2(1080, 1920)), ("4k", SIMD2(3840, 2160))] {
        for (name, content) in contents {
            for overlay in OverlaySize.allCases where orientation == "16x9" || overlay == .medium {
                for captioned in [false, true] where !captioned || overlay == .medium {
                    var style = CaptionStyle.default
                    style.preset = .classic
                    let captions = CaptionPlan(show: captioned, style: style)
                    var document = EditDocument.legacy(take: StageDrawing.bareTake(seconds: 8), events: [])
                    document.captions = captions
                    document.transcript = Transcript(
                        language: "es-MX", engine: "speechTranscriber-1",
                        takes: [TranscriptTake(
                            take: takeID, track: "microphone-1",
                            words: ["Con", "comando", "mayúsculas", "cuatro", "se", "captura", "una", "parte."].enumerated().map { index, text in
                                TranscriptWord(start: base.adding(seconds: 0.3 * Double(index)), end: base.adding(seconds: 0.3 * Double(index) + 0.25), text: text)
                            })])
                    let caption = captioned
                        ? CaptionScene(document: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
                            .layer(atOutput: TimeMap.outputNanoseconds(seconds: 0.95))
                        : nil
                    let keys = KeyOverlayLayer(items: [item(content, size: overlay, outputSize: size, captions: captions)])
                    let whole = Rect(x: 0, y: 0, width: Double(size.x), height: Double(size.y))
                    let screen = ScreenLayer(trackID: trackID, sourceTime: base, rect: whole, cornerRadius: 0)
                    let frame = RenderFrame(
                        outputSize: size, gradientStart: .zero, gradientEnd: .one, gradientAngleDegrees: 0, screen: screen, keys: keys,
                        captions: caption)
                    shots.append(("\(orientation)-\(name)-\(overlay.rawValue)\(captioned ? "-captions" : "")", frame))
                }
            }
        }
    }
    let drawnShots = shots
    let images = try await offThePool {
        let drawer = try KeyDrawer()
        // Half white with grey bars like text, half a dark photo-like gradient: the keys over both.
        let screen = try drawer.texture(width: 960, height: 540) { x, y in
            if x < 480 {
                let bar = y % 36 < 8 && x > 40 && x < 440 && (y / 36) % 3 != 2
                return bar ? [90, 90, 90, 255] : [255, 255, 255, 255]
            }
            let t = Double(y) / 540, u = Double(x - 480) / 480
            return [UInt8(40 + 30 * u), UInt8(30 + 40 * t), UInt8(20 + 60 * (1 - t) * u), 255]
        }
        return try drawnShots.map { ($0.name, $0.frame.outputSize, try drawer.draw($0.frame, screen: screen)) }
    }
    for (name, size, bytes) in images {
        try writePNG(bytes, size: size, to: folder.appendingPathComponent("\(name).png"))
    }
    // The textures alone, enlarged 4× without smoothing, to look at the pixels.
    for (name, content) in contents.prefix(4) + [contents[8]] {
        let h = KeyOverlayPlacement.capHeight(.medium, outputSize: size1080)
        let bitmap = try #require(try KeyOverlayTexture.bitmap(of: content, capHeight: h))
        let scale = 4
        let large = SIMD2(bitmap.size.x * scale, bitmap.size.y * scale)
        var bytes = [UInt8](repeating: 0, count: large.x * large.y * 4)
        for y in 0..<large.y {
            for x in 0..<large.x {
                let from = ((y / scale) * bitmap.size.x + x / scale) * 4, to = (y * large.x + x) * 4
                // Over mid grey, so the box's translucency shows.
                let alpha = Double(bitmap.bytes[from + 3]) / 255
                for c in 0..<3 { bytes[to + c] = UInt8((Double(bitmap.bytes[from + c]) + 128 * (1 - alpha)).rounded()) }
                bytes[to + 3] = 255
            }
        }
        try writePNG(bytes, size: large, to: folder.appendingPathComponent("zoom-\(name).png"))
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
