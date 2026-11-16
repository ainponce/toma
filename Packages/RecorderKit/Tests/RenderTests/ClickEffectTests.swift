// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Testing

// The click effects (design §7.5): `ripple-1` and `circle-1` at each kept click inside what is shown of the screen, in
// stage coordinates like the cursor, drawn over it and never blurred (plan decision 26).

private let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(1280, 720)
private let white = RGBA(1, 1, 1, 1)

/// Output second `seconds` in nanoseconds.
private func at(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// `ClickEffects.layers` at output second `t`, for clicks at output seconds `clicks` released at output seconds
/// `releases`, each placed at `center` with a cursor `cursorHeight` tall (or as `place` says, by index).
private func layers(
    at t: Double, clicks: [Double] = [1], releases: [Double] = [], effect: String, center: SIMD2<Double> = [100, 80],
    cursorHeight: Double = 40, place: ((Int) -> (center: SIMD2<Double>, cursorHeight: Double)?)? = nil
) -> [ClickEffectLayer] {
    ClickEffects.layers(atOutput: at(t), clicks: clicks.map(at), releases: releases.map(at), effect: effect) { index in
        place.map { $0(index) } ?? (center, cursorHeight)
    }
}

private func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

private func event(_ seconds: Double, _ kind: InputEvent.Kind) -> InputEvent {
    InputEvent(t: base.adding(seconds: seconds), kind: kind)
}

/// A take of `seconds` on display 1 (`screenFrame`, or `globalFrame` with `captureArea`), without files.
private func bareTake(seconds: Double = 3, globalFrame: Rect = screenFrame, captureArea: Rect? = nil) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(
            globalFrame: globalFrame, captureArea: captureArea, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
    ])
}

/// The legacy document of `take` with the click effect `effect`.
private func document(_ take: TakeRecord, _ events: [InputEvent], effect: String) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    document.cursor.clickEffect = effect
    return document
}

/// Every frame at 60 fps of `document`'s output, as `FrameEvaluator` works them out.
private func everyFrame(_ take: TakeRecord, _ events: [InputEvent], _ document: EditDocument) -> [RenderFrame] {
    let evaluator = FrameEvaluator(take: take, events: events, document: document, outputSize: size)
    return (0..<evaluator.timeMap.frameCount(frameRate: 60)).map { n in
        evaluator.frame(at: Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9)
    }
}

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// opens its files, which blocks (`offThePool` in DocumentRenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// `frame` drawn by a compositor of the default device without a screen or a camera, as BGRA bytes: its cursor with
/// the texture `cursor` makes, Toma's arrow without one.
private func composite(_ frame: RenderFrame, cursor: ((any MTLDevice) throws -> any MTLTexture)? = nil) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: frame.outputSize.x, height: frame.outputSize.y, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: descriptor))
    let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    let texture = try cursor?(device) ?? CursorSprite.makeTexture(device: device)
    try compositor.encode(frame, screen: nil, camera: nil, cursor: texture, into: target, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)
    var bytes = [UInt8](repeating: 0, count: frame.outputSize.x * frame.outputSize.y * 4)
    target.getBytes(
        &bytes, bytesPerRow: frame.outputSize.x * 4, from: MTLRegionMake2D(0, 0, frame.outputSize.x, frame.outputSize.y),
        mipmapLevel: 0)
    return bytes
}

@Test func rippleRadiusAndOpacityFollowTheCurve() throws {
    // τ 0.25 s, h 40: radius 40 × (0.25 + 1.35 × easeOutCubic(0.5)), 0.08 × 40 thick, 0.55 × (1 − 0.5)².
    let ripple = try #require(layers(at: 1.25, effect: "ripple-1").first)
    #expect(layers(at: 1.25, effect: "ripple-1").count == 1)
    #expect(ripple.kind == .ripple && ripple.center == [100, 80])
    #expect(isClose(ripple.radius, 57.25), "\(ripple.radius)")
    #expect(isClose(ripple.thickness, 3.2) && isClose(ripple.opacity, 0.1375), "\(ripple)")
    // At the click itself: a quarter of h, at 0.55.
    let start = try #require(layers(at: 1, effect: "ripple-1").first)
    #expect(isClose(start.radius, 10) && isClose(start.opacity, 0.55), "\(start)")
    // Centred where `place` puts the click; none where it has no place.
    #expect(layers(at: 1.25, effect: "ripple-1", center: [200, 160]).first?.center == [200, 160])
    #expect(layers(at: 1.25, effect: "ripple-1") { _ in nil }.isEmpty)
    // Two clicks: two rings, in click order.
    let two = layers(at: 1.25, clicks: [1, 1.2], effect: "ripple-1")
    #expect(two.count == 2 && isClose(two[0].radius, 57.25) && two[1].radius < two[0].radius)
}

