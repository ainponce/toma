// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, the compositor's counts and the readers' times.
@testable import Render
import SyntheticCapture
import Testing
import simd

// Screen changes, geometry changes and their spring (design §7.6, plan decision 30): with `spring`, the screen's rect goes
// from the old shape to the new one and a change of screen crossfades its content over 0.25 s, each screen filling the rect
// it passes through; with `none` it jumps, as in phase 0 and 1a.

private let size = SIMD2(1920, 1080)
/// 16:9, and 1:1 to its right.
private let display1 = Rect(x: 0, y: 0, width: 640, height: 360)
private let display2 = Rect(x: 640, y: 0, width: 480, height: 480)
private let display2ID = "display-2"
private let wholeFrame = Rect(x: 0, y: 0, width: 1, height: 1)

/// Display 1 and display 2, each with a segment of `seconds` without files.
private func twoDisplays(seconds: Double = 6, area: Rect? = nil) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: display1, captureArea: area, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
        displayTrack(
            id: display2ID, displayID: 2, globalFrame: display2,
            segments: [segment(track: display2ID, start: base, end: base.adding(seconds: seconds))]),
    ])
}

/// The legacy document of `take` with `transition`, starting on `initial` and changing to each of `changes` (seconds of
/// the take, track).
private func document(
    _ take: TakeRecord, _ events: [InputEvent] = [], initial: String = trackID, changes: [(Double, String)] = [(3, display2ID)],
    transition: GeometryTransition
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.screens.initial[takeID] = initial
    document.screens.changes = changes.enumerated().map { index, change in
        ScreenChange(
            id: String(format: "p-%08x", index + 1), take: takeID, t: base.adding(seconds: change.0), track: change.1, origin: .user)
    }
    document.style.geometryTransition = transition
    return document
}

/// How far `value` is from `from` to `to`.
private func along(_ from: Double, _ to: Double, _ value: Double) -> Double {
    (value - from) / (to - from)
}

/// The shape (width over height) of what `layer` shows of a frame of a screen of `display`'s shape.
private func shape(of layer: ScreenLayer, on display: Rect) -> Double {
    layer.crop.width * display.width / (layer.crop.height * display.height)
}

private func cursor(_ seconds: Double, _ x: Double, _ y: Double) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: .cursor(x: x, y: y))
}

@Test func screenChangeSpringsTheRectAndCrossfades() throws {
    let take = twoDisplays()
    let spring = FrameEvaluator(take: take, events: [], document: document(take, transition: .spring), outputSize: size)
    let jump = FrameEvaluator(take: take, events: [], document: document(take, transition: .none), outputSize: size)
    let from = try #require(jump.frame(at: 2.9).screen), to = try #require(jump.frame(at: 3.125).screen)
    #expect(from.trackID == trackID && to.trackID == display2ID && from.rect.width > to.rect.width)

    let frame = spring.frame(at: 3.125)
    let screen = try #require(frame.screen), previous = try #require(frame.previousScreen)
    #expect(screen.trackID == display2ID && previous.trackID == trackID)
    #expect(screen.opacity == 0.5 && previous.opacity == 1)
    #expect(abs(GeometryTransitions.progress(seconds: 0.125) - 0.7361) < 1e-4)
    // The rect, 0.7361 of the way: both screens are 772.8 px tall, so only its width and its left edge move.
    #expect(abs(along(from.rect.x, to.rect.x, screen.rect.x) - 0.7361) < 1e-4)
    #expect(abs(along(from.rect.width, to.rect.width, screen.rect.width) - 0.7361) < 1e-4)
    #expect(screen.rect.y == from.rect.y && screen.rect.height == from.rect.height)
    #expect(previous.rect == screen.rect && previous.cornerRadius == screen.cornerRadius)
    // Each fills that rect: display 2 cut at its top and bottom, display 1 at its sides.
    let rectShape = screen.rect.width / screen.rect.height
    #expect(abs(shape(of: screen, on: display2) - rectShape) < 1e-9 && screen.crop.width == 1 && screen.crop.height < 1)
    #expect(abs(shape(of: previous, on: display1) - rectShape) < 1e-9 && previous.crop.height == 1 && previous.crop.width < 1)
    #expect(abs(screen.crop.y + screen.crop.height / 2 - 0.5) < 1e-12 && abs(previous.crop.x + previous.crop.width / 2 - 0.5) < 1e-12)

    // The crossfade is linear and over at 0.25 s; the spring goes on, and settles on display 2's rect exactly.
    #expect(spring.frame(at: 3.0625).screen?.opacity == 0.25)
    let after = spring.frame(at: 3.25)
    #expect(after.previousScreen == nil && after.screen?.opacity == 1)
    let moving = try #require(after.screen)
    #expect(moving.rect != to.rect && abs(shape(of: moving, on: display2) - moving.rect.width / moving.rect.height) < 1e-9)
    for t in [2.9, 2.999, 4.5, 5.9] {
        #expect(spring.frame(at: t) == jump.frame(at: t), "at \(t) s")
    }

    // With `none`, it jumps, as today.
    let jumped = jump.frame(at: 3)
    #expect(jumped.screen?.trackID == display2ID && jumped.previousScreen == nil)
    #expect(jumped.screen?.opacity == 1 && jumped.screen?.crop == wholeFrame && jumped.screen?.rect == to.rect)
}

