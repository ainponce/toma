// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameRenderer.titleTexture` and `TitleTexture.drawCount`.
@testable import Render
import SyntheticCapture
import Testing

// The generic macOS window frame around the screen: the bar, its three buttons and its title, the window's corners.

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(1280, 720)
/// The background of these frames: a colour that is neither the bars' nor the screen's.
private let backgroundColor = RGBA(0.2, 0.4, 0.6, 1)
private let backgroundBGRA: SIMD4<Float> = [153, 102, 51, 255]
/// What the screen shows: every frame painted this blue.
private let screenBGRA: SIMD4<Float> = [255, 0, 0, 255]

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// decodes, which blocks (`offThePool` in DocumentRenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// `sample` painted pure blue.
@Sendable private func paintingBlue(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFF00_00FF, count: width)  // BGRA (255, 0, 0, 255)
    }
    return sample
}

/// A take of one second of a blue screen.
private func screenProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: trackID, source: displaySource(globalFrame: screenFrame),
        segments: [VideoSegmentSpec(start: base, seconds: 1, transform: paintingBlue)])
    return try builder.write()
}

/// The legacy document of `project` over a plain background, with a macOS window frame.
private func framed(
    _ project: LoadedProject, appearance: FrameAppearance = .light, title: String = "", buttons: Bool = true
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.style.background = .color(backgroundColor)
    document.style.frame = .macWindow(appearance: appearance, title: title, buttons: buttons)
    return document
}

/// The window frame of `document`'s frames.
private func windowLayer(_ project: LoadedProject, _ document: EditDocument) throws -> WindowFrameLayer {
    let frame = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size).frame(at: 0.5)
    return try #require(frame.windowFrame)
}

/// The frame at 0.5 s of `document`, as BGRA bytes.
private func render(_ project: LoadedProject, _ document: EditDocument) async throws -> [UInt8] {
    let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
    return try await offThePool { try renderer.renderBytes(at: 0.5) }
}

/// The BGRA colour of `hex` (`0xRRGGBB`), 0...255.
private func bgra(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4(Float(hex & 0xFF), Float((hex >> 8) & 0xFF), Float((hex >> 16) & 0xFF), 255)
}