@Test func rippleEndsAfterHalfASecond() {
    #expect(layers(at: 1.5, effect: "ripple-1").isEmpty)
    #expect(layers(at: 3, effect: "ripple-1").isEmpty)
    // A nanosecond before, nearly gone; nothing before the click.
    let last = ClickEffects.layers(atOutput: at(1.5) - 1, clicks: [at(1)], releases: [], effect: "ripple-1") { _ in
        ([100, 80], 40)
    }
    #expect(last.count == 1 && last[0].opacity < 1e-15)
    let before = ClickEffects.layers(atOutput: at(1) - 1, clicks: [at(1)], releases: [], effect: "ripple-1") { _ in
        ([100, 80], 40)
    }
    #expect(before.isEmpty)
}

@Test func circleScalesInAndOut() throws {
    // Pressed 0.06 s ago: scaled halfway from 0.6 to 1.
    let pressed = try #require(layers(at: 1.06, releases: [1.5], effect: "circle-1").first)
    #expect(pressed.kind == .circle && pressed.center == [100, 80] && pressed.thickness == 0)
    #expect(isClose(pressed.radius, 0.9 * 40 * 0.8) && isClose(pressed.opacity, 0.22), "\(pressed)")
    // Past 0.12 s, whole until the release.
    let whole = try #require(layers(at: 1.4, releases: [1.5], effect: "circle-1").first)
    #expect(isClose(whole.radius, 36) && isClose(whole.opacity, 0.22), "\(whole)")
    // Released 0.10 s ago: halfway out.
    let released = try #require(layers(at: 1.6, releases: [1.5], effect: "circle-1").first)
    #expect(isClose(released.radius, 36) && isClose(released.opacity, 0.11), "\(released)")
    // Out 0.20 s after the release; never released, the last click's stays.
    #expect(layers(at: 1.7, releases: [1.5], effect: "circle-1").isEmpty)
    #expect(layers(at: 100, effect: "circle-1").first.map { isClose($0.opacity, 0.22) } == true)
    // A release before the click is not its own.
    #expect(layers(at: 2, releases: [0.5], effect: "circle-1").count == 1)
    // A quick click still enters scaling: released at 0.05 s, 0.02 s later.
    let quick = try #require(layers(at: 1.07, releases: [1.05], effect: "circle-1").first)
    #expect(isClose(quick.radius, 0.9 * 40 * (0.6 + 0.4 * 0.07 / 0.12)) && isClose(quick.opacity, 0.22 * 0.9), "\(quick)")
    // Nothing for no effect, an id this version does not know, or a cursor of no size.
    for effect in ["none", "ripple-2", "circle", ""] {
        #expect([1.0, 1.06, 1.25, 1.6].allSatisfy { layers(at: $0, releases: [1.5], effect: effect).isEmpty }, "\(effect)")
    }
    #expect(layers(at: 1.06, effect: "circle-1", cursorHeight: 0).isEmpty)
    #expect(layers(at: 1.06, effect: "ripple-1", cursorHeight: .nan).isEmpty)
}

@Test func clicksInACutHaveNoEffect() {
    let take = bareTake()
    // One click inside the cut second, and one 0.1 s before the next clip starts: both released inside it too.
    let events = [
        event(0, .cursor(x: 320, y: 180)),
        event(1.5, .mouseDown(.left, x: 320, y: 180)), event(1.55, .mouseUp(.left, x: 320, y: 180)),
        event(1.9, .mouseDown(.left, x: 330, y: 190)), event(1.95, .mouseUp(.left, x: 330, y: 190)),
    ]
    for effect in ["ripple-1", "circle-1"] {
        var cut = document(take, events, effect: effect)
        cut.sequence = [
            Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
            Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
        ]
        let frames = everyFrame(take, events, cut)
        #expect(frames.count == 120)
        #expect(frames.allSatisfy { $0.clickEffects.isEmpty }, "\(effect)")
        // Without the cut, the same clicks have their effects.
        #expect(everyFrame(take, events, document(take, events, effect: effect)).contains { !$0.clickEffects.isEmpty }, "\(effect)")
    }
}

