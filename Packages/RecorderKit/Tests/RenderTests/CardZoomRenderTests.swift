// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Metal
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)` and `forcedPath`, `StageTransform.outputRect`, `DrawCounts` and the
// compositor's counting `encode`.
@testable import Render
import simd
import Testing

// The zoom inside the screen's card (1c design §5.4 and §14.2): in a split the background stays still and the zoom acts
// inside the screen's card, cut to it with its corners, along the card's own path (`MotionPaths.cardZoom`); between the
// stage and a card, the background's transform, the content's and the cut blend by the layouts' `p`. Over a take on a
// display of 640 × 360 pt with a camera, without files, drawn by a compositor over `StageDrawing`'s smooth screen texture
// (the camera is not drawn): what a pixel shows says where on the screen it is.

private let display = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(1280, 720)

private func at(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

/// A take of `seconds` on display 1 with a camera, without files.
private func cardTake(seconds: Double = 6) -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: display, segments: [segment(start: base, end: base.adding(seconds: seconds))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, start: base, end: base.adding(seconds: seconds))]),
    ])
}

/// The legacy document of `take` with `events` on a gradient across the output, the camera shown, the project's layout
/// `layout`, the layout `blocks` and the zoom `regions`, with the camera's shutter `zoomBlur` and no cursor blur; with a
/// macOS window frame when `framed`.
private func document(
    _ take: TakeRecord, events: [InputEvent] = [], layout: LayoutKind = .split, blocks: [LayoutBlock] = [],
    regions: [ZoomRegion] = [], zoomBlur: Double = 0, framed: Bool = false
) -> EditDocument {
    var document = EditDocument.legacy(take: take, events: events)
    if framed { document.style.frame = .macWindow(appearance: .light, title: "Toma", buttons: true) }
    document.style.background = .gradient(start: RGBA(0.9, 0.2, 0.1, 1), end: RGBA(0.1, 0.3, 0.9, 1), angle: 30)
    document.camera.show = true
    document.camera.layout = CameraLayout(kind: layout)
    document.camera.layouts = blocks
    document.zoom.regions = regions
    document.zoom.motionBlur = zoomBlur
    document.cursor.motionBlur = 0
    return document
}

/// A split block over source seconds `[from, to)` of the take.
private func splitBlock(from: Double, to: Double) -> LayoutBlock {
    LayoutBlock(
        id: "l-00000001", take: takeID, start: base.adding(seconds: from), end: base.adding(seconds: to), kind: .split,
        instant: false, split: SplitLayout())
}

private func evaluator(_ take: TakeRecord, _ document: EditDocument, events: [InputEvent] = []) -> FrameEvaluator {
    FrameEvaluator(take: take, events: events, document: document, outputSize: size)
}

/// Whether pixel (`x`, `y`) touches `rect` (output pixels).
private func touches(_ x: Int, _ y: Int, _ rect: Rect) -> Bool {
    let left = Double(x), top = Double(y)
    return left + 1 > rect.x && left < rect.x + rect.width && top + 1 > rect.y && top < rect.y + rect.height
}

/// Whether pixel (`x`, `y`) is wholly inside `rect` inset by `inset` pixels on every side.
private func isInside(_ x: Int, _ y: Int, _ rect: Rect, inset: Double) -> Bool {
    let left = Double(x), top = Double(y)
    return left >= rect.x + inset && left + 1 <= rect.x + rect.width - inset && top >= rect.y + inset
        && top + 1 <= rect.y + rect.height - inset
}

/// The pixels where two images of `size` differ.
private func differing(_ a: [UInt8], _ b: [UInt8]) -> [(x: Int, y: Int)] {
    (0..<(size.x * size.y)).compactMap { i in
        a[4 * i..<4 * i + 4] == b[4 * i..<4 * i + 4] ? nil : (i % size.x, i / size.x)
    }
}

/// Whether two images of `size` have the same bytes at every pixel that does not touch `rect`.
private func sameOutside(_ a: [UInt8], _ b: [UInt8], _ rect: Rect) -> Bool {
    differing(a, b).allSatisfy { touches($0.x, $0.y, rect) }
}

/// Where the card's camera `state` draws the content's points, worked out here: the point at `state.center` of
/// `content` at its middle, `z` times as large.
private func cardPoint(_ p: SIMD2<Double>, _ state: CardZoomState, content: Rect) -> SIMD2<Double> {
    let origin = SIMD2(content.x, content.y), extent = SIMD2(content.width, content.height)
    return (p - (origin + state.center * extent)) * state.depth + origin + extent / 2
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func splitZoomStaysInsideTheScreenCard() throws {
    let take = cardTake()
    // The cursor at (0.6, 0.5) of the screen, off the crop at (0.3, 0.3): the zoom draws it past the card's right edge,
    // still in the output.
    let events = [StageDrawing.event(0, .cursor(x: 384, y: 180))]
    let zoom = [StageDrawing.zoom(1, from: 0, to: 6, depth: 2, focus: .fixed(x: 0.3, y: 0.3), instant: true)]
    let frame = evaluator(take, document(take, events: events, regions: zoom), events: events).frame(at: 2)
    let card = try #require(frame.card)
    let screen = try #require(frame.screen)
    let cursor = try #require(frame.cursor)
    // The background still, the zoom in the card, cut to the screen's rect.
    #expect(frame.backgroundTransform == .identity(outputSize: size) && frame.stage == nil)
    #expect(card.content.depth == 2 && card.mix == 1)
    #expect(card.rect == screen.rect && card.cornerRadius == screen.cornerRadius)
    // The point in focus at the card's middle.
    let focus = SIMD2(screen.rect.x, screen.rect.y) + SIMD2(0.3, 0.3) * SIMD2(screen.rect.width, screen.rect.height)
    let middle = SIMD2(card.rect.x + card.rect.width / 2, card.rect.y + card.rect.height / 2)
    #expect(simd_length(card.content.outputPoint(ofStage: focus, outputSize: size) - middle) < 1e-9)
    let drawnCursor = card.content.outputPoint(ofStage: cursor.hotspot, outputSize: size)
    #expect(drawnCursor.x > card.rect.x + card.rect.width && drawnCursor.x < Double(size.x) - 40)
    #expect(drawnCursor.y > card.rect.y && drawnCursor.y < card.rect.y + card.rect.height)

    let drawer = try StageDrawing.Drawer()
    let drawn = try drawer.draw(frame)
    var bare = frame
    (bare.screen, bare.cursor) = (nil, nil)
    let background = try drawer.draw(bare)
    // Nothing of the screen nor of the cursor outside the card, and all of the card inside its corners covered.
    let changed = differing(drawn, background)
    #expect(changed.allSatisfy { touches($0.x, $0.y, card.rect) })
    let inset = card.cornerRadius + 1
    let inside = (0..<size.y).flatMap { y in (0..<size.x).filter { isInside($0, y, card.rect, inset: inset) }.map { ($0, y) } }
    let covered = Set(changed.map { $0.y * size.x + $0.x })
    #expect(inside.allSatisfy { covered.contains($0.1 * size.x + $0.0) })
    // At the card's middle, the screen's point (0.3, 0.3): texel (192, 108) of the smooth texture.
    let red = 255 * 192 / 639, green = 255 * 108 / 359
    let expected = SIMD4<Float>(Float(255 - red / 2 - green / 2), Float(green), Float(red), 255)
    let centre = pixel(drawn, width: size.x, x: Int(middle.x), y: Int(middle.y))
    #expect(isClose(centre, expected, tolerance: 3), "\(centre) \(expected)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func backgroundStaysStillInCardMode() throws {
    let take = cardTake()
    // A zoom that moves from 1 s on, then holds, and none.
    let zoom = [StageDrawing.zoom(1, from: 1, to: 5, depth: 2.5, focus: .fixed(x: 0.7, y: 0.2))]
    let drawer = try StageDrawing.Drawer()
    for framed in [false, true] {
        let zoomed = evaluator(take, document(take, regions: zoom, framed: framed))
        let still = evaluator(take, document(take, framed: framed))
        for t in [0.5, 1.2, 1.6, 3.0] {
            let a = zoomed.frame(at: t), b = still.frame(at: t)
            #expect(a.backgroundTransform == .identity(outputSize: size) && b.backgroundTransform == .identity(outputSize: size))
            let card = try #require(a.card?.rect)
            #expect(card == b.card?.rect && (a.windowFrame != nil) == framed && a.windowFrame == b.windowFrame)
            #expect(t < 1 || a.card!.content.depth > 1, "\(t)")
            // The background, and the window's bar over the screen, the same bytes with the zoom and without it.
            #expect(sameOutside(try drawer.draw(a), try drawer.draw(b), card), "\(t), framed \(framed)")
        }
    }
    // Over the whole stage, as in the Bubble, the zoom moves the background: the test sees it.
    let bubble = evaluator(take, document(take, layout: .bubble, regions: zoom)).frame(at: 3)
    let flat = evaluator(take, document(take, layout: .bubble)).frame(at: 3)
    let screen = try #require(flat.screen?.rect)
    #expect(bubble.card == nil && bubble.backgroundTransform == nil && bubble.stage != nil)
    #expect(!sameOutside(try drawer.draw(bubble), try drawer.draw(flat), screen))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func cursorScalesWithTheCardContent() throws {
    let take = cardTake()
    // The cursor still at the display's centre, a 2× zoom on it, and no zoom.
    let events = [StageDrawing.event(0, .cursor(x: 320, y: 180))]
    let zoom = [StageDrawing.zoom(1, from: 0, to: 6, depth: 2, focus: .fixed(x: 0.5, y: 0.5), instant: true)]
    let zoomed = evaluator(take, document(take, events: events, regions: zoom), events: events).frame(at: 2)
    let plain = evaluator(take, document(take, events: events), events: events).frame(at: 2)
    let a = try #require(zoomed.cursor), b = try #require(plain.cursor)
    let zoomedCard = try #require(zoomed.card), plainCard = try #require(plain.card)
    // The same cursor on the card, drawn twice as tall through the card's content, its hotspot where it was.
    #expect(a == b)
    #expect(plainCard.content == .identity(outputSize: size))
    let big = zoomedCard.content.drawn(a, outputSize: size), small = plainCard.content.drawn(b, outputSize: size)
    #expect(big.height == 2 * small.height)
    #expect(simd_length(big.hotspot - small.hotspot) < 1e-9)
    // Drawn: about four times as many pixels (its antialiased rim grows only twice as long, so a little less).
    let drawer = try StageDrawing.Drawer()
    func cursorPixels(_ frame: RenderFrame) throws -> Int {
        var without = frame
        without.cursor = nil
        return differing(try drawer.draw(frame), try drawer.draw(without)).count
    }
    let ratio = Double(try cursorPixels(zoomed)) / Double(try cursorPixels(plain))
    #expect(ratio > 3.2 && ratio < 4.2, "\(ratio)")
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurInTheCardUsesTheCardPath() throws {
    let take = cardTake()
    // The card's camera moving fast as it enters a block 2.5 deep, with the camera's shutter a whole frame.
    let regions = [StageDrawing.zoom(1, from: 0.5, to: 2.5, depth: 2.5, focus: .fixed(x: 0.25, y: 0.3))]
    let doc = document(take, regions: regions, zoomBlur: 1, framed: true)
    let scene = evaluator(take, doc)
    let frame = scene.frame(at: 0.7)
    let card = try #require(frame.card)
    let content = try #require(frame.screen?.rect)
    let count = frame.subframes.count
    #expect(count > 1 && frame.cursorSamples.isEmpty)
    #expect(frame.backgroundTransform == .identity(outputSize: size))
    // The window's title is made for the still bar, not for the zoom of the subsamples.
    #expect(frame.windowFrame != nil && frame.subframes.allSatisfy { $0.stage.depth > 1 } && TitleTexture.scale(for: frame) == 1)
    // Each subsample is the card's camera at its time, on the card's path: its depth, its focus at the card's middle.
    let path = try #require(scene.paths.cardZoom)
    let times = MotionBlurPlan.sampleTimes(
        at: at(0.7), shutter: 1, frameDuration: TimeMap.frameTime(1, frameRate: doc.frameRate), count: count,
        jumps: scene.paths.zoom.jumps)
    for (subframe, t) in zip(frame.subframes, times) {
        let state = path.state(atOutput: t)
        #expect(subframe.stage.depth == state.depth)
        for p in [SIMD2(content.x, content.y), SIMD2(content.x + content.width, content.y + content.height)] {
            let drawn = subframe.stage.outputPoint(ofStage: p, outputSize: size)
            #expect(simd_length(drawn - cardPoint(p, state, content: content)) < 1e-6)
        }
    }
    #expect(Set(frame.subframes.map(\.stage.center)).count == count)
    // Drawn: the background once, the same bytes as without the blur (N = 1); the card's content averaged.
    let drawer = try StageDrawing.Drawer()
    var counts = DrawCounts()
    let blurred = try drawer.draw(frame, counts: &counts)
    #expect(counts == DrawCounts(renderPasses: 1, backgrounds: 1, screens: count, accumulations: count), "\(counts)")
    var once = frame
    once.subframes = []
    let sharp = try drawer.draw(once)
    #expect(sameOutside(blurred, sharp, card.rect))
    #expect(StageDrawing.largestDifference(blurred, sharp) > 1)
    // N equal subsamples: the frame drawn once through that transform, within a level, but for two at the card's partly
    // covered edge, whose alpha the sum holds in half precision.
    var equal = frame
    equal.subframes = Array(repeating: StageSubframe(stage: card.content, cursor: frame.cursor), count: count)
    let averaged = try drawer.draw(equal)
    let off = differing(averaged, sharp).filter { p in
        let i = 4 * (p.y * size.x + p.x)
        let most = (0..<4).map { abs(Int(averaged[i + $0]) - Int(sharp[i + $0])) }.max()!
        let edge = touches(p.x, p.y, card.rect) && !isInside(p.x, p.y, card.rect, inset: 0)
        return most > (edge ? 2 : 1)
    }
    #expect(off.isEmpty, "\(off.prefix(5))")
    // The same bytes twice.
    #expect(try drawer.draw(frame) == blurred)
}

@Test func modeTransitionBlendsTheTransforms() throws {
    let take = cardTake()
    // A 2× zoom off the centre over the whole take, in the Bubble, then a split from 2 s.
    let zoom = [StageDrawing.zoom(1, from: 0, to: 6, depth: 2, focus: .fixed(x: 0.3, y: 0.3), instant: true)]
    let doc = document(take, layout: .bubble, blocks: [splitBlock(from: 2, to: 6)], regions: zoom)
    let scene = evaluator(take, doc)
    var legacy = evaluator(take, doc)
    legacy.forcedPath = .legacy
    let layouts = LayoutTimeline(document: doc, take: take, timeMap: scene.timeMap, cameraReadable: true)

    // Before the split, the stage's zoom over everything, as 1b's path draws it.
    let before = scene.frame(at: 1.5)
    #expect(before.card == nil && before.backgroundTransform == nil && before.stage == legacy.frame(at: 1.5).stage)
    // Settled in the split: the background still, the card's zoom inside the card.
    let after = scene.frame(at: 4)
    #expect(after.backgroundTransform == .identity(outputSize: size) && after.stage == nil && after.card?.content.depth == 2)

    // Half way: the first instant at which `p` reaches 0.5.
    var low = at(2), high = at(3)
    while high - low > 1 {
        let mid = (low + high) / 2
        if layouts.cardWeight(atOutput: mid) < 0.5 { low = mid } else { high = mid }
    }
    let seconds = Double(high) / 1e9, τ = TimeMap.outputNanoseconds(seconds: seconds)
    let p = layouts.cardWeight(atOutput: τ)
    #expect(abs(p - 0.5) < 1e-6, "\(p)")
    let frame = scene.frame(at: seconds)
    let stage = try #require(legacy.frame(at: seconds).stage)
    let background = try #require(frame.backgroundTransform)
    let card = try #require(frame.card)
    let content = try #require(frame.screen?.rect)
    let state = try #require(scene.paths.cardZoom).state(atOutput: τ)
    #expect(stage.depth == 2 && state.depth == 2 && card.mix == p)
    #expect(abs(background.depth - 1.5) < 1e-6 && abs(card.content.depth - 2) < 1e-9)
    // Every point where the zoom's transform and the identity draw it, mixed by `p`; the content's, where the stage's
    // zoom and the card's draw it; the cut, the screen as the background's transform draws it.
    let points = [SIMD2(0.0, 0), SIMD2(1280, 0), SIMD2(0, 720), SIMD2(1280, 720), SIMD2(400, 300), SIMD2(content.x, content.y)]
    for q in points {
        let mixed = stage.outputPoint(ofStage: q, outputSize: size) * (1 - p) + q * p
        #expect(simd_length(background.outputPoint(ofStage: q, outputSize: size) - mixed) < 1e-6, "\(q)")
        let blended = stage.outputPoint(ofStage: q, outputSize: size) * (1 - p) + cardPoint(q, state, content: content) * p
        #expect(simd_length(card.content.outputPoint(ofStage: q, outputSize: size) - blended) < 1e-6, "\(q)")
    }
    #expect(card.rect == background.outputRect(ofStage: content, outputSize: size))
    // Nothing jumps as the transition starts: just after the border, all of it as the stage's zoom draws it.
    let start = scene.frame(at: 2 + 1e-4)
    let first = try #require(start.card)
    let stageThen = try #require(legacy.frame(at: 2 + 1e-4).stage)
    for q in points {
        let drawn = stageThen.outputPoint(ofStage: q, outputSize: size)
        #expect(simd_length(try #require(start.backgroundTransform).outputPoint(ofStage: q, outputSize: size) - drawn) < 0.01)
        #expect(simd_length(first.content.outputPoint(ofStage: q, outputSize: size) - drawn) < 0.01)
    }
}