@Test func cursorMovesToTheNewScreenAtTheChange() throws {
    let take = twoDisplays()
    // On display 1 until 3 s, then on display 2: samples 0.1 s apart, so the legacy cursor never moves between them.
    let p1 = SIMD2(480.0, 90), p2 = SIMD2(760.0, 240)
    let events = (0..<60).map { i in
        let t = Double(i) / 10
        return t < 3 ? cursor(t, p1.x, p1.y) : cursor(t, p2.x, p2.y)
    }
    let evaluator = FrameEvaluator(take: take, events: events, document: document(take, events, transition: .spring), outputSize: size)
    /// Where `point` of `display` is drawn in `layer`: through the part of its frame the layer shows.
    func drawn(_ point: SIMD2<Double>, on display: Rect, _ layer: ScreenLayer) -> SIMD2<Double> {
        let inFrame = (point - SIMD2(display.x, display.y)) / SIMD2(display.width, display.height)
        let inCrop = (inFrame - SIMD2(layer.crop.x, layer.crop.y)) / SIMD2(layer.crop.width, layer.crop.height)
        return SIMD2(layer.rect.x, layer.rect.y) + inCrop * SIMD2(layer.rect.width, layer.rect.height)
    }
    let before = evaluator.frame(at: 2.99)
    let screen = try #require(before.screen)
    #expect(screen.trackID == trackID)
    #expect(simd_length(try #require(before.cursor).hotspot - drawn(p1, on: display1, screen)) < 1e-9)
    // From the change on, on display 2's content wherever the rect is, frame after frame: never anywhere in between.
    for n in 180...270 {
        let t = Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9
        let frame = evaluator.frame(at: t)
        let layer = try #require(frame.screen)
        #expect(layer.trackID == display2ID, "at \(t) s")
        let hotspot = try #require(frame.cursor, "at \(t) s").hotspot
        #expect(simd_length(hotspot - drawn(p2, on: display2, layer)) < 1e-9, "at \(t) s")
    }
    // At the change itself, display 2 fills display 1's rect: the cursor is drawn on it there, not on display 1.
    let at = evaluator.frame(at: 3)
    #expect(at.screen?.rect == screen.rect && at.screen?.opacity == 0 && at.previousScreen?.trackID == trackID)
    #expect(simd_length(try #require(at.cursor).hotspot - drawn(p1, on: display1, screen)) > 100)
}