@Test func clicksOutsideTheShownScreenHaveNoEffect() {
    let display = Rect(x: 0, y: 0, width: 1512, height: 982)
    let area = Rect(x: 100, y: 100, width: 800, height: 450)
    let take = bareTake(globalFrame: display, captureArea: area)
    func events(clickingAt point: SIMD2<Double>) -> [InputEvent] {
        [
            event(0, .cursor(x: 500, y: 325)),
            event(1, .mouseDown(.left, x: point.x, y: point.y)), event(1.05, .mouseUp(.left, x: point.x, y: point.y)),
        ]
    }
    // On the display, outside the area: `place` has nowhere to put it, from the click to 0.5 s after it.
    let outside = events(clickingAt: [1200, 800])
    for effect in ["ripple-1", "circle-1"] {
        let evaluator = FrameEvaluator(take: take, events: outside, document: document(take, outside, effect: effect), outputSize: size)
        #expect((60...90).allSatisfy { evaluator.frame(at: Double($0) / 60).clickEffects.isEmpty }, "\(effect)")
    }
    // Inside the area, the same click has its ripple.
    let inside = events(clickingAt: [500, 300])
    let evaluator = FrameEvaluator(take: take, events: inside, document: document(take, inside, effect: "ripple-1"), outputSize: size)
    #expect((60..<90).allSatisfy { evaluator.frame(at: Double($0) / 60).clickEffects.count == 1 })
    #expect(evaluator.frame(at: 1.5).clickEffects.isEmpty)
}