@Test func framedDocumentPlacesTheScreenUnderTheBar() throws {
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 1))])])
    var document = EditDocument.legacy(take: take, events: [])
    let unframed = FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: 0.5)
    #expect(unframed.windowFrame == nil)
    document.style.frame = .macWindow(appearance: .dark, title: "Demo", buttons: false)
    let frame = FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: 0.5)
    let layout = StageLayout.windowRect(contentAspect: 16.0 / 9, padding: 0.08, outputSize: [1280, 720])
    let radius = 0.012 * 1280
    #expect(frame.windowFrame == WindowFrameLayer(
        rect: layout.window, barHeight: layout.barHeight, appearance: .dark, title: "Demo", buttons: false, cornerRadius: radius))
    // The screen fills the window under the bar, with the window's corners at its bottom.
    let screen = try #require(frame.screen)
    #expect(screen.rect == layout.screen && screen.cornerRadius == radius)
    // Everything else is as without the frame.
    var expected = unframed
    expected.screen?.rect = layout.screen
    expected.windowFrame = frame.windowFrame
    #expect(frame == expected)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func buttonsAreTheGenericColors() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        for appearance in [FrameAppearance.light, .dark] {
            let document = framed(project, appearance: appearance)
            let layer = try windowLayer(project, document)
            let bytes = try await render(project, document)
            let bar = layer.barHeight, centreY = layer.rect.y + bar / 2
            func at(_ x: Double, _ y: Double) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: Int(x), y: Int(y)) }
            // The centres of the three circles, 0.66 of the bar apart from 0.6 of it.
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let x = layer.rect.x + (0.6 + 0.66 * Double(i)) * bar
                #expect(isClose(at(x, centreY), bgra(UInt32(hex))), "\(appearance) button \(i): \(at(x, centreY))")
            }
            // Between two circles (0.21 of the bar in radius), and right of them, the bar.
            let barColor = bgra(appearance == .light ? 0xECECEC : 0x2B2B2E)
            for x in [layer.rect.x + 0.93 * bar, layer.rect.x + 3 * bar, layer.rect.x + layer.rect.width - 2 * bar] {
                #expect(isClose(at(x, centreY), barColor, tolerance: 1), "\(appearance) at \(x): \(at(x, centreY))")
            }
            // Without the buttons, the bar where the first circle was.
            let plain = try await render(project, framed(project, appearance: appearance, buttons: false))
            let x = Int(layer.rect.x + 0.6 * bar)
            #expect(isClose(pixel(plain, width: size.x, x: x, y: Int(centreY)), barColor, tolerance: 1), "\(appearance)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func titleIsRedrawnOnlyWhenItChanges() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let document = framed(project, title: "Demo")
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let frames = try await offThePool { try (0..<10).map { try renderer.renderBytes(at: Double($0) / 10) } }
        #expect(renderer.titleTexture.drawCount == 1)
        // Another renderer draws the same title the same way: the preview's and the export's are the same bytes.
        let other = try FrameRenderer(project: project, document: document, outputSize: size)
        #expect(try await offThePool { try other.renderBytes(at: 0) } == frames[0])

        let layer = try windowLayer(project, document)
        let titles = renderer.titleTexture
        let first = try #require(try titles.texture(for: layer))
        #expect(titles.drawCount == 1)
        var renamed = layer
        renamed.title = "Another"
        let second = try #require(try titles.texture(for: renamed))
        #expect(titles.drawCount == 2 && second !== first)
        // Its size too: another bar is another texture.
        var larger = renamed
        larger.barHeight *= 2
        #expect(try titles.texture(for: larger) !== second && titles.drawCount == 3)
        // What does not change the drawing does not redraw it.
        larger.cornerRadius += 4
        _ = try titles.texture(for: larger)
        #expect(titles.drawCount == 3)
        // An empty title draws nothing.
        larger.title = ""
        #expect(try titles.texture(for: larger) == nil && titles.drawCount == 3)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func emptyTitleDrawsNoText() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        for appearance in [FrameAppearance.light, .dark] {
            let layer = try windowLayer(project, framed(project, appearance: appearance))
            let barColor = bgra(appearance == .light ? 0xECECEC : 0x2B2B2E)
            // The bar's whole pixels right of the third button (its right edge at 2.13 of the bar), away from the
            // window's right corner.
            let columns =
                Int((layer.rect.x + 2.2 * layer.barHeight).rounded(.up))..<Int(layer.rect.x + layer.rect.width - layer.cornerRadius)
            let rows = Int(layer.rect.y.rounded(.up))..<Int((layer.rect.y + layer.barHeight).rounded(.down))
            func textPixels(_ bytes: [UInt8]) -> Int {
                var count = 0
                for y in rows {
                    for x in columns where !isClose(pixel(bytes, width: size.x, x: x, y: y), barColor, tolerance: 1) { count += 1 }
                }
                return count
            }
            #expect(textPixels(try await render(project, framed(project, appearance: appearance))) == 0, "\(appearance)")
            // A title is drawn there, centred in the window.
            let titled = try await render(project, framed(project, appearance: appearance, title: "Toma Demo"))
            #expect(textPixels(titled) > 50, "\(appearance)")
            let centre = Int(layer.rect.x + layer.rect.width / 2)
            func drawn(_ columns: Range<Int>) -> Bool {
                rows.contains { y in columns.contains { !isClose(pixel(titled, width: size.x, x: $0, y: y), barColor, tolerance: 1) } }
            }
            #expect(drawn(centre - 60..<centre) && drawn(centre..<centre + 60), "\(appearance)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cornersOnTheWholeWindowNotTheScreenTop() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        let document = framed(project)
        let layer = try windowLayer(project, document)
        let bytes = try await render(project, document)
        func at(_ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }
        let rect = layer.rect, radius = layer.cornerRadius
        #expect(radius > 10 && radius < layer.barHeight)
        let left = Int(rect.x.rounded(.up)), right = Int((rect.x + rect.width).rounded(.down)) - 1
        let top = Int(rect.y.rounded(.up)), bottom = Int((rect.y + rect.height).rounded(.down)) - 1
        let screenTop = Int((rect.y + layer.barHeight).rounded(.up))
        // The window's four corners are round: the background shows at each.
        for (x, y) in [(left, top), (right, top), (left, bottom), (right, bottom)] {
            #expect(isClose(at(x, y), backgroundBGRA), "corner (\(x), \(y)): \(at(x, y))")
        }
        // The screen's top corners are square: the pixel just under the bar at each side is the screen's.
        for x in [left, right] {
            #expect(isClose(at(x, screenTop), screenBGRA), "(\(x), \(screenTop)): \(at(x, screenTop))")
        }
        // The bar meets the screen without a seam of background: the row of the edge is bar and screen only.
        let barColor = bgra(0xECECEC)
        let seam = Int((rect.y + layer.barHeight).rounded(.down))
        for x in stride(from: left, through: right, by: 7) {
            let p = at(x, seam), q = SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), Float(p.w))
            // Some mix of the bar and the screen: its red and green are the bar's share of 0xEC, its blue the rest.
            let barShare = q.z / 236
            #expect(abs(q.y - q.z) <= 2 && abs(q.x - (barShare * 236 + (1 - barShare) * 255)) <= 2, "seam at \(x): \(p)")
        }
        // Along the bottom, the screen reaches the window's round corners.
        #expect(isClose(at(left + Int(radius), bottom), screenBGRA), "\(at(left + Int(radius), bottom))")
        #expect(isClose(at(left + 1, bottom - Int(radius)), screenBGRA), "\(at(left + 1, bottom - Int(radius)))")
        // At the top of the window, past its corner, the bar.
        #expect(isClose(at(left + Int(radius), top + 1), barColor, tolerance: 1), "\(at(left + Int(radius), top + 1))")
    }
}