@Test func geometryChangeSprings() throws {
    let take = twoDisplays()
    // Display 1 goes from 16:9 to 1:1 at 1.5 s.
    let square = Rect(x: 0, y: 0, width: 480, height: 480)
    let events = [InputEvent(t: base.adding(seconds: 1.5), kind: .displayGeometry(displayID: 1, frame: square, scale: 1))]
    let spring = FrameEvaluator(
        take: take, events: events, document: document(take, events, changes: [], transition: .spring), outputSize: size)
    let jump = FrameEvaluator(take: take, events: events, document: document(take, events, changes: [], transition: .none), outputSize: size)
    let from = try #require(jump.frame(at: 1.4).screen), to = try #require(jump.frame(at: 1.6).screen)
    #expect(from.rect.width > to.rect.width && to.crop == wholeFrame)

    let frame = spring.frame(at: 1.6)
    let screen = try #require(frame.screen)
    #expect(frame.previousScreen == nil && screen.opacity == 1 && screen.trackID == trackID)
    let p = GeometryTransitions.progress(seconds: 0.1)
    #expect(p > 0 && p < 1)
    #expect(abs(along(from.rect.x, to.rect.x, screen.rect.x) - p) < 1e-9)
    #expect(abs(along(from.rect.width, to.rect.width, screen.rect.width) - p) < 1e-9)
    #expect(screen.rect.width < from.rect.width && screen.rect.width > to.rect.width)
    // The new frame fills it, cut at its top and bottom.
    #expect(abs(shape(of: screen, on: square) - screen.rect.width / screen.rect.height) < 1e-9)
    #expect(screen.crop.width == 1 && screen.crop.height < 1)
    for t in [1.4, 1.499, 3.1, 5] {
        #expect(spring.frame(at: t) == jump.frame(at: t), "at \(t) s")
    }
    // A second change while the first moves starts from the rect shown then.
    let back = events + [InputEvent(t: base.adding(seconds: 1.6), kind: .displayGeometry(displayID: 1, frame: display1, scale: 1))]
    let twice = FrameEvaluator(
        take: take, events: back, document: document(take, back, changes: [], transition: .spring), outputSize: size)
    #expect(twice.frame(at: 1.6).screen?.rect == screen.rect)
    let returning = try #require(twice.frame(at: 1.7).screen)
    #expect(abs(along(screen.rect.width, from.rect.width, returning.rect.width) - p) < 1e-9)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func onlyShownScreensAreDecoded() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: trackID, source: displaySource(globalFrame: display1), segments: [VideoSegmentSpec(start: base, seconds: 4)])
        var source2 = displaySource(globalFrame: display2)
        source2.displayID = 2
        try await builder.addVideoTrack(
            id: display2ID, source: source2, segments: [VideoSegmentSpec(start: base, seconds: 4, width: 480, height: 480)])
        let project = try builder.write()
        for transition in [GeometryTransition.spring, .none] {
            let renderer = try FrameRenderer(
                project: project, document: document(project.take, transition: transition), outputSize: [320, 180])
            let asked = try await StageDrawing.offThePool {
                for n in 0..<120 {
                    _ = try renderer.renderBytes(at: Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9)
                }
                return (renderer.askedFor(track: trackID), renderer.askedFor(track: display2ID))
            }
            // Display 2 is read from the change on; display 1 until it, and through the crossfade with the spring.
            #expect(asked.0?.lowerBound == base, "\(transition)")
            #expect(asked.1?.lowerBound == base.adding(seconds: 3), "\(transition)")
            let last = try #require(asked.0?.upperBound)
            if transition == .spring {
                #expect(last >= base.adding(seconds: 3.2) && last < base.adding(seconds: 3.25), "\(last)")
            } else {
                #expect(last < base.adding(seconds: 3), "\(last)")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func missingVideoListsOnlyTheScreenShown() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Gaps", app: AppInfo(name: "Tests", version: "0"), now: Date())
        // No file at all: both screens are missing all along, but each is listed only where it is shown.
        let project = makeProject(package, take: twoDisplays())
        func missing(_ transition: GeometryTransition, changes: [(Double, String)]) throws -> [MissingVideo] {
            try FrameRenderer(
                project: project, document: document(project.take, changes: changes, transition: transition), outputSize: [320, 180]
            ).missingVideo
        }
        let file1 = "takes/\(takeID)/\(trackID)/seg-0001.mov", file2 = "takes/\(takeID)/\(display2ID)/seg-0001.mov"
        #expect(try missing(.none, changes: [(3, display2ID)]) == [
            MissingVideo(track: trackID, file: file1, start: 0, end: 3, reason: .fileMissing),
            MissingVideo(track: display2ID, file: file2, start: 3, end: 6, reason: .fileMissing),
        ])
        // With the spring both are shown during the crossfade; back on display 1 later, it is listed there again.
        #expect(try missing(.spring, changes: [(3, display2ID), (5, trackID)]) == [
            MissingVideo(track: trackID, file: file1, start: 0, end: 3.25, reason: .fileMissing),
            MissingVideo(track: display2ID, file: file2, start: 3, end: 5.25, reason: .fileMissing),
            MissingVideo(track: trackID, file: file1, start: 5, end: 6, reason: .fileMissing),
        ])
        // Trimmed past the change, display 1 is never shown: none of its gaps is.
        var trimmed = document(project.take, changes: [(3, display2ID)], transition: .none)
        trimmed.sequence = [clip(1, from: 4, to: 6)]
        #expect(try FrameRenderer(project: project, document: trimmed, outputSize: [320, 180]).missingVideo == [
            MissingVideo(track: display2ID, file: file2, start: 0, end: 2, reason: .fileMissing),
        ])
        // Display 1 left at 3 s, display 2 at 3.1 s for display 3: display 1 is drawn under display 2 only until then, and
        // listed only that long.
        let display3 = "display-3", file3 = "takes/\(takeID)/display-3/seg-0001.mov"
        let three = makeProject(package, take: makeTake(tracks: twoDisplays().tracks + [
            displayTrack(
                id: display3, displayID: 3, globalFrame: Rect(x: 1120, y: 0, width: 640, height: 360),
                segments: [segment(track: display3, start: base, end: base.adding(seconds: 6))]),
        ]))
        let quick = document(three.take, changes: [(3, display2ID), (3.1, display3)], transition: .spring)
        let evaluator = FrameEvaluator(take: three.take, events: [], document: quick, outputSize: [320, 180])
        #expect(evaluator.frame(at: 3.05).previousScreen?.trackID == trackID)
        #expect(evaluator.frame(at: 3.15).previousScreen?.trackID == display2ID)
        #expect(try FrameRenderer(project: three, document: quick, outputSize: [320, 180]).missingVideo == [
            MissingVideo(track: trackID, file: file1, start: 0, end: 3.1, reason: .fileMissing),
            MissingVideo(track: display2ID, file: file2, start: 3, end: 3.35, reason: .fileMissing),
            MissingVideo(track: display3, file: file3, start: 3.1, end: 6, reason: .fileMissing),
        ])
    }
}