@Test func effectsArePlacedLikeTheCursorAtTheClick() throws {
    let take = bareTake()
    let events = [
        event(0, .cursor(x: 320, y: 180)),
        event(0.5, .mouseDown(.left, x: 400, y: 200)), event(0.6, .mouseUp(.left, x: 400, y: 200)),
    ]
    var ripple = document(take, events, effect: "ripple-1")
    let evaluator = FrameEvaluator(take: take, events: events, document: ripple, outputSize: size)
    let cursor = try #require(evaluator.frame(at: 0.5).cursor)
    // 0.1 s after the click: centred where the cursor was on it, of its height.
    let effect = try #require(evaluator.frame(at: 0.6).clickEffects.first)
    #expect(effect.center == cursor.hotspot)
    let progress = 0.1 / 0.5, eased = 1 - pow(1 - progress, 3)
    #expect(isClose(effect.radius, cursor.height * (0.25 + 1.35 * eased)) && isClose(effect.thickness, 0.08 * cursor.height))
    #expect(evaluator.frame(at: 0.4).clickEffects.isEmpty && evaluator.frame(at: 1).clickEffects.isEmpty)
    // The legacy document has none; nor does a hidden cursor, whose height they are measured by.
    #expect(everyFrame(take, events, .legacy(take: take, events: events)).allSatisfy { $0.clickEffects.isEmpty })
    ripple.cursor.show = false
    #expect(everyFrame(take, events, ripple).allSatisfy { $0.clickEffects.isEmpty })
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func effectsAreDrawnAsARingAndADisc() throws {
    let black = SIMD4<Float>(0, 0, 0, 1)
    func frame(_ effects: [ClickEffectLayer]) -> RenderFrame {
        RenderFrame(
            outputSize: [200, 160], gradientStart: black, gradientEnd: black, gradientAngleDegrees: 0, clickEffects: effects)
    }
    let background = try composite(frame([]))
    #expect(pixel(background, width: 200, x: 100, y: 80) == [0, 0, 0, 255])
    // A disc of 30 px at 22 %: 0.22 of white over the black inside it, nothing outside it.
    let disc = try composite(frame([ClickEffectLayer(kind: .circle, center: [100, 80], radius: 30, thickness: 0, opacity: 0.22)]))
    #expect(isClose(pixel(disc, width: 200, x: 100, y: 80), [56.1, 56.1, 56.1, 255], tolerance: 1))
    #expect(isClose(pixel(disc, width: 200, x: 120, y: 80), [56.1, 56.1, 56.1, 255], tolerance: 1))
    #expect(pixel(disc, width: 200, x: 133, y: 80) == [0, 0, 0, 255])
    // A ring 30 px out and 6 px across at full opacity: white on its circle, hollow inside, black beyond its outline.
    let ring = try composite(frame([ClickEffectLayer(kind: .ripple, center: [100, 80], radius: 30, thickness: 6, opacity: 1)]))
    #expect(pixel(ring, width: 200, x: 129, y: 80) == [255, 255, 255, 255])
    #expect(pixel(ring, width: 200, x: 70, y: 80) == [255, 255, 255, 255])
    #expect(pixel(ring, width: 200, x: 100, y: 80) == [0, 0, 0, 255])
    #expect(pixel(ring, width: 200, x: 140, y: 80) == [0, 0, 0, 255])
    // Not shown, or of no size: nothing.
    let hidden = ClickEffectLayer(kind: .ripple, center: [100, 80], radius: 30, thickness: 6, opacity: 0)
    let flat = ClickEffectLayer(kind: .circle, center: [100, 80], radius: 0, thickness: 0, opacity: 0.22)
    #expect(try composite(frame([hidden, flat])) == background)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func rippleIsVisibleOnWhite() async throws {
    try await withTemporaryDirectory { dir in
        // A take whose video file is missing: over the white background, the cursor and the ripple are all there is.
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: trackID, source: displaySource(globalFrame: screenFrame), segments: [])
        try builder.addEmptySegment(
            track: trackID, index: 1, start: base, end: base.adding(seconds: 1), endReason: .stopped, file: .absent)
        try builder.addEvents([
            event(0, .cursor(x: 320, y: 180)),
            event(0.2, .mouseDown(.left, x: 320, y: 180)), event(0.25, .mouseUp(.left, x: 320, y: 180)),
        ])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.style.background = .color(white)
        document.cursor.clickEffect = "ripple-1"
        // 0.05 s after the click.
        let frame = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size).frame(at: 0.25)
        let ripple = try #require(frame.clickEffects.first)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let bytes = try await offThePool { try renderer.renderBytes(at: 0.25) }
        // Along the row through its centre, left of it (the arrow is to the right of its tip): its white is lost on
        // the white, its outline is not.
        let y = Int(ripple.center.y)
        let ringLeft = ripple.center.x - ripple.radius
        let reach = ripple.thickness / 2 + 3
        let darkest = (Int(ringLeft - reach)...Int(ringLeft + reach)).map { x in
            let p = pixel(bytes, width: size.x, x: x, y: y)
            return min(p.x, p.y, p.z)
        }.min()
        #expect(try #require(darkest) < 240, "\(String(describing: darkest))")
        // Around it, the white background.
        #expect(pixel(bytes, width: size.x, x: Int(ringLeft - reach - 4), y: y) == [255, 255, 255, 255])
        // Without the effect, nothing darker there.
        document.cursor.clickEffect = "none"
        let plain = try FrameRenderer(project: project, document: document, outputSize: size)
        let none = try await offThePool { try plain.renderBytes(at: 0.25) }
        #expect((Int(ringLeft - reach)...Int(ringLeft + reach)).allSatisfy {
            pixel(none, width: size.x, x: $0, y: y) == [255, 255, 255, 255]
        })
    }
}

@Test func aLostReleaseEndsTheCircleAtTheNextClick() throws {
    // Three clicks whose releases the events lost: each circle's press ends at the next click, and fades from there.
    let clicks = [1.0, 2.0, 3.0]
    let between = layers(at: 2.1, clicks: clicks, effect: "circle-1")
    #expect(between.count == 2 && isClose(between[0].opacity, 0.11) && isClose(between[1].opacity, 0.22), "\(between)")
    #expect(layers(at: 2.5, clicks: clicks, effect: "circle-1").count == 1)
    // Never more than the last one held to the end.
    let late = try #require(layers(at: 100, clicks: clicks, effect: "circle-1").first)
    #expect(layers(at: 100, clicks: clicks, effect: "circle-1").count == 1 && isClose(late.opacity, 0.22))
    // Only the clicks under way are placed.
    var placed: [Int] = []
    _ = layers(at: 100, clicks: Array(stride(from: 1.0, through: 50, by: 1)), effect: "circle-1") { index in
        placed.append(index)
        return ([100, 80], 40)
    }
    #expect(placed == [49])
    // A release that comes first still ends it.
    #expect(isClose(try #require(layers(at: 1.6, clicks: clicks, releases: [1.5], effect: "circle-1").first).opacity, 0.11))
}