@Test func windowCornersAreAtMostOnePointThreeBars() throws {
    let take = makeTake(tracks: [displayTrack(globalFrame: screenFrame, segments: [segment(start: base, end: base.adding(seconds: 1))])])
    var document = EditDocument.legacy(take: take, events: [])
    document.style.frame = .macWindow(appearance: .light, title: "", buttons: true)
    document.style.shadow = 0.5
    func frame() -> RenderFrame { FrameEvaluator(take: take, events: [], document: document, outputSize: size).frame(at: 0.5) }
    // Today's corners are under 1.3 bars: as they are.
    let small = try #require(frame().windowFrame)
    #expect(small.cornerRadius == 0.012 * 1280)
    // The slider's largest corners, 0.04 of the width, are more than 1.3 bars of a 16:9 window: 1.3 bars, on the window,
    // the screen at its bottom and the shadow.
    document.style.cornerRadius = 0.04
    let large = frame()
    let window = try #require(large.windowFrame)
    #expect(0.04 * 1280 > 1.3 * window.barHeight)
    #expect(window.cornerRadius == 1.3 * window.barHeight)
    #expect(large.screen?.cornerRadius == window.cornerRadius && large.shadow?.cornerRadius == window.cornerRadius)
    // Without the frame, the screen keeps them.
    document.style.frame = .none
    #expect(frame().screen?.cornerRadius == 0.04 * 1280)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func largeCornersNeverCutTheButtons() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await screenProject(in: dir)
        var document = framed(project)
        document.style.cornerRadius = 0.04
        let layer = try windowLayer(project, document)
        let bytes = try await render(project, document)
        // The red button's top-left edge, 4.5 px from its centre (its radius is 0.21 bars, 5.8 px): inside the window's
        // corner of 1.3 bars, where one of 0.04 of the width would show the background.
        let centre = layer.firstButton
        let edge = centre + SIMD2(-4.5, -4.5) / 2.squareRoot()
        let p = pixel(bytes, width: size.x, x: Int(edge.x), y: Int(edge.y))
        #expect(isClose(p, bgra(0xFF5F57), tolerance: 2), "\(p)")
        // The whole button is red to its rim, all around it.
        for step in 0..<16 {
            let angle = Double(step) * .pi / 8
            let point = centre + 3.5 * SIMD2(cos(angle), sin(angle))
            let p = pixel(bytes, width: size.x, x: Int(point.x), y: Int(point.y))
            #expect(isClose(p, bgra(0xFF5F57), tolerance: 2), "at \(angle): \(p)")
        }
    }
}