/// Clip `number` of the take over its seconds `[from, to)`.
private func clip(_ number: Int, from: Double, to: Double) -> Clip {
    Clip(id: String(format: "c-%08x", number), take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), speed: 1)
}

@Test func changesInACutAreOneAndOneBeforeTheFirstClipIsUnderWay() throws {
    let take = twoDisplays()
    func evaluator(_ changes: [(Double, String)], _ sequence: [Clip], _ transition: GeometryTransition = .spring) -> FrameEvaluator {
        var doc = document(take, changes: changes, transition: transition)
        doc.sequence = sequence
        return FrameEvaluator(take: take, events: [], document: doc, outputSize: size)
    }
    // The second second is cut out, from 2 s to 4 s of the take: what changes in it changes where the cut closes, 2 s out.
    let cut = [clip(1, from: 0, to: 2), clip(2, from: 4, to: 6)]
    // To display 2 and back inside the cut: nothing changes there.
    let back = evaluator([(2.5, display2ID), (3.5, trackID)], cut)
    for t in [1.9, 2, 2.1, 2.3] {
        #expect(back.frame(at: t) == evaluator([(2.5, display2ID), (3.5, trackID)], cut, .none).frame(at: t), "at \(t) s")
        #expect(back.frame(at: t).screen?.trackID == trackID && back.frame(at: t).previousScreen == nil, "at \(t) s")
    }
    // To display 2, back and to display 2 again: one change, from display 1, shown before the cut.
    let jumps = evaluator([(2.5, display2ID), (3.5, trackID), (3.7, display2ID)], cut, .none)
    let from = try #require(jumps.frame(at: 1.9).screen), to = try #require(jumps.frame(at: 2.5).screen)
    let again = evaluator([(2.5, display2ID), (3.5, trackID), (3.7, display2ID)], cut).frame(at: 2.125)
    let screen = try #require(again.screen)
    #expect(screen.trackID == display2ID && screen.opacity == 0.5 && again.previousScreen?.trackID == trackID)
    #expect(abs(along(from.rect.width, to.rect.width, screen.rect.width) - GeometryTransitions.progress(seconds: 0.125)) < 1e-9)

    // The start trimmed 0.1 s after the change: at output 0 it is 0.1 s under way.
    let trimmed = evaluator([(3, display2ID)], [clip(1, from: 3.1, to: 6)])
    let start = trimmed.frame(at: 0)
    let first = try #require(start.screen)
    #expect(first.trackID == display2ID && start.previousScreen?.trackID == trackID && abs(first.opacity - 0.4) < 1e-12)
    #expect(abs(along(from.rect.width, to.rect.width, first.rect.width) - GeometryTransitions.progress(seconds: 0.1)) < 1e-9)
    #expect(trimmed.frame(at: 0.15).previousScreen == nil && trimmed.frame(at: 0.15).screen?.opacity == 1)
    #expect(trimmed.frame(at: 1.4) == evaluator([(3, display2ID)], [clip(1, from: 3.1, to: 6)], .none).frame(at: 1.4))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aSpringOfTheWindowDrawsItsTitleAFewTimes() throws {
    let take = twoDisplays()
    // In a macOS window frame with a title, display 1 goes from 16:9 to 1:1 at 1.5 s, and back at 3.5 s.
    let square = Rect(x: 0, y: 0, width: 480, height: 480)
    let events = [
        InputEvent(t: base.adding(seconds: 1.5), kind: .displayGeometry(displayID: 1, frame: square, scale: 1)),
        InputEvent(t: base.adding(seconds: 3.5), kind: .displayGeometry(displayID: 1, frame: display1, scale: 1)),
    ]
    let outputSize = SIMD2(1280, 720)
    var doc = document(take, events, changes: [], transition: .spring)
    doc.style.frame = .macWindow(appearance: .light, title: "Toma Toma Toma", buttons: true)
    let evaluator = FrameEvaluator(take: take, events: events, document: doc, outputSize: outputSize)
    let drawer = try StageDrawing.Drawer()
    let titles = TitleTexture(device: drawer.device)
    var moving = 0
    for n in 60..<330 {
        let frame = evaluator.frame(at: Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9)
        let window = try #require(frame.windowFrame)
        if frame.settledWindowFrame != nil { moving += 1 }
        let source = try #require(TitleTexture.source(for: frame))
        let texture = try #require(try titles.texture(for: source, scale: TitleTexture.scale(for: frame)))
        // Never magnified: at least as many texels across as the bar has pixels now.
        #expect(Double(texture.width) >= window.rect.width.rounded(.down), "frame \(n)")
    }
    // Two springs of 1.5 s, every frame moving, and only a few titles: from where the window goes, a step of √2 at a time.
    #expect(moving > 150)
    #expect(titles.drawCount <= 6, "\(titles.drawCount) titles")
    // Settled, the title is the window's own, one texel per pixel.
    let settled = evaluator.frame(at: 3.2)
    #expect(settled.settledWindowFrame == nil && TitleTexture.scale(for: settled) == 1)

    // Mid-way, the title is drawn where the window's own would be.
    let frame = evaluator.frame(at: 1.6)
    let window = try #require(frame.windowFrame)
    var own = frame
    own.settledWindowFrame = nil
    func ink(_ frame: RenderFrame, title: any MTLTexture) throws -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let target = try StageDrawing.target(device: drawer.device, size: outputSize)
        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
        try drawer.compositor.encode(
            frame, screen: drawer.screen, camera: nil, cursor: drawer.cursor, windowTitle: title, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytes = StageDrawing.bytes(of: target)
        var xs: [Int] = [], ys: [Int] = []
        for y in Int(window.rect.y)..<Int(window.rect.y + window.barHeight) {
            for x in Int(window.rect.x)..<Int(window.rect.x + window.rect.width) {
                let p = pixel(bytes, width: outputSize.x, x: x, y: y)
                if p.x < 160, p.y < 160, p.z < 160 { xs.append(x); ys.append(y) }
            }
        }
        return (try #require(xs.min())...(try #require(xs.max())), try #require(ys.min())...(try #require(ys.max())))
    }
    let source = try #require(TitleTexture.source(for: frame))
    let drawn = try ink(frame, title: try #require(try titles.texture(for: source, scale: TitleTexture.scale(for: frame))))
    let exact = try ink(own, title: try #require(try titles.texture(for: window, scale: 1)))
    // Centred on the same pixel, in the same rows, and as wide within 5 %: the glyphs' advances are whole pixels at each
    // size, so a title made larger and drawn smaller is not exactly as wide as one made at its size.
    #expect(abs((drawn.x.lowerBound + drawn.x.upperBound) - (exact.x.lowerBound + exact.x.upperBound)) <= 2, "\(drawn) against \(exact)")
    #expect(abs(drawn.y.lowerBound - exact.y.lowerBound) <= 1 && abs(drawn.y.upperBound - exact.y.upperBound) <= 1, "\(drawn) against \(exact)")
    #expect(abs(Double(drawn.x.count) / Double(exact.x.count) - 1) <= 0.05, "\(drawn) against \(exact)")
}

/// A `.bgra8Unorm` texture `width` × `height` of the opaque BGRA colour `inside`, but `outside` (BGRA) out of `area` (whole
/// pixels).
private func solidTexture(
    device: any MTLDevice, width: Int, height: Int, inside: SIMD4<UInt8>, outside: SIMD4<UInt8>? = nil,
    area: (x: Range<Int>, y: Range<Int>)? = nil
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let inArea = area.map { $0.x.contains(x) && $0.y.contains(y) } ?? true
            let color = inArea ? inside : outside ?? inside
            let i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (color.x, color.y, color.z, color.w)
        }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return texture
}

/// `frame` drawn by `drawer`'s compositor with `screen` and `previous` as the two screens' frames.
private func draw(
    _ frame: RenderFrame, drawer: StageDrawing.Drawer, screen: any MTLTexture, previous: (any MTLTexture)?
) throws -> [UInt8] {
    let target = try StageDrawing.target(device: drawer.device, size: frame.outputSize)
    let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
    try drawer.compositor.encode(
        frame, screen: screen, previousScreen: previous, camera: nil, cursor: drawer.cursor, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    return StageDrawing.bytes(of: target)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func crossfadeIsDrawnUnderTheBlurToo() throws {
    // A red background; display 1 in blue going away under display 2 in green at half its opacity.
    let drawer = try StageDrawing.Drawer()
    let blue = try solidTexture(device: drawer.device, width: 64, height: 36, inside: SIMD4(255, 0, 0, 255))
    let green = try solidTexture(device: drawer.device, width: 64, height: 36, inside: SIMD4(0, 255, 0, 255))
    let outputSize = SIMD2(320, 180)
    let rect = Rect(x: 40, y: 20, width: 240, height: 140)
    var frame = RenderFrame(
        outputSize: outputSize, gradientStart: .zero, gradientEnd: .zero, gradientAngleDegrees: 0,
        screen: ScreenLayer(trackID: display2ID, sourceTime: base, rect: rect, cornerRadius: 12, opacity: 0.5),
        background: .color(SIMD4(1, 0, 0, 1)))
    let still = Array(repeating: StageSubframe(stage: .identity(outputSize: outputSize)), count: 16)
    let centre = (x: 160, y: 90)
    // Alone, the background shows through it; with the screen going away under it, that one does: drawn once, and the same
    // under the motion blur, where the background is not left out under a screen that is not opaque.
    for previous in [nil, ScreenLayer(trackID: trackID, sourceTime: base, rect: rect, cornerRadius: 12)] {
        frame.previousScreen = previous
        frame.subframes = []
        let direct = try draw(frame, drawer: drawer, screen: green, previous: blue)
        let expected = previous == nil ? SIMD4<Float>(0, 127.5, 127.5, 255) : SIMD4<Float>(127.5, 127.5, 0, 255)
        #expect(isClose(pixel(direct, width: outputSize.x, x: centre.x, y: centre.y), expected, tolerance: 1.5))
        frame.subframes = still
        let blurred = try draw(frame, drawer: drawer, screen: green, previous: blue)
        #expect(StageDrawing.largestDifference(blurred, direct) <= 1, "\(String(describing: previous))")
    }
    // At full opacity the screen hides what is under it, as before.
    frame.previousScreen = nil
    frame.subframes = []
    frame.screen?.opacity = 1
    #expect(isClose(pixel(try draw(frame, drawer: drawer, screen: green, previous: nil), width: outputSize.x, x: centre.x, y: centre.y),
                    SIMD4(0, 255, 0, 255), tolerance: 0))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func anAreaNeverShowsWhatIsOutsideItDuringATransition() throws {
    // Display 1 recorded in Area mode, 4:3 inside its 16:9: green inside the area, red outside it. Display 2 all green, the
    // background blue: no red may show anywhere, with or without mipmaps, while one fills the other's rect.
    let area = Rect(x: 100, y: 50, width: 320, height: 240)
    let take = twoDisplays(area: area)
    let drawer = try StageDrawing.Drawer()
    let areaFrame = try solidTexture(
        device: drawer.device, width: 640, height: 360, inside: SIMD4(0, 255, 0, 255), outside: SIMD4(0, 0, 255, 255),
        area: (100..<420, 50..<290))
    let green = try solidTexture(device: drawer.device, width: 480, height: 480, inside: SIMD4(0, 255, 0, 255))
    let wider = Rect(x: 0, y: 0, width: 960, height: 480)
    let events = [InputEvent(t: base.adding(seconds: 4), kind: .displayGeometry(displayID: 2, frame: wider, scale: 1))]
    for sampling in [ScreenSampling.mipmapped, .bilinear] {
        var doc = document(take, events, initial: display2ID, changes: [(1, trackID), (3, display2ID)], transition: .spring)
        doc.style.screenSampling = sampling
        doc.style.background = .color(RGBA(0, 0, 1, 1))
        let evaluator = FrameEvaluator(take: take, events: events, document: doc, outputSize: [960, 540])
        for t in [1, 1.05, 1.1, 1.2, 1.4, 3.05, 3.2] {
            let frame = evaluator.frame(at: t)
            // Display 1 is the screen coming at 1 s and the one going away at 3 s.
            let display1Layer = frame.screen?.trackID == trackID ? frame.screen : frame.previousScreen
            let layer = try #require(display1Layer, "at \(t) s")
            #expect(layer.crop.x >= 100.0 / 640 && layer.crop.x + layer.crop.width <= 420.0 / 640 + 1e-12, "at \(t) s")
            #expect(layer.crop.y >= 50.0 / 360 && layer.crop.y + layer.crop.height <= 290.0 / 360 + 1e-12, "at \(t) s")
            let (screen, previous) = frame.screen?.trackID == trackID ? (areaFrame, green) : (green, areaFrame)
            let bytes = try draw(frame, drawer: drawer, screen: screen, previous: previous)
            let red = stride(from: 2, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0
            #expect(red == 0, "\(sampling) at \(t) s: red \(red)")
        }
        // A geometry spring of display 2 (to 2:1 at 4 s) fills its rect too, cut at its sides.
        let frame = evaluator.frame(at: 4.1)
        let layer = try #require(frame.screen)
        #expect(frame.previousScreen == nil && layer.crop.width < 1 && layer.crop.height == 1)
        let bytes = try draw(frame, drawer: drawer, screen: green, previous: nil)
        #expect(stride(from: 2, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 })
    }
}