@Test func releasesAreWhenNoButtonIsDown() {
    let take = bareTake()
    let events = [
        event(0, .cursor(x: 320, y: 180)),
        // Left, then right with left still down: released once both are up.
        event(0.5, .mouseDown(.left, x: 320, y: 180)), event(0.6, .mouseDown(.right, x: 320, y: 180)),
        event(0.7, .mouseUp(.left, x: 320, y: 180)), event(0.8, .mouseUp(.right, x: 320, y: 180)),
        // Released in the cut: from the next clip on, as the cursor's press.
        event(0.9, .mouseDown(.left, x: 320, y: 180)), event(1.5, .mouseUp(.left, x: 320, y: 180)),
    ]
    var cut = EditDocument.legacy(take: take, events: events)
    cut.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
    ]
    #expect(MotionPaths(take: take, events: events, document: cut).cursor.releases == [at(0.8), at(1)])
}

@Test func aCursorImageChangeKeepsTheEffectsSize() throws {
    let take = bareTake()
    func image(_ t: Double, hash: String, height: Double) -> InputEvent {
        event(t, .cursorImage(hash: hash, hotspot: [0.5, 0.5], size: [24, height], kind: nil))
    }
    // In the recorded shapes (macOS style), 32 pt tall at the click and 16 pt from 0.1 s after it.
    let events = [
        event(0, .cursor(x: 320, y: 180)), image(0, hash: "00112233445566778899aabbccddeeff", height: 32),
        event(0.5, .mouseDown(.left, x: 320, y: 180)), event(0.55, .mouseUp(.left, x: 320, y: 180)),
        image(0.6, hash: "ffeeddccbbaa99887766554433221100", height: 16),
    ]
    for effect in ["ripple-1", "circle-1"] {
        var system = document(take, events, effect: effect)
        system.cursor.style = .system
        let evaluator = FrameEvaluator(take: take, events: events, document: system, outputSize: size)
        let atClick = try #require(evaluator.frame(at: 0.5).cursor).height
        let after = evaluator.frame(at: 0.65)
        #expect(isClose(try #require(after.cursor).height, atClick / 2))
        let layer = try #require(after.clickEffects.first)
        if effect == "ripple-1" {
            let eased = 1 - pow(1 - 0.15 / 0.5, 3)
            #expect(isClose(layer.radius, atClick * (0.25 + 1.35 * eased)) && isClose(layer.thickness, 0.08 * atClick))
        } else {
            #expect(isClose(layer.radius, 0.9 * atClick), "\(layer)")
        }
    }
}

@Test func aMovingWindowKeepsTheEffectOnTheClickedPoint() throws {
    let window = "window-7"
    let take = makeTake(tracks: [
        displayTrack(
            id: window, kind: .window, globalFrame: Rect(x: 100, y: 100, width: 800, height: 600),
            segments: [segment(track: window, start: base, end: base.adding(seconds: 3))]),
    ])
    // A drag of the window by its title bar: held from 0.5 s to 1.5 s, the window 200 pt to the right from 0.7 s.
    let events = [
        event(0, .cursor(x: 300, y: 120)), event(0.5, .mouseDown(.left, x: 300, y: 120)),
        event(0.7, .windowGeometry(track: window, frame: Rect(x: 300, y: 100, width: 800, height: 600), onScreen: true)),
        event(0.7, .cursor(x: 500, y: 120)), event(1.5, .mouseUp(.left, x: 500, y: 120)),
    ]
    for effect in ["circle-1", "ripple-1"] {
        let evaluator = FrameEvaluator(
            take: take, events: events, document: document(take, events, effect: effect), outputSize: size)
        let clicked = try #require(evaluator.frame(at: 0.5).cursor).hotspot
        // The window holds the same rect on the stage: the clicked point is where it was, under the dragged cursor.
        #expect(evaluator.frame(at: 0.9).screen?.rect == evaluator.frame(at: 0.5).screen?.rect)
        #expect(evaluator.frame(at: 0.9).cursor?.hotspot == clicked)
        let times = effect == "circle-1" ? [0.9, 1.2, 1.6] : [0.75, 0.9]
        for t in times {
            #expect(evaluator.frame(at: t).clickEffects.map(\.center) == [clicked], "\(effect) at \(t)")
        }
    }
    // While the window is off screen, nothing; back on screen, the effect where it was.
    let hidden = events + [
        event(1.0, .windowGeometry(track: window, frame: Rect(x: 300, y: 100, width: 800, height: 600), onScreen: false)),
        event(1.1, .windowGeometry(track: window, frame: Rect(x: 300, y: 100, width: 800, height: 600), onScreen: true)),
    ]
    let evaluator = FrameEvaluator(
        take: take, events: hidden, document: document(take, hidden, effect: "circle-1"), outputSize: size)
    #expect(evaluator.frame(at: 1.05).clickEffects.isEmpty)
    #expect(evaluator.frame(at: 1.2).clickEffects.map(\.center) == evaluator.frame(at: 0.9).clickEffects.map(\.center))
}

@Test func aRippleAcrossACutPlaysOnInTheNextClip() throws {
    let take = bareTake()
    // 0.2 s before the cut [1, 2) s.
    let events = [
        event(0, .cursor(x: 320, y: 180)),
        event(0.8, .mouseDown(.left, x: 400, y: 200)), event(0.85, .mouseUp(.left, x: 400, y: 200)),
    ]
    var cut = document(take, events, effect: "ripple-1")
    cut.sequence = [
        Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 1), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: base.adding(seconds: 2), end: base.adding(seconds: 3), speed: 1),
    ]
    let evaluator = FrameEvaluator(take: take, events: events, document: cut, outputSize: size)
    let cursor = try #require(evaluator.frame(at: 0.8).cursor)
    // Its 0.5 s are of output: it goes on past the cut into the next clip, where it was, as the cursor's spring does.
    for t in [0.9, 1.1, 1.25] {
        let ripple = try #require(evaluator.frame(at: t).clickEffects.first, "\(t)")
        let eased = 1 - pow(1 - (t - 0.8) / 0.5, 3)
        #expect(ripple.center == cursor.hotspot && isClose(ripple.radius, cursor.height * (0.25 + 1.35 * eased)), "\(t)")
    }
    #expect(evaluator.frame(at: 1.3).clickEffects.isEmpty)
}

@Test func aClickInAFasterClipLastsHalfASecondOfOutput() throws {
    let take = bareTake()
    // At 2×, the click at 1 s of the source is at 0.5 s of the output.
    let events = [
        event(0, .cursor(x: 320, y: 180)),
        event(1, .mouseDown(.left, x: 400, y: 200)), event(1.05, .mouseUp(.left, x: 400, y: 200)),
    ]
    var fast = document(take, events, effect: "ripple-1")
    fast.sequence = [Clip(id: "c-00000001", take: takeID, start: base, end: base.adding(seconds: 3), speed: 2)]
    let evaluator = FrameEvaluator(take: take, events: events, document: fast, outputSize: size)
    let h = try #require(evaluator.frame(at: 0.5).cursor).height
    let ripple = try #require(evaluator.frame(at: 0.75).clickEffects.first)
    #expect(isClose(ripple.radius, h * 1.43125) && isClose(ripple.opacity, 0.1375), "\(ripple)")
    #expect(evaluator.frame(at: 0.99).clickEffects.count == 1)
    #expect(evaluator.frame(at: 1).clickEffects.isEmpty && evaluator.frame(at: 0.49).clickEffects.isEmpty)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func effectsAreDrawnOverTheCursor() throws {
    let black = SIMD4<Float>(0, 0, 0, 1)
    // A red cursor 32 × 64 around (100, 80), and a 22 % disc over it.
    let cursor = CursorLayer(
        hotspot: [100, 80], height: 64, image: .recorded(hash: "00112233445566778899aabbccddeeff"), hotspotFraction: [0.5, 0.5],
        aspect: 0.5)
    let frame = RenderFrame(
        outputSize: [200, 160], gradientStart: black, gradientEnd: black, gradientAngleDegrees: 0, cursor: cursor,
        clickEffects: [ClickEffectLayer(kind: .circle, center: [100, 80], radius: 30, thickness: 0, opacity: 0.22)])
    let bytes = try composite(frame) { device in
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let red = [UInt8]((0..<64).flatMap { _ in [0, 0, 255, 255] as [UInt8] })
        texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: red, bytesPerRow: 32)
        return texture
    }
    // The white over the red: 0.22 of white plus 0.78 of the red under it.
    #expect(isClose(pixel(bytes, width: 200, x: 100, y: 80), [56.1, 56.1, 255, 255], tolerance: 1))
}
